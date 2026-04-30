
#  ── ogulcan yetim - albus playbook
#  ── https://www.github.com/oqullcan/albuswin
#  ── https://www.x.com/oqullcn

#  ── bootstrap ─────────────────────────────────────────

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls13, [Net.SecurityProtocolType]::Tls12

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "albus requires administrator privileges."; exit 1
}

#  ── constants ─────────────────────────────────────────

$ALBUS_DIR     = 'C:\Albus'
$ALBUS_LOG     = "$ALBUS_DIR\albus.log"
$ALBUS_VERSION = '6.2'
$TODAY         = Get-Date

$script:ActiveSID = $null
try {
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($explorer) { $script:ActiveSID = (Invoke-CimMethod -InputObject $explorer -MethodName GetOwnerSid).Sid }
} catch { }

$HKCU_ROOT = if ($script:ActiveSID) { "HKEY_USERS\$script:ActiveSID" } else { "HKEY_CURRENT_USER" }
$HKCU_PS =   if ($script:ActiveSID) { "Registry::HKEY_USERS\$script:ActiveSID" } else { "HKCU:" }

# ── logging & ui ──────────────────────────────────────

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
        'run'  { '·', 'DarkGray' }
        'ok'   { '✓', 'Green' }
        'skip' { '○', 'DarkGray' }
        'fail' { '✗', 'Red' }
        'warn' { '!', 'Yellow' }
        'query' { '?', 'Cyan' }
    }
    Write-Host "  │  $icon " -NoNewline -ForegroundColor $color
    Write-Host $Message.ToLower() -ForegroundColor Gray
    Write-Log "  [$Status] $Message"
}

function Read-Choice {
    param(
        [string]$Title,
        [string]$Question,
        [array]$Options
    )
    $script:PhaseTimer = [Diagnostics.Stopwatch]::StartNew()
    $line = '─' * (60 - $Title.Length - 3)
    Write-Host ""
    Write-Host "  ┌─ " -NoNewline -ForegroundColor DarkGray
    Write-Host $Title.ToUpper() -NoNewline -ForegroundColor White
    Write-Host " $line" -ForegroundColor DarkGray
    Write-Host "  │  ? " -NoNewline -ForegroundColor Cyan
    $validLabels = $Options.Label -join '/'
    Write-Host "$Question ($validLabels): " -NoNewline -ForegroundColor Gray
    return (Read-Host).Trim()
}

#  print banner
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


# ── registry engine ───────────────────────────────────

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
    $clean = $Path.TrimStart('-') -replace '^Microsoft\.PowerShell\.Core\\Registry::', '' -replace '^Registry::', ''
    $clean = $clean -replace '^HKLM:', 'HKEY_LOCAL_MACHINE' `
                    -replace '^HKCU:', $HKCU_ROOT `
                    -replace '^HKCR:', 'HKEY_CLASSES_ROOT' `
                    -replace '^HKU:',  'HKEY_USERS'
    $psPath = "Registry::$clean"
    $regPath = $clean -replace '^HKEY_LOCAL_MACHINE', 'LocalMachine' `
                      -replace '^HKEY_CURRENT_USER',  'CurrentUser' `
                      -replace '^HKEY_CLASSES_ROOT',  'ClassesRoot' `
                      -replace '^HKEY_USERS',         'Users'
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

        if ($delete) {
            if (Test-Path $psPath) { Remove-Item -Path $psPath -Recurse -Force -ErrorAction SilentlyContinue }
            return
        }

        if ($Value -eq '-') {
            if (Test-Path $psPath) { Remove-ItemProperty -Path $psPath -Name $Name -Force -ErrorAction SilentlyContinue }
            return
        }

        $hive, $subKey = $regPath.Split('\', 2)
        $root = [Microsoft.Win32.Registry]::$hive

        $regType = switch ($Type) {
            'String'       { [Microsoft.Win32.RegistryValueKind]::String }
            'ExpandString' { [Microsoft.Win32.RegistryValueKind]::ExpandString }
            'Binary'       { [Microsoft.Win32.RegistryValueKind]::Binary }
            'DWord'        { [Microsoft.Win32.RegistryValueKind]::DWord }
            'MultiString'  { [Microsoft.Win32.RegistryValueKind]::MultiString }
            'QWord'        { [Microsoft.Win32.RegistryValueKind]::QWord }
            default        { [Microsoft.Win32.RegistryValueKind]::DWord }
        }

        $key = $root.CreateSubKey($subKey)
        if ($key) {
            $finalValue = $Value
            if ($regType -eq 'DWord') { $finalValue = [int32]$Value }
            elseif ($regType -eq 'QWord') { $finalValue = [int64]$Value }
            $key.SetValue($Name, $finalValue, $regType)
            $key.Close()
        }
    } catch {
        Write-Log "REG ERR: $Path\$Name — $_"
    }
}

function Set-Tweaks {
    param(
        [string]$Path,
        [hashtable]$Settings,
        [string]$Type = 'DWord'
    )
    try {
        $psPath, $regPath = Resolve-RegistryPath $Path
        $hive, $subKey = $regPath.Split('\', 2)
        $root = [Microsoft.Win32.Registry]::$hive
        $key = $root.CreateSubKey($subKey)

        if ($key) {
            foreach ($name in $Settings.Keys) {
                $val = $Settings[$name]
                $regType = switch ($Type) {
                    'String'       { [Microsoft.Win32.RegistryValueKind]::String }
                    'ExpandString' { [Microsoft.Win32.RegistryValueKind]::ExpandString }
                    'Binary'       { [Microsoft.Win32.RegistryValueKind]::Binary }
                    'DWord'        { [Microsoft.Win32.RegistryValueKind]::DWord }
                    'MultiString'  { [Microsoft.Win32.RegistryValueKind]::MultiString }
                    'QWord'        { [Microsoft.Win32.RegistryValueKind]::QWord }
                    default        { [Microsoft.Win32.RegistryValueKind]::DWord }
                }
                $key.SetValue($name, $val, $regType)
            }
            $key.Close()
        }
    } catch {
        Write-Log "TWEAK ERR: $Path — $_"
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

# ── network helper ────────────────────────────────────

function Test-Network {
    return (Test-Connection -ComputerName '1.1.1.1' -Count 3 -Quiet -ErrorAction SilentlyContinue)
}

#  ════════════════════════════════════════════════════════════
#  execution begins
#  ════════════════════════════════════════════════════════════

Write-Banner
Initialize-Drives

#  ════════════════════════════════════════════════════════════
#  phase 1  system preparation
#  must run first — sets up base environment before any
#  registry or service changes. Ordering matters
#  ════════════════════════════════════════════════════════════

Write-Phase 'system preparation'

# 1.1  kill interfering processes before touching their state
Write-Step 'stopping shell processes'
'AppActions',
'CrossDeviceResume',
'FESearchHost',
'SearchHost',
'SoftLandingTask',
'TextInputHost',
'WebExperienceHostApp',
'WindowsBackupClient',
'ShellExperienceHost',
'StartMenuExperienceHost',
'Widgets',
'WidgetService',
'MiniSearchHost' | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }

# 1.2  psdrive registration (already done via initialize-drives, confirm)
Write-Step 'registry drives initialized'

# 1.3  capability consent storage reset (must precede camera/mic tweaks)
Write-Step 'resetting capability consent storage'
Stop-Service -Name 'camsvc' -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityConsentStorage.db*" -Force -ErrorAction SilentlyContinue

Write-Done 'system preparation'
<#
# ════════════════════════════════════════════════════════════
#  PHASE 2 · SOFTWARE INSTALLATION

Write-Phase 'software installation'

if (Test-Network) {

    # 2.1  brave browser
    try {
        Write-Step 'brave browser'
        $rel = Get-GitHubRelease 'brave/brave-browser'
        Get-File "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe" "$ALBUS_DIR\BraveSetup.exe"
        Start-Process -Wait "$ALBUS_DIR\BraveSetup.exe" -ArgumentList '/silent /install' -WindowStyle Hidden
        Set-Reg 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'HardwareAccelerationModeEnabled' 0
        Set-Reg 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'BackgroundModeEnabled'           0
        Set-Reg 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave' 'HighEfficiencyModeEnabled'       1
        Write-Step "brave $($rel.tag_name) installed" 'ok'
    } catch { Write-Step 'brave installation failed' 'fail' }

    # 2.2  7-zip
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

    # 2.3  localsend
    try {
        Write-Step 'localsend'
        $rel = Get-GitHubRelease 'localsend/localsend'
        $url = ($rel.assets | Where-Object { $_.name -match 'LocalSend-.*-windows-x86-64\.exe' }).browser_download_url
        Get-File $url "$ALBUS_DIR\localsend.exe"
        Start-Process -Wait "$ALBUS_DIR\localsend.exe" -ArgumentList '/VERYSILENT /ALLUSERS /SUPPRESSMSGBOXES /NORESTART'
        Write-Step "localsend $($rel.name) installed" 'ok'
    } catch { Write-Step 'localsend installation failed' 'fail' }

    # 2.4  visual c++ redistributable
    try {
        Write-Step 'visual c++ x64 runtime'
        Get-File 'https://aka.ms/vs/17/release/vc_redist.x64.exe' "$ALBUS_DIR\vc_redist.x64.exe"
        Start-Process -Wait "$ALBUS_DIR\vc_redist.x64.exe" -ArgumentList '/quiet /norestart' -WindowStyle Hidden
        Write-Step 'vc++ runtime installed' 'ok'
    } catch { Write-Step 'vc++ runtime failed' 'fail' }

    # 2.5  directx runtime
    try {
        Write-Step 'directx runtime'
        Get-File 'https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe' "$ALBUS_DIR\dxwebsetup.exe"
        Start-Process -Wait "$ALBUS_DIR\dxwebsetup.exe" -ArgumentList '/Q' -WindowStyle Hidden
        Write-Step 'directx runtime installed' 'ok'
    } catch { Write-Step 'directx runtime failed' 'fail' }

} else {
    Write-Step 'no network — skipping software installation' 'warn'
}

Write-Done 'software installation'

# ════════════════════════════════════════════════════════════
#  PHASE 14 · GPU DRIVER  (interactive)
# ════════════════════════════════════════════════════════════

function NVIDIA {
Write-Phase 'nvidia driver setup'

    Start-Process 'https://www.nvidia.com/en-us/drivers'
    Write-Step '  download the driver, then press any key...' -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title, $dlg.Filter = 'select nvidia driver', 'Executable (*.exe)|*.exe'
    if ($dlg.ShowDialog() -ne 'OK') { Write-Step 'cancelled' 'warn'; return }

    $ZipExe = 'C:\Program Files\7-Zip\7z.exe'
    if (-not (Test-Path $ZipExe)) { Write-Step '7-zip not found' 'fail'; return }

    $ExtractPath = "$ALBUS_DIR\NVIDIA"
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }

    Write-Step 'extracting & debloating'
    & $ZipExe x $dlg.FileName -o"$ExtractPath" -y | Out-Null

    $Whitelist = '^(Display\.Driver|NVI2|EULA\.txt|ListDevices\.txt|setup\.cfg|setup\.exe)$'
    Get-ChildItem $ExtractPath | Where-Object { $_.Name -notmatch $Whitelist } | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $cfg = "$ExtractPath\setup.cfg"
    if (Test-Path $cfg) { (Get-Content $cfg) | Where-Object { $_ -notmatch 'EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile' } | Set-Content $cfg -Force }

    Write-Step 'installing silently'
    Start-Process "$ExtractPath\setup.exe" -ArgumentList '-s -noreboot -noeula -clean' -Wait

    Write-Step 'nvidia optimizations'
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        Set-Reg $_.PSPath 'DisableDynamicPstate' 1
        Set-Reg $_.PSPath 'RMHdcpKeyglobZero'    1
        Set-Reg $_.PSPath 'RmProfilingAdminOnly' 0
    }

    $nvTweak = 'HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak'
    Set-Reg $nvTweak 'NvCplPhysxAuto' 0
    Set-Reg $nvTweak 'NvDevToolsVisible' 1
    Set-Reg $nvTweak 'RmProfilingAdminOnly' 0

    Set-Reg 'HKCU:\Software\NVIDIA Corporation\NvTray' 'StartOnLogin' 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS' 'EnableGR535' 0
    Set-Reg 'HKLM:\SYSTEM\ControlSet001\Services\nvlddmkm\Parameters\FTS' 'EnableGR535' 0
    Set-Reg 'HKCU:\Software\NVIDIA Corporation\NVControlPanel2\Client' 'OptInOrOutPreference' 0

    $DRSPath = 'C:\ProgramData\NVIDIA Corporation\Drs'
    if (Test-Path $DRSPath) { Get-ChildItem -Path $DRSPath -Recurse | Unblock-File -ErrorAction SilentlyContinue }

    Write-Step 'fetching & applying profile inspector'
    $InspectorZip = "$ALBUS_DIR\nvidiaProfileInspector.zip"
    $ExtractDir   = "$ALBUS_DIR\Temp\nvidiaProfileInspector"

    try {
        $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/Orbmu2k/nvidiaProfileInspector/releases/latest" -ErrorAction Stop
        $Asset = ($Release.assets | Where-Object { $_.name -match '\.zip$' })[0]
        if ($Asset) {
            Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $InspectorZip -UseBasicParsing -ErrorAction Stop
            & $ZipExe x "$InspectorZip" -o"$ExtractDir" -y | Out-Null
        }
    } catch { }

    $NIPFile = @"
<?xml version="1.0" encoding="utf-16"?>
<ArrayOfProfile>
  <Profile>
    <ProfileName>Base Profile</ProfileName>
    <Settings>
      <ProfileSetting><SettingNameInfo>Frame Rate Limiter V3</SettingNameInfo><SettingID>277041154</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Application Mode</SettingNameInfo><SettingID>294973784</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Application State</SettingNameInfo><SettingID>279476687</SettingID><SettingValue>4</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Global Feature</SettingNameInfo><SettingID>278196567</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Global Mode</SettingNameInfo><SettingID>278196727</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>GSYNC - Indicator Overlay</SettingNameInfo><SettingID>268604728</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Maximum Pre-Rendered Frames</SettingNameInfo><SettingID>8102046</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Preferred Refresh Rate</SettingNameInfo><SettingID>6600001</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Ultra Low Latency - CPL State</SettingNameInfo><SettingID>390467</SettingID><SettingValue>2</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Ultra Low Latency - Enabled</SettingNameInfo><SettingID>277041152</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vertical Sync</SettingNameInfo><SettingID>11041231</SettingID><SettingValue>138504007</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vertical Sync - Smooth AFR Behavior</SettingNameInfo><SettingID>270198627</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vertical Sync - Tear Control</SettingNameInfo><SettingID>5912412</SettingID><SettingValue>2525368439</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vulkan/OpenGL Present Method</SettingNameInfo><SettingID>550932728</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Gamma Correction</SettingNameInfo><SettingID>276652957</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Mode</SettingNameInfo><SettingID>276757595</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Setting</SettingNameInfo><SettingID>282555346</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic Filter - Optimization</SettingNameInfo><SettingID>8703344</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic Filter - Sample Optimization</SettingNameInfo><SettingID>15151633</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic Filtering - Mode</SettingNameInfo><SettingID>282245910</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic Filtering - Setting</SettingNameInfo><SettingID>270426537</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture Filtering - Negative LOD Bias</SettingNameInfo><SettingID>1686376</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture Filtering - Quality</SettingNameInfo><SettingID>13510289</SettingID><SettingValue>20</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture Filtering - Trilinear Optimization</SettingNameInfo><SettingID>3066610</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>CUDA - Force P2 State</SettingNameInfo><SettingID>1343646814</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>CUDA - Sysmem Fallback Policy</SettingNameInfo><SettingID>283962569</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Power Management - Mode</SettingNameInfo><SettingID>274197361</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Shader Cache - Cache Size</SettingNameInfo><SettingID>11306135</SettingID><SettingValue>4294967295</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Threaded Optimization</SettingNameInfo><SettingID>549528094</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
    </Settings>
  </Profile>
</ArrayOfProfile>
"@
    $NIPPath = "$ALBUS_DIR\inspector.nip"
    $NIPFile | Set-Content $NIPPath -Force

    if (Test-Path $ExtractDir) {
        $InspectorExe = Get-ChildItem -Path $ExtractDir -Filter "*nvidiaProfileInspector.exe" -Recurse | Select-Object -First 1
        if ($InspectorExe) {
            Start-Process $InspectorExe.FullName -ArgumentList "-silentImport $NIPPath" -Wait -NoNewWindow
        }
    }

    Write-Done 'nvidia driver setup'
}

function AMD {
    Write-Phase 'amd driver setup'

    Start-Process 'https://www.amd.com/en/support/download/drivers.html'
    Write-Step '  download the adrenalin driver, then press any key...' -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title, $dlg.Filter = 'select amd driver', 'Executable (*.exe)|*.exe'
    if ($dlg.ShowDialog() -ne 'OK') { Write-Step 'cancelled' 'warn'; return }

    $ZipExe = 'C:\Program Files\7-Zip\7z.exe'
    if (-not (Test-Path $ZipExe)) { Write-Step '7-zip not found' 'fail'; return }

    $ExtractPath = "$ALBUS_DIR\AMD"
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }

    Write-Step 'extracting & patching'
    & $ZipExe x $dlg.FileName -o"$ExtractPath" -y | Out-Null

    $XMLDirs = @('Config\AMDAUEPInstaller.xml', 'Config\AMDCOMPUTE.xml', 'Config\AMDLinkDriverUpdate.xml', 'Config\AMDRELAUNCHER.xml', 'Config\AMDScoSupportTypeUpdate.xml', 'Config\AMDUpdater.xml', 'Config\AMDUWPLauncher.xml', 'Config\EnableWindowsDriverSearch.xml', 'Config\InstallUEP.xml', 'Config\ModifyLinkUpdate.xml')
    foreach ($X in $XMLDirs) {
        $XP = Join-Path $ExtractPath $X
        if (Test-Path $XP) {
            $Content = Get-Content $XP -Raw
            $Content = $Content -replace '<Enabled>true</Enabled>', '<Enabled>false</Enabled>' -replace '<Hidden>true</Hidden>', '<Hidden>false</Hidden>'
            Set-Content $XP -Value $Content -NoNewline
        }
    }

    $JSONDirs = @('Config\InstallManifest.json', 'Bin64\cccmanifest_64.json')
    foreach ($J in $JSONDirs) {
        $JP = Join-Path $ExtractPath $J
        if (Test-Path $JP) {
            $Content = Get-Content $JP -Raw
            $Content = $Content -replace '"InstallByDefault"\s*:\s*"Yes"', '"InstallByDefault" : "No"'
            Set-Content $JP -Value $Content -NoNewline
        }
    }

    Write-Step 'installing silently'
    $Setup = "$ExtractPath\Bin64\ATISetup.exe"
    if (Test-Path $Setup) {
        Start-Process -Wait $Setup -ArgumentList '-INSTALL -VIEW:2' -WindowStyle Hidden
    }

    Write-Step 'cleaning up amd bloat'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'AMDNoiseSuppression' '-' 'String'
    Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' 'StartRSX' '-' 'String'
    Unregister-ScheduledTask -TaskName 'StartCN' -Confirm:$false -ErrorAction SilentlyContinue

    $AMDSvcs = 'AMD Crash Defender Service', 'amdfendr', 'amdfendrmgr', 'amdacpbus', 'AMDSAFD', 'AtiHDAudioService'
    foreach ($S in $AMDSvcs) {
        cmd /c "sc stop `"$S`" >nul 2>&1"
        cmd /c "sc delete `"$S`" >nul 2>&1"
    }

    Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Bug Report Tool" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item "$env:SystemDrive\Windows\SysWOW64\AMDBugReportTool.exe" -Force -ErrorAction SilentlyContinue | Out-Null

    $AMDInstallMgr = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'AMD Install Manager' }
    if ($AMDInstallMgr) { Start-Process 'msiexec.exe' -ArgumentList "/x $($AMDInstallMgr.PSChildName) /qn /norestart" -Wait -NoNewWindow }

    $RSPath = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Software$([char]0xA789) Adrenalin Edition"
    if (Test-Path $RSPath) {
        Move-Item -Path "$RSPath\*.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue
        Remove-Item $RSPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item "$env:SystemDrive\AMD" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

    Write-Step 'amd optimizations'
    $RSP = "$env:SystemDrive\Program Files\AMD\CNext\CNext\RadeonSoftware.exe"
    if (Test-Path $RSP) {
        Start-Process $RSP; Start-Sleep -Seconds 15; Stop-Process -Name 'RadeonSoftware' -Force -ErrorAction SilentlyContinue
    }

    $CN = 'HKCU:\Software\AMD\CN'
    Set-Reg $CN 'AutoUpdate' 0
    Set-Reg $CN 'WizardProfile' 'PROFILE_CUSTOM' 'String'
    Set-Reg "$CN\CustomResolutions" 'EulaAccepted' 'true' 'String'
    Set-Reg "$CN\DisplayOverride" 'EulaAccepted' 'true' 'String'
    Set-Reg $CN 'SystemTray' 'false' 'String'
    Set-Reg $CN 'CN_Hide_Toast_Notification' 'true' 'String'
    Set-Reg $CN 'AnimationEffect' 'false' 'String'

    $GpuBase = 'HKLM:\System\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}'
    Get-ChildItem $GpuBase -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSChildName -eq 'UMD') {
            Set-Reg $_.PSPath 'VSyncControl' ([byte[]](0x30,0x00)) 'Binary'
            Set-Reg $_.PSPath 'TFQ' ([byte[]](0x32,0x00)) 'Binary'
            Set-Reg $_.PSPath 'Tessellation' ([byte[]](0x31,0x00)) 'Binary'
            Set-Reg $_.PSPath 'Tessellation_OPTION' ([byte[]](0x32,0x00)) 'Binary'
        }
        if ($_.PSChildName -eq 'power_v1') {
            Set-Reg $_.PSPath 'abmlevel' ([byte[]](0x00,0x00,0x00,0x00)) 'Binary'
        }
    }

    Write-Done 'amd driver setup'
}

function intel {
}

$GpuMenu = @(
    @{ Label = 'nvidia' }
    @{ Label = 'amd' }
    @{ Label = 'intel' }
    @{ Label = 'skip' }
)

$selection = Read-Choice -Title "GPU DEPLOYMENT SELECTION" -Question "select target hardware" -Options $GpuMenu

switch -regex ($selection) {
    '(?i)^nvidia$' {
        Write-Done "GPU SELECTION"
        NVIDIA
    }
    '(?i)^amd$' {
        Write-Done "GPU SELECTION"
        AMD
    }
    '(?i)^intel$' {
        Write-Step 'intel core not implemented yet' 'warn'
        Write-Done 'GPU SELECTION'
    }
    '(?i)^skip$' {
        Write-Step 'hardware deployment skipped' 'skip'
        Write-Done 'GPU SELECTION'
    }
    default {
        Write-Step "invalid selection: $selection" 'fail'
        Write-Done 'GPU SELECTION'
    }
}

# ── phase 1 - registry tweaks ───────────────────────────────────────────────
Write-Phase 'registry tweaks'

# ── 1.1  boot
Write-Step 'boot'
# disable automatic disk-check on boot (skip autochk on c:)
Set-Reg -Path 'HKLM:\SYSTEM\ControlSet001\Control\Session Manager' `
        -Name 'BootExecute' `
        -Value ([string[]]@('autocheck autochk /k:C*')) `
        -Type 'MultiString'

# disable wpbt (windows platform binary table)
Set-Reg -Path 'HKLM:\SYSTEM\ControlSet001\Control\Session Manager' `
        -Name 'DisableWpbtExecution' -Value 1

# ── 1.2  crash control
Write-Step 'crash control'
Apply-Tweaks @(
    # no auto-reboot on bsod
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\CrashControl'; Name = 'AutoReboot';       Value = 0 }
    # small memory dump (64kb)
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\CrashControl'; Name = 'CrashDumpEnabled'; Value = 3 }
)

# ── 1.3  win32 priority separation
Write-Step 'win32 priority separation'
Set-Reg -Path 'HKLM:\SYSTEM\ControlSet001\Control\PriorityControl' -Name 'Win32PrioritySeparation' -Value 38 # short quantum, variable, 3× foreground boost

# ── 1.4  bypass windows 11 hardware requirements
Write-Step 'bypass hw requirements'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassSecureBootCheck'; Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassTPMCheck';        Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassCPUCheck';        Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassRAMCheck';        Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\LabConfig'; Name = 'BypassStorageCheck';    Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Setup\MoSetup';   Name = 'AllowUpgradesWithUnsupportedTPMOrCPU'; Value = 1 }
    @{ Path = 'HKCU:\Control Panel\UnsupportedHardwareNotificationCache';         Name = 'SV1'; Value = 0 }
    @{ Path = 'HKCU:\Control Panel\UnsupportedHardwareNotificationCache';         Name = 'SV2'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV1'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache'; Name = 'SV2'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'; Name = 'BypassNRO'; Value = 1 }
)

# ── 1.5  bitlocker — disable auto device encryption
Write-Step 'bitlocker'
Set-Reg -Path 'HKLM:\SYSTEM\ControlSet001\Control\BitLocker' -Name 'PreventDeviceEncryption' -Value 1
Get-BitLockerVolume -ErrorAction SilentlyContinue | Where-Object { $_.ProtectionStatus -eq 'On' } | Disable-BitLocker -ErrorAction SilentlyContinue | Out-Null

# ── 1.6  logon
Write-Step 'logon'
Apply-Tweaks @(
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableFirstLogonAnimation';     Value = 0 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'DisableStartupSound';           Value = 1 }
    # prevent apps from reopening after restart/update
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'DisableAutomaticRestartSignOn'; Value = 1 }
    # allow shutdown without logon
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'ShutdownWithoutLogon';         Value = 1 }
    # msa optional for apps
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'MSAOptional';                  Value = 1 }
    # fix for mapped network drives under uac
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name = 'EnableLinkedConnections';      Value = 1 }
)

# ── 1.7  oobe
Write-Step 'oobe'
$OobePaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE'
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'
)
$OobeTweaks = @{
    HideOnlineAccountScreens  = 1
    HideEULAPage              = 1
    SkipMachineOOBE           = 0
    SkipUserOOBE              = 0
    HideWirelessSetupInOOBE   = 1
    ProtectYourPC             = 3
    HideLocalAccountScreen    = 0
    DisablePrivacyExperience  = 1
    HideOEMRegistrationScreen = 1
    EnableCortanaVoice        = 0
    DisableVoice              = 1
}
foreach ($p in $OobePaths) { Set-Tweaks -Path $p -Settings $OobeTweaks }
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' -Name 'NetworkLocation' -Value 'Home' -Type 'String'
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE'       -Name 'NetworkLocation' -Value 'Home' -Type 'String'
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE\AppSettings' -Name 'Skype-UserConsentAccepted' -Value 0

# ── 1.8  desktop & responsiveness
Write-Step 'control panel — desktop & responsiveness'
Apply-Tweaks @(
    # no jpeg wallpaper compression
    @{ Path = 'HKCU:\Control Panel\Desktop';         Name = 'JPEGImportQuality';    Value = 100;    Type = 'DWord' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'JPEGImportQuality';    Value = 100;    Type = 'DWord' }
    # no system beep
    @{ Path = 'HKCU:\Control Panel\Sound';           Name = 'Beep'; Value = 'no'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Sound';   Name = 'Beep'; Value = 'no'; Type = 'String' }
    # instant start menu
    @{ Path = 'HKCU:\Control Panel\Desktop';         Name = 'MenuShowDelay';        Value = '0';    Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'MenuShowDelay';        Value = '0';    Type = 'String' }
    # active window track timeout (10 ms)
    @{ Path = 'HKCU:\Control Panel\Desktop';         Name = 'ActiveWndTrkTimeout';  Value = 10 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'ActiveWndTrkTimeout';  Value = 10 }
    # auto-end tasks on shutdown
    @{ Path = 'HKCU:\Control Panel\Desktop';         Name = 'AutoEndTasks';         Value = '1';    Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'AutoEndTasks';         Value = '1';    Type = 'String' }
    # hung app timeout (2 s)
    @{ Path = 'HKCU:\Control Panel\Desktop';         Name = 'HungAppTimeout';       Value = '2000'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'HungAppTimeout';       Value = '2000'; Type = 'String' }
    # wait-to-kill app timeout (2 s)
    @{ Path = 'HKCU:\Control Panel\Desktop';         Name = 'WaitToKillAppTimeout'; Value = '2000'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'WaitToKillAppTimeout'; Value = '2000'; Type = 'String' }
    # low-level hooks timeout (1 s)
    @{ Path = 'HKCU:\Control Panel\Desktop';         Name = 'LowLevelHooksTimeout'; Value = '1000'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Desktop'; Name = 'LowLevelHooksTimeout'; Value = '1000'; Type = 'String' }
    # audio ducking — do nothing on comms activity
    @{ Path = 'HKCU:\Software\Microsoft\Multimedia\Audio';         Name = 'UserDuckingPreference'; Value = 3 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Multimedia\Audio'; Name = 'UserDuckingPreference'; Value = 3 }
    # real-time clock = utc (dual-boot fix)
    @{ Path = 'HKLM:\System\CurrentControlSet\Control\TimeZoneInformation'; Name = 'RealTimeIsUniversal'; Value = 1 }
)

# ── 1.9  mouse
Write-Step 'control panel — mouse'
Apply-Tweaks @(
    # disable enhance pointer precision
    @{ Path = 'HKCU:\Control Panel\Mouse';         Name = 'MouseSpeed';      Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Mouse';         Name = 'MouseThreshold1'; Value = '0'; Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Mouse';         Name = 'MouseThreshold2'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Mouse'; Name = 'MouseSpeed';      Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Mouse'; Name = 'MouseThreshold1'; Value = '0'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Mouse'; Name = 'MouseThreshold2'; Value = '0'; Type = 'String' }
    # mousekeys sensitivity purge
    @{ Path = 'HKCU:\Control Panel\Accessibility\MouseKeys';         Name = 'MaximumSpeed';       Value = '-' }
    @{ Path = 'HKCU:\Control Panel\Accessibility\MouseKeys';         Name = 'TimeToMaximumSpeed'; Value = '-' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys'; Name = 'MaximumSpeed';       Value = '-' }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys'; Name = 'TimeToMaximumSpeed'; Value = '-' }
)

# ── 1.10  ease of access — purge & disable
Write-Step 'ease of access purge'
$AccHives = @(
    'AudioDescription','Blind Access','HighContrast','Keyboard Preference','Keyboard Response','MouseKeys','On','ShowSounds','SlateLaunch','SoundSentry','StickyKeys','TimeOut','ToggleKeys'
)
foreach ($h in $AccHives) {
    Set-Reg -Path "HKCU:\Control Panel\Accessibility\$h"         -Name 'Flags' -Value '0' -Type 'String'
    Set-Reg -Path "HKU:\.DEFAULT\Control Panel\Accessibility\$h" -Name 'Flags' -Value '0' -Type 'String'
}

# ── 1.11  typing & autocorrect
Write-Step 'typing & input'
$TypingKeys = @('EnableAutocorrection','EnableSpellchecking','EnableTextPrediction','EnablePredictionSpaceInsertion','EnableDoubleTapSpace')
foreach ($k in $TypingKeys) {
    Set-Reg -Path 'HKCU:\SOFTWARE\Microsoft\TabletTip\1.7' -Name $k -Value 0
    Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\TabletTip\1.7' -Name $k -Value 0
}
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Input\Settings'; Name = 'InsightsEnabled';          Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'; Name = 'InsightsEnabled';          Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Input\Settings'; Name = 'EnableHwkbTextPrediction'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'; Name = 'EnableHwkbTextPrediction'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Input\Settings'; Name = 'EnableHwkbAutocorrection'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'; Name = 'EnableHwkbAutocorrection'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Input\Settings'; Name = 'MultilingualEnabled';      Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\Settings'; Name = 'MultilingualEnabled';      Value = 0 }
    # inking & typing data collection
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\TextInput'; Name = 'AllowLinguisticDataCollection'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Input\TIPC'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Input\TIPC'; Name = 'Enabled'; Value = 0 }
    # input personalization
    @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization';                  Name = 'RestrictImplicitInkCollection';  Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization';                  Name = 'RestrictImplicitTextCollection'; Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts';                Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\InputPersonalization\Settings';         Name = 'AcceptedPrivacyPolicy';          Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\InputPersonalization';         Name = 'RestrictImplicitInkCollection';  Value = 1 }
    @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\InputPersonalization';         Name = 'RestrictImplicitTextCollection'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization';         Name = 'RestrictImplicitInkCollection';  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization';         Name = 'RestrictImplicitTextCollection'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization';         Name = 'AllowInputPersonalization';      Value = 0 }
)

# ── 1.12  context menu
Write-Step 'context menu'
# classic right-click context menu (windows 11)
Set-Reg -Path 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Name '' -Value '' -Type 'String'

# ── 1.13  explorer performance
Write-Step 'explorer performance'
Apply-Tweaks @(
    # disable automatic folder-type discovery
    @{ Path = 'HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell';         Name = 'FolderType'; Value = 'NotSpecified'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'; Name = 'FolderType'; Value = 'NotSpecified'; Type = 'String' }
    # force explorer to high-performance gpu
    @{ Path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences';         Name = 'C:\Windows\explorer.exe'; Value = 'GpuPreference=2;'; Type = 'String' }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\DirectX\UserGpuPreferences'; Name = 'C:\Windows\explorer.exe'; Value = 'GpuPreference=2;'; Type = 'String' }
    # disable onedrive account-based insights
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableGraphRecentItems'; Value = 1 }
    # hide spotlight icon on Desktop (24h2)
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'; Name = '{2cc5ca98-6485-489a-920e-b3e88a6ccce3}'; Value = 1 }
    # raise context menu selection threshold
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer';         Name = 'MultipleInvokePromptMinimum'; Value = 100 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'MultipleInvokePromptMinimum'; Value = 100 }
    # remove '- shortcut' text from new shortcuts
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';         Name = 'link'; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = 'Binary' }
    @{ Path = 'HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer'; Name = 'link'; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = 'Binary' }
    # always show copy-dialog details
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager';         Name = 'EnthusiastMode'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'; Name = 'EnthusiastMode'; Value = 1 }
    # disable autoplay
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers';         Name = 'DisableAutoplay'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'; Name = 'DisableAutoplay'; Value = 1 }
    # disable autorun on all drives
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun'; Value = 255 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun'; Value = 255 }
    # no low disk-space balloon
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'NoLowDiskSpaceChecks';     Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoLowDiskSpaceChecks';     Value = 1 }
    # do not track shell shortcuts during roaming
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'LinkResolveIgnoreLinkInfo'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'LinkResolveIgnoreLinkInfo'; Value = 1 }
    # do not use search when resolving shell shortcuts
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'NoResolveSearch'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoResolveSearch'; Value = 1 }
    # no online tips in explorer/settings
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'AllowOnlineTips'; Value = 0 }
    # service shutdown timeout (1.5 s)
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control'; Name = 'WaitToKillServiceTimeout'; Value = '1500'; Type = 'String' }
)

# downloads folder — disable group by
$DownloadsID = '{885a186e-a440-4ada-812b-db871b942259}'
Get-ChildItem -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes\$DownloadsID" -Recurse -EA 0 |
    ForEach-Object {
        if ((Get-ItemProperty $_.PSPath -EA 0).GroupBy) {
            Set-ItemProperty -Path $_.PSPath -Name GroupBy -Value '' -EA 0
        }
    }
$bagsPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
Get-ChildItem -Path $bagsPath -EA 0 | ForEach-Object {
    $fp = Join-Path $_.PSPath "Shell\$DownloadsID"
    if (Test-Path $fp) { Remove-Item -Path $fp -Recurse -EA 0 }
}

# ── 1.14  explorer view
Write-Step 'explorer view'
Apply-Tweaks @(
    # show full path in title bar
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState';         Name = 'FullPath';                    Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState'; Name = 'FullPath';                    Value = 1 }
    # show file extensions
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'HideFileExt';                 Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'HideFileExt';                 Value = 0 }
    # no onedrive sync-provider ads
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'ShowSyncProviderNotifications'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowSyncProviderNotifications'; Value = 0 }
)
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI' -Name 'AllowEdgeSwipe' -Value 0

# ── 1.15  taskbar
Write-Step 'taskbar'
Apply-Tweaks @(
    # no taskbar animations
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarAnimations'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; Value = 0 }
    # search icon only (no box)
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';         Name = 'SearchboxTaskbarMode'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'SearchboxTaskbarMode'; Value = 0 }
    # hide task view button
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'ShowTaskViewButton'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowTaskViewButton'; Value = 0 }
    # enable 'end task' in right-click
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings';         Name = 'TaskbarEndTask'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Name = 'TaskbarEndTask'; Value = 1 }
    # open file explorer to this pc
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'LaunchTo'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'LaunchTo'; Value = 1 }
    # hide pop-up tooltips
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'ShowInfoTip'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowInfoTip'; Value = 0 }
    # tablet mode — always desktop, no auto-hide
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell';         Name = 'SignInMode';                           Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell';         Name = 'TabletMode';                           Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell';         Name = 'ConvertibleSlateModePromptPreference'; Value = 2 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell'; Name = 'SignInMode';                           Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell'; Name = 'TabletMode';                           Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell'; Name = 'ConvertibleSlateModePromptPreference'; Value = 2 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarAppsVisibleInTabletMode';    Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAppsVisibleInTabletMode';    Value = 1 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarAutoHideInTabletMode';       Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAutoHideInTabletMode';       Value = 0 }
    # remove news & interests / widgets
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds';           Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh';                   Name = 'AllowNewsAndInterests'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds';         Name = 'ShellFeedsTaskbarViewMode'; Value = 2 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Feeds'; Name = 'ShellFeedsTaskbarViewMode'; Value = 2 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarDa'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarDa'; Value = 0 }
    # remove people bar
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer';         Name = 'HidePeopleBar'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer'; Name = 'HidePeopleBar'; Value = 1 }
    # remove meet now
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'HideSCAMeetNow'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'HideSCAMeetNow'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';         Name = 'HideSCAMeetNow'; Value = 1 }
    # disable chat (teams) icon
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat'; Name = 'ChatIcon'; Value = 3 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'TaskbarMn'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarMn'; Value = 0 }
    # windows ink workspace — on, no suggested apps
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace'; Name = 'AllowWindowsInkWorkspace';                Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace'; Name = 'AllowSuggestedAppsInWindowsInkWorkspace'; Value = 0 }
    # power — show sleep in shutdown menu
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'; Name = 'ShowSleepOption'; Value = 1 }
)

# ── 1.16  notifications & tray
Write-Step 'notifications & tray'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoToastApplicationNotification'; Value = 1 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'; Name = 'NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND';         Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'; Name = 'NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK';          Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'; Name = 'NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK'; Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'; Name = 'NOC_GLOBAL_SETTING_TOASTS_ENABLED';                   Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'ToastEnabled'; Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'ToastEnabled'; Value = 0 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'ToastEnabled'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener'; Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener'; Name = 'Value'; Value = 'Deny'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableNotificationCenter'; Value = 1 }
    @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'DisableNotificationCenter'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer';         Name = 'NoBalloonFeatureAdvertisements'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoBalloonFeatureAdvertisements'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer';         Name = 'NoAutoTrayNotify';               Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer'; Name = 'NoAutoTrayNotify';               Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications'; Name = 'NoCloudApplicationNotification'; Value = 1 }
    # oobe "let's finish setting up" nag
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement';         Name = 'ScoobeSystemSettingEnabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Name = 'ScoobeSystemSettingEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless';         Name = 'ScoobeCheckCompleted'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless'; Name = 'ScoobeCheckCompleted'; Value = 1 }
)

# ── 1.17  start menu
Write-Step 'start menu'
$Pins = '{"pinnedList":[{"packagedAppId":"Microsoft.WindowsStore_8wekyb3d8bbwe!App"},{"packagedAppId":"windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"},{"packagedAppId":"Microsoft.WindowsNotepad_8wekyb3d8bbwe!App"},{"packagedAppId":"Microsoft.Paint_8wekyb3d8bbwe!App"},{"desktopAppLink":"%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\File Explorer.lnk"},{"packagedAppId":"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"}]}'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'ConfigureStartPins'; Value = $Pins; Type = 'String' }
    # start recommendations
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'Start_IrisRecommendations';  Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_IrisRecommendations';  Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced';         Name = 'Start_AccountNotifications'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'Start_AccountNotifications'; Value = 0 }
    # start folder shortcuts — all hidden except settings
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDocuments';                  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDocuments_ProviderSet';      Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDownloads';                  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderDownloads_ProviderSet';      Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderFileExplorer';               Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderFileExplorer_ProviderSet';   Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderHomeGroup';                  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderHomeGroup_ProviderSet';      Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderMusic';                      Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderMusic_ProviderSet';          Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderNetwork';                    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderNetwork_ProviderSet';        Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPersonalFolder';             Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPersonalFolder_ProviderSet'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPictures';                   Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderPictures_ProviderSet';       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderSettings';                   Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderSettings_ProviderSet';       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderVideos';                     Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'; Name = 'AllowPinnedFolderVideos_ProviderSet';         Value = 0 }
)

# ── 1.18  search & indexing
Write-Step 'search & indexing'
Apply-Tweaks @(
    @{ Path = 'HKLM:\Software\Microsoft\Windows Search\Gather\Windows\SystemIndex'; Name = 'RespectPowerModes';                   Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';           Name = 'PreventIndexOnBattery';               Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer';                 Name = 'DisableSearchBoxSuggestions';         Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer'; Name = 'DisableSearchBoxSuggestions';                 Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'AllowCloudSearch';                            Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'AllowCortanaAboveLock';                       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'AllowCortana';                                Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'AllowCortanaInAAD';                           Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'AllowCortanaInAADPathOOBE';                   Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'AllowSearchToUseLocation';                    Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'ConnectedSearchUseWeb';                       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'ConnectedSearchUseWebOverMeteredConnections'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'DisableWebSearch';                            Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search';   Name = 'ConnectedSearchPrivacy';                      Value = 3 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';         Name = 'CortanaConsent';    Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'CortanaConsent';    Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';         Name = 'BingSearchEnabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BingSearchEnabled'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Speech_OneCore\Preferences'; Name = 'VoiceActivationEnableAboveLockscreen'; Value = 0 }
    # disable store results in search (25h2)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask'; Name = 'ActivationType'; Value = 4294967295 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask'; Name = 'Server';         Value = ''; Type = 'String' }
    # prevent webview2 from searchhost
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Policies\Microsoft\FeatureManagement\Overrides'; Name = '1694661260'; Value = 0 }
)

# ── 1.19  windows update
Write-Step 'windows update'

# pause windows updates for 16 years
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'FlightSettingsMaxPauseDays'   -Value 5269 -Type 'DWord'
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseFeatureUpdatesStartTime' -Value '2023-08-17T12:47:51Z' -Type 'String'
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseFeatureUpdatesEndTime'   -Value '2038-01-19T03:14:07Z' -Type 'String'
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseQualityUpdatesStartTime' -Value '2023-08-17T12:47:51Z' -Type 'String'
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseQualityUpdatesEndTime'   -Value '2038-01-19T03:14:07Z' -Type 'String'
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesStartTime'        -Value '2023-08-17T12:47:51Z' -Type 'String'
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name 'PauseUpdatesExpiryTime'       -Value '2038-01-19T03:14:07Z' -Type 'String'
Apply-Tweaks @(
    # drivers (windows update için)
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\DriverSearching'; Name = 'DontSearchWindowsUpdate';          Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\DriverSearching'; Name = 'DriverUpdateWizardWuSearchEnabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\DriverSearching'; Name = 'DontPromptForWindowsUpdate';       Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DriverSearching'; Name = 'DontPromptForWindowsUpdate';       Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DriverSearching'; Name = 'SearchOrderConfig';                Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate';   Name = 'ExcludeWUDriversInQualityUpdate';  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings';        Name = 'ExcludeWUDriversInQualityUpdate';  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata'; Name = 'PreventDeviceMetadataFromNetwork'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'; Name = 'PreventDeviceMetadataFromNetwork'; Value = 1 }
    # store — no silent os upgrade, no auto-update push
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsStore'; Name = 'AutoDownload';     Value = 4 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsStore'; Name = 'DisableOSUpgrade'; Value = 1 }
    # suppress upgrade-available notification
    @{ Path = 'HKLM:\SYSTEM\Setup\UpgradeNotification'; Name = 'UpgradeAvailable'; Value = 0 }
    # mrt infection reporting — off
    @{ Path = 'HKLM:\Software\Policies\Microsoft\MRT'; Name = 'DontReportInfectionInformation'; Value = 0 }
    # delivery optimisation — LAN only
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Value = 0 }
    # no insider / preview builds
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds'; Name = 'AllowBuildPreview'; Value = 0 }
    # no reserved storage
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager'; Name = 'ShippedWithReserves'; Value = 0 }
    # media player auto-update — off
    @{ Path = 'HKLM:\Software\Policies\Microsoft\WindowsMediaPlayer'; Name = 'DisableAutoUpdate'; Value = 0 }
    # block devhome / outlook silent installs
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate';  Name = 'workCompleted'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate';  Name = 'workCompleted'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe'; Name = 'BlockedOobeUpdaters'; Value = '["MS_Outlook"]'; Type = 'String' }
    # hide mct link & restart notifications
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'HideMCTLink';                  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'RestartNotificationsAllowed2'; Value = 0 }
    # hide insider page from WU settings
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\UI\Visibility'; Name = 'HideInsiderPage'; Value = 1 }
    # hide wu tray icon
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'TrayIconVisibility'; Value = 0 }
    # wu update notification — silent (level 2)
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'UpdateNotificationLevel'; Value = 2 }
)
# delete wu orchestrator oobe keys
$OrchestratorOobe = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe'
@('DevHomeUpdate','OutlookUpdate') | ForEach-Object {
    $kp = "$OrchestratorOobe\$_"
    if (Test-Path $kp) { Remove-Item -Path $kp -Recurse -Force -EA 0 }
}

# ── 1.20  multimedia & power
Write-Step 'multimedia & power'
Apply-Tweaks @(
    # networkthrottlingindex = 10 (default — keeps network stable)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; Name = 'NetworkThrottlingIndex'; Value = 10 }
    # offline maps — wifi-only, no auto-update
    @{ Path = 'HKLM:\SYSTEM\Maps'; Name = 'UpdateOnlyOnWifi';  Value = 1 }
    @{ Path = 'HKLM:\SYSTEM\Maps'; Name = 'AutoUpdateEnabled'; Value = 0 }
    # disable automatic maintenance & scheduled diagnostics
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'; Name = 'MaintenanceDisabled'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScheduledDiagnostics';          Name = 'EnabledExecution';    Value = 0 }
    # disable system restore auto-config (leaves user in control)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'; Name = 'RPSessionInterval'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\cfg'; Name = 'DiskPercent'; Value = 0 }
)

# ── 1.21  performance — ifeo & process priorities
Write-Step 'ifeo — process priorities'
$IfeoBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

# cpu / io priority adjustments for background processes
Apply-Tweaks @(
    @{ Path = "$IfeoBase\SearchIndexer.exe\PerfOptions"; Name = 'CpuPriorityClass'; Value = 5 } # below normal
    @{ Path = "$IfeoBase\ctfmon.exe\PerfOptions";        Name = 'CpuPriorityClass'; Value = 5 } # below normal
    @{ Path = "$IfeoBase\fontdrvhost.exe\PerfOptions";   Name = 'CpuPriorityClass'; Value = 1 } # idle
    @{ Path = "$IfeoBase\fontdrvhost.exe\PerfOptions";   Name = 'IoPriority';       Value = 0 } # idle
    @{ Path = "$IfeoBase\lsass.exe\PerfOptions";         Name = 'CpuPriorityClass'; Value = 1 } # idle
    @{ Path = "$IfeoBase\sihost.exe\PerfOptions";        Name = 'CpuPriorityClass'; Value = 1 } # idle
    @{ Path = "$IfeoBase\sihost.exe\PerfOptions";        Name = 'IoPriority';       Value = 0 } # idle
)

# disable rsop logging (group policy) — reduces boot overhead
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'RSoPLogging' -Value 0

# disable office background logging
Apply-Tweaks @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\ClickToRun\OverRide';              Name = 'DisableLogManagement'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration';  Name = 'TimerInterval';        Value = '900000'; Type = 'String' }
)


# ── 1.22  security
Write-Step 'security'
Apply-Tweaks @(
    # disable uac
    $p = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    @{ Path = $p; Name = 'EnableVirtualization';        Value = 0 }
    @{ Path = $p; Name = 'EnableInstallerDetection';    Value = 0 }
    @{ Path = $p; Name = 'PromptOnSecureDesktop';       Value = 0 }
    @{ Path = $p; Name = 'EnableLUA';                   Value = 0 }
    @{ Path = $p; Name = 'EnableSecureUIAPaths';        Value = 0 }
    @{ Path = $p; Name = 'ConsentPromptBehaviorAdmin';  Value = 0 }
    @{ Path = $p; Name = 'ValidateAdminCodeSignatures'; Value = 0 }
    @{ Path = $p; Name = 'EnableUIADesktopToggle';      Value = 0 }
    @{ Path = $p; Name = 'ConsentPromptBehaviorUser';   Value = 0 }
    @{ Path = $p; Name = 'FilterAdministratorToken';    Value = 0 }
    # hide account protection nag in defender
    @{ Path = 'HKCU:\Software\Microsoft\Windows Security Health\State';         Name = 'AccountProtection_MicrosoftAccount_Disconnected'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows Security Health\State'; Name = 'AccountProtection_MicrosoftAccount_Disconnected'; Value = 0 }
    # disable defender generic reports (watson)
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows Defender\Reporting'; Name = 'DisableGenericRePorts'; Value = 1 }
    # no signature updates on battery
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows Defender\Signature Updates'; Name = 'DisableScheduledSignatureUpdateOnBattery'; Value = 1 }
    # smartscreen — app install control → anywhere
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows Defender\SmartScreen'; Name = 'ConfigureAppInstallControlEnabled'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows Defender\SmartScreen'; Name = 'ConfigureAppInstallControl';        Value = 'Anywhere'; Type = 'String' }
    # disable web-content evaluation (apphost)
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost'; Name = 'EnableWebContentEvaluation'; Value = 0 }
    # disable smartscreen in edge (legacy)
    @{ Path = 'HKLM:\Software\Policies\Microsoft\MicrosoftEdge\PhishingFilter'; Name = 'EnabledV9'; Value = 0 }
    # hide windows security systray icon
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray'; Name = 'HideSystray'; Value = 1 }
    # remove securityhealth from startup
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Name = 'SecurityHealth'; Value = '-' }
    # fix vs not being allowed to install webview2 (aveyo)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'InstallDefault';                                Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'; Name = 'DoNotUpdateToEdgeWithChromium';                 Value = 1 }
    # enable sudo — inline mode
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sudo'; Name = 'Enabled'; Value = 3 }
)

# disable vbs & memory integrity
write-step 'disable vbs & memory integrity'
bcdedit /set nx AlwaysOff | Out-Null
bcdedit /set hypervisorlaunchtype off | Out-Null
bcdedit /set vsmlaunchtype off | Out-Null
Apply-Tweaks @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'; Name = 'EnableVirtualizationBasedSecurity'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'; Name = 'LsaCfgFlags';                       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard'; Name = 'HVCIMATRequired';                   Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\DeviceGuard';        Name = 'EnableVirtualizationBasedSecurity'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\DeviceGuard';        Name = 'Mandatory';                         Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\DeviceGuard';        Name = 'HVCIMATRequired';                   Value = 0 }
)
$hvci = 'HKLM:\SYSTEM\ControlSet001\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
Set-Reg -Path $hvci -Name 'Enabled' -Value 0
@('WasEnabledBy','ChangedInBootCycle') | ForEach-Object { Remove-ItemProperty -Path $hvci -Name $_ -ErrorAction SilentlyContinue | Out-Null }

# ── 1.23  privacy & telemetry
Write-Step 'telemetry & data collection'
Apply-Tweaks @(
    @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';                            Name = 'AllowTelemetry';   Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';                            Name = 'AllowTelemetry';   Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection';             Name = 'AllowTelemetry';   Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Policies\DataCollection'; Name = 'AllowTelemetry';   Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\System\AllowTelemetry';                Name = 'value';            Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\DevicePolicy\AllowTelemetry';    Name = 'DefaultValue';     Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\AllowTelemetry';           Name = 'Value';            Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowCommercialDataPipeline';                 Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowDeviceNameInTelemetry';                  Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'DisableEnterpriseAuthProxy';                  Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'MicrosoftEdgeDataOptIn';                      Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'DisableTelemetryOptInChangeNotification';     Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'DisableTelemetryOptInSettingsUx';             Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'DoNotShowFeedbackNotifications';              Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'LimitEnhancedDiagnosticDataWindowsAnalytics'; Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowBuildPreview';                           Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'LimitDiagnosticLogCollection';                Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\DataCollection'; Name = 'LimitDumpCollection';                         Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\PreviewBuilds';  Name = 'EnableConfigFlighting';                       Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System'; Name = 'AllowExperimentation'; Value = 0 }
    # wmi autologger — disable telemetry loggers
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener'; Name = 'Start'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SQMLogger';          Name = 'Start'; Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SetupPlatformTel';   Name = 'Start'; Value = 0 }
    # tailored experiences
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy';         Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\DevicePolicy\TailoredExperiencesWithDiagnosticDataEnabled'; Name = 'DefaultValue'; Value = 0 }
    # diagnostic event transcript
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack\EventTranscriptKey'; Name = 'EnableEventTranscript'; Value = 0 }
    # feedback frequency — never
    @{ Path = 'HKCU:\Software\Microsoft\Siuf\Rules';         Name = 'NumberOfSIUFInPeriod'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Siuf\Rules';         Name = 'PeriodInNanoSeconds';  Value = '-' }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Siuf\Rules'; Name = 'NumberOfSIUFInPeriod'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Siuf\Rules'; Name = 'PeriodInNanoSeconds';  Value = '-' }
    # activity history
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'UploadUserActivities';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'PublishUserActivities'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'EnableActivityFeed';    Value = 0 }
    # online speech recognition
    @{ Path = 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy';         Name = 'HasAccepted'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; Name = 'HasAccepted'; Value = 0 }
    # advertising id
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Id';      Value = '-' }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Id';      Value = '-' }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AdvertisingInfo';       Name = 'DisabledByGroupPolicy'; Value = 1 }
    # language list — no website local-content access
    @{ Path = 'HKCU:\Control Panel\International\User Profile';         Name = 'HttpAcceptLanguageOptOut'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Control Panel\International\User Profile'; Name = 'HttpAcceptLanguageOptOut'; Value = 1 }
    # clipboard history off (keep clipboard functional)
    @{ Path = 'HKCU:\Software\Microsoft\Clipboard';         Name = 'EnableClipboardHistory'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Clipboard'; Name = 'EnableClipboardHistory'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'AllowClipboardHistory';     Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'AllowCrossDeviceClipboard'; Value = 1 }
    # game dvr
    @{ Path = 'HKCU:\System\GameConfigStore';         Name = 'GameDVR_Enabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 }
    # settings sync — all off
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableApplicationSettingSync';                 Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableApplicationSettingSyncUserOverride';     Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSync';                            Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSettingSyncUserOverride';                Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableWebBrowserSettingSync';                  Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableWebBrowserSettingSyncUserOverride';      Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableDesktopThemeSettingSync';                Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableDesktopThemeSettingSyncUserOverride';    Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableSyncOnPaidNetwork';                      Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableWindowsSettingSync';                     Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableWindowsSettingSyncUserOverride';         Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableCredentialsSettingSync';                 Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableCredentialsSettingSyncUserOverride';     Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisablePersonalizationSettingSync';             Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisablePersonalizationSettingSyncUserOverride'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableStartLayoutSettingSync';                 Value = 2 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync'; Name = 'DisableStartLayoutSettingSyncUserOverride';     Value = 1 }
    # disable recall / ai snapshots (24h2)
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 }
    # gaming copilot dll (xbox)
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions'; Name = 'ActivationType'; Value = 4294967295 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions'; Name = 'Server';         Value = ''; Type = 'String' }
    # disable valuebanners in settings
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\ValueBanner.IdealStateFeatureControlProvider'; Name = 'ActivationType'; Value = 4294967295 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\ValueBanner.IdealStateFeatureControlProvider'; Name = 'Server';         Value = ''; Type = 'String' }
    # wi-fi sense — all off
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config';   Name = 'AutoConnectAllowedOEM'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features'; Name = 'PaidWifi';              Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features'; Name = 'WiFiSenseOpen';         Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting';           Name = 'value'; Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots'; Name = 'value'; Value = 0 }
    # timeline suggestions
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';         Name = 'SubscribedContent-353698Enabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353698Enabled'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';         Name = 'SystemPaneSuggestionsEnabled';    Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled';    Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager';         Name = 'SubscribedContent-338388Enabled'; Value = 0 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Value = 0 }
    # settings account notifications
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications';         Name = 'EnableAccountNotifications'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications'; Name = 'EnableAccountNotifications'; Value = 1 }
)

# ── 1.24  app permissions
Write-Step 'app permissions'
$Cap = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$CapLM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$CapDef = 'HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
@(
    @{ s = 'location';               cu = 'Deny';  lm = $null;    du = 'Deny'  }
    @{ s = 'webcam';                 cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'microphone';             cu = 'Allow'; lm = 'Allow';  du = $null   }
    @{ s = 'activity';               cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'userAccountInformation'; cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'appointments';           cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'userDataTasks';          cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'chat';                   cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'radios';                 cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'bluetoothSync';          cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'appDiagnostics';         cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'documentsLibrary';       cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'picturesLibrary';        cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'videosLibrary';          cu = 'Deny';  lm = 'Deny';   du = $null   }
    @{ s = 'broadFileSystemAccess';  cu = 'Deny';  lm = 'Deny';   du = $null   }
) | ForEach-Object {
    Set-Reg -Path "$Cap\$($_.s)"    -Name 'Value' -Value $_.cu -Type 'String'
    Set-Reg -Path "$CapDef\$($_.s)" -Name 'Value' -Value $_.cu -Type 'String'
    if ($_.lm) { Set-Reg -Path "$CapLM\$($_.s)" -Name 'Value' -Value $_.lm -Type 'String' }
}

# ── 1.25  ceip
Write-Step 'ceip'
Apply-Tweaks @(
    @{ Path = 'HKLM:\Software\Policies\Microsoft\SQMClient\Windows';                           Name = 'CEIPEnable';                        Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\AppV\CEIP';                                   Name = 'CEIPEnable';                        Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Internet Explorer\SQM';                       Name = 'DisableCustomerImprovementProgram'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Messenger\Client';                            Name = 'CEIP';                              Value = 2 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\UnattendSettings\SQMClient'; Name = 'CEIPEnabled';                       Value = 0 }
)

# ── 1.26  app compatibility
Write-Step 'app compatibility'
Apply-Tweaks @(
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisableEngine';    Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'AITEnable';        Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisableUAR';       Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisablePCA';       Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'DisableInventory'; Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppCompat'; Name = 'SbEnable';         Value = 1 }
)

# ── 1.27  cloud content & spotlight
Write-Step 'cloud content & spotlight'
Apply-Tweaks @(
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableSoftLanding'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableTailoredExperiencesWithDiagnosticData'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableCloudOptimizedContent';                 Value = 1 }
)
$CloudUserPaths = @('HKCU:\Software\Policies\Microsoft\Windows\CloudContent','HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent')
$CloudUserTweaks = @{
    ConfigureWindowsSpotlight                       = 2
    IncludeEnterpriseSpotlight                      = 0
    DisableThirdPartySuggestions                    = 1
    DisableTailoredExperiencesWithDiagnosticData    = 1
    DisableWindowsSpotlightFeatures                 = 1
    DisableWindowsSpotlightWindowsWelcomeExperience = 1
    DisableWindowsSpotlightOnActionCenter           = 1
    DisableWindowsSpotlightOnSettings               = 1
}
foreach ($p in $CloudUserPaths) { Set-Tweaks -Path $p -Settings $CloudUserTweaks }

# ── 1.28  content delivery manager (cdm)
Write-Step 'content delivery manager'
$CdmBase = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$CdmDef  = 'HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$CdmOff  = @{
    ContentDeliveryAllowed            = 0; SubscribedContentEnabled          = 0
    'SubscribedContent-310093Enabled' = 0; SoftLandingEnabled                = 0
    'SubscribedContent-338389Enabled' = 0; SilentInstalledAppsEnabled        = 0
    PreInstalledAppsEnabled           = 0; PreInstalledAppsEverEnabled       = 0
    OemPreInstalledAppsEnabled        = 0; FeatureManagementEnabled          = 0
    RemediationRequired               = 0; 'SubscribedContent-314559Enabled' = 0
    'SubscribedContent-280815Enabled' = 0; 'SubscribedContent-314563Enabled' = 0
    'SubscribedContent-202914Enabled' = 0; 'SubscribedContent-338387Enabled' = 0
    'SubscribedContent-280810Enabled' = 0; 'SubscribedContent-280811Enabled' = 0
    RotatingLockScreenEnabled         = 0; RotatingLockScreenOverlayEnabled  = 0
}
Set-Tweaks -Path $CdmBase -Settings $CdmOff
Set-Tweaks -Path $CdmDef  -Settings $CdmOff
@(
    "$CdmBase\Subscriptions"; "$CdmDef\Subscriptions"
    "$CdmBase\SuggestedApps"; "$CdmDef\SuggestedApps"
) | ForEach-Object { if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -EA 0 } }

# ── 1.29  internet communication restrictions
Write-Step 'internet communication restrictions'
Apply-Tweaks @(
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\Messaging'; Name = 'AllowMessageSync'; Value = 0 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\EdgeUI';         Name = 'DisableHelpSticker'; Value = 1 }
    @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\EdgeUI';         Name = 'DisableMFUTracking'; Value = 1 }
    @{ Path = 'HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\EdgeUI'; Name = 'DisableMFUTracking'; Value = 1 }
)
$IcmHKCU = @{
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' = @{
        NoPublishingWizard = 1; NoWebServices = 1; NoOnlinePrintsWizard = 1; NoInternetOpenWith = 1
    }
    'HKCU:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform' = @{ NoGenTicket = 1 }
    'HKCU:\Software\Policies\Microsoft\Windows NT\Printers' = @{ DisableHTTPPrinting = 1; DisableWebPnPDownload = 1 }
    'HKCU:\Software\Policies\Microsoft\Windows\HandwritingErrorReports' = @{ PreventHandwritingErrorReports = 1 }
    'HKCU:\Software\Policies\Microsoft\Windows\TabletPC' = @{ PreventHandwritingDataSharing = 1 }
    'HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0' = @{ NoOnlineAssist = 1; NoExplicitFeedback = 1; NoImplicitFeedback = 1 }
    'HKCU:\Software\Policies\Microsoft\WindowsMovieMaker' = @{ WebHelp = 1; CodecDownload = 1; WebPublish = 1 }
}
$IcmHKLM = @{
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' = @{
        NoPublishingWizard = 1; NoWebServices = 1; NoOnlinePrintsWizard = 1; NoInternetOpenWith = 1
    }
    'HKLM:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform' = @{ NoGenTicket = 1 }
    'HKLM:\Software\Policies\Microsoft\PCHealth\HelpSvc' = @{ Headlines = 0; MicrosoftKBSearch = 0 }
    'HKLM:\Software\Policies\Microsoft\PCHealth\ErrorReporting' = @{ DoReport = 0 }
    'HKLM:\Software\Policies\Microsoft\Windows\Windows Error Reporting' = @{ Disabled = 1 }
    'HKLM:\Software\Policies\Microsoft\Windows\Internet Connection Wizard' = @{ ExitOnMSICW = 1 }
    'HKLM:\Software\Policies\Microsoft\EventViewer' = @{ MicrosoftEventVwrDisableLinks = 1 }
    'HKLM:\Software\Policies\Microsoft\Windows\Registration Wizard Control' = @{ NoRegistration = 1 }
    'HKLM:\Software\Policies\Microsoft\SearchCompanion' = @{ DisableContentFileUpdates = 1 }
    'HKLM:\Software\Policies\Microsoft\Windows NT\Printers' = @{ DisableHTTPPrinting = 1; DisableWebPnPDownload = 1 }
    'HKLM:\Software\Policies\Microsoft\Windows\HandwritingErrorReports' = @{ PreventHandwritingErrorReports = 1 }
    'HKLM:\Software\Policies\Microsoft\Windows\TabletPC' = @{ PreventHandwritingDataSharing = 1 }
    'HKLM:\Software\Policies\Microsoft\WindowsMovieMaker' = @{ WebHelp = 1; CodecDownload = 1; WebPublish = 1 }
}
foreach ($path in $IcmHKCU.Keys) { Set-Tweaks -Path $path -Settings $IcmHKCU[$path] }
foreach ($path in $IcmHKLM.Keys) { Set-Tweaks -Path $path -Settings $IcmHKLM[$path] }

# ── 1.30  windows error reporting (wer)
Write-Step 'windows error reporting'
$WerPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting'
$WerData   = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
Apply-Tweaks @(
    @{ Path = $WerPolicy; Name = 'AutoApproveOSDumps';     Value = 0 }
    @{ Path = $WerPolicy; Name = 'LoggingDisabled';        Value = 1 }
    @{ Path = $WerPolicy; Name = 'Disabled';               Value = 1 }
    @{ Path = $WerPolicy; Name = 'DontSendAdditionalData'; Value = 1 }
    @{ Path = $WerPolicy; Name = 'DontShowUI';             Value = 1 }
    @{ Path = $WerData;   Name = 'Disabled';               Value = 1 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent'; Name = 'DefaultConsent';          Value = 0 }
    @{ Path = 'HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent'; Name = 'DefaultOverrideBehavior'; Value = 1 }
    @{ Path = "$WerPolicy\Consent"; Name = '0'; Value = ''; Type = 'String' }
)

# ── 1.31  firewall — telemetry & error reporting block
Write-Step 'firewall rules — telemetry block'
$FwDefaults  = 'HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules'
$FwParams    = 'HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
Apply-Tweaks @(
    @{ Path = $FwDefaults; Name = 'Block-Unified-Telemetry-Client'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|'
       Type = 'String' }
    @{ Path = $FwDefaults; Name = 'Block-Windows-Error-Reporting'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Error-Reporting|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|'
       Type = 'String' }
    @{ Path = $FwParams;   Name = 'Block-Unified-Telemetry-Client'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|'
       Type = 'String' }
    @{ Path = $FwParams;   Name = 'Block-Windows-Error-Reporting'
       Value = 'v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Telemetry-Client|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|'
       Type = 'String' }
)

# ── 1.32 fullscreen optimization (disable)
Write-Step 'fullscreen optimization (disable)'
Apply-Tweaks @(
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode';               Value = 2 }
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_HonorUserFSEBehaviorMode';      Value = 1 }
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_DXGIHonorFSEWindowsCompatible'; Value = 1 }
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_EFSEFeatureFlags';              Value = 0 }
    @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_FSEBehavior';                   Value = 2 }
)

# ── 1.33 windowed optimization (disable)
Write-Step 'windowed optimization (disable)'
$p = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$n = 'DirectXUserGlobalSettings'
$cur = (Get-ItemProperty -Path $p -Name $n -EA 0).$n
if ([string]::IsNullOrEmpty($cur)) { $new = 'SwapEffectUpgradeEnable=0;' }
else { $new = 'SwapEffectUpgradeEnable=0;' + ($cur -replace 'SwapEffectUpgradeEnable=1;?','') }
Set-Reg -Path $p -Name $n -Value $new -Type 'String'

# ── 1.34 overlaytestmode (disable)
Write-Step 'overlaytestmode (disable)'
Set-Reg -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name 'OverlayTestMode' -Value 5

# ── 1.35  prefetch optimization (ssd)
Write-Step 'prefetch optimization (ssd)'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters'; Name = 'EnablePrefetcher';  Value = 0 }
    @{ Path = 'HKLM:\SYSTEM\ControlSet001\Control\Session Manager\Memory Management\PrefetchParameters'; Name = 'EnableSuperfetch';  Value = 0 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\EMDMgmt'; Name = 'GroupPolicyDisallowCaches';  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\EMDMgmt'; Name = 'AllowNewCachesByDefault';    Value = 0 }
)

# ── 1.36 background app toggle (disable)
Write-Step 'background app toggle (disable)'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search';                       Name = 'BackgroundAppGlobalToggle'; Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; Name = 'GlobalUserDisabled';    Value = 1 }
    @{ Path = 'HKLM:\Software\Policies\Microsoft\Windows\AppPrivacy';                         Name = 'LetAppsRunInBackground'; Value = 2 }
)

# ── 1.37 background window message rate limit
Write-Step 'background window message rate limit'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'RawMouseThrottleEnabled';  Value = 1 }
    @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'RawMouseThrottleDuration'; Value = 20 }
)

# ── 1.38 branding & oem
Write-Step 'branding & oem'
Apply-Tweaks @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; Name = 'EditionSubManufacturer'; Value = 'Albus';     Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; Name = 'EditionSubstring';       Value = 'Albus';     Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; Name = 'EditionSubVersion';      Value = 'Albus 6.2'; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'HelpCustomized';  Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'Manufacturer';    Value = 'Albus';                                    Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'SupportProvider'; Value = 'Albus Support';                            Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'SupportAppURL';   Value = 'albus-support-help';                       Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation'; Name = 'SupportURL';      Value = 'https://www.github.com/oqullcan/albuswin'; Type = 'String' }
)

Write-Step 'registry tweaks complete' 'ok'
Write-Done 'registry tweaks'

# ════════════════════════════════════════════════════════════
#  PHASE 13 · UI: TRUE BLACK WALLPAPER & SHELL REFRESH
# ════════════════════════════════════════════════════════════

Write-Phase 'ui'

# black wallpaper & lock screen
Write-Step 'generating true black wallpaper'
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

Write-Step 'applying true black theme'
Apply-Tweaks @(
    @{ Path = 'HKCU:\Control Panel\Colors';                                          Name = 'Background';               Value = '0 0 0';    Type = 'String' }
    @{ Path = 'HKCU:\Control Panel\Desktop';                                         Name = 'WallPaper';                Value = '';         Type = 'String' }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'; Name = 'BackgroundType';           Value = 1 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize';  Name = 'AppsUseLightTheme';        Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize';  Name = 'SystemUsesLightTheme';     Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize';  Name = 'EnableTransparency';       Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize';  Name = 'ColorPrevalence';          Value = 1 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent';     Name = 'AccentColorMenu';          Value = 0 }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent';     Name = 'StartColorMenu';           Value = 0 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM';                                Name = 'AccentColor';              Value = -15132391 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM';                                Name = 'ColorizationAfterglow';    Value = -1004988135 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM';                                Name = 'ColorizationColor';        Value = -1004988135 }
    @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM';                                Name = 'EnableWindowColorization'; Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP';  Name = 'LockScreenImagePath';      Value = $BlackFile; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP';  Name = 'LockScreenImageStatus';    Value = 1 }
)
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent' 'AccentPalette' ([byte[]](
    0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00,
    0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00, 0x00,0x00,0x00,0x00
)) 'Binary'

# blackout account pictures
Write-Step 'blacking out account pictures'
@(
    "$env:ProgramData\Microsoft\User Account Pictures"
    "$env:AppData\Microsoft\Windows\AccountPictures"
) | ForEach-Object {
    if (-not (Test-Path $_)) { return }
    Get-ChildItem $_ -Include *.png,*.bmp,*.jpg -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $img = [System.Drawing.Bitmap]::FromFile($_.FullName)
            $w = $img.Width; $h = $img.Height; $img.Dispose()
            $new = New-Object System.Drawing.Bitmap $w, $h
            $g   = [System.Drawing.Graphics]::FromImage($new)
            $g.Clear([System.Drawing.Color]::Black); $g.Dispose()
            $fmt = switch ($_.Extension.ToLower()) {
                '.png' { [System.Drawing.Imaging.ImageFormat]::Png }
                '.bmp' { [System.Drawing.Imaging.ImageFormat]::Bmp }
                default { [System.Drawing.Imaging.ImageFormat]::Jpeg }
            }
            $new.Save($_.FullName, $fmt); $new.Dispose()
        } catch {}
    }
}

# context menu cleanup
Write-Step 'cleaning context menu'
@(
    '-HKCR:\Folder\shell\pintohome'
    '-HKCR:\*\shell\pintohomefile'
    '-HKCR:\exefile\shellex\ContextMenuHandlers\Compatibility'
    '-HKCR:\Folder\ShellEx\ContextMenuHandlers\Library Location'
    '-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing'
    '-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo'
    '-HKCR:\UserLibraryFolder\shellex\ContextMenuHandlers\SendTo'
) | ForEach-Object { Set-Reg -Path $_ -Name '' -Value '' }

Apply-Tweaks @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';        Name = 'NoCustomizeThisFolder';                Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer';                 Name = 'NoPreviousVersionsPage';               Value = 1 }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{9F156763-7844-4DC4-B2B1-901F640F5155}'; Value = ''; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{09A47860-11B0-4DA5-AFA5-26D86198A780}'; Value = ''; Type = 'String' }
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}'; Value = ''; Type = 'String' }
)

# start menu
Write-Step 'configuring start menu'
$start2 = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin"
Remove-Item $start2 -Force -ErrorAction SilentlyContinue
[System.IO.File]::WriteAllBytes($start2, [Convert]::FromBase64String("AgAAABAAAAD9////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="))
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Start' 'AllAppsViewMode' 2

# taskbar unpin
Write-Step 'unpinning taskbar items'
Set-Reg '-HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' '' ''
Remove-Item "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch" -Recurse -Force -ErrorAction SilentlyContinue

# tray icons — promote all
Write-Step 'promoting all tray icons'
Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 1 -Force -ErrorAction SilentlyContinue }

# accessibility folders — hide
Write-Step 'hiding accessibility folders'
@(
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Accessibility"
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessibility"
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories"
) | ForEach-Object {
    if (Test-Path $_) { attrib +h "$_" /s /d *>$null }
}

# shell refresh
Write-Step 'refreshing shell'
rundll32.exe user32.dll, UpdatePerUserSystemParameters
Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue

Write-Step 'ui applied' 'ok'
Write-Done 'ui'

# ════════════════════════════════════════════════════════════
#  PHASE 4 · SERVICES
# ════════════════════════════════════════════════════════════
Write-Phase 'services'

# rdyboost → lowerfilters
Write-Step 'removing rdyboost from lowerfilters'
$lfPath = 'HKLM:\SYSTEM\ControlSet001\Control\Class\{71a27cdd-812a-11d0-bec7-08002be2092f}'
$lf = (Get-ItemProperty -Path $lfPath -ErrorAction SilentlyContinue).LowerFilters
if ($lf -contains 'rdyboost') {
    $lf = $lf | Where-Object { $_ -ne 'rdyboost' }
    Set-ItemProperty -Path $lfPath -Name 'LowerFilters' -Value $lf
}

# ── svchost split threshold (disable split host) ──────────────
Write-Step 'svchost split threshold (disable split host)'
Set-Reg -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -Value 0xffffffff -Type DWord -Force

$config = @(
    # telemetry & diagnostics
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
    # bloat
    @{ Name = 'WpnUserService';                           Start = 4 }
    @{ Name = 'RetailDemo';                               Start = 4 }
    @{ Name = 'MapsBroker';                               Start = 4 }
    @{ Name = 'wisvc';                                    Start = 4 }
    @{ Name = 'UCPD';                                     Start = 4 }
    @{ Name = 'GraphicsPerfSvc';                          Start = 4 }
    @{ Name = 'Ndu';                                      Start = 4 }
    @{ Name = 'DSSvc';                                    Start = 4 }
    @{ Name = 'WSAIFabricSvc';                            Start = 4 }
    # print
    @{ Name = 'Spooler';                                  Start = 4 }
    @{ Name = 'PrintNotify';                              Start = 4 }
    # remote desktop
    @{ Name = 'TermService';                              Start = 4 }
    @{ Name = 'UmRdpService';                             Start = 4 }
    @{ Name = 'SessionEnv';                               Start = 4 }
    # sync
    @{ Name = 'OneSyncSvc';                               Start = 4 }
    @{ Name = 'CDPUserSvc';                               Start = 4 }
    @{ Name = 'TrkWks';                                   Start = 4 }
    # superfluous
    @{ Name = 'RdyBoost';                                 Start = 4 }
    @{ Name = 'SysMain';                                  Start = 4 }
    @{ Name = 'dam';                                      Start = 4 }
    # condrv needs auto
    @{ Name = 'condrv';                                   Start = 2 }
)

$groups = @{
    'telemetry & diagnostics' = @('DiagTrack','dmwappushservice','diagnosticshub.standardcollector.service','WerSvc','wercplsupport','DPS','WdiServiceHost','WdiSystemHost','troubleshootingsvc','diagsvc','PcaSvc','InventorySvc')
    'bloat'                   = @('WpnUserService','RetailDemo','MapsBroker','wisvc','UCPD','GraphicsPerfSvc','Ndu','DSSvc','WSAIFabricSvc')
    'print'                   = @('Spooler','PrintNotify')
    'remote desktop'          = @('TermService','UmRdpService','SessionEnv')
    'sync'                    = @('OneSyncSvc','CDPUserSvc','TrkWks')
    'superfluous'             = @('RdyBoost','SysMain','dam')
}

foreach ($group in $groups.Keys) {
    Write-Step "disabling $group services"
}

foreach ($svc in $config) {
    $Pattern = "^$($svc.Name)(_[a-fA-F0-9]{4,8})?$"
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match $Pattern } |
        ForEach-Object {
            $matchedName = $_.PSChildName
            if ($svc.Start -eq 4) {
                sc.exe stop $matchedName | Out-Null
            }
            $startType = switch ($svc.Start) { 2 { 'auto' } 3 { 'demand' } 4 { 'disabled' } }
            sc.exe config $matchedName start= $startType | Out-Null
            Set-Reg $_.PSPath 'Start' $svc.Start
        }
}

Write-Step 'disabling svchost splitting'
Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\*' -Name 'ImagePath' -ErrorAction SilentlyContinue |
    Where-Object { $_.ImagePath -match 'svchost\.exe' } |
    ForEach-Object {
        Set-Reg $_.PSPath 'SvcHostSplitDisable' 1
    }

Write-Step 'services configured' 'ok'
Write-Done 'services'

# ════════════════════════════════════════════════════════════
#  PHASE 5 · SCHEDULED TASKS
# ════════════════════════════════════════════════════════════

Write-Phase 'scheduled tasks'

$paths = @(
    '\Microsoft\Windows\Application Experience\'
    '\Microsoft\Windows\AppxDeploymentClient\'
    '\Microsoft\Windows\Autochk\'
    '\Microsoft\Windows\Customer Experience Improvement Program\'
    '\Microsoft\Windows\DiskDiagnostic\'
    '\Microsoft\Windows\Flighting\'
    '\Microsoft\Windows\Defrag\'
    '\Microsoft\Windows\Power Efficiency Diagnostics\'
    '\Microsoft\Windows\Feedback\'
    '\Microsoft\Windows\Maintenance\'
    '\Microsoft\Windows\Maps\'
    '\Microsoft\Windows\SettingSync\'
    '\Microsoft\Windows\CloudExperienceHost\'
    '\Microsoft\Windows\DiskFootprint\'
    '\Microsoft\Windows\WindowsAI\'
    '\Microsoft\Windows\WDI\'
    '\Microsoft\Windows\PI\'
)

foreach ($path in $paths) {
    $label = $path.Trim('\').Split('\')[-1].ToLower()
    Write-Step "disabling $label"
    Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue |
        Where-Object { $_.State -ne 'Disabled' } |
        Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
}

Write-Step 'scheduled tasks disabled' 'ok'
Write-Done 'scheduled tasks'

# ════════════════════════════════════════════════════════════
#  PHASE 6 · NETWORK STACK
# ════════════════════════════════════════════════════════════

Write-Phase 'network configuration'

Write-Step 'configuring tcp/ip stack'
$tcp = @(
    'autotuninglevel=restricted',
    'ecncapability=disabled',
    'timestamps=disabled',
    'initialRto=2000',
    'rss=enabled',
    'rsc=disabled',
    'nonsackrttresiliency=disabled'
)
foreach ($cmd in $tcp) { netsh int tcp set global $cmd | Out-Null }

netsh int tcp set supplemental template=internet congestionprovider=cubic | Out-Null

Write-Step 'tuning network quality of service'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\QoS' 'Do not use NLA' '1' 'String'
Remove-NetQosPolicy -Name 'Albus_*' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$games = @(
    'cs2.exe',
    'r5apex.exe'
)
foreach ($Game in $games) {
    $Name = "albus_QoS_$($Game.Replace('.exe', ''))"
    New-NetQosPolicy -Name $Name -AppPathNameMatchCondition $Game -DSCPAction 46 -NetworkProfile All -ErrorAction SilentlyContinue | Out-Null
}

Write-Step 'optimizing network interface settings'
$ActiveNICs = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
if ($ActiveNICs) {
    $ActiveNICs | Disable-NetAdapterLso -IPv4 -ErrorAction SilentlyContinue | Out-Null
    $ActiveNICs | Set-NetAdapterAdvancedProperty -DisplayName 'Interrupt Moderation' -DisplayValue 'Disabled' -ErrorAction SilentlyContinue | Out-Null

    $Bloat = @('ms_lldp', 'ms_lltdio', 'ms_implat', 'ms_rspndr', 'ms_tcpip6', 'ms_server', 'ms_msclient')
    foreach ($B in $Bloat) { $ActiveNICs | Disable-NetAdapterBinding -ComponentID $B -ErrorAction SilentlyContinue | Out-Null }

    $TcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    Set-Reg $TcpParams 'DisableNetbiosOverTcpip' 1
    Set-Reg "$TcpParams\Dnscache" 'EnableLLMNR' 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' 'DisableCoalescing' 1

    foreach ($NIC in $ActiveNICs) {
        $TargetKey = "$TcpParams\Interfaces\$($NIC.InterfaceGuid)"
        Set-Reg $TargetKey 'TcpAckFrequency' 1
        Set-Reg $TargetKey 'TCPNoDelay'      1
    }
}

Write-Step 'applying network card optimizations'
foreach ($NIC in $ActiveNICs) {
    $SafeID  = $NIC.InstanceID -replace '\\', '\'
    $RegPath = Resolve-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}\*" -ErrorAction SilentlyContinue | Where-Object {
        (Get-ItemProperty $_.Path -Name 'DeviceInstanceID' -ErrorAction SilentlyContinue).DeviceInstanceID -eq $SafeID
    }
    if ($RegPath) {
        $p = $RegPath.Path
        $AntiSleep = @(
            'EnablePME', '*DeviceSleepOnDisconnect', '*EEE', 'AdvancedEEE', '*SipsEnabled', 'EnableAspm', '*WakeOnMagicPacket', '*WakeOnPattern', 'AutoPowerSaveModeEnabled',
            'EEELinkAdvertisement', 'EnableGreenEthernet', 'SavePowerNowEnabled', 'ULPMode', 'WakeOnLink', 'WakeOnSlot', '*NicAutoPowerSaver', 'PowerSaveEnable', 'EnablePowerManagement'
        )
        foreach ($Prop in $AntiSleep) {
            if (Get-ItemProperty -Path $p -Name $Prop -ErrorAction SilentlyContinue) { Set-Reg $p $Prop '0' 'String' }
        }
        if (Get-ItemProperty -Path $p -Name 'PnPCapabilities' -ErrorAction SilentlyContinue) { Set-Reg $p 'PnPCapabilities' 24 }
    }
}

Write-Step 'network optimizations applied' 'ok'
Write-Done 'network configuration'

# ════════════════════════════════════════════════════════════
#  PHASE 7 · POWER PLAN
# ════════════════════════════════════════════════════════════
Write-Phase 'power plan'

$PowerBase      = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$PowerSaverGUID = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$UltimateGUID   = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighPerfGUID   = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$AlbusGUID      = '6f71756c-6c63-616e-8000-010101010101'

# reset & safe base
Write-Step 'resetting power schemes'
powercfg.exe -restoredefaultschemes *>$null
cmd.exe /c "powercfg /setactive $PowerSaverGUID >NUL 2>&1"

# import ultimate performance silently
Write-Step 'importing ultimate performance base'
cmd.exe /c "powercfg /duplicatescheme $UltimateGUID >NUL 2>&1"

# remove old albus plan
cmd.exe /c "powercfg /delete $AlbusGUID >NUL 2>&1"
if (Test-Path "$PowerBase\$AlbusGUID") {
    Remove-Item "$PowerBase\$AlbusGUID" -Recurse -Force -ErrorAction SilentlyContinue
}

# determine source: ultimate or high performance
$SourceGUID = if (Test-Path "$PowerBase\$UltimateGUID") { $UltimateGUID } else { $HighPerfGUID }
Write-Step "base plan: $SourceGUID"

# copy source plan structure to albus via registry
function Copy-RegistryKey {
    param([string]$Src, [string]$Dst)
    $srcKey = Get-Item $Src -ErrorAction SilentlyContinue
    if (-not $srcKey) { return }
    New-Item $Dst -Force -ErrorAction SilentlyContinue | Out-Null
    foreach ($val in $srcKey.GetValueNames()) {
        $data = $srcKey.GetValue($val, $null, 'DoNotExpandEnvironmentNames')
        $kind = $srcKey.GetValueKind($val)
        Set-ItemProperty -Path $Dst -Name $val -Value $data -Type $kind -ErrorAction SilentlyContinue
    }
    foreach ($sub in $srcKey.GetSubKeyNames()) {
        Copy-RegistryKey "$Src\$sub" "$Dst\$sub"
    }
}

Write-Step 'building albus plan structure'
Copy-RegistryKey "$PowerBase\$SourceGUID" "$PowerBase\$AlbusGUID"
Set-ItemProperty -Path "$PowerBase\$AlbusGUID" -Name 'FriendlyName' -Value 'albus 6.2'                                         -Type String -ErrorAction SilentlyContinue
Set-ItemProperty -Path "$PowerBase\$AlbusGUID" -Name 'Description'  -Value 'minimal latency, unparked cores, peak throughput.' -Type String -ErrorAction SilentlyContinue

# remove all unnecessary plans
Write-Step 'removing unnecessary power plans'
[regex]::Matches((powercfg /l | Out-String), '[a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12}', 'IgnoreCase') | ForEach-Object {
    if ($_.Value -notin @($AlbusGUID, $PowerSaverGUID)) {
        cmd.exe /c "powercfg /delete $($_.Value) >NUL 2>&1"
    }
}

# unlock all hidden power settings
Write-Step 'unlocking hidden power settings'
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.Property -contains 'Attributes') {
        Set-ItemProperty -Path $_.PSPath -Name 'Attributes' -Value 0 -ErrorAction SilentlyContinue
    }
}

# apply albus power settings directly via registry
Write-Step 'applying albus power settings'

function Set-PowerSetting {
    param([string]$Plan, [string]$SubGroup, [string]$Setting, [int]$AC, [int]$DC)
    $base = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$Plan\$SubGroup\$Setting"
    if (-not (Test-Path $base)) { New-Item $base -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty $base -Name 'ACSettingIndex' -Value $AC -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty $base -Name 'DCSettingIndex' -Value $DC -Type DWord -ErrorAction SilentlyContinue
}

# disk
Set-PowerSetting $AlbusGUID '0012ee47-9041-4b5d-9b77-535fba8b1442' '6738e2c4-e8a5-4a42-b16a-e040e769756e' 0   0    # disk turn off (never)
# desktop slideshow
Set-PowerSetting $AlbusGUID '0d7dbae2-4294-402a-ba8e-26777e8488cd' '309dce9b-bef4-4119-9921-a851fb12f0f4' 1   1    # paused
# wireless
Set-PowerSetting $AlbusGUID '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1' '12bbebe6-58d6-4636-95bb-3217ef867c1a' 0   0    # max perf
# sleep
Set-PowerSetting $AlbusGUID '238c9fa8-0aad-41ed-83f4-97be242c8f20' '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' 0   0    # sleep after: never
Set-PowerSetting $AlbusGUID '238c9fa8-0aad-41ed-83f4-97be242c8f20' '94ac6d29-73ce-41a6-809f-6363ba21b47e' 0   0    # hybrid sleep off
Set-PowerSetting $AlbusGUID '238c9fa8-0aad-41ed-83f4-97be242c8f20' '9d7815a6-7ee4-497e-8888-515a05f02364' 0   0    # hibernate after: never
Set-PowerSetting $AlbusGUID '238c9fa8-0aad-41ed-83f4-97be242c8f20' 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d' 0   0    # wake timers off
# usb
Set-PowerSetting $AlbusGUID '2a737441-1930-4402-8d77-b2bebba308a3' '0853a681-27c8-4100-a2fd-82013e970683' 0   0    # hub suspend timeout
Set-PowerSetting $AlbusGUID '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0   0    # selective suspend off
Set-PowerSetting $AlbusGUID '2a737441-1930-4402-8d77-b2bebba308a3' 'd4e98f31-5ffe-4ce1-be31-1b38b384c009' 0   0    # usb3 link power off
# power button
Set-PowerSetting $AlbusGUID '4f971e89-eebd-4455-a8de-9e59040e7347' 'a7066653-8d6c-40a8-910e-a1f54b84c7e5' 2   2    # shutdown
# pcie
Set-PowerSetting $AlbusGUID '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0   0    # link state off
# cpu
Set-PowerSetting $AlbusGUID '54533251-82be-4824-96c1-47b60b740d00' '893dee8e-2bef-41e0-89c6-b55d0929964c' 100 100  # min cpu state
Set-PowerSetting $AlbusGUID '54533251-82be-4824-96c1-47b60b740d00' 'bc5038f7-23e0-4960-96da-33abaf5935ec' 100 100  # max cpu state
Set-PowerSetting $AlbusGUID '54533251-82be-4824-96c1-47b60b740d00' '0cc5b647-c1df-4637-891a-dec35c318583' 100 100  # core parking min
Set-PowerSetting $AlbusGUID '54533251-82be-4824-96c1-47b60b740d00' 'ea062031-0e34-4ff1-9b6d-eb1059334028' 100 100  # core parking max
Set-PowerSetting $AlbusGUID '54533251-82be-4824-96c1-47b60b740d00' '94d3a615-a899-4ac5-ae2b-e4d8f634367f' 1   1    # cooling active
Set-PowerSetting $AlbusGUID '54533251-82be-4824-96c1-47b60b740d00' '36687f9e-e3a5-4dbf-b1dc-15eb381c6863' 0   0    # energy perf pref
Set-PowerSetting $AlbusGUID '54533251-82be-4824-96c1-47b60b740d00' '93b8b6dc-0698-4d1c-9ee4-0644e900c85d' 0   0    # heterogeneous scheduling
# display
Set-PowerSetting $AlbusGUID '7516b95f-f776-4464-8c53-06167f40cc99' '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' 600 600  # timeout 10m
Set-PowerSetting $AlbusGUID '7516b95f-f776-4464-8c53-06167f40cc99' 'aded5e82-b909-4619-9949-f5d71dac0bcb' 100 100  # brightness
Set-PowerSetting $AlbusGUID '7516b95f-f776-4464-8c53-06167f40cc99' 'f1fbfde2-a960-4165-9f88-50667911ce96' 100 100  # dimmed brightness
Set-PowerSetting $AlbusGUID '7516b95f-f776-4464-8c53-06167f40cc99' 'fbd9aa66-9553-4097-ba44-ed6e9d65eab8' 0   0    # adaptive brightness off
# video
Set-PowerSetting $AlbusGUID '9596fb26-9850-41fd-ac3e-f7c3c00afd4b' '10778347-1370-4ee0-8bbd-33bdacaade49' 1   1    # quality bias
Set-PowerSetting $AlbusGUID '9596fb26-9850-41fd-ac3e-f7c3c00afd4b' '34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4' 0   0    # optimize quality
# graphics
Set-PowerSetting $AlbusGUID '44f3beca-a7c0-460e-9df2-bb8b99e0cba6' '3619c3f2-afb2-4afc-b0e9-e7fef372de36' 2   2    # intel max perf
Set-PowerSetting $AlbusGUID 'c763b4ec-0e50-4b6b-9bed-2b92a6ee884e' '7ec1751b-60ed-4588-afb5-9819d3d77d90' 3   3    # amd best perf
Set-PowerSetting $AlbusGUID 'f693fb01-e858-4f00-b20f-f30e12ac06d6' '191f65b5-d45c-4a4f-8aae-1ab8bfd980e6' 1   1    # ati max perf
Set-PowerSetting $AlbusGUID 'e276e160-7cb0-43c6-b20b-73f5dce39954' 'a1662ab2-9d34-4e53-ba8b-2639b9e20857' 3   3    # switchable dynamic
# battery
Set-PowerSetting $AlbusGUID 'e73a048d-bf27-4f12-9731-8b2076e8891f' '5dbb7c9f-38e9-40d2-9749-4f8a0e9f640f' 0   0    # crit notif off
Set-PowerSetting $AlbusGUID 'e73a048d-bf27-4f12-9731-8b2076e8891f' '637ea02f-bbcb-4015-8e2c-a1c7b9c0b546' 0   0    # crit action nothing
Set-PowerSetting $AlbusGUID 'e73a048d-bf27-4f12-9731-8b2076e8891f' '8183ba9a-e910-48da-8769-14ae6dc1170a' 0   0    # low level 0
Set-PowerSetting $AlbusGUID 'e73a048d-bf27-4f12-9731-8b2076e8891f' '9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469' 0   0    # crit level 0
Set-PowerSetting $AlbusGUID 'e73a048d-bf27-4f12-9731-8b2076e8891f' 'bcded951-187b-4d05-bccc-f7e51960c258' 0   0    # low notif off
Set-PowerSetting $AlbusGUID 'e73a048d-bf27-4f12-9731-8b2076e8891f' 'd8742dcb-3e6a-4b3c-b3fe-374623cdcf06' 0   0    # low action nothing
Set-PowerSetting $AlbusGUID 'e73a048d-bf27-4f12-9731-8b2076e8891f' 'f3c5027d-cd16-4930-aa6b-90db844a8f00' 0   0    # reserve level 0
Set-PowerSetting $AlbusGUID 'de830923-a562-41af-a086-e3a2c6bad2da' '13d09884-f74e-474a-a852-b6bde8ad03a8' 100 100  # battery saver brightness off
Set-PowerSetting $AlbusGUID 'de830923-a562-41af-a086-e3a2c6bad2da' 'e69653ca-cf7f-4f05-aa73-cb833fa90ad4' 0   0    # battery saver auto never

# activate albus
Write-Step 'activating albus power plan'
cmd.exe /c "powercfg /setactive $AlbusGUID >NUL 2>&1"
if ($LASTEXITCODE -ne 0) {
    Set-ItemProperty -Path $PowerBase -Name 'ActivePowerScheme' -Value $AlbusGUID -Type String -ErrorAction SilentlyContinue
}

# hibernate
Write-Step 'disabling hibernate'
powercfg.exe /hibernate off *>$NULL
$PwrKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
Set-Reg $PwrKey 'HibernateEnabled'        0
Set-Reg $PwrKey 'HibernateEnabledDefault' 0

# fast boot
Write-Step 'disabling fast boot'
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'             'HiberbootEnabled' 0

# power throttling
Write-Step 'disabling power throttling'
$ThrottleKey = "$PwrKey\PowerThrottling"
if (-not (Test-Path $ThrottleKey)) { New-Item $ThrottleKey -Force | Out-Null }
Set-Reg $ThrottleKey 'PowerThrottlingOff' 1

# modern standby
Write-Step 'disabling modern standby'
Set-Reg 'HKLM:\System\CurrentControlSet\Control\Power' 'PlatformAoAcOverride' 0

# sleep study
Write-Step 'disabling sleep study reporting'
cmd.exe /c "wevtutil sl Microsoft-Windows-SleepStudy/Diagnostic /q:false >NUL 2>&1"
cmd.exe /c "wevtutil sl Microsoft-Windows-Kernel-Processor-Power/Diagnostic /q:false >NUL 2>&1"
cmd.exe /c "wevtutil sl Microsoft-Windows-UserModePowerService/Diagnostic /q:false >NUL 2>&1"
Set-Reg 'HKLM:\SYSTEM\ControlSet001\Control\Session Manager\Power' 'SleepStudyDisabled' 1

# flyout
Write-Step 'removing sleep & lock from start menu'
$FlyoutKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
if (-not (Test-Path $FlyoutKey)) { New-Item $FlyoutKey -Force | Out-Null }
Set-Reg $FlyoutKey 'ShowLockOption'  0
Set-Reg $FlyoutKey 'ShowSleepOption' 0

Write-Step "albus power plan active [$AlbusGUID]" 'ok'
Write-Done 'power plan'

#  PHASE 8 · HARDWARE TUNING

Write-Phase 'hardware tuning'

# 8.1  ghost device removal
Write-Step 'cleaning up ghost devices'
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Present -and $_.InstanceId -notmatch '^(ROOT|SWD|HTREE|DISPLAY|BTHENUM)\\' } |
    ForEach-Object {
        pnputil /remove-device $_.InstanceId /quiet | Out-Null
    }

# 8.2  msi interrupt mode
Write-Step 'enabling msi mode for pci devices'
Get-PnpDevice -InstanceId 'PCI\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -match '^(OK|Unknown)$' } |
    ForEach-Object {
        $base = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters"
        Set-Reg "$base\Interrupt Management\MessageSignaledInterruptProperties" 'MSISupported' 1
        if ($_.Class -eq 'Display') {
            Remove-ItemProperty -Path "$base\Interrupt Management\Affinity Policy" -Name 'DevicePriority' -ErrorAction SilentlyContinue
        }
    }

# 8.3  disk write cache
Write-Step 'enabling aggressive disk write caching'
Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceType -ne 'USB' -and $_.PNPDeviceID } |
    ForEach-Object {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters\Disk"
        Set-Reg $p 'UserWriteCacheSetting' 1
        Set-Reg $p 'CacheIsPowerProtected' 1
        Set-Reg $p 'EnablePowerManagement' 0
        Set-Reg $p 'AllowIdleIrpInD3'      0
    }

# 8.4  disable device power saving
Write-Step 'disabling device power saving states'
$PowerKeys = @('SelectiveSuspendEnabled', 'SelectiveSuspendOn', 'EnhancedPowerManagementEnabled', 'WaitWakeEnabled','DeviceIdleEnabled','AllowIdleIrpInD3','EnablePowerManagement','EnableSelectiveSuspend','DeviceIdleIgnoreWakeEnable')
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -match '^(OK|Unknown)$' } |
    ForEach-Object {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters"
        Set-Reg "$p\WDF" 'IdleInWorkingState' 0
        foreach ($key in $PowerKeys) { Set-Reg $p $key 0 }
    }
Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like '*USB\ROOT*' -or $_.InstanceId -like '*USB\VID*' } |
    ForEach-Object {
        $id = $_.InstanceId
        Get-CimInstance -ClassName MSPower_DeviceEnable -Namespace root\wmi -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceName -like "*$id*" } |
            ForEach-Object {
                Set-CimInstance -InputObject $_ -Property @{ Enable = $true } -ErrorAction SilentlyContinue
            }
        Get-CimInstance -ClassName MSPower_DeviceWakeEnable -Namespace root\wmi -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceName -like "*$id*" } |
            ForEach-Object {
                Set-CimInstance -InputObject $_ -Property @{ Enable = $false } -ErrorAction SilentlyContinue
            }
    }

# dma remapping & kernel guard
Write-Step 'optimizing dma remapping & kernel guard policy'
Set-Reg 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\DmaGuard\DeviceEnumerationPolicy' 'value' 2
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object {
    $p = "$($_.Name.Replace('HKEY_LOCAL_MACHINE', 'HKLM:'))\Parameters"
    if ((Get-ItemProperty $p -Name 'DmaRemappingCompatible' -ErrorAction SilentlyContinue) -ne $null) {
        Set-Reg $p 'DmaRemappingCompatible' 0
    }
}

# 8.5  exploit guard — disable system-wide mitigations for peak performance
Write-Step 'disabling exploit guard & mitigations'
$Mitigations = (Get-Command 'Set-ProcessMitigation' -ErrorAction SilentlyContinue).Parameters['Disable'].Attributes.ValidValues
if ($Mitigations) {
    Set-ProcessMitigation -SYSTEM -Disable $Mitigations -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
}

$KernelPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel'
$auditLen   = try { (Get-ItemProperty $KernelPath 'MitigationAuditOptions' -ErrorAction Stop).MitigationAuditOptions.Length } catch { 38 }

[byte[]]$mitigPayload = ,[byte]34 * $auditLen

$CriticalProcs = @(
    'fontdrvhost.exe', 'dwm.exe', 'lsass.exe', 'svchost.exe', 'WmiPrvSE.exe', 'winlogon.exe', 'csrss.exe', 'audiodg.exe', 'services.exe', 'explorer.exe', 'taskhostw.exe', 'sihost.exe'
)

foreach ($proc in $CriticalProcs) {
    $ifeoPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$proc"
    Set-Reg $ifeoPath 'MitigationOptions' $mitigPayload 'Binary'
    Set-Reg $ifeoPath 'MitigationAuditOptions' $mitigPayload 'Binary'
}

Set-Reg $KernelPath 'MitigationOptions' $mitigPayload 'Binary'
Set-Reg $KernelPath 'MitigationAuditOptions' $mitigPayload 'Binary'

$MemMgmt = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'

# meltdown & spectre (cve-2017-5754, cve-2017-5715)
Write-Step 'disabling meltdown & spectre mitigations'
Set-Reg -Path $MemMgmt -Name 'FeatureSettings'             -Value 1
Set-Reg -Path $MemMgmt -Name 'FeatureSettingsOverride'     -Value 3
Set-Reg -Path $MemMgmt -Name 'FeatureSettingsOverrideMask' -Value 3

# intel tsx (transaction synchronization extensions)
# downfall
if ((Get-CimInstance Win32_Processor -EA 0).Manufacturer -match 'Intel') {
    Set-Reg $KernelPath 'DisableTSX' 0
    Set-Reg $KernelPath 'DisableGatherDataSampling' 1
} else {
    Remove-ItemProperty -Path $KernelPath -Name 'DisableTSX' -EA 0
}

Write-Done 'hardware tuning'

Write-Phase 'filesystem & boot'

Write-Step 'ntfs'
fsutil behavior set disable8dot3 1 | Out-Null
fsutil behavior set disabledeletenotify 0 | Out-Null
fsutil behavior set disablelastaccess 1 | Out-Null
fsutil behavior set memoryusage 1 | Out-Null

Write-Step 'bcdedit'
bcdedit /timeout 10 | Out-Null
bcdedit /deletevalue useplatformclock | Out-Null
bcdedit /deletevalue useplatformtick | Out-Null
bcdedit /set bootmenupolicy legacy | Out-Null
bcdedit /set '{current}' description 'Albus 6.2' | Out-Null
label C: Albus | Out-Null

Write-Step 'disable memory compression'
Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null

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

#  PHASE 10 · ALBUSX SERVICE

Write-Phase 'albusx service'

$SvcName = 'AlbusXSvc'
$ExePath  = "$env:SystemRoot\AlbusX.exe"
$CSPath   = "$env:SystemRoot\AlbusX.cs"
$CSC      = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$SrcURL   = 'https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/albus/albus.cs'

if (Get-Service $SvcName -ErrorAction SilentlyContinue) {
    Stop-Service $SvcName -Force -ErrorAction SilentlyContinue
    sc.exe delete $SvcName | Out-Null
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
           -out:"$ExePath" "$CSPath" | Out-Null
    Remove-Item $CSPath -Force -ErrorAction SilentlyContinue
}

if (Test-Path $ExePath) {
    New-Service -Name $SvcName -BinaryPathName $ExePath -DisplayName 'AlbusX' `
        -Description 'albus core engine 3.0 — precision timer, audio latency, memory, interrupt affinity.' `
        -StartupType Automatic -ErrorAction SilentlyContinue | Out-Null
    sc.exe failure $SvcName reset= 60 actions= restart/5000/restart/10000/restart/30000 | Out-Null
    Start-Service $SvcName -ErrorAction SilentlyContinue
    Write-Step 'albusx running' 'ok'
} else {
    Write-Step 'albusx not deployed (compilation unavailable)' 'warn'
}

Write-Step 'enforcing global kernel timer resolution requests'
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1

Write-Done 'albusx service'

# ════════════════════════════════════════════════════════════
#  PHASE 11 · DEBLOAT
#  UWP removal, Edge, OneDrive.
#  Runs late — all services are stopped, state is clean.
# ════════════════════════════════════════════════════════════

Write-Phase 'debloat'

# uwp removal
Write-Step 'removing uwp bloat'
Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -notlike '*CBS*'                                       -and
    $_.Name -notlike '*Microsoft.AV1VideoExtension*'               -and
    $_.Name -notlike '*Microsoft.AVCEncoderVideoExtension*'        -and
    $_.Name -notlike '*Microsoft.HEIFImageExtension*'              -and
    $_.Name -notlike '*Microsoft.HEVCVideoExtension*'              -and
    $_.Name -notlike '*Microsoft.MPEG2VideoExtension*'             -and
    $_.Name -notlike '*Microsoft.Paint*'                           -and
    $_.Name -notlike '*Microsoft.RawImageExtension*'               -and
    $_.Name -notlike '*Microsoft.SecHealthUI*'                     -and
    $_.Name -notlike '*Microsoft.VP9VideoExtensions*'              -and
    $_.Name -notlike '*Microsoft.WebMediaExtensions*'              -and
    $_.Name -notlike '*Microsoft.WebpImageExtension*'              -and
    $_.Name -notlike '*Microsoft.Windows.Photos*'                  -and
    $_.Name -notlike '*Microsoft.Windows.ShellExperienceHost*'     -and
    $_.Name -notlike '*Microsoft.Windows.StartMenuExperienceHost*' -and
    $_.Name -notlike '*Microsoft.WindowsNotepad*'                  -and
    $_.Name -notlike '*Microsoft.WindowsStore*'                    -and
    $_.Name -notlike '*Microsoft.ImmersiveControlPanel*'
} | ForEach-Object {
    try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue | Out-Null } catch {}
}

# windows capabilities
Write-Step 'removing windows capabilities'
try {
    Get-WindowsCapability -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Installed'             -and
        $_.Name -notlike '*Ethernet*'        -and
        $_.Name -notlike '*WiFi*'            -and
        $_.Name -notlike '*Notepad*'         -and
        $_.Name -notlike '*NetFX3*'          -and
        $_.Name -notlike '*VBSCRIPT*'        -and
        $_.Name -notlike '*WMIC*'            -and
        $_.Name -notlike '*ShellComponents*'
    } | ForEach-Object {
        try { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
} catch {}

# optional features
Write-Step 'disabling optional features'
try {
    Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Enabled'                          -and
        $_.FeatureName -notlike '*DirectPlay*'          -and
        $_.FeatureName -notlike '*LegacyComponents*'    -and
        $_.FeatureName -notlike '*NetFx*'               -and
        $_.FeatureName -notlike '*SearchEngine-Client*' -and
        $_.FeatureName -notlike '*Server-Shell*'        -and
        $_.FeatureName -notlike '*Windows-Defender*'    -and
        $_.FeatureName -notlike '*Drivers-General*'     -and
        $_.FeatureName -notlike '*Server-Gui-Mgmt*'     -and
        $_.FeatureName -notlike '*WirelessNetworking*'
    } | ForEach-Object {
        try { Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
} catch {}

#>
# ── edge ──────────────────────────────────────────────────
Write-Step 'removing microsoft edge'

function Invoke-EdgeUninstallProcess {
    param([string]$Key)
    $baseKey      = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate'
    $registryPath = "$baseKey\ClientState\$Key"
    if (!(Test-Path $registryPath)) { Write-Step "edge registry key not found: $Key" 'warn'; return }

    Remove-ItemProperty -Path $registryPath -Name 'experiment_control_labels' -ErrorAction SilentlyContinue | Out-Null

    try {
        $folderPath = "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
        if (!(Test-Path $folderPath)) { New-Item -ItemType Directory -Path $folderPath -Force | Out-Null }
        New-Item -ItemType File -Path $folderPath -Name 'MicrosoftEdge.exe' -Force | Out-Null
    } catch { Write-Step "failed to create fake microsoftedge.exe: $_" 'warn'; return }

    $env:windir           = ''
    $uninstallString      = (Get-ItemProperty -Path $registryPath -EA SilentlyContinue).UninstallString
    $uninstallArguments   = (Get-ItemProperty -Path $registryPath -EA SilentlyContinue).UninstallArguments

    if ([string]::IsNullOrEmpty($uninstallString) -or [string]::IsNullOrEmpty($uninstallArguments)) {
        Write-Step "cannot find uninstall string for $Key" 'warn'; return
    }

    $uninstallArguments += ' --force-uninstall --delete-profile'
    if (!(Test-Path $uninstallString)) { Write-Step "setup.exe not found: $uninstallString" 'warn'; return }

    $spoofPath = "$env:SystemRoot\ImmersiveControlPanel\sihost.exe"
    try {
        Copy-Item "$env:SystemRoot\System32\cmd.exe" -Destination $spoofPath -Force
        $process = Start-Process -FilePath $spoofPath -ArgumentList "/c `"$uninstallString`" $uninstallArguments" -Wait -NoNewWindow -PassThru
        Write-Step "edge uninstall exit code: $($process.ExitCode)" 'ok'
    } catch {
        Write-Step "edge uninstall failed: $_" 'fail'
    } finally {
        Remove-Item $spoofPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-Edge {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' `
        -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    [Microsoft.Win32.Registry]::SetValue(
        'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev',
        'AllowUninstall', 1, [Microsoft.Win32.RegistryValueKind]::DWord) | Out-Null

    Invoke-EdgeUninstallProcess -Key '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'

    @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
      "$env:PUBLIC\Desktop",
      "$env:USERPROFILE\Desktop") | ForEach-Object {
        $lnk = Join-Path $_ 'Microsoft Edge.lnk'
        if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-WebView {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView' `
        -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    Invoke-EdgeUninstallProcess -Key '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
}

function Remove-EdgeUpdate {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update' `
        -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    $registryPath   = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate'
    $uninstallCmd   = (Get-ItemProperty -Path $registryPath -EA SilentlyContinue).UninstallCmdLine
    if ([string]::IsNullOrEmpty($uninstallCmd)) { Write-Step 'edge update uninstall string not found' 'warn'; return }
    Start-Process cmd.exe "/c $uninstallCmd" -WindowStyle Hidden -Wait
}

Remove-Edge
Remove-WebView
Remove-EdgeUpdate

# ── onedrive ──────────────────────────────────────────────
Write-Step 'removing onedrive'

function Remove-OneDrive {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
    }

    $setupPaths       = [System.Collections.ArrayList]@()
    $fallbackPaths    = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    )

    Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.PSChildName
        if (Test-Path "HKU:\$sid\Volatile Environment") {
            $regPath        = "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe"
            $uninstallStr   = (Get-ItemProperty -Path $regPath -EA SilentlyContinue).UninstallString
            if (-not [string]::IsNullOrEmpty($uninstallStr)) {
                $setupPaths.Add([System.IO.Path]::GetDirectoryName($uninstallStr)) | Out-Null
            }
            Remove-ItemProperty -Path "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
                -Name 'OneDrive' -ErrorAction SilentlyContinue
            Remove-Item -Path $regPath -Force -ErrorAction SilentlyContinue
        }
    }

    $allPaths = @($setupPaths) + $fallbackPaths | Select-Object -Unique

    foreach ($p in $allPaths) {
        if (Test-Path $p) {
            Write-Step "uninstalling onedrive from $p"
            Start-Process -FilePath $p -ArgumentList '/uninstall' -Wait -NoNewWindow -PassThru | Out-Null
        }
    }

    # kullanici klasorlerinden kalıntı temizle
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $odPath  = Join-Path $_.FullName 'AppData\Local\Microsoft\OneDrive'
        $lnkPath = Join-Path $_.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk'
        if (Test-Path $odPath)  { Remove-Item $odPath  -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force   -ErrorAction SilentlyContinue }
    }

    # explorer sidebar'dan kaldır
    [Microsoft.Win32.Registry]::SetValue(
        'HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}',
        'System.IsPinnedToNameSpaceTree', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
}

Remove-OneDrive

# ── winsxs ai & telemetry cleanup ─────────────────────────
Write-Step 'winsxs ai & telemetry cleanup'

# 1. telemetry / ai binary'lerini etkisizleştir (rename → .bak)
$telemetryBinaries = @(
    "$env:SystemRoot\System32\CompatTelRunner.exe"
    "$env:SystemRoot\System32\DeviceCensus.exe"
    "$env:SystemRoot\System32\AggregatorHost.exe"
    "$env:SystemRoot\System32\wsqmcons.exe"
    "$env:SystemRoot\System32\WerFault.exe"
    "$env:SystemRoot\System32\WerFaultSecure.exe"
    "$env:SystemRoot\System32\wermgr.exe"
    "$env:SystemRoot\System32\DiagSvcs\DiagnosticsHub.StandardCollector.Service.exe"
    "$env:SystemRoot\System32\omadmclient.exe"
    "$env:SystemRoot\SysWOW64\CompatTelRunner.exe"
    "$env:SystemRoot\SysWOW64\DeviceCensus.exe"
)

foreach ($bin in $telemetryBinaries) {
    if (-not (Test-Path $bin)) { continue }
    try {
        # ownership al
        $acl = Get-Acl $bin
        $owner = [System.Security.Principal.NTAccount]'Administrators'
        $acl.SetOwner($owner)
        Set-Acl $bin $acl

        # full control ver
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'Administrators','FullControl','Allow')
        $acl.SetAccessRule($rule)
        Set-Acl $bin $acl

        # rename → .bak (silmek yerine — geri alınabilir)
        Rename-Item $bin "$bin.bak" -Force -ErrorAction Stop
        Write-Step "neutralized: $(Split-Path $bin -Leaf)" 'ok'
    } catch {
        # takeown + icacls fallback
        $name = $bin
        takeown /f $name /a | Out-Null
        icacls $name /grant "Administrators:F" | Out-Null
        try { Rename-Item $name "$name.bak" -Force -ErrorAction Stop }
        catch { Write-Step "skipped (locked): $(Split-Path $bin -Leaf)" 'warn' }
    }
}

# 2. DISM component cleanup — eski güncelleme artıkları + superseded paketler
Write-Step 'dism component store cleanup'
try {
    $dismJobs = @(
        '/Online /Cleanup-Image /StartComponentCleanup /ResetBase'
        '/Online /Cleanup-Image /SPSuperseded'
    )
    foreach ($args in $dismJobs) {
        # $result = Start-Process -FilePath 'dism.exe' -ArgumentList $args -Wait -NoNewWindow -HideWindow -PassThru
        if ($result.ExitCode -eq 0) {
            Write-Step "dism $($args.Split('/')[3].Trim()) done" 'ok'
        } else {
            Write-Step "dism exit: $($result.ExitCode)" 'warn'
        }
    }
} catch {
    Write-Step "dism cleanup failed: $_" 'fail'
}

# 3. DISM ile AI / telemetry capability paketlerini kaldır
Write-Step 'removing ai & telemetry dism packages'
$dismPackages = @(
    'Microsoft-Windows-DiagTrack-Package*'
    'Microsoft-Windows-Telemetry-Package*'
    'Microsoft-Windows-CEIP-Package*'
    'Microsoft-OneCore-ApplicationModel-Cortana*'
    'Microsoft-Windows-AI-MachineLearning*'
    'Microsoft-Windows-BioEnrollment-Package*'
    'Microsoft-Windows-Holographic*'
    'Microsoft-Windows-QuickAssist*'
    'Microsoft-Windows-StepsRecorder*'
    'Microsoft-Windows-WirelessDisplay-Package*'
)

foreach ($pkg in $dismPackages) {
    try {
        $found = dism /Online /Get-Packages /Format:Table 2>$null |
            Where-Object { $_ -match [regex]::Escape($pkg.Replace('*','')) }
        if (-not $found) { continue }

        $found | ForEach-Object {
            $pkgName = ($_ -split '\|')[0].Trim()
            if ([string]::IsNullOrWhiteSpace($pkgName)) { return }
            $r = Start-Process dism -ArgumentList "/Online /Remove-Package /PackageName:$pkgName /NoRestart /Quiet" `
                -Wait -NoNewWindow -PassThru
            if ($r.ExitCode -eq 0) { Write-Step "removed: $pkgName" 'ok' }
            else { Write-Step "skip (in-use?): $pkgName" 'warn' }
        }
    } catch { Write-Step "package query failed: $pkg" 'warn' }
}

# 4. WinSxS içindeki telemetry manifest'lerini devre dışı bırak
Write-Step 'disabling telemetry winsxs manifests'
$winsxsManifests = @('*diagtrack*','*telemetry*','*ceip*','*diaghub*','*wer*') | ForEach-Object {
    Get-ChildItem "$env:SystemRoot\WinSxS\Manifests" -Filter $_ -ErrorAction SilentlyContinue
}
foreach ($manifest in $winsxsManifests) {
    try {
        takeown /f $manifest.FullName /a | Out-Null
        icacls $manifest.FullName /grant "Administrators:F" | Out-Null
        Rename-Item $manifest.FullName "$($manifest.FullName).bak" -Force -ErrorAction Stop
        Write-Step "manifest disabled: $($manifest.Name)" 'ok'
    } catch {
        Write-Step "manifest locked: $($manifest.Name)" 'warn'
    }
}

Write-Step 'winsxs ai & telemetry cleanup complete' 'ok'

# update health tools
Write-Step 'removing update health tools'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Update for x64-based Windows Systems|Microsoft Update Health Tools' } |
    ForEach-Object {
        if ($_.PSChildName) { Start-Process 'msiexec.exe' -ArgumentList "/x $($_.PSChildName) /qn /norestart" -Wait -NoNewWindow }
    }
sc.exe delete 'uhssvc' *>$null
Unregister-ScheduledTask -TaskName PLUGScheduler -Confirm:$false -ErrorAction SilentlyContinue

# gameinput
Write-Step 'removing microsoft gameinput'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '*Microsoft GameInput*' } |
    ForEach-Object { Start-Process 'msiexec.exe' -ArgumentList "/x $($_.PSChildName) /qn /norestart" -Wait -NoNewWindow }

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
        Get-Item $_ | ForEach-Object {
            $keyPath = $_.PSPath
            $_.GetValueNames() | ForEach-Object {
                Remove-ItemProperty -Path $keyPath -Name $_ -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

@("$env:AppData\Microsoft\Windows\Start Menu\Programs\Startup",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") | ForEach-Object {
    if (Test-Path $_) { Remove-Item "$_\*" -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Step 'startup entries cleared' 'ok'
Write-Done 'startup cleanup'

# ════════════════════════════════════════════════════════════
#  PHASE 15 · CLEANUP
# ════════════════════════════════════════════════════════════

Write-Phase 'cleanup'

Start-Process cleanmgr.exe -ArgumentList '/autoclean /d C:' -Wait -NoNewWindow
Remove-Item "C:\Albus" -Recurse -Force -ErrorAction SilentlyContinue

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
