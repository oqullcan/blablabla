# ──────────────────────────────────────────────────────────
#  albus playbook v2 | https://github.com/oqullcan/albuswin
# ──────────────────────────────────────────────────────────

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── 64-bit enforcement ────────────────────────────────────────────────────────
if ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -and -not [Environment]::Is64BitProcess) {
    $sysnative = "$env:windir\sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $sysnative) {
        & $sysnative -ExecutionPolicy Bypass -NoProfile -File $PSCommandPath
        exit
    }
}

# ── active user sid resolver ──────────────────────────────────────────────────
$script:ActiveSID = $null
try {
    $exp = Get-WmiObject Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exp) { $script:ActiveSID = $exp.GetOwnerSid().Sid }
} catch { }

$Identity  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Privilege = $Identity.Split('\')[-1].ToLower()
[Console]::Title = "albus playbook v2 - $Privilege"

# ── status engine ─────────────────────────────────────────────────────────────
function status ($msg, $type = "info") {
    $p, $c = switch ($type) {
        "info"  { "info", "Cyan"    }
        "done"  { "done", "Green"   }
        "warn"  { "warn", "Yellow"  }
        "fail"  { "fail", "Red"     }
        "step"  { "step", "Magenta" }
        default { "albus", "Gray"   }
    }
    Write-Host "$p - " -NoNewline -ForegroundColor $c
    Write-Host $msg.ToLower()
}

# ── registry engine ───────────────────────────────────────────────────────────
function Set-Registry {
    param ([string]$Path, [string]$Name, $Value, [string]$Type = "DWord")
    try {
        $Prefix     = if ($Path.StartsWith("-")) { "-" } else { "" }
        $ActualPath = if ($Path.StartsWith("-")) { $Path.Substring(1) } else { $Path }

        $ResolveHKCU = "HKEY_CURRENT_USER"
        $ResolvePS   = "HKCU:"
        if ($script:ActiveSID) {
            $ResolveHKCU = "HKEY_USERS\$script:ActiveSID"
            $ResolvePS   = "Registry::HKEY_USERS\$script:ActiveSID"
        }

        $CleanPath = $ActualPath.
            Replace("HKLM:", "HKEY_LOCAL_MACHINE").
            Replace("HKCU:", $ResolveHKCU).
            Replace("HKCR:", "HKEY_CLASSES_ROOT").
            Replace("HKU:",  "HKEY_USERS")

        $PSPath = $ActualPath.
            Replace("HKLM:", "Registry::HKEY_LOCAL_MACHINE").
            Replace("HKCU:", $ResolvePS).
            Replace("HKCR:", "Registry::HKEY_CLASSES_ROOT").
            Replace("HKU:",  "Registry::HKEY_USERS")

        # delete key
        if ($Prefix -eq "-") {
            if ($CleanPath -like "*HKEY_CLASSES_ROOT*") {
                & cmd.exe /c "reg delete `"$CleanPath`" /f 2>nul"
            } else {
                if (Test-Path $PSPath) { Remove-Item -Path $PSPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
            }
            return
        }

        # delete value
        if ($Value -eq "-") {
            if (Test-Path $PSPath) { Remove-ItemProperty -Path $PSPath -Name $Name -Force -ErrorAction SilentlyContinue | Out-Null }
            return
        }

        if (-not (Test-Path $PSPath)) { New-Item -Path $PSPath -Force -ErrorAction SilentlyContinue | Out-Null }

        if ($Name -eq "") {
            Set-Item -Path $PSPath -Value $Value -Force -ErrorAction SilentlyContinue | Out-Null
        } else {
            try {
                New-ItemProperty -Path $PSPath -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
            } catch {
                $RegType = switch ($Type) {
                    "DWord"        { "REG_DWORD"     }
                    "QWord"        { "REG_QWORD"     }
                    "String"       { "REG_SZ"        }
                    "ExpandString" { "REG_EXPAND_SZ" }
                    "Binary"       { "REG_BINARY"    }
                    "MultiString"  { "REG_MULTI_SZ"  }
                    default        { "REG_DWORD"     }
                }
                $FinalValue = if ($Type -eq "Binary") { ($Value | ForEach-Object { "{0:X2}" -f $_ }) -join "" } else { $Value }
                & cmd.exe /c "reg add `"$CleanPath`" /v `"$Name`" /t $RegType /d `"$FinalValue`" /f 2>nul"
                if ($LASTEXITCODE -ne 0) {
                    Add-Content -Path "C:\Albus\albus_error.log" -Value "[$(Get-Date -Format 'HH:mm:ss')] fail -> $CleanPath\$Name" -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {
        if (-not ($Path.StartsWith("-") -or $Value -eq "-")) {
            status "registry failed: $Path\$Name" "fail"
        }
    }
}

# ── init ──────────────────────────────────────────────────────────────────────
$dest = "C:\Albus"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

# ── software payload ──────────────────────────────────────────────────────────
if (Test-Connection -ComputerName "1.1.1.1" -Count 3 -Quiet -ErrorAction SilentlyContinue) {
    status "network available. initializing payload retrieval..." "step"

    # brave browser
    try {
        $braveRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/brave/brave-browser/releases/latest" -ErrorAction Stop
        $braveVer     = $braveRelease.tag_name
        $braveUrl     = "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe"
        status "fetching brave browser ($braveVer)..." "info"
        Invoke-WebRequest -Uri $braveUrl -OutFile "$dest\BraveSetup.exe" -UseBasicParsing -ErrorAction Stop
        status "installing brave browser..." "info"
        Start-Process -Wait "$dest\BraveSetup.exe" -ArgumentList "/silent /install" -WindowStyle Hidden
        Set-Registry "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" "HardwareAccelerationModeEnabled" 0 "DWord"
        Set-Registry "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" "BackgroundModeEnabled"           0 "DWord"
        Set-Registry "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" "HighEfficiencyModeEnabled"       1 "DWord"
        status "brave browser installed." "done"
    } catch { status "failed to install brave browser." "fail" }

    # 7-zip
    try {
        $7zRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/ip7z/7zip/releases/latest" -ErrorAction Stop
        $7zVer     = $7zRelease.name
        $7zUrl     = ($7zRelease.assets | Where-Object { $_.name -match "7z.*-x64\.exe" }).browser_download_url
        if ($7zUrl) {
            status "fetching 7-zip ($7zVer)..." "info"
            Invoke-WebRequest -Uri $7zUrl -OutFile "$dest\7zip.exe" -UseBasicParsing
            status "installing 7-zip..." "info"
            Start-Process -Wait "$dest\7zip.exe" -ArgumentList "/S"
            Set-Registry "HKCU:\Software\7-Zip\Options" "ContextMenu"   259 "DWord"
            Set-Registry "HKCU:\Software\7-Zip\Options" "CascadedMenu"  0   "DWord"
            status "7-zip installed." "done"
        }
    } catch { status "failed to install 7-zip." "fail" }

    # visual c++ runtimes
    try {
        status "fetching visual c++ x64 runtime..." "info"
        Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" -OutFile "$dest\vc_redist.x64.exe" -UseBasicParsing
        Start-Process -Wait "$dest\vc_redist.x64.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
        status "visual c++ runtime installed." "done"
    } catch { status "failed to install visual c++ runtime." "fail" }

    # directx end-user runtime
    try {
        status "fetching directx end-user runtime..." "info"
        Invoke-WebRequest -Uri "https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe" `
            -OutFile "$dest\dxwebsetup.exe" -UseBasicParsing -ErrorAction Stop
        Start-Process -Wait "$dest\dxwebsetup.exe" -ArgumentList "/Q" -WindowStyle Hidden
        status "directx runtime installed." "done"
    } catch { status "failed to install directx runtime." "fail" }

} else {
    status "network unavailable. skipping payload retrieval." "warn"
}

# ── reset capability consent storage ──────────────────────────────────────────
Stop-Service -Name 'camsvc' -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityConsentStorage.db*" -Force -ErrorAction SilentlyContinue

# ── registry tweaks ───────────────────────────────────────────────────────────
status "executing registry optimization engine..." "step"

if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null }
if (-not (Get-PSDrive -Name HKU  -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU  -PSProvider Registry -Root HKEY_USERS        | Out-Null }

$Today    = Get-Date
$PauseEnd = $Today.AddYears(31)
$TodayStr = $Today.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$PauseStr = $PauseEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$Tweaks = @(
    # ── ease of access ────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "DuckAudio"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "WinEnterLaunchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "ScriptingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "OnlineServicesEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "NarratorCursorHighlight"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "CoupleNarratorCursorKeyboard"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "IntonationPause"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "ReadHints"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "ErrorNotificationType"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "EchoChars"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "EchoWords"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NarratorHome"; Name = "MinimizeType"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NarratorHome"; Name = "AutoStart"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "EchoToggleKeys"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Ease of Access"; Name = "selfvoice"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Ease of Access"; Name = "selfscan"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowCaret"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowNarrator"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowMouse"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowFocus"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Accessibility"; Name = "Sound on Activation"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Accessibility"; Name = "Warning Sounds"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Accessibility\HighContrast"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "AutoRepeatRate"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "AutoRepeatDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys"; Name = "MaximumSpeed"; Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys"; Name = "TimeToMaximumSpeed"; Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\StickyKeys"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\ToggleKeys"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "FSTextEffect"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "TextEffect"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SoundSentry"; Name = "WindowsEffect"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SlateLaunch"; Name = "ATapp"; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SlateLaunch"; Name = "LaunchAT"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Accessibility\AudioDescription"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Blind Access"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Preference"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\On"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\ShowSounds"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\TimeOut"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Keyboard"; Name = "PrintScreenKeyForSnippingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\AudioDescription"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\Blind Access"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\HighContrast"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\Keyboard Preference"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\Keyboard Response"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys"; Name = "MaximumSpeed"; Value = "-"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys"; Name = "TimeToMaximumSpeed"; Value = "-"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\On"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\ShowSounds"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\SlateLaunch"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\SoundSentry"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\StickyKeys"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\TimeOut"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\ToggleKeys"; Name = "Flags"; Value = "0"; Type = "String" }

    # ── control panel ─────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Control Panel\TimeDate"; Name = "DstNotification"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "JPEGImportQuality"; Value = 100; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "MenuShowDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "ActiveWndTrkTimeout"; Value = 10; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "AutoEndTasks"; Value = "1"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "HungAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "WaitToKillAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "LowLevelHooksTimeout"; Value = "1000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Sound"; Name = "Beep"; Value = "no"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "JPEGImportQuality"; Value = 100; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "MenuShowDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "ActiveWndTrkTimeout"; Value = 10; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "AutoEndTasks"; Value = "1"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "HungAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "WaitToKillAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "LowLevelHooksTimeout"; Value = "1000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Sound"; Name = "Beep"; Value = "no"; Type = "String" }

    # ── visual effects ────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"; Name = "VisualFXSetting"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "UserPreferencesMask"; Value = ([byte[]](0x90,0x12,0x03,0x80,0x12,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Desktop\WindowMetrics"; Name = "MinAnimate"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "DragFullWindows"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "FontSmoothing"; Value = "2"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAnimations"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IconsOnly"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ListviewAlphaSelect"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ListviewShadow"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "EnableAeroPeek"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "AlwaysHibernateThumbnails"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAnimations"; Value = 0; Type = "DWord" }

    # ── explorer & shell ──────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "ShowFrequent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "ShowCloudFilesInQuickAccess"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "EnableAutoTray"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "MultipleInvokePromptMinimum"; Value = 100; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "link"; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "LaunchTo"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "HideFileExt"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "FolderContentsInfoTip"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowInfoTip"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowPreviewHandlers"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowStatusBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowSyncProviderNotifications"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SharingWizardOn"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSmallIcons"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "UseCompactMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SnapAssist"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableSnapBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableTaskGroups"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableSnapAssistFlyout"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SnapFill"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "JointResize"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "DITest"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "MultiTaskingAltTabFilter"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; Name = "TaskbarEndTask"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"; Name = "FullPath"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager"; Name = "EnthusiastMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"; Name = "System.IsPinnedToNameSpaceTree"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"; Name = "System.IsPinnedToNameSpaceTree"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"; Name = "FolderType"; Value = "NotSpecified"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"; Name = "FolderType"; Value = "NotSpecified"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "C:\Windows\explorer.exe"; Value = "GpuPreference=2;"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "C:\Windows\explorer.exe"; Value = "GpuPreference=2;"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoDriveTypeAutoRun"; Value = 255; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoLowDiskSpaceChecks"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "LinkResolveIgnoreLinkInfo"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoResolveSearch"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoPublishingWizard"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoWebServices"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoOnlinePrintsWizard"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInternetOpenWith"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "HubMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings"; Name = "ShowLockOption"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings"; Name = "ShowSleepOption"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"; Name = "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; Name = "SecurityHealth"; Value = ([byte[]](0x07,0x00,0x00,0x00,0x05,0xDB,0x8A,0x69,0x8A,0x49,0xD9,0x01)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"; Name = "SearchOrderConfig"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoDriveTypeAutoRun"; Value = 255; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoLowDiskSpaceChecks"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "LinkResolveIgnoreLinkInfo"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoResolveSearch"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoPublishingWizard"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoWebServices"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoOnlinePrintsWizard"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInternetOpenWith"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "AllowOnlineTips"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideRecentlyAddedApps"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "SettingsPageVisibility"; Value = "hide:home;"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "DisableGraphRecentItems"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "HideRecommendedSection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "HideRecentlyAddedApps"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "ShowOrHideMostUsedApps"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "HidePeopleBar"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "NoBalloonFeatureAdvertisements"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "NoAutoTrayNotify"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace"; Name = "AllowWindowsInkWorkspace"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace"; Name = "AllowSuggestedAppsInWindowsInkWorkspace"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control"; Name = "WaitToKillServiceTimeout"; Value = "1500"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; Name = "LongPathsEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "MultipleInvokePromptMinimum"; Value = 100; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "link"; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager"; Name = "EnthusiastMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"; Name = "DisableAutoplay"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "LaunchTo"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowInfoTip"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; Name = "TaskbarEndTask"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"; Name = "FullPath"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoBalloonFeatureAdvertisements"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoAutoTrayNotify"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "LinkResolveIgnoreLinkInfo"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoResolveSearch"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "HidePeopleBar"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableSearchBoxSuggestions"; Value = 1; Type = "DWord" }

    # ── taskbar ───────────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAl"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSd"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarMn"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSn"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowTaskViewButton"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowCopilotButton"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarDa"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IconSizePreference"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAppsVisibleInTabletMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAutoHideInTabletMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds"; Name = "ShellFeedsTaskbarViewMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds"; Name = "EnableFeeds"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat"; Name = "ChatIcon"; Value = 3; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; Name = "AllowNewsAndInterests"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowTaskViewButton"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarMn"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarDa"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAppsVisibleInTabletMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAutoHideInTabletMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Feeds"; Name = "ShellFeedsTaskbarViewMode"; Value = 2; Type = "DWord" }

    # ── start menu ────────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_Layout"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_AccountNotifications"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_RecoPersonalizedSites"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_TrackDocs"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_IrisRecommendations"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "ShowRecentList"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "AllAppsViewMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "RightCompanionToggledOpen"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"; Name = "IsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"; Name = "IsAvailable"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "ShowOrHideMostUsedApps"; Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableSearchBoxSuggestions"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "HideRecommendedSection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "ConfigureStartPins"; Value = '{"pinnedList":[{"packagedAppId":"Microsoft.WindowsStore_8wekyb3d8bbwe!App"},{"packagedAppId":"windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"},{"packagedAppId":"Microsoft.WindowsNotepad_8wekyb3d8bbwe!App"},{"packagedAppId":"Microsoft.Paint_8wekyb3d8bbwe!App"},{"desktopAppLink":"%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\File Explorer.lnk"},{"packagedAppId":"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"}]}'; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDocuments"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDownloads"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderFileExplorer"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderMusic"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderNetwork"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPersonalFolder"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPictures"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderSettings"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderVideos"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education"; Name = "IsEducationEnvironment"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\2792562829"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\3036241548"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\734731404";  Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\762256525";  Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_IrisRecommendations"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_AccountNotifications"; Value = 0; Type = "DWord" }

    # ── personalization ───────────────────────────────────────────────────────
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "Wallpaper"; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers"; Name = "BackgroundType"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Colors"; Name = "Background"; Value = "0 0 0"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu"; Name = "{645FF040-5081-101B-9F08-00AA002F954E}"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"; Name = "{645FF040-5081-101B-9F08-00AA002F954E}"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "AppsUseLightTheme"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "SystemUsesLightTheme"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "EnableTransparency"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "ColorPrevalence"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent"; Name = "AccentColorMenu"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent"; Name = "StartColorMenu"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Accent"; Name = "AccentPalette"; Value = ([byte[]](0x64,0x64,0x64,0x00,0x6b,0x6b,0x6b,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "AccentColor"; Value = -15132391; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "ColorizationAfterglow"; Value = -1004988135; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "ColorizationColor"; Value = -1004988135; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "EnableWindowColorization"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "UseDpiScaling"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "AmbientLightingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "ControlledByForegroundApp"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "UseSystemAccentColor"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\0\Theme0"; Name = "Color"; Value = 4279374354; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\0\Theme1"; Name = "Color"; Value = 4278190294; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\1\Theme0"; Name = "Color"; Value = 4294926889; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\1\Theme1"; Name = "Color"; Value = 4282117119; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\2\Theme0"; Name = "Color"; Value = 4278229247; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\2\Theme1"; Name = "Color"; Value = 4283680768; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\3\Theme0"; Name = "Color"; Value = 4294901930; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\3\Theme1"; Name = "Color"; Value = 4294967064; Type = "DWord" }

    # ── mouse ─────────────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSpeed"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold1"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold2"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSensitivity"; Value = "10"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "RawMouseThrottleEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "SmoothMouseXCurve"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xC0,0xCC,0x0C,0x00,0x00,0x00,0x00,0x00,0x80,0x99,0x19,0x00,0x00,0x00,0x00,0x00,0x40,0x66,0x26,0x00,0x00,0x00,0x00,0x00,0x00,0x33,0x33,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "SmoothMouseYCurve"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x38,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x70,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xA8,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xE0,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "ContactVisualization"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "GestureVisualization"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Scheme Source"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "AppStarting"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Arrow"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Crosshair"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Hand"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Help"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "IBeam"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "No"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "NWPen"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeAll"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeNESW"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeNS"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeNWSE"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "SizeWE"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "UpArrow"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Wait"; Value = ""; Type = "ExpandString" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseSpeed"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseThreshold1"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseThreshold2"; Value = "0"; Type = "String" }

    # ── search ────────────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "SearchboxTaskbarMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "BingSearchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "CortanaConsent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "GleamEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "WeatherEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "HolidayEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsDeviceSearchHistoryEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsDynamicSearchBoxEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "SafeSearchMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsAADCloudSearchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsMSACloudSearchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "PreventIndexOnBattery"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCloudSearch"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortanaAboveLock"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortana"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortanaInAAD"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowSearchToUseLocation"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchUseWeb"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "DisableWebSearch"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchPrivacy"; Value = 3; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Speech_OneCore\Preferences"; Name = "VoiceActivationEnableAboveLockscreen"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask"; Name = "ActivationType"; Value = 4294967295; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask"; Name = "Server"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\Software\Microsoft\Windows Search\Gather\Windows\SystemIndex"; Name = "RespectPowerModes"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Policies\Microsoft\FeatureManagement\Overrides"; Name = "1694661260"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "BingSearchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "CortanaConsent"; Value = 0; Type = "DWord" }

    # ── notifications ─────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "ToastEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "AutoOpenCopilotLargeScreens"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AutoPlay"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.CapabilityAccess"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard"; Name = "Disabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "NoCloudApplicationNotification"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "UpdateNotificationLevel"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless"; Name = "ScoobeCheckCompleted"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless"; Name = "ScoobeCheckCompleted"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0; Type = "DWord" }

    # ── sound schemes ─────────────────────────────────────────────────────────
    @{ Path = "HKCU:\AppEvents\Schemes"; Name = ""; Value = ".None"; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\.Default\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\CriticalBatteryAlarm\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceConnect\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceDisconnect\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceFail\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\LowBatteryAlarm\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\Notification.Default\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\SystemAsterisk\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\SystemExclamation\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\SystemHand\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\WindowsUAC\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\DisNumbersSound\.current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\HubOffSound\.current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\HubOnSound\.current";  Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\HubSleepSound\.current"; Name = ""; Value = ""; Type = "String" }

    # ── audio ─────────────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Multimedia\Audio"; Name = "UserDuckingPreference"; Value = 3; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation"; Name = "DisableStartupSound"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\EditionOverrides"; Name = "UserSetting_DisableStartupSound"; Value = 1; Type = "DWord" }

    # ── autoplay ──────────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"; Name = "DisableAutoplay"; Value = 1; Type = "DWord" }

    # ── hardware & devices ────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"; Name = "PreventDeviceMetadataFromNetwork"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Network\SharedAccessConnection"; Name = "EnableControl"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Shell\USB"; Name = "NotifyOnUsbErrors"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows"; Name = "LegacyDefaultPrinterMode"; Value = 1; Type = "DWord" }

    # ── input & language ──────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\input\Settings"; Name = "IsVoiceTypingKeyEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\input\Settings"; Name = "InsightsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\input"; Name = "IsInputAppPreloadEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "EnableAutoShiftEngage"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "EnableKeyAudioFeedback"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "EnableDoubleTapSpace"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "TouchKeyboardTapInvoke"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "TipbandDesiredVisibility"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "IsKeyBackgroundEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableAutocorrection"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableSpellchecking"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableTextPrediction"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnablePredictionSpaceInsertion"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\EmbeddedInkControl"; Name = "EnableInkingWithTouch"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Input\Settings"; Name = "EnableHwkbTextPrediction"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Input\Settings"; Name = "EnableHwkbAutocorrection"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Input\Settings"; Name = "MultilingualEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "ExtraIconsOnMinimized"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "Label"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "ShowStatus"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "Transparency"; Value = 255; Type = "DWord" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Language Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Layout Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\International\User Profile"; Name = "HttpAcceptLanguageOptOut"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableAutocorrection"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableSpellchecking"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableTextPrediction"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnablePredictionSpaceInsertion"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableDoubleTapSpace"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\Settings"; Name = "EnableHwkbTextPrediction"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\Settings"; Name = "EnableHwkbAutocorrection"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\Settings"; Name = "MultilingualEnabled"; Value = 0; Type = "DWord" }

    # ── dpi & gpu ─────────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "LogPixels"; Value = 96; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "Win8DpiScaling"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "EnablePerProcessSystemDPI"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "HwSchMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "MiracastForceDisable"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "TdrDelay"; Value = 12; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "WarpSupportsResourceResidency"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "DirectXUserGlobalSettings"; Value = "SwapEffectUpgradeEnable=1;VRROptimizeEnable=0;"; Type = "String" }

    # ── gaming ────────────────────────────────────────────────────────────────
    @{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AppCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AudioCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MicrophoneCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CursorCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleGameBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleGameBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MaximumRecordLength"; Value = 720000000000; Type = "QWord" }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "UseNexusForGameBarEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "GamepadNexusChordEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "AutoGameModeEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter"; Name = "ActivationType"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions"; Name = "ActivationType"; Value = 4294967295; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions"; Name = "Server"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamebar"; Name = ""; Value = "URL:ms-gamebar"; Type = "String" }
    @{ Path = "HKCR:\ms-gamebar"; Name = "URL Protocol"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamebar"; Name = "NoOpenWith"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamebar\shell\open\command"; Name = ""; Value = "$env:SystemRoot\System32\systray.exe"; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices"; Name = ""; Value = "URL:ms-gamebarservices"; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices"; Name = "URL Protocol"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices"; Name = "NoOpenWith"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamebarservices\shell\open\command"; Name = ""; Value = "$env:SystemRoot\System32\systray.exe"; Type = "String" }
    @{ Path = "HKCR:\ms-gamingoverlay"; Name = ""; Value = "URL:ms-gamingoverlay"; Type = "String" }
    @{ Path = "HKCR:\ms-gamingoverlay"; Name = "URL Protocol"; Value = ""; Type = "String" }
    @{ Path = "HKCR:\ms-gamingoverlay"; Name = "NoOpenWith"; Value = ""; Type = "String" }

    # ── copilot & ai ──────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI"; Name = "DisableAIDataAnalysis"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI"; Name = "AllowRecallEnablement"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\Shell\Copilot\BingChat"; Name = "IsUserEligible"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage\ShowJumpView"; Name = "Microsoft.Copilot_8wekyb3d8bbwe!App"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Dsh"; Name = "IsPrelaunchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Name = "DisableAIDataAnalysis"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Name = "AllowRecallEnablement"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Name = "DisableClickToDo"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot\BingChat"; Name = "IsUserEligible"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsCopilot"; Name = "DisableAIDataAnalysis"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableGenerativeFill"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableCocreator"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableImageCreator"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\WindowsNotepad"; Name = "DisableAIFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests"; Name = "value"; Value = 0; Type = "DWord" }

    # ── privacy & tracking ────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"; Name = "TailoredExperiencesWithDiagnosticDataEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\TailoredExperiencesWithDiagnosticDataEnabled"; Name = "Value"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications"; Name = "EnableAccountNotifications"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps"; Name = "AgentActivationEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps"; Name = "AgentActivationLastUsed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization"; Name = "RestrictImplicitTextCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore"; Name = "HarvestContacts"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Personalization\Settings"; Name = "AcceptedPrivacyPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Siuf\Rules"; Name = "NumberOfSIUFInPeriod"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Siuf\Rules"; Name = "PeriodInNanoSeconds"; Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\UserLocationOverridePrivacySetting"; Name = "Value"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; Name = "ShowGlobalPrompts"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Input\TIPC"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\InputPersonalization"; Name = "RestrictImplicitTextCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Personalization\Settings"; Name = "AcceptedPrivacyPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Siuf\Rules"; Name = "NumberOfSIUFInPeriod"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Siuf\Rules"; Name = "PeriodInNanoSeconds"; Value = ""; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore"; Name = "HarvestContacts"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy"; Name = "HasAccepted"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\MdmCommon\SettingValues"; Name = "LocationSyncEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"; Name = "Value"; Value = "Allow"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userAccountInformation"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\contacts"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appointments"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCall"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\phoneCallHistory"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\email"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userDataTasks"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\chat"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\radios"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\appDiagnostics"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\documentsLibrary"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\downloadsFolder"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\musicLibrary"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\picturesLibrary"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\videosLibrary"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\broadFileSystemAccess"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\systemAIModels"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeys"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\passkeysEnumeration"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowDesktopAnalyticsProcessing"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowDeviceNameInTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowCommercialDataPipeline"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowWUfBCloudProcessing"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowUpdateComplianceProcessing"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "MicrosoftEdgeDataOptIn"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DisableEnterpriseAuthProxy"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DisableTelemetryOptInChangeNotification"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DisableTelemetryOptInSettingsUx"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DoNotShowFeedbackNotifications"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "LimitEnhancedDiagnosticDataWindowsAnalytics"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowBuildPreview"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "LimitDiagnosticLogCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "LimitDumpCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DisableOneSettingsDownloads"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "DoNotShowFeedbackNotifications"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "MaxTelemetryAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\System\AllowTelemetry"; Name = "value"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\DevicePolicy\AllowTelemetry"; Name = "DefaultValue"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\AllowTelemetry"; Name = "Value"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System"; Name = "AllowExperimentation"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener"; Name = "Start"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SQMLogger"; Name = "Start"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SetupPlatformTel"; Name = "Start"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo"; Name = "DisabledByGroupPolicy"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "PublishUserActivities"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "EnableActivityFeed"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "UploadUserActivities"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableHelpSticker"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization"; Name = "AllowInputPersonalization"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports"; Name = "PreventHandwritingErrorReports"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC"; Name = "PreventHandwritingDataSharing"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps"; Name = "AllowUntriggeredNetworkTrafficOnSettingsPage"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps"; Name = "AutoDownloadAndUpdateMapData"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\TIPC"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\TextInput"; Name = "AllowLinguisticDataCollection"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\ProtectedEventLogging"; Name = "EnableProtectedEventLogging"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice"; Name = "AllowFindMyDevice"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableSoftLanding"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableCloudOptimizedContent"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsConsumerFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableTailoredExperiencesWithDiagnosticData"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableSoftLanding"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "ConfigureWindowsSpotlight"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableThirdPartySuggestions"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableTailoredExperiencesWithDiagnosticData"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightWindowsWelcomeExperience"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnActionCenter"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnSettings"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "ConfigureWindowsSpotlight"; Value = 2; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableThirdPartySuggestions"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\SQMClient\Windows"; Name = "CEIPEnable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\AppV\CEIP"; Name = "CEIPEnable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Messenger\Client"; Name = "CEIP"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\UnattendSettings\SQMClient"; Name = "CEIPEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "AutoApproveOSDumps"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "LoggingDisabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DontSendAdditionalData"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DontShowUI"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DisableArchive"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DisableWerUpload"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "0"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "DontSendAdditionalData"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "LoggingDisabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "DefaultConsent"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "DefaultOverrideBehavior"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"; Name = "Block-Unified-Telemetry-Client"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"; Name = "Block-Windows-Error-Reporting"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Windows-Error-Reporting|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules"; Name = "Block-Unified-Telemetry-Client"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules"; Name = "Block-Windows-Error-Reporting"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Windows-Error-Reporting|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; Name = "LetAppsRunInBackground"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform"; Name = "NoGenTicket"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableHTTPPrinting"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableWebPnPDownload"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0"; Name = "NoOnlineAssist"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0"; Name = "NoExplicitFeedback"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0"; Name = "NoImplicitFeedback"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform"; Name = "NoGenTicket"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableHTTPPrinting"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableWebPnPDownload"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\PCHealth\HelpSvc"; Name = "Headlines"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\PCHealth\ErrorReporting"; Name = "DoReport"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Internet Connection Wizard"; Name = "ExitOnMSICW"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\EventViewer"; Name = "MicrosoftEventVwrDisableLinks"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\SearchCompanion"; Name = "DisableContentFileUpdates"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Messaging"; Name = "AllowMessageSync"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1; Type = "DWord" }

    # ── content delivery manager ──────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "ContentDeliveryAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "FeatureManagementEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "OemPreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEverEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenOverlayEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SoftLandingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SlideshowEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContentEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RemediationRequired"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-310093Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-314559Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338387Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338389Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338393Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353694Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353696Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "ContentDeliveryAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContentEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEverEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "OemPreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "FeatureManagementEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "ContentDeliveryAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContentEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "OemPreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "FeatureManagementEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RemediationRequired"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SoftLandingEnabled"; Value = 0; Type = "DWord" }

    # ── accounts & sync ───────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"; Name = "EnableGoodbye"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableAutomaticRestartSignOn"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "EnableFirstLogonAnimation"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableStartupSound"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "MSAOptional"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "EnableLinkedConnections"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"; Name = "DevicePasswordLessBuildVersion"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"; Name = "DevicePasswordLessUpdateType"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableApplicationSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAppSyncSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableCredentialsSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisablePersonalizationSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableDesktopThemeSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWindowsSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableStartLayoutSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWebBrowserSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableLanguageSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAccessibilitySettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableSyncOnPaidNetwork"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "EnableWindowsBackup"; Value = 0; Type = "DWord" }

    # ── cross device ──────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration"; Name = "IsResumeAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration"; Name = "IsOneDriveResumeAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume"; Name = "value"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "AllowClipboardHistory"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "AllowCrossDeviceClipboard"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "DragTrayEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "RomeSdkChannelUserAuthzPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "CdpSessionUserAuthzPolicy"; Value = 0; Type = "DWord" }

    # ── cloud experience host ─────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\developer"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\developer"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\gaming"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\gaming"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\family"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\creative"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\schoolwork"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\entertainment"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\business"; Name = "Intent"; Value = 0; Type = "DWord" }

    # ── tablet & immersive shell ──────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "SignInMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "TabletMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "ConvertibleSlateModePromptPreference"; Value = 2; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "SignInMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "TabletMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "ConvertibleSlateModePromptPreference"; Value = 2; Type = "DWord" }

    # ── system performance ────────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"; Name = "Win32PrioritySeparation"; Value = 38; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\PriorityControl"; Name = "Win32PrioritySeparation"; Value = 38; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; Name = "NetworkThrottlingIndex"; Value = 10; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance"; Name = "fAllowToGetHelp"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"; Name = "MaintenanceDisabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScheduledDiagnostics"; Name = "EnabledExecution"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fTaskEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fDeadlineEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"; Name = "DisableWpbtExecution"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\Session Manager"; Name = "DisableWpbtExecution"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\Session Manager"; Name = "BootExecute"; Value = "autocheck autochk /k:C*"; Type = "MultiString" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1387020943"; Name = "EnabledState"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1694661260"; Name = "EnabledState"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; Name = "AutoReboot"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; Name = "CrashDumpEnabled"; Value = 3; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; Name = "DisplayParameters"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\System\CurrentControlSet\Control\TimeZoneInformation"; Name = "RealTimeIsUniversal"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsMitigation"; Name = "UserPreference"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Minimal\MSIServer"; Name = ""; Value = "Service"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Network\MSIServer"; Name = ""; Value = "Service"; Type = "String" }

    # ── storage & power shell ─────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense"; Name = "AllowStorageSenseGlobal"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "04"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "08"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "32"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "256"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "2048"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "StoragePoliciesChanged"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\VideoSettings"; Name = "VideoQualityOnBattery"; Value = 1; Type = "DWord" }

    # ── apps & maps ───────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\Maps"; Name = "AutoUpdateEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\Maps"; Name = "UpdateOnlyOnWifi"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"; Name = "AllowAutomaticAppArchiving"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate"; Name = "AutoDownload"; Value = 2; Type = "DWord" }

    # ── wifi & network ────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config"; Name = "AutoConnectAllowedOEM"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features"; Name = "WiFiSenseOpen"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting"; Name = "value"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots"; Name = "value"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\Local"; Name = "fDisablePowerManagement"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy"; Name = "fDisablePowerManagement"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings"; Name = "DownloadMode"; Value = 0; Type = "DWord" }

    # ── updates ───────────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseUpdatesExpiryTime"; Value = $PauseStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseFeatureUpdatesEndTime"; Value = $PauseStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseFeatureUpdatesStartTime"; Value = $TodayStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseQualityUpdatesEndTime"; Value = $PauseStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseQualityUpdatesStartTime"; Value = $TodayStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseUpdatesStartTime"; Value = $TodayStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "TrayIconVisibility"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "HideMCTLink"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "RestartNotificationsAllowed2"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "FlightSettingsMaxPauseDays"; Value = 5269; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "ExcludeWUDriversInQualityUpdate"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "SetAllowOptionalContent"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "AllowTemporaryEnterpriseFeatureControl"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = "IncludeRecommendedUpdates"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = "EnableFeaturedSoftware"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = "NoAutoUpdate"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DriverSearching"; Name = "SearchOrderConfig"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Settings"; Name = "DisableSendGenericDriverNotFoundToWER"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Settings"; Name = "DisableSendRequestAdditionalSoftwareToWER"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Device Metadata"; Name = "PreventDeviceMetadataFromNetwork"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\PreviewBuilds"; Name = "EnableConfigFlighting"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds"; Name = "AllowBuildPreview"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; Name = "DODownloadMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager"; Name = "ShippedWithReserves"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsStore"; Name = "AutoDownload"; Value = 4; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsStore"; Name = "DisableOSUpgrade"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\Setup\UpgradeNotification"; Name = "UpgradeAvailable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate"; Name = "workCompleted"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate"; Name = "workCompleted"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe"; Name = "BlockedOobeUpdaters"; Value = '["MS_Outlook"]'; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"; Name = "ExcludeWUDriversInQualityUpdate"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Update"; Name = "ExcludeWUDriversInQualityUpdate"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Update\ExcludeWUDriversInQualityUpdate"; Name = "value"; Value = 1; Type = "DWord" }

    # ── security & smartscreen ────────────────────────────────────────────────
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Edge\SmartScreenEnabled"; Name = ""; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost"; Name = "EnableWebContentEvaluation"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows Security Health\State"; Name = "AccountProtection_MicrosoftAccount_Disconnected"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen"; Name = "ConfigureAppInstallControlEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\SmartScreen"; Name = "ConfigureAppInstallControl"; Value = "Anywhere"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray"; Name = "HideSystray"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Name = "SecurityHealth"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\BitLocker"; Name = "PreventDeviceEncryption"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows Defender\Reporting"; Name = "DisableGenericRePorts"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System"; Name = "AllowExperimentation"; Value = 0; Type = "DWord" }

    # ── app compat & app privacy ──────────────────────────────────────────────
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisableEngine"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "AITEnable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisableUAR"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisablePCA"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisableInventory"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "SbEnable"; Value = 1; Type = "DWord" }

    # ── edge & logging ────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"; Name = "InstallDefault"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"; Name = "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"; Name = "Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\EdgeUpdate"; Name = "DoNotUpdateToEdgeWithChromium"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\ClickToRun\OverRide"; Name = "DisableLogManagement"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"; Name = "RPSessionInterval"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\cfg"; Name = "DiskPercent"; Value = 0; Type = "DWord" }

    # ── ifeo: telemetry & performance ─────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CompatTelRunner.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\AggregatorHost.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\BingChatInstaller.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\BGAUpsell.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\BCILauncher.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SearchIndexer.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 5; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ctfmon.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 5; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\fontdrvhost.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\fontdrvhost.exe\PerfOptions"; Name = "IoPriority"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\lsass.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sihost.exe\PerfOptions"; Name = "CpuPriorityClass"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sihost.exe\PerfOptions"; Name = "IoPriority"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vgc.exe"; Name = "MitigationOptions"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vgc.exe"; Name = "EAFModules"; Value = ""; Type = "String" }

    # ── oobe ──────────────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "BypassNRO"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideOnlineAccountScreens"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideEULAPage"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideWirelessSetupInOOBE"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "ProtectYourPC"; Value = 3; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "DisablePrivacyExperience"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideOEMRegistrationScreen"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "DisableVoice"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "EnableCortanaVoice"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "HideOnlineAccountScreens"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "HideEULAPage"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "HideWirelessSetupInOOBE"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "DisablePrivacyExperience"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "HideOEMRegistrationScreen"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "DisableVoice"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE\AppSettings"; Name = "Skype-UserConsentAccepted"; Value = 0; Type = "DWord" }

    # ── bypass requirements ───────────────────────────────────────────────────
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassSecureBootCheck"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassTPMCheck"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassCPUCheck"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassRAMCheck"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\Setup\LabConfig"; Name = "BypassStorageCheck"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\Setup\MoSetup"; Name = "AllowUpgradesWithUnsupportedTPMOrCPU"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\UnsupportedHardwareNotificationCache"; Name = "SV1"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\UnsupportedHardwareNotificationCache"; Name = "SV2"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache"; Name = "SV1"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache"; Name = "SV2"; Value = 0; Type = "DWord" }

    # ── oem & branding ────────────────────────────────────────────────────────
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; Name = "EditionSubManufacturer"; Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; Name = "EditionSubstring"; Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; Name = "EditionSubVersion"; Value = "V2.0"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "HelpCustomized"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "Manufacturer"; Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "SupportProvider"; Value = "Albus Support"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "SupportURL"; Value = "https://github.com/oqullcan/albuswin"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\UI\Visibility"; Name = "HideInsiderPage"; Value = 1; Type = "DWord" }

    # ── focus assist ──────────────────────────────────────────────────────────
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$$windows.data.notifications.quiethourssettings\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0xB4,0x67,0x2B,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x14,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x55,0x00,0x6E,0x00,0x72,0x00,0x65,0x00,0x73,0x00,0x74,0x00,0x72,0x00,0x69,0x00,0x63,0x00,0x74,0x00,0x65,0x00,0x64,0x00,0xCA,0x28,0xD0,0x14,0x02,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentgame$windows.data.notifications.quietmoment\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x6C,0x39,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x50,0x00,0x72,0x00,0x69,0x00,0x6F,0x00,0x72,0x00,0x69,0x00,0x74,0x00,0x79,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)); Type = "Binary" }
)

foreach ($Tweak in $Tweaks) {
    Set-Registry -Path $Tweak.Path -Name $Tweak.Name -Value $Tweak.Value -Type $(if ($Tweak.Type) { $Tweak.Type } else { "DWord" })
}

# ── extended registry hooks ───────────────────────────────────────────────────
try {
    Remove-Item "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate"  -Recurse -Force -ErrorAction SilentlyContinue
} catch { }
try {
    $folderPath = Join-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes' '{885a186e-a440-4ada-812b-db871b942259}'
    Get-ChildItem -Path $folderPath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        if ($null -ne $props.GroupBy) { Set-ItemProperty -Path $_.PSPath -Name GroupBy -Value '' -ErrorAction SilentlyContinue }
    }
} catch { }
try {
    $bags = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
    if (Test-Path $bags) {
        Get-ChildItem $bags -ErrorAction SilentlyContinue | ForEach-Object {
            $full = Join-Path $_.PSPath 'Shell\{885A186E-A440-4ADA-812B-DB871B942259}'
            if (Test-Path $full) { Remove-Item $full -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
} catch { }

status "registry optimization complete." "done"

# ── svchost & service optimization ───────────────────────────────────────────
status "optimizing svchost & services..." "step"

Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "SvcHostSplitThresholdInKB" -Value 0xffffffff -Type "DWord"

Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Services" -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $img = (Get-ItemProperty -Path $_.PSPath -Name "ImagePath" -ErrorAction SilentlyContinue).ImagePath
        if ($img -match "svchost\.exe") {
            Set-Registry -Path $_.PSPath -Name "SvcHostSplitDisable" -Value 1 -Type "DWord"
        }
    } catch { }
}

$ServiceConfig = @(
    @{ Name = "DiagTrack";                                     Start = 4 }
    @{ Name = "Telemetry";                                     Start = 4 }
    @{ Name = "dmwappushservice";                              Start = 4 }
    @{ Name = "diagnosticshub.standardcollector.service";      Start = 4 }
    @{ Name = "WerSvc";                                        Start = 4 }
    @{ Name = "wercplsupport";                                 Start = 4 }
    @{ Name = "DPS";                                           Start = 4 }
    @{ Name = "WdiServiceHost";                                Start = 4 }
    @{ Name = "WdiSystemHost";                                 Start = 4 }
    @{ Name = "troubleshootingsvc";                            Start = 4 }
    @{ Name = "diagsvc";                                       Start = 4 }
    @{ Name = "PcaSvc";                                        Start = 4 }
    @{ Name = "RetailDemo";                                    Start = 4 }
    @{ Name = "MapsBroker";                                    Start = 4 }
    @{ Name = "edgeupdate";                                    Start = 4 }
    @{ Name = "Wecsvc";                                        Start = 4 }
    @{ Name = "SysMain";                                       Start = 4 }
    @{ Name = "wisvc";                                         Start = 4 }
    @{ Name = "UCPD";                                          Start = 4 }
    @{ Name = "GraphicsPerfSvc";                               Start = 4 }
    @{ Name = "Ndu";                                           Start = 4 }
    @{ Name = "DSSvc";                                         Start = 4 }
    @{ Name = "WSAIFabricSvc";                                 Start = 4 }
    @{ Name = "Spooler";                                       Start = 4 }
    @{ Name = "PrintNotify";                                   Start = 4 }
    @{ Name = "PrintScanBrokerService";                        Start = 4 }
    @{ Name = "PrintDeviceConfigurationService";               Start = 4 }
    @{ Name = "TermService";                                   Start = 4 }
    @{ Name = "UmRdpService";                                  Start = 4 }
    @{ Name = "SessionEnv";                                    Start = 4 }
    @{ Name = "NetBT";                                         Start = 4 }
    @{ Name = "dam";                                           Start = 4 }
    @{ Name = "CSC";                                           Start = 4 }
    @{ Name = "CSCSERVICE";                                    Start = 4 }
    @{ Name = "svsvc";                                         Start = 4 }
    @{ Name = "dusmsvc";                                       Start = 4 }
    @{ Name = "amdfendr";                                      Start = 4 }
    @{ Name = "amdfendrmgr";                                   Start = 4 }
    @{ Name = "InventorySvc";                                  Start = 4 }
    @{ Name = "printworkflowusersvc";                          Start = 4 }
    @{ Name = "stisvc";                                        Start = 4 }
    @{ Name = "usbprint";                                      Start = 4 }
    @{ Name = "McpManagementService";                          Start = 4 }
    @{ Name = "bttflt";                                        Start = 4 }
    @{ Name = "gencounter";                                    Start = 4 }
    @{ Name = "hyperkbd";                                      Start = 4 }
    @{ Name = "hypervideo";                                    Start = 4 }
    @{ Name = "spaceparser";                                   Start = 4 }
    @{ Name = "storflt";                                       Start = 4 }
    @{ Name = "vmgid";                                         Start = 4 }
    @{ Name = "vpci";                                          Start = 4 }
    @{ Name = "vid";                                           Start = 4 }
    @{ Name = "GpuEnergyDrv";                                  Start = 4 }
    @{ Name = "tcpipreg";                                      Start = 4 }
    @{ Name = "OneSyncSvc";                                    Start = 4 }
    @{ Name = "TrkWks";                                        Start = 4 }
    @{ Name = "CDPUserSvc";                                    Start = 4 }
    @{ Name = "condrv";                                        Start = 2 }
)

foreach ($S in $ServiceConfig) {
    if (Get-Service -Name $S.Name -ErrorAction SilentlyContinue) {
        Stop-Service -Name $S.Name -Force -ErrorAction SilentlyContinue
        $type = switch ($S.Start) { 2 { "Automatic" } 3 { "Manual" } 4 { "Disabled" } }
        Set-Service -Name $S.Name -StartupType $type -ErrorAction SilentlyContinue
        Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($S.Name)" -Name "Start" -Value $S.Start -Type "DWord"
    }
}

# ── scheduled tasks ───────────────────────────────────────────────────────────
status "disabling diagnostic scheduled tasks..." "step"

$TasksToDisable = @(
    "Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
    "Microsoft\Windows\Application Experience\ProgramDataUpdater",
    "Microsoft\Windows\Application Experience\StartupAppTask",
    "Microsoft\Windows\Application Experience\PcaPatchDbTask",
    "Microsoft\Windows\AppxDeploymentClient\UCPD Velocity",
    "Microsoft\Windows\Autochk\Proxy",
    "Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
    "Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
    "Microsoft\Windows\Customer Experience Improvement Program\Uploader",
    "Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
    "Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance",
    "Microsoft\Windows\Windows Defender\Windows Defender Cleanup",
    "Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan",
    "Microsoft\Windows\Windows Defender\Windows Defender Verification",
    "Microsoft\Windows\Flighting\FeatureConfig\UsageDataReporting",
    "Microsoft\Windows\Defrag\ScheduledDefrag",
    "Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem",
    "Microsoft\Windows\Feedback\Siuf\DmClient",
    "Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload"
)

foreach ($Task in $TasksToDisable) {
    Disable-ScheduledTask -TaskPath "\" -TaskName ($Task -split "\\")[-1] -ErrorAction SilentlyContinue | Out-Null
}

# ── post tweaks ───────────────────────────────────────────────────────────────
status "applying post-registry system tweaks..." "step"

# memory compression & bitlocker
Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null
Get-BitLockerVolume -ErrorAction SilentlyContinue |
    Where-Object { $_.ProtectionStatus -eq "On" } |
    Disable-BitLocker -ErrorAction SilentlyContinue | Out-Null

# ── network optimization ──────────────────────────────────────────────────────
status "optimizing network stack..." "step"

& netsh int tcp set global autotuninglevel=restricted    2>&1 | Out-Null
& netsh int tcp set global ecncapability=disabled        2>&1 | Out-Null
& netsh int tcp set global timestamps=disabled           2>&1 | Out-Null
& netsh int tcp set global initialRto=2000               2>&1 | Out-Null
& netsh int tcp set global rss=enabled                   2>&1 | Out-Null
& netsh int tcp set global rsc=disabled                  2>&1 | Out-Null
& netsh int tcp set global nonsackrttresiliency=disabled 2>&1 | Out-Null

Disable-NetAdapterLso -Name "*" -IPv4 -ErrorAction SilentlyContinue | Out-Null
Set-NetAdapterAdvancedProperty -Name "*" -DisplayName "Interrupt Moderation" -DisplayValue "Disabled" -ErrorAction SilentlyContinue | Out-Null

'ms_lldp','ms_lltdio','ms_implat','ms_rspndr','ms_tcpip6','ms_server','ms_msclient','ms_pacer' | ForEach-Object {
    Disable-NetAdapterBinding -Name "*" -ComponentID $_ -ErrorAction SilentlyContinue | Out-Null
}

Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -ErrorAction SilentlyContinue | ForEach-Object {
    Set-Registry -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -Type "DWord"
    Set-Registry -Path $_.PSPath -Name "TCPNoDelay"      -Value 1 -Type "DWord"
}

# adapter power saving
Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue | ForEach-Object {
    $P = $_.PSPath
    if ((Get-ItemProperty -Path $P -Name "*SpeedDuplex" -ErrorAction SilentlyContinue) -and
        -not (Get-ItemProperty -Path $P -Name "*PhyType" -ErrorAction SilentlyContinue)) {

        "EnablePME","*DeviceSleepOnDisconnect","*EEE","AdvancedEEE","*SipsEnabled","EnableAspm","ASPM",
        "*ModernStandbyWoLMagicPacket","*SelectiveSuspend","EnableGigaLite","*WakeOnMagicPacket",
        "*WakeOnPattern","AutoPowerSaveModeEnabled","EEELinkAdvertisement","EnableGreenEthernet",
        "EnableModernStandby","PowerDownPll","PowerSavingMode","ReduceSpeedOnPowerDown","S5WakeOnLan",
        "SavePowerNowEnabled","ULPMode","WakeOnLink","WakeOnSlot","WakeOnLinkUp",
        "*NicAutoPowerSaver","PowerSaveEnable","EnablePowerManagement","WakeFromS5",
        "EnableSavePowerNow","*EnableDynamicPowerGating","DynamicPowerGating","WakeFromPowerOff","LogLinkStateEvent" | ForEach-Object {
            if (Get-ItemProperty -Path $P -Name $_ -ErrorAction SilentlyContinue) {
                Set-Registry -Path $P -Name $_ -Value "0" -Type "String"
            }
        }
        if (Get-ItemProperty -Path $P -Name "PnPCapabilities" -ErrorAction SilentlyContinue)    { Set-Registry -Path $P -Name "PnPCapabilities" -Value 24 -Type "DWord" }
        if (Get-ItemProperty -Path $P -Name "WakeOnMagicPacketFromS5" -ErrorAction SilentlyContinue) { Set-Registry -Path $P -Name "WakeOnMagicPacketFromS5" -Value "2" -Type "String" }
        if (Get-ItemProperty -Path $P -Name "WolShutdownLinkSpeed" -ErrorAction SilentlyContinue)    { Set-Registry -Path $P -Name "WolShutdownLinkSpeed" -Value "2" -Type "String" }
    }
}

Set-Registry -Path "HKLM:\System\CurrentControlSet\Services\Dnscache\Parameters" -Name "DisableCoalescing" -Value 1 -Type "DWord"

# focus assist priority blob injection
status "configuring focus assist..." "step"
$PriorityBlob = [byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xDF,0xB8,0xB4,0xCC,0x06,0x2A,0x2B,0x0E,0xD0,0x03,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xCD,0x14,0x06,0x02,0x05,0x00,0x00,0x01,0x01,0x02,0x00,0x03,0x01,0x04,0x00,0xCC,0x32,0x12,0x05,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x53,0x00,0x63,0x00,0x72,0x00,0x65,0x00,0x65,0x00,0x6E,0x00,0x53,0x00,0x6B,0x00,0x65,0x00,0x74,0x00,0x63,0x00,0x68,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x29,0x57,0x00,0x69,0x00,0x6E,0x00,0x64,0x00,0x6F,0x00,0x77,0x00,0x73,0x00,0x2E,0x00,0x53,0x00,0x79,0x00,0x73,0x00,0x74,0x00,0x65,0x00,0x6D,0x00,0x2E,0x00,0x4E,0x00,0x65,0x00,0x61,0x00,0x72,0x00,0x53,0x00,0x68,0x00,0x61,0x00,0x72,0x00,0x65,0x00,0x45,0x00,0x78,0x00,0x70,0x00,0x65,0x00,0x72,0x00,0x69,0x00,0x65,0x00,0x6E,0x00,0x63,0x00,0x65,0x00,0x52,0x00,0x65,0x00,0x63,0x00,0x65,0x00,0x69,0x00,0x76,0x00,0x65,0x00,0x00,0x00,0x00,0x00)

Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current" -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\{[a-f0-9-]+\}\$' } | ForEach-Object {
        $guid = ($_.PSChildName -split '\$')[0]
        $targ = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\$guid`$windows.data.donotdisturb.quiethoursprofile`$quiethoursprofilelist\windows.data.donotdisturb.quiethoursprofile`$microsoft.quiethoursprofile.priorityonly"
        Set-Registry -Path $targ -Name "Data" -Value $PriorityBlob -Type "Binary"
    }

# cbs settings.dat hive
status "optimizing windows client session settings..." "step"
"AppActions","CrossDeviceResume","FESearchHost","SearchHost","SoftLandingTask","TextInputHost",
"WebExperienceHostApp","WindowsBackupClient","ShellExperienceHost","StartMenuExperienceHost",
"Widgets","WidgetService","MiniSearchHost" | ForEach-Object {
    Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

$SettingsDat = "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Settings\settings.dat"
if (Test-Path $SettingsDat) {
    & cmd.exe /c "reg load `"HKLM\Settings`" `"$SettingsDat`" 2>nul"
    if ($LASTEXITCODE -eq 0) {
        $State = "HKLM:\Settings\LocalState"
        $Val1  = [byte[]](0x01,0x61,0xed,0x11,0x34,0xf7,0x9f,0xdc,0x01)
        $Val0  = [byte[]](0x00,0x36,0xd0,0x88,0x8e,0xcd,0x93,0xdc,0x01)
        
        Set-Registry -Path "$State\DisabledApps"       -Name "Microsoft.Paint_8wekyb3d8bbwe"                 -Value $Val1 -Type "Binary"
        Set-Registry -Path "$State\DisabledApps"       -Name "Microsoft.Windows.Photos_8wekyb3d8bbwe"        -Value $Val1 -Type "Binary"
        Set-Registry -Path "$State\DisabledApps"       -Name "MicrosoftWindows.Client.CBS_cw5n1h2txyewy"     -Value $Val1 -Type "Binary"
        Set-Registry -Path "$State\DisabledApps"       -Name "Microsoft.YourPhone_8wekyb3d8bbwe"             -Value $Val1 -Type "Binary"
        
        Set-Registry -Path $State                      -Name "VideoAutoplay"                                 -Value $Val0 -Type "Binary"
        Set-Registry -Path $State                      -Name "EnableAppInstallNotifications"                 -Value $Val0 -Type "Binary"
        Set-Registry -Path $State                      -Name "SearchSuggestionsEnabled"                      -Value $Val0 -Type "Binary"
        Set-Registry -Path $State                      -Name "EnableCloudSearch"                             -Value $Val0 -Type "Binary"
        Set-Registry -Path $State                      -Name "NewsAndInterestsEnabled"                       -Value $Val0 -Type "Binary"
        Set-Registry -Path $State                      -Name "ShowRecentlyOpenedApps"                        -Value $Val0 -Type "Binary"
        Set-Registry -Path "$State\PersistentSettings" -Name "PersonalizationEnabled"                        -Value ([byte[]](0x00,0x0d,0x56,0xa1,0x8a,0xcd,0x93,0xdc,0x01)) -Type "Binary"
        [GC]::Collect()
        Start-Sleep -Seconds 1
        reg unload "HKLM\Settings" 2>$null | Out-Null
    }
}

# ── power plan ────────────────────────────────────────────────────────────────
status "deploying albus power plan..." "step"

$PowerSaverGUID = "a1841308-3541-4fab-bc81-f71556f20b4a"
& powercfg -restoredefaultschemes 2>&1 | Out-Null
& powercfg /SETACTIVE $PowerSaverGUID 2>&1 | Out-Null

$dupOut = & powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
$AlbusGUID = if ($dupOut -match '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $Matches[1] }
else {
    $AlbusGUID = "99999999-9999-9999-9999-999999999999"
    & powercfg /delete $AlbusGUID 2>&1 | Out-Null
    & powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $AlbusGUID 2>&1 | Out-Null
    $AlbusGUID
}

& powercfg /changename $AlbusGUID "Albus 2.0" "minimal latency, unparked cores, peak throughput." 2>&1 | Out-Null

# delete all other schemes
(& powercfg /l 2>$null | Out-String) -split "`r?`n" | ForEach-Object {
    if ($_ -match ':') {
        $parse = $_ -split ':'
        if ($parse.Count -gt 1) {
            $idx  = $parse[1].Trim().IndexOf('(')
            if ($idx -gt 0) {
                $guid = $parse[1].Trim().Substring(0, $idx).Trim()
                if ($guid -ne $AlbusGUID -and $guid -ne $PowerSaverGUID -and $guid.Length -ge 36) {
                    & powercfg /delete $guid 2>&1 | Out-Null
                }
            }
        }
    }
}

@(
    "0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0",    # hard disk turn off
    "0d7dbae2-4294-402a-ba8e-26777e8488cd 309dce9b-bef4-4119-9921-a851fb12f0f4 1",    # desktop background slideshow
    "19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0",    # wireless adapter
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0",    # sleep after
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0",    # allow hybrid sleep off
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 0",    # hibernate after
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 0",    # allow wake timers disable
    "2a737441-1930-4402-8d77-b2bebba308a3 0853a681-27c8-4100-a2fd-82013e970683 0",    # usb hub selective suspend timeout
    "2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0",    # usb selective suspend setting disabled
    "2a737441-1930-4402-8d77-b2bebba308a3 d4e98f31-5ffe-4ce1-be31-1b38b384c009 0",    # usb 3 link power management off
    "4f971e89-eebd-4455-a8de-9e59040e7347 a7066653-8d6c-40a8-910e-a1f54b84c7e5 2",    # start menu power button shut down
    "501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0",    # pci express link state pm off
    "54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100",  # min processor state
    "54533251-82be-4824-96c1-47b60b740d00 94d3a615-a899-4ac5-ae2b-e4d8f634367f 1",    # system cooling active
    "54533251-82be-4824-96c1-47b60b740d00 bc5038f7-23e0-4960-96da-33abaf5935ec 100",  # max processor state
    "54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100",  # unpark cpu cores min
    "54533251-82be-4824-96c1-47b60b740d00 ea062031-0e34-4ff1-9b6d-eb1059334028 100",  # unpark cpu cores max
    "54533251-82be-4824-96c1-47b60b740d00 36687f9e-e3a5-4dbf-b1dc-15eb381c6863 0",    # cpu energy performance preference
    "54533251-82be-4824-96c1-47b60b740d00 93b8b6dc-0698-4d1c-9ee4-0644e900c85d 0",    # heterogeneous thread scheduling
    "54533251-82be-4824-96c1-47b60b740d00 75b0ae3f-bce0-45a7-8c89-c9611c25e100 0",    # lock maximum processor frequency
    "7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e 600",  # display timeout 10 min
    "7516b95f-f776-4464-8c53-06167f40cc99 aded5e82-b909-4619-9949-f5d71dac0bcb 100",  # display brightness
    "7516b95f-f776-4464-8c53-06167f40cc99 f1fbfde2-a960-4165-9f88-50667911ce96 100",  # dimmed brightness
    "7516b95f-f776-4464-8c53-06167f40cc99 fbd9aa66-9553-4097-ba44-ed6e9d65eab8 0",    # adaptive brightness off
    "9596fb26-9850-41fd-ac3e-f7c3c00afd4b 10778347-1370-4ee0-8bbd-33bdacaade49 1",    # video playback bias
    "9596fb26-9850-41fd-ac3e-f7c3c00afd4b 34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4 0",    # optimize video quality
    "e276e160-7cb0-43c6-b20b-73f5dce39954 a1662ab2-9d34-4e53-ba8b-2639b9e20857 3",    # switchable graphics global maximize
    "e73a048d-bf27-4f12-9731-8b2076e8891f 5dbb7c9f-38e9-40d2-9749-4f8a0e9f640f 0",    # critical battery notification
    "e73a048d-bf27-4f12-9731-8b2076e8891f 637ea02f-bbcb-4015-8e2c-a1c7b9c0b546 0",    # critical battery action
    "e73a048d-bf27-4f12-9731-8b2076e8891f 8183ba9a-e910-48da-8769-14ae6dc1170a 0",    # low battery level
    "e73a048d-bf27-4f12-9731-8b2076e8891f 9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469 0",    # critical battery level
    "e73a048d-bf27-4f12-9731-8b2076e8891f bcded951-187b-4d05-bccc-f7e51960c258 0",    # low battery notification
    "e73a048d-bf27-4f12-9731-8b2076e8891f d8742dcb-3e6a-4b3c-b3fe-374623cdcf06 0",    # low battery action
    "e73a048d-bf27-4f12-9731-8b2076e8891f f3c5027d-cd16-4930-aa6b-90db844a8f00 0",    # reserve battery level
    "de830923-a562-41af-a086-e3a2c6bad2da 13d09884-f74e-474a-a852-b6bde8ad03a8 100",  # low screen brightness battery saver
    "de830923-a562-41af-a086-e3a2c6bad2da e69653ca-cf7f-4f05-aa73-cb833fa90ad4 0"     # turn battery saver on automatically
) | ForEach-Object {
    if ($_ -match '(?<s>[a-f0-9-]+)\s+(?<i>[a-f0-9-]+)\s+(?<v>\d+)') {
        $s = $Matches.s; $i = $Matches.i; $v = $Matches.v
        & powercfg /attributes $s $i -ATTRIB_HIDE 2>$null | Out-Null
        & { trap { continue }
            powercfg /setacvalueindex $AlbusGUID $s $i $v 2>$null | Out-Null
            powercfg /setdcvalueindex $AlbusGUID $s $i $v 2>$null | Out-Null
        }
    }
}

& powercfg /SETACTIVE $AlbusGUID 2>&1 | Out-Null
& powercfg /hibernate off 2>$null | Out-Null

Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled" -Value 0 -Type "DWord"
Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabledDefault" -Value 0 -Type "DWord"
Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0 -Type "DWord"
Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "PowerThrottlingOff" -Value 1 -Type "DWord"

Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore" -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Set-Registry -Path $_.PSPath -Name "AutoColorManagementEnabled" -Value 0 }

status "power plan deployed." "done"

# ── albusx 2.0 service ────────────────────────────────────────────────────────
status "deploying albusx 2.0 core engine..." "step"

$SvcName = "AlbusXSvc"
$ExePath  = "$env:SystemRoot\AlbusX.exe"
$CSPath   = "$env:SystemRoot\AlbusX.cs"
$CSC      = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$SrcURL   = "https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/albus/albus2.cs"

if (Get-Service $SvcName -ErrorAction SilentlyContinue) {
    Stop-Service $SvcName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $SvcName >$null 2>&1
    Start-Sleep -Seconds 1
}
if (Test-Path $ExePath) { Remove-Item $ExePath -Force -ErrorAction SilentlyContinue }

status "fetching albusx 2.0 source..." "info"
try { Invoke-WebRequest -Uri $SrcURL -OutFile $CSPath -UseBasicParsing -ErrorAction Stop } catch {
    status "failed to fetch albusx source." "warn"
}

if ((Test-Path $CSPath) -and (Test-Path $CSC)) {
    status "compiling albusx 2.0..." "info"
    & $CSC `
        -r:System.ServiceProcess.dll `
        -r:System.Configuration.Install.dll `
        -r:System.Management.dll `
        -r:Microsoft.Win32.Registry.dll `
        -out:"$ExePath" "$CSPath" >$null 2>&1
    Remove-Item $CSPath -Force -ErrorAction SilentlyContinue
}

if (Test-Path $ExePath) {
    New-Service -Name $SvcName `
        -BinaryPathName $ExePath `
        -DisplayName "AlbusX" `
        -Description "albus core engine 2.0 — precision timer, audio latency, memory, interrupt affinity, game profiles." `
        -StartupType Automatic `
        -ErrorAction SilentlyContinue | Out-Null

    & sc.exe failure $SvcName reset= 60 actions= restart/5000/restart/10000/restart/30000 >$null 2>&1
    Start-Service $SvcName -ErrorAction SilentlyContinue
    status "albusx 2.0 service is running." "done"
} else {
    status "albusx compilation failed. engine not deployed." "warn"
}

Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" -Name "GlobalTimerResolutionRequests" -Value 1 -Type "DWord"

# ── exploit guard ─────────────────────────────────────────────────────────────
status "disabling system-wide exploit guard mitigations..." "step"

(Get-Command 'Set-ProcessMitigation' -ErrorAction SilentlyContinue).Parameters['Disable'].Attributes.ValidValues |
    ForEach-Object { Set-ProcessMitigation -SYSTEM -Disable $_.ToString() -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null }

$KernelPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel"
$AuditLen   = if ((Get-ItemProperty $KernelPath -Name "MitigationAuditOptions" -ErrorAction SilentlyContinue).MitigationAuditOptions) {
    (Get-ItemProperty $KernelPath -Name "MitigationAuditOptions").MitigationAuditOptions.Length
} else { 38 }
[byte[]]$MitigPayload = [System.Linq.Enumerable]::Repeat([byte]34, $AuditLen)

"fontdrvhost.exe","dwm.exe","lsass.exe","svchost.exe","WmiPrvSE.exe","winlogon.exe", "csrss.exe","audiodg.exe","services.exe","explorer.exe","taskhostw.exe","sihost.exe" | ForEach-Object {
    $P = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$_"
    Set-Registry -Path $P -Name "MitigationOptions"      -Value $MitigPayload -Type "Binary"
    Set-Registry -Path $P -Name "MitigationAuditOptions" -Value $MitigPayload -Type "Binary"
}
Set-Registry -Path $KernelPath -Name "MitigationOptions"      -Value $MitigPayload -Type "Binary"
Set-Registry -Path $KernelPath -Name "MitigationAuditOptions" -Value $MitigPayload -Type "Binary"

if ((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Manufacturer -eq 'GenuineIntel') {
    Set-Registry -Path $KernelPath -Name "DisableTSX" -Value 0 -Type "DWord"
} else {
    Remove-ItemProperty -Path $KernelPath -Name "DisableTSX" -ErrorAction SilentlyContinue
}

# ── MSI interrupt mode ────────────────────────────────────────────────────────
status "enabling msi mode for pci devices..." "step"

# ── MSI interrupt mode ────────────────────────────────────────────────────────
status "enabling msi mode for pci devices..." "step"

Get-PnpDevice -InstanceId "PCI\*" -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -match 'OK|Unknown' } | ForEach-Object {
        $P = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management"
        Set-Registry -Path "$P\MessageSignaledInterruptProperties" -Name "MSISupported" -Value 1
        if (Test-Path "$P\Affinity Policy") {
            Remove-ItemProperty -Path "$P\Affinity Policy" -Name "DevicePriority" -ErrorAction SilentlyContinue
        }
    }

# ── ghost device cleanup ──────────────────────────────────────────────────────
status "removing ghost pnp devices..." "step"

Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Present -and $_.InstanceId -notmatch '^(ROOT|SWD|HTREE|DISPLAY|BTHENUM)\\' } |
    ForEach-Object { pnputil /remove-device $_.InstanceId /quiet >$null 2>&1 }

# ── disk cache ────────────────────────────────────────────────────────────────
status "optimizing disk write-cache..." "step"

Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceType -ne "USB" -and $_.PNPDeviceID } | ForEach-Object {
        $P = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters\Disk"
        Set-Registry -Path $P -Name "UserWriteCacheSetting" -Value 1
        Set-Registry -Path $P -Name "CacheIsPowerProtected" -Value 1
    }

# ── device power saving ───────────────────────────────────────────────────────
status "disabling aggressive device power saving..." "step"

Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -match 'OK|Unknown' } | ForEach-Object {
    $P = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters"
    Set-Registry -Path "$P\WDF" -Name "IdleInWorkingState" -Value 0
    "SelectiveSuspendEnabled","SelectiveSuspendOn","EnhancedPowerManagementEnabled","WaitWakeEnabled" | ForEach-Object {
        Set-Registry -Path $P -Name $_ -Value 0
    }
}

# ── winevt diagnostic channels ────────────────────────────────────────────────
status "disabling winevt diagnostic channels..." "step"
try {
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $ep = Get-ItemProperty -Path $_.PSPath -Name 'Enabled' -ErrorAction SilentlyContinue
            if ($null -ne $ep -and $ep.Enabled -eq 1) {
                Set-ItemProperty -Path $_.PSPath -Name 'Enabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
} catch { }

# ── ntfs ──────────────────────────────────────────────────────────────────────
status "optimizing ntfs..." "step"
& fsutil behavior set disable8dot3 1 2>&1 | Out-Null
& fsutil behavior set disabledeletenotify 0 2>&1 | Out-Null
& fsutil behavior set disablelastaccess 1 2>&1 | Out-Null
& fsutil behavior set encryptpagingfile 0 2>&1 | Out-Null

# ── bcdedit ───────────────────────────────────────────────────────────────────
status "applying boot optimizations..." "step"
& bcdedit /deletevalue useplatformclock 2>&1 | Out-Null
& bcdedit /deletevalue useplatformtick 2>&1 | Out-Null
& bcdedit /set bootmenupolicy legacy 2>&1 | Out-Null
& bcdedit /timeout 10 2>&1 | Out-Null
& label C: Albus 2>&1 | Out-Null
& bcdedit /set "{current}" description "Albus 2.0" 2>&1 | Out-Null

# ── ui: true black theme ──────────────────────────────────────────────────────
status "applying true black ui..." "step"

Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction SilentlyContinue
$BlackFile = "C:\Windows\Wallpaper.jpg"
if (-not (Test-Path $BlackFile)) {
    try {
        $SW  = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width
        $SH  = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Height
        $Bmp = New-Object System.Drawing.Bitmap $SW, $SH
        $Gfx = [System.Drawing.Graphics]::FromImage($Bmp)
        $Gfx.FillRectangle([System.Drawing.Brushes]::Black, 0, 0, $SW, $SH)
        $Gfx.Dispose(); $Bmp.Save($BlackFile); $Bmp.Dispose()
    } catch { }
}

Set-Registry "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" "LockScreenImagePath" $BlackFile "String"
Set-Registry "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" "LockScreenImageStatus" 1 "DWord"

rundll32.exe user32.dll, UpdatePerUserSystemParameters

@("$env:SystemDrive\ProgramData\Microsoft\User Account Pictures", "$env:AppData\Microsoft\Windows\AccountPictures") | ForEach-Object {
    if (Test-Path $_) {
        Get-ChildItem $_ -Include *.png,*.bmp,*.jpg -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $Img = [System.Drawing.Bitmap]::FromFile($_.FullName)
                $W = $Img.Width; $H = $Img.Height; $Img.Dispose()
                $New = New-Object System.Drawing.Bitmap $W, $H
                $G   = [System.Drawing.Graphics]::FromImage($New)
                $G.Clear([System.Drawing.Color]::Black); $G.Dispose()
                $Ext = [System.IO.Path]::GetExtension($_.FullName).ToLower()
                $Fmt = switch ($Ext) { ".png" { [System.Drawing.Imaging.ImageFormat]::Png }; ".bmp" { [System.Drawing.Imaging.ImageFormat]::Bmp }; default { [System.Drawing.Imaging.ImageFormat]::Jpeg } }
                $New.Save($_.FullName, $Fmt); $New.Dispose()
            } catch { }
        }
    }
}

Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -Recurse -ErrorAction SilentlyContinue | ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null }

Set-Registry "-HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" "" ""
Remove-Item "$env:USERPROFILE\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

@("-HKCR:\Folder\shell\pintohome",
  "-HKCR:\*\shell\pintohomefile",
  "-HKCR:\exefile\shellex\ContextMenuHandlers\Compatibility",
  "-HKCR:\Folder\ShellEx\ContextMenuHandlers\Library Location",
  "-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing",
  "-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo",
  "-HKCR:\UserLibraryFolder\shellex\ContextMenuHandlers\SendTo") | ForEach-Object {
    Set-Registry -Path $_ -Name "" -Value ""
}
Set-Registry "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" "NoCustomizeThisFolder" 1
@("{9F156763-7844-4DC4-B2B1-901F640F5155}","{09A47860-11B0-4DA5-AFA5-26D86198A780}","{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}") | ForEach-Object {
    Set-Registry "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked" $_ "" "String"
}

# start menu (win11)
if ([Environment]::OSVersion.Version.Major -eq 10 -and [Environment]::OSVersion.Version.Build -ge 22000) {
    $start2 = "$env:USERPROFILE\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin"
    Remove-Item $start2 -Force -ErrorAction SilentlyContinue | Out-Null
    [System.IO.File]::WriteAllBytes($start2, [Convert]::FromBase64String("AgAAABAAAAD9////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="))
}

Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue

# ── uwp debloat ───────────────────────────────────────────────────────────────
status "removing uwp bloat..." "step"

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
        $pfn = $_.PackageFullName
        $pfamily = $_.PackageFamilyName
        Remove-AppxPackage -Package $pfn -AllUsers -ErrorAction Stop | Out-Null

        $deprovPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$pfamily"
        if (-not (Test-Path $deprovPath)) { New-Item -Path $deprovPath -Force | Out-Null }
        
        Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -eq $pfn } | ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null
        }
    } catch { }
}

try {
    Get-WindowsCapability -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Installed' -and
        $_.Name -notlike '*Ethernet*' -and $_.Name -notlike '*MSPaint*' -and
        $_.Name -notlike '*Notepad*'  -and $_.Name -notlike '*Wifi*'    -and
        $_.Name -notlike '*NetFX3*'   -and $_.Name -notlike '*VBSCRIPT*' -and
        $_.Name -notlike '*WMIC*'     -and $_.Name -notlike '*ShellComponents*'
    } | ForEach-Object { try { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null } catch { } }
} catch { }

try {
    Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Enabled' -and
        $_.FeatureName -notlike '*DirectPlay*'       -and $_.FeatureName -notlike '*LegacyComponents*' -and
        $_.FeatureName -notlike '*NetFx*'            -and $_.FeatureName -notlike '*SearchEngine-Client*' -and
        $_.FeatureName -notlike '*Windows-Defender*' -and $_.FeatureName -notlike '*WirelessNetworking*'
    } | ForEach-Object { try { Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null } catch { } }
} catch { }

# ── edge & onedrive removal ───────────────────────────────────────────────────
status "removing edge and onedrive..." "step"

# edge
"backgroundTaskHost","Copilot","MicrosoftEdgeUpdate","msedge","msedgewebview2","WidgetService","Widgets" |
    ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Get-Process | Where-Object { $_.ProcessName -like "*edge*" } | Stop-Process -Force -ErrorAction SilentlyContinue

"HKCU:\SOFTWARE","HKLM:\SOFTWARE","HKCU:\SOFTWARE\Policies","HKLM:\SOFTWARE\Policies",
"HKLM:\SOFTWARE\WOW6432Node","HKLM:\SOFTWARE\WOW6432Node\Policies" | ForEach-Object {
    Remove-Item "$_\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue
}

"LocalApplicationData","ProgramFilesX86","ProgramFiles" | ForEach-Object {
    Get-ChildItem "$([Environment]::GetFolderPath($_))\Microsoft\EdgeUpdate\*.*.*.*\MicrosoftEdgeUpdate.exe" -Recurse -ErrorAction SilentlyContinue
} | ForEach-Object {
    if (Test-Path $_.FullName) {
        Start-Process -Wait $_.FullName -ArgumentList "/unregsvc" -WindowStyle Hidden
        Start-Process -Wait $_.FullName -ArgumentList "/uninstall" -WindowStyle Hidden
    }
}

try {
    $euKey = Get-Item "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" -ErrorAction SilentlyContinue
    if ($euKey) {
        $uStr = $euKey.GetValue("UninstallString") + " --force-uninstall"
        Start-Process cmd.exe -ArgumentList "/c $uStr" -WindowStyle Hidden -Wait
    }
} catch { }

@("$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
  "$env:ProgramFiles (x86)\Microsoft") | ForEach-Object {
    if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
}
 
Get-Service | Where-Object { $_.Name -match 'Edge' } | ForEach-Object {
    & sc.exe stop $_.Name >$null 2>&1
    & sc.exe delete $_.Name >$null 2>&1
}
 
# legacy edge (win10 dism)
$LegacyEdge = (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages" -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like "*Microsoft-Windows-Internet-Browser-Package*~~*" }).PSChildName
if ($LegacyEdge) {
    $LPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$LegacyEdge"
    Set-Registry -Path $LPath -Name "Visibility" -Value 1
    $OwnersPath = "$LPath\Owners"
    if (Test-Path $OwnersPath) { Remove-Item $OwnersPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
    dism.exe /online /Remove-Package /PackageName:$LegacyEdge /quiet /norestart >$null 2>&1
}
 
# onedrive
Stop-Process -Force -Name OneDrive -ErrorAction SilentlyContinue | Out-Null
@("$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") | ForEach-Object {
    if (Test-Path $_) { Start-Process -Wait $_ -ArgumentList "/uninstall" -WindowStyle Hidden }
}
Get-ScheduledTask | Where-Object { $_.TaskName -match 'OneDrive' } |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
 
# update health tools
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object { $_.DisplayName -match "Microsoft Update Health Tools" } | ForEach-Object {
        if ($_.PSChildName) {
            Start-Process "msiexec.exe" -ArgumentList "/x $($_.PSChildName) /qn /norestart" -Wait -NoNewWindow
        }
    }
& sc.exe delete "uhssvc" >$null 2>&1
Unregister-ScheduledTask -TaskName PLUGScheduler -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
 
# braille service
& sc.exe stop "brlapi" >$null 2>&1
& sc.exe delete "brlapi" >$null 2>&1
$BrlPath = "$env:SystemRoot\brltty"
if (Test-Path $BrlPath) {
    takeown /f "$BrlPath" /r /d y >$null 2>&1
    icacls "$BrlPath" /grant *S-1-5-32-544:F /t >$null 2>&1
    Remove-Item $BrlPath -Recurse -Force -ErrorAction SilentlyContinue
}
 
# gameinput
$GameInput = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object { $_.DisplayName -like "*Microsoft GameInput*" }
if ($GameInput -and $GameInput.PSChildName) {
    Start-Process "msiexec.exe" -ArgumentList "/x $($GameInput.PSChildName) /qn /norestart" -Wait -NoNewWindow
}
 
status "edge, onedrive and legacy tools removed." "done"
 
# ── startup & scheduled task cleanup ─────────────────────────────────────────
status "clearing 3rd party startup entries and tasks..." "step"
 
@("HKCU:\Software\Microsoft\Windows\CurrentVersion\RunNotification",
  "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
  "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
  "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
  "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce",
  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run") | ForEach-Object {
    if (Test-Path $_) {
        $realPath = $_.Replace("HKCU:", "HKEY_CURRENT_USER").Replace("HKLM:", "HKEY_LOCAL_MACHINE")
        reg.exe delete "$realPath" /f /va >$null 2>&1
    }
}
 
@("$env:AppData\Microsoft\Windows\Start Menu\Programs\Startup",
  "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") | ForEach-Object {
    if (Test-Path $_) { Remove-Item "$_\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
}
 
$TaskTree = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree"
Get-ChildItem $TaskTree -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -ne "Microsoft" } |
    ForEach-Object { Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
 
$TaskFiles = "$env:SystemRoot\System32\Tasks"
Get-ChildItem $TaskFiles -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "Microsoft" } |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
 
# ── gpu driver installation ───────────────────────────────────────────────────
function show-gpu-menu {
    Write-Host ""
    Write-Host " select graphics driver" -ForegroundColor Yellow
    Write-Host " 1. nvidia"              -ForegroundColor Green
    Write-Host " 2. amd"                 -ForegroundColor Red
    Write-Host " 3. skip"                -ForegroundColor Gray
    Write-Host ""
}
 
:gpu while ($true) {
    show-gpu-menu
    Write-Host "ask  - " -NoNewline -ForegroundColor Yellow
    $choice = Read-Host "enter choice"
    Write-Host ""
 
    if ($choice -notmatch '^[1-3]$') { continue }
 
    switch ($choice) {
        # ── nvidia ────────────────────────────────────────────────────────────
        "1" {
            status "starting nvidia driver procedure..." "step"
 
            Start-Process "https://www.nvidia.com/en-us/drivers"
            Write-Host ""
            Write-Host " download the driver then press any key to continue..." -ForegroundColor Yellow
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
 
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title  = "select nvidia driver installer"
            $dlg.Filter = "Executable (*.exe)|*.exe|All Files (*.*)|*.*"
 
            if ($dlg.ShowDialog() -ne "OK") { status "cancelled." "warn"; break }
 
            $InstallFile  = $dlg.FileName
            $ExtractPath  = "$env:SystemRoot\Temp\NVIDIA"
            $ZipExe       = "C:\Program Files\7-Zip\7z.exe"
 
            if (-not (Test-Path $ZipExe)) { status "7-zip not found. debloat aborted." "fail"; break }
 
            status "extracting driver..." "step"
            if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
            & $ZipExe x "$InstallFile" -o"$ExtractPath" -y | Out-Null
 
            status "stripping bloat (whitelist: display.driver + nvi2)..." "step"
            $Whitelist = @("Display.Driver","NVI2","EULA.txt","ListDevices.txt","setup.cfg","setup.exe")
            Get-ChildItem $ExtractPath | Where-Object { $Whitelist -notcontains $_.Name } |
                ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
 
            # patch setup.cfg — remove consent/eula lines
            $CfgPath = Join-Path $ExtractPath "setup.cfg"
            if (Test-Path $CfgPath) {
                (Get-Content $CfgPath) |
                    Where-Object { $_ -notmatch 'EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile' } |
                    Set-Content $CfgPath -Force
            }
 
            status "installing driver silently..." "step"
            $Setup = "$ExtractPath\setup.exe"
            if (-not (Test-Path $Setup)) { status "setup.exe not found." "fail"; break }
 
            Start-Process $Setup -ArgumentList "-s -noreboot -noeula -clean" -Wait -NoNewWindow
 
            status "applying nvidia registry tweaks..." "step"
 
            # p-state, hdcp, profiling
            Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}" -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
                    Set-Registry -Path $_.PSPath -Name "DisableDynamicPstate"   -Value 1
                    Set-Registry -Path $_.PSPath -Name "RMHdcpKeyglobZero"      -Value 1
                    Set-Registry -Path $_.PSPath -Name "RmProfilingAdminOnly"   -Value 0
                }
 
            Set-Registry "HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak" "NvCplPhysxAuto"       0
            Set-Registry "HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak" "NvDevToolsVisible"    1
            Set-Registry "HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak" "RmProfilingAdminOnly" 0
            Set-Registry "HKCU:\Software\NVIDIA Corporation\NvTray"                               "StartOnLogin"         0
            Set-Registry "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS"                   "EnableGR535"          0
            Set-Registry "HKLM:\SYSTEM\ControlSet001\Services\nvlddmkm\Parameters\FTS"            "EnableGR535"          0
            Set-Registry "HKCU:\Software\NVIDIA Corporation\NVControlPanel2\Client"               "OptInOrOutPreference"  0
 
            $DRSPath = "C:\ProgramData\NVIDIA Corporation\Drs"
            if (Test-Path $DRSPath) { Get-ChildItem $DRSPath -Recurse | Unblock-File -ErrorAction SilentlyContinue }
 
            # nvidia profile inspector
            status "fetching nvidia profile inspector..." "step"
            $InspectorZip = "$env:SystemRoot\Temp\nvidiaProfileInspector.zip"
            $InspectorDir = "$env:SystemRoot\Temp\nvidiaProfileInspector"
 
            try {
                $rel   = Invoke-RestMethod "https://api.github.com/repos/Orbmu2k/nvidiaProfileInspector/releases/latest" -ErrorAction Stop
                $asset = ($rel.assets | Where-Object { $_.name -like "*.zip" })[0]
                if ($asset) {
                    Invoke-WebRequest $asset.browser_download_url -OutFile $InspectorZip -UseBasicParsing -ErrorAction Stop
                    & $ZipExe x "$InspectorZip" -o"$InspectorDir" -y | Out-Null
                }
            } catch { status "failed to download nvidia profile inspector." "warn" }
 
            $NIPContent = @'
<?xml version="1.0" encoding="utf-16"?>
<ArrayOfProfile>
  <Profile>
    <ProfileName>Base Profile</ProfileName>
    <Executeables />
    <Settings>
      <ProfileSetting><SettingNameInfo> </SettingNameInfo><SettingID>390467</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Shader Cache</SettingNameInfo><SettingID>1675263</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture filtering - Negative LOD bias</SettingNameInfo><SettingID>1686376</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture filtering - Trilinear optimization</SettingNameInfo><SettingID>3066610</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Sharpening Value</SettingNameInfo><SettingID>3070157</SettingID><SettingValue>50</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Sharpening - Denoising Factor</SettingNameInfo><SettingID>3070158</SettingID><SettingValue>17</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Sharpening Filter</SettingNameInfo><SettingID>5867816</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vertical Sync Tear Control</SettingNameInfo><SettingID>5912412</SettingID><SettingValue>2525368439</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Preferred refresh rate</SettingNameInfo><SettingID>6600001</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>NVIDIA Predefined Ambient Occlusion Usage</SettingNameInfo><SettingID>6701881</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo> </SettingNameInfo><SettingID>6710836</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo> </SettingNameInfo><SettingID>6710885</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Ambient Occlusion</SettingNameInfo><SettingID>6714153</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo> </SettingNameInfo><SettingID>6776373</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo> </SettingNameInfo><SettingID>6776937</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Maximum pre-rendered frames</SettingNameInfo><SettingID>8102046</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture filtering - Anisotropic filter optimization</SettingNameInfo><SettingID>8703344</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>SILK Smoothness</SettingNameInfo><SettingID>9990737</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Enable sample interleaving (MFAA)</SettingNameInfo><SettingID>10011052</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vertical Sync</SettingNameInfo><SettingID>11041231</SettingID><SettingValue>138504007</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Sharpening Value for NIS 2.0</SettingNameInfo><SettingID>11250465</SettingID><SettingValue>50</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Enable NIS 2.0</SettingNameInfo><SettingID>11250721</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Enable NIS2 App Count</SettingNameInfo><SettingID>11250737</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Shader disk cache maximum size</SettingNameInfo><SettingID>11306135</SettingID><SettingValue>4294967295</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture filtering - Quality</SettingNameInfo><SettingID>13510289</SettingID><SettingValue>20</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo> </SettingNameInfo><SettingID>14019014</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo> </SettingNameInfo><SettingID>14019015</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Texture filtering - Anisotropic sample optimization</SettingNameInfo><SettingID>15151633</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Virtual Reality pre-rendered frames</SettingNameInfo><SettingID>269553971</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Whisper Mode</SettingNameInfo><SettingID>269573258</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Whisper Mode Application FPS</SettingNameInfo><SettingID>269573259</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Flag to control smooth AFR behavior</SettingNameInfo><SettingID>270198627</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic filtering setting</SettingNameInfo><SettingID>270426537</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>SLI indicator</SettingNameInfo><SettingID>271085649</SettingID><SettingValue>877871204</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>NVIDIA predefined SLI mode</SettingNameInfo><SettingID>271830721</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>NVIDIA predefined SLI mode on DirectX 10</SettingNameInfo><SettingID>271830722</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>SLI rendering mode</SettingNameInfo><SettingID>271830737</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Number of GPUs to use on SLI rendering mode</SettingNameInfo><SettingID>271834321</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>NVIDIA predefined number of GPUs to use on SLI rendering mode</SettingNameInfo><SettingID>271834322</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>NVIDIA predefined number of GPUs to use on SLI rendering mode on DirectX 10</SettingNameInfo><SettingID>271834323</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>NVIDIA Predefined FXAA Usage</SettingNameInfo><SettingID>271895433</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>List of Universal GPU ids</SettingNameInfo><SettingID>271929336</SettingID><SettingValue>none</SettingValue><ValueType>String</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>No override of Anisotropic filtering</SettingNameInfo><SettingID>272354485</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>NVIDIA Quality upscaling</SettingNameInfo><SettingID>272909380</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Application Profile Notification Popup Timeout</SettingNameInfo><SettingID>272979126</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Power management mode</SettingNameInfo><SettingID>274197361</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Do not display this profile in the Control Panel</SettingNameInfo><SettingID>275602687</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Enable FXAA</SettingNameInfo><SettingID>276089202</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Enable Ansel</SettingNameInfo><SettingID>276158834</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - SLI AA</SettingNameInfo><SettingID>276495451</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Gamma correction</SettingNameInfo><SettingID>276652957</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Mode</SettingNameInfo><SettingID>276757595</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Platform Boost</SettingNameInfo><SettingID>277041150</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>FRL Low Latency</SettingNameInfo><SettingID>277041152</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Frame Rate Limiter</SettingNameInfo><SettingID>277041154</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Background Application Max Frame Rate</SettingNameInfo><SettingID>277041157</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Background Application Max Frame Rate only for NVCPL to maintain the previous slider value when the BG_FRL_FPS is set to Disabled.</SettingNameInfo><SettingID>277041158</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Frame Rate Limiter for NVCPL</SettingNameInfo><SettingID>277041162</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Toggle the VRR global feature</SettingNameInfo><SettingID>278196567</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Display the PhysX indicator</SettingNameInfo><SettingID>278196591</SettingID><SettingValue>877871204</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>VRR requested state</SettingNameInfo><SettingID>278196727</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Display the VRR Overlay Indicator</SettingNameInfo><SettingID>278262127</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>G-SYNC</SettingNameInfo><SettingID>279476652</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Variable refresh Rate</SettingNameInfo><SettingID>279476686</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>G-SYNC</SettingNameInfo><SettingID>279476687</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo> </SettingNameInfo><SettingID>281106605</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Anisotropic filtering mode</SettingNameInfo><SettingID>282245910</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Transparency Supersampling</SettingNameInfo><SettingID>282364549</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Setting</SettingNameInfo><SettingID>282555346</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Behavior Flags</SettingNameInfo><SettingID>283958146</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Optimus flags for enabled applications</SettingNameInfo><SettingID>284810368</SettingID><SettingValue>16</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Enable application for Optimus</SettingNameInfo><SettingID>284810369</SettingID><SettingValue>16</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Shim Rendering Mode Options per application for Optimus</SettingNameInfo><SettingID>284810372</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Transparency Multisampling</SettingNameInfo><SettingID>284962204</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Memory Allocation Policy</SettingNameInfo><SettingID>286335539</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Overlay Indicator</SettingNameInfo><SettingID>286335574</SettingID><SettingValue>51</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Stereo - swap mode</SettingNameInfo><SettingID>288568115</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Enable G-SYNC globally</SettingNameInfo><SettingID>294973784</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Stereo - Enable</SettingNameInfo><SettingID>296394393</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Stereo - Swap eyes</SettingNameInfo><SettingID>296633180</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Stereo - Display mode</SettingNameInfo><SettingID>300489313</SettingID><SettingValue>4294967295</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Buffer-flipping mode</SettingNameInfo><SettingID>538927519</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Force Stereo shuttering</SettingNameInfo><SettingID>541956620</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Enable overlay</SettingNameInfo><SettingID>543959236</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>OpenGL GDI compatibility</SettingNameInfo><SettingID>544392611</SettingID><SettingValue>2</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo /><SettingID>544543941</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Antialiasing - Line gamma</SettingNameInfo><SettingID>545898348</SettingID><SettingValue>16</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Deep color for 3D applications</SettingNameInfo><SettingID>546816758</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Exported Overlay pixel types</SettingNameInfo><SettingID>547022447</SettingID><SettingValue>1</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Unified back/depth buffer</SettingNameInfo><SettingID>547524693</SettingID><SettingValue>4294967295</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Threaded optimization</SettingNameInfo><SettingID>549528094</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Preferred OpenGL GPU</SettingNameInfo><SettingID>550564838</SettingID><SettingValue>autoselect</SettingValue><ValueType>String</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Vulkan/OpenGL present method</SettingNameInfo><SettingID>550932728</SettingID><SettingValue>2</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Triple buffering</SettingNameInfo><SettingID>553505273</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Extension String version</SettingNameInfo><SettingID>553612435</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo /><SettingID>4294967295</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
    </Settings>
  </Profile>
</ArrayOfProfile>
'@
            $NIPPath = "$env:SystemRoot\Temp\albus.nip"
            $NIPContent | Set-Content $NIPPath -Force
 
            $InspectorExe = Get-ChildItem $InspectorDir -Filter "*nvidiaProfileInspector.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($InspectorExe) {
                Start-Process $InspectorExe.FullName -ArgumentList "-silentImport `"$NIPPath`"" -Wait -NoNewWindow
            }
 
            status "re-applying gpu msi mode..." "step"
            Start-Sleep -Seconds 2
            Get-PnpDevice -InstanceId "PCI\*" -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -match 'OK|Unknown' } | ForEach-Object {
                    $P = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management"
                    Set-Registry -Path "$P\MessageSignaledInterruptProperties" -Name "MSISupported" -Value 1
                    if (Test-Path "$P\Affinity Policy") {
                    Remove-ItemProperty -Path "$P\Affinity Policy" -Name "DevicePriority" -ErrorAction SilentlyContinue
        }     
    }
            # mpo fix
            Set-Registry "HKLM:\SOFTWARE\Microsoft\Windows\DWM" "OverlayTestMode" 5
            
            status "nvidia driver installation complete." "done"
            break
        }
 
        # ── amd ───────────────────────────────────────────────────────────────
        "2" {
            status "starting amd driver procedure..." "step"
 
            Start-Process "https://www.amd.com/en/support/download/drivers.html"
            Write-Host ""
            Write-Host " download the adrenalin driver then press any key to continue..." -ForegroundColor Yellow
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
 
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.OpenFileDialog
            $dlg.Title  = "select amd driver installer"
            $dlg.Filter = "Executable (*.exe)|*.exe|All Files (*.*)|*.*"
 
            if ($dlg.ShowDialog() -ne "OK") { status "cancelled." "warn"; break }
 
            $InstallFile = $dlg.FileName
            $ExtractPath = "$env:SystemRoot\Temp\amddriver"
            $ZipExe      = "C:\Program Files\7-Zip\7z.exe"
 
            if (-not (Test-Path $ZipExe)) { status "7-zip not found. debloat aborted." "fail"; break }
 
            status "extracting amd installer..." "step"
            if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
            & $ZipExe x "$InstallFile" -o"$ExtractPath" -y | Out-Null
 
            # patch xml — disable telemetry & uep components
            @("Config\AMDAUEPInstaller.xml","Config\AMDCOMPUTE.xml","Config\AMDLinkDriverUpdate.xml",
              "Config\AMDRELAUNCHER.xml","Config\AMDUpdater.xml","Config\AMDUWPLauncher.xml",
              "Config\InstallUEP.xml","Config\ModifyLinkUpdate.xml") | ForEach-Object {
                $xp = Join-Path $ExtractPath $_
                if (Test-Path $xp) {
                    $c = Get-Content $xp -Raw
                    $c = $c -replace '<Enabled>true</Enabled>', '<Enabled>false</Enabled>'
                    Set-Content $xp -Value $c -NoNewline
                }
            }
 
            # patch json — set InstallByDefault: No
            @("Config\InstallManifest.json","Bin64\cccmanifest_64.json") | ForEach-Object {
                $jp = Join-Path $ExtractPath $_
                if (Test-Path $jp) {
                    $c = Get-Content $jp -Raw
                    $c = $c -replace '"InstallByDefault"\s*:\s*"Yes"', '"InstallByDefault" : "No"'
                    Set-Content $jp -Value $c -NoNewline
                }
            }
 
            status "installing amd driver..." "step"
            $Setup = "$ExtractPath\Bin64\ATISetup.exe"
            if (Test-Path $Setup) {
                Start-Process -Wait $Setup -ArgumentList "-INSTALL -VIEW:2" -WindowStyle Hidden
            }
 
            status "cleaning amd bloatware..." "step"
 
            Set-Registry "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"     "AMDNoiseSuppression" "-"
            Set-Registry "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" "StartRSX"            "-"
            Unregister-ScheduledTask -TaskName "StartCN" -Confirm:$false -ErrorAction SilentlyContinue
 
            "AMD Crash Defender Service","amdfendr","amdfendrmgr","amdacpbus","AMDSAFD","AtiHDAudioService" | ForEach-Object {
                & sc.exe stop   $_ >$null 2>&1
                & sc.exe delete $_ >$null 2>&1
            }
 
            Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Bug Report Tool" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item "$env:SystemDrive\Windows\SysWOW64\AMDBugReportTool.exe" -Force -ErrorAction SilentlyContinue | Out-Null
 
            $AMDMgr = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
                Where-Object { $_.DisplayName -match "AMD Install Manager" }
            if ($AMDMgr) { Start-Process "msiexec.exe" -ArgumentList "/x $($AMDMgr.PSChildName) /qn /norestart" -Wait -NoNewWindow }
 
            $RSPath = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Software$([char]0xA789) Adrenalin Edition"
            if (Test-Path $RSPath) {
                Move-Item "$RSPath\*.lnk" "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue
                Remove-Item $RSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-Item "$env:SystemDrive\AMD" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
 
            # amd registry settings
            status "applying amd performance settings..." "step"

            Set-Registry "HKCU:\Software\AMD\CN" "AutoUpdate"                 0
            Set-Registry "HKCU:\Software\AMD\CN" "SystemTray"                 "false" "String"
            Set-Registry "HKCU:\Software\AMD\CN" "CN_Hide_Toast_Notification" "true"  "String"
            Set-Registry "HKCU:\Software\AMD\CN" "AnimationEffect"            "false" "String"

            $GpuBase = "HKLM:\System\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}"
            Get-ChildItem $GpuBase -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
                $P = $_.PSPath
                # general & analytics
                Set-Registry $P "ReportAnalytics"            0
                Set-Registry $P "NotifySubscription"         0
                Set-Registry $P "AllowSubscription"          0
                Set-Registry $P "ShowReleaseNotes"           0
                # performance & stutter
                Set-Registry $P "StutterMode"                0
                Set-Registry $P "KMD_DeLagEnabled"           1
                Set-Registry $P "DalDisableStutter"          1
                Set-Registry $P "KMD_EnableAmdFendrOptions"  0
                Set-Registry $P "KMD_ChillEnabled"           0
                Set-Registry $P "KMD_FramePacingSupport"     0
                Set-Registry $P "KMD_RadeonBoostEnabled"     0
                Set-Registry $P "DisableBlockWrite"          1
                Set-Registry $P "DisableFBCSupport"          1
                Set-Registry $P "DisableFBCForFullScreenApp" 1
                # powerplay
                Set-Registry $P "PP_Force3DPerformanceMode"      1
                Set-Registry $P "PP_ForceHighDPMLevel"           1
                Set-Registry $P "PP_SclkDeepSleepDisable"        1
                Set-Registry $P "PP_GfxOffControl"               0
                Set-Registry $P "PP_ThermalAutoThrottlingEnable" 0
                Set-Registry $P "PP_EnableRaceToIdle"            0
                # ulps
                Set-Registry $P "EnableUlps"                 0
                Set-Registry $P "EnableUlps_NA"              "0" "String"
                Set-Registry $P "PP_DisableULPS"             1
                Set-Registry $P "KMD_EnableULPS"             0
                Set-Registry $P "KMD_ForceD3ColdSupport"     0
                # aspm
                Set-Registry $P "EnableAspmL0s"              0
                Set-Registry $P "EnableAspmL1"               0
                Set-Registry $P "EnableAspmL1SS"             0
                Set-Registry $P "DisableAspmL0s"             1
                Set-Registry $P "DisableAspmL1"              1
                # clock gating
                Set-Registry $P "DisableGfxClockGating"                   1
                Set-Registry $P "DisableVceClockGating"                   1
                Set-Registry $P "DisableSamuClockGating"                  1
                Set-Registry $P "DisableRomMGCGClockGating"               1
                Set-Registry $P "DisableGfxCoarseGrainClockGating"        1
                Set-Registry $P "DisableGfxMediumGrainClockGating"        1
                Set-Registry $P "DisableGfxFineGrainClockGating"          1
                Set-Registry $P "DisableHdpMGClockGating"                 1
                Set-Registry $P "EnableVceSwClockGating"                  0
                Set-Registry $P "EnableUvdClockGating"                    0
                Set-Registry $P "EnableGfxClockGatingThruSmu"             0
                Set-Registry $P "EnableSysClockGatingThruSmu"             0
                Set-Registry $P "DisableXdmaSclkGating"                   1
                Set-Registry $P "DalFineGrainClockGating"                 0
                Set-Registry $P "DisableRomMediumGrainClockGating"        1
                Set-Registry $P "DisableNbioMediumGrainClockGating"       1
                Set-Registry $P "DisableMcMediumGrainClockGating"         1
                Set-Registry $P "IRQMgrDisableIHClockGating"              1
                # power gating
                Set-Registry $P "DisableGfxMGLS"                          1
                Set-Registry $P "DisableHdpClockPowerGating"              1
                Set-Registry $P "DisableUVDPowerGating"                   1
                Set-Registry $P "DisableVCEPowerGating"                   1
                Set-Registry $P "DisableAcpPowerGating"                   1
                Set-Registry $P "DisableDrmdmaPowerGating"                1
                Set-Registry $P "DisableGfxCGPowerGating"                 1
                Set-Registry $P "DisableStaticGfxMGPowerGating"           1
                Set-Registry $P "DisableDynamicGfxMGPowerGating"          1
                Set-Registry $P "DisableCpPowerGating"                    1
                Set-Registry $P "DisableGDSPowerGating"                   1
                Set-Registry $P "DisableXdmaPowerGating"                  1
                Set-Registry $P "DisableGFXPipelinePowerGating"           1
                Set-Registry $P "DisableQuickGfxMGPowerGating"            1
                Set-Registry $P "DisablePowerGating"                      1
                Set-Registry $P "SMU_DisableMmhubPowerGating"             1
                Set-Registry $P "SMU_DisableAthubPowerGating"             1
                # dal
                Set-Registry $P "DalForceMaxDisplayClock"                 1
                Set-Registry $P "DalDisableClockGating"                   1
                Set-Registry $P "DalDisableDeepSleep"                     1
                Set-Registry $P "DalDisableDiv2"                          1
                # spread spectrum
                Set-Registry $P "EnableSpreadSpectrum"                    0
                Set-Registry $P "EnableVcePllSpreadSpectrum"              0

                if (Test-Path "$P\UMD") {
                    Set-Registry "$P\UMD" "VSyncControl"       ([byte[]](0x30,0x00)) "Binary"
                    Set-Registry "$P\UMD" "TFQ"                ([byte[]](0x32,0x00)) "Binary"
                    Set-Registry "$P\UMD" "Tessellation"       ([byte[]](0x31,0x00)) "Binary"
                    Set-Registry "$P\UMD" "Tessellation_OPTION" ([byte[]](0x32,0x00)) "Binary"
                }
                if (Test-Path "$P\power_v1") {
                    Set-Registry "$P\power_v1" "abmlevel" ([byte[]](0x00,0x00,0x00,0x00)) "Binary"
                }
            }

            # mpo fix
            Set-Registry "HKLM:\SOFTWARE\Microsoft\Windows\DWM" "OverlayTestMode" 5

            status "re-applying gpu msi mode..." "step"
            Start-Sleep -Seconds 2
            Get-PnpDevice -InstanceId "PCI\*" -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -match 'OK|Unknown' } | ForEach-Object {
                    $P = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)\Device Parameters\Interrupt Management"
                    Set-Registry -Path "$P\MessageSignaledInterruptProperties" -Name "MSISupported" -Value 1
                    if (Test-Path "$P\Affinity Policy") {
                    Remove-ItemProperty -Path "$P\Affinity Policy" -Name "DevicePriority" -ErrorAction SilentlyContinue
        }
        }
            status "amd driver installation complete." "done"
            break
        }
 
        "3" { break gpu }
    }
}
 
# ── environment cleanup ───────────────────────────────────────────────────────
status "cleaning up environment..." "step"
 
@("inetpub","PerfLogs","XboxGames","Windows.old") | ForEach-Object {
    if (Test-Path "$env:SystemDrive\$_") {
        Remove-Item "$env:SystemDrive\$_" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}
if (Test-Path "$env:SystemDrive\DumpStack.log") { Remove-Item "$env:SystemDrive\DumpStack.log" -Force -ErrorAction SilentlyContinue | Out-Null }
 
Remove-Item "$env:UserProfile\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$env:SystemDrive\Windows\Temp\*"       -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
 
# rebuild performance counters
& "$env:SystemRoot\system32\lodctr.exe" /R 2>&1 | Out-Null
& "$env:SystemRoot\SysWOW64\lodctr.exe" /R 2>&1 | Out-Null
 
# disk cleanup
status "running disk cleanup..." "step"
Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/autoclean /d C:" -Wait -NoNewWindow
 
Write-Host ""
status "albus playbook v2 complete." "done"
Exit
# ============================================================================================================================
