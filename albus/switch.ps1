# =============================================================================================================================================================================
# albusx switcher — fetch .cs files from repo, select one, compile & swap the service
# =============================================================================================================================================================================

$ErrorActionPreference = 'Stop'
Clear-Host

function status ($msg, $type = "info") {
    $p, $c = switch ($type) {
        "info" { "info", "Cyan"    }
        "done" { "done", "Green"   }
        "warn" { "warn", "Yellow"  }
        "fail" { "fail", "Red"     }
        "step" { "step", "Magenta" }
        "ask"  { "ask ", "Yellow"  }
        default { "albus", "Gray"  }
    }
    Write-Host "$p - " -NoNewline -ForegroundColor $c
    Write-Host $msg.ToLower()
}

# ── config ────────────────────────────────────────────────────────────────────

$ServiceName = "AlbusXSvc"
$InstallPath = "C:\Albus"
$ExePath     = "$InstallPath\AlbusX.exe"
$CSC         = "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$RepoApi     = "https://api.github.com/repos/oqullcan/albuswin/contents/albus"
$RepoRaw     = "https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/albus"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── fetch available .cs files from repo ───────────────────────────────────────

status "fetching available versions from repo..." "step"

try {
    $Files = Invoke-RestMethod -Uri $RepoApi -UseBasicParsing -ErrorAction Stop |
             Where-Object { $_.name -match "\.cs$" }
} catch {
    status "failed to reach repo: $($_.Exception.Message)" "fail"
    Pause; Exit
}

if (-not $Files -or $Files.Count -eq 0) {
    status "no .cs files found in albus/ directory." "fail"
    Pause; Exit
}

# ── display menu ─────────────────────────────────────────────────────────────

Write-Host ""
status "available versions:" "info"
Write-Host ""

$i = 0
foreach ($f in $Files) {
    $i++
    Write-Host "  $i. " -NoNewline -ForegroundColor Magenta
    Write-Host $f.name
}

Write-Host ""
Write-Host "ask  - " -NoNewline -ForegroundColor Yellow
$choice = Read-Host "select version (1-$i)"

if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $i) {
    status "invalid selection. aborting." "fail"
    Pause; Exit
}

$Selected = $Files[[int]$choice - 1]
status "selected: $($Selected.name)" "info"

# ── stop & remove existing service ───────────────────────────────────────────

Write-Host ""
status "stopping and removing existing albusx service..." "step"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq 'Running') {
        try {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            status "service stopped." "done"
        } catch {
            status "could not stop service gracefully, forcing..." "warn"
            & sc.exe stop $ServiceName | Out-Null
            Start-Sleep -Seconds 2
        }
    }
    try {
        & sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 1
        status "service deleted." "done"
    } catch {
        status "failed to delete service: $($_.Exception.Message)" "fail"
        Pause; Exit
    }
} else {
    status "no existing service found. continuing." "info"
}

# remove old binary
if (Test-Path $ExePath) {
    try {
        Remove-Item $ExePath -Force -ErrorAction Stop
        status "old binary removed." "done"
    } catch {
        status "could not remove old binary — it may be locked." "fail"
        Pause; Exit
    }
}

# ── download selected .cs file ────────────────────────────────────────────────

Write-Host ""
status "downloading $($Selected.name)..." "step"

if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

$CSPath = "$InstallPath\AlbusX.cs"
try {
    Invoke-WebRequest -Uri "$RepoRaw/$($Selected.name)" -OutFile $CSPath -UseBasicParsing -ErrorAction Stop
    status "downloaded successfully." "done"
} catch {
    status "download failed: $($_.Exception.Message)" "fail"
    Pause; Exit
}

# ── compile ───────────────────────────────────────────────────────────────────

Write-Host ""
status "compiling $($Selected.name)..." "step"

if (-not (Test-Path $CSC)) {
    status "csc.exe not found at $CSC" "fail"
    Pause; Exit
}

$CompileArgs = @(
    "-r:System.ServiceProcess.dll",
    "-r:System.Configuration.Install.dll",
    "-r:System.Management.dll",
    "-r:System.dll",
    "-out:`"$ExePath`"",
    "`"$CSPath`""
)

try {
    $result = & $CSC @CompileArgs 2>&1
    if (-not (Test-Path $ExePath)) {
        status "compilation failed." "fail"
        Write-Host ""
        $result | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        Pause; Exit
    }
    status "compiled successfully." "done"
} catch {
    status "compiler error: $($_.Exception.Message)" "fail"
    Pause; Exit
}

# clean up source
Remove-Item $CSPath -Force -ErrorAction SilentlyContinue

# ── install & start service ───────────────────────────────────────────────────

Write-Host ""
status "installing albusx service..." "step"

try {
    New-Service `
        -Name $ServiceName `
        -BinaryPathName $ExePath `
        -DisplayName "AlbusX" `
        -Description "albus core engine — $($Selected.name)" `
        -StartupType Automatic `
        -ErrorAction Stop | Out-Null

    & sc.exe failure $ServiceName reset= 60 actions= restart/5000/restart/10000/restart/30000 | Out-Null

    status "service installed." "done"
} catch {
    status "failed to install service: $($_.Exception.Message)" "fail"
    Pause; Exit
}

status "starting service..." "step"

try {
    Start-Service -Name $ServiceName -ErrorAction Stop
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name $ServiceName
    if ($svc.Status -eq 'Running') {
        status "albusx is running. ($($Selected.name))" "done"
    } else {
        status "service started but status is: $($svc.Status)" "warn"
    }
} catch {
    status "failed to start service: $($_.Exception.Message)" "fail"
    Pause; Exit
}

# ── summary ──────────────────────────────────────────────────────────────────

Write-Host ""
status "active version : $($Selected.name)" "done"
status "binary         : $ExePath" "done"
status "log            : C:\Albus\albusx.log" "done"
Write-Host ""
Pause
# =============================================================================================================================================================================
