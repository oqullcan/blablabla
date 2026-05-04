# ── edge ──────────────────────────────────────────────────
Write-Step 'removing microsoft edge'

function Get-EdgeSetupPaths {

    $paths = New-Object System.Collections.Generic.List[string]

    # canonical locations
    $roots = @(
        "$env:ProgramFiles (x86)\Microsoft\Edge\Application",
        "$env:ProgramFiles\Microsoft\Edge\Application"
    )

    foreach ($root in $roots) {
        if (Test-Path $root) {
            Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $setup = Join-Path $_.FullName 'Installer\setup.exe'
                if (Test-Path $setup) {
                    $paths.Add($setup) | Out-Null
                }
            }
        }
    }

    return $paths | Select-Object -Unique
}

function Invoke-EdgeSetupUninstall {
    param([string]$SetupPath)

    try {
        Write-Step "edge uninstall → $SetupPath"

        Start-Process -FilePath $SetupPath `
            -ArgumentList '--uninstall --system-level --force-uninstall --verbose-logging --delete-profile' `
            -Wait -NoNewWindow | Out-Null

    } catch {
        Write-Step "edge uninstall failed: $_" 'warn'
    }
}

function Remove-EdgeCore {

    $setups = Get-EdgeSetupPaths

    if (-not $setups -or $setups.Count -eq 0) {
        Write-Step 'edge setup.exe not found, skipping' 'warn'
        return
    }

    foreach ($s in $setups) {
        Invoke-EdgeSetupUninstall $s
    }
}

function Remove-WebView2 {

    $wvPaths = @(
        "$env:ProgramFiles (x86)\Microsoft\EdgeWebView\Application",
        "$env:ProgramFiles\Microsoft\EdgeWebView\Application"
    )

    foreach ($root in $wvPaths) {
        if (Test-Path $root) {
            Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $setup = Join-Path $_.FullName 'Installer\setup.exe'
                if (Test-Path $setup) {
                    try {
                        Write-Step "webview2 uninstall → $setup"
                        Start-Process $setup `
                            -ArgumentList '--uninstall --system-level --force-uninstall' `
                            -Wait -NoNewWindow | Out-Null
                    } catch {}
                }
            }
        }
    }
}

function Remove-EdgeUpdate {

    $updateExe = "$env:ProgramFiles (x86)\Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe"

    if (Test-Path $updateExe) {
        try {
            Write-Step 'removing edge update'
            Start-Process $updateExe -ArgumentList '/uninstall' -Wait -NoNewWindow | Out-Null
        } catch {}
    }

    # scheduled tasks purge
    Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskName -like '*EdgeUpdate*'
    } | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
}

function Remove-EdgeShortcuts {

    @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:Public\Desktop",
        "$env:UserProfile\Desktop"
    ) | ForEach-Object {

        $lnk = Join-Path $_ 'Microsoft Edge.lnk'
        if (Test-Path $lnk) {
            Remove-Item $lnk -Force -ErrorAction SilentlyContinue
        }
    }
}

function Block-EdgeReinstall {

    # policy kill switch
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate'
    New-Item $policy -Force | Out-Null

    Set-ItemProperty $policy 'InstallDefault' 0 -Type DWord
    Set-ItemProperty $policy 'DoNotUpdateToEdgeWithChromium' 1 -Type DWord
    Set-ItemProperty $policy 'UpdateDefault' 0 -Type DWord

    Write-Step 'edge reinstall blocked (policy)'
}

function Remove-Edge {

    Stop-Process -Name msedge -Force -ErrorAction SilentlyContinue
    Stop-Process -Name msedgewebview2 -Force -ErrorAction SilentlyContinue

    Remove-EdgeCore
    Remove-WebView2
    Remove-EdgeUpdate
    Remove-EdgeShortcuts
    Block-EdgeReinstall

    Write-Step 'edge removal complete'
}

Remove-Edge
