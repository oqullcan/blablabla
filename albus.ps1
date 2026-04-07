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
        # Normalized Path for reg.exe fallback
        $CleanPath = $Path.Replace("HKLM:", "HKEY_LOCAL_MACHINE").Replace("HKCU:", "HKEY_CURRENT_USER").Replace("HKCR:", "HKEY_CLASSES_ROOT").Replace("HKU:", "HKEY_USERS")
        
        # Deletion: Key level (- prefix)
        if ($Path.StartsWith("-")) {
            $RealPath = $Path.Substring(1)
            # Use reg.exe directly for deletions on HKCR (Protects against provider hangs)
            if ($Path -like "*-HKCR*") {
                & reg.exe delete "$($CleanPath.Substring(1))" /f 2>&1 | Out-Null
            } else {
                if (Test-Path $RealPath) { Remove-Item -Path $RealPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
            }
            return
        }

        # Deletion: Value level (Value is "-")
        if ($Value -eq "-") {
            if (Test-Path $Path) { Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue | Out-Null }
            return
        }

        # Creation / Modification
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }

        if ($Name -eq "") {
            Set-Item -Path $Path -Value $Value -Force | Out-Null
        } else {
            $PT = if ($Type -eq "QWord") { "QWord" } else { $Type }
            try {
                New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PT -Force -ErrorAction Stop | Out-Null
            } catch {
                # Fallback to reg.exe for protected/deep system keys
                $RegType = switch ($Type) {
                    "DWord"  { "REG_DWORD" } "String" { "REG_SZ" } "Binary" { "REG_BINARY" }
                    "QWord"  { "REG_QWORD" } "ExpandString" { "REG_EXPAND_SZ" } Default { "REG_DWORD" }
                }
                # Format binary for reg.exe (Continuous hex string)
                $FinalValue = if ($Type -eq "Binary") { ($Value | ForEach-Object { "{0:X2}" -f $_ }) -join "" } else { $Value }
                & reg.exe add "$CleanPath" /v "$Name" /t $RegType /d $FinalValue /f 2>&1 | Out-Null
            }
        }
    } catch {
        # Only log failures for additions, not deletions
        if (-not ($Path.StartsWith("-") -or $Value -eq "-")) {
            Status "failed to set registry: $Path\$Name" "fail"
        }
    }
}

<#
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

# =============================================================================================================================================================================
#>

Status "executing registry optimization engine..." "step"

# Ensure all standard registry drives are mapped
if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null }
if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null }

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
    @{ Path = "HKCU:\Control Panel\Accessibility\HighContrast"; Name = "Flags"; Value = "4194"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "Flags"; Value = "2"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "AutoRepeatRate"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\Keyboard Response"; Name = "AutoRepeatDelay"; Value = "0"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys"; Name = "Flags"; Value = "130"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys"; Name = "MaximumSpeed"; Value = "39"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\MouseKeys"; Name = "TimeToMaximumSpeed"; Value = "3000"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\StickyKeys"; Name = "Flags"; Value = "2"; Type = "String" }
    @{ Path = "HKCU:\Control Panel\Accessibility\ToggleKeys"; Name = "Flags"; Value = "34"; Type = "String" }
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
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "SearchboxTaskbarMode"; Value = 0; Type = "DWord" }
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
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-310093Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-314563Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338388Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338389Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338393Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353694Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353696Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353698Enabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContentEnabled"; Value = 0; Type = "DWord" }
    @{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SystemPaneSuggestionsEnabled"; Value = 0; Type = "DWord" }

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

)

foreach ($Tweak in $Tweaks) {
    Set-Registry -Path $Tweak.Path -Name $Tweak.Name -Value $Tweak.Value -Type $Tweak.Type
}

# Sound Schemes (Bulk)
$SoundKeys = @(
    ".Default\.Default", "CriticalBatteryAlarm", "DeviceConnect", "DeviceDisconnect", "DeviceFail", "FaxBeep", 
    "LowBatteryAlarm", "MailBeep", "MessageNudge", "Notification.Default", "Notification.IM", "Notification.Mail", 
    "Notification.Proximity", "Notification.Reminder", "Notification.SMS", "ProximityConnection", "SystemAsterisk", 
    "SystemExclamation", "SystemHand", "SystemNotification", "WindowsUAC"
)
foreach ($s in $SoundKeys) {
    $p = if ($s -eq ".Default\.Default") { "HKCU:\AppEvents\Schemes\Apps\.Default\.Default\.Current" } else { "HKCU:\AppEvents\Schemes\Apps\.Default\$s\.Current" }
    Set-Registry -Path $p -Name "" -Value "" -Type "String"
}

# Speech Sound Schemes
$SpeechKeys = @("DisNumbersSound", "HubOffSound", "HubOnSound", "HubSleepSound", "MisrecoSound", "PanelSound")
foreach ($s in $SpeechKeys) {
    Set-Registry -Path "HKCU:\AppEvents\Schemes\Apps\sapisvr\$s\.current" -Name "" -Value "" -Type "String"
}

# Mouse Cursors (Bulk None)
$CursorKeys = @(
    "AppStarting", "Arrow", "Crosshair", "Hand", "Help", "IBeam", "No", "NWPen", 
    "SizeAll", "SizeNESW", "SizeNS", "SizeNWSE", "SizeWE", "UpArrow", "Wait"
)
foreach ($c in $CursorKeys) {
    Set-Registry -Path "HKCU:\Control Panel\Cursors" -Name $c -Value "" -Type "ExpandString"
}

Status "registry optimization complete." "done"

# =============================================================================================================================================================================
# --- POST-REGISTRY SYSTEM TWEAKS ---
# =============================================================================================================================================================================

Status "performing post-optimization system tweaks..." "step"

# Privacy & Security: Clear Capability Access database (Resets app permissions to default/deny)
Status "resetting privacy & security app permissions database..." "step"
Stop-Service -Name 'camsvc' -Force -ErrorAction SilentlyContinue
$CapabilityPath = "$env:ProgramData\Microsoft\Windows\CapabilityAccessManager"
if (Test-Path "$CapabilityPath\CapabilityConsentStorage.db*") {
    Remove-Item -Path "$CapabilityPath\CapabilityConsentStorage.db*" -Force -ErrorAction SilentlyContinue
}

# Service Management: Disable Windows Backup / Connected Devices Platform Service
Status "disabling windows backup & connected devices service..." "step"
Set-ItemProperty -Path "HKLM:\SYSTEM\ControlSet001\Services\CDPUserSvc" -Name "Start" -Value 4 -Force

# Memory & Hardware: Disable Memory Compression & BitLocker
Status "optimizing memory & storage security..." "step"
Disable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null
try {
    Get-BitLockerVolume -ErrorAction SilentlyContinue | Where-Object { $_.ProtectionStatus -eq "On" -or $_.VolumeStatus -ne "FullyDecrypted" } | ForEach-Object {
        Disable-BitLocker -MountPoint $_.MountPoint -ErrorAction SilentlyContinue | Out-Null
    }
} catch { }

# Security: Disable SmartScreen & Scheduled Tasks
Status "disabling smartscreen & background system tasks..." "step"
Set-Registry -Path "HKCU:\SOFTWARE\Microsoft\Edge\SmartScreenEnabled" -Name "" -Value 0 -Type "DWord"
Set-Registry -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppHost" -Name "EnableWebContentEvaluation" -Value 0 -Type "DWord"

$TasksToDisable = @(
    "Microsoft\Windows\ExploitGuard\ExploitGuard MDM policy Refresh",
    "Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance",
    "Microsoft\Windows\Windows Defender\Windows Defender Cleanup",
    "Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan",
    "Microsoft\Windows\Windows Defender\Windows Defender Verification",
    "Microsoft\Windows\Defrag\ScheduledDefrag"
)
foreach ($Task in $TasksToDisable) {
    Disable-ScheduledTask -TaskPath "\" -TaskName ($Task -split "\\")[-1] -ErrorAction SilentlyContinue | Out-Null
    # Fallback to schtasks if path is specific
    schtasks /Change /TN "$Task" /Disable 2>$null | Out-Null
}

# Network: Optimize bindings (Disable IPv6, LLDP, QoS, etc.)
Status "optimizing network adapter bindings (IPv4 Priority)..." "step"
$AdaptersToDisable = @('ms_lldp', 'ms_lltdio', 'ms_implat', 'ms_rspndr', 'ms_tcpip6', 'ms_server', 'ms_msclient', 'ms_pacer')
foreach ($Binding in $AdaptersToDisable) {
    Disable-NetAdapterBinding -Name "*" -ComponentID $Binding -ErrorAction SilentlyContinue
}

# Updates: Pause Windows Updates for 365 days & Block Driver Updates
Status "pausing windows & driver updates (1 year)..." "step"
$Today = Get-Date
$PauseEnd = $Today.AddDays(365)
$TodayStr = $Today.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$PauseStr = $PauseEnd.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$UpdatePath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
Set-ItemProperty -Path $UpdatePath -Name "PauseUpdatesExpiryTime" -Value $PauseStr -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $UpdatePath -Name "PauseFeatureUpdatesEndTime" -Value $PauseStr -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $UpdatePath -Name "PauseFeatureUpdatesStartTime" -Value $TodayStr -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $UpdatePath -Name "PauseQualityUpdatesEndTime" -Value $PauseStr -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $UpdatePath -Name "PauseQualityUpdatesStartTime" -Value $TodayStr -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $UpdatePath -Name "PauseUpdatesStartTime" -Value $TodayStr -Force -ErrorAction SilentlyContinue

# Registry Driver Blocks
Set-Registry -Path "HKLM:\Software\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Value 1 -Type "DWord"
Set-Registry -Path "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Settings" -Name "DisableSendGenericDriverNotFoundToWER" -Value 1 -Type "DWord"
Set-Registry -Path "HKLM:\Software\Policies\Microsoft\Windows\DeviceInstall\Settings" -Name "DisableSendRequestAdditionalSoftwareToWER" -Value 1 -Type "DWord"
Set-Registry -Path "HKLM:\Software\Policies\Microsoft\Windows\DriverSearching" -Name "SearchOrderConfig" -Value 0 -Type "DWord"
Set-Registry -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -Name "SetAllowOptionalContent" -Value 0 -Type "DWord"
Set-Registry -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -Name "AllowTemporaryEnterpriseFeatureControl" -Value 0 -Type "DWord"
Set-Registry -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -Value 1 -Type "DWord"
Set-Registry -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "IncludeRecommendedUpdates" -Value 0 -Type "DWord"
Set-Registry -Path "HKLM:\Software\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "EnableFeaturedSoftware" -Value 0 -Type "DWord"

# Power & Sign-in: Disable Sign-in requirement after away
Status "disabling sign-in requirement after sleep/away..." "step"
powercfg /setdcvalueindex scheme_current sub_none consolelock 0 2>$null
powercfg /setacvalueindex scheme_current sub_none consolelock 0 2>$null
powercfg /setactive scheme_current 2>$null

# Notifications: Disable Priority Notifications (Dynamic GUID)
Status "disabling priority-only notification prompts..." "step"
$PriorityGUIDs = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current" -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match '^\{[a-f0-9-]+\}\$' } | ForEach-Object { ($_.PSChildName -split '\$')[0] } | Select-Object -Unique

$PriorityBlob = [byte[]](0x43,0x42,0x01,0x00,0x0A,0x02,0x01,0x00,0x2A,0x06,0xDF,0xB8,0xB4,0xCC,0x06,0x2A,0x2B,0x0E,0xD0,0x03,0x43,0x42,0x01,0x00,0xC2,0x0A,0x01,0xCD,0x14,0x06,0x02,0x05,0x00,0x00,0x01,0x01,0x02,0x00,0x03,0x01,0x04,0x00,0xCC,0x32,0x12,0x05,0x28,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x53,0x00,0x63,0x00,0x72,0x00,0x65,0x00,0x65,0x00,0x6E,0x00,0x53,0x00,0x6B,0x00,0x65,0x00,0x74,0x00,0x63,0x00,0x68,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x29,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x57,0x00,0x69,0x00,0x6E,0x00,0x64,0x00,0x6F,0x00,0x77,0x00,0x73,0x00,0x41,0x00,0x6C,0x00,0x61,0x00,0x72,0x00,0x6D,0x00,0x73,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x31,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x58,0x00,0x62,0x00,0x6F,0x00,0x78,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x2D,0x4D,0x00,0x69,0x00,0x63,0x00,0x72,0x00,0x6F,0x00,0x73,0x00,0x6F,0x00,0x66,0x00,0x74,0x00,0x2E,0x00,0x58,0x00,0x62,0x00,0x6F,0x00,0x78,0x00,0x47,0x00,0x61,0x00,0x6D,0x00,0x69,0x00,0x6E,0x00,0x67,0x00,0x4F,0x00,0x76,0x00,0x65,0x00,0x72,0x00,0x6C,0x00,0x61,0x00,0x79,0x00,0x5F,0x00,0x38,0x00,0x77,0x00,0x65,0x00,0x6B,0x00,0x79,0x00,0x62,0x00,0x33,0x00,0x64,0x00,0x38,0x00,0x62,0x00,0x62,0x00,0x77,0x00,0x65,0x00,0x21,0x00,0x41,0x00,0x70,0x00,0x70,0x00,0x29,0x57,0x00,0x69,0x00,0x6E,0x00,0x64,0x00,0x6F,0x00,0x77,0x00,0x73,0x00,0x2E,0x00,0x53,0x00,0x79,0x00,0x73,0x00,0x74,0x00,0x65,0x00,0x6D,0x00,0x2E,0x00,0x4E,0x00,0x65,0x00,0x61,0x00,0x72,0x00,0x53,0x00,0x68,0x00,0x61,0x00,0x72,0x00,0x65,0x00,0x45,0x00,0x78,0x00,0x70,0x00,0x65,0x00,0x72,0x00,0x69,0x00,0x65,0x00,0x6E,0x00,0x63,0x00,0x65,0x00,0x52,0x00,0x65,0x00,0x63,0x00,0x65,0x00,0x69,0x00,0x76,0x00,0x65,0x00,0x00,0x00,0x00,0x00)

foreach ($guid in $PriorityGUIDs) {
    Set-Registry -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\DefaultAccount\Current\$guid`$windows.data.donotdisturb.quiethoursprofile`$quiethoursprofilelist\windows.data.donotdisturb.quiethoursprofile`$microsoft.quiethoursprofile.priorityonly" -Name "Data" -Value $PriorityBlob -Type "Binary"
}

# App Actions: Disable Windows Client CBS & Store Integration (Hive Loading)
Status "optimizing windows client session apps & hive settings..." "step"
$AppsToKill = "AppActions", "CrossDeviceResume", "DesktopStickerEditorWin32Exe", "DiscoveryHubApp", "FESearchHost", "SearchHost", "SoftLandingTask", "TextInputHost", "VisualAssistExe", "WebExperienceHostApp", "WindowsBackupClient", "WindowsMigration"
$AppsToKill | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

$SettingsDat = "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\Settings\settings.dat"
if (Test-Path $SettingsDat) {
    reg load "HKLM\Settings" $SettingsDat 2>$null
    if ($LASTEXITCODE -eq 0) {
        # Original Apps
        Set-Registry -Path "HKLM:\Settings\LocalState\DisabledApps" -Name "Microsoft.Paint_8wekyb3d8bbwe" -Value ([byte[]](0x01,0x61,0xed,0x11,0x34,0xf7,0x9f,0xdc,0x01)) -Type "Binary"
        Set-Registry -Path "HKLM:\Settings\LocalState\DisabledApps" -Name "Microsoft.Windows.Photos_8wekyb3d8bbwe" -Value ([byte[]](0x01,0x61,0xed,0x11,0x34,0xf7,0x9f,0xdc,0x01)) -Type "Binary"
        Set-Registry -Path "HKLM:\Settings\LocalState\DisabledApps" -Name "MicrosoftWindows.Client.CBS_cw5n1h2txyewy" -Value ([byte[]](0x01,0x61,0xed,0x11,0x34,0xf7,0x9f,0xdc,0x01)) -Type "Binary"
        
        # New System Settings (Moved from main loop to fix access denied)
        Set-Registry -Path "HKLM:\Settings\LocalState" -Name "VideoAutoplay" -Value ([byte[]](0x00,0x96,0x9d,0x69,0x8d,0xcd,0x93,0xdc,0x01)) -Type "Binary"
        Set-Registry -Path "HKLM:\Settings\LocalState" -Name "EnableAppInstallNotifications" -Value ([byte[]](0x00,0x36,0xd0,0x88,0x8e,0xcd,0x93,0xdc,0x01)) -Type "Binary"
        Set-Registry -Path "HKLM:\Settings\LocalState\PersistentSettings" -Name "PersonalizationEnabled" -Value ([byte[]](0x00,0x0d,0x56,0xa1,0x8a,0xcd,0x93,0xdc,0x01)) -Type "Binary"

        [gc]::Collect()
        Start-Sleep -Seconds 2
        reg unload "HKLM\Settings" 2>$null
    }
}

# Hardware: Network Adapter Power & Wake Optimization
Status "optimizing network adapter power & wake features..." "step"
$NICPath = "HKLM:\System\ControlSet001\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}"
Get-ChildItem -Path $NICPath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
    $RegPath = $_.Name.Replace("HKEY_LOCAL_MACHINE", "HKLM")
    $FullRegPath = $_.Name # For native reg command
    
    # Power Settings
    reg add "$FullRegPath" /v "PnPCapabilities" /t REG_DWORD /d "24" /f | Out-Null
    reg add "$FullRegPath" /v "AdvancedEEE" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "*EEE" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "EEELinkAdvertisement" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "SipsEnabled" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "ULPMode" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "GigaLite" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "EnableGreenEthernet" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "PowerSavingMode" /t REG_SZ /d "0" /f | Out-Null
    
    # Wake Settings
    reg add "$FullRegPath" /v "S5WakeOnLan" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "*WakeOnMagicPacket" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "*ModernStandbyWoLMagicPacket" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "*WakeOnPattern" /t REG_SZ /d "0" /f | Out-Null
    reg add "$FullRegPath" /v "WakeOnLink" /t REG_SZ /d "0" /f | Out-Null
}

# Hardware: Disable Selective Suspend & Wake for USB/PCI/HID/ACPI
Status "disabling selective suspend & wake for all I/O devices..." "step"
$DeviceHives = @("ACPI", "HID", "PCI", "USB")
foreach ($Hive in $DeviceHives) {
    # Parameters & Power
    Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\$Hive" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "Device Parameters" } | ForEach-Object {
        $P = $_.Name
        reg add "$P" /v "EnhancedPowerManagementEnabled" /t REG_DWORD /d "0" /f | Out-Null
        reg add "$P" /v "SelectiveSuspendEnabled" /t REG_BINARY /d "00" /f | Out-Null
        reg add "$P" /v "SelectiveSuspendOn" /t REG_DWORD /d "0" /f | Out-Null
        reg add "$P" /v "WaitWakeEnabled" /t REG_DWORD /d "0" /f | Out-Null
    }
    # WDF Idle
    Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\$Hive" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "WDF" } | ForEach-Object {
        reg add "$($_.Name)" /v "IdleInWorkingState" /t REG_DWORD /d "0" /f | Out-Null
    }
}

# --- SYSTEM PERFORMANCE: POWER & HARDWARE ---
Status "deploying albus ultimate power policy..." "step"

# MSI Mode for GPUs
$GpuDevs = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue
foreach ($G in $GpuDevs) {
    if ($G.InstanceId) {
        $RegMSI = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($G.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        Set-Registry -Path $RegMSI -Name "MSISupported" -Value 1
    }
}

# Ultimate Power Plan
$UltimateGUID = "99999999-9999-9999-9999-999999999999"
cmd /c "powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 $UltimateGUID >nul 2>&1"
cmd /c "powercfg /SETACTIVE $UltimateGUID >nul 2>&1"
# Purge other plans
$AllPlans = (powercfg /L) | Where-Object { $_ -match ':' } | ForEach-Object {
    if ($_ -match 'GUID:\s+([a-fA-F0-9-]+)') { $Matches[1] }
}
foreach ($P in $AllPlans) {
    if ($P -ne $UltimateGUID) { cmd /c "powercfg /delete $P 2>nul" | Out-Null }
}

# Global Power Tweaks
powercfg /hibernate off
Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabled" -Value 0
Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name "HibernateEnabledDefault" -Value 0
Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value 0
Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "PowerThrottlingOff" -Value 1
Set-Registry -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" -Name "ShowLockOption" -Value 0
Set-Registry -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" -Name "ShowSleepOption" -Value 0

# Monitor Data Store (Disable Auto Color)
$MonStore = Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore" -Recurse -ErrorAction SilentlyContinue
foreach ($M in $MonStore) { Set-Registry -Path $M.PSPath -Name "AutoColorManagementEnabled" -Value 0 }

# Deep Policy Tuning (Ultimate Plan)
Status "optimizing low-latency power settings..." "info"
$PowerSettings = @(
    # HDD, Wireless, PCI-E
    "0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0", # HDD Off
    "19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0", # Wireless Max
    "501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0", # PCI-E Exp Off
    # Sleep & Wake
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0", # Sleep Off
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0", # Hybrid Off
    "238c9fa8-0aad-41ed-83f4-97be242c8f20 bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 0", # Wake Timers Off
    # Processor (Unpark Cores 100%)
    "54533251-82be-4824-96c1-47b60b740d00 893dee8e-2bef-41e0-89c6-b55d0929964c 100", # Min Processor
    "54533251-82be-4824-96c1-47b60b740d00 bc5038f7-23e0-4960-96da-33abaf5935ec 100", # Max Processor
    "54533251-82be-4824-96c1-47b60b740d00 0cc5b647-c1df-4637-891a-dec35c318583 100", # Core Park Min
    "54533251-82be-4824-96c1-47b60b740d00 ea062031-0e34-4ff1-9b6d-eb1059334028 100", # Core Park Max
    # Display & Graphics
    "7516b95f-f776-4464-8c53-06167f40cc99 aded5e82-b909-4619-9949-f5d71dac0bcb 100", # Brightness
    "7516b95f-f776-4464-8c53-06167f40cc99 fbd9aa66-9553-4097-ba44-ed6e9d65eab8 0",   # Adaptive Off
    "44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 2",   # Intel Graphics
    "f693fb01-e858-4f00-b20f-f30e12ac06d6 191f65b5-d45c-4a4f-8aae-1ab8bfd980e6 1",   # ATI PowerPlay
    "e276e160-7cb0-43c6-b20b-73f5dce39954 a1662ab2-9d34-4e53-ba8b-2639b9e20857 3",   # Switchable Graphics
    # USB
    "2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0",   # USB Selective Suspend
    "2a737441-1930-4402-8d77-b2bebba308a3 d4e98f31-5ffe-4ce1-be31-1b38b384c009 0"    # USB3 Link Power
)
foreach ($S in $PowerSettings) {
    if ($S -match '^#') { continue }
    $P = $S -split ' '
    powercfg /setacvalueindex $UltimateGUID $P[0] $P[1] $P[2] | Out-Null
    powercfg /setdcvalueindex $UltimateGUID $P[0] $P[1] $P[2] | Out-Null
}
powercfg /setactive $UltimateGUID | Out-Null


# UI: Force Tray Icon Visibility
Status "enforcing unified taskbar icon visibility (all show)..." "step"
$NotifySettings = Get-ChildItem -Path 'HKCU:\Control Panel\NotifyIconSettings' -Recurse -ErrorAction SilentlyContinue
foreach ($S in $NotifySettings) {
    Set-ItemProperty -Path $S.PSPath -Name 'IsPromoted' -Value 1 -Force -ErrorAction SilentlyContinue | Out-Null
}

# --- ALBUS SERVICES: TIMER RESOLUTION ---
Status "deploying albus timer resolution service..." "step"

$SourceURL = "https://raw.githubusercontent.com/oqullcan/blablabla/main/albus/albus.cs"
$CSFile = "$env:SystemRoot\Temp\albus.cs"
$ExeFile = "$env:SystemRoot\AlbusServices.exe"

try {
    # Download Source
    Invoke-WebRequest -Uri $SourceURL -OutFile $CSFile -UseBasicParsing -ErrorAction Stop
    
    # Compile Natively
    $CSC = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (Test-Path $CSC) {
        Status "compiling albus services natively..." "info"
        & $CSC -out:$ExeFile $CSFile -WindowStyle Hidden | Out-Null
        
        # Service Management
        $NewSvc = "Albus Services"

        # Create & Start New Service
        if (Test-Path $ExeFile) {
            if (-not (Get-Service -Name $NewSvc -ErrorAction SilentlyContinue)) {
                New-Service -Name $NewSvc -BinaryPathName $ExeFile -DisplayName $NewSvc -Description "Albus Services" -StartupType Automatic -ErrorAction SilentlyContinue | Out-Null
            }
            Start-Service -Name $NewSvc -ErrorAction SilentlyContinue | Out-Null
            Status "albus timer resolution service and audio is active." "done"
        }
    }
} catch { Status "failed to deploy albus services online." "warn" }


# Storage: Optimize Write-Cache Buffer Flushing (SCSI & NVME)
Status "optimizing storage write-cache buffer flushing..." "step"
$StorageHives = @("SCSI", "NVME")
foreach ($Hive in $StorageHives) {
    Get-ChildItem -Path "HKLM:\SYSTEM\ControlSet001\Enum\$Hive" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "Device Parameters" } | ForEach-Object {
        $DiskPath = "$($_.Name)\Disk"
        reg add "$DiskPath" /v "CacheIsPowerProtected" /t REG_DWORD /d "1" /f | Out-Null
    }
}

# UI & Shell: Taskbar Unpin All
Status "unpinning all taskbar items..." "step"
Set-Registry -Path "-HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband" -Name "" -Value ""
Remove-Item -Recurse -Force "$env:USERPROFILE\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch" -ErrorAction SilentlyContinue | Out-Null

# UI & Shell: Generate & Apply "Pro Black" Theme
Status "applying pro black minimalist theme..." "step"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction SilentlyContinue 
$SW = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Width
$SH = [System.Windows.Forms.SystemInformation]::PrimaryMonitorSize.Height
$BlackFile = "C:\Windows\Black.jpg"
if (-not (Test-Path $BlackFile)) {
    try {
        $Bmp = New-Object System.Drawing.Bitmap $SW, $SH
        $Gfx = [System.Drawing.Graphics]::FromImage($Bmp)
        $Gfx.FillRectangle([System.Drawing.Brushes]::Black, 0, 0, $SW, $SH)
        $Gfx.Dispose(); $Bmp.Save($BlackFile); $Bmp.Dispose()
    } catch {}
}
# Apply Lock Screen & Wallpaper
Set-Registry -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Name "LockScreenImagePath" -Value $BlackFile -Type "String"
Set-Registry -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP" -Name "LockScreenImageStatus" -Value 1 -Type "DWord"
Set-Registry -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -Value $BlackFile -Type "String"
rundll32.exe user32.dll, UpdatePerUserSystemParameters

# UI & Shell: Context Menu Debloat
Status "cleaning up bloated context menu items (using engine)..." "step"
$MenuTweaks = @(
    # Core Cleanup
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"; Name = "NoCustomizeThisFolder"; Value = 1 }
    @{ Path = "-HKCR:\Folder\shell\pintohome"; Name = ""; Value = "" }
    @{ Path = "-HKCR:\*\shell\pintohomefile"; Name = ""; Value = "" }
    @{ Path = "-HKCR:\exefile\shellex\ContextMenuHandlers\Compatibility"; Name = ""; Value = "" }
    @{ Path = "-HKCR:\Folder\ShellEx\ContextMenuHandlers\Library Location"; Name = ""; Value = "" }
    @{ Path = "-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\ModernSharing"; Name = ""; Value = "" }
    @{ Path = "-HKCR:\AllFilesystemObjects\shellex\ContextMenuHandlers\SendTo"; Name = ""; Value = "" }
    @{ Path = "-HKCR:\UserLibraryFolder\shellex\ContextMenuHandlers\SendTo"; Name = ""; Value = "" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer"; Name = "NoPreviousVersionsPage"; Value = 1 }
    
    # Blocked Shell Extensions
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"; Name = "{9F156763-7844-4DC4-B2B1-901F640F5155}"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"; Name = "{09A47860-11B0-4DA5-AFA5-26D86198A780}"; Value = ""; Type = "String" }
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked"; Name = "{f81e9010-6ea4-11ce-a7ff-00aa003ca9f6}"; Value = ""; Type = "String" }
)
foreach ($M in $MenuTweaks) { 
    $Type = if ($M.Type) { $M.Type } else { "DWord" }
    Set-Registry -Path $M.Path -Name $M.Name -Value $M.Value -Type $Type 
}

# UI & Shell: Start Menu Reset (Windows 10 & 11)
Status "resetting start menu layout (unpin & clean)..." "step"

# Windows 10 Logic: XML-based reset
if ([Environment]::OSVersion.Version.Major -eq 10 -and [Environment]::OSVersion.Version.Build -lt 22000) {
    Status "applying windows 10 start layout reset..." "step"
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
    
    foreach ($Hive in @("HKLM", "HKCU")) {
        Set-ItemProperty -Path "${Hive}:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name "LockedStartLayout" -Value 0 -Force
    }
    Remove-Item -Path $LayoutXML -Force -ErrorAction SilentlyContinue
}

# Windows 11 Logic: start2.bin reset (Embedded Clear Layout)
if ([Environment]::OSVersion.Version.Major -eq 10 -and [Environment]::OSVersion.Version.Build -ge 22000) {
    Status "applying windows 11 start layout reset (zero-pin template)..." "step"
    $Start2BinPath = "$env:USERPROFILE\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start2.bin"
    
    # Embedded Base64 for a minimalist/empty pinned list
    $EmptyStartB64 = "AgAAABAAAAD9////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
    $StartBytes = [Convert]::FromBase64String($EmptyStartB64)
    
    # Wipe existing and write new empty layout
    Remove-Item -Path $Start2BinPath -Force -ErrorAction SilentlyContinue | Out-Null
    [System.IO.File]::WriteAllBytes($Start2BinPath, $StartBytes)
    
    Set-Registry -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Start" -Name "AllAppsViewMode" -Value 2 -Type "DWord"
    Stop-Process -Force -Name explorer -ErrorAction SilentlyContinue
}

# UI & Shell: Start Menu Organization & Shortcuts
Status "organizing start menu & creating system shortcuts..." "step"
# recycle bin shortcut
$WshShell = New-Object -ComObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Recycle Bin.lnk")
$Shortcut.TargetPath = '::{645ff040-5081-101b-9f08-00aa002f954e}'
$Shortcut.Save()

# hide accessibility/accessories folders
$HideFolders = @(
    "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Accessibility",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessibility",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Accessories"
)
foreach ($F in $HideFolders) {
    if (Test-Path $F) {
        attrib +h "$F" /s /d >$null 2>&1
    }
}

# Application Debloat: Complete Microsoft Edge Removal
Status "executing deep microsoft edge removal (force uninstall)..." "step"

# Region Spoof (US) to bypass restrictions
$OldRegion = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' -Name DeviceRegion -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' -Name DeviceRegion -Value 244 -Force -ErrorAction SilentlyContinue

# Kill all Edge & related processes
$EdgeProcs = "backgroundTaskHost", "Copilot", "CrossDeviceResume", "GameBar", "MicrosoftEdgeUpdate", "msedge", "msedgewebview2", "OneDrive", "OneDrive.Sync.Service", "OneDriveStandaloneUpdater", "Resume", "RuntimeBroker", "Search", "SearchHost", "Setup", "StoreDesktopExtension", "WidgetService", "Widgets"
$EdgeProcs | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
Get-Process | Where-Object { $_.ProcessName -like "*edge*" } | Stop-Process -Force -ErrorAction SilentlyContinue

# Registry Clean: EdgeUpdate
$EdgeRegHives = "HKCU:\SOFTWARE", "HKLM:\SOFTWARE", "HKCU:\SOFTWARE\Policies", "HKLM:\SOFTWARE\Policies", "HKCU:\SOFTWARE\WOW6432Node", "HKLM:\SOFTWARE\WOW6432Node", "HKCU:\SOFTWARE\WOW6432Node\Policies", "HKLM:\SOFTWARE\WOW6432Node\Policies"
foreach ($H in $EdgeRegHives) { Remove-Item "$H\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue }

# Uninstall Update Services
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

# Force Uninstall Edge via native registry string
try {
    $EdgeUninstallKey = Get-Item "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" -ErrorAction SilentlyContinue
    if ($EdgeUninstallKey) {
        $UString = $EdgeUninstallKey.GetValue("UninstallString") + " --force-uninstall"
        Start-Process cmd.exe -ArgumentList "/c $UString" -WindowStyle Hidden -Wait
    }
} catch {}

# Cleanup Edge leftovers
$EdgeLeftovers = @(
    "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe",
    "$env:ProgramFiles (x86)\Microsoft",
    "$env:SystemDrive\Windows\System32\config\systemprofile\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk"
)
$EdgeLeftovers | ForEach-Object { if (Test-Path $_) { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue } }

# Delete Edge Services
Get-Service | Where-Object { $_.Name -match 'Edge' } | ForEach-Object {
    sc.exe stop $_.Name >$null 2>&1
    sc.exe delete $_.Name >$null 2>&1
}

# Windows 10: Legacy Edge Package (DISM)
$LegacyEdge = (Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "*Microsoft-Windows-Internet-Browser-Package*~~*" }).PSChildName
if ($LegacyEdge) {
    $LPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages\$LegacyEdge"
    reg add "$LPath" /v Visibility /t REG_DWORD /d 1 /f | Out-Null
    reg delete "$LPath\Owners" /va /f | Out-Null
    dism.exe /online /Remove-Package /PackageName:$LegacyEdge /quiet /norestart >$null 2>&1
}

# Revert Region
if ($OldRegion) { Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion' -Name DeviceRegion -Value $OldRegion -Force }

# System Debloat: UWP Applications (Filtered)
Status "removing bloated UWP applications (preserving core)..." "step"
$UWPToKill = Get-AppxPackage -AllUsers | Where-Object {
    $_.Name -notmatch 'CBS|AV1VideoExtension|AVCEncoderVideoExtension|HEIFImageExtension|HEVCVideoExtension|MPEG2VideoExtension|Paint|RawImageExtension|SecHealthUI|VP9VideoExtensions|WebMediaExtensions|WebpImageExtension|Photos|ShellExperienceHost|StartMenuExperienceHost|Notepad|WindowsStore|NVIDIAControlPanel|immersivecontrolpanel|FilePicker|Search|BioEnrollment|LockApp|AAD|Accounts'
}
foreach ($App in $UWPToKill) {
    try {
        Remove-AppxPackage -Package $App.PackageFullName -AllUsers -ErrorAction Stop | Out-Null
    } catch { }
}

# System Debloat: Windows Capabilities (Filtered)
Status "removing unnecessary windows capabilities..." "step"
Get-WindowsCapability -Online | Where-Object {
    $_.State -eq 'Installed' -and
    $_.Name -notmatch 'Ethernet|MSPaint|Notepad|Wifi|NetFX3|VBSCRIPT|WMIC|ShellComponents'
} | ForEach-Object { try { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null } catch {} }

# System Debloat: Optional Features (Filtered)
Status "disabling bloated legacy optional features..." "step"
Get-WindowsOptionalFeature -Online | Where-Object {
    $_.State -eq 'Enabled' -and
    $_.FeatureName -notmatch 'DirectPlay|LegacyComponents|NetFx|SearchEngine-Client|Server-Shell|Windows-Defender|Drivers-General|Server-Gui-Mgmt|WirelessNetworking'
} | ForEach-Object { try { Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -WarningAction SilentlyContinue | Out-Null } catch {} }

# Application Cleanup: Legacy Software & Tools
Status "uninstalling legacy apps, onedrive & health tools..." "step"

# brlapi (Braille)
sc.exe stop "brlapi" >$null 2>&1; sc.exe delete "brlapi" >$null 2>&1
$BrlPath = "$env:SystemRoot\brltty"
if (Test-Path $BrlPath) {
    takeown /f "$BrlPath" /r /d y >$null 2>&1
    icacls "$BrlPath" /grant *S-1-5-32-544:F /t >$null 2>&1
    Remove-Item $BrlPath -Recurse -Force -ErrorAction SilentlyContinue
}

# Microsoft GameInput
$GameInput = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName -like "*Microsoft GameInput*" }
if ($GameInput) {
    $Guid = $GameInput.PSChildName
    Start-Process "msiexec.exe" -ArgumentList "/x $Guid /qn /norestart" -Wait -NoNewWindow
}

# OneDrive
Stop-Process -Force -Name OneDrive -ErrorAction SilentlyContinue | Out-Null
$OneDriveSetups = @(
    "$env:SystemRoot\System32\OneDriveSetup.exe",
    "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
)
foreach ($O in $OneDriveSetups) { if (Test-Path $O) { Start-Process -Wait $O -ArgumentList "/uninstall" -WindowStyle Hidden } }
Get-ScheduledTask | Where-Object {$_.Taskname -match 'OneDrive'} | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

# Remote Desktop Connection (MSTSC)
try { Start-Process "mstsc" -ArgumentList "/Uninstall" -ErrorAction SilentlyContinue } catch {}
$MSTSCProc = Get-Process -Name mstsc -ErrorAction SilentlyContinue
if ($MSTSCProc) { $MSTSCProc | Stop-Process -Force -ErrorAction SilentlyContinue }

# Legacy Snipping Tool (Win10)
try { Start-Process "C:\Windows\System32\SnippingTool.exe" -ArgumentList "/Uninstall" -ErrorAction SilentlyContinue } catch {}
$SnipProc = Get-Process -Name SnippingTool -ErrorAction SilentlyContinue
if ($SnipProc) { $SnipProc | Stop-Process -Force -ErrorAction SilentlyContinue }

# Update Health Tools & UHSSVC
$UpdateTools = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName -match "Update for x64-based Windows Systems|Microsoft Update Health Tools" }
foreach ($T in $UpdateTools) {
    if ($T.PSChildName) { Start-Process "msiexec.exe" -ArgumentList "/x $($T.PSChildName) /qn /norestart" -Wait -NoNewWindow }
}
sc.exe delete "uhssvc" >$null 2>&1
Unregister-ScheduledTask -TaskName PLUGScheduler -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

# System Debloat: Startup Apps & Registry Persistence
Status "clearing all 3rd party startup applications..." "step"
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

# Physical Startup Folders
$StartupFolders = @("$env:AppData\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp")
foreach ($F in $StartupFolders) {
    if (Test-Path $F) {
        Remove-Item -Path "$F\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

# System Debloat: 3rd Party Scheduled Tasks
Status "removing all non-microsoft scheduled tasks..." "step"
# Registry Task Cache
$TaskTree = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree"
Get-ChildItem $TaskTree -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -ne "Microsoft" } | ForEach-Object {
    Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}
# File System Tasks
$TaskFiles = "$env:SystemRoot\System32\Tasks"
Get-ChildItem $TaskFiles -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "Microsoft" } | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}

# =============================================================================================================================================================================
# --- GPU DRIVER INSTALLATION & DEBLOAT ---
# =============================================================================================================================================================================

function Show-GPU-Menu {
    Write-Host ""
    Write-Host "`n select graphics drivers" -ForegroundColor Yellow
    Write-Host " 1. nvidia" -ForegroundColor Green
    Write-Host " 2. amd" -ForegroundColor Red
    Write-Host " 3. skip`n" -ForegroundColor Gray
    Write-Host ""
}


:GPULoop while ($true) {
    Show-GPU-Menu
    $Choice = Read-Host " Enter choice [1-3]"
    if ($Choice -match '^[1-3]$') {
        switch ($Choice) {
            1 {
                Status "starting NVIDIA GPU driver procedure..." "step"
                
                # Step 1: Download
                Status "opening default browser for driver download..." "info"
                Start-Process "https://www.nvidia.com/en-us/drivers"
                
                Write-Host "`n[!] PLEASE DOWNLOAD THE DRIVER AND PRESS ANY KEY TO CONTINUE..." -ForegroundColor Yellow
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                
                # Step 2: Select File
                Status "waiting for file selection..." "step"
                Add-Type -AssemblyName System.Windows.Forms
                $Dialog = New-Object System.Windows.Forms.OpenFileDialog
                $Dialog.Title = "Select the downloaded NVIDIA Driver Installer"
                $Dialog.Filter = "NVIDIA Installer (*.exe)|*.exe|All Files (*.*)|*.*"
                if ($Dialog.ShowDialog() -eq "OK") {
                    $InstallFile = $Dialog.FileName
                    
                    # Step 3: Extract & Debloat
                    Status "extracting and debloating driver (this may take a minute)..." "step"
                    $ExtractPath = "$env:SystemRoot\Temp\nvidiadriver"
                    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
                    
                    $ZipPath = "C:\Program Files\7-Zip\7z.exe"
                    if (Test-Path $ZipPath) {
                        & $ZipPath x "$InstallFile" -o"$ExtractPath" -y | Out-Null
                    } else {
                        Status "7-Zip not found! Debloat aborted." "fail"
                        pause; break
                    }

                    # Aggressive Strip-down (Whitelist Approach)
                    Status "executing aggressive strip-down (keeping core only)..." "step"
                    $Whitelist = @("Display.Driver", "NVI2", "EULA.txt", "ListDevices.txt", "setup.cfg", "setup.exe")
                    Get-ChildItem -Path $ExtractPath | ForEach-Object {
                        if ($Whitelist -notcontains $_.Name) {
                            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                    }

                    # Step 4: Patch setup.cfg (Remove Consent/Eula lines)
                    Status "patching setup.cfg for silent install..." "info"
                    $CfgPath = Join-Path $ExtractPath "setup.cfg"
                    if (Test-Path $CfgPath) {
                        (Get-Content $CfgPath) | Where-Object {
                            $_ -notmatch 'EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile'
                        } | Set-Content $CfgPath -Force
                    }

                    # Step 5: Silent Install
                    Status "executing clean driver installation..." "step"
                    $Setup = "$ExtractPath\setup.exe"
                    if (Test-Path $Setup) {
                        Start-Process $Setup -ArgumentList "-s -noreboot -noeula -clean" -Wait -NoNewWindow
                        Status "NVIDIA driver installation complete." "done"
                        
                    # Step 6: Post-Installation Performance Tuning
                    Status "applying advanced NVIDIA performance tweaks..." "step"
                        
                    # Class ID Based Tweaks (P-State, HDCP, Profiling)
                    $GPUClasses = Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E968-E325-11CE-BFC1-08002BE10318}" -ErrorAction SilentlyContinue
                    foreach ($C in $GPUClasses) {
                        if ($C.PSChildName -match '^\d{4}$') {
                            Set-Registry -Path $C.PSPath -Name "DisableDynamicPstate" -Value 1
                            Set-Registry -Path $C.PSPath -Name "RMHdcpKeyglobZero" -Value 1
                            Set-Registry -Path $C.PSPath -Name "RmProfilingAdminOnly" -Value 0
                        }
                    }

                    # NVTweak / FTS / Tray
                    Set-Registry -Path "HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak" -Name "NvCplPhysxAuto" -Value 0
                    Set-Registry -Path "HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak" -Name "NvDevToolsVisible" -Value 1
                    Set-Registry -Path "HKLM:\System\ControlSet001\Services\nvlddmkm\Parameters\Global\NVTweak" -Name "RmProfilingAdminOnly" -Value 0
                    Set-Registry -Path "HKCU:\Software\NVIDIA Corporation\NvTray" -Name "StartOnLogin" -Value 0
                    Set-Registry -Path "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\FTS" -Name "EnableGR535" -Value 0
                    Set-Registry -Path "HKLM:\SYSTEM\ControlSet001\Services\nvlddmkm\Parameters\FTS" -Name "EnableGR535" -Value 0
                        
                    # Unblock DRS Files
                    $DRSPath = "C:\ProgramData\NVIDIA Corporation\Drs"
                    if (Test-Path $DRSPath) { Get-ChildItem -Path $DRSPath -Recurse | Unblock-File -ErrorAction SilentlyContinue }

                    # Step 7: NVIDIA Profile Inspector (Download & Apply)
                    Status "fetching latest NVIDIA Profile Inspector from GitHub..." "step"
                    $InspectorZip = "$env:SystemRoot\Temp\nvidiaProfileInspector.zip"
                    $ExtractDir = "$env:SystemRoot\Temp\nvidiaProfileInspector"
                        
                    try {
                        $Repo = "Orbmu2k/nvidiaProfileInspector"
                        $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -ErrorAction Stop
                        $Asset = ($Release.assets | Where-Object { $_.name -like "*.zip" })[0]
                        if ($Asset) {
                            Status "downloading $($Asset.name)..." "info"
                            Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $InspectorZip -UseBasicParsing -ErrorAction Stop
                                
                            # Extract using 7z
                            $ZipPath = "C:\Program Files\7-Zip\7z.exe"
                            if (Test-Path $ZipPath) {
                                & $ZipPath x "$InspectorZip" -o"$ExtractDir" -y | Out-Null
                            }
                        }
                    } catch { Status "failed to download NVIDIA Profile Inspector online." "warn" }

                    Status "configuring NVIDIA Profile Inspector settings..." "step"
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
                        Status "NVIDIA performance profile applied." "done"
                    } else {
                        Status "setup.exe not found in extracted files!" "fail"
                    }
                } else {
                    Status "selection cancelled." "warn"
                }
                pause
            }
            2 {
                Status "starting AMD GPU driver procedure..." "step"

                # Step 1: Download
                Status "opening default browser for AMD support..." "info"
                Start-Process "https://www.amd.com/en/support/download/drivers.html"
                Write-Host "`n[!] PLEASE DOWNLOAD THE ADRENALIN DRIVER AND PRESS ANY KEY TO CONTINUE..." -ForegroundColor Yellow
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

                # Step 2: Select File
                Status "waiting for file selection..." "step"
                Add-Type -AssemblyName System.Windows.Forms
                $Dialog = New-Object System.Windows.Forms.OpenFileDialog
                $Dialog.Title = "Select the downloaded AMD Driver Installer"
                $Dialog.Filter = "AMD Installer (*.exe)|*.exe|All Files (*.*)|*.*"
                if ($Dialog.ShowDialog() -eq "OK") {
                    $InstallFile = $Dialog.FileName
                    
                    # Step 3: Extract & Surgery
                    Status "extracting and patching AMD installer files..." "step"
                    $ExtractPath = "$env:SystemRoot\Temp\amddriver"
                    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
                    
                    $ZipPath = "C:\Program Files\7-Zip\7z.exe"
                    if (Test-Path $ZipPath) {
                        & $ZipPath x "$InstallFile" -o"$ExtractPath" -y | Out-Null
                    } else {
                        Status "7-Zip not found! Debloat aborted." "fail"; pause; break
                    }

                    # Patch XML Configs (Disable Telemetry/UEP)
                    $XMLDirs = @("Config\AMDAUEPInstaller.xml", "Config\AMDCOMPUTE.xml", "Config\AMDLinkDriverUpdate.xml", "Config\AMDRELAUNCHER.xml", "Config\AMDScoSupportTypeUpdate.xml", "Config\AMDUpdater.xml", "Config\AMDUWPLauncher.xml", "Config\EnableWindowsDriverSearch.xml", "Config\InstallUEP.xml", "Config\ModifyLinkUpdate.xml")
                    foreach ($X in $XMLDirs) {
                        $XP = Join-Path $ExtractPath $X
                        if (Test-Path $XP) {
                            $Content = Get-Content $XP -Raw
                            $Content = $Content -replace '<Enabled>true</Enabled>', '<Enabled>false</Enabled>' -replace '<Hidden>true</Hidden>', '<Hidden>false</Hidden>'
                            Set-Content $XP -Value $Content -NoNewline
                        }
                    }

                    # Patch JSON Manifests (InstallByDefault: No)
                    $JSONDirs = @("Config\InstallManifest.json", "Bin64\cccmanifest_64.json")
                    foreach ($J in $JSONDirs) {
                        $JP = Join-Path $ExtractPath $J
                        if (Test-Path $JP) {
                            $Content = Get-Content $JP -Raw
                            $Content = $Content -replace '"InstallByDefault"\s*:\s*"Yes"', '"InstallByDefault" : "No"'
                            Set-Content $JP -Value $Content -NoNewline
                        }
                    }

                    # Step 4: Installation
                    Status "executing AMD driver installation (GUI mode)..." "step"
                    $Setup = "$ExtractPath\Bin64\ATISetup.exe"
                    if (Test-Path $Setup) {
                        Start-Process -Wait $Setup -ArgumentList "-INSTALL -VIEW:2" -WindowStyle Hidden
                    }

                    # Step 5: Post-Install Cleanup
                    Status "cleaning up AMD bloatware and services..." "step"
                    # Run Keys & Tasks
                    Set-Registry -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "AMDNoiseSuppression" -Value "-"
                    Set-Registry -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "StartRSX" -Value "-"
                    Unregister-ScheduledTask -TaskName "StartCN" -Confirm:$false -ErrorAction SilentlyContinue
                    
                    # Massive Service Wipe
                    $AMDSvcs = "AMD Crash Defender Service", "amdfendr", "amdfendrmgr", "amdacpbus", "AMDSAFD", "AtiHDAudioService"
                    foreach ($S in $AMDSvcs) {
                        cmd /c "sc stop `"$S`" >nul 2>&1"
                        cmd /c "sc delete `"$S`" >nul 2>&1"
                    }

                    # Bug Report & Uninstaller cleanup
                    Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Bug Report Tool" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                    Remove-Item "$env:SystemDrive\Windows\SysWOW64\AMDBugReportTool.exe" -Force -ErrorAction SilentlyContinue | Out-Null
                    $AMDInstallMgr = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" | Where-Object { $_.DisplayName -match "AMD Install Manager" }
                    if ($AMDInstallMgr) { Start-Process "msiexec.exe" -ArgumentList "/x $($AMDInstallMgr.PSChildName) /qn /norestart" -Wait -NoNewWindow }
                    
                    # Shortcut & File cleanup
                    $RSPath = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Software$([char]0xA789) Adrenalin Edition"
                    if (Test-Path $RSPath) {
                        Move-Item -Path "$RSPath\*.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue
                        Remove-Item $RSPath -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Remove-Item "$env:SystemDrive\AMD" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

                    # Step 6: Settings & Profiles
                    Status "applying optimized AMD performance profile..." "step"
                    # Initializing Radeon Software
                    $RSP = "$env:SystemDrive\Program Files\AMD\CNext\CNext\RadeonSoftware.exe"
                    if (Test-Path $RSP) {
                        Start-Process $RSP; Start-Sleep -Seconds 15; Stop-Process -Name "RadeonSoftware" -Force -ErrorAction SilentlyContinue
                    }
                    
                    # Global Settings (VSync Off, Texture Quality, etc)
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "AutoUpdate" -Value 0
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "WizardProfile" -Value "PROFILE_CUSTOM" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN\CustomResolutions" -Name "EulaAccepted" -Value "true" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN\DisplayOverride" -Name "EulaAccepted" -Value "true" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "SystemTray" -Value "false" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "CN_Hide_Toast_Notification" -Value "true" -Type "String"
                    Set-Registry -Path "HKCU:\Software\AMD\CN" -Name "AnimationEffect" -Value "false" -Type "String"
                    
                    # UMD & Power Settings (VSync, Texture Filter, Tessellation, Vari-Bright)
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
                    Status "AMD driver installation and optimization complete." "done"
                } else { Status "selection cancelled." "warn" }
                pause
            }

            3 { break GPULoop }
        }
    }
}

Status "Albus optimization engine has finished all tasks." "done"
pause

# =============================================================================================================================================================================
