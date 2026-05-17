#Requires -RunAsAdministrator

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
$ALBUS_VERSION = '7.0'
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

#  download file from url
function Get-File {
    param([string]$Url, [string]$Dest)
    Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -ErrorAction Stop
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

function Set-Regs {
    param([array]$Tweaks)
    foreach ($t in $Tweaks) {
        $tName = if ($t.Name) { $t.Name } else { '' }
        $tType = if ($t.Type) { $t.Type } else { 'DWord' }
        Set-Reg -Path $t.Path -Name $tName -Value $t.Value -Type $tType
    }
}

# ── app package settings engine ───────────────────────
function Set-AppPackageSettings {
    param(
        [string]$Name,
        [string]$PackageName,
        [string[]]$StopProcesses,
        [string]$RegistryContent
    )
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    Write-Step "configuring $Name"

    # kill running target processes
    if ($StopProcesses) {
        $StopProcesses | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    }
    # check settings.dat path
    $settingsDat = "$env:LocalAppData\Packages\$PackageName\Settings\settings.dat"
    if (-not (Test-Path $settingsDat)) {
        Write-Step "skipping $Name (settings.dat not found)" -Status 'skip'
        $ErrorActionPreference = $oldEAP
        return
    }

    $tempRegPath = "$env:SystemRoot\Temp\$($Name.Replace(' ', '')).reg"
    $hiveLoaded = $false
    $importStatus = -1

    try {
        # create registry file
        $regHeader = "Windows Registry Editor Version 5.00`r`n`r`n"
        Set-Content -Path $tempRegPath -Value ($regHeader + $RegistryContent) -Force
        # load hive
        reg load "HKLM\Settings" $settingsDat >$null 2>&1
        if ($LASTEXITCODE -eq 0) {
            $hiveLoaded = $true
        } else {
            Write-Step "failed to load hive for $Name" -Status 'fail'
            return
        }
        # import registry file
        reg import $tempRegPath >$null 2>&1
        $importStatus = $LASTEXITCODE

        if ($importStatus -eq 0) {
            Write-Step "$Name settings applied" -Status 'ok'
        } else {
            Write-Step "failed to import settings for $Name" -Status 'fail'
        }
    } catch {
        Write-Step "error configuring $Name" -Status 'fail'
        Write-Log "APP SETTINGS ERR ($Name): $_"
    } finally {
        # unload hive if successfully loaded
        if ($hiveLoaded) {
            [gc]::Collect()
            Start-Sleep -Seconds 2
            reg unload "HKLM\Settings" >$null 2>&1
        }
        # clean up temp registry file
        if (Test-Path $tempRegPath) {
            Remove-Item -Path $tempRegPath -Force -ErrorAction SilentlyContinue
        }
        # restore ErrorActionPreference
        $ErrorActionPreference = $oldEAP
    }
}

# ── network helper ────────────────────────────────────

function Test-Network { return (Test-Connection -ComputerName '1.1.1.1' -Count 3 -Quiet -ErrorAction SilentlyContinue) }

<#
# ── phase 1 · debloat | aggressively uninstalls uwp bloatware, optional features, onedrive, and executes a total structural purge of microsoft edge.

Write-Phase 'debloat'

Write-Step 'uwp bloat'
$keepList = @(
    '*CBS*'
    '*Microsoft.AV1VideoExtension*'
    '*Microsoft.AVCEncoderVideoExtension*'
    '*Microsoft.HEIFImageExtension*'
    '*Microsoft.HEVCVideoExtension*'
    '*Microsoft.MPEG2VideoExtension*'
    '*Microsoft.Paint*'
    '*Microsoft.RawImageExtension*'
    '*Microsoft.SecHealthUI*'
    '*Microsoft.VP9VideoExtensions*'
    '*Microsoft.WebMediaExtensions*'
    '*Microsoft.WebpImageExtension*'
    '*Microsoft.Windows.ShellExperienceHost*'
    '*Microsoft.Windows.StartMenuExperienceHost*'
    '*Microsoft.WindowsCalculator*'
    '*Microsoft.WindowsNotepad*'
    '*Microsoft.WindowsStore*'
    '*Windows.ImmersiveControlPanel*'
    '*NVIDIACorp.NVIDIAControlPanel*'
)
function Test-ShouldKeep {
    param([string]$Name)
    foreach ($p in $keepList) {
        if ($Name -like $p) { return $true }
    }
    return $false
}
Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-ShouldKeep $_.Name) } |
    ForEach-Object {
        try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-ShouldKeep $_.DisplayName) } |
    ForEach-Object {
        try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -NoRestart -ErrorAction SilentlyContinue | Out-Null } catch {}
    }

# windows capabilities
Write-Step 'windows capabilities'
try {
    Get-WindowsCapability -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Installed'             -and
        $_.Name  -notlike '*Ethernet*'       -and
        $_.Name  -notlike '*WiFi*'           -and
        $_.Name  -notlike '*Notepad*'        -and
        $_.Name  -notlike '*NetFX3*'         -and
        $_.Name  -notlike '*VBSCRIPT*'       -and
        $_.Name  -notlike '*WMIC*'           -and
        $_.Name  -notlike '*ShellComponents*'
    } | ForEach-Object {
        # Write-Step "capability: $($_.Name.Split('~')[0].ToLower())" 'run'
        try {
            Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null
            # Write-Step "capability: $($_.Name.Split('~')[0].ToLower())" 'ok'
        } catch {
            # Write-Step "capability: $($_.Name.Split('~')[0].ToLower())" 'fail'
        }
    }
} catch { Write-Step 'capability removal skipped' 'warn' }

# optional features
Write-Step 'windows optional features'
try {
    Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object {
        $_.State       -eq 'Enabled'                    -and
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
        # Write-Step "feature: $($_.FeatureName.ToLower())" 'run'
        try {
            Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null
            # Write-Step "feature: $($_.FeatureName.ToLower())" 'ok'
        } catch {
            # Write-Step "feature: $($_.FeatureName.ToLower())" 'fail'
        }
    }
} catch { Write-Step 'optional feature removal skipped' 'warn' }

# ── edge ──────────────────────────────────────────────────
Write-Step 'microsoft edge'

function Remove-MicrosoftEdge {
    $updRoot = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate'

    # Write-Step 'stopping edge processes' 'run'
    $edgeProcs = @('msedge','MicrosoftEdgeUpdate','MicrosoftEdge','msedgewebview2','setup','identity_helper','msedge_proxy','MicrosoftEdgeUpdateBroker','MicrosoftEdgeUpdateOnDemand','MicrosoftEdgeUpdateComRegisterShell64','msedgeupdate')
    foreach ($pname in $edgeProcs) {
        Get-Process -Name $pname -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Write-Step 'disabling edge tasks & services' 'run'
    @('\MicrosoftEdgeUpdateTaskMachineCore',
      '\MicrosoftEdgeUpdateTaskMachineUA',
      '\MicrosoftEdgeUpdateTaskMachineCoreSystem',
      '\MicrosoftEdgeUpdateBrowserReplacementTask'
    ) | ForEach-Object {
        try { Disable-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        $tn = $_.TrimStart('\')
        $tf = "$env:windir\System32\Tasks\$tn"
        if (Test-Path $tf) {
            Remove-Item -Path $tf -Force -ErrorAction SilentlyContinue
        }
    }

    @('edgeupdate','edgeupdatem','MicrosoftEdgeElevationService') | ForEach-Object {
        try { Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue } catch {}
        & sc.exe config $_ start= disabled 2>&1 | Out-Null
        & sc.exe delete $_ 2>&1 | Out-Null
    }

    [Microsoft.Win32.Registry]::SetValue('HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev', 'AllowUninstall', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update' -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView' -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null

    # Write-Step 'removing edge appx packages' 'run'
    $edgePkg = Get-AppxPackage -AllUsers -Name 'Microsoft.MicrosoftEdge*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*WebView*' }
    foreach ($pkg in $edgePkg) {
        try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction SilentlyContinue | Out-Null } catch {}
    }

    # Write-Step 'executing edge uninstaller' 'run'
    $edgeDirs = @("$env:ProgramFiles\Microsoft\Edge", "${env:ProgramFiles(x86)}\Microsoft\Edge")
    foreach ($d in $edgeDirs) {
        if ($d -and (Test-Path $d)) {
            $appDir = Join-Path $d 'Application'
            if (Test-Path $appDir) {
                $ver = Get-ChildItem $appDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+\.' } | Select-Object -First 1
                if ($ver) {
                    $setupExe = Join-Path $ver.FullName 'Installer\setup.exe'
                    if (Test-Path $setupExe) {
                        Start-Process $setupExe -ArgumentList '--uninstall --system-level --verbose-logging --force-uninstall' -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
                    }
                }
            }
        }
    }

    $csPaths = @("$updRoot\ClientState\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}", "$updRoot\ClientState\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}")
    foreach ($csPath in $csPaths) {
        if (Test-Path $csPath) {
            Remove-ItemProperty -Path $csPath -Name 'experiment_control_labels' -ErrorAction SilentlyContinue | Out-Null
            $fakeDir = "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
            if (!(Test-Path $fakeDir)) { New-Item -ItemType Directory -Path $fakeDir -Force -ErrorAction SilentlyContinue | Out-Null }
            New-Item -ItemType File -Path "$fakeDir\MicrosoftEdge.exe" -Force -ErrorAction SilentlyContinue | Out-Null

            $prevWinDir = $env:windir; $env:windir = ''
            $exe = (Get-ItemProperty -Path $csPath -ErrorAction SilentlyContinue).UninstallString
            $uargs = (Get-ItemProperty -Path $csPath -ErrorAction SilentlyContinue).UninstallArguments

            if ($exe -and $uargs -and (Test-Path $exe)) {
                $uargs += ' --force-uninstall --delete-profile'
                $spoofPath = "$env:SystemRoot\ImmersiveControlPanel\sihost.exe"
                try {
                    if (!(Test-Path "$env:SystemRoot\ImmersiveControlPanel")) { New-Item -ItemType Directory -Path "$env:SystemRoot\ImmersiveControlPanel" -Force -ErrorAction SilentlyContinue | Out-Null }
                    Copy-Item "$env:SystemRoot\System32\cmd.exe" -Destination $spoofPath -Force -ErrorAction SilentlyContinue
                    Start-Process -FilePath $spoofPath -ArgumentList "/c `"$exe`" $uargs" -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
                } finally {
                    Remove-Item $spoofPath -Force -ErrorAction SilentlyContinue
                }
            }
            $env:windir = $prevWinDir
        }
    }

    $unCmd = (Get-ItemProperty -Path $updRoot -ErrorAction SilentlyContinue).UninstallCmdLine
    if ($unCmd) {
        Start-Process cmd.exe -ArgumentList "/c $unCmd" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($pname in $edgeProcs) {
        Get-Process -Name $pname -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Write-Step 'cleaning up shortcuts & files' 'run'
    $desktopPaths = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs","$env:PUBLIC\Desktop")
    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public','Default','Default User','All Users','WDAGUtilityAccount') } | ForEach-Object {
        $desktopPaths += (Join-Path $_.FullName 'Desktop')
    }
    foreach ($p in $desktopPaths) {
        Remove-Item (Join-Path $p 'Microsoft Edge.lnk') -Force -ErrorAction SilentlyContinue
    }

    $edgeUpdateDirs = @(
        "$env:ProgramFiles\Microsoft\EdgeUpdate", "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate",
        "$env:ProgramFiles\Microsoft\EdgeCore", "${env:ProgramFiles(x86)}\Microsoft\EdgeCore"
    )
    foreach ($d in ($edgeDirs + $edgeUpdateDirs)) {
        if ($d -and (Test-Path $d)) { Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('Public','Default','Default User','All Users','WDAGUtilityAccount') } | ForEach-Object {
        foreach ($sub in @('Microsoft\Edge','Microsoft\EdgeUpdate','Microsoft\EdgeCore','Microsoft\EdgeWebView')) {
            $p = Join-Path $_.FullName "AppData\Local\$sub"
            if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # Write-Step 'purging edge registry keys' 'run'
    foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Edge',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update'
    )) {
        if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $liveUserKeys = @()
    try {
        if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
        }
        $liveUserKeys = Get-ChildItem -Path 'Registry::HKU' -ErrorAction SilentlyContinue | Where-Object {
            ($_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$') -or $_.PSChildName -match '^Albus_UserHive_'
        }
    } catch {}

    foreach ($userKey in $liveUserKeys) {
        $sid = $userKey.PSChildName
        $hivePath = "Registry::HKU\$sid"
        $appData = $null
        if ($sid -match '^Albus_UserHive_') {
            $appData = "$env:SystemDrive\Users\Default\AppData\Roaming"
        } else {
            try {
                $sf = "$hivePath\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
                $appData = (Get-ItemProperty -Path $sf -Name 'AppData' -ErrorAction SilentlyContinue).AppData
            } catch {}
            if ([string]::IsNullOrEmpty($appData) -or -not (Test-Path $appData)) {
                try {
                    $profileList = "Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
                    $profPath = (Get-ItemProperty -Path $profileList -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
                    if ($profPath -and (Test-Path $profPath)) { $appData = Join-Path $profPath 'AppData\Roaming' }
                } catch {}
            }
        }
        if (-not [string]::IsNullOrEmpty($appData) -and (Test-Path $appData)) {
            $taskBarDir = Join-Path $appData 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
            if (Test-Path $taskBarDir) {
                Get-ChildItem -Path $taskBarDir -File -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match '^Microsoft Edge.*\.lnk$' -or $_.Name -ieq 'Edge.lnk'
                } | Remove-Item -Force -ErrorAction SilentlyContinue
            }
            $implicitDir = Join-Path $taskBarDir 'ImplicitAppShortcuts'
            if (Test-Path $implicitDir) {
                Get-ChildItem -Path $implicitDir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -match '^Microsoft Edge.*\.lnk$' -or $_.Name -ieq 'Edge.lnk'
                } | Remove-Item -Force -ErrorAction SilentlyContinue
            }
        }
        $taskband = "$hivePath\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
        if (Test-Path $taskband) {
            try { Remove-ItemProperty -Path $taskband -Name 'Favorites' -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-ItemProperty -Path $taskband -Name 'FavoritesResolve' -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-ItemProperty -Path $taskband -Name 'Pinned' -Force -ErrorAction SilentlyContinue } catch {}
            try { Set-ItemProperty -Path $taskband -Name 'FavoritesChanges' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
        }
        $auxPins = "$taskband\AuxilliaryPins"
        if (Test-Path $auxPins) {
            try { Set-ItemProperty -Path $auxPins -Name 'EdgePin' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    try {
        $sig = '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);'
        $type = Add-Type -MemberDefinition $sig -Name 'AlbusShellRefresh' -Namespace 'Albus' -PassThru -ErrorAction SilentlyContinue
        if ($type) { $type::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero) }
    } catch {}

    # Write-Step 'edge completely removed' 'ok'
}

Remove-MicrosoftEdge

# ── onedrive ──────────────────────────────────────────────
Write-Step 'onedrive'

function Remove-OneDrive {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
    }
    $exePaths = New-Object System.Collections.Generic.List[string]
    $fallbackPaths = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    )
    Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.PSChildName
        if ($sid -notmatch '^S-1-5-21-') { return }
        $regPath = "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe"
        try {
            $uninstallStr = (Get-ItemProperty -Path $regPath -ErrorAction Stop).UninstallString
        } catch {
            $uninstallStr = $null
        }
        if ($uninstallStr) {
            $exePath = $null
            if ($uninstallStr -match '^"(.+?)"') {
                $exePath = $matches[1]
            } else {
                $exePath = $uninstallStr.Split(' ')[0]
            }
            if ($exePath -and (Test-Path $exePath)) {
                $exePaths.Add($exePath) | Out-Null
            }
        }
        Remove-ItemProperty `
            -Path "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" `
            -Name 'OneDrive' `
            -ErrorAction SilentlyContinue
        Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in $fallbackPaths) {
        if (Test-Path $f) {
            $exePaths.Add($f) | Out-Null
        }
    }
    $exePaths = $exePaths | Select-Object -Unique
    foreach ($exe in $exePaths) {
        try {
            # Write-Step "uninstalling onedrive → $exe"
            Start-Process -FilePath $exe -ArgumentList '/uninstall' -Wait -NoNewWindow | Out-Null
        } catch {}
    }
    try {
        Get-AppxProvisionedPackage -Online | Where-Object {
            $_.DisplayName -like '*OneDrive*'
        } | ForEach-Object {
            Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue
        }
    } catch {}
    try {
        Get-AppxPackage -AllUsers *OneDrive* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    } catch {}
    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $paths = @(
            "$($_.FullName)\OneDrive",
            "$($_.FullName)\AppData\Local\Microsoft\OneDrive",
            "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $clsid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    try {
        New-Item -Path "HKCR:\CLSID\$clsid" -Force | Out-Null
        Set-ItemProperty -Path "HKCR:\CLSID\$clsid" -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord
    } catch {}
    try {
        New-Item -Path "HKCR:\Wow6432Node\CLSID\$clsid" -Force | Out-Null
        Set-ItemProperty -Path "HKCR:\Wow6432Node\CLSID\$clsid" -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord
    } catch {}
    # Write-Step 'onedrive removal complete'
}

Remove-OneDrive

# ── misc ──────────────────────────────────────────────────
Write-Step 'update health tools & gameinput'
$targets = 'Update for x64-based Windows Systems', 'Microsoft Update Health Tools', 'Microsoft GameInput'
$pattern = ($targets | ForEach-Object { [regex]::Escape($_) }) -join '|'

Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    Where-Object { $_.GetValue('DisplayName') -match $pattern } |
    ForEach-Object {
        if ($_.PSChildName) { Start-Process 'msiexec.exe' -ArgumentList "/x $($_.PSChildName) /qn /norestart" -Wait -NoNewWindow }
    }

$productKeys = Get-ChildItem 'HKCR:\Installer\Products' -ErrorAction SilentlyContinue |
    Where-Object { $_.GetValue('ProductName') -match $pattern }

foreach ($key in $productKeys) {
    $prodID = $key.PSChildName
    Set-Reg -Path "-HKCR:\Installer\Products\$prodID"
    Set-Reg -Path "-HKCR:\Installer\Features\$prodID"
    Set-Reg -Path "-HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$prodID"

    foreach ($path in @(
        'HKCR:\Installer\UpgradeCodes',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components'
    )) {
        Get-ChildItem $path -ErrorAction SilentlyContinue |
            Where-Object { $_.GetValueNames() -contains $prodID } |
            ForEach-Object { Set-Reg -Path "-$($_.Name)" }
    }
}

Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    Where-Object { $_.GetValue('DisplayName') -match $pattern } |
    ForEach-Object { Set-Reg -Path "-$($_.Name)" }

Unregister-ScheduledTask -TaskName PLUGScheduler -Confirm:$false -ErrorAction SilentlyContinue

Write-Done 'debloat'

# ── phase 2 · software | silently deploys essential tools: brave, 7-zip, localsend, vc++ runtimes, and directx.

Write-Phase 'software installation'
if (Test-Network) {
    # 2.1  brave browser
    try {
        Write-Step 'brave browser'
        $rel = (Invoke-RestMethod 'https://api.github.com/repos/brave/brave-browser/releases/latest')
        Get-File "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe" "$ALBUS_DIR\BraveSetup.exe"
        Start-Process -Wait "$ALBUS_DIR\BraveSetup.exe" -ArgumentList '/silent /install' -WindowStyle Hidden
        $bravePolicy = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
        Remove-Item -Path $bravePolicy -Recurse -Force -ErrorAction SilentlyContinue
        Set-Regs @(
            # telemetry & privacy
            @{ Path = $bravePolicy; Name = 'MetricsReportingEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'SafeBrowsingExtendedReportingEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'UrlKeyedAnonymizedDataCollectionEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'BraveP3AEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'BraveStatsPingEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'SafeBrowsingProtectionLevel'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'AutofillAddressEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'AutofillCreditCardEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'PasswordManagerEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'BrowserSignin'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'EnableDoNotTrack'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BraveGlobalPrivacyControlEnabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BraveDeAmpEnabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BraveDebouncingEnabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BraveTrackingQueryParametersFilteringEnabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BraveReduceLanguageEnabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'WebRtcIPHandling'; Value = 'disable_non_proxied_udp'; Type = 'String' }
            @{ Path = $bravePolicy; Name = 'QuicAllowed'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'BlockThirdPartyCookies'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'ForceGoogleSafeSearch'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'HttpsOnlyMode'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'DnsOverHttpsMode'; Value = 'secure'; Type = 'String' }
            @{ Path = $bravePolicy; Name = 'DnsOverHttpsTemplates'; Value = 'https://dns.quad9.net/dns-query'; Type = 'String' }
            # feature neutralization
            @{ Path = $bravePolicy; Name = 'BraveRewardsDisabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BraveWalletDisabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BraveVPNDisabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BraveAIChatEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'BraveNewsDisabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BraveTalkDisabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BravePlaylistEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'BraveWebDiscoveryEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'BraveSpeedreaderEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'TorDisabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'SyncDisabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'IPFSEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'BackgroundModeEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'ShoppingListEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'AlwaysOpenPdfExternally'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'TranslateEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'SpellcheckEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'SearchSuggestEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'PrintingEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'DefaultBrowserSettingEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'DeveloperToolsAvailability'; Value = 2 }
            @{ Path = $bravePolicy; Name = 'BraveWaybackMachineEnabled'; Value = 0 }
            @{ Path = $bravePolicy; Name = 'HardwareAccelerationModeEnabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'HighEfficiencyModeEnabled'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'BlockExternalExtensions'; Value = 1 }
            @{ Path = $bravePolicy; Name = 'SavingBrowserHistoryDisabled'; Value = 0 }
            @{ Path = "$bravePolicy\ExtensionInstallForcelist"; Name = '1'; Value = 'nngceckbapebfimnlniiiahkandclblb;https://clients2.google.com/service/update2/crx'; Type = 'String' } # bitwarden
        )
        Write-Step "brave $($rel.tag_name) installed" 'ok'
    } catch { Write-Step 'brave installation failed' 'fail' }

    # 2.2  7-zip
    try {
        Write-Step '7-zip'
        $rel = (Invoke-RestMethod 'https://api.github.com/repos/ip7z/7zip/releases/latest')
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
        $rel = (Invoke-RestMethod 'https://api.github.com/repos/localsend/localsend/releases/latest')
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

# ── phase 3 · gpu | automated driver fetching, extraction, and debloating (nvidia, amd, intel). applies profile inspector presets and driver-level registry optimizations.

function NVIDIA {
    Write-Phase 'nvidia driver setup'

    Write-Step 'finding latest nvidia driver'
    $uri = 'https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=120&pfid=929&osID=57&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1'
    $response = Invoke-RestMethod -Uri $uri -Method GET -UseBasicParsing
    $version = $response.IDS[0].downloadInfo.Version
    $windowsVersion = if ([Environment]::OSVersion.Version -ge (new-object 'Version' 9, 1)) {"win10-win11"} else {"win8-win7"}
    $windowsArchitecture = if ([Environment]::Is64BitOperatingSystem) {"64bit"} else {"32bit"}
    $url = "https://international.download.nvidia.com/Windows/$version/$version-desktop-$windowsVersion-$windowsArchitecture-international-dch-whql.exe"
    $OriginalFileName = ($url -split '/')[-1]

    $DriverExe = "$ALBUS_DIR\$OriginalFileName"
    Write-Step "downloading $OriginalFileName"
    Get-File $url $DriverExe

    $ZipExe = "$env:ProgramFiles\7-Zip\7z.exe"
    if (-not (Test-Path $ZipExe)) { Write-Step '7-zip not found' 'fail'; return }

    $ExtractPath = "$ALBUS_DIR\NVIDIA"
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }

    Write-Step 'extracting & debloating'
    & $ZipExe x $DriverExe -o"$ExtractPath" -y | Out-Null

    $Whitelist = '^(Display\.Driver|NVI2|EULA\.txt|ListDevices\.txt|setup\.cfg|setup\.exe)$'
    Get-ChildItem $ExtractPath | Where-Object { $_.Name -notmatch $Whitelist } | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $cfg = "$ExtractPath\setup.cfg"
    if (Test-Path $cfg) { (Get-Content $cfg) | Where-Object { $_ -notmatch 'EulaHtmlFile|FunctionalConsentFile|PrivacyPolicyFile' } | Set-Content $cfg -Force }

    Write-Step 'installing silently'
    Start-Process "$ExtractPath\setup.exe" -ArgumentList '-s -noreboot -noeula -clean' -Wait -NoNewWindow

    Remove-Item $DriverExe -Force -ErrorAction SilentlyContinue
    Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemDrive\NVIDIA" -Recurse -Force -ErrorAction SilentlyContinue

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
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Parameters\FTS' 'EnableGR535' 0

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
      <ProfileSetting><SettingNameInfo>OpenGL GDI Compatibility</SettingNameInfo><SettingID>544392611</SettingID><SettingValue>0</SettingValue><ValueType>Dword</ValueType></ProfileSetting>
      <ProfileSetting><SettingNameInfo>Preferred OpenGL GPU</SettingNameInfo><SettingID>550564838</SettingID><SettingValue>id,2.0:268410DE,00000100,GF - (400,2,161,24564) @ (0)</SettingValue><ValueType>String</ValueType></ProfileSetting>
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

    Write-Step 'downloading amd web installer'
    $DownloadAmd = Invoke-WebRequest "https://www.amd.com/en/support/download/drivers.html" -UseBasicParsing |
        Select-Object -ExpandProperty Links |
        Where-Object { $_.href -match "drivers\.amd\.com/drivers/installer/.*/whql/amd-software-adrenalin-edition-.*-minimalsetup-.*_web\.exe" } | Select-Object href -First 1

    $spoofwebbrowser = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        "Accept"     = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        "Referer"    = "https://www.amd.com/"
    }
    $OriginalFileName = ($DownloadAmd.href.Split('?')[0] -split '/')[-1]
    $DriverExe = "$ALBUS_DIR\$OriginalFileName"
    Write-Step "downloading $OriginalFileName"
    Invoke-WebRequest $DownloadAmd.href -UseBasicParsing -Headers $spoofwebbrowser -OutFile $DriverExe -ErrorAction SilentlyContinue | Out-Null

    $ZipExe = "$env:ProgramFiles\7-Zip\7z.exe"
    if (-not (Test-Path $ZipExe)) { Write-Step '7-zip not found' 'fail'; return }

    $ExtractPath = "$ALBUS_DIR\AMD"
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }

    Write-Step 'extracting & debloating'
    & $ZipExe x $DriverExe -o"$ExtractPath" -y | Out-Null

    $xmlFiles = @(
        "$ExtractPath\Config\AMDAUEPInstaller.xml",
        "$ExtractPath\Config\AMDCOMPUTE.xml",
        "$ExtractPath\Config\AMDLinkDriverUpdate.xml",
        "$ExtractPath\Config\AMDRELAUNCHER.xml",
        "$ExtractPath\Config\AMDScoSupportTypeUpdate.xml",
        "$ExtractPath\Config\AMDUpdater.xml",
        "$ExtractPath\Config\AMDUWPLauncher.xml",
        "$ExtractPath\Config\EnableWindowsDriverSearch.xml",
        "$ExtractPath\Config\InstallUEP.xml",
        "$ExtractPath\Config\ModifyLinkUpdate.xml"
    )
    foreach ($file in $xmlFiles) {
        if (Test-Path $file) {
            $content = Get-Content $file -Raw
            $content = $content -replace '<Enabled>true</Enabled>', '<Enabled>false</Enabled>'
            $content = $content -replace '<Hidden>true</Hidden>', '<Hidden>false</Hidden>'
            Set-Content $file -Value $content -NoNewline
        }
    }

    $jsonFiles = @(
        "$ExtractPath\Config\InstallManifest.json",
        "$ExtractPath\Bin64\cccmanifest_64.json"
    )
    foreach ($file in $jsonFiles) {
        if (Test-Path $file) {
            $content = Get-Content $file -Raw
            $content = $content -replace '"InstallByDefault"\s*:\s*"Yes"', '"InstallByDefault" : "No"'
            Set-Content $file -Value $content -NoNewline
        }
    }

    Write-Step 'installing silently'
    Start-Process "$ExtractPath\Bin64\ATISetup.exe" -ArgumentList "-INSTALL -VIEW:2" -Wait -WindowStyle Hidden

    Write-Step 'cleaning up bloatware & services'
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "AMDNoiseSuppression" -ErrorAction SilentlyContinue | Out-Null
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" -Name "StartRSX" -ErrorAction SilentlyContinue | Out-Null
    Unregister-ScheduledTask -TaskName "StartCN" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

    @('AMD Crash Defender Service', 'amdfendr', 'amdfendrmgr', 'amdacpbus', 'AMDSAFD', 'AtiHDAudioService') | ForEach-Object {
        sc.exe stop $_ | Out-Null
        sc.exe delete $_ | Out-Null
    }

    Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AMD Bug Report Tool" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemDrive\Windows\SysWOW64\AMDBugReportTool.exe" -Force -ErrorAction SilentlyContinue

    $amdinstallmanager = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*AMD Install Manager*" }
    if ($amdinstallmanager) {
        $guid = $amdinstallmanager.PSChildName
        Start-Process "msiexec.exe" -ArgumentList "/x $guid /qn /norestart" -Wait -NoNewWindow
    }

    $folderName = "AMD Software$([char]0xA789) Adrenalin Edition"
    Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$folderName\$folderName.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$folderName" -Recurse -Force -ErrorAction SilentlyContinue

    Remove-Item $DriverExe -Force -ErrorAction SilentlyContinue
    Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemDrive\AMD" -Recurse -Force -ErrorAction SilentlyContinue

    Write-Step 'amd optimizations'
    Start-Process "$env:SystemDrive\Program Files\AMD\CNext\CNext\RadeonSoftware.exe"
    Start-Sleep -Seconds 15
    Stop-Process -Name "RadeonSoftware" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Set-Reg 'HKCU:\Software\AMD\CN' 'AutoUpdate' 0
    Set-Reg 'HKCU:\Software\AMD\CN' 'WizardProfile' 'PROFILE_CUSTOM' 'String'

    $basePath = "HKLM:\System\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "UMD" } | ForEach-Object {
        Set-Reg $_.Name 'VSyncControl' ([byte[]](0x30,0x30,0x30,0x30)) 'Binary'
        Set-Reg $_.Name 'TFQ' ([byte[]](0x33,0x32,0x30,0x30)) 'Binary'
        Set-Reg $_.Name 'Tessellation' ([byte[]](0x33,0x31,0x30,0x30)) 'Binary'
        Set-Reg $_.Name 'Tessellation_OPTION' ([byte[]](0x33,0x32,0x30,0x30)) 'Binary'
    }

    Set-Reg 'HKCU:\Software\AMD\CN\CustomResolutions' 'EulaAccepted' 'true' 'String'
    Set-Reg 'HKCU:\Software\AMD\CN\DisplayOverride' 'EulaAccepted' 'true' 'String'

    Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "power_v1" } | ForEach-Object {
        Set-Reg $_.Name 'abmlevel' ([byte[]](0x30,0x30,0x30,0x30,0x30,0x30,0x30,0x30)) 'Binary'
    }

    Set-Reg 'HKCU:\Software\AMD\CN' 'SystemTray' 'false' 'String'
    Set-Reg 'HKCU:\Software\AMD\CN' 'CN_Hide_Toast_Notification' 'true' 'String'
    Set-Reg 'HKCU:\Software\AMD\CN' 'AnimationEffect' 'false' 'String'

    Remove-Item "Registry::HKCU\Software\AMD\CN\Notification" -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path "Registry::HKCU\Software\AMD\CN\Notification" -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Reg 'HKCU:\Software\AMD\CN\FreeSync' 'AlreadyNotified' 1
    Set-Reg 'HKCU:\Software\AMD\CN\OverlayNotification' 'AlreadyNotified' 1
    Set-Reg 'HKCU:\Software\AMD\CN\VirtualSuperResolution' 'AlreadyNotified' 1

    Write-Done 'amd driver setup'
}

function INTEL {
    Write-Phase 'intel driver setup'

    Write-Step '  download the driver, then press any key...' -ForegroundColor Yellow
    Start-Process "https://www.intel.com/content/www/us/en/search.html#sortCriteria=%40lastmodifieddt%20descending&f-operatingsystem_en=Windows%2011%20Family*&f-downloadtype=Drivers&cf-tabfilter=Downloads&cf-downloadsppth=Graphics"
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title, $dlg.Filter = 'select intel driver', 'Executable (*.exe)|*.exe'
    if ($dlg.ShowDialog() -ne 'OK') { Write-Step 'cancelled' 'warn'; return }

    $ZipExe = "$env:ProgramFiles\7-Zip\7z.exe"
    if (-not (Test-Path $ZipExe)) { Write-Step '7-zip not found' 'fail'; return }

    $ExtractPath = "$ALBUS_DIR\INTEL"
    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }

    Write-Step 'extracting & debloating'
    & $ZipExe x $dlg.FileName -o"$ExtractPath" -y | Out-Null

    Write-Step 'installing silently'
    Start-Process "cmd.exe" -ArgumentList "/c `"$ExtractPath\Installer.exe`" -f --noExtras --terminateProcesses -s" -WindowStyle Hidden -Wait

    $IntelGraphicsSoftware = Get-ChildItem "$ExtractPath\Resources\Extras\IntelGraphicsSoftware_*.exe" | Select-Object -First 1 -ExpandProperty Name
    if ($IntelGraphicsSoftware) {
        Start-Process "$ExtractPath\Resources\Extras\$IntelGraphicsSoftware" -ArgumentList "/s" -Wait -NoNewWindow
    }

    Write-Step 'cleaning up bloatware & services'
    $FileName = "Intel$([char]0xAE) Graphics Software"
    Remove-ItemProperty -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run" -Name $FileName -ErrorAction SilentlyContinue | Out-Null

    @('IntelGFXFWupdateTool', 'cplspcon', 'CtaChildDriver', 'GSCAuxDriver', 'GSCx64') | ForEach-Object {
        sc.exe stop $_ | Out-Null
        sc.exe delete $_ | Out-Null
    }

    @('IntelGraphicsSoftware', 'PresentMonService') | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Remove-Item "$env:SystemDrive\Program Files\Intel\Intel Graphics Software\PresentMonService.exe" -Force -ErrorAction SilentlyContinue

    Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Intel\Intel Graphics Software\$FileName.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Intel" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:SystemDrive\Intel" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue

    Write-Step 'intel optimizations'
    $basePath = "HKLM:\System\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    Get-ChildItem -Path $basePath -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        New-Item -Path "$($_.PSPath)\3DKeys" -Force -ErrorAction SilentlyContinue | Out-Null
    }

    Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -eq "3DKeys" } | ForEach-Object {
        Set-Reg $_.Name 'Global_AsyncFlipMode' 2
        Set-Reg $_.Name 'Global_LowLatency' 0
    }

    Write-Done 'intel driver setup'
}

$basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\MonitorDataStore"
Get-ChildItem -Path $basePath -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    Set-Reg $_.Name 'AutoColorManagementEnabled' 0
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
        Write-Step 'amd core not implemented yet' 'warn'
        Write-Done 'GPU SELECTION'
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

#>

# ── phase 4 · registry | overwrites ~400 keys covering boot optimizations, prefetch, uac, defender, edge policies, and visual effects.

Write-Phase 'services'

# removing rdyboost from lowerfilters
$lfPath = 'HKLM:\SYSTEM\ControlSet001\Control\Class\{71a27cdd-812a-11d0-bec7-08002be2092f}'
$lf = (Get-ItemProperty -Path $lfPath -ErrorAction SilentlyContinue).LowerFilters
if ($lf -contains 'rdyboost') {
    $lf = $lf | Where-Object { $_ -ne 'rdyboost' }
    Set-ItemProperty -Path $lfPath -Name 'LowerFilters' -Value $lf
}

# ── svchost split threshold (disable split host) ──────────────
Write-Step 'svchost split threshold'
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
    # .
    @{ Name = 'uhssvc';                                   Start = 2 }
)

Write-Step 'configuring services and drivers'
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

Write-Done 'services configured'

# phase 2 · scheduled tasks | wipes 16 scheduled task groups (ceip, defrag, diagnostics, telemetry).
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
    Write-Step "$label"
    Get-ScheduledTask -TaskPath $path -ErrorAction SilentlyContinue |
        Where-Object { $_.State -ne 'Disabled' } |
        Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
}

Write-Done 'scheduled tasks'

Write-Phase 'network configuration'

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

Write-Step 'tuning network quality of service'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\QoS' 'Do not use NLA' '1' 'String'
Remove-NetQosPolicy -Name 'Albus-QoS-*' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

$games = @(
    'cs2.exe',
    'r5apex.exe'
)
foreach ($Game in $games) {
    $Name = "Albus-QoS-$($Game.Replace('.exe', ''))"
    New-NetQosPolicy -Name $Name -AppPathNameMatchCondition $Game -DSCPAction 46 -NetworkProfile All -ErrorAction SilentlyContinue | Out-Null
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

Write-Step 'configuring tcp/ip stack'
$tcp = @(
    'autotuninglevel=normal',
    'ecncapability=disabled',
    'timestamps=disabled',
    'initialRto=2000',
    'rss=enabled',
    'rsc=disabled',
    'nonsackrttresiliency=disabled'
)
foreach ($cmd in $tcp) { netsh int tcp set global $cmd | Out-Null }

netsh int tcp set supplemental template=internet congestionprovider=cubic | Out-Null

Write-Done 'network configuration'

# phase 
# 