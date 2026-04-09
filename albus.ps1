# =============================================================================================================================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Privilege = $Identity.Split('\')[-1]
[Console]::Title = "Albus Playbook - $Privilege"

function Status ($Msg, $Type = "info") {
    $P, $C = switch ($Type) {
        "info"    { "info", "Cyan" }
        "done"    { "done", "Green" }
        "warn"    { "warn", "Yellow" }
        "fail"    { "fail", "Red" }
        "step"    { "step", "Magenta" }
        Default   { "albus", "Gray" }
    }
    Write-Host "$P - " -NoNewline -ForegroundColor $C
    Write-Host $Msg
}

function Set-Registry {
    param (
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = "DWord"
    )
    try {
        $CleanPath = $Path.Replace("HKLM:", "HKEY_LOCAL_MACHINE").Replace("HKCU:", "HKEY_CURRENT_USER").Replace("HKCR:", "HKEY_CLASSES_ROOT").Replace("HKU:", "HKEY_USERS")
        
        if ($Path.StartsWith("-")) {
            $RealPath = $Path.Substring(1)
            if ($Path -like "*-HKCR*") {
                & reg.exe delete "$($CleanPath.Substring(1))" /f 2>&1 | Out-Null
            } else {
                if (Test-Path $RealPath) { Remove-Item -Path $RealPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
            }
            return
        }

        if ($Value -eq "-") {
            if (Test-Path $Path) { Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue | Out-Null }
            return
        }

        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }

        if ($Name -eq "") {
            Set-Item -Path $Path -Value $Value -Force | Out-Null
        } else {
            $PT = if ($Type -eq "QWord") { "QWord" } else { $Type }
            try {
                New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PT -Force -ErrorAction Stop | Out-Null
            } catch {
                $RegType = switch ($Type) {
                    "DWord"  { "REG_DWORD" } "String" { "REG_SZ" } "Binary" { "REG_BINARY" }
                    "QWord"  { "REG_QWORD" } "ExpandString" { "REG_EXPAND_SZ" } Default { "REG_DWORD" }
                }
                $FinalValue = if ($Type -eq "Binary") { ($Value | ForEach-Object { "{0:X2}" -f $_ }) -join "" } else { $Value }
                & reg.exe add "$CleanPath" /v "$Name" /t $RegType /d $FinalValue /f 2>&1 | Out-Null
            }
        }
    } catch {
        if (-not ($Path.StartsWith("-") -or $Value -eq "-")) {
            Status "failed to set registry: $Path\$Name" "fail"
        }
    }
}

$dest = "C:\Albus"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }

if (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue) {
    Status "initializing dynamic payload retrieval..." "done"

    try {
        $braveRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/brave/brave-browser/releases/latest" -ErrorAction Stop
        $braveVer = $braveRelease.tag_name
        $braveUrl = "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe"
        
        Status "fetching brave browser ($braveVer)" "info"
        Invoke-WebRequest -Uri $braveUrl -OutFile "$dest\BraveSetup.exe" -UseBasicParsing -ErrorAction Stop
        
        Status "installing brave browser..." "info"
        Start-Process -Wait "$dest\BraveSetup.exe" -ArgumentList "/silent /install" -WindowStyle Hidden
        
        Status "applying browser hardening..." "info"
        Set-Registry "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" "HardwareAccelerationModeEnabled" 0 "DWord"
        Set-Registry "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" "BackgroundModeEnabled" 0 "DWord"
        Set-Registry "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave" "HighEfficiencyModeEnabled" 1 "DWord"
    } catch {
        Status "failed to retrieve brave browser package." "fail"
    }

    try {
        $7zRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/ip7z/7zip/releases/latest" -ErrorAction Stop
        $7zVer = $7zRelease.name
        $7zUrl = ($7zRelease.assets | Where-Object { $_.name -match "7z.*-x64\.exe" }).browser_download_url
        if ($7zUrl) {
            Status "fetching 7-zip ($7zVer)" "info"
            Invoke-WebRequest -Uri $7zUrl -OutFile "$dest\7zip.exe" -UseBasicParsing
            
            Status "extracting and installing 7-zip..." "info"
            Start-Process -Wait "$dest\7zip.exe" -ArgumentList "/S"
            Set-Registry "HKCU:\Software\7-Zip\Options" "ContextMenu" 259 "DWord"
            Set-Registry "HKCU:\Software\7-Zip\Options" "CascadedMenu" 0 "DWord"
            
            Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip\7-Zip File Manager.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Status "failed to retrieve 7-zip package." "fail"
    }

    try {
        Status "fetching visual c++ runtimes (latest)" "info"
        $vcLinks = @(
            "https://aka.ms/vs/17/release/vc_redist.x64.exe"
        )
        foreach ($vcLink in $vcLinks) {
            $arch = if ($vcLink -match "x64") { "x64" } else { "x86" }
            Status "downloading vc++ $arch..." "info"
            Invoke-WebRequest -Uri $vcLink -OutFile "$dest\vc_redist.$arch.exe" -UseBasicParsing
            
            Status "installing vc++ $arch..." "info"
            Start-Process -Wait "$dest\vc_redist.$arch.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
        }
    } catch {
        Status "failed to retrieve visual c++ packages." "fail"
    }

    try {
        Status "fetching directx end-user runtime (latest)" "info"
        $dxUrl = "https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe"
        Status "downloading directx updater..." "info"
        Invoke-WebRequest -Uri $dxUrl -OutFile "$dest\dxwebsetup.exe" -UseBasicParsing -ErrorAction Stop
        
        Status "installing graphics api runtimes..." "info"
        Start-Process -Wait "$dest\dxwebsetup.exe" -ArgumentList "/Q" -WindowStyle Hidden
    } catch {
        Status "failed to retrieve directx." "fail"
    }

} else {
    Status "network interface unresponsive. bypassing payload retrieval." "fail"
}

#>
# =============================================================================================================================================================================

Status "executing registry optimization engine..." "step"

# Ensure all standard registry drives are mapped
if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null }
if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null }

$Today = Get-Date
$PauseEnd = $Today.AddYears(31)
$TodayStr = $Today.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$PauseStr = $PauseEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$Tweaks = @(
    # --- EASE OF ACCESS ---
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "DuckAudio"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "WinEnterLaunchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "ScriptingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "OnlineServicesEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "NarratorCursorHighlight"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "CoupleNarratorCursorKeyboard"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Ease of Access"; Name = "selfvoice"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Ease of Access"; Name = "selfscan"; Value = 0; Type = "DWord" }
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

    # --- CLOCK AND REGION ---
    @{ Path = "HKCU:\Control Panel\TimeDate"; Name = "DstNotification"; Value = 0; Type = "DWord" }

    # --- APPEARANCE AND PERSONALIZATION ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "ShowFrequent"; Value = 0; Type = "DWord" }
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
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"; Name = "FullPath"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsDeviceSearchHistoryEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "ShowCloudFilesInQuickAccess"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}"; Name = "System.IsPinnedToNameSpaceTree"; Value = 0; Type = "DWord" }

    # --- HARDWARE AND SOUND ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings"; Name = "ShowLockOption"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings"; Name = "ShowSleepOption"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Multimedia\Audio"; Name = "UserDuckingPreference"; Value = 3; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation"; Name = "DisableStartupSound"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\EditionOverrides"; Name = "UserSetting_DisableStartupSound"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\AppEvents\Schemes"; Name = ""; Value = ".None"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"; Name = "DisableAutoplay"; Value = 1; Type = "DWord" }

    # --- MOUSE AND CURSORS ---
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSpeed"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold1"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseThreshold2"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "ContactVisualization"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "GestureVisualization"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = "Scheme Source"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Cursors"; Name = ""; Value = ""; Type = "String" }

    # --- HARDWARE AND DEVICE MANAGEMENT ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata"; Name = "PreventDeviceMetadataFromNetwork"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Network\SharedAccessConnection"; Name = "EnableControl"; Value = 0; Type = "DWord" }

    # --- SYSTEM PERFORMANCE AND MAINTENANCE ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fAllVolumes"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fDeadlineEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fExclude"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fTaskEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "fUpgradeRestored"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "TaskFrequency"; Value = 4; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Dfrg\TaskSettings"; Name = "Volumes"; Value = " "; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"; Name = "Win32PrioritySeparation"; Value = 38; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance"; Name = "fAllowToGetHelp"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"; Name = "MaintenanceDisabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }

    # --- VISUAL EFFECTS AND DWM ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"; Name = "VisualFXSetting"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "UserPreferencesMask"; Value = ([byte[]](0x90,0x12,0x03,0x80,0x12,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Desktop\WindowMetrics"; Name = "MinAnimate"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAnimations"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "EnableAeroPeek"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "AlwaysHibernateThumbnails"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IconsOnly"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ListviewAlphaSelect"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "DragFullWindows"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "FontSmoothing"; Value = "2"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ListviewShadow"; Value = 0; Type = "DWord" }

    # --- WINDOWS UPDATE & DELIVERY OPTIMIZATION ---
    @{ Path = "HKU:\S-1-5-20\Software\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings"; Name = "DownloadMode"; Value = 0; Type = "DWord" }

    # --- PRIVACY & TRACKING ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\MdmCommon\SettingValues"; Name = "LocationSyncEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications"; Name = "EnableAccountNotifications"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\TailoredExperiencesWithDiagnosticDataEnabled"; Name = "Value"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"; Name = "TailoredExperiencesWithDiagnosticDataEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; Name = "Value"; Value = "Deny"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CPSS\Store\UserLocationOverridePrivacySetting"; Name = "Value"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; Name = "ShowGlobalPrompts"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam"; Name = "Value"; Value = "Allow"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"; Name = "Value"; Value = "Allow"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps"; Name = "AgentActivationEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Speech_OneCore\Settings\VoiceActivation\UserPreferenceForAllApps"; Name = "AgentActivationLastUsed"; Value = 0; Type = "DWord" }
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
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\bluetoothSync"; Name = "Value"; Value = "Deny"; Type = "String" }
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
    @{ Path = "HKCU:\Control Panel\International\User Profile"; Name = "HttpAcceptLanguageOptOut"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization"; Name = "RestrictImplicitTextCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore"; Name = "HarvestContacts"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Personalization\Settings"; Name = "AcceptedPrivacyPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Siuf\Rules"; Name = "NumberOfSIUFInPeriod"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Siuf\Rules"; Name = "PeriodInNanoSeconds"; Value = "-"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "PublishUserActivities"; Value = 0; Type = "DWord" }

    # --- SEARCH & CLOUD ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsDynamicSearchBoxEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "SafeSearchMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsAADCloudSearchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = "IsMSACloudSearchEnabled"; Value = 0; Type = "DWord" }

    # --- ADVANCED EASE OF ACCESS ---
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowCaret"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowNarrator"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowMouse"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\ScreenMagnifier"; Name = "FollowFocus"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "IntonationPause"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "ReadHints"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "ErrorNotificationType"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "EchoChars"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator"; Name = "EchoWords"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NarratorHome"; Name = "MinimizeType"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NarratorHome"; Name = "AutoStart"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Narrator\NoRoam"; Name = "EchoToggleKeys"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Keyboard"; Name = "PrintScreenKeyForSnippingEnabled"; Value = 0; Type = "DWord" }

    # --- GAMING & PERFORMANCE ---
    @{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AppCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "UseNexusForGameBarEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "GamepadNexusChordEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "AutoGameModeEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AudioEncodingBitrate"; Value = 128000; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AudioCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CustomVideoEncodingBitrate"; Value = 4000000; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CustomVideoEncodingHeight"; Value = 720; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CustomVideoEncodingWidth"; Value = 1280; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalBufferLength"; Value = 30; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalBufferLengthUnit"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalCaptureOnBatteryAllowed"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "HistoricalCaptureOnWirelessDisplayAllowed"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MaximumRecordLength"; Value = 720000000000; Type = "QWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VideoEncodingBitrateMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VideoEncodingResolutionMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VideoEncodingFrameRateMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "EchoCancellationEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "CursorCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleGameBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleGameBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKSaveHistoricalVideo"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMSaveHistoricalVideo"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleRecording"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleRecording"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKTakeScreenshot"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMTakeScreenshot"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleRecordingIndicator"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleRecordingIndicator"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleMicrophoneCapture"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleMicrophoneCapture"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleCameraCapture"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleCameraCapture"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKToggleBroadcast"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "VKMToggleBroadcast"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MicrophoneCaptureEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "SystemAudioGain"; Value = 10000; Type = "QWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "MicrophoneGain"; Value = 10000; Type = "QWord" }

    # --- TIME, LANGUAGE & INPUT ---
    @{ Path = "HKCU:\Software\Microsoft\input\Settings"; Name = "IsVoiceTypingKeyEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "EnableAutoShiftEngage"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "EnableKeyAudioFeedback"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "EnableDoubleTapSpace"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\input\Settings"; Name = "InsightsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "TouchKeyboardTapInvoke"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "ExtraIconsOnMinimized"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "Label"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "ShowStatus"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\CTF\LangBar"; Name = "Transparency"; Value = 255; Type = "DWord" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Language Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Keyboard Layout\Toggle"; Name = "Layout Hotkey"; Value = "3"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "GleamEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "WeatherEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "HolidayEnabled"; Value = 0; Type = "DWord" }

    # --- ACCOUNTS & SYNC ---
    @{ Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon"; Name = "EnableGoodbye"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableAutomaticRestartSignOn"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"; Name = "DevicePasswordLessBuildVersion"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"; Name = "DevicePasswordLessUpdateType"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAccessibilitySettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAccessibilitySettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAppSyncSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableAppSyncSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableApplicationSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableApplicationSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableCredentialsSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableCredentialsSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableDesktopThemeSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableDesktopThemeSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableLanguageSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableLanguageSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisablePersonalizationSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisablePersonalizationSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableStartLayoutSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableStartLayoutSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableSyncOnPaidNetwork"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWebBrowserSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWebBrowserSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWindowsSettingSync"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "DisableWindowsSettingSyncUserOverride"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync"; Name = "EnableWindowsBackup"; Value = 0; Type = "DWord" }

    # --- APPS & MAPS ---
    @{ Path = "HKLM:\SYSTEM\Maps"; Name = "AutoUpdateEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx"; Name = "AllowAutomaticAppArchiving"; Value = 0; Type = "DWord" }

    # --- PERSONALIZATION & THEMES ---
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "Wallpaper"; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers"; Name = "BackgroundType"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "AppsUseLightTheme"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "ColorPrevalence"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "EnableTransparency"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "SystemUsesLightTheme"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "AppsUseLightTheme"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"; Name = "AccentPalette"; Value = ([byte[]](0x64,0x64,0x64,0x00,0x6b,0x6b,0x6b,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"; Name = "StartColorMenu"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent"; Name = "AccentColorMenu"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "EnableWindowColorization"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "AccentColor"; Value = 0xff191919; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "ColorizationColor"; Value = 0xc4191919; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "ColorizationAfterglow"; Value = 0xc4191919; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Colors"; Name = "Background"; Value = "0 0 0"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu"; Name = "{645FF040-5081-101B-9F08-00AA002F954E}"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"; Name = "{645FF040-5081-101B-9F08-00AA002F954E}"; Value = 1; Type = "DWord" }

    # --- START MENU & TASKBAR ---
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "ShowOrHideMostUsedApps"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "ShowOrHideMostUsedApps"; Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoStartMenuMFUprogramsList"; Value = "-"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInstrumentation"; Value = "-"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoStartMenuMFUprogramsList"; Value = "-"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInstrumentation"; Value = "-"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "HideRecommendedSection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education"; Name = "IsEducationEnvironment"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "HideRecommendedSection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_Layout"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "HideRecentlyAddedApps"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideRecentlyAddedApps"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_AccountNotifications"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_RecoPersonalizedSites"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_TrackDocs"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "TipbandDesiredVisibility"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IconSizePreference"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAl"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSd"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarMn"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowTaskViewButton"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "SearchboxTaskbarMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; Name = "AllowNewsAndInterests"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowCopilotButton"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "IsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds"; Name = "EnableFeeds"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "EnableAutoTray"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; Name = "SecurityHealth"; Value = ([byte[]](0x07,0x00,0x00,0x00,0x05,0xDB,0x8A,0x69,0x8A,0x49,0xD9,0x01)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "AmbientLightingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "ControlledByForegroundApp"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Lighting"; Name = "UseSystemAccentColor"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\1.7"; Name = "IsKeyBackgroundEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_IrisRecommendations"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "ShowRecentList"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarSn"; Value = 0; Type = "DWord" }

    # --- CLOUD EXPERIENCE HOST INTENT ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\developer"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\developer"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\gaming"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\gaming"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\family"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\family"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\creative"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\creative"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\schoolwork"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\schoolwork"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\entertainment"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\entertainment"; Name = "Priority"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\business"; Name = "Intent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudExperienceHost\Intent\business"; Name = "Priority"; Value = 0; Type = "DWord" }

    # --- DEVICES & HARDWARE ---
    @{ Path = "HKCU:\Software\Microsoft\Shell\USB"; Name = "NotifyOnUsbErrors"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows"; Name = "LegacyDefaultPrinterMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\TabletTip\EmbeddedInkControl"; Name = "EnableInkingWithTouch"; Value = 0; Type = "DWord" }

    # --- SYSTEM, GPU & DPI ---
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "LogPixels"; Value = 96; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "Win8DpiScaling"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "UseDpiScaling"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "EnablePerProcessSystemDPI"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "HwSchMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "DirectXUserGlobalSettings"; Value = "SwapEffectUpgradeEnable=1;VRROptimizeEnable=0;"; Type = "String" }

    # --- NOTIFICATIONS & TOASTS ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "ToastEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_CRITICAL_TOASTS_ABOVE_LOCK"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "NOC_GLOBAL_SETTING_ALLOW_TOASTS_ABOVE_LOCK"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AutoPlay"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.SecurityAndMaintenance"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.CapabilityAccess"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard"; Name = "Disabled"; Value = 1; Type = "DWord" }

    # --- FOCUS ASSIST & QUIET HOURS (BINARY BLOCKS) ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$$windows.data.notifications.quiethourssettings\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0xB4,0x67,0x2B,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x14,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x55,0x00,0x6E,0x00,0x72,0x00,0x65,0x00,0x73,0x00,0x74,0x00,0x72,0x00,0x69,0x00,0x63,0x00,0x74,0x00,0x65,0x00,0x64,0x00,0xCA,0x28,0xD0,0x14,0x02,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentfullscreen$windows.data.notifications.quietmoment\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x97,0x1D,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentgame$windows.data.notifications.quietmoment\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x6C,0x39,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x50,0x00,0x72,0x00,0x69,0x00,0x6F,0x00,0x72,0x00,0x69,0x00,0x74,0x00,0x79,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount\$quietmomentpresentation$windows.data.notifications.quietmoment\Current"; Name = "Data"; Value = ([byte[]](0x02,0x00,0x00,0x00,0x83,0x6E,0x2D,0x68,0xF0,0x0B,0xD8,0x01,0x00,0x00,0x00,0x00,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xC2,0x28,0x01,0xCA,0x50,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentpresentation"; Name = "Data"; Value = ([byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xE2,0xF3,0xAA,0xCC,0x06,0x2A,0x2B,0x0E,0x5A,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xCA,0x50,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentgame"; Name = "Data"; Value = ([byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xE1,0xF3,0xAA,0xCC,0x06,0x2A,0x2B,0x0E,0x5E,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x50,0x00,0x72,0x00,0x69,0x00,0x6F,0x00,0x72,0x00,0x69,0x00,0x74,0x00,0x79,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xCA,0x50,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.donotdisturb.quietmoment$quietmomentlist\windows.data.donotdisturb.quietmoment$quietmomentfullscreen"; Name = "Data"; Value = ([byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xE0,0xF3,0xAA,0xCC,0x06,0x2A,0x2B,0x0E,0x5A,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xD2,0x1E,0x26,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x51,0x00,0x75,0x00,0x69,0x00,0x65,0x00,0x74,0x00,0x48,0x00,0x6F,0x00,0x75,0x00,0x72,0x00,0x73,0x00,0x50,0x00,0x72,0x00,0x6F,0x00,0x66,0x00,0x69,0x00,0x6C,0x00,0x65,0x00,0x2E,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x4F,0x00,0x6E,0x00,0x6C,0x00,0x79,0x00,0xCA,0x50,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\default$windows.data.shell.focussessionactivetheme\windows.data.shell.focussessionactivetheme${1b019365-25a5-4ff1-b50a-c155229afc8f}"; Name = "Data"; Value = ([byte[]](0x43,0x42,0x01,0x00,0x0A,0x00,0x2A,0x06,0xF4,0xE2,0xAA,0xCC,0x06,0x2A,0x2B,0x0E,0x08,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0x00,0x00,0x00,0x00)); Type = "Binary" }

    # --- STORAGE, POWER & SHELL ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\VideoSettings"; Name = "VideoQualityOnBattery"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense"; Name = "AllowStorageSenseGlobal"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "04"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "2048"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "08"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "256"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "32"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy"; Name = "StoragePoliciesChanged"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "DragTrayEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SnapAssist"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "DITest"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableSnapBar"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableTaskGroups"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "EnableSnapAssistFlyout"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "SnapFill"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "JointResize"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; Name = "TaskbarEndTask"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"; Name = "LongPathsEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "MultiTaskingAltTabFilter"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "RomeSdkChannelUserAuthzPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"; Name = "CdpSessionUserAuthzPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsMitigation"; Name = "UserPreference"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate"; Name = "AutoDownload"; Value = 2; Type = "DWord" }

    # --- START MENU & FEATURES ---
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\2792562829"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\3036241548"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\734731404"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\14\762256525"; Name = "EnabledState"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "AllAppsViewMode"; Value = 2; Type = "DWord" }

    # --- UWP, AI & COPILOT ---
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy"; Name = "LetAppsRunInBackground"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\input"; Name = "IsInputAppPreloadEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Dsh"; Name = "IsPrelaunchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableSearchBoxSuggestions"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Name = "DisableAIDataAnalysis"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Name = "AllowRecallEnablement"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"; Name = "DisableClickToDo"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot\BingChat"; Name = "IsUserEligible"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableGenerativeFill"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableCocreator"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"; Name = "DisableImageCreator"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\WindowsNotepad"; Name = "DisableAIFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests"; Name = "value"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "RawMouseThrottleEnabled"; Value = 0; Type = "DWord" }

    # --- ADVERTISING & CONTENT DELIVERY ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "ContentDeliveryAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "FeatureManagementEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "OemPreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEverEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenOverlayEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SlideshowEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SoftLandingEnabled"; Value = 0; Type = "DWord" }

    # --- GAMEBAR PROTOCOL REDIRECTION ---
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
    @{ Path = "HKCU:\ms-gamingoverlay\shell\open\command"; Name = ""; Value = "$env:SystemRoot\System32\systray.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Windows.Gaming.GameBar.PresenceServer.Internal.PresenceWriter"; Name = "ActivationType"; Value = 0; Type = "DWord" }

    # --- SHELL & EXPLORER CLEANUP ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\MyComputer\NameSpace\{0DB7E03F-FC29-4DC6-9020-FF41B59E513A}"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "HubMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}"; Name = "System.IsPinnedToNameSpaceTree"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "MenuShowDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching"; Name = "SearchOrderConfig"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoWebServices"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "SettingsPageVisibility"; Value = "hide:home;"; Type = "String" }

    # --- NO ACCEL MOUSE FIX ---
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "MouseSensitivity"; Value = "10"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "SmoothMouseXCurve"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0xC0,0xCC,0x0C,0x00,0x00,0x00,0x00,0x00, 0x80,0x99,0x19,0x00,0x00,0x00,0x00,0x00, 0x40,0x66,0x26,0x00,0x00,0x00,0x00,0x00, 0x00,0x33,0x33,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Control Panel\Mouse"; Name = "SmoothMouseYCurve"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x38,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0x70,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0xA8,0x00,0x00,0x00,0x00,0x00, 0x00,0x00,0xE0,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseSpeed"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseThreshold1"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Mouse"; Name = "MouseThreshold2"; Value = "0"; Type = "String" }

    # --- SYSTEM & STABILITY ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start"; Name = "RightCompanionToggledOpen"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"; Name = "IsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe"; Name = "IsAvailable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl"; Name = "DisplayParameters"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"; Name = "DisableWpbtExecution"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration"; Name = "IsResumeAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CrossDeviceResume\Configuration"; Name = "IsOneDriveResumeAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Connectivity\DisableCrossDeviceResume"; Name = "value"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1387020943"; Name = "EnabledState"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\1694661260"; Name = "EnabledState"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Console\%SystemRoot%_System32_WindowsPowerShell_v1.0_powershell.exe"; Name = "ScreenColors"; Value = 15; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0; Type = "DWord" }

    # --- SOUND SCHEMES ---
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\.Default\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\CriticalBatteryAlarm\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceConnect\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceDisconnect\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\DeviceFail\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\FaxBeep\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\LowBatteryAlarm\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\MailBeep\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\MessageNudge\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\Notification.Default\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\Notification.IM\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\Notification.Mail\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\Notification.Proximity\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\Notification.Reminder\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\Notification.SMS\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\ProximityConnection\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\SystemAsterisk\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\SystemExclamation\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\SystemHand\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\SystemNotification\.Current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\.Default\WindowsUAC\.Current"; Name = ""; Value = ""; Type = "String" }

    # --- SPEECH SOUND SCHEMES ---
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\DisNumbersSound\.current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\HubOffSound\.current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\HubOnSound\.current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\HubSleepSound\.current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\MisrecoSound\.current"; Name = ""; Value = ""; Type = "String" }
    @{ Path = "HKCU:\AppEvents\Schemes\Apps\sapisvr\PanelSound\.current"; Name = ""; Value = ""; Type = "String" }

    # --- MOUSE CURSORS ---
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

    # --- SECURITY & SMARTSCREEN ---
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Edge\SmartScreenEnabled"; Name = ""; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost"; Name = "EnableWebContentEvaluation"; Value = 0; Type = "DWord" }

    # --- UPDATES & PAUSE TIME ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseUpdatesExpiryTime"; Value = $PauseStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseFeatureUpdatesEndTime"; Value = $PauseStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseFeatureUpdatesStartTime"; Value = $TodayStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseQualityUpdatesEndTime"; Value = $PauseStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseQualityUpdatesStartTime"; Value = $TodayStr; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "PauseUpdatesStartTime"; Value = $TodayStr; Type = "String" }

    # --- DRIVER BLOCKS ---
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Device Metadata"; Name = "PreventDeviceMetadataFromNetwork"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Settings"; Name = "DisableSendGenericDriverNotFoundToWER"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Settings"; Name = "DisableSendRequestAdditionalSoftwareToWER"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DriverSearching"; Name = "SearchOrderConfig"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "SetAllowOptionalContent"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "AllowTemporaryEnterpriseFeatureControl"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "ExcludeWUDriversInQualityUpdate"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = "IncludeRecommendedUpdates"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = "EnableFeaturedSoftware"; Value = 0; Type = "DWord" }

    # --- CONFIGURE CONTROL PANEL (ADDED) ---
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "JPEGImportQuality"; Value = 100; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "JPEGImportQuality"; Value = 100; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Sound"; Name = "Beep"; Value = "no"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Sound"; Name = "Beep"; Value = "no"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "MenuShowDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "ActiveWndTrkTimeout"; Value = 10; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "ActiveWndTrkTimeout"; Value = 10; Type = "DWord" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "AutoEndTasks"; Value = "1"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "AutoEndTasks"; Value = "1"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "HungAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "HungAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "WaitToKillAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "WaitToKillAppTimeout"; Value = "2000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Desktop"; Name = "LowLevelHooksTimeout"; Value = "1000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Desktop"; Name = "LowLevelHooksTimeout"; Value = "1000"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys"; Name = "MaximumSpeed"; Value = "-"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys"; Name = "TimeToMaximumSpeed"; Value = "-"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "AllowOnlineTips"; Value = 0; Type = "DWord" }

    # --- ADVANCED EASE OF ACCESS - HKCU (ADDED) ---
    @{ Path = "HKCU:\Control Panel\Accessibility\AudioDescription"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Blind Access"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Preference"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\On"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\ShowSounds"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\SlateLaunch"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\TimeOut"; Name = "Flags"; Value = "0"; Type = "String" }

    # --- ADVANCED EASE OF ACCESS - HKU\.DEFAULT (ADDED) ---
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\AudioDescription"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\Blind Access"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\HighContrast"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\Keyboard Preference"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\Keyboard Response"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\MouseKeys"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\On"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\ShowSounds"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\SlateLaunch"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\SoundSentry"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\StickyKeys"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\TimeOut"; Name = "Flags"; Value = "0"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Control Panel\Accessibility\ToggleKeys"; Name = "Flags"; Value = "0"; Type = "String" }

    # --- CONFIGURE EXPLORER (ADDED) ---
    @{ Path = "HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"; Name = "FolderType"; Value = "NotSpecified"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"; Name = "FolderType"; Value = "NotSpecified"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "C:\Windows\explorer.exe"; Value = "GpuPreference=2;"; Type = "String" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\DirectX\UserGpuPreferences"; Name = "C:\Windows\explorer.exe"; Value = "GpuPreference=2;"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"; Name = "DisableGraphRecentItems"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"; Name = "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "MultipleInvokePromptMinimum"; Value = 100; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer"; Name = "MultipleInvokePromptMinimum"; Value = 100; Type = "DWord" }
    @{ Path = "HKCU:\Software\Winaero.com\Winaero Tweaker\Changes"; Name = "pageContextMenuSelectionLimit"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "link"; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "link"; Value = ([byte[]](0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager"; Name = "EnthusiastMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager"; Name = "EnthusiastMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"; Name = "DisableAutoplay"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoDriveTypeAutoRun"; Value = 255; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoDriveTypeAutoRun"; Value = 255; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoLowDiskSpaceChecks"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoLowDiskSpaceChecks"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control"; Name = "WaitToKillServiceTimeout"; Value = "1500"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "LinkResolveIgnoreLinkInfo"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "LinkResolveIgnoreLinkInfo"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAnimations"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace"; Name = "AllowWindowsInkWorkspace"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace"; Name = "AllowSuggestedAppsInWindowsInkWorkspace"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_IrisRecommendations"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "Start_AccountNotifications"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings"; Name = "TaskbarEndTask"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "LaunchTo"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowInfoTip"; Value = 0; Type = "DWord" }

    # --- ADVANCED EXPLORER: NOTIFICATIONS (ADDED) ---
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "NoBalloonFeatureAdvertisements"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "NoBalloonFeatureAdvertisements"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "NoAutoTrayNotify"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "NoAutoTrayNotify"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "NoCloudApplicationNotification"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate"; Name = "UpdateNotificationLevel"; Value = 2; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"; Name = "ScoobeSystemSettingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless"; Name = "ScoobeCheckCompleted"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Context\CloudExperienceHostIntent\Wireless"; Name = "ScoobeCheckCompleted"; Value = 1; Type = "DWord" }

    # --- ADVANCED EXPLORER: SEARCH (ADDED) ---
    @{ Path = "HKLM:\Software\Microsoft\Windows Search\Gather\Windows\SystemIndex"; Name = "RespectPowerModes"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "PreventIndexOnBattery"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableSearchBoxSuggestions"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCloudSearch"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortanaAboveLock"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortana"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortanaInAAD"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortanaInAADPathOOBE"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowSearchToUseLocation"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchUseWeb"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchUseWebOverMeteredConnections"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "DisableWebSearch"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchPrivacy"; Value = 3; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "CortanaConsent"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "CortanaConsent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "BingSearchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "BingSearchEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Speech_OneCore\Preferences"; Name = "VoiceActivationEnableAboveLockscreen"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask"; Name = "ActivationType"; Value = 4294967295; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\WinStore.Tasks.WindowsSearchTask"; Name = "Server"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Policies\Microsoft\FeatureManagement\Overrides"; Name = "1694661260"; Value = 0; Type = "DWord" }

    # --- ADVANCED EXPLORER: START MENU (ADDED) ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "ConfigureStartPins"; Value = '{"pinnedList":[{"packagedAppId":"Microsoft.WindowsStore_8wekyb3d8bbwe!App"},{"packagedAppId":"windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel"},{"packagedAppId":"Microsoft.WindowsNotepad_8wekyb3d8bbwe!App"},{"packagedAppId":"Microsoft.Paint_8wekyb3d8bbwe!App"},{"desktopAppLink":"%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\File Explorer.lnk"},{"packagedAppId":"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"}]}'; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDocuments"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDocuments_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDownloads"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderDownloads_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderFileExplorer"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderFileExplorer_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderHomeGroup"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderHomeGroup_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderMusic"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderMusic_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderNetwork"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderNetwork_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPersonalFolder"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPersonalFolder_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPictures"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderPictures_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderSettings"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderSettings_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderVideos"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start"; Name = "AllowPinnedFolderVideos_ProviderSet"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoResolveSearch"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoResolveSearch"; Value = 1; Type = "DWord" }

    # --- ADVANCED EXPLORER: TASKBAR (ADDED) ---
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "SearchboxTaskbarMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowTaskViewButton"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds"; Name = "ShellFeedsTaskbarViewMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Feeds"; Name = "ShellFeedsTaskbarViewMode"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarDa"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarDa"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "HidePeopleBar"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\Explorer"; Name = "HidePeopleBar"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat"; Name = "ChatIcon"; Value = 3; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarMn"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "HideSCAMeetNow"; Value = 1; Type = "DWord" }

    # --- CONFIGURE EXPLORER VIEW (ADDED) ---
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"; Name = "FullPath"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\CabinetState"; Name = "FullPath"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsSelfHost\UI\Visibility"; Name = "HideInsiderPage"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "TrayIconVisibility"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "SignInMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "TabletMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "ConvertibleSlateModePromptPreference"; Value = 2; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "SignInMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "TabletMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ImmersiveShell"; Name = "ConvertibleSlateModePromptPreference"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAppsVisibleInTabletMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAppsVisibleInTabletMode"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAutoHideInTabletMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAutoHideInTabletMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "AllowClipboardHistory"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "AllowCrossDeviceClipboard"; Value = 1; Type = "DWord" }
    
    # --- DEVICES: TYPING & KEYBOARD ---
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableAutocorrection"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableAutocorrection"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableSpellchecking"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableSpellchecking"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableTextPrediction"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableTextPrediction"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnablePredictionSpaceInsertion"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnablePredictionSpaceInsertion"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableDoubleTapSpace"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\TabletTip\1.7"; Name = "EnableDoubleTapSpace"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Input\Settings"; Name = "EnableHwkbTextPrediction"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\Settings"; Name = "EnableHwkbTextPrediction"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Input\Settings"; Name = "EnableHwkbAutocorrection"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\Settings"; Name = "EnableHwkbAutocorrection"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Input\Settings"; Name = "MultilingualEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\Settings"; Name = "MultilingualEnabled"; Value = 0; Type = "DWord" }
    
    # --- UI COLORS ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\0\Theme0"; Name = "Color"; Value = 4279374354; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\0\Theme1"; Name = "Color"; Value = 4278190294; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\1\Theme0"; Name = "Color"; Value = 4294926889; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\1\Theme1"; Name = "Color"; Value = 4282117119; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\2\Theme0"; Name = "Color"; Value = 4278229247; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\2\Theme1"; Name = "Color"; Value = 4283680768; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\3\Theme0"; Name = "Color"; Value = 4294901930; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Accents\3\Theme1"; Name = "Color"; Value = 4294967064; Type = "DWord" }
    
    # --- MAPS & WIFI SENSE ---
    @{ Path = "HKLM:\SYSTEM\Maps"; Name = "UpdateOnlyOnWifi"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\config"; Name = "AutoConnectAllowedOEM"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features"; Name = "PaidWifi"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WcmSvc\wifinetworkmanager\features"; Name = "WiFiSenseOpen"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting"; Name = "value"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots"; Name = "value"; Value = 0; Type = "DWord" }
    
    # --- APP DEPROVISIONING ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.549981C3F5F10_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.BingNews_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.BingWeather_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ECApp_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.GetHelp_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Getstarted_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftEdge.Stable_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftEdgeDevToolsClient_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\EdgeUpdate"; Name = "DoNotUpdateToEdgeWithChromium"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftSolitaireCollection_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.People_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.PowerAutomateDesktop_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Todos_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.Apprep.ChxApp_cw5n1h2txyewy"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.PeopleExperienceHost_cw5n1h2txyewy"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.Photos_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.SecureAssessmentBrowser_cw5n1h2txyewy"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsAlarms_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsCamera_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsFeedbackHub_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsMaps_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ZuneMusic_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.ZuneVideo_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\microsoft.windowscommunicationsapps_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Advertising.Xaml_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Microsoft3DViewer_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MixedReality.Portal_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MSPaint_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Paint_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsNotepad_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\clipchamp.clipchamp_yxz26nhyzhsrt"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SecHealthUI_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.WindowsCalculator_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftCorporationII.MicrosoftFamily_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Whiteboard_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\microsoft.microsoftskydrive_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftTeamsforSurfaceHub_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MicrosoftCorporationII.MailforSurfaceHub_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftPowerBIForWindows_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.SkypeApp_kzf8qxf38zg5c"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.OneNote_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.Excel_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.PowerPoint_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Office.Word_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.Windows.DevHome_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\Microsoft.OutlookForWindows_8wekyb3d8bbwe"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\MSTeams_8wekyb3d8bbwe"; Name = ""; Value = "" }
    
    # --- LOGGING, OPTIMIZATION & SYSTEM FIXES ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\ClickToRun\OverRide"; Name = "DisableLogManagement"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration"; Name = "TimerInterval"; Value = "900000"; Type = "String" }
    @{ Path = "-HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore"; Name = "RPSessionInterval"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\cfg"; Name = "DiskPercent"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Internet Explorer\LowRegistry\Audio\PolicyConfig\PropertyStore"; Name = ""; Value = "" }
    @{ Path = "HKLM:\System\CurrentControlSet\Control\TimeZoneInformation"; Name = "RealTimeIsUniversal"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "EnableLinkedConnections"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vgc.exe"; Name = "MitigationOptions"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vgc.exe"; Name = "MitigationAuditOptions"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\vgc.exe"; Name = "EAFModules"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\osu!.exe"; Name = "MitigationOptions"; Value = ([byte[]](0x00,0x00,0x21,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\osu!.exe"; Name = "MitigationAuditOptions"; Value = ([byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00)); Type = "Binary" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\osu!.exe"; Name = "EAFModules"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"; Name = "InstallDefault"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"; Name = "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate"; Name = "Install{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\Session Manager"; Name = "DisableWpbtExecution"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Minimal\MSIServer"; Name = ""; Value = "Service"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\SafeBoot\Network\MSIServer"; Name = ""; Value = "Service"; Type = "String" }

    # --- REVISION EDITION & OEM INFO ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; Name = "EditionSubManufacturer"; Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; Name = "EditionSubstring"; Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"; Name = "EditionSubVersion"; Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "HelpCustomized"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "Manufacturer"; Value = "Albus"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "SupportProvider"; Value = "Albus Support"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "SupportAppURL"; Value = "albus-support"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation"; Name = "SupportURL"; Value = "https://github.com/oqullcan/blablabla"; Type = "String" }

    # --- PRIVACY: APP COMPATIBILITY ---
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisableEngine"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "AITEnable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisableUAR"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisablePCA"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "DisableInventory"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\AppCompat"; Name = "SbEnable"; Value = 1; Type = "DWord" }

    # --- PRIVACY: CONTENT DELIVERY MANAGER ---
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "ContentDeliveryAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "ContentDeliveryAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContentEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContentEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-310093Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-310093Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SoftLandingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338389Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SoftLandingEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338389Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEverEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEverEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "OemPreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "OemPreInstalledAppsEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "FeatureManagementEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "FeatureManagementEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RemediationRequired"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RemediationRequired"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-314559Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-280815Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-314563Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-202914Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338387Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-280810Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-280811Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-314559Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-280815Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-314563Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-202914Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338387Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-280810Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-280811Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenOverlayEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "RotatingLockScreenOverlayEnabled"; Value = 0; Type = "DWord" }

    # --- PRIVACY: CEIP ---
    @{ Path = "HKLM:\Software\Policies\Microsoft\SQMClient\Windows"; Name = "CEIPEnable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\AppV\CEIP"; Name = "CEIPEnable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Internet Explorer\SQM"; Name = "DisableCustomerImprovementProgram"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Messenger\Client"; Name = "CEIP"; Value = 2; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\UnattendSettings\SQMClient"; Name = "CEIPEnabled"; Value = 0; Type = "DWord" }

    # --- PRIVACY: CLOUD CONTENT ---
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableSoftLanding"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "ConfigureWindowsSpotlight"; Value = 2; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "ConfigureWindowsSpotlight"; Value = 2; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "IncludeEnterpriseSpotlight"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "IncludeEnterpriseSpotlight"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableThirdPartySuggestions"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableThirdPartySuggestions"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableTailoredExperiencesWithDiagnosticData"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableTailoredExperiencesWithDiagnosticData"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightWindowsWelcomeExperience"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightWindowsWelcomeExperience"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnActionCenter"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnActionCenter"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnSettings"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightOnSettings"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableCloudOptimizedContent"; Value = 1; Type = "DWord" }

    # --- PRIVACY: GENERAL INTERNET RESTRICTIONS ---
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "MSAOptional"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Messaging"; Name = "AllowMessageSync"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableHelpSticker"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Policies\Microsoft\Windows\EdgeUI"; Name = "DisableMFUTracking"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoPublishingWizard"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoWebServices"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform"; Name = "NoGenTicket"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoOnlinePrintsWizard"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInternetOpenWith"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableHTTPPrinting"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableWebPnPDownload"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\HandwritingErrorReports"; Name = "PreventHandwritingErrorReports"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\TabletPC"; Name = "PreventHandwritingDataSharing"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0"; Name = "NoOnlineAssist"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0"; Name = "NoExplicitFeedback"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Assistance\Client\1.0"; Name = "NoImplicitFeedback"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "WebHelp"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "CodecDownload"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "WebPublish"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoPublishingWizard"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoWebServices"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform"; Name = "NoGenTicket"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoOnlinePrintsWizard"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\PCHealth\HelpSvc"; Name = "Headlines"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\PCHealth\HelpSvc"; Name = "MicrosoftKBSearch"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\PCHealth\ErrorReporting"; Name = "DoReport"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoInternetOpenWith"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Internet Connection Wizard"; Name = "ExitOnMSICW"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\EventViewer"; Name = "MicrosoftEventVwrDisableLinks"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Registration Wizard Control"; Name = "NoRegistration"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\SearchCompanion"; Name = "DisableContentFileUpdates"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableHTTPPrinting"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\Printers"; Name = "DisableWebPnPDownload"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\HandwritingErrorReports"; Name = "PreventHandwritingErrorReports"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\TabletPC"; Name = "PreventHandwritingDataSharing"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "WebHelp"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "CodecDownload"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsMovieMaker"; Name = "WebPublish"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\NVIDIA Corporation\NVControlPanel2\Client"; Name = "OptInOrOutPreference"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"; Name = "Block-Unified-Telemetry-Client"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"; Name = "Block-Windows-Error-Reporting"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Telemetry-Client|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules"; Name = "Block-Unified-Telemetry-Client"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|"; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules"; Name = "Block-Windows-Error-Reporting"; Value = "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Telemetry-Client|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions"; Name = "ActivationType"; Value = 4294967295; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\Microsoft.Xbox.GamingAI.Companion.Host.GamingCompanionHostOptions"; Name = "Server"; Value = ""; Type = "String" }

    # --- PRIVACY: DATA COLLECTION ---
    @{ Path = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\System\AllowTelemetry"; Name = "value"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\DevicePolicy\AllowTelemetry"; Name = "DefaultValue"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\AllowTelemetry"; Name = "Value"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "AllowCommercialDataPipeline"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "AllowDeviceNameInTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "DisableEnterpriseAuthProxy"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "MicrosoftEdgeDataOptIn"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "DisableTelemetryOptInChangeNotification"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "DisableTelemetryOptInSettingsUx"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\PreviewBuilds"; Name = "EnableConfigFlighting"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "DoNotShowFeedbackNotifications"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "LimitEnhancedDiagnosticDataWindowsAnalytics"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "AllowBuildPreview"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "LimitDiagnosticLogCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"; Name = "LimitDumpCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\System"; Name = "AllowExperimentation"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener"; Name = "Start"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SQMLogger"; Name = "Start"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\WMI\Autologger\SetupPlatformTel"; Name = "Start"; Value = 0; Type = "DWord" }

    # --- PRIVACY: WINDOWS ERROR REPORTING ---
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "AutoApproveOSDumps"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "LoggingDisabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "DefaultConsent"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "DefaultOverrideBehavior"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DontSendAdditionalData"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DontShowUI"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "0"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\BitLocker"; Name = "PreventDeviceEncryption"; Value = 1; Type = "DWord" }

    # --- SECURITY ---
    @{ Path = "HKCU:\Software\Microsoft\Windows Security Health\State"; Name = "AccountProtection_MicrosoftAccount_Disconnected"; Value = 0; Type = "DWord" }
    @{ Path = "HKU:\.DEFAULT\Software\Microsoft\Windows Security Health\State"; Name = "AccountProtection_MicrosoftAccount_Disconnected"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows Defender\Reporting"; Name = "DisableGenericRePorts"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows Defender\Signature Updates"; Name = "DisableScheduledSignatureUpdateOnBattery"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows Defender\SmartScreen"; Name = "ConfigureAppInstallControlEnabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows Defender\SmartScreen"; Name = "ConfigureAppInstallControl"; Value = "Anywhere"; Type = "String" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost"; Name = "EnableWebContentEvaluation"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\MicrosoftEdge\PhishingFilter"; Name = "EnabledV9"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender Security Center\Systray"; Name = "HideSystray"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"; Name = "SecurityHealth"; Value = ""; Type = "String" }
    # --- CONFIGURE BOOT ---
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\Session Manager"; Name = "BootExecute"; Value = "autocheck autochk /k:C*"; Type = "MultiString" }

    # --- BYPASS REQUIREMENTS ---
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
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "BypassNRO"; Value = 1; Type = "DWord" }

    # --- CONFIGURE CRASH CONTROL ---
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\CrashControl"; Name = "AutoReboot"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\CrashControl"; Name = "CrashDumpEnabled"; Value = 3; Type = "DWord" }

    # --- DISABLE AUTOMATIC MAINTENANCE ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"; Name = "MaintenanceDisabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\ScheduledDiagnostics"; Name = "EnabledExecution"; Value = 0; Type = "DWord" }

    # --- CONFIGURE IFEO (TELEMETRY & BING ADS) ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\CompatTelRunner.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\AggregatorHost.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\DeviceCensus.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\FeatureLoader.exe"; Name = "Debugger"; Value = "%windir%\System32\taskkill.exe"; Type = "String" }
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

    # --- CONFIGURE SYSTEM LOGON ---
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "EnableFirstLogonAnimation"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableStartupSound"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "DisableAutomaticRestartSignOn"; Value = 1; Type = "DWord" }

    # --- CONFIGURE MULTIMEDIA ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; Name = "NetworkThrottlingIndex"; Value = 10; Type = "DWord" }

    # --- CONFIGURE OOBE ---
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideOnlineAccountScreens"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "HideOnlineAccountScreens"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideEULAPage"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "HideEULAPage"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "SkipMachineOOBE"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "SkipMachineOOBE"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "SkipUserOOBE"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "SkipUserOOBE"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideWirelessSetupInOOBE"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "HideWirelessSetupInOOBE"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "NetworkLocation"; Value = "Home"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "NetworkLocation"; Value = "Home"; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "ProtectYourPC"; Value = 3; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "ProtectYourPC"; Value = 3; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideLocalAccountScreen"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "HideLocalAccountScreen"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "DisablePrivacyExperience"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "DisablePrivacyExperience"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "HideOEMRegistrationScreen"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "HideOEMRegistrationScreen"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "EnableCortanaVoice"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "EnableCortanaVoice"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"; Name = "DisableVoice"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE"; Name = "DisableVoice"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE\AppSettings"; Name = "Skype-UserConsentAccepted"; Value = 0; Type = "DWord" }

    # --- CONFIGURE WIN32PRIORITYSEPARATION ---
    @{ Path = "HKLM:\SYSTEM\ControlSet001\Control\PriorityControl"; Name = "Win32PrioritySeparation"; Value = 38; Type = "DWord" }

    # --- CONFIGURE UPDATES ---
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsStore"; Name = "AutoDownload"; Value = 4; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsStore"; Name = "DisableOSUpgrade"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\Setup\UpgradeNotification"; Name = "UpgradeAvailable"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\MRT"; Name = "DontReportInfectionInformation"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"; Name = "DODownloadMode"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds"; Name = "AllowBuildPreview"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager"; Name = "ShippedWithReserves"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\WindowsMediaPlayer"; Name = "DisableAutoUpdate"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate"; Name = "workCompleted"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate"; Name = "workCompleted"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe"; Name = "BlockedOobeUpdaters"; Value = '["MS_Outlook"]'; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "HideMCTLink"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"; Name = "RestartNotificationsAllowed2"; Value = 0; Type = "DWord" }

    # --- OPTIMIZING NETWORK SETTINGS ---
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters"; Name = "EnableNetbios"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp"; Name = "DisableWpad"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp"; Name = "EnableDefaultHttp2"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"; Name = "MaxNegativeCacheTtl"; Value = 5; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\BFE\Parameters\Policy\Options"; Name = "CollectConnections"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\BFE\Parameters\Policy\Options"; Name = "CollectNetEvents"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Services\Dhcp"; Name = "PdcActivationDisabled"; Value = 1; Type = "DWord" }

    # --- OPTIMIZING GRAPHIC DRIVERS ---
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "MiracastForceDisable"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "TdrDelay"; Value = 12; Type = "DWord" }
    @{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "WarpSupportsResourceResidency"; Value = 1; Type = "DWord" }

    # --- IMPROVING TELEMETRY ---
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableSoftLanding"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsSpotlightFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableCloudOptimizedContent"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableWindowsConsumerFeatures"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo"; Name = "DisabledByGroupPolicy"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowDesktopAnalyticsProcessing"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowDeviceNameInTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "MicrosoftEdgeDataOptIn"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowWUfBCloudProcessing"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowUpdateComplianceProcessing"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowCommercialDataPipeline"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DisableOneSettingsDownloads"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "DoNotShowFeedbackNotifications"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "AllowTelemetry"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "DoNotShowFeedbackNotifications"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform"; Name = "NoGenTicket"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "DontSendAdditionalData"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting"; Name = "LoggingDisabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "DefaultConsent"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\Software\Microsoft\Windows\Windows Error Reporting\Consent"; Name = "DefaultOverrideBehavior"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "Disabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "LoggingDisabled"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DisableArchive"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"; Name = "DisableWerUpload"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsCopilot"; Name = "DisableAIDataAnalysis"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"; Name = "TurnOffWindowsCopilot"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\Shell\Copilot\BingChat"; Name = "IsUserEligible"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"; Name = "AutoOpenCopilotLargeScreens"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "ShowCopilotButton"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage\ShowJumpView"; Name = "Microsoft.Copilot_8wekyb3d8bbwe!App"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization"; Name = "AllowInputPersonalization"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\HandwritingErrorReports"; Name = "PreventHandwritingErrorReports"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\TabletPC"; Name = "PreventHandwritingDataSharing"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps"; Name = "AllowUntriggeredNetworkTrafficOnSettingsPage"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Maps"; Name = "AutoDownloadAndUpdateMapData"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Input\TIPC"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"; Name = "AllowNewsAndInterests"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\TextInput"; Name = "AllowLinguisticDataCollection"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\ProtectedEventLogging"; Name = "EnableProtectedEventLogging"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338393Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353694Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353696Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338387Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "ContentDeliveryAllowed"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy"; Name = "HasAccepted"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Personalization\Settings"; Name = "AcceptedPrivacyPolicy"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Siuf\Rules"; Name = "NumberOfSIUFInPeriod"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\InputPersonalization\TrainedDataStore"; Name = "HarvestContacts"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Input\TIPC"; Name = "Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI"; Name = "DisableAIDataAnalysis"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\Software\Policies\Microsoft\Windows\WindowsAI"; Name = "AllowRecallEnablement"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Siuf\Rules"; Name = "PeriodInNanoSeconds"; Value = ""; Type = "String" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy"; Name = "TailoredExperiencesWithDiagnosticDataEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"; Name = "DisableTailoredExperiencesWithDiagnosticData"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "EnableActivityFeed"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "PublishUserActivities"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "UploadUserActivities"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\MdmCommon\SettingValues"; Name = "LocationSyncEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\FindMyDevice"; Name = "AllowFindMyDevice"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\InputPersonalization"; Name = "RestrictImplicitInkCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKCU:\SOFTWARE\Microsoft\InputPersonalization"; Name = "RestrictImplicitTextCollection"; Value = 1; Type = "DWord" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "MaxTelemetryAllowed"; Value = 0; Type = "DWord" }
)

foreach ($Tweak in $Tweaks) {
    Set-Registry -Path $Tweak.Path -Name $Tweak.Name -Value $Tweak.Value -Type $Tweak.Type
}

# --- EXTENDED EXECUTION HOOKS ---
try {
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate" -Recurse -Force -ErrorAction SilentlyContinue
} catch {}

# Disable 'Group By' in the Downloads folder
try {
    $folderTypesKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FolderTypes'
    $downloadsFolderID = '{885a186e-a440-4ada-812b-db871b942259}'
    $path = Join-Path -Path $folderTypesKey -ChildPath $downloadsFolderID
    Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
        if ($null -ne $props -and $null -ne $props.GroupBy) {
            Set-ItemProperty -Path $_.PSPath -Name GroupBy -Value '' -ErrorAction SilentlyContinue
        }
    }
} catch { }

# Refresh Bags
try {
    $bagsPath = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags'
    if (Test-Path -Path $bagsPath) {
        Get-ChildItem -Path $bagsPath -ErrorAction SilentlyContinue | ForEach-Object {
            $fullPath = Join-Path -Path $_.PSPath -ChildPath 'Shell\{885A186E-A440-4ADA-812B-DB871B942259}'
            if (Test-Path -Path $fullPath) {
                Remove-Item -Path $fullPath -Recurse -Force -ErrorAction SilentlyContinue
            } 
        }
    }
} catch { }

Status "registry optimization complete." "done"

# services and drivers
Status "optimizing svchost split threshold..." "step"
Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "SvcHostSplitThresholdInKB" -Value 0xffffffff -Type "DWord"

Status "enforcing service grouping for all svchost instances..." "step"
$Services = Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Services" -ErrorAction SilentlyContinue
foreach ($S in $Services) {
    try {
        $ImagePath = (Get-ItemProperty -Path $S.PSPath -Name "ImagePath" -ErrorAction SilentlyContinue).ImagePath
        if ($ImagePath -match "svchost\.exe") {
            Set-Registry -Path $S.PSPath -Name "SvcHostSplitDisable" -Value 1 -Type "DWord"
        }
    } catch { }
}

Status "configuring system service startup types..." "step"
$ServiceTweaks = @(
    # Core Telemetry & Sync
    @{ Name = "DiagTrack"; Start = 4 }
    @{ Name = "dmwappushservice"; Start = 4 }
    @{ Name = "Telemetry"; Start = 4 }
    @{ Name = "diagnosticshub.standardcollector.service"; Start = 4 }
    @{ Name = "InventorySvc"; Start = 4 }
    @{ Name = "CDPUserSvc"; Start = 4 }
    # Diagnostics & Error Reporting
    @{ Name = "WerSvc"; Start = 4 }
    @{ Name = "wercplsupport"; Start = 4 }
    @{ Name = "DPS"; Start = 4 }
    @{ Name = "WdiServiceHost"; Start = 4 }
    @{ Name = "WdiSystemHost"; Start = 4 }
    @{ Name = "troubleshootingsvc"; Start = 4 }
    @{ Name = "diagsvc"; Start = 4 }
    @{ Name = "PcaSvc"; Start = 4 }
    # Cloud & Retail 
    @{ Name = "RetailDemo"; Start = 4 }
    @{ Name = "MapsBroker"; Start = 4 }
    @{ Name = "edgeupdate"; Start = 4 }
    @{ Name = "Wecsvc"; Start = 4 }
    # System Components
    @{ Name = "SysMain"; Start = 4 }
    @{ Name = "wisvc"; Start = 4 }
    @{ Name = "svsvc"; Start = 4 }
    @{ Name = "UCPD"; Start = 4 }
    @{ Name = "GraphicsPerfSvc"; Start = 4 }
    @{ Name = "Ndu"; Start = 4 }
    @{ Name = "dusmsvc"; Start = 4 }
    @{ Name = "DSSvc"; Start = 4 }
    @{ Name = "WSAIFabricSvc"; Start = 4 }
    # Printing & Scanning
    @{ Name = "Spooler"; Start = 4 }
    @{ Name = "printworkflowusersvc"; Start = 4 }
    @{ Name = "stisvc"; Start = 4 }
    @{ Name = "PrintNotify"; Start = 4 }
    @{ Name = "usbprint"; Start = 4 }
    @{ Name = "PrintScanBrokerService"; Start = 4 }
    @{ Name = "PrintDeviceConfigurationService"; Start = 4 }
    # Remote Desktop & Terminal Services
    @{ Name = "TermService"; Start = 4 }
    @{ Name = "UmRdpService"; Start = 4 }
    @{ Name = "SessionEnv"; Start = 4 }
    # Networking & Energy
    @{ Name = "NetBT"; Start = 4 }
    @{ Name = "tcpipreg"; Start = 4 }
    @{ Name = "GpuEnergyDrv"; Start = 4 }
    # Hyper-V / Virtualization
    @{ Name = "McpManagementService"; Start = 4 }
    @{ Name = "bttflt"; Start = 4 }
    @{ Name = "gencounter"; Start = 4 }
    @{ Name = "hyperkbd"; Start = 4 }
    @{ Name = "hypervideo"; Start = 4 }
    @{ Name = "spaceparser"; Start = 4 }
    @{ Name = "storflt"; Start = 4 }
    @{ Name = "vmgid"; Start = 4 }
    @{ Name = "vpci"; Start = 4 }
    @{ Name = "vid"; Start = 4 }
    # Miscellaneous / Low Level
    @{ Name = "dam"; Start = 4 }
    @{ Name = "CSC"; Start = 4 }
    @{ Name = "CSCSERVICE"; Start = 4 }
    @{ Name = "condrv"; Start = 2 }
)

foreach ($T in $ServiceTweaks) {
    if (Get-Service -Name $T.Name -ErrorAction SilentlyContinue) {
        $SType = switch($T.Start) { 2 { "Automatic" } 3 { "Manual" } 4 { "Disabled" } }
        Set-Service -Name $T.Name -StartupType $SType -ErrorAction SilentlyContinue
        Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($T.Name)" -Name "Start" -Value $T.Start -Type "DWord"
    }
}

Status "disabling background system tasks..." "step"
$TasksToDisable = @(
    "Microsoft\Windows\AppxDeploymentClient\UCPD Velocity",
    "Microsoft\Windows\ExploitGuard\ExploitGuard MDM Policy Refresh",
    "Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance",
    "Microsoft\Windows\Windows Defender\Windows Defender Cleanup",
    "Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan",
    "Microsoft\Windows\Windows Defender\Windows Defender Verification",
    "Microsoft\Windows\Defrag\ScheduledDefrag"
)
foreach ($Task in $TasksToDisable) {
    Disable-ScheduledTask -TaskPath "\" -TaskName ($Task -split "\\")[-1] -ErrorAction SilentlyContinue | Out-Null
}

Status "performing post-optimization system tweaks..." "step"

# privacy & security: clear app permissions (resets capability consent storage to default/deny)
Status "resetting privacy & security app permissions database..." "step"
Stop-Service -Name 'camsvc' -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityConsentStorage.db*" -Force -ErrorAction SilentlyContinue

# memory & storage: disable compression and suspend active bitlocker drives
Status "optimizing memory & storage security..." "step"
Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null
Get-BitLockerVolume -ErrorAction SilentlyContinue | Where-Object { $_.ProtectionStatus -eq "On" } | Disable-BitLocker -ErrorAction SilentlyContinue | Out-Null

# network: tcp latency, interface offloading & power states
Status "optimizing network logic (latency, nagle's algorithm & adapter sleep)..." "step"
'ms_lldp', 'ms_lltdio', 'ms_implat', 'ms_rspndr', 'ms_tcpip6', 'ms_server', 'ms_msclient', 'ms_pacer' | ForEach-Object {
    Disable-NetAdapterBinding -Name "*" -ComponentID $_ -ErrorAction SilentlyContinue
}

Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -ErrorAction SilentlyContinue | ForEach-Object {
    $P = $_.PSPath
    Set-Registry -Path $P -Name "TcpAckFrequency" -Value 1 -Type "DWord"
    Set-Registry -Path $P -Name "TCPNoDelay" -Value 1 -Type "DWord"
}

Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}" -ErrorAction SilentlyContinue | ForEach-Object {
    $P = $_.PSPath
    $HasSpeedDuplex = Get-ItemProperty -Path $P -Name "*SpeedDuplex" -ErrorAction SilentlyContinue
    if ($HasSpeedDuplex -and -not (Get-ItemProperty -Path $P -Name "*PhyType" -ErrorAction SilentlyContinue)) {
        "EnablePME", "*DeviceSleepOnDisconnect", "*EEE", "AdvancedEEE", "*SipsEnabled", "EnableAspm", "ASPM", "*ModernStandbyWoLMagicPacket", "*SelectiveSuspend", "EnableGigaLite", "GigaLite", "*WakeOnMagicPacket", "*WakeOnPattern", "AutoPowerSaveModeEnabled", "EEELinkAdvertisement", "EeePhyEnable", "EnableGreenEthernet", "EnableModernStandby", "PowerDownPll", "PowerSavingMode", "ReduceSpeedOnPowerDown", "S5WakeOnLan", "SavePowerNowEnabled", "ULPMode", "WakeOnLink", "WakeOnSlot", "WakeOnLinkChg", "WakeOnLinkUp", "WakeUpModeCap", "*NicAutoPowerSaver", "PowerSaveEnable", "EnablePowerManagement", "ForceWakeFromMagicPacketOnModernStandby", "WakeFromS5", "WakeOn", "EnableSavePowerNow", "*EnableDynamicPowerGating", "DynamicPowerGating", "EnableD3ColdInS0", "WakeFromPowerOff", "LogLinkStateEvent" | ForEach-Object {
            if ($null -ne (Get-ItemProperty -Path $P -Name $_ -ErrorAction SilentlyContinue)) {
                Set-Registry -Path $P -Name $_ -Value "0" -Type "String"
            }
        }
        
        if ($null -ne (Get-ItemProperty -Path $P -Name "PnPCapabilities" -ErrorAction SilentlyContinue)) { Set-Registry -Path $P -Name "PnPCapabilities" -Value 24 -Type "DWord" }
        if ($null -ne (Get-ItemProperty -Path $P -Name "WakeOnMagicPacketFromS5" -ErrorAction SilentlyContinue)) { Set-Registry -Path $P -Name "WakeOnMagicPacketFromS5" -Value "2" -Type "String" }
        if ($null -ne (Get-ItemProperty -Path $P -Name "WolShutdownLinkSpeed" -ErrorAction SilentlyContinue)) { Set-Registry -Path $P -Name "WolShutdownLinkSpeed" -Value "2" -Type "String" }
    }
}

Set-Registry -Path "HKLM:\System\CurrentControlSet\Services\Dnscache\Parameters" -Name "DisableCoalescing" -Value 1 -Type "DWord"
Set-Registry -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\Local" -Name "fDisablePowerManagement" -Value 1 -Type "DWord"
Set-Registry -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WcmSvc\GroupPolicy" -Name "fDisablePowerManagement" -Value 1 -Type "DWord"

# notifications: priority-only prompt blob injection
Status "disabling priority-only notification prompts..." "step"
$PriorityBlob = [byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xDF,0xB8,0xB4,0xCC,0x06,0x2A,0x2B,0x0E,0xD0,0x03,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xCD,0x14,0x06,0x02,0x05,0x00,0x00,0x01,0x01,0x02,0x00,0x03,0x01,0x04,0x00,0xCC,0x32,0x12,0x05,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x53,0x00,0x63,0x00,0x72,0x00,0x65,0x00,0x65,0x00,0x6E,0x00,0x53,0x00,0x6B,0x00,0x65,0x00,0x74,0x00,0x63,0x00,0x68,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x29,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x57,0x00,0x69,0x00,0x6E,0x00,0x64,0x00,0x6F,0x00,0x77,0x00,0x73,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x31,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x58,0x00,0x62,0x00,0x6F,0x00,0x78,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x2D,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x58,0x00,0x62,0x00,0x6F,0x00,0x78,0x00,0x47,0x00,0x61,0x00,0x6D,0x00,0x69,0x00,0x6E,0x00,0x67,0x00,0x4F,0x00,0x76,0x00,0x65,0x00,0x72,0x00,0x6C,0x00,0x61,0x00,0x79,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x29,0x57,0x00,0x69,0x00,0x6E,0x00,0x64,0x00,0x6F,0x00,0x77,0x00,0x73,0x00,0x2E,0x00,0x53,0x00,0x79,0x00,0x73,0x00,0x74,0x00,0x65,0x00,0x6D,0x00,0x2E,0x00,0x4E,0x00,0x65,0x00,0x61,0x00,0x72,0x00,0x53,0x00,0x68,0x00,0x61,0x00,0x72,0x00,0x65,0x00,0x45,0x00,0x78,0x00,0x70,0x00,0x65,0x00,0x72,0x00,0x69,0x00,0x65,0x00,0x6E,0x00,0x63,0x00,0x65,0x00,0x52,0x00,0x65,0x00,0x63,0x00,0x65,0x00,0x69,0x00,0x76,0x00,0x65,0x00,0x00,0x00,0x00,0x00)

Get-ChildItem -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current" -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\{[a-f0-9-]+\}\$' } | ForEach-Object {
        $Guid = ($_.PSChildName -split '\$')[0]
        $Targ = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\$Guid`$windows.data.donotdisturb.quiethoursprofile`$quiethoursprofilelist\windows.data.donotdisturb.quiethoursprofile`$microsoft.quiethoursprofile.priorityonly"
        Set-Registry -Path $Targ -Name "Data" -Value $PriorityBlob -Type "Binary"
    }

# hive config: disable windows client cbs, original apps & autoplay settings natively
Status "optimizing windows client session apps & hive settings..." "step"
"AppActions", "CrossDeviceResume", "DesktopStickerEditorWin32Exe", "DiscoveryHubApp", "FESearchHost", "SearchHost", "SoftLandingTask", "TextInputHost", "VisualAssistExe", "WebExperienceHostApp", "WindowsBackupClient", "WindowsMigration" | ForEach-Object {
    Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

$SettingsDat = "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Settings\settings.dat"
if (Test-Path $SettingsDat) {
    reg load "HKLM\Settings" $SettingsDat 2>$null
    if ($LASTEXITCODE -eq 0) {
        $State = "HKLM:\Settings\LocalState"
        $Val1  = [byte[]](0x01,0x61,0xed,0x11,0x34,0xf7,0x9f,0xdc,0x01)
        
        Set-Registry -Path "$State\DisabledApps" -Name "Microsoft.Paint_8wekyb3d8bbwe" -Value $Val1 -Type "Binary"
        Set-Registry -Path "$State\DisabledApps" -Name "Microsoft.Windows.Photos_8wekyb3d8bbwe" -Value $Val1 -Type "Binary"
        Set-Registry -Path "$State\DisabledApps" -Name "MicrosoftWindows.Client.CBS_cw5n1h2txyewy" -Value $Val1 -Type "Binary"
        
        Set-Registry -Path $State -Name "VideoAutoplay" -Value ([byte[]](0x00,0x96,0x9d,0x69,0x8d,0xcd,0x93,0xdc,0x01)) -Type "Binary"
        Set-Registry -Path $State -Name "EnableAppInstallNotifications" -Value ([byte[]](0x00,0x36,0xd0,0x88,0x8e,0xcd,0x93,0xdc,0x01)) -Type "Binary"
        Set-Registry -Path "$State\PersistentSettings" -Name "PersonalizationEnabled" -Value ([byte[]](0x00,0x0d,0x56,0xa1,0x8a,0xcd,0x93,0xdc,0x01)) -Type "Binary"

        [GC]::Collect()
        Start-Sleep -Seconds 1
        reg unload "HKLM\Settings" 2>$null | Out-Null
    }
}

# power 
Status "deploying albus core power policy..." "step"
$PowerSaverGUID = "a1841308-3541-4fab-bc81-f71556f20b4a"

& powercfg -restoredefaultschemes 2>&1 | Out-Null
& powercfg /SETACTIVE $PowerSaverGUID 2>&1 | Out-Null

$AlbusGUID = ""
$duplicateOutput = & powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
if ($duplicateOutput -match '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') {
    $AlbusGUID = $Matches[1]
} else {
    $AlbusGUID = "99999999-9999-9999-9999-999999999999"
    & powercfg /delete $AlbusGUID 2>&1 | Out-Null
    & powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $AlbusGUID 2>&1 | Out-Null
}

& powercfg /changename $AlbusGUID "Albus" "optimized for minimal latency, deep unparking, and peak hardware throughput." 2>&1 | Out-Null

$PList = & powercfg /l 2>$null | Out-String

if (-not [string]::IsNullOrEmpty($PList)) {
    $PList -split "`r?`n" | ForEach-Object {
        if ($_ -match ':') {
            $parse = $_ -split ':'
            if ($parse.Count -gt 1) {
                $index = $parse[1].Trim().IndexOf('(')
                if ($index -gt 0) {
                    $guid = $parse[1].Trim().Substring(0, $index).Trim()
                    if ($guid -ne $AlbusGUID -and $guid -ne $PowerSaverGUID -and $guid.Length -ge 36) {
                        & powercfg /delete $guid 2>&1 | Out-Null
                    }
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
        & { 
            trap { continue }
            powercfg /setacvalueindex $AlbusGUID $s $i $v 2>$null | Out-Null
            powercfg /setdcvalueindex $AlbusGUID $s $i $v 2>$null | Out-Null
        }
    }
}

& powercfg /SETACTIVE $AlbusGUID 2>&1 | Out-Null

# 4. global performance tweaks
& { powercfg /hibernate off } 2>$null | Out-Null
@("HKLM:\SYSTEM\CurrentControlSet\Control\Power|HibernateEnabled|0",
  "HKLM:\SYSTEM\CurrentControlSet\Control\Power|HibernateEnabledDefault|0",
  "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power|HiberbootEnabled|0",
  "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling|PowerThrottlingOff|1",
  "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings|ShowLockOption|0",
  "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings|ShowSleepOption|0") | ForEach-Object {
    $p = $_ -split '\|'; Set-Registry -Path $p[0] -Name $p[1] -Value $p[2]
}
$MonStore = Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore" -Recurse -ErrorAction SilentlyContinue
foreach ($M in $MonStore) { Set-Registry -Path $M.PSPath -Name "AutoColorManagementEnabled" -Value 0 }

Status "deploying albus core optimization engine..." "step"
$Exe = "$env:SystemRoot\AlbusX.exe"
$Svc = "AlbusXSvc"

# cleanup legacy deployment & enforce fresh install
if (Get-Service $Svc -ErrorAction Ignore) { Stop-Service $Svc -Force -ErrorAction Ignore; sc.exe delete $Svc >$null 2>&1 }
if (Test-Path $Exe) { Remove-Item $Exe -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

# fetch & compile payload
Status "fetching & compiling albus native payload..." "info"
$CS = "$env:SystemRoot\AlbusX.cs"
$CSC = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
try { Invoke-WebRequest "https://raw.githubusercontent.com/oqullcan/blablabla/main/albus/albus.cs" -OutFile $CS -UseBasicParsing -ErrorAction Stop } catch {}

if ((Test-Path $CS) -and (Test-Path $CSC)) {
    & $CSC -r:System.ServiceProcess.dll -r:System.Configuration.Install.dll -r:System.Management.dll -out:"$Exe" "$CS" >$null 2>&1
    Remove-Item $CS -Force -ErrorAction SilentlyContinue
}

# deploy & execute service
if (Test-Path $Exe) {
    Status "installing albus core system service..." "info"
    New-Service -Name $Svc -BinaryPathName $Exe -DisplayName "AlbusX" -Description "Albus Core Engine. Enforces sub-millisecond kernel timer resolution, audio thread prioritization, and continuous low-latency system optimizations." -StartupType Automatic -ErrorAction SilentlyContinue | Out-Null
    sc.exe failure $Svc reset= 60 actions= restart/5000/restart/10000/restart/30000 >$null 2>&1
    Start-Service $Svc -ErrorAction SilentlyContinue | Out-Null
    Status "albus service, timer resolution & audio is active." "done"
} else { Status "engine payload deployment failed." "warn" }

Status "enforcing global kernel timer resolution requests..." "step"
Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel" -Name "GlobalTimerResolutionRequests" -Value 1 -Type "DWord"

# system-wide process mitigations (exploit guard)
Status "disabling system-wide exploit guard mitigations..." "step"
(Get-Command -Name 'Set-ProcessMitigation' -ErrorAction SilentlyContinue).Parameters['Disable'].Attributes.ValidValues | ForEach-Object {
    Set-ProcessMitigation -SYSTEM -Disable $_.ToString() -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
}

# ifeo & kernel mitigation payload (inject binary 0x22 to core procs)
Status "injecting exploit guard bypass payload to core processes..." "step"
$KernelPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel"
$AuditVal = Get-ItemProperty -Path $KernelPath -Name "MitigationAuditOptions" -ErrorAction SilentlyContinue
$Len = if ($AuditVal.MitigationAuditOptions) { $AuditVal.MitigationAuditOptions.Length } else { 38 }
[byte[]]$Payload = [System.Linq.Enumerable]::Repeat([byte]34, $Len)

"fontdrvhost.exe", "dwm.exe", "lsass.exe", "svchost.exe", "WmiPrvSE.exe", "winlogon.exe", "csrss.exe", "audiodg.exe", "ntoskrnl.exe", "services.exe", "explorer.exe", "taskhostw.exe", "sihost.exe" | ForEach-Object {
    $P = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$_"
    Set-Registry -Path $P -Name "MitigationOptions" -Value $Payload -Type "Binary"
    Set-Registry -Path $P -Name "MitigationAuditOptions" -Value $Payload -Type "Binary"
}
Set-Registry -Path $KernelPath -Name "MitigationOptions" -Value $Payload -Type "Binary"
Set-Registry -Path $KernelPath -Name "MitigationAuditOptions" -Value $Payload -Type "Binary"

# intel tsx (transactional synchronization extensions)
Status "optimizing intel tsx (transactional synchronization)..." "step"
if ((Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue).Manufacturer -eq 'GenuineIntel') {
    Set-Registry -Path $KernelPath -Name "DisableTSX" -Value 0 -Type "DWord"
} else { Remove-ItemProperty -Path $KernelPath -Name "DisableTSX" -ErrorAction SilentlyContinue }

# ghost devices cleanup
Status "removing ghost/hidden pnp devices (cleaning leftovers)..." "step"
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { -not $_.Present -and $_.InstanceId -notmatch '^(ROOT|SWD|HTREE|DISPLAY|BTHENUM)\\' } | ForEach-Object {
    pnputil /remove-device $_.InstanceId /quiet >$null 2>&1
}

# disk cache optimization
Status "optimizing internal storage write-cache performance..." "step"
Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceType -ne "USB" -and $_.PNPDeviceID } | ForEach-Object {
    $P = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.PNPDeviceID)\Device Parameters\Disk"
    Set-Registry -Path $P -Name "UserWriteCacheSetting" -Value 1
    Set-Registry -Path $P -Name "CacheIsPowerProtected" -Value 1
}

# aggressive deep device power saving disable
Status "disabling aggressive power saving for all hardware classes..." "step"
Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.Status -match 'OK|Unknown' } | ForEach-Object {
    $I = $_.InstanceId; $P = "HKLM:\SYSTEM\CurrentControlSet\Enum\$I\Device Parameters"
    
    Set-Registry -Path "$P\WDF" -Name "IdleInWorkingState" -Value 0
    "SelectiveSuspendEnabled", "SelectiveSuspendOn", "EnhancedPowerManagementEnabled", "WaitWakeEnabled" | ForEach-Object {
        Set-Registry -Path $P -Name $_ -Value 0
    }
    
    Get-WmiObject -Class MSPower_DeviceEnable -Namespace root\wmi -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -like "*$($I.Replace('\', '\\'))*" } | ForEach-Object { $_.Enable = $false; $_.Put() | Out-Null }
}

# dma remapping & kernel guard policy
Status "optimizing dma remapping & kernel guard policy..." "step"
Set-Registry -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\DmaGuard\DeviceEnumerationPolicy" -Name "value" -Value 2
Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Services" -ErrorAction SilentlyContinue | ForEach-Object {
    $P = "$($_.Name.Replace('HKEY_LOCAL_MACHINE', 'HKLM'))\Parameters"
    if ((Get-ItemProperty $P -Name "DmaRemappingCompatible" -ErrorAction SilentlyContinue) -ne $null) {
        Set-Registry -Path $P -Name "DmaRemappingCompatible" -Value 0
    }
}

# winevt
Status "disabling winevt diagnostic channels..." "step"
try {
    $channelsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WINEVT\Channels'
    Get-ChildItem -Path $channelsPath -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $enabledProp = Get-ItemProperty -Path $_.PSPath -Name 'Enabled' -ErrorAction SilentlyContinue
            if ($null -ne $enabledProp -and $enabledProp.Enabled -eq 1) { 
                Set-ItemProperty -Path $_.PSPath -Name 'Enabled' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue 
            }
        } catch {}
    }
} catch {}

# ntfs
Status "optimizing ntfs behaviors..." "step"
& fsutil behavior set disable8dot3 1 2>&1 | Out-Null
& fsutil behavior set disabledeletenotify 0 2>&1 | Out-Null
& fsutil behavior set disablelastaccess 1 2>&1 | Out-Null
& fsutil behavior set encryptpagingfile 0 2>&1 | Out-Null

# bcdedit
Status "applying bcdedit boot optimizations..." "step"
& bcdedit.exe /deletevalue useplatformclock 2>&1 | Out-Null
& bcdedit.exe /deletevalue useplatformtick 2>&1 | Out-Null
& bcdedit.exe /set bootmenupolicy legacy 2>&1 | Out-Null
& bcdedit.exe /timeout 10 2>&1 | Out-Null
& label C: Albus 2>&1 | Out-Null
& bcdedit.exe /set "{current}" description "Albus Playbook" 2>&1 | Out-Null

# ui & shell optimization
Status "applying ui & shell settings..." "step"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction SilentlyContinue 
$SW = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width
$SH = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Height
$BlackFile = "C:\Windows\Wallpaper.jpg"
if (-not (Test-Path $BlackFile)) {
    try {
        $Bmp = New-Object System.Drawing.Bitmap $SW, $SH
        $Gfx = [System.Drawing.Graphics]::FromImage($Bmp)
        $Gfx.FillRectangle([System.Drawing.Brushes]::Black, 0, 0, $SW, $SH)
        $Gfx.Dispose(); $Bmp.Save($BlackFile); $Bmp.Dispose()
    } catch {}
}
# apply theme & wallpaper
Set-Registry -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Name "LockScreenImagePath" -Value $BlackFile -Type "String"
Set-Registry -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Name "LockScreenImageStatus" -Value 1 -Type "DWord"
Set-Registry -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -Value $BlackFile -Type "String"
rundll32.exe user32.dll, UpdatePerUserSystemParameters

# force tray icon visibility
$NotifySettings = Get-ChildItem -Path 'HKCU:\Control Panel\NotifyIconSettings' -Recurse -ErrorAction SilentlyContinue
foreach ($S in $NotifySettings) {
    Set-ItemProperty -Path $S.PSPath -Name 'IsPromoted' -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
}

# blackout account pictures
$AccountPicPaths = @("$env:SystemDrive\ProgramData\Microsoft\User Account Pictures", "$env:AppData\Microsoft\Windows\AccountPictures")
foreach ($PicPath in $AccountPicPaths) {
    if (Test-Path $PicPath) {
        $BackupPath = "$env:SystemDrive\ProgramData\User_Account_Pictures_Backup"
        if ($PicPath -match "ProgramData" -and !(Test-Path $BackupPath)) {
            Copy-Item $PicPath -Destination $BackupPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Get-ChildItem $PicPath -Include *.png,*.bmp,*.jpg -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $Img = [System.Drawing.Bitmap]::FromFile($_.FullName)
                $W = $Img.Width; $H = $Img.Height; $Img.Dispose()
                $NewImg = New-Object System.Drawing.Bitmap $W, $H
                $Gfx = [System.Drawing.Graphics]::FromImage($NewImg)
                $Gfx.Clear([System.Drawing.Color]::Black)
                $Gfx.Dispose()
                $Ext = [System.IO.Path]::GetExtension($_.FullName).ToLower()
                $Fmt = switch ($Ext) { ".png" { [System.Drawing.Imaging.ImageFormat]::Png }; ".bmp" { [System.Drawing.Imaging.ImageFormat]::Bmp }; Default { [System.Drawing.Imaging.ImageFormat]::Jpeg } }
                $NewImg.Save($_.FullName, $Fmt); $NewImg.Dispose()
            } catch {}
        }
    }
}

# unpin taskbar items
Set-Registry -Path "-HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" -Name "" -Value ""
Remove-Item -Recurse -Force "$env:USERPROFILE\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch" -ErrorAction SilentlyContinue | Out-Null

# context menu debloat
$MenuTweaks = @(
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoCustomizeThisFolder"; Value = 1 },
    @{ Path = "-HKCR:\Folder\shell\pintohome"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\*\shell\pintohomefile"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\exefile\shellex\ContextMenuHandlers\Compatibility"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\Folder\ShellEx\ContextMenuHandlers\Library Location"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo"; Name = ""; Value = "" },
    @{ Path = "-HKCR:\UserLibraryFolder\shellex\ContextMenuHandlers\SendTo"; Name = ""; Value = "" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "NoPreviousVersionsPage"; Value = 1 },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"; Name = "{9F156763-7844-4DC4-B2B1-901F640F5155}"; Value = ""; Type = "String" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"; Name = "{09A47860-11B0-4DA5-AFA5-26D86198A780}"; Value = ""; Type = "String" },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"; Name = "{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}"; Value = ""; Type = "String" }
)
foreach ($M in $MenuTweaks) { Set-Registry -Path $M.Path -Name $M.Name -Value $M.Value -Type $(if($M.Type){$M.Type}else{"DWord"}) }

# start menu reset & organization
if ([Environment]::OSVersion.Version.Major -eq 10 -and [Environment]::OSVersion.Version.Build -lt 22000) {
    $LayoutXML = 'C:\Windows\StartMenuLayout.xml'
    $XMLContent = @"
<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification">
    <LayoutOptions StartTileGroupCellWidth="6" />
    <DefaultLayoutOverride><StartLayoutCollection><defaultlayout:StartLayout GroupCellWidth="6" /></StartLayoutCollection></DefaultLayoutOverride>
</LayoutModificationTemplate>
"@
    Set-Content -Path $LayoutXML -Value $XMLContent -Force -Encoding ASCII
    foreach ($Hive in @("HKLM", "HKCU")) {
        $P = "${Hive}:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
        if (!(Test-Path $P)) { New-Item -Path $P -Force | Out-Null }
        Set-ItemProperty -Path $P -Name "LockedStartLayout" -Value 1 -Force
        Set-ItemProperty -Path $P -Name "StartLayoutFile" -Value $LayoutXML -Force
    }
    Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3
    foreach ($Hive in @("HKLM", "HKCU")) { Set-ItemProperty -Path "${Hive}:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "LockedStartLayout" -Value 0 -Force }
    Remove-Item -Path $LayoutXML -Force -ErrorAction SilentlyContinue
}
if ([Environment]::OSVersion.Version.Major -eq 10 -and [Environment]::OSVersion.Version.Build -ge 22000) {
    $Start2BinPath = "$env:USERPROFILE\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin"
    $StartBytes = [Convert]::FromBase64String("AgAAABAAAAD9////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==")
    Remove-Item -Path $Start2BinPath -Force -ErrorAction SilentlyContinue | Out-Null
    [System.IO.File]::WriteAllBytes($Start2BinPath, $StartBytes)
    Set-Registry -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start" -Name "AllAppsViewMode" -Value 2 -Type "DWord"
    Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue
}
# recycle bin shortcut
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Recycle Bin.lnk")
$Shortcut.TargetPath = '::{645ff040-5081-101b-9f08-00aa002f954e}'
$Shortcut.Save()
# hide accessories folders
@("$env:UserProfile\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Accessibility", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessibility", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories") | ForEach-Object { if (Test-Path $_) { attrib +h "$_" /s /d >$null 2>&1 } }

Status "removing system bloat (uwp, capabilities, legacy features)..." "step"
$UWPToKill = Get-AppxPackage -AllUsers | Where-Object {
    $_.Name -notlike '*CBS*' -and
    $_.Name -notlike '*Microsoft.AV1VideoExtension*' -and
    $_.Name -notlike '*Microsoft.AVCEncoderVideoExtension*' -and
    $_.Name -notlike '*Microsoft.HEIFImageExtension*' -and
    $_.Name -notlike '*Microsoft.HEVCVideoExtension*' -and
    $_.Name -notlike '*Microsoft.MPEG2VideoExtension*' -and
    $_.Name -notlike '*Microsoft.Paint*' -and
    $_.Name -notlike '*Microsoft.RawImageExtension*' -and
    $_.Name -notlike '*Microsoft.SecHealthUI*' -and
    $_.Name -notlike '*Microsoft.VP9VideoExtensions*' -and
    $_.Name -notlike '*Microsoft.WebMediaExtensions*' -and
    $_.Name -notlike '*Microsoft.WebpImageExtension*' -and
    $_.Name -notlike '*Microsoft.Windows.Photos*' -and
    $_.Name -notlike '*Microsoft.Windows.ShellExperienceHost*' -and
    $_.Name -notlike '*Microsoft.Windows.StartMenuExperienceHost*' -and
    $_.Name -notlike '*Microsoft.WindowsNotepad*' -and
    $_.Name -notlike '*Microsoft.WindowsStore*' -and
    $_.Name -notlike '*windows.immersivecontrolpanel*'
}
foreach ($App in $UWPToKill) {
    try {
        Remove-AppxPackage -Package $App.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
    } catch { }
}

Get-WindowsCapability -Online | Where-Object {
    $_.State -eq 'Installed' -and
    $_.Name -notlike '*Ethernet*' -and
    $_.Name -notlike '*MSPaint*' -and
    $_.Name -notlike '*Notepad*' -and
    $_.Name -notlike '*Wifi*' -and
    $_.Name -notlike '*NetFX3*' -and
    $_.Name -notlike '*VBSCRIPT*' -and
    $_.Name -notlike '*WMIC*' -and
    $_.Name -notlike '*ShellComponents*'
} | ForEach-Object { try { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null } catch {} }

Get-WindowsOptionalFeature -Online | Where-Object {
    $_.State -eq 'Enabled' -and
    $_.FeatureName -notlike '*DirectPlay*' -and
    $_.FeatureName -notlike '*LegacyComponents*' -and
    $_.FeatureName -notlike '*NetFx*' -and
    $_.FeatureName -notlike '*SearchEngine-Client*' -and
    $_.FeatureName -notlike '*Server-Shell*' -and
    $_.FeatureName -notlike '*Windows-Defender*' -and
    $_.FeatureName -notlike '*Drivers-General*' -and
    $_.FeatureName -notlike '*Server-Gui-Mgmt*' -and
    $_.FeatureName -notlike '*WirelessNetworking*'
} | ForEach-Object { try { Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -WarningAction SilentlyContinue | Out-Null } catch {} }

Status "uninstalling edge, onedrive, health tools, legacy apps..." "step"
# region spoof (us) to bypass restrictions
$OldRegion = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' -Name DeviceRegion -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' -Name DeviceRegion -Value 244 -Force -ErrorAction SilentlyContinue
# kill all edge & related processes
$EdgeProcs = "backgroundTaskHost", "Copilot", "CrossDeviceResume", "GameBar", "MicrosoftEdgeUpdate", "msedge", "msedgewebview2", "OneDrive", "OneDrive.Sync.Service", "OneDriveStandaloneUpdater", "Resume", "RuntimeBroker", "Search", "SearchHost", "Setup", "StoreDesktopExtension", "WidgetService", "Widgets"
$EdgeProcs | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Get-Process | Where-Object { $_.ProcessName -like "*edge*" } | Stop-Process -Force -ErrorAction SilentlyContinue
# registry clean: edgeupdate
$EdgeRegHives = "HKCU:\SOFTWARE", "HKLM:\SOFTWARE", "HKCU:\SOFTWARE\Policies", "HKLM:\SOFTWARE\Policies", "HKCU:\SOFTWARE\WOW6432Node", "HKLM:\SOFTWARE\WOW6432Node", "HKCU:\SOFTWARE\WOW6432Node\Policies", "HKLM:\SOFTWARE\WOW6432Node\Policies"
foreach ($H in $EdgeRegHives) { Remove-Item "$H\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue }
# uninstall update services
$EdgeUpdatePaths = @(); "LocalApplicationData", "ProgramFilesX86", "ProgramFiles" | ForEach-Object {
    $Root = [Environment]::GetFolderPath($_)
    $EdgeUpdatePaths += Get-ChildItem "$Root\Microsoft\EdgeUpdate\*.*.*.*\MicrosoftEdgeUpdate.exe" -Recurse -ErrorAction SilentlyContinue
}
foreach ($P in $EdgeUpdatePaths) {
    if (Test-Path $P) {
        Start-Process -Wait $P -ArgumentList "/unregsvc" -WindowStyle Hidden
        Start-Process -Wait $P -ArgumentList "/uninstall" -WindowStyle Hidden
    }
}
# force uninstall edge via native registry string
try {
    $EdgeUninstallKey = Get-Item "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" -ErrorAction SilentlyContinue
    if ($EdgeUninstallKey) {
        $UString = $EdgeUninstallKey.GetValue("UninstallString") + " --force-uninstall"
        Start-Process cmd.exe -ArgumentList "/c $UString" -WindowStyle Hidden -Wait
    }
} catch {}
# cleanup edge leftovers
$EdgeLeftovers = @(
    "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
    "$env:ProgramFiles (x86)\Microsoft",
    "$env:SystemDrive\Windows\System32\config\systemprofile\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk"
)
$EdgeLeftovers | ForEach-Object { if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue } }
# delete edge services
Get-Service | Where-Object { $_.Name -match 'Edge' } | ForEach-Object {
    sc.exe stop $_.Name >$null 2>&1
    sc.exe delete $_.Name >$null 2>&1
}
# windows 10: legacy edge package (dism)
$LegacyEdge = (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "*Microsoft-Windows-Internet-Browser-Package*~~*" }).PSChildName
if ($LegacyEdge) {
    $LPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$LegacyEdge"
    Set-Registry -Path $LPath -Name "Visibility" -Value 1
    $OwnersPath = "$LPath\Owners"
    if (Test-Path $OwnersPath) { Remove-Item -Path $OwnersPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
    dism.exe /online /Remove-Package /PackageName:$LegacyEdge /quiet /norestart >$null 2>&1
}
# revert region
if ($OldRegion) { Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' -Name DeviceRegion -Value $OldRegion -Force }

# onedrive
Stop-Process -Force -Name OneDrive -ErrorAction SilentlyContinue | Out-Null
$OneDriveSetups = @(
    "$env:SystemRoot\System32\OneDriveSetup.exe",
    "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
)
foreach ($O in $OneDriveSetups) { if (Test-Path $O) { Start-Process -Wait $O -ArgumentList "/uninstall" -WindowStyle Hidden } }
Get-ScheduledTask | Where-Object {$_.Taskname -match 'OneDrive'} | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

# update health tools & uhssvc
$UpdateTools = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName -match "Update for x64-based Windows Systems|Microsoft Update Health Tools" }
foreach ($T in $UpdateTools) {
    if ($T.PSChildName) { Start-Process "msiexec.exe" -ArgumentList "/x $($T.PSChildName) /qn /norestart" -Wait -NoNewWindow }
}
sc.exe delete "uhssvc" >$null 2>&1
Unregister-ScheduledTask -TaskName PLUGScheduler -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

# brlapi (braille display service - accessibility feature)
sc.exe stop "brlapi" >$null 2>&1; sc.exe delete "brlapi" >$null 2>&1
$BrlPath = "$env:SystemRoot\brltty"
if (Test-Path $BrlPath) {
    takeown /f "$BrlPath" /r /d y >$null 2>&1
    icacls "$BrlPath" /grant *S-1-5-32-544:F /t >$null 2>&1
    Remove-Item $BrlPath -Recurse -Force -ErrorAction SilentlyContinue
}

# remote desktop connection (mstsc)
try { Start-Process "mstsc" -ArgumentList "/Uninstall" -ErrorAction SilentlyContinue } catch {}
$MSTSCProc = Get-Process -Name mstsc -ErrorAction SilentlyContinue
if ($MSTSCProc) { $MSTSCProc | Stop-Process -Force -ErrorAction SilentlyContinue }

# legacy snipping tool (w10)
try { Start-Process "C:\Windows\System32\SnippingTool.exe" -ArgumentList "/Uninstall" -ErrorAction SilentlyContinue } catch {}
$SnipProc = Get-Process -Name SnippingTool -ErrorAction SilentlyContinue
if ($SnipProc) { $SnipProc | Stop-Process -Force -ErrorAction SilentlyContinue }

# microsoft gameinput
$GameInput = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName -like "*Microsoft GameInput*" }
if ($GameInput) {
    $Guid = $GameInput.PSChildName
    Start-Process "msiexec.exe" -ArgumentList "/x $Guid /qn /norestart" -Wait -NoNewWindow
}

# clearing all 3rd party startup applications, registry persistence, and scheduled tasks
Status "clearing all 3rd party startup applications, registry persistence, and scheduled tasks..." "step"
$RunKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunNotification",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
)
foreach ($Key in $RunKeys) {
    if (Test-Path $Key) {
        $RealPath = $Key.Replace("HKCU:", "HKEY_CURRENT_USER").Replace("HKLM:", "HKEY_LOCAL_MACHINE")
        reg.exe delete "$RealPath" /f /va >$null 2>&1
    }
}
$StartupFolders = @("$env:AppData\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp")
foreach ($F in $StartupFolders) {
    if (Test-Path $F) {
        Remove-Item -Path "$F\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}
$TaskTree = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree"
Get-ChildItem $TaskTree -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -ne "Microsoft" } | ForEach-Object {
    Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}
$TaskFiles = "$env:SystemRoot\System32\Tasks"
Get-ChildItem $TaskFiles -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "Microsoft" } | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}

# ================================================== #
#       graphics driver installation & debloat       #
# ================================================== #

function Show-GPU-Menu {
    Write-Host ""
    Write-Host "`n select graphics drivers" -ForegroundColor Yellow
    Write-Host " 1. nvidia" -ForegroundColor Green
    Write-Host " 2. amd" -ForegroundColor Red
    Write-Host " 3. skip`n" -ForegroundColor Gray
    Write-Host ""
}

:gpu while ($true) {
    Show-GPU-Menu
    $Choice = Read-Host " enter choice > "
    Write-Host ""
    if ($Choice -match '^[1-3]$') {
        switch ($Choice) {
            1 {
                Status "starting nvidia gpu driver procedure..." "step"
                
                # Step 1: Download
                Status "opening default browser for driver download..." "info"
                Start-Process "https://www.nvidia.com/en-us/drivers"
                
                Write-Host "`nplease download the driver and press any key to continue..." -ForegroundColor Yellow
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                
                # Step 2: Select File
                Status "waiting for file selection..." "step"
                Add-Type -AssemblyName System.Windows.Forms
                $Dialog = New-Object System.Windows.Forms.OpenFileDialog
                $Dialog.Title = "select the downloaded nvidia driver installer"
                $Dialog.Filter = "NVIDIA Installer (*.exe)|*.exe|All Files (*.*)|*.*"
                if ($Dialog.ShowDialog() -eq "OK") {
                    $InstallFile = $Dialog.FileName
                    
                    # Step 3: Extract & Debloat
                    Status "extracting and debloating driver (this may take a minute)..." "step"
                    $ExtractPath = "$env:SystemRoot\Temp\NVIDIA"
                    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
                    
                    $ZipPath = "C:\Program Files\7-Zip\7z.exe"
                    if (Test-Path $ZipPath) {
                        & $ZipPath x "$InstallFile" -o"$ExtractPath" -y | Out-Null
                    } else {
                        Status "7-zip not found! debloat aborted." "fail"
                        pause; break
                    }

                    # aggressive strip-down (whitelist approach)
                    Status "executing aggressive strip-down (keeping core only)..." "step"
                    $Whitelist = @("Display.Driver", "NVI2", "EULA.txt", "ListDevices.txt", "setup.cfg", "setup.exe")
                    Get-ChildItem -Path $ExtractPath | ForEach-Object {
                        if ($Whitelist -notcontains $_.Name) {
                            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                    }

                    # step 4: patch setup.cfg (remove consent/eula lines)
                    Status "patching setup.cfg for silent install..." "info"
                    $CfgPath = Join-Path $ExtractPath "setup.cfg"
                    if (Test-Path $CfgPath) {
                        (Get-Content $CfgPath) | Where-Object {
                            $_ -notmatch 'EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile'
                        } | Set-Content $CfgPath -Force
                    }

                    # step 5: silent install
                    Status "executing clean driver installation..." "step"
                    $Setup = "$ExtractPath\setup.exe"
                    if (Test-Path $Setup) {
                        Start-Process $Setup -ArgumentList "-s -noreboot -noeula -clean" -Wait -NoNewWindow
                        Status "nvidia driver installation complete." "done"
                        
                    # step 6: post-installation performance tuning
                    Status "applying advanced nvidia performance tweaks..." "step"
                        
                    # class id based tweaks (p-state, hdcp, profiling)
                    $GPUClasses = Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}" -ErrorAction SilentlyContinue
                    foreach ($C in $GPUClasses) {
                        if ($C.PSChildName -match '^\d{4}$') {
                            Set-Registry -Path $C.PSPath -Name "DisableDynamicPstate" -Value 1
                            Set-Registry -Path $C.PSPath -Name "RMHdcpKeyglobZero" -Value 1
                            Set-Registry -Path $C.PSPath -Name "RmProfilingAdminOnly" -Value 0
                        }
                    }

                    # nvtweak / fts / tray
                    Set-Registry -Path "HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak" -Name "NvCplPhysxAuto" -Value 0
                    Set-Registry -Path "HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak" -Name "NvDevToolsVisible" -Value 1
                    Set-Registry -Path "HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak" -Name "RmProfilingAdminOnly" -Value 0
                    Set-Registry -Path "HKCU:\Software\NVIDIA Corporation\NvTray" -Name "StartOnLogin" -Value 0
                    Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS" -Name "EnableGR535" -Value 0
                    Set-Registry -Path "HKLM:\SYSTEM\ControlSet001\Services\nvlddmkm\Parameters\FTS" -Name "EnableGR535" -Value 0
                        
                    # unblock drs files
                    $DRSPath = "C:\ProgramData\NVIDIA Corporation\Drs"
                    if (Test-Path $DRSPath) { Get-ChildItem -Path $DRSPath -Recurse | Unblock-File -ErrorAction SilentlyContinue }

                    # step 7: nvidia profile inspector (download & apply)
                    Status "fetching latest nvidia profile inspector from github..." "step"
                    $InspectorZip = "$env:SystemRoot\Temp\nvidiaProfileInspector.zip"
                    $ExtractDir = "$env:SystemRoot\Temp\nvidiaProfileInspector"
                        
                    try {
                        $Repo = "Orbmu2k/nvidiaProfileInspector"
                        $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -ErrorAction Stop
                        $Asset = ($Release.assets | Where-Object { $_.name -like "*.zip" })[0]
                        if ($Asset) {
                            Status "downloading $($Asset.name)..." "info"
                            Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $InspectorZip -UseBasicParsing -ErrorAction Stop
                                
                            # extract using 7z
                            $ZipPath = "C:\Program Files\7-Zip\7z.exe"
                            if (Test-Path $ZipPath) {
                                & $ZipPath x "$InspectorZip" -o"$ExtractDir" -y | Out-Null
                            }
                        }
                    } catch { Status "failed to download nvidia profile inspector online." "warn" }

                    Status "configuring nvidia profile inspector settings..." "step"
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
                        $NIPPath = "$env:SystemRoot\Temp\inspector.nip"
                        $NIPFile | Set-Content $NIPPath -Force
                        $InspectorExe = Get-ChildItem -Path $ExtractDir -Filter "*nvidiaProfileInspector.exe" -Recurse | Select-Object -First 1
                        if ($InspectorExe) {
                            Start-Process $InspectorExe.FullName -ArgumentList "-silentImport $NIPPath" -Wait -NoNewWindow
                        }
                        Status "nvidia performance profile applied." "done"
                    } else {
                        Status "setup.exe not found in extracted files!" "fail"
                    }
                } else {
                    Status "selection cancelled." "warn"
                }
                pause
            }
            2 {
                Status "starting amd gpu driver procedure..." "step"

                # step 1: download
                Status "opening default browser for amd support..." "info"
                Start-Process "https://www.amd.com/en/support/download/drivers.html"
                Write-Host "`nplease download the adrenalin driver and press any key to continue..." -ForegroundColor Yellow
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

                # step 2: select file
                Status "waiting for file selection..." "step"
                Add-Type -AssemblyName System.Windows.Forms
                $Dialog = New-Object System.Windows.Forms.OpenFileDialog
                $Dialog.Title = "select the downloaded amd driver installer"
                $Dialog.Filter = "AMD Installer (*.exe)|*.exe|All Files (*.*)|*.*"
                if ($Dialog.ShowDialog() -eq "OK") {
                    $InstallFile = $Dialog.FileName
                    
                    # step 3: extract & surgery
                    Status "extracting and patching amd installer files..." "step"
                    $ExtractPath = "$env:SystemRoot\Temp\amddriver"
                    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
                    
                    $ZipPath = "C:\Program Files\7-Zip\7z.exe"
                    if (Test-Path $ZipPath) {
                        & $ZipPath x "$InstallFile" -o"$ExtractPath" -y | Out-Null
                    } else {
                        Status "7-Zip not found! debloat aborted." "fail"; pause; break
                    }

                    # patch xml configs (disable telemetry/uep)
                    $XMLDirs = @("Config\AMDAUEPInstaller.xml", "Config\AMDCOMPUTE.xml", "Config\AMDLinkDriverUpdate.xml", "Config\AMDRELAUNCHER.xml", "Config\AMDScoSupportTypeUpdate.xml", "Config\AMDUpdater.xml", "Config\AMDUWPLauncher.xml", "Config\EnableWindowsDriverSearch.xml", "Config\InstallUEP.xml", "Config\ModifyLinkUpdate.xml")
                    foreach ($X in $XMLDirs) {
                        $XP = Join-Path $ExtractPath $X
                        if (Test-Path $XP) {
                            $Content = Get-Content $XP -Raw
                            $Content = $Content -replace '<Enabled>true</Enabled>', '<Enabled>false</Enabled>' -replace '<Hidden>true</Hidden>', '<Hidden>false</Hidden>'
                            Set-Content $XP -Value $Content -NoNewline
                        }
                    }

                    # patch json manifests (installbydefault: no)
                    $JSONDirs = @("Config\InstallManifest.json", "Bin64\cccmanifest_64.json")
                    foreach ($J in $JSONDirs) {
                        $JP = Join-Path $ExtractPath $J
                        if (Test-Path $JP) {
                            $Content = Get-Content $JP -Raw
                            $Content = $Content -replace '"InstallByDefault"\s*:\s*"Yes"', '"InstallByDefault" : "No"'
                            Set-Content $JP -Value $Content -NoNewline
                        }
                    }

                    # step 4: installation
                    Status "executing amd driver installation (gui mode)..." "step"
                    $Setup = "$ExtractPath\Bin64\ATISetup.exe"
                    if (Test-Path $Setup) {
                        Start-Process -Wait $Setup -ArgumentList "-INSTALL -VIEW:2" -WindowStyle Hidden
                    }

                    # step 5: post-install cleanup
                    Status "cleaning up amd bloatware and services..." "step"
                    # run keys & tasks
                    Set-Registry -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "AMDNoiseSuppression" -Value "-"
                    Set-Registry -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "StartRSX" -Value "-"
                    Unregister-ScheduledTask -TaskName "StartCN" -Confirm:$false -ErrorAction SilentlyContinue
                    
                    # massive service wipe
                    $AMDSvcs = "AMD Crash Defender Service", "amdfendr", "amdfendrmgr", "amdacpbus", "AMDSAFD", "AtiHDAudioService"
                    foreach ($S in $AMDSvcs) {
                        cmd /c "sc stop `"$S`" >nul 2>&1"
                        cmd /c "sc delete `"$S`" >nul 2>&1"
                    }

                    # bug report & uninstaller cleanup
                    Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Bug Report Tool" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                    Remove-Item "$env:SystemDrive\Windows\SysWOW64\AMDBugReportTool.exe" -Force -ErrorAction SilentlyContinue | Out-Null
                    $AMDInstallMgr = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName -match "AMD Install Manager" }
                    if ($AMDInstallMgr) { Start-Process "msiexec.exe" -ArgumentList "/x $($AMDInstallMgr.PSChildName) /qn /norestart" -Wait -NoNewWindow }
                    
                    # shortcut & file cleanup
                    $RSPath = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Software$([char]0xA789) Adrenalin Edition"
                    if (Test-Path $RSPath) {
                        Move-Item -Path "$RSPath\*.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue
                        Remove-Item $RSPath -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Remove-Item "$env:SystemDrive\AMD" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

                    # step 6: settings & profiles
                    Status "applying optimized AMD performance profile..." "step"
                    # initializing radeon software
                    $RSP = "$env:SystemDrive\Program Files\AMD\CNext\CNext\RadeonSoftware.exe"
                    if (Test-Path $RSP) {
                        Start-Process $RSP; Start-Sleep -Seconds 15; Stop-Process -Name "RadeonSoftware" -Force -ErrorAction SilentlyContinue
                    }
                    
                    # global settings (vsync off, texture quality, etc)
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "AutoUpdate" -Value 0
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "WizardProfile" -Value "PROFILE_CUSTOM" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN\CustomResolutions" -Name "EulaAccepted" -Value "true" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN\DisplayOverride" -Name "EulaAccepted" -Value "true" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "SystemTray" -Value "false" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "CN_Hide_Toast_Notification" -Value "true" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "AnimationEffect" -Value "false" -Type "String"
                    
                    # umd & power settings (vsync, texture filter, tessellation, vari-bright)
                    $GpuBase = "HKLM:\System\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}"
                    Get-ChildItem $GpuBase -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                        if ($_.PSChildName -eq "UMD") {
                            Set-Registry -Path $_.PSPath -Name "VSyncControl" -Value ([byte[]](0x30,0x00)) -Type "Binary"
                            Set-Registry -Path $_.PSPath -Name "TFQ" -Value ([byte[]](0x32,0x00)) -Type "Binary"
                            Set-Registry -Path $_.PSPath -Name "Tessellation" -Value ([byte[]](0x31,0x00)) -Type "Binary"
                            Set-Registry -Path $_.PSPath -Name "Tessellation_OPTION" -Value ([byte[]](0x32,0x00)) -Type "Binary"
                        }
                        if ($_.PSChildName -eq "power_v1") {
                            Set-Registry -Path $_.PSPath -Name "abmlevel" -Value ([byte[]](0x00,0x00,0x00,0x00)) -Type "Binary"
                        }
                    }
                    Status "amd driver installation and optimization complete." "done"
                } else { Status "selection cancelled." "warn" }
                pause
            }

            3 { break gpu }
        }
    }
}

Status "optimizing interrupt management & msi mode..." "step"
$PciDevices = Get-PnpDevice -InstanceId "PCI\*" -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' -or $_.Status -eq 'Unknown' }
foreach ($D in $PciDevices) {
    if ($D.InstanceId) {
        $P = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($D.InstanceId)\Device Parameters\Interrupt Management"
        Set-Registry -Path "$P\MessageSignaledInterruptProperties" -Name "MSISupported" -Value 1
        if (Test-Path "$P\Affinity Policy") { Remove-ItemProperty -Path "$P\Affinity Policy" -Name "DevicePriority" -ErrorAction SilentlyContinue }
    }
}

Status "executing environment cleanups..." "step"
# purge base directories
@("inetpub", "PerfLogs", "XboxGames", "Windows.old") | ForEach-Object {
    if (Test-Path "$env:SystemDrive\$_") { Remove-Item "$env:SystemDrive\$_" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
}
if (Test-Path "$env:SystemDrive\DumpStack.log") { Remove-Item "$env:SystemDrive\DumpStack.log" -Force -ErrorAction SilentlyContinue | Out-Null }

# clear runtime temporary stores
Remove-Item -Path "$env:UserProfile\AppData\Local\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Remove-Item -Path "$env:SystemDrive\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

# rebuild systemic performance counters
& "$env:SystemRoot\system32\lodctr.exe" /R 2>&1 | Out-Null
& "$env:SystemRoot\SysWOW64\lodctr.exe" /R 2>&1 | Out-Null

Status "running native disk cleanup..." "step"
Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/autoclean /d C:" -Wait -NoNewWindow

Write-Host ""
Status "albus-playbook has finished all tasks." "done"
pause

# =============================================================================================================================================================================
