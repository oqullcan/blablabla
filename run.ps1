# =============================================================================================================================================================================

$ErrorActionPreference = 'Stop'
Clear-Host

# admin privilege audit
$Principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"" -Verb RunAs
    Exit
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Privilege = $Identity.Split('\')[-1].ToLower()
[Console]::Title = "albus - $Privilege"

# path configuration
$Env:InstallPath = "C:\Albus"
$MinSudoPath = "$Env:InstallPath\MinSudo.exe"
$RepoURL = "https://raw.githubusercontent.com/oqullcan/blablabla/refs/heads/main/albus.ps1"

# albus status engine (unified)
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
    Write-Host $Msg.ToLower()
}

# environment setup
if (-not (Test-Path $Env:InstallPath)) { $null = New-Item -Path $Env:InstallPath -ItemType Directory -Force }

try {
    Add-MpPreference -ExclusionPath $Env:InstallPath -ErrorAction SilentlyContinue
} catch {
    Status "could not add defender exclusion. continuing anyway..." "warn"
}

# .net framework optimization (ngen)
Status "optimizing .net framework runtimes (ngen engine)..." "info"
$dotNetTasks = Get-ScheduledTask -TaskPath "\Microsoft\Windows\.NET Framework\" -ErrorAction SilentlyContinue
if ($dotNetTasks) {
    foreach ($T in $dotNetTasks) {
        if ($T.State -eq 'Disabled') { Enable-ScheduledTask -InputObject $T | Out-Null }
        Start-ScheduledTask -InputObject $T | Out-Null
    }
}

$ngenPath = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
if (Test-Path "$ngenPath\ngen.exe") {
    Set-Location $ngenPath
    & ".\ngen.exe" executeQueuedItems /nologo | Out-Null
    & ".\ngen.exe" update /nologo | Out-Null
}

$StalePaths = @(
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\Temporary ASP.NET Files",
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\Temporary ASP.NET Files"
)
foreach ($P in $StalePaths) { if (Test-Path $P) { Remove-Item $P -Recurse -Force -ErrorAction SilentlyContinue } }
Status "net optimization cycle finished successfully." "done"


# minsudo integration
if (-not (Test-Path $MinSudoPath)) {
    Status "minsudo not found. resolving latest binary..." "warn"
    try {
        $Ref = Invoke-RestMethod -Uri "https://api.github.com/repos/M2Team/NanaRun/releases" -UseBasicParsing
        $Asset = $Ref[0].assets | Where-Object Name -Match "\.zip$" | Select-Object -First 1
        
        if (-not $Asset) { throw "no valid minsudo archive found." }

        Status "downloading $($Asset.name)..." "info"
        $TempZip = "$env:TEMP\nana.zip"
        Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $TempZip -UseBasicParsing
        
        Status "extracting and integrating minsudo payload..." "info"
        $TempDir = "$env:TEMP\nana_extract"
        Expand-Archive -Path $TempZip -DestinationPath $TempDir -Force

        $Exe = Get-ChildItem -Path $TempDir -Filter "MinSudo.exe" -Recurse | Where-Object FullName -Match "x64" | Select-Object -First 1
        if (-not $Exe) { $Exe = Get-ChildItem -Path $TempDir -Filter "MinSudo.exe" -Recurse | Select-Object -First 1 }
        
        Move-Item -Path $Exe.FullName -Destination $MinSudoPath -Force
        Remove-Item -Path $TempZip, $TempDir -Recurse -Force
        Status "minsudo integrated successfully." "done"
    } catch {
        Status "minsudo installation failed: $($_.Exception.Message)" "fail"
        Pause; Exit
    }
}

# trustedinstaller handoff
Status "streaming latest engine from remote to memory..." "info"
Status "handoff to trustedinstaller engine..." "step"
try {
    $AlbusCmd = "iex (Invoke-RestMethod -Uri '$RepoURL' -UseBasicParsing)"
    & $MinSudoPath -NoL -TI -P powershell.exe -NoProfile -NoLogo -NoExit -ExecutionPolicy Bypass -Command "$AlbusCmd"
} catch {
    Status "critical error: trustedinstaller elevation failed." "fail"
    Pause
}

Exit
# =============================================================================================================================================================================
