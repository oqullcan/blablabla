# ════════════════════════════════════════════════════════════
#  WINSXS · TELEMETRY & AI PURGE  (ReviOS-inspired, v2)
#  Requires: Run as Administrator / TrustedInstaller
# ════════════════════════════════════════════════════════════

#region ── helpers ────────────────────────────────────────────

function Write-Phase ([string]$msg) {
    Write-Host "`n[$msg]" -ForegroundColor Cyan
}
function Write-Step ([string]$msg, [string]$status = 'run') {
    $color = switch ($status) {
        'ok'   { 'Green'  }
        'warn' { 'Yellow' }
        'skip' { 'DarkGray' }
        'err'  { 'Red'    }
        default{ 'White'  }
    }
    Write-Host "  $status  $msg" -ForegroundColor $color
}
function Write-Done ([string]$msg) {
    Write-Host "`n[done] $msg`n" -ForegroundColor Cyan
}

# ── CBS registry: paketi kaldırmadan önce kurulu mu kontrol et ──
function Test-CbsPackageInstalled ([string]$packageName) {
    $cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
    try {
        $key = Get-ChildItem $cbsPath -ErrorAction Stop |
               Where-Object { $_.PSChildName -like "$packageName*" } |
               Select-Object -Last 1
        if (-not $key) { return $false }
        $state = (Get-ItemProperty $key.PSPath -Name CurrentState -EA SilentlyContinue).CurrentState
        $err   = (Get-ItemProperty $key.PSPath -Name LastError    -EA SilentlyContinue).LastError
        # CurrentState 5 = Absent, 4294967264 = Staged (uninstalled)
        return ($state -ne 5 -and $state -ne 4294967264 -and $null -eq $err)
    } catch { return $false }
}

# ── ACL kilitleme: ownership al, izni kes, dummy bırak ──────────
function Lock-SystemBinary ([string]$path) {
    if (-not (Test-Path $path)) { return }
    $leaf = Split-Path $path -Leaf
    try {
        # TrustedInstaller sahipliğini Administrators'a devret
        & takeown.exe /F $path /A 2>$null | Out-Null
        & icacls.exe  $path /inheritance:r /grant:r "Administrators:(F)" 2>$null | Out-Null

        # binary'yi yeniden adlandır
        $bak = "$path.bak"
        if (Test-Path $bak) { Remove-Item $bak -Force -EA SilentlyContinue }
        Rename-Item $path $bak -Force -ErrorAction Stop

        # dummy boş dosya bırak (servis crash'ini önler), sonra tamamen kilitle
        New-Item $path -ItemType File -Force | Out-Null
        & icacls.exe $path /inheritance:r `
            /deny "SYSTEM:(F)" `
            /deny "TrustedInstaller:(F)" `
            /deny "NT SERVICE\TrustedInstaller:(F)" 2>$null | Out-Null

        Write-Step "locked: $leaf" 'ok'
    } catch {
        Write-Step "skipped (locked by OS): $leaf" 'warn'
    }
}

# ── Servis durdur + devre dışı bırak (opsiyonel: sil) ──────────
function Disable-SystemService ([string]$name, [switch]$Delete) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    try {
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        Set-Service  -Name $name -StartupType Disabled -ErrorAction Stop
        if ($Delete) { & sc.exe delete $name 2>$null | Out-Null }
        Write-Step "service disabled: $name" 'ok'
    } catch {
        Write-Step "service skip: $name" 'warn'
    }
}

# ── PageVisibility ayarı: Settings sayfalarını gizle ───────────
function Set-PageVisibilityHide ([string[]]$pages) {
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    if (-not (Test-Path $regPath)) {
        New-Item $regPath -Force | Out-Null
    }
    $current = (Get-ItemProperty $regPath -Name SettingsPageVisibility -EA SilentlyContinue).SettingsPageVisibility
    $existing = if ($current) { $current -replace '^hide:', '' -split ';' | Where-Object { $_ } } else { @() }
    $merged = ($existing + $pages | Sort-Object -Unique) -join ';'
    Set-ItemProperty $regPath -Name SettingsPageVisibility -Value "hide:$merged" -Type String
    Write-Step "settings page hidden: $($pages -join ', ')" 'ok'
}

#endregion

# ════════════════════════════════════════════════════════════
Write-Phase 'telemetry & ai purge — v2'

# ════════════════════════════════════════════════════════════
#  BÖLÜM 1 · SERVİSLER — önce durdur, sonra binary kilitle
# ════════════════════════════════════════════════════════════
Write-Phase 'services — stop & disable'

$purgeServices = @(
    # telemetry / diagnostics
    @{ Name = 'DiagTrack';          Delete = $true  }   # Connected User Experiences & Telemetry
    @{ Name = 'dmwappushservice';   Delete = $true  }   # WAP Push
    @{ Name = 'WerSvc';             Delete = $false }   # Windows Error Reporting
    @{ Name = 'wercplsupport';      Delete = $false }
    @{ Name = 'WdiServiceHost';     Delete = $false }
    @{ Name = 'WdiSystemHost';      Delete = $false }
    @{ Name = 'diagnosticshub.standardcollector.service'; Delete = $true }
    # ai / copilot
    @{ Name = 'AIXService';         Delete = $true  }
    @{ Name = 'CopilotService';     Delete = $true  }
    # misc
    @{ Name = 'wisvc';              Delete = $true  }   # Windows Insider
    @{ Name = 'RetailDemo';         Delete = $true  }
    @{ Name = 'MapsBroker';         Delete = $false }
    @{ Name = 'lfsvc';             Delete = $false }   # Geolocation
    @{ Name = 'wlidsvc';            Delete = $false }   # Microsoft Account Sign-in
)

foreach ($s in $purgeServices) {
    Disable-SystemService -Name $s.Name -Delete:$s.Delete
}

# ════════════════════════════════════════════════════════════
#  BÖLÜM 2 · BINARY KİLİTLEME (ACL + dummy)
# ════════════════════════════════════════════════════════════
Write-Phase 'binary lock (acl + dummy file)'

$purgeBinaries = @(
    # telemetry
    "$env:SystemRoot\System32\CompatTelRunner.exe"
    "$env:SystemRoot\System32\DeviceCensus.exe"
    "$env:SystemRoot\System32\AggregatorHost.exe"
    "$env:SystemRoot\System32\wsqmcons.exe"
    "$env:SystemRoot\System32\WerFault.exe"
    "$env:SystemRoot\System32\WerFaultSecure.exe"
    "$env:SystemRoot\System32\wermgr.exe"
    "$env:SystemRoot\System32\omadmclient.exe"
    "$env:SystemRoot\System32\DiagSvcs\DiagnosticsHub.StandardCollector.Service.exe"
    "$env:SystemRoot\SysWOW64\CompatTelRunner.exe"
    "$env:SystemRoot\SysWOW64\DeviceCensus.exe"
    # copilot & ai
    "$env:SystemRoot\System32\Copilot.exe"
    "$env:SystemRoot\SysWOW64\Copilot.exe"
    "$env:SystemRoot\System32\WindowsCopilotRuntimeActions.exe"
    # smartscreen
    "$env:SystemRoot\System32\smartscreen.exe"
)

foreach ($bin in $purgeBinaries) {
    Lock-SystemBinary -path $bin
}

# ════════════════════════════════════════════════════════════
#  BÖLÜM 3 · AI / RECALL / COPILOT — AppX + Feature
# ════════════════════════════════════════════════════════════
Write-Phase 'ai & recall removal'

# Recall özelliğini kapat
Write-Step 'disabling Windows Recall feature' 'run'
$r = Start-Process powershell -ArgumentList '-Command', `
    'Disable-WindowsOptionalFeature -Online -FeatureName Recall -NoRestart' `
    -Wait -NoNewWindow -PassThru
if ($r.ExitCode -eq 0) { Write-Step 'Recall disabled' 'ok' }
else                   { Write-Step "Recall exit: $($r.ExitCode)" 'warn' }

# Copilot AppX kaldır (tüm kullanıcılar)
Write-Step 'removing Copilot AppX packages' 'run'
$copilotPkgs = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'Copilot|AIX|AIAssistant' }
foreach ($pkg in $copilotPkgs) {
    try {
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        Write-Step "appx removed: $($pkg.Name)" 'ok'
    } catch {
        Write-Step "appx skip: $($pkg.Name)" 'warn'
    }
}
if (-not $copilotPkgs) { Write-Step 'no Copilot AppX found' 'skip' }

# Settings sayfalarını gizle (PageVisibility)
Write-Step 'hiding AI settings pages' 'run'
Set-PageVisibilityHide -pages @('aicomponents', 'privacy-systemaimodels')

# ════════════════════════════════════════════════════════════
#  BÖLÜM 4 · DISM PACKAGE PURGE (CBS kontrolü ile)
# ════════════════════════════════════════════════════════════
Write-Phase 'dism package purge (cbs-verified)'

Write-Step 'querying installed dism packages' 'run'
$allPackages = dism /Online /Get-Packages 2>$null |
    Where-Object { $_ -match '^\s*Package Identity\s*:' } |
    ForEach-Object { ($_ -split ':\s*', 2)[1].Trim() }
Write-Step "total packages found: $($allPackages.Count)" 'ok'

$dismTargets = @(
    # telemetry / diagnostics
    'DiagTrack', 'Telemetry', 'CEIP', 'CEIPEnable', 'SQM',
    'UsbCeip', 'TelemetryClient', 'Unified-Telemetry', 'Update-Aggregators',
    'DataCollection', 'SetupPlatform-Telemetry', 'SettingsHandlers-SIUF',
    'SettingsHandlers-Flights', 'Application-Experience', 'Compat-Appraiser',
    'Compat-CompatTelRunner', 'Compat-GeneralTel', 'OneCoreUAP-Feedback',
    'Diagnostics-Telemetry', 'Diagnostics-TraceReporting', 'BuildFlighting',
    'Flighting', 'Feedback', 'FeedbackNotifications', 'StringFeedbackEngine',
    'ErrorReporting',
    # ai / copilot
    'Microsoft-Copilot', 'SettingsHandlers-Copilot',
    'UserExperience-AIX', 'UserExperience-CoreAI', 'AI-MachineLearning',
    # misc bloat
    'BingSearch', 'Windows-UNP', 'Cortana', 'AdvertisingId', 'RetailDemo',
    'OneDrive', 'QuickAssist', 'PeopleExperienceHost', 'OOBE-FirstLogonAnim',
    'Skype-ORTC', 'FlipGridPWA', 'OutlookPWA', 'PortableWorkspaces',
    'StepsRecorder', 'Holographic', 'Adobe-Flash', 'Bubbles', 'Mystify',
    'PhotoScreensaver', 'scrnsave', 'ssText3d', 'Shell-SoundThemes',
    'KeyboardDiagnostic', 'SecureAssessment', 'InputCloudStore',
    'Windows-Ribbons', 'PhotoBasic', 'shimgvw'
)

$removedCount = 0
$skippedCount = 0

foreach ($target in $dismTargets) {
    $matched = $allPackages | Where-Object { $_ -match $target }
    if (-not $matched) { continue }

    foreach ($pkg in $matched) {
        $shortName = $pkg.Split('~')[0].ToLower()

        # ── CBS kontrolü: zaten kaldırılmış mı? ──────────────
        $cbsInstalled = Test-CbsPackageInstalled -packageName ($pkg.Split('~')[0])
        if (-not $cbsInstalled) {
            Write-Step "already absent (cbs): $shortName" 'skip'
            $skippedCount++
            continue
        }

        Write-Step "removing: $shortName" 'run'
        $r = Start-Process dism `
            -ArgumentList "/Online /Remove-Package /PackageName:$pkg /NoRestart /Quiet" `
            -Wait -NoNewWindow -PassThru

        if ($r.ExitCode -eq 0) {
            Write-Step "removed: $shortName" 'ok'
            $removedCount++
        } else {
            Write-Step "skip (exit $($r.ExitCode)): $shortName" 'warn'
        }
    }
}

Write-Step "dism complete — removed: $removedCount  skipped(absent): $skippedCount" 'ok'

# ════════════════════════════════════════════════════════════
#  BÖLÜM 5 · WINSXS MANIFEST DEAKTIVE
# ════════════════════════════════════════════════════════════
Write-Phase 'winsxs manifest deactivation'

$manifestPatterns = @(
    '*diagtrack*', '*telemetry*', '*ceip*', '*diaghub*',
    '*wer*', '*compattelrunner*', '*devicecensus*',
    '*sqmclient*', '*aggregatorhost*',
    '*copilot*', '*cortana*', '*bingsearch*',
    '*retaildemo*', '*feedback*', '*flighting*', '*errorrepor*',
    '*recall*', '*aicomponent*', '*aix*'
)

$manifestDir    = "$env:SystemRoot\WinSxS\Manifests"
$manifestOkCnt  = 0
$manifestErrCnt = 0

foreach ($pattern in $manifestPatterns) {
    Get-ChildItem $manifestDir -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Rename-Item $_.FullName "$($_.FullName).bak" -Force -ErrorAction Stop
            $manifestOkCnt++
        } catch {
            $manifestErrCnt++
        }
    }
}

Write-Step "manifests renamed: $manifestOkCnt  locked/skipped: $manifestErrCnt" 'ok'

# ════════════════════════════════════════════════════════════
#  BÖLÜM 6 · DISM COMPONENT STORE CLEANUP
# ════════════════════════════════════════════════════════════
Write-Phase 'dism component store cleanup'

$dismCleanupArgs = @(
    '/Online /Cleanup-Image /StartComponentCleanup /ResetBase'
    '/Online /Cleanup-Image /SPSuperseded'
)

foreach ($arg in $dismCleanupArgs) {
    $label = ($arg -split '/')[-1].Trim()
    Write-Step "dism: $label" 'run'
    $r = Start-Process dism -ArgumentList $arg -Wait -NoNewWindow -PassThru
    if ($r.ExitCode -eq 0) { Write-Step "dism: $label" 'ok' }
    else                   { Write-Step "dism: $label exit $($r.ExitCode)" 'warn' }
}

# ════════════════════════════════════════════════════════════
Write-Done 'telemetry & ai purge — v2 complete'
# ════════════════════════════════════════════════════════════
