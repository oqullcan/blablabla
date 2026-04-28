# ============================================================
#  ALBUS PLAYBOOK v3.0
#  github.com/oqullcan/albuswin
#
#  architecture  : single-script, phase-driven
#  philosophy    : minimal surface, maximum intent
#  target        : windows 11 24h2+ / 2027 ready
#  execution     : phases run top-to-bottom, each self-contained
#  author        : oqullcan
# ============================================================

#region ── BOOTSTRAP ─────────────────────────────────────────

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls13, [Net.SecurityProtocolType]::Tls12

# 64-bit process enforcement
if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -and -not [Environment]::Is64BitProcess) {
    $native = "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $native) { & $native -ExecutionPolicy Bypass -NoProfile -File $PSCommandPath; exit }
}

# Admin check
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "albus requires administrator privileges."; exit 1
}

#endregion

#region ── CONSTANTS ─────────────────────────────────────────

$ALBUS_DIR     = 'C:\Albus'
$ALBUS_LOG     = "$ALBUS_DIR\albus.log"
$ALBUS_VERSION = '3.0'
$TODAY         = Get-Date
$PAUSE_END     = $TODAY.AddYears(31)
$TODAY_STR     = $TODAY.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$PAUSE_STR     = $PAUSE_END.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Resolve active user SID (handles running-as-admin from another user)
$script:ActiveSID = $null
try {
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue |
                Select-Object -First 1
    if ($explorer) { $script:ActiveSID = (Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid).Sid }
} catch { }

$HKCU_ROOT = if ($script:ActiveSID) { "HKEY_USERS\$script:ActiveSID" }    else { "HKEY_CURRENT_USER" }
$HKCU_PS   = if ($script:ActiveSID) { "Registry::HKEY_USERS\$script:ActiveSID" } else { "HKCU:" }

#endregion

#region ── LOGGING & UI ──────────────────────────────────────

if (-not (Test-Path $ALBUS_DIR)) { New-Item -ItemType Directory -Path $ALBUS_DIR -Force | Out-Null }

$script:PhaseTimer = $null

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] $Message"
    Add-Content -Path $ALBUS_LOG -Value $entry -ErrorAction SilentlyContinue
}

function Write-Phase {
    param([string]$Name)
    $script:PhaseTimer = [Diagnostics.Stopwatch]::StartNew()
    $line = '─' * (60 - $Name.Length - 3)
    Write-Host ""
    Write-Host "  ┌─ " -NoNewline -ForegroundColor DarkGray
    Write-Host $Name.ToUpper() -NoNewline -ForegroundColor White
    Write-Host " $line" -ForegroundColor DarkGray
    Write-Log "PHASE: $Name"
}

function Write-Done {
    param([string]$Name)
    $elapsed = if ($script:PhaseTimer) { "$([math]::Round($script:PhaseTimer.Elapsed.TotalSeconds, 1))s" } else { "" }
    Write-Host "  └─ " -NoNewline -ForegroundColor DarkGray
    Write-Host "done" -NoNewline -ForegroundColor Green
    Write-Host " [$elapsed]" -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Message, [string]$Status = 'run')
    $icon, $color = switch ($Status) {
        'run'  { '·', 'DarkGray'  }
        'ok'   { '✓', 'Green'     }
        'skip' { '○', 'DarkGray'  }
        'fail' { '✗', 'Red'       }
        'warn' { '!', 'Yellow'    }
    }
    Write-Host "  │  $icon " -NoNewline -ForegroundColor $color
    Write-Host $Message.ToLower() -ForegroundColor Gray
    Write-Log "  [$Status] $Message"
}

# Print banner
function Write-Banner {
    [Console]::Title = "albus v$ALBUS_VERSION"
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name.Split('\')[-1].ToLower()
    Write-Host ""
    Write-Host "  albus " -NoNewline -ForegroundColor White
    Write-Host "v$ALBUS_VERSION" -NoNewline -ForegroundColor DarkGray
    Write-Host "  ·  " -NoNewline -ForegroundColor DarkGray
    Write-Host $user -ForegroundColor DarkGray
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor DarkGray
    Write-Host ""
}

#endregion

#region ── REGISTRY ENGINE ───────────────────────────────────

# PSDrives
function Initialize-Drives {
    foreach ($d in @('HKCR', 'HKU')) {
        if (-not (Get-PSDrive -Name $d -ErrorAction SilentlyContinue)) {
            $root = if ($d -eq 'HKCR') { 'HKEY_CLASSES_ROOT' } else { 'HKEY_USERS' }
            New-PSDrive -Name $d -PSProvider Registry -Root $root | Out-Null
        }
    }
}

function Resolve-RegistryPath {
    param([string]$Path)
    $clean = $Path.TrimStart('-')
    $psPath = $clean `
        -replace '^HKLM:', 'Registry::HKEY_LOCAL_MACHINE' `
        -replace '^HKCU:', $HKCU_PS `
        -replace '^HKCR:', 'Registry::HKEY_CLASSES_ROOT' `
        -replace '^HKU:',  'Registry::HKEY_USERS'
    $regPath = $clean `
        -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' `
        -replace '^HKCU:', $HKCU_ROOT `
        -replace '^HKCR:', 'HKEY_CLASSES_ROOT' `
        -replace '^HKU:',  'HKEY_USERS'
    return $psPath, $regPath
}

function Set-Reg {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    try {
        $delete = $Path.StartsWith('-')
        $psPath, $regPath = Resolve-RegistryPath $Path

        # Delete entire key
        if ($delete) {
            if ($regPath -like '*HKEY_CLASSES_ROOT*') {
                cmd /c "reg delete `"$regPath`" /f 2>nul"
            } elseif (Test-Path $psPath) {
                Remove-Item -Path $psPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            return
        }

        # Delete value
        if ($Value -eq '-') {
            if (Test-Path $psPath) {
                Remove-ItemProperty -Path $psPath -Name $Name -Force -ErrorAction SilentlyContinue
            }
            return
        }

        # Create key if needed
        if (-not (Test-Path $psPath)) {
            New-Item -Path $psPath -Force -ErrorAction SilentlyContinue | Out-Null
        }

        # Set value
        if ($Name -eq '') {
            Set-Item -Path $psPath -Value $Value -Force -ErrorAction SilentlyContinue
        } else {
            $regTypeMap = @{
                DWord        = 'REG_DWORD'
                QWord        = 'REG_QWORD'
                String       = 'REG_SZ'
                ExpandString = 'REG_EXPAND_SZ'
                Binary       = 'REG_BINARY'
                MultiString  = 'REG_MULTI_SZ'
            }
            try {
                New-ItemProperty -Path $psPath -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
            } catch {
                $regType   = if ($regTypeMap[$Type]) { $regTypeMap[$Type] } else { 'REG_DWORD' }
                $regValue  = if ($Type -eq 'Binary') { ($Value | ForEach-Object { '{0:X2}' -f $_ }) -join '' } else { $Value }
                $exit = cmd /c "reg add `"$regPath`" /v `"$Name`" /t $regType /d `"$regValue`" /f 2>nul"; `$LASTEXITCODE
                if ($exit -ne 0) { Write-Log "REG FAIL: $regPath\$Name" }
            }
        }
    } catch {
        Write-Log "REG ERR: $Path\$Name — $_"
    }
}

function Apply-Tweaks {
    param([array]$Tweaks)
    foreach ($t in $Tweaks) {
        $tName = if ($t.Name) { $t.Name } else { '' }
        $tType = if ($t.Type) { $t.Type } else { 'DWord' }
        Set-Reg -Path $t.Path -Name $tName -Value $t.Value -Type $tType
    }
}

#endregion

#region ── NETWORK HELPER ────────────────────────────────────

function Test-Network {
    return (Test-Connection -ComputerName '1.1.1.1' -Count 2 -Quiet -ErrorAction SilentlyContinue)
}

function Get-GitHubRelease {
    param([string]$Repo)
    return (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -ErrorAction Stop)
}

function Get-File {
    param([string]$Url, [string]$Out)
    Invoke-WebRequest -Uri $Url -OutFile $Out -UseBasicParsing -ErrorAction Stop
}

#endregion

# ════════════════════════════════════════════════════════════
#  EXECUTION BEGINS
# ════════════════════════════════════════════════════════════

Write-Banner
Initialize-Drives

# ════════════════════════════════════════════════════════════
#  PHASE 1 · SYSTEM PREPARATION
#  Must run first — sets up base environment before any
#  registry or service changes. Ordering matters here.
# ════════════════════════════════════════════════════════════

Write-Phase 'system preparation'

# 1.1  Kill interfering processes before touching their state
Write-Step 'stopping shell processes'
'AppActions','CrossDeviceResume','FESearchHost','SearchHost','SoftLandingTask',
'TextInputHost','WebExperienceHostApp','WindowsBackupClient','ShellExperienceHost',
'StartMenuExperienceHost','Widgets','WidgetService','MiniSearchHost' |
    ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }

# 1.2  PsDrive registration (already done via Initialize-Drives, confirm)
Write-Step 'registry drives initialized'

# 1.3  Capability consent storage reset (must precede camera/mic tweaks)
Write-Step 'resetting capability consent storage'
Stop-Service -Name 'camsvc' -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityConsentStorage.db*" `
    -Force -ErrorAction SilentlyContinue

Write-Done 'system preparation'

# ════════════════════════════════════════════════════════════
#  PHASE 2 · SOFTWARE INSTALLATION
#  Network-dependent. Runs early so downloads happen while
#  later phases execute (sequential here, could be parallelized
#  in a future version with PowerShell jobs).
# ════════════════════════════════════════════════════════════

Write-Phase 'software installation'

if (Test-Network) {

    # 2.1  Brave Browser
    try {
        Write-Step 'brave browser'
        $rel = Get-GitHubRelease 'brave/brave-browser'
        Get-File "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe" `
                 "$ALBUS_DIR\BraveSetup.exe"
        Start-Process -Wait "$ALBUS_DIR\BraveSetup.exe" -ArgumentList '/silent /install' -WindowStyle Hidden
        Set-Reg 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'HardwareAccelerationModeEnabled' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BackgroundModeEnabled'           0
        Set-Reg 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'HighEfficiencyModeEnabled'       1
        Write-Step "brave $($rel.tag_name) installed" 'ok'
    } catch { Write-Step 'brave installation failed' 'fail' }

    # 2.2  7-Zip
    try {
        Write-Step '7-zip'
        $rel = Get-GitHubRelease 'ip7z/7zip'
        $url = ($rel.assets | Where-Object { $_.name -match '7z.*-x64\.exe' }).browser_download_url
        Get-File $url "$ALBUS_DIR\7zip.exe"
        Start-Process -Wait "$ALBUS_DIR\7zip.exe" -ArgumentList '/S'
        Set-Reg 'HKCU:\Software\7-Zip\Options' 'ContextMenu'  259
        Set-Reg 'HKCU:\Software\7-Zip\Options' 'CascadedMenu' 0
        Write-Step "7-zip $($rel.name) installed" 'ok'
    } catch { Write-Step '7-zip installation failed' 'fail' }

    # 2.3  LocalSend
    try {
        Write-Step 'localsend'
        $rel = Get-GitHubRelease 'localsend/localsend'
        $url = ($rel.assets | Where-Object { $_.name -match 'LocalSend-.*-windows-x86-64\.exe' }).browser_download_url
        Get-File $url "$ALBUS_DIR\localsend.exe"
        Start-Process -Wait "$ALBUS_DIR\localsend.exe" -ArgumentList '/VERYSILENT /ALLUSERS /SUPPRESSMSGBOXES /NORESTART'
        Write-Step "localsend $($rel.name) installed" 'ok'
    } catch { Write-Step 'localsend installation failed' 'fail' }

    # 2.4  Visual C++ Redistributable
    try {
        Write-Step 'visual c++ x64 runtime'
        Get-File 'https://aka.ms/vs/17/release/vc_redist.x64.exe' "$ALBUS_DIR\vc_redist.x64.exe"
        Start-Process -Wait "$ALBUS_DIR\vc_redist.x64.exe" -ArgumentList '/quiet /norestart' -WindowStyle Hidden
        Write-Step 'vc++ runtime installed' 'ok'
    } catch { Write-Step 'vc++ runtime failed' 'fail' }

    # 2.5  DirectX End-User Runtime
    try {
        Write-Step 'directx runtime'
        Get-File 'https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe' `
                 "$ALBUS_DIR\dxwebsetup.exe"
        Start-Process -Wait "$ALBUS_DIR\dxwebsetup.exe" -ArgumentList '/Q' -WindowStyle Hidden
        Write-Step 'directx runtime installed' 'ok'
    } catch { Write-Step 'directx runtime failed' 'fail' }

} else {
    Write-Step 'no network — skipping software installation' 'warn'
}

Write-Done 'software installation'

# ════════════════════════════════════════════════════════════
#  PHASE 3 · REGISTRY TWEAKS
#  Ordered by system scope: accessibility → UI/UX → privacy
#  → performance. Each section is independently reviewable.
# ════════════════════════════════════════════════════════════

Write-Phase 'registry tweaks'

# ── 3.1  Accessibility (disable unused assistive tech) ──────
Write-Step 'accessibility'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Narrator\NoRoam'; Name = 'DuckAudio';              Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator\NoRoam'; Name = 'WinEnterLaunchEnabled';  Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator\NoRoam'; Name = 'ScriptingEnabled';       Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator\NoRoam'; Name = 'OnlineServicesEnabled';  Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator\NoRoam'; Name = 'EchoToggleKeys';         Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator';        Name = 'NarratorCursorHighlight';Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator';        Name = 'CoupleNarratorCursorKeyboard'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator';        Name = 'IntonationPause';        Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator';        Name = 'ReadHints';              Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator';        Name = 'ErrorNotificationType';  Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator';        Name = 'EchoChars';              Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator';        Name = 'EchoWords';              Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator\NarratorHome'; Name = 'MinimizeType';     Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Narrator\NarratorHome'; Name = 'AutoStart';        Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Ease of Access'; Name = 'selfvoice';               Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Ease of Access'; Name = 'selfscan';                Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\ScreenMagnifier'; Name = 'FollowCaret';            Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\ScreenMagnifier'; Name = 'FollowNarrator';         Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\ScreenMagnifier'; Name = 'FollowMouse';            Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\ScreenMagnifier'; Name = 'FollowFocus';            Value = 0 }
    @{ Path = 'HKCU:\Control Panel\Accessibility';        Name = 'Sound on Activation';    Value = 0 }
    @{ Path = 'HKCU:\Control Panel\Accessibility';        Name = 'Warning Sounds';         Value = 0 }
    @{ Path = 'HKCU:\Control Panel\Accessibility\HighContrast';     Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\Keyboard Response'; Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\Keyboard Response'; Name = 'AutoRepeatRate'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\Keyboard Response'; Name = 'AutoRepeatDelay'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\MouseKeys';   Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\StickyKeys';  Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\ToggleKeys';  Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\SoundSentry'; Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\SoundSentry'; Name = 'FSTextEffect';  Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\SoundSentry'; Name = 'TextEffect';    Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\SoundSentry'; Name = 'WindowsEffect'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\SlateLaunch'; Name = 'ATapp';    Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\SlateLaunch'; Name = 'LaunchAT'; Value = 0 }
    @{ Path = 'HKCU:\Control Panel\Accessibility\AudioDescription';  Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\Blind Access';      Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\Keyboard Preference'; Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\ShowSounds'; Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\TimeOut';    Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Keyboard'; Name = 'PrintScreenKeyForSnippingEnabled'; Value = 0 }
    # Default user
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\AudioDescription'; Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\HighContrast';     Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\Keyboard Response'; Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys';   Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\StickyKeys';  Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\ToggleKeys';  Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\SoundSentry'; Name = 'Flags'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\TimeOut';     Name = 'Flags'; Value = '0'; Type = 'String' }
)

# ── 3.2  Visual Effects & Desktop ────────────────────────────
Write-Step 'visual effects'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; Value = 3 }
    @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'UserPreferencesMask'; Value = ([byte[]](0x90,0x12,0x03,0x80,0x12,0x00,0x00,0x00)); Type = 'Binary' }
    @{ Path = 'HKCU:\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate';    Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'DragFullWindows'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'FontSmoothing';  Value = '2'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'JPEGImportQuality'; Value = 100 }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'MenuShowDelay';  Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'ActiveWndTrkTimeout'; Value = 10 }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'AutoEndTasks';   Value = '1'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'HungAppTimeout'; Value = '2000'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'WaitToKillAppTimeout'; Value = '2000'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'LowLevelHooksTimeout'; Value = '1000'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'LogPixels'; Value = 96 }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'Win8DpiScaling'; Value = 1 }
    @{ Path = 'HKCU:\Control Panel\Desktop';               Name = 'EnablePerProcessSystemDPI'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations';    Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'IconsOnly';            Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewAlphaSelect';  Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewShadow';       Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'EnableAeroPeek';          Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'AlwaysHibernateThumbnails'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'AccentColor';              Value = -15132391 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'ColorizationAfterglow';    Value = -1004988135 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'ColorizationColor';        Value = -1004988135 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'EnableWindowColorization'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'UseDpiScaling';            Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'OverlayTestMode';          Value = 5 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'JPEGImportQuality';  Value = 100 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'MenuShowDelay';      Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'AutoEndTasks';       Value = '1'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'HungAppTimeout';     Value = '2000'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'WaitToKillAppTimeout'; Value = '2000'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; Value = 0 }
)

# ── 3.3  Personalization ──────────────────────────────────────
Write-Step 'personalization'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Control Panel\Desktop';                                  Name = 'Wallpaper';         Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'; Name = 'BackgroundType'; Value = 1 }
    @{ Path = 'HKCU:\Control Panel\Colors';                                   Name = 'Background';        Value = '0 0 0'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'AppsUseLightTheme';      Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'SystemUsesLightTheme';   Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency';     Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'ColorPrevalence';        Value = 1 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent'; Name = 'AccentColorMenu'; Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent'; Name = 'StartColorMenu';  Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent'; Name = 'AccentPalette'; Type = 'Binary'
       Value = ([byte[]](0x64,0x64,0x64,0x00,0x6b,0x6b,0x6b,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)) }
    @{ Path = 'HKCU:\Software\Microsoft\Lighting'; Name = 'AmbientLightingEnabled';   Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Lighting'; Name = 'ControlledByForegroundApp'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Lighting'; Name = 'UseSystemAccentColor';      Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu'; Name = '{645FF040-5081-101B-9F08-00AA002F954E}'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel';    Name = '{645FF040-5081-101B-9F08-00AA002F954E}'; Value = 1 }
)

# ── 3.4  Explorer & Shell ──────────────────────────────────────
Write-Step 'explorer & shell'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowFrequent';             Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'ShowCloudFilesInQuickAccess'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'EnableAutoTray';           Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'MultipleInvokePromptMinimum'; Value = 100 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'link'; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = 'Binary' }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo';              Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt';            Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'FolderContentsInfoTip';  Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowInfoTip';            Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowPreviewHandlers';    Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowStatusBar';          Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowSyncProviderNotifications'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SharingWizardOn';        Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarSmallIcons';      Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'UseCompactMode';         Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SnapAssist';             Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'EnableSnapBar';          Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'EnableTaskGroups';       Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'EnableSnapAssistFlyout'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SnapFill';               Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'JointResize';            Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'MultiTaskingAltTabFilter'; Value = 3 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name = 'TaskbarEndTask'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'; Name = 'FullPath'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'; Name = 'EnthusiastMode'; Value = 1 }
    @{ Path = 'HKCU:\Software\Classes\CLSID\{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}'; Name = 'System.IsPinnedToNameSpaceTree'; Value = 0 }
    @{ Path = 'HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}'; Name = 'System.IsPinnedToNameSpaceTree'; Value = 0 }
    @{ Path = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'; Name = 'FolderType'; Value = 'NotSpecified'; Type = 'String' }
    @{ Path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; Name = 'C:\Windows\explorer.exe'; Value = 'GpuPreference=2;'; Type = 'String' }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun';     Value = 255 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoLowDiskSpaceChecks';   Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'LinkResolveIgnoreLinkInfo'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoResolveSearch';        Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoPublishingWizard';     Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoWebServices';          Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoOnlinePrintsWizard';   Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoInternetOpenWith';     Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'HideSCAMeetNow';         Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'HubMode'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'; Name = 'ShowLockOption';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'; Name = 'ShowSleepOption'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'; Name = 'SearchOrderConfig'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun';   Value = 255 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoLowDiskSpaceChecks'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'AllowOnlineTips';      Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'HideSCAMeetNow';       Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'HideRecentlyAddedApps'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableGraphRecentItems';  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection';   Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecentlyAddedApps';    Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'ShowOrHideMostUsedApps';   Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HidePeopleBar';            Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoBalloonFeatureAdvertisements'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'NoAutoTrayNotify';         Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control';                  Name = 'WaitToKillServiceTimeout'; Value = '1500'; Type = 'String' }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem';   Name = 'LongPathsEnabled';        Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'MultipleInvokePromptMinimum'; Value = 100 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo';    Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowInfoTip'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name = 'TaskbarEndTask'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'; Name = 'EnthusiastMode'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'LinkResolveIgnoreLinkInfo'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'HideSCAMeetNow'; Value = 1 }
)

# ── 3.5  Taskbar ──────────────────────────────────────────────
Write-Step 'taskbar'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAl';   Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarSd';   Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarMn';   Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarSn';   Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa';   Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowTaskViewButton'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowCopilotButton'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'IconSizePreference'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds'; Name = 'ShellFeedsTaskbarViewMode'; Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds';           Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat'; Name = 'ChatIcon';               Value = 3 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests';                   Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowTaskViewButton'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarMn'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Feeds'; Name = 'ShellFeedsTaskbarViewMode'; Value = 2 }
)

# ── 3.6  Start Menu ───────────────────────────────────────────
Write-Step 'start menu'
$StartPins = '{"pinnedList":[{"packagedAppId":"Microsoft.WindowsStore_8wekyb3d8bbwe!App"},{"packagedAppId":"windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"},{"packagedAppId":"Microsoft.WindowsNotepad_8wekyb3d8bbwe!App"},{"packagedAppId":"Microsoft.Paint_8wekyb3d8bbwe!App"},{"desktopAppLink":"%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\File Explorer.lnk"},{"packagedAppId":"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"}]}'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_Layout'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_AccountNotifications'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_RecoPersonalizedSites'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_TrackDocs'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_IrisRecommendations'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'; Name = 'ShowRecentList';           Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'; Name = 'AllAppsViewMode';          Value = 2 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start'; Name = 'RightCompanionToggledOpen'; Value = 0 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'HideRecommendedSection'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'ConfigureStartPins';  Value = $StartPins; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDocuments'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDownloads'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderFileExplorer'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderMusic'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderNetwork'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPersonalFolder'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPictures'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderSettings'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderVideos'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education'; Name = 'IsEducationEnvironment'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_IrisRecommendations'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_AccountNotifications'; Value = 0 }
)
# Clear start2.bin (Win11)
if ([Environment]::OSVersion.Version.Build -ge 22000) {
    $start2 = "$env:USERPROFILE\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin"
    Remove-Item $start2 -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllBytes($start2, [Convert]::FromBase64String('AgAAABAAAAD9////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=='))
}

# ── 3.7  Mouse & Input ────────────────────────────────────────
Write-Step 'mouse & input'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSpeed';      Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold1'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold2'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSensitivity'; Value = '10'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'RawMouseThrottleEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'SmoothMouseXCurve'; Type = 'Binary'
       Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xC0,0xCC,0x0C,0x00,0x00,0x00,0x00,0x00,0x80,0x99,0x19,0x00,0x00,0x00,0x00,0x00,0x40,0x66,0x26,0x00,0x00,0x00,0x00,0x00,0x00,0x33,0x33,0x00,0x00,0x00,0x00,0x00)) }
    @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'SmoothMouseYCurve'; Type = 'Binary'
       Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x38,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x70,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xA8,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xE0,0x00,0x00,0x00,0x00,0x00)) }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'ContactVisualization'; Value = 0 }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'GestureVisualization'; Value = 0 }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'Scheme Source';        Value = 0 }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = '';           Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'Arrow';      Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'IBeam';      Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'Wait';       Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'Hand';       Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'Help';       Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'No';         Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'SizeAll';    Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'SizeNS';     Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'SizeWE';     Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'SizeNESW';   Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'SizeNWSE';   Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'UpArrow';    Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'Crosshair';  Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'AppStarting'; Value = ''; Type = 'ExpandString' }
    @{ Path = 'HKCU:\Control Panel\Cursors'; Name = 'NWPen';      Value = ''; Type = 'ExpandString' }
    # Keyboard
    @{ Path = 'HKCU:\Keyboard Layout\Toggle'; Name = 'Language Hotkey'; Value = '3'; Type = 'String' }
    @{ Path = 'HKCU:\Keyboard Layout\Toggle'; Name = 'Hotkey';          Value = '3'; Type = 'String' }
    @{ Path = 'HKCU:\Keyboard Layout\Toggle'; Name = 'Layout Hotkey';   Value = '3'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\International\User Profile'; Name = 'HttpAcceptLanguageOptOut'; Value = 1 }
    # Touch keyboard
    @{ Path = 'HKCU:\Software\Microsoft\TabletTip\1.7';  Name = 'EnableAutoShiftEngage'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\TabletTip\1.7';  Name = 'EnableKeyAudioFeedback'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\TabletTip\1.7';  Name = 'EnableDoubleTapSpace';  Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7';  Name = 'EnableAutocorrection';  Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7';  Name = 'EnableSpellchecking';   Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7';  Name = 'EnableTextPrediction';  Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\input\Settings'; Name = 'IsVoiceTypingKeyEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\input\Settings'; Name = 'InsightsEnabled';          Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\TabletTip\1.7';  Name = 'EnableAutocorrection';   Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\TabletTip\1.7';  Name = 'EnableSpellchecking';    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\TabletTip\1.7';  Name = 'EnableTextPrediction';   Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\CTF\LangBar'; Name = 'ExtraIconsOnMinimized'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\CTF\LangBar'; Name = 'ShowStatus';            Value = 3 }
    @{ Path = 'HKCU:\Software\Microsoft\CTF\LangBar'; Name = 'Transparency';          Value = 255 }
    # HW Mouse (DEFAULT)
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Mouse'; Name = 'MouseSpeed';      Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Mouse'; Name = 'MouseThreshold1'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Mouse'; Name = 'MouseThreshold2'; Value = '0'; Type = 'String' }
)

# ── 3.8  Sound ───────────────────────────────────────────────
Write-Step 'sound'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Control Panel\Sound'; Name = 'Beep'; Value = 'no'; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes'; Name = ''; Value = '.None'; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\.Default\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\CriticalBatteryAlarm\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\DeviceConnect\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\DeviceDisconnect\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\DeviceFail\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\LowBatteryAlarm\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\Notification.Default\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\SystemAsterisk\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\SystemExclamation\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\SystemHand\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\AppEvents\Schemes\Apps\.Default\WindowsUAC\.Current'; Name = ''; Value = ''; Type = 'String' }
    @{ Path = 'HKCU:\Software\Microsoft\Multimedia\Audio'; Name = 'UserDuckingPreference'; Value = 3 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation'; Name = 'DisableStartupSound'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\EditionOverrides'; Name = 'UserSetting_DisableStartupSound'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Sound'; Name = 'Beep'; Value = 'no'; Type = 'String' }
)

# ── 3.9  Search ───────────────────────────────────────────────
Write-Step 'search'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled';    Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'CortanaConsent';       Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'GleamEnabled';         Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'WeatherEnabled';       Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsDeviceSearchHistoryEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsDynamicSearchBoxEnabled';   Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsAADCloudSearchEnabled';     Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings'; Name = 'IsMSACloudSearchEnabled';     Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCloudSearch';       Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowCortanaAboveLock';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'AllowSearchToUseLocation'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchUseWeb';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'DisableWebSearch';       Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'PreventIndexOnBattery';  Value = 1 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows Search\Gather\Windows\SystemIndex'; Name = 'RespectPowerModes'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'CortanaConsent';    Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions'; Value = 1 }
)

# ── 3.10  Notifications ───────────────────────────────────────
Write-Step 'notifications'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; Name = 'NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; Name = 'NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'; Name = 'AutoOpenCopilotLargeScreens'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoCloudApplicationNotification'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'UpdateNotificationLevel'; Value = 2 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Value = 0 }
)

# ── 3.11  Copilot & AI Features ───────────────────────────────
Write-Step 'copilot & ai features'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis';  Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement';  Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Dsh'; Name = 'IsPrelaunchEnabled';      Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis';  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo';       Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name = 'DisableGenerativeFill'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name = 'DisableCocreator';      Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name = 'DisableImageCreator';   Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\WindowsNotepad'; Name = 'DisableAIFeatures'; Value = 1 }
)

# ── 3.12  Privacy & Telemetry ─────────────────────────────────
Write-Step 'privacy & telemetry'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Input\TIPC'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Personalization\Settings'; Name = 'AcceptedPrivacyPolicy'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name = 'HasAccepted'; Value = 0 }
    # Capability access
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location';               Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam';                 Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone';             Name = 'Value'; Value = 'Allow'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener'; Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\contacts';               Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments';           Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\email';                  Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics';         Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess';  Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\systemAIModels';         Name = 'Value'; Value = 'Deny'; Type = 'String' }
    # Telemetry policy
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry';            Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowDeviceNameInTelemetry'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'LimitDiagnosticLogCollection'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'LimitDumpCollection';        Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'DisableOneSettingsDownloads'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'DoNotShowFeedbackNotifications'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Name = 'AllowTelemetry'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Name = 'AllowTelemetry'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener'; Name = 'Start'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SQMLogger'; Name = 'Start'; Value = 0 }
    # Firewall: block telemetry & error reporting outbound
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
       Name = 'Block-Unified-Telemetry-Client'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|'
       Type = 'String' }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
       Name = 'Block-Windows-Error-Reporting'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Windows-Error-Reporting|'
       Type = 'String' }
    # Error reporting
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'Disabled';            Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'DontSendAdditionalData'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'DontShowUI';          Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'; Name = 'DisableWerUpload';    Value = 1 }
    # Cloud content
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableSoftLanding';          Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsSpotlightFeatures'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsConsumerFeatures'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableThirdPartySuggestions'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableWindowsSpotlightFeatures'; Value = 1 }
    # Activity tracking
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed';    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'; Name = 'LetAppsRunInBackground'; Value = 2 }
    # CEIP
    @{ Path = 'HKLM:\Software\Policies\Microsoft\SQMClient\Windows'; Name = 'CEIPEnable'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\AppV\CEIP';          Name = 'CEIPEnable'; Value = 0 }
    # Maps
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps'; Name = 'AutoDownloadAndUpdateMapData'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps'; Name = 'AllowUntriggeredNetworkTrafficOnSettingsPage'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\Maps'; Name = 'AutoUpdateEnabled'; Value = 0 }
    # Input personalization
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization'; Name = 'AllowInputPersonalization'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC'; Name = 'PreventHandwritingDataSharing'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\TIPC'; Name = 'Enabled'; Value = 0 }
)

# ── 3.13  Content Delivery Manager ────────────────────────────
Write-Step 'content delivery manager'
$cdmKeys = @('ContentDeliveryAllowed','FeatureManagementEnabled','OemPreInstalledAppsEnabled',
              'PreInstalledAppsEnabled','PreInstalledAppsEverEnabled','RotatingLockScreenEnabled',
              'RotatingLockScreenOverlayEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled',
              'SlideshowEnabled','SubscribedContentEnabled','RemediationRequired',
              'SubscribedContent-310093Enabled','SubscribedContent-338387Enabled',
              'SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
              'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled')
$cdmPaths = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
              'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
              'HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
              'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager')
foreach ($p in $cdmPaths) {
    foreach ($k in $cdmKeys) { Set-Reg $p $k 0 }
}

# ── 3.14  Updates & Delivery Optimization ─────────────────────
Write-Step 'windows update'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'PauseUpdatesExpiryTime';        Value = $PAUSE_STR; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'PauseFeatureUpdatesEndTime';    Value = $PAUSE_STR; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'PauseFeatureUpdatesStartTime';  Value = $TODAY_STR; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'PauseQualityUpdatesEndTime';    Value = $PAUSE_STR; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'PauseQualityUpdatesStartTime';  Value = $TODAY_STR; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'TrayIconVisibility';            Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'HideMCTLink';                   Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'RestartNotificationsAllowed2';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'FlightSettingsMaxPauseDays';    Value = 5269 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate';    Name = 'ExcludeWUDriversInQualityUpdate'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate';    Name = 'AllowTemporaryEnterpriseFeatureControl'; Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'IncludeRecommendedUpdates'; Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'EnableFeaturedSoftware'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'; Name = 'ShippedWithReserves'; Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsStore'; Name = 'AutoDownload';    Value = 4 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsStore'; Name = 'DisableOSUpgrade'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate';  Name = 'workCompleted'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate';  Name = 'workCompleted'; Value = 1 }
)
try {
    Remove-Item 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'   -Recurse -Force -ErrorAction SilentlyContinue
} catch { }

# ── 3.15  Security & SmartScreen ──────────────────────────────
Write-Step 'security'
Apply-Tweaks @(
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost'; Name = 'EnableWebContentEvaluation'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen'; Name = 'ConfigureAppInstallControlEnabled'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen'; Name = 'ConfigureAppInstallControl'; Value = 'Anywhere'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray'; Name = 'HideSystray'; Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\BitLocker'; Name = 'PreventDeviceEncryption'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device'; Name = 'DevicePasswordLessBuildVersion'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'DisableAutomaticRestartSignOn'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableFirstLogonAnimation'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'MSAOptional'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSync'; Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSyncUserOverride'; Value = 1 }
)

# ── 3.16  OOBE ────────────────────────────────────────────────
Write-Step 'oobe'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'BypassNRO';               Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'HideOnlineAccountScreens'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'ProtectYourPC';            Value = 3 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'DisablePrivacyExperience'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'DisableVoice';             Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'EnableCortanaVoice';       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'; Name = 'DisablePrivacyExperience';       Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'; Name = 'HideOnlineAccountScreens';       Value = 1 }
)

# ── 3.17  Bypass Requirements ─────────────────────────────────
Write-Step 'hardware requirement bypass'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassSecureBootCheck'; Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassTPMCheck';        Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassCPUCheck';        Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassRAMCheck';        Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\MoSetup';   Name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; Value = 1 }
    @{ Path = 'HKCU:\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; Value = 0 }
    @{ Path = 'HKCU:\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Value = 0 }
)

# ── 3.18  GPU & Graphics ──────────────────────────────────────
Write-Step 'gpu & graphics'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode';         Value = 2 }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'MiracastForceDisable'; Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'TdrDelay';           Value = 12 }
    @{ Path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; Name = 'DirectXUserGlobalSettings'; Value = 'SwapEffectUpgradeEnable=1;VRROptimizeEnable=0;'; Type = 'String' }
)
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Set-Reg $_.PSPath 'AutoColorManagementEnabled' 0 }

# ── 3.19  Gaming ──────────────────────────────────────────────
Write-Step 'gaming'
Apply-Tweaks @(
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled';        Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AudioCaptureEnabled';      Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'CursorCaptureEnabled';     Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'MaximumRecordLength'; Value = 720000000000; Type = 'QWord' }
    @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'UseNexusForGameBarEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled';       Value = 1 }
    @{ Path = 'HKCR:\ms-gamebar'; Name = 'NoOpenWith'; Value = ''; Type = 'String' }
    @{ Path = 'HKCR:\ms-gamingoverlay'; Name = 'NoOpenWith'; Value = ''; Type = 'String' }
)

# ── 3.20  System Performance ──────────────────────────────────
Write-Step 'system performance'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; Name = 'Win32PrioritySeparation'; Value = 38 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\PriorityControl';     Name = 'Win32PrioritySeparation'; Value = 38 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; Value = 10 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'; Name = 'MaintenanceDisabled'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScheduledDiagnostics'; Name = 'EnabledExecution'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; Name = 'fAllowToGetHelp'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name = 'AutoReboot';        Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name = 'CrashDumpEnabled';  Value = 3 }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'; Name = 'DisplayParameters'; Value = 1 }
    @{ Path = 'HKLM:\System\CurrentControlSet\Control\TimeZoneInformation'; Name = 'RealTimeIsUniversal'; Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; Name = 'DisableWpbtExecution'; Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\Session Manager'; Name = 'BootExecute'; Value = 'autocheck autochk /k:C*'; Type = 'MultiString' }
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'; Name = 'PowerThrottlingOff'; Value = 1 }
    # IFEO performance overrides
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SearchIndexer.exe\PerfOptions'; Name = 'CpuPriorityClass'; Value = 5 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ctfmon.exe\PerfOptions';       Name = 'CpuPriorityClass'; Value = 5 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\fontdrvhost.exe\PerfOptions';  Name = 'CpuPriorityClass'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\lsass.exe\PerfOptions';       Name = 'CpuPriorityClass'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sihost.exe\PerfOptions';      Name = 'CpuPriorityClass'; Value = 1 }
    # IFEO telemetry blockers
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CompatTelRunner.exe'; Name = 'Debugger'; Value = '%windir%\System32\taskkill.exe'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\AggregatorHost.exe';  Name = 'Debugger'; Value = '%windir%\System32\taskkill.exe'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe';    Name = 'Debugger'; Value = '%windir%\System32\taskkill.exe'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\BCILauncher.exe';     Name = 'Debugger'; Value = '%windir%\System32\taskkill.exe'; Type = 'String' }
    # Branding
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; Name = 'EditionSubManufacturer'; Value = 'Albus'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; Name = 'EditionSubVersion';      Value = 'V3.0'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'Manufacturer';  Value = 'Albus'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'SupportURL';    Value = 'https://github.com/oqullcan/albuswin'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\UI\Visibility'; Name = 'HideInsiderPage'; Value = 1 }
    # Timer resolution
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel'; Name = 'GlobalTimerResolutionRequests'; Value = 1 }
    # App compat
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisableEngine';    Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'AITEnable';        Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisableInventory'; Value = 1 }
    # Storage
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'; Name = 'AllowStorageSenseGlobal'; Value = 0 }
    # Edge blocking
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'InstallDefault'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate'; Name = 'DoNotUpdateToEdgeWithChromium'; Value = 1 }
    # Wifi sense
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features'; Name = 'WiFiSenseOpen'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy'; Name = 'fDisablePowerManagement'; Value = 1 }
    # Svchost split threshold (merge all svchost instances → less RAM overhead)
    @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control'; Name = 'SvcHostSplitThresholdInKB'; Value = 0xffffffff }
)

Write-Step 'registry tweaks complete' 'ok'
Write-Done 'registry tweaks'

# ════════════════════════════════════════════════════════════
#  PHASE 4 · SERVICES
#  Runs after registry so Start values written above agree
#  with what sc.exe then enforces.
# ════════════════════════════════════════════════════════════

Write-Phase 'services'

$ServiceConfig = @(
    # Telemetry & diagnostics
    @{ Name = 'DiagTrack';                                Start = 4 }
    @{ Name = 'dmwappushservice';                         Start = 4 }
    @{ Name = 'diagnosticshub.standardcollector.service'; Start = 4 }
    @{ Name = 'WerSvc';                                   Start = 4 }
    @{ Name = 'wercplsupport';                            Start = 4 }
    @{ Name = 'DPS';                                      Start = 4 }
    @{ Name = 'WdiServiceHost';                           Start = 4 }
    @{ Name = 'WdiSystemHost';                            Start = 4 }
    @{ Name = 'troubleshootingsvc';                       Start = 4 }
    @{ Name = 'diagsvc';                                  Start = 4 }
    @{ Name = 'PcaSvc';                                   Start = 4 }
    @{ Name = 'InventorySvc';                             Start = 4 }
    # Bloat
    @{ Name = 'RetailDemo';                               Start = 4 }
    @{ Name = 'MapsBroker';                               Start = 4 }
    @{ Name = 'wisvc';                                    Start = 4 }
    @{ Name = 'UCPD';                                     Start = 4 }
    @{ Name = 'GraphicsPerfSvc';                          Start = 4 }
    @{ Name = 'Ndu';                                      Start = 4 }
    @{ Name = 'DSSvc';                                    Start = 4 }
    @{ Name = 'WSAIFabricSvc';                            Start = 4 }
    # Print
    @{ Name = 'Spooler';                                  Start = 4 }
    @{ Name = 'PrintNotify';                              Start = 4 }
    # Remote desktop
    @{ Name = 'TermService';                              Start = 4 }
    @{ Name = 'UmRdpService';                             Start = 4 }
    @{ Name = 'SessionEnv';                               Start = 4 }
    # Edge update
    @{ Name = 'edgeupdate';                               Start = 4 }
    # Sync
    @{ Name = 'OneSyncSvc';                               Start = 4 }
    @{ Name = 'CDPUserSvc';                               Start = 4 }
    @{ Name = 'TrkWks';                                   Start = 4 }
    # Superfluous
    @{ Name = 'SysMain';                                  Start = 4 }
    @{ Name = 'dam';                                      Start = 4 }
    @{ Name = 'amdfendr';                                 Start = 4 }
    @{ Name = 'amdfendrmgr';                              Start = 4 }
    # condrv needs auto
    @{ Name = 'condrv';                                   Start = 2 }
)

foreach ($svc in $ServiceConfig) {
    if (Get-Service -Name $svc.Name -ErrorAction SilentlyContinue) {
        sc.exe stop $svc.Name >$null 2>&1
        $startType = switch ($svc.Start) { 2 { 'auto' } 3 { 'demand' } 4 { 'disabled' } }
        sc.exe config $svc.Name start= $startType >$null 2>&1
        Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Services\$($svc.Name)" 'Start' $svc.Start
    }
}

# Merge svchost instances for all matching services
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $img = (Get-ItemProperty -Path $_.PSPath -Name 'ImagePath' -ErrorAction SilentlyContinue).ImagePath
        if ($img -match 'svchost\.exe') {
            Set-Reg $_.PSPath 'SvcHostSplitDisable' 1
        }
    } catch { }
}

Write-Step 'services configured' 'ok'
Write-Done 'services'

# ════════════════════════════════════════════════════════════
#  PHASE 5 · SCHEDULED TASKS
# ════════════════════════════════════════════════════════════

Write-Phase 'scheduled tasks'

$TasksToDisable = @(
    'Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    'Microsoft\Windows\Application Experience\ProgramDataUpdater',
    'Microsoft\Windows\Application Experience\StartupAppTask',
    'Microsoft\Windows\Application Experience\PcaPatchDbTask',
    'Microsoft\Windows\AppxDeploymentClient\UCPD Velocity',
    'Microsoft\Windows\Autochk\Proxy',
    'Microsoft\Windows\Customer Experience Improvement Program\Consolidator',
    'Microsoft\Windows\Customer Experience Improvement Program\UsbCeip',
    'Microsoft\Windows\Customer Experience Improvement Program\Uploader',
    'Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector',
    'Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance',
    'Microsoft\Windows\Windows Defender\Windows Defender Cleanup',
    'Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan',
    'Microsoft\Windows\Windows Defender\Windows Defender Verification',
    'Microsoft\Windows\Flighting\FeatureConfig\UsageDataReporting',
    'Microsoft\Windows\Defrag\ScheduledDefrag',
    'Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem',
    'Microsoft\Windows\Feedback\Siuf\DmClient',
    'Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload'
)

foreach ($task in $TasksToDisable) {
    $taskName = ($task -split '\\')[-1]
    $taskPath = '\' + ($task -split '\\')[0..($task.Split('\').Count - 2)] -join '\'
    Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue | Out-Null
}

Write-Step 'scheduled tasks disabled' 'ok'
Write-Done 'scheduled tasks'

# ════════════════════════════════════════════════════════════
#  PHASE 6 · NETWORK STACK
# ════════════════════════════════════════════════════════════

Write-Phase 'network'

Write-Step 'tcp stack'
netsh int tcp set global autotuninglevel=restricted    2>&1 | Out-Null
netsh int tcp set global ecncapability=disabled        2>&1 | Out-Null
netsh int tcp set global timestamps=disabled           2>&1 | Out-Null
netsh int tcp set global initialRto=2000               2>&1 | Out-Null
netsh int tcp set global rss=enabled                   2>&1 | Out-Null
netsh int tcp set global rsc=disabled                  2>&1 | Out-Null
netsh int tcp set global nonsackrttresiliency=disabled 2>&1 | Out-Null

Write-Step 'adapter optimization'
Disable-NetAdapterLso -Name '*' -IPv4 -ErrorAction SilentlyContinue | Out-Null
Set-NetAdapterAdvancedProperty -Name '*' -DisplayName 'Interrupt Moderation' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue | Out-Null
'ms_lldp','ms_lltdio','ms_implat','ms_rspndr','ms_tcpip6','ms_server','ms_msclient','ms_pacer' | ForEach-Object {
    Disable-NetAdapterBinding -Name '*' -ComponentID $_ -ErrorAction SilentlyContinue | Out-Null
}

Write-Step 'per-interface tcp no-delay'
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue | ForEach-Object {
    Set-Reg $_.PSPath 'TcpAckFrequency' 1
    Set-Reg $_.PSPath 'TCPNoDelay'      1
}

Write-Step 'nic power saving'
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = $_.PSPath
    if (-not (Get-ItemProperty -Path $p -Name '*SpeedDuplex' -ErrorAction SilentlyContinue)) { return }
    if (Get-ItemProperty -Path $p -Name '*PhyType' -ErrorAction SilentlyContinue) { return }
    'EnablePME','*DeviceSleepOnDisconnect','*EEE','AdvancedEEE','*SipsEnabled','EnableAspm',
    '*WakeOnMagicPacket','*WakeOnPattern','AutoPowerSaveModeEnabled','EEELinkAdvertisement',
    'EnableGreenEthernet','SavePowerNowEnabled','ULPMode','WakeOnLink','WakeOnSlot',
    '*NicAutoPowerSaver','PowerSaveEnable','EnablePowerManagement' | ForEach-Object {
        if (Get-ItemProperty -Path $p -Name $_ -ErrorAction SilentlyContinue) { Set-Reg $p $_ '0' 'String' }
    }
    if (Get-ItemProperty -Path $p -Name 'PnPCapabilities' -ErrorAction SilentlyContinue) { Set-Reg $p 'PnPCapabilities' 24 }
}

Set-Reg 'HKLM:\System\CurrentControlSet\Services\Dnscache\Parameters' 'DisableCoalescing' 1
Write-Done 'network'

# ════════════════════════════════════════════════════════════
#  PHASE 7 · POWER PLAN
# ════════════════════════════════════════════════════════════

Write-Phase 'power plan'

$PowerSaverGUID = 'a1841308-3541-4fab-bc81-f71556f20b4a'
powercfg -restoredefaultschemes 2>&1 | Out-Null
powercfg /SETACTIVE $PowerSaverGUID 2>&1 | Out-Null

$dupOut    = powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
$AlbusGUID = if ($dupOut -match '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $Matches[1] } else {
    $AlbusGUID = '99999999-9999-9999-9999-999999999999'
    powercfg /delete $AlbusGUID 2>&1 | Out-Null
    powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $AlbusGUID 2>&1 | Out-Null
    $AlbusGUID
}
powercfg /changename $AlbusGUID 'Albus 3.0' 'minimal latency, unparked cores, peak throughput.' 2>&1 | Out-Null

# Remove other plans
(powercfg /l 2>$null | Out-String) -split "`r?`n" | ForEach-Object {
    if ($_ -match ':') {
        $parts = $_ -split ':'
        if ($parts.Count -gt 1) {
            $idx = $parts[1].Trim().IndexOf('(')
            if ($idx -gt 0) {
                $guid = $parts[1].Trim().Substring(0, $idx).Trim()
                if ($guid -ne $AlbusGUID -and $guid -ne $PowerSaverGUID -and $guid.Length -ge 36) {
                    powercfg /delete $guid 2>&1 | Out-Null
                }
            }
        }
    }
}

# Power settings: "SubGUID SettingGUID Value"
@(
    '54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100'  # min cpu
    '54533251-82be-4824-96c1-47b60b740d00 bc5038f7-23e0-4960-96da-33abaf5935ec 100'  # max cpu
    '54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100'  # min unpark
    '54533251-82be-4824-96c1-47b60b740d00 ea062031-0e34-4ff1-9b6d-eb1059334028 100'  # max unpark
    '54533251-82be-4824-96c1-47b60b740d00 94d3a615-a899-4ac5-ae2b-e4d8f634367f 1'    # cooling active
    '54533251-82be-4824-96c1-47b60b740d00 36687f9e-e3a5-4dbf-b1dc-15eb381c6863 0'    # energy perf pref
    '54533251-82be-4824-96c1-47b60b740d00 93b8b6dc-0698-4d1c-9ee4-0644e900c85d 0'    # heterogeneous scheduling
    '238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0'    # sleep after
    '238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0'    # hybrid sleep off
    '238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 0'    # hibernate after
    '238c9fa8-0aad-41ed-83f4-97be242c8f20 bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 0'    # wake timers off
    '2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0'    # usb selective suspend off
    '501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0'    # pcie link state off
    '7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 600'  # display timeout 10m
    '7516b95f-f776-4464-8c53-06167f40cc99 aded5e82-b909-4619-9949-f5d71dac0bcb 100'  # display brightness
    '7516b95f-f776-4464-8c53-06167f40cc99 fbd9aa66-9553-4097-ba44-ed6e9d65eab8 0'    # adaptive brightness off
    '4f971e89-eebd-4455-a8de-9e59040e7347 a7066653-8d6c-40a8-910e-a1f54b84c7e5 2'    # power button = shutdown
    'de830923-a562-41af-a086-e3a2c6bad2da e69653ca-cf7f-4f05-aa73-cb833fa90ad4 0'    # battery saver auto off
) | ForEach-Object {
    if ($_ -match '(?<s>[a-f0-9-]+)\s+(?<i>[a-f0-9-]+)\s+(?<v>\d+)') {
        powercfg /attributes $Matches.s $Matches.i -ATTRIB_HIDE 2>$null | Out-Null
        powercfg /setacvalueindex $AlbusGUID $Matches.s $Matches.i $Matches.v 2>$null | Out-Null
        powercfg /setdcvalueindex $AlbusGUID $Matches.s $Matches.i $Matches.v 2>$null | Out-Null
    }
}

powercfg /SETACTIVE $AlbusGUID 2>&1 | Out-Null
powercfg /hibernate off 2>$null | Out-Null

Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'        0
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabledDefault' 0
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0

Write-Step "albus power plan active [$AlbusGUID]" 'ok'
Write-Done 'power plan'

# ════════════════════════════════════════════════════════════
#  PHASE 8 · HARDWARE TUNING
#  MSI mode, ghost devices, disk cache, device power
# ════════════════════════════════════════════════════════════

Write-Phase 'hardware tuning'

# 8.1  MSI interrupt mode
Write-Step 'msi mode'
Get-PnpDevice -InstanceId 'PCI\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -match 'OK|Unknown' } | ForEach-Object {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management"
        Set-Reg "$p\MessageSignaledInterruptProperties" 'MSISupported' 1
    }

# 8.2  GPU MSI
Write-Step 'gpu msi mode'
Get-PnpDevice -Class 'Display' -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match '^PCI\\' } | ForEach-Object {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management"
        Set-Reg "$p\MessageSignaledInterruptProperties" 'MSISupported' 1
        Remove-ItemProperty -Path "$p\Affinity Policy" -Name 'DevicePriority' -ErrorAction SilentlyContinue
    }

# 8.3  Ghost device removal
Write-Step 'ghost device cleanup'
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Present -and $_.InstanceId -notmatch '^(ROOT|SWD|HTREE|DISPLAY|BTHENUM)\\' } |
    ForEach-Object { pnputil /remove-device $_.InstanceId /quiet >$null 2>&1 }

# 8.4  Disk write cache
Write-Step 'disk write cache'
Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceType -ne 'USB' -and $_.PNPDeviceID } | ForEach-Object {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters\Disk"
        Set-Reg $p 'UserWriteCacheSetting' 1
        Set-Reg $p 'CacheIsPowerProtected' 1
    }

# 8.5  Disable device power saving
Write-Step 'device power saving'
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -match 'OK|Unknown' } | ForEach-Object {
    $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters"
    Set-Reg "$p\WDF" 'IdleInWorkingState' 0
    'SelectiveSuspendEnabled','SelectiveSuspendOn','EnhancedPowerManagementEnabled','WaitWakeEnabled' |
        ForEach-Object { Set-Reg $p $_ 0 }
}

# 8.6  Exploit guard — disable system-wide mitigations for perf
Write-Step 'exploit guard'
(Get-Command 'Set-ProcessMitigation' -ErrorAction SilentlyContinue).Parameters['Disable'].Attributes.ValidValues |
    ForEach-Object { Set-ProcessMitigation -SYSTEM -Disable $_.ToString() -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null }

$KernelPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel'
$auditLen   = try { (Get-ItemProperty $KernelPath 'MitigationAuditOptions').MitigationAuditOptions.Length } catch { 38 }
[byte[]]$mitigPayload = [Linq.Enumerable]::Repeat([byte]34, $auditLen)

'fontdrvhost.exe','dwm.exe','lsass.exe','svchost.exe','WmiPrvSE.exe',
'winlogon.exe','csrss.exe','audiodg.exe','services.exe','explorer.exe',
'taskhostw.exe','sihost.exe' | ForEach-Object {
    $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$_"
    Set-Reg $ifeoPath 'MitigationOptions'      $mitigPayload 'Binary'
    Set-Reg $ifeoPath 'MitigationAuditOptions' $mitigPayload 'Binary'
}
Set-Reg $KernelPath 'MitigationOptions'      $mitigPayload 'Binary'
Set-Reg $KernelPath 'MitigationAuditOptions' $mitigPayload 'Binary'

# Intel TSX
if ((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Manufacturer -eq 'GenuineIntel') {
    Set-Reg $KernelPath 'DisableTSX' 0
} else {
    Remove-ItemProperty -Path $KernelPath -Name 'DisableTSX' -ErrorAction SilentlyContinue
}

Write-Done 'hardware tuning'

# ════════════════════════════════════════════════════════════
#  PHASE 9 · FILESYSTEM & BOOT
# ════════════════════════════════════════════════════════════

Write-Phase 'filesystem & boot'

Write-Step 'ntfs'
fsutil behavior set disable8dot3 1        2>&1 | Out-Null
fsutil behavior set disabledeletenotify 0 2>&1 | Out-Null
fsutil behavior set disablelastaccess 1   2>&1 | Out-Null

Write-Step 'bcdedit'
bcdedit /deletevalue useplatformclock 2>&1 | Out-Null
bcdedit /deletevalue useplatformtick  2>&1 | Out-Null
bcdedit /set bootmenupolicy legacy    2>&1 | Out-Null
bcdedit /timeout 10                   2>&1 | Out-Null
bcdedit /set '{current}' description 'Albus 3.0' 2>&1 | Out-Null
label C: Albus 2>&1 | Out-Null

Write-Step 'disable memory compression'
Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null

Write-Step 'disable bitlocker'
Get-BitLockerVolume -ErrorAction SilentlyContinue |
    Where-Object { $_.ProtectionStatus -eq 'On' } |
    Disable-BitLocker -ErrorAction SilentlyContinue | Out-Null

Write-Step 'winevt diagnostic channels'
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels' -ErrorAction SilentlyContinue |
    ForEach-Object {
        $ep = Get-ItemProperty -Path $_.PSPath -Name 'Enabled' -ErrorAction SilentlyContinue
        if ($ep -and $ep.Enabled -eq 1) {
            Set-ItemProperty -Path $_.PSPath -Name 'Enabled' -Value 0 -Force -ErrorAction SilentlyContinue
        }
    }

Write-Step 'safe mode msiserver'
Set-Reg 'HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Minimal\MSIServer' '' 'Service' 'String'
Set-Reg 'HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Network\MSIServer' '' 'Service' 'String'

Write-Done 'filesystem & boot'

# ════════════════════════════════════════════════════════════
#  PHASE 10 · ALBUSX SERVICE
#  Compile & deploy the core engine last — it depends on all
#  previous phases having completed successfully.
# ════════════════════════════════════════════════════════════

Write-Phase 'albusx service'

$SvcName = 'AlbusXSvc'
$ExePath  = "$env:SystemRoot\AlbusX.exe"
$CSPath   = "$env:SystemRoot\AlbusX.cs"
$CSC      = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$SrcURL   = 'https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/albus/albus2.cs'

if (Get-Service $SvcName -ErrorAction SilentlyContinue) {
    Stop-Service $SvcName -Force -ErrorAction SilentlyContinue
    sc.exe delete $SvcName >$null 2>&1
    Start-Sleep 1
}
Remove-Item $ExePath -Force -ErrorAction SilentlyContinue

if (Test-Network) {
    Write-Step 'fetching albusx source'
    try { Get-File $SrcURL $CSPath } catch { Write-Step 'source fetch failed' 'warn' }
}

if ((Test-Path $CSPath) -and (Test-Path $CSC)) {
    Write-Step 'compiling albusx'
    & $CSC -r:System.ServiceProcess.dll -r:System.Configuration.Install.dll `
           -r:System.Management.dll -r:Microsoft.Win32.Registry.dll `
           -out:"$ExePath" "$CSPath" >$null 2>&1
    Remove-Item $CSPath -Force -ErrorAction SilentlyContinue
}

if (Test-Path $ExePath) {
    New-Service -Name $SvcName -BinaryPathName $ExePath -DisplayName 'AlbusX' `
        -Description 'albus core engine 3.0 — precision timer, audio latency, memory, interrupt affinity.' `
        -StartupType Automatic -ErrorAction SilentlyContinue | Out-Null
    sc.exe failure $SvcName reset= 60 actions= restart/5000/restart/10000/restart/30000 >$null 2>&1
    Start-Service $SvcName -ErrorAction SilentlyContinue
    Write-Step 'albusx running' 'ok'
} else {
    Write-Step 'albusx not deployed (compilation unavailable)' 'warn'
}

Write-Done 'albusx service'

# ════════════════════════════════════════════════════════════
#  PHASE 11 · DEBLOAT
#  UWP removal, Edge, OneDrive.
#  Runs late — all services are stopped, state is clean.
# ════════════════════════════════════════════════════════════

Write-Phase 'debloat'

# 11.1  UWP apps
Write-Step 'uwp packages'
$UWPKeep = '*CBS*','*AV1VideoExtension*','*AVCEncoderVideoExtension*','*HEIFImageExtension*',
           '*HEVCVideoExtension*','*MPEG2VideoExtension*','*Paint*','*RawImageExtension*',
           '*SecHealthUI*','*VP9VideoExtensions*','*WebMediaExtensions*','*WebpImageExtension*',
           '*Windows.Photos*','*ShellExperienceHost*','*StartMenuExperienceHost*',
           '*WindowsNotepad*','*WindowsStore*','*NVIDIACorp.NVIDIAControlPanel*','*immersivecontrolpanel*'
Get-AppxPackage -AllUsers | Where-Object {
    $name = $_.Name
    -not ($UWPKeep | Where-Object { $name -like $_ })
} | ForEach-Object {
    try {
        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
        Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -eq $_.PackageFullName } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null }
    } catch { }
}

# 11.2  Windows capabilities
Write-Step 'optional capabilities'
try {
    Get-WindowsCapability -Online -ErrorAction Stop |
        Where-Object {
            $_.State -eq 'Installed' -and
            $_.Name -notlike '*Ethernet*' -and $_.Name -notlike '*MSPaint*' -and
            $_.Name -notlike '*Notepad*'  -and $_.Name -notlike '*Wifi*' -and
            $_.Name -notlike '*NetFX3*'   -and $_.Name -notlike '*ShellComponents*'
        } | ForEach-Object {
            try { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
} catch { }

# 11.3  Optional features
Write-Step 'optional features'
try {
    Get-WindowsOptionalFeature -Online -ErrorAction Stop |
        Where-Object {
            $_.State -eq 'Enabled' -and
            $_.FeatureName -notlike '*NetFx*' -and
            $_.FeatureName -notlike '*SearchEngine-Client*' -and
            $_.FeatureName -notlike '*Windows-Defender*' -and
            $_.FeatureName -notlike '*WirelessNetworking*'
        } | ForEach-Object {
            try { Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
} catch { }

# 11.4  Edge removal
Write-Step 'microsoft edge'
'backgroundTaskHost','Copilot','MicrosoftEdgeUpdate','msedge','msedgewebview2','Widgets','WidgetService' |
    ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }

'HKCU:\SOFTWARE','HKLM:\SOFTWARE','HKCU:\SOFTWARE\Policies','HKLM:\SOFTWARE\Policies',
'HKLM:\SOFTWARE\WOW6432Node','HKLM:\SOFTWARE\WOW6432Node\Policies' | ForEach-Object {
    Remove-Item "$_\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue
}

try {
    $euKey = Get-Item 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' -ErrorAction SilentlyContinue
    if ($euKey) {
        $uStr = $euKey.GetValue('UninstallString') + ' --force-uninstall'
        Start-Process cmd.exe -ArgumentList "/c $uStr" -WindowStyle Hidden -Wait
    }
} catch { }

Get-Service | Where-Object { $_.Name -match 'Edge' } | ForEach-Object {
    sc.exe stop $_.Name >$null 2>&1; sc.exe delete $_.Name >$null 2>&1
}

# 11.5  OneDrive removal
Write-Step 'onedrive'
Stop-Process -Force -Name OneDrive -ErrorAction SilentlyContinue
@("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") |
    Where-Object { Test-Path $_ } |
    ForEach-Object { Start-Process -Wait $_ -ArgumentList '/uninstall' -WindowStyle Hidden }
Get-ScheduledTask | Where-Object { $_.TaskName -match 'OneDrive' } |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

Write-Step 'debloat complete' 'ok'
Write-Done 'debloat'

# ════════════════════════════════════════════════════════════
#  PHASE 12 · STARTUP & TASK CLEANUP
# ════════════════════════════════════════════════════════════

Write-Phase 'startup cleanup'

@('HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce') | ForEach-Object {
    if (Test-Path $_) {
        $real = $_.Replace('HKCU:', 'HKEY_CURRENT_USER').Replace('HKLM:', 'HKEY_LOCAL_MACHINE')
        reg.exe delete "$real" /f /va >$null 2>&1
    }
}

@("$env:AppData\Microsoft\Windows\Start Menu\Programs\Startup",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") | ForEach-Object {
    if (Test-Path $_) { Remove-Item "$_\*" -Recurse -Force -ErrorAction SilentlyContinue }
}

# Remove third-party scheduled tasks (keep Microsoft subtree)
$taskTree = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree'
Get-ChildItem $taskTree -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -ne 'Microsoft' } |
    ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }

Write-Step 'startup entries cleared' 'ok'
Write-Done 'startup cleanup'

# ════════════════════════════════════════════════════════════
#  PHASE 13 · UI: TRUE BLACK WALLPAPER & SHELL REFRESH
# ════════════════════════════════════════════════════════════

Write-Phase 'ui'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction SilentlyContinue

$BlackFile = "$env:SystemRoot\Albus.jpg"
if (-not (Test-Path $BlackFile)) {
    try {
        $sw  = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width
        $sh  = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Height
        $bmp = New-Object System.Drawing.Bitmap $sw, $sh
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.FillRectangle([System.Drawing.Brushes]::Black, 0, 0, $sw, $sh)
        $g.Dispose(); $bmp.Save($BlackFile); $bmp.Dispose()
    } catch { Write-Step 'wallpaper generation failed' 'warn' }
}

Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' 'LockScreenImagePath'   $BlackFile 'String'
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' 'LockScreenImageStatus' 1

# context menu cleanup
@('-HKCR:\Folder\shell\pintohome',
  '-HKCR:\*\shell\pintohomefile',
  '-HKCR:\exefile\shellex\ContextMenuHandlers\Compatibility',
  '-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing',
  '-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo') | ForEach-Object {
    Set-Reg -Path $_ -Name '' -Value ''
}

# block shell extensions
@('{9F156763-7844-4DC4-B2B1-901F640F5155}', '{09A47860-11B0-4DA5-AFA5-26D86198A780}', '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}') | ForEach-Object {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked' $_ '' 'String'
}

# notify icons - promote all
Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 1 -Force -ErrorAction SilentlyContinue }

# refresh shell
rundll32.exe user32.dll, UpdatePerUserSystemParameters
Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue

Write-Step 'ui applied' 'ok'
Write-Done 'ui'

# ════════════════════════════════════════════════════════════
#  PHASE 14 · GPU DRIVER  (interactive)
# ════════════════════════════════════════════════════════════

Write-Phase 'gpu driver'

function Install-NvidiaDriver {
    Start-Process 'https://www.nvidia.com/en-us/drivers'
    Write-Host ''
    Write-Host '  download the driver, then press any key...' -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = 'select nvidia driver'
    $dlg.Filter = 'Executable (*.exe)|*.exe'
    if ($dlg.ShowDialog() -ne 'OK') { Write-Step 'cancelled' 'warn'; return }

    $ZipExe = 'C:\Program Files\7-Zip\7z.exe'
    if (-not (Test-Path $ZipExe)) { Write-Step '7-zip not found' 'fail'; return }

    $ExtractPath = "$env:SystemRoot\Temp\NVIDIA"
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
    Write-Step 'extracting'
    & $ZipExe x $dlg.FileName -o"$ExtractPath" -y | Out-Null

    Write-Step 'stripping bloat (display.driver + nvi2 only)'
    Get-ChildItem $ExtractPath |
        Where-Object { @('Display.Driver','NVI2','EULA.txt','ListDevices.txt','setup.cfg','setup.exe') -notcontains $_.Name } |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $cfg = "$ExtractPath\setup.cfg"
    if (Test-Path $cfg) {
        (Get-Content $cfg) | Where-Object { $_ -notmatch 'EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile' } |
            Set-Content $cfg -Force
    }

    Write-Step 'installing silently'
    Start-Process "$ExtractPath\setup.exe" -ArgumentList '-s -noreboot -noeula -clean' -Wait -NoNewWindow

    Write-Step 'nvidia registry tweaks'
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
            Set-Reg $_.PSPath 'DisableDynamicPstate' 1
            Set-Reg $_.PSPath 'RMHdcpKeyglobZero'    1
            Set-Reg $_.PSPath 'RmProfilingAdminOnly'  0
        }

    Set-Reg 'HKLM:\System\ControlSet001\Services\nvlddmkm\FTS'         'EnableGR535'           0
    Set-Reg 'HKCU:\Software\NVIDIA Corporation\NvTray'                  'StartOnLogin'          0
    Set-Reg 'HKCU:\Software\NVIDIA Corporation\NVControlPanel2\Client'  'OptInOrOutPreference'  0

    Write-Step 'nvidia driver installed' 'ok'
}

function Install-AmdDriver {
    Start-Process 'https://www.amd.com/en/support/download/drivers.html'
    Write-Host ''
    Write-Host '  download the adrenalin driver, then press any key...' -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = 'select amd driver'
    $dlg.Filter = 'Executable (*.exe)|*.exe'
    if ($dlg.ShowDialog() -ne 'OK') { Write-Step 'cancelled' 'warn'; return }

    $ZipExe = 'C:\Program Files\7-Zip\7z.exe'
    if (-not (Test-Path $ZipExe)) { Write-Step '7-zip not found' 'fail'; return }

    $ExtractPath = "$env:SystemRoot\Temp\amddriver"
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
    Write-Step 'extracting'
    & $ZipExe x $dlg.FileName -o"$ExtractPath" -y | Out-Null

    # Patch telemetry out of install manifests
    @('Config\AMDAUEPInstaller.xml','Config\AMDCOMPUTE.xml','Config\AMDUpdater.xml',
      'Config\InstallUEP.xml') | ForEach-Object {
        $xp = Join-Path $ExtractPath $_
        if (Test-Path $xp) {
            (Get-Content $xp -Raw) -replace '<Enabled>true</Enabled>', '<Enabled>false</Enabled>' |
                Set-Content $xp -NoNewline
        }
    }

    Write-Step 'installing'
    $setup = "$ExtractPath\Bin64\ATISetup.exe"
    if (Test-Path $setup) { Start-Process -Wait $setup -ArgumentList '-INSTALL -VIEW:2' -WindowStyle Hidden }

    Write-Step 'amd registry tweaks'
    $gpuBase = 'HKLM:\System\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}'
    Get-ChildItem $gpuBase -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $p = $_.PSPath
        Set-Reg $p 'KMD_DeLagEnabled'       1
        Set-Reg $p 'EnableUlps'             0
        Set-Reg $p 'PP_Force3DPerformanceMode' 1
        Set-Reg $p 'PP_ForceHighDPMLevel'   1
        Set-Reg $p 'PP_SclkDeepSleepDisable' 1
        Set-Reg $p 'DisableGfxClockGating'  1
        Set-Reg $p 'DalDisableClockGating'  1
        Set-Reg $p 'DalForceMaxDisplayClock' 1
    }

    Write-Step 'amd driver installed' 'ok'
}

Write-Host ''
Write-Host '  ┌─ SELECT GPU VENDOR ────────────────────' -ForegroundColor DarkGray
Write-Host '  │  1  nvidia' -ForegroundColor Gray
Write-Host '  │  2  amd'    -ForegroundColor Gray
Write-Host '  │  3  skip'   -ForegroundColor DarkGray
Write-Host '  └────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

:gpuLoop while ($true) {
    Write-Host '  > ' -NoNewline -ForegroundColor DarkGray
    $choice = Read-Host
    switch ($choice.Trim()) {
        '1' { Install-NvidiaDriver; break gpuLoop }
        '2' { Install-AmdDriver;   break gpuLoop }
        '3' { Write-Step 'gpu driver skipped' 'skip'; break gpuLoop }
    }
}

Write-Done 'gpu driver'

# ════════════════════════════════════════════════════════════
#  PHASE 15 · CLEANUP
# ════════════════════════════════════════════════════════════

Write-Phase 'cleanup'

lodctr.exe /R 2>&1 | Out-Null

Remove-Item "$env:USERPROFILE\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\Temp\*"                -Recurse -Force -ErrorAction SilentlyContinue

Start-Process cleanmgr.exe -ArgumentList '/autoclean /d C:' -Wait -NoNewWindow

Write-Step 'temp files removed' 'ok'
Write-Done 'cleanup'

# ════════════════════════════════════════════════════════════
#  DONE
# ════════════════════════════════════════════════════════════

$totalTime = [math]::Round(((Get-Date) - $TODAY).TotalMinutes, 1)

Write-Host ''
Write-Host '  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor DarkGray
Write-Host "  albus v$ALBUS_VERSION  ·  complete  ·  ${totalTime}m" -ForegroundColor White
Write-Host "  log → $ALBUS_LOG" -ForegroundColor DarkGray
Write-Host '  restart recommended.' -ForegroundColor DarkGray
Write-Host ''

Write-Log "COMPLETE in ${totalTime}m"
