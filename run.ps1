# =============================================================================================================================================================================

$ErrorActionPreference = 'Stop'

$Principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"" -Verb RunAs
    Exit
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Privilege = $Identity.Split('\')[-1]
[Console]::Title = "Albus - $Privilege"

$Env:InstallPath = "C:\Albus"
$Paths = @{
	TempZip = "$Env:InstallPath\NanaRun.zip"
    TempDirection = "$Env:InstallPath\NanaRun"
    MinSudo = "$Env:InstallPath\MinSudo.exe"
    Script  = "$Env:InstallPath\Albus-win.ps1"
}

$RepoURL = "https://raw.githubusercontent.com/oqullcan/blablabla/refs/heads/main/albus.ps1"

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

if (-not (Test-Path $Env:InstallPath)) { $null = New-Item -Path $Env:InstallPath -ItemType Directory -Force }

try {
    Add-MpPreference -ExclusionPath $Env:InstallPath -ErrorAction Stop
} catch {
    Status "could not add defender exclusion. continuing anyway..." "warn"
}

if (-not (Test-Path $Paths.MinSudo)) {
    Status "minsudo not found. resolving latest binary..." "warn"
    try {
        $Ref = Invoke-RestMethod -Uri "https://api.github.com/repos/M2Team/NanaRun/releases" -UseBasicParsing
        $Asset = $Ref[0].assets | Where-Object Name -Match "\.zip$" | Select-Object -First 1
        
        if (-not $Asset) { throw "no valid archive found." }

        Status "downloading $($Asset.name)..." "info"
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $Paths.TempZip -UseBasicParsing
        
        Status "extracting and integrating..." "info"
        Expand-Archive -Path $Paths.TempZip -DestinationPath $Paths.TempDirection -Force

        $Exe = Get-ChildItem -Path $Paths.TempDirection -Filter "MinSudo.exe" -Recurse | Where-Object FullName -Match "x64" | Select-Object -First 1
        if (-not $Exe) { $Exe = Get-ChildItem -Path $Paths.TempDirection -Filter "MinSudo.exe" -Recurse | Select-Object -First 1 }
        if (-not $Exe) { throw "minsudo.exe missing." }

        Move-Item -Path $Exe.FullName -Destination $Paths.MinSudo -Force
        Remove-Item -Path $Paths.TempZip, $Paths.TempDirection -Recurse -Force

        Status "minsudo integrated successfully." "done"
    } catch {
        Status "installation failed: $($_.Exception.Message)" "fail"
        Pause; Exit
    }
}

Status "fetching remote engine..." "info"
try {
    Invoke-WebRequest -Uri $RepoURL -OutFile $Paths.Script -UseBasicParsing
    Status "remote engine synchronized." "done"
} catch {
    Status "synchronization failed." "fail"
    Pause; Exit
}

Status "handoff to trustedinstaller engine..." "step"
try {
    & $Paths.MinSudo -NoL -TI -P powershell.exe -NoProfile -NoLogo -NoExit -ExecutionPolicy Bypass -File $Paths.Script
} catch {
    Status "critical error: elevation failed." "fail"
    Pause
}

Exit

# =============================================================================================================================================================================
