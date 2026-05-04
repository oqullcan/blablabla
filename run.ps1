# =============================================================================================================
# albus bootstrap — hardened edition
# =============================================================================================================

$ErrorActionPreference = 'Stop'
Clear-Host

# ─── admin elevation ─────────────────────────────────────────────────────────
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"" -Verb RunAs
    exit
}

# ─── env setup ──────────────────────────────────────────────────────────────
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$InstallPath = "C:\Albus"
$MinSudoPath = "$InstallPath\MinSudo.exe"
$TempDir     = "$InstallPath\tmp"
$ZipPath     = "$TempDir\nana.zip"
$RepoURL     = "https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/albus.ps1"

# ─── ui ─────────────────────────────────────────────────────────────────────
function Status ($Msg, $Type = "info") {
    $colors = @{
        info="Cyan"; done="Green"; warn="Yellow"; fail="Red"; step="Magenta"
    }
    $c = $colors[$Type]; if (-not $c) { $c = "Gray" }
    Write-Host "$Type - " -NoNewline -ForegroundColor $c
    Write-Host $Msg.ToLower()
}

# ─── directory prep ─────────────────────────────────────────────────────────
New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# ─── defender exclusion (early) ─────────────────────────────────────────────
try {
    Add-MpPreference -ExclusionPath $InstallPath -ErrorAction Stop
    Status "defender exclusion applied." "done"
} catch {
    Status "defender exclusion skipped." "warn"
}

# =============================================================================================================
# .NET OPTIMIZATION (DIRECT - NO SCHEDULED TASKS)
# =============================================================================================================

Status "optimizing .net runtimes..." "info"

try {
    $ngen = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()

    if (Test-Path "$ngen\ngen.exe") {
        Push-Location $ngen

        .\ngen.exe executeQueuedItems /nologo | Out-Null
        .\ngen.exe update /nologo | Out-Null

        Pop-Location
        Status ".net ngen execution completed." "done"
    } else {
        Status "ngen not found, skipping." "warn"
    }
}
catch {
    Status ".net optimization failed." "warn"
}

# =============================================================================================================
# MINSUDO INSTALL (CONTROLLED + RETRY)
# =============================================================================================================

if (-not (Test-Path $MinSudoPath)) {

    Status "resolving minsudo release..." "warn"

    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/M2Team/NanaRun/releases"
        $asset = $release[0].assets | Where-Object { $_.name -match "\.zip$" } | Select-Object -First 1

        if (-not $asset) { throw "release asset not found" }

        Status "downloading $($asset.name)..." "info"
        Invoke-WebRequest $asset.browser_download_url -OutFile $ZipPath

        Status "extracting archive..." "info"
        Expand-Archive $ZipPath -DestinationPath $TempDir -Force

        $exe = Get-ChildItem $TempDir -Recurse -Filter "MinSudo.exe" |
               Where-Object FullName -match "x64" |
               Select-Object -First 1

        if (-not $exe) {
            $exe = Get-ChildItem $TempDir -Recurse -Filter "MinSudo.exe" | Select-Object -First 1
        }

        if (-not $exe) { throw "minsudo binary not found" }

        # ─── retry move (defender race condition fix)
        $success = $false
        for ($i=0; $i -lt 6; $i++) {
            if (Test-Path $exe.FullName) {
                try {
                    Move-Item $exe.FullName $MinSudoPath -Force
                    $success = $true
                    break
                } catch {
                    Start-Sleep -Milliseconds 400
                }
            } else {
                Start-Sleep -Milliseconds 400
            }
        }

        if (-not $success) {
            throw "failed to move minsudo (blocked or removed)"
        }

        Status "minsudo installed." "done"
    }
    catch {
        Status "minsduo install failed: $($_.Exception.Message)" "fail"
        exit
    }
    finally {
        Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================================================
# EXECUTION (TRUSTEDINSTALLER HANDOFF)
# =============================================================================================================

Status "loading remote engine..." "info"
Status "handoff -> trustedinstaller" "step"

try {
    $cmd = "iex (Invoke-RestMethod '$RepoURL')"

    & $MinSudoPath `
        -NoL `
        -TI `
        -P powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -Command $cmd
}
catch {
    Status "trustedinstaller execution failed." "fail"
}

exit

# =============================================================================================================
