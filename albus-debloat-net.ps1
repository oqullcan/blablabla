#Requires -RunAsAdministrator

Add-Type -AssemblyName System.ServiceProcess

# configuration - exclusion lists
[string[]]$UwpAppExclusions = @(
    '*CBS*', '*Microsoft.AV1VideoExtension*', '*Microsoft.AVCEncoderVideoExtension*',
    '*Microsoft.HEIFImageExtension*', '*Microsoft.HEVCVideoExtension*', '*Microsoft.MPEG2VideoExtension*',
    '*Microsoft.Paint*', '*Microsoft.RawImageExtension*', '*Microsoft.SecHealthUI*',
    '*Microsoft.VP9VideoExtensions*', '*Microsoft.WebMediaExtensions*', '*Microsoft.WebpImageExtension*',
    '*Microsoft.Windows.Photos*', '*Microsoft.Windows.ShellExperienceHost*',
    '*Microsoft.Windows.StartMenuExperienceHost*', '*Microsoft.WindowsNotepad*',
    '*Microsoft.WindowsStore*', '*NVIDIACorp.NVIDIAControlPanel*', '*windows.immersivecontrolpanel*',
    '*Microsoft.UI.Xaml*', '*Microsoft.VCLibs*', '*Microsoft.NET.Native.Framework*',
    '*Microsoft.NET.Native.Runtime*', '*Microsoft.DesktopAppInstaller*', '*Microsoft.Windows.Search*',
    '*Microsoft.Windows.ShellComponents*'
)

[string[]]$UwpFeatureExclusions = @(
    '*Microsoft.Windows.Ethernet*', '*Microsoft.Windows.MSPaint*', '*Microsoft.Windows.Notepad*',
    '*Microsoft.Windows.Notepad.System*', '*Microsoft.Windows.Wifi*', '*NetFX3*', '*VBSCRIPT*',
    '*WMIC*', '*Windows.Client.ShellComponents*'
)

[string[]]$LegacyFeatureExclusions = @(
    '*DirectPlay*', '*LegacyComponents*', '*NetFx3*', '*NetFx4*', '*NetFx4-AdvSrvs*', '*NetFx4ServerFeatures*',
    '*SearchEngine-Client-Package*', '*Server-Shell*', '*Windows-Defender*', '*Server-Drivers-General*',
    '*ServerCore-Drivers-General*', '*ServerCore-Drivers-General-WOW64*', '*Server-Gui-Mgmt*',
    '*WirelessNetworking*'
)

[string[]]$StartupExclusions = @("SecurityHealth", "ctfmon", "WindowsDefender")

# silent process execution helper
function Invoke-SilentProcess([string]$FilePath, [string]$Arguments) {
    if (-not [System.IO.File]::Exists($FilePath)) { return }
    $PSI = [System.Diagnostics.ProcessStartInfo]::new()
    $PSI.FileName = $FilePath
    $PSI.Arguments = $Arguments
    $PSI.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $PSI.CreateNoWindow = $true
    $PSI.UseShellExecute = $false
    try {
        $Proc = [System.Diagnostics.Process]::Start($PSI)
        if ($null -ne $Proc) { $Proc.WaitForExit() }
    } catch {}
}


# 1. kill all bloatware processes first to prevent interference
Write-Host "Killing bloatware processes..." -ForegroundColor Cyan

[string[]]$KillList = "backgroundTaskHost", "Copilot", "CrossDeviceResume", "GameBar", "MicrosoftEdgeUpdate", "msedge", "msedgewebview2", "OneDrive", "OneDrive.Sync.Service", "OneDriveStandaloneUpdater", "Resume", "RuntimeBroker", "Search", "SearchHost", "Setup", "StoreDesktopExtension", "WidgetService", "Widgets"
foreach ($Proc in [System.Diagnostics.Process]::GetProcesses()) {
    $Name = $Proc.ProcessName
    if ($KillList -contains $Name -or $Name -like "*edge*") {
        try { $Proc.Kill() } catch {}
    }
}


# 2. remove 3rd party startup entries and scheduled tasks (prevent respawning)
Write-Host "`nRemoving 3rd party startup entries & scheduled tasks..." -ForegroundColor Cyan

# startup registry keys via api
$RunKeys = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunNotification",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
)
foreach ($KeyPath in $RunKeys) {
    try {
        $Hive = if ($KeyPath.StartsWith("HKLM")) { [Microsoft.Win32.Registry]::LocalMachine } else { [Microsoft.Win32.Registry]::CurrentUser }
        $SubPath = $KeyPath.Substring(5)
        $Key = $Hive.OpenSubKey($SubPath, $true)
        if ($Key) {
            foreach ($Val in $Key.GetValueNames()) {
                if ($StartupExclusions -notcontains $Val) { $Key.DeleteValue($Val, $false) }
            }
        }
    } catch {}
}

# startup folders via api
try {
    foreach ($F in [System.IO.Directory]::GetFiles([Environment]::GetFolderPath("Startup"))) { [System.IO.File]::Delete($F) }
    foreach ($F in [System.IO.Directory]::GetFiles([Environment]::GetFolderPath("CommonStartup"))) { [System.IO.File]::Delete($F) }
} catch {}

# scheduled tasks via registry api
try {
    $TaskCache = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree", $true)
    if ($TaskCache) {
        foreach ($Task in $TaskCache.GetSubKeyNames()) {
            if ($Task -ne "Microsoft") { $TaskCache.DeleteSubKeyTree($Task, $false) }
        }
    }
    $TasksDir = [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "System32\Tasks")
    if ([System.IO.Directory]::Exists($TasksDir)) {
        foreach ($D in [System.IO.Directory]::GetDirectories($TasksDir)) {
            if ([System.IO.Path]::GetFileName($D) -ne "Microsoft") { [System.IO.Directory]::Delete($D, $true) }
        }
        foreach ($F in [System.IO.Directory]::GetFiles($TasksDir)) { [System.IO.File]::Delete($F) }
    }
} catch {}


# 3. remove microsoft edge
Write-Host "`nPurging Microsoft Edge..." -ForegroundColor Cyan

# bypass eu restrictions via region spoof
$RegionKey = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Control Panel\DeviceRegion"
$OldRegion = [Microsoft.Win32.Registry]::GetValue($RegionKey, "DeviceRegion", $null)
[Microsoft.Win32.Registry]::SetValue($RegionKey, "DeviceRegion", 244, [Microsoft.Win32.RegistryValueKind]::DWord)

# allow uninstall via registry api
[Microsoft.Win32.Registry]::SetValue("HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev", "AllowUninstall", 1, [Microsoft.Win32.RegistryValueKind]::DWord)
try {
    $EdgeUninstallKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge", $true)
    if ($EdgeUninstallKey) { $EdgeUninstallKey.DeleteValue("NoRemove", $false) }
    $EdgeUpdateUninstallKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update", $true)
    if ($EdgeUpdateUninstallKey) { $EdgeUpdateUninstallKey.DeleteValue("NoRemove", $false) }
} catch {}

# clear edgeupdate registry
[string[]]$EdgeRegPaths = "SOFTWARE\Microsoft\EdgeUpdate", "SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate", "SOFTWARE\Policies\Microsoft\EdgeUpdate", "SOFTWARE\WOW6432Node\Policies\Microsoft\EdgeUpdate"
foreach ($Path in $EdgeRegPaths) {
    try { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($Path, $false) } catch {}
    try { [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree($Path, $false) } catch {}
}

# uninstall edgeupdate binaries
[string[]]$EdgeDirs = [Environment]::GetFolderPath("LocalApplicationData"), [Environment]::GetFolderPath("ProgramFilesX86"), [Environment]::GetFolderPath("ProgramFiles")
foreach ($Dir in $EdgeDirs) {
    $UpdateDir = [System.IO.Path]::Combine($Dir, "Microsoft", "EdgeUpdate")
    if ([System.IO.Directory]::Exists($UpdateDir)) {
        foreach ($Exe in [System.IO.Directory]::GetFiles($UpdateDir, "MicrosoftEdgeUpdate.exe", [System.IO.SearchOption]::AllDirectories)) {
            Invoke-SilentProcess $Exe "/unregsvc"
            Invoke-SilentProcess $Exe "/uninstall"
        }
    }
}

# spoof edge system app for uninstaller
$EdgeAppPath = [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "SystemApps", "Microsoft.MicrosoftEdge_8wekyb3d8bbwe")
if (-not [System.IO.Directory]::Exists($EdgeAppPath)) { [System.IO.Directory]::CreateDirectory($EdgeAppPath) | Out-Null }
$SpoofExe = [System.IO.Path]::Combine($EdgeAppPath, "MicrosoftEdge.exe")
if (-not [System.IO.File]::Exists($SpoofExe)) { [System.IO.File]::Create($SpoofExe).Close() }

# invoke edge uninstaller
try {
    $EdgeKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge")
    if ($EdgeKey) {
        $UninstallString = $EdgeKey.GetValue("UninstallString")
        if ($UninstallString) {
            $UninstallString += " --force-uninstall --delete-profile"
            Invoke-SilentProcess "cmd.exe" "/c $UninstallString"
        }
    }
} catch {}

# clean edge leftover files
if ([System.IO.Directory]::Exists($EdgeAppPath)) { try { [System.IO.Directory]::Delete($EdgeAppPath, $true) } catch {} }

[string[]]$Shortcuts = [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("SystemDrive"), "Windows\System32\config\systemprofile\AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\Microsoft Edge.lnk"),
                       [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("PUBLIC"), "Desktop\Microsoft Edge.lnk"),
                       [System.IO.Path]::Combine([Environment]::GetFolderPath("Desktop"), "Microsoft Edge.lnk"),
                       [System.IO.Path]::Combine([Environment]::GetFolderPath("CommonPrograms"), "Microsoft Edge.lnk")
foreach ($Shortcut in $Shortcuts) { if ([System.IO.File]::Exists($Shortcut)) { try { [System.IO.File]::Delete($Shortcut) } catch {} } }

# clean edge leftover registry
try { [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree("SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView", $false) } catch {}

# remove edge services via api
foreach ($Svc in [System.ServiceProcess.ServiceController]::GetServices()) {
    if ($Svc.ServiceName -match 'Edge') {
        try {
            if ($Svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) { $Svc.Stop(); $Svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(5)) }
            Invoke-SilentProcess "sc.exe" "delete `"$($Svc.ServiceName)`""
        } catch {}
    }
}

# remove edge folders (only edge, not whole microsoft dir)
$Prog86 = [Environment]::GetFolderPath("ProgramFilesX86")
$EdgeFolder = [System.IO.Path]::Combine($Prog86, "Microsoft", "Edge")
$EdgeUpdateFolder = [System.IO.Path]::Combine($Prog86, "Microsoft", "EdgeUpdate")
if ([System.IO.Directory]::Exists($EdgeFolder)) { try { [System.IO.Directory]::Delete($EdgeFolder, $true) } catch {} }
if ([System.IO.Directory]::Exists($EdgeUpdateFolder)) { try { [System.IO.Directory]::Delete($EdgeUpdateFolder, $true) } catch {} }

# edge legacy cbs package (windows 10)
try {
    $CBSKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages", $true)
    if ($CBSKey) {
        foreach ($Sub in $CBSKey.GetSubKeyNames()) {
            if ($Sub -like "*Microsoft-Windows-Internet-Browser-Package*~~*") {
                $PkgKey = $CBSKey.OpenSubKey($Sub, $true)
                if ($PkgKey) { $PkgKey.SetValue("Visibility", 1, [Microsoft.Win32.RegistryValueKind]::DWord) }
                try { $CBSKey.OpenSubKey($Sub, $true).DeleteSubKeyTree("Owners", $false) } catch {}
                Invoke-SilentProcess "dism.exe" "/online /Remove-Package /PackageName:$Sub /quiet /norestart"
            }
        }
    }
} catch {}

# restore original region
if ($OldRegion) {
    [Microsoft.Win32.Registry]::SetValue($RegionKey, "DeviceRegion", $OldRegion, [Microsoft.Win32.RegistryValueKind]::DWord)
}


# 4. remove onedrive & legacy apps
Write-Host "`nPurging OneDrive & Legacy Apps..." -ForegroundColor Cyan

# onedrive
try {
    foreach ($P in [System.Diagnostics.Process]::GetProcessesByName("OneDrive")) { $P.Kill() }
} catch {}
Invoke-SilentProcess ([System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "System32\OneDriveSetup.exe")) "-uninstall"
Invoke-SilentProcess ([System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "SysWOW64\OneDriveSetup.exe")) "-uninstall"
try {
    $LocalAppData = [Environment]::GetFolderPath("LocalApplicationData")
    foreach ($Exe in [System.IO.Directory]::GetFiles($LocalAppData, "OneDriveSetup.exe", [System.IO.SearchOption]::AllDirectories)) {
        Invoke-SilentProcess $Exe "/uninstall /allusers"
    }
} catch {}
Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'OneDrive' } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

# brlapi
foreach ($Svc in [System.ServiceProcess.ServiceController]::GetServices()) {
    if ($Svc.ServiceName -eq 'brlapi') {
        try {
            if ($Svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) { $Svc.Stop() }
            Invoke-SilentProcess "sc.exe" "delete brlapi"
        } catch {}
    }
}
$BrlttyPath = [System.IO.Path]::Combine([Environment]::GetEnvironmentVariable("SystemRoot"), "brltty")
if ([System.IO.Directory]::Exists($BrlttyPath)) {
    Invoke-SilentProcess "cmd.exe" "/c takeown /f `"$BrlttyPath`" /r /d y & icacls `"$BrlttyPath`" /grant *S-1-5-32-544:F /t & rd /s /q `"$BrlttyPath`""
}

# msi installers (gameinput, health tools, update for x64)
[string[]]$MSINames = "*Microsoft GameInput*", "*Microsoft Update Health Tools*", "*Update for x64-based Windows Systems*"
try {
    $UninstallReg = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")
    if ($UninstallReg) {
        foreach ($Sub in $UninstallReg.GetSubKeyNames()) {
            $AppKey = $UninstallReg.OpenSubKey($Sub)
            if ($AppKey) {
                $DisplayName = $AppKey.GetValue("DisplayName")
                if ($DisplayName) {
                    foreach ($Pattern in $MSINames) {
                        if ($DisplayName -like $Pattern) {
                            Invoke-SilentProcess "msiexec.exe" "/x $Sub /qn /norestart"
                            break
                        }
                    }
                }
            }
        }
    }
} catch {}

try { [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree("SYSTEM\ControlSet001\Services\uhssvc", $false) } catch {}
try { Unregister-ScheduledTask -TaskName PLUGScheduler -Confirm:$false -ErrorAction Stop | Out-Null } catch {}


# 5. remove uwp apps
Write-Host "`nPurging UWP Apps..." -ForegroundColor Cyan

$UwpRegex = "(?i)^(" + (($UwpAppExclusions | ForEach-Object { [Regex]::Escape($_).Replace('\*', '.*') }) -join '|') + ")$"
foreach ($App in (Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
    if ($App.Name -notmatch $UwpRegex) {
        try { Remove-AppxPackage -Package $App.PackageFullName -AllUsers -ErrorAction Stop | Out-Null } catch {}
    }
}


# 6. remove uwp features
Write-Host "`nPurging UWP Features..." -ForegroundColor Cyan

$FeatRegex = "(?i)^(" + (($UwpFeatureExclusions | ForEach-Object { [Regex]::Escape($_).Replace('\*', '.*') }) -join '|') + ")$"
foreach ($Feat in (Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object State -eq 'Installed')) {
    if ($Feat.Name -notmatch $FeatRegex) {
        try { Remove-WindowsCapability -Online -Name $Feat.Name -ErrorAction Stop | Out-Null } catch {}
    }
}


# 7. remove legacy features
Write-Host "`nPurging Legacy Features..." -ForegroundColor Cyan

$LegRegex = "(?i)^(" + (($LegacyFeatureExclusions | ForEach-Object { [Regex]::Escape($_).Replace('\*', '.*') }) -join '|') + ")$"
foreach ($Feat in (Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object State -eq 'Enabled')) {
    if ($Feat.FeatureName -notmatch $LegRegex) {
        try { Disable-WindowsOptionalFeature -Online -FeatureName $Feat.FeatureName -NoRestart -WarningAction SilentlyContinue | Out-Null } catch {}
    }
}


# 8. remove ai & copilot packages (winsxs - owners bypass + cmdlet)
Write-Host "`nPurging AI & Copilot Packages..." -ForegroundColor Cyan

try {
    $PkgKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages", $true)
    if ($PkgKey) {
        foreach ($Sub in $PkgKey.GetSubKeyNames()) {
            if ($Sub -match "(?i)(Copilot|MachineLearning|Windows-AI-|Windows\.Copilot|ShellAI|Recall)") {
                $SubKey = $PkgKey.OpenSubKey($Sub, $true)
                if ($SubKey) {
                    $SubKey.SetValue("Visibility", 1, [Microsoft.Win32.RegistryValueKind]::DWord)
                    try { $SubKey.DeleteSubKeyTree("Owners", $false) } catch {}
                }
                try { Remove-WindowsPackage -Online -PackageName $Sub -NoRestart -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null } catch {}
            }
        }
    }
} catch {}


# finish - graceful explorer restart
Write-Host "`nRestarting Explorer..." -ForegroundColor Cyan
Stop-Process -Name Explorer -Force -ErrorAction SilentlyContinue
[System.Threading.Thread]::Sleep(2000)
[System.Diagnostics.Process]::Start("Explorer.exe") | Out-Null

Write-Host "`nDebloat completed successfully." -ForegroundColor Green
