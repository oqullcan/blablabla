# ════════════════════════════════════════════════════════════
#  WINSXS · TELEMETRY & AI PURGE  (ReviOS-inspired, v3)
#  Context: TrustedInstaller
# ════════════════════════════════════════════════════════════

#region ── helpers ────────────────────────────────────────────

function Write-Phase ([string]$msg) {
    Write-Host "`n[$msg]" -ForegroundColor Cyan
}
function Write-Step ([string]$msg, [string]$status = 'run') {
    $color = switch ($status) {
        'ok'   { 'Green'    }
        'warn' { 'Yellow'   }
        'skip' { 'DarkGray' }
        'err'  { 'Red'      }
        default{ 'White'    }
    }
    Write-Host "  $status  $msg" -ForegroundColor $color
}
function Write-Done ([string]$msg) {
    Write-Host "`n[done] $msg`n" -ForegroundColor Cyan
}

# ── CBS registry: paket kurulu mu? ──────────────────────────
function Test-CbsPackageInstalled ([string]$packageName) {
    $cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
    try {
        $key = Get-ChildItem $cbsPath -ErrorAction Stop |
               Where-Object { $_.PSChildName -like "$packageName*" } |
               Select-Object -Last 1
        if (-not $key) { return $false }
        $state = (Get-ItemProperty $key.PSPath -Name CurrentState -EA SilentlyContinue).CurrentState
        $err   = (Get-ItemProperty $key.PSPath -Name LastError    -EA SilentlyContinue).LastError
        # 5 = Absent, 4294967264 = Staged
        return ($state -ne 5 -and $state -ne 4294967264 -and $null -eq $err)
    } catch { return $false }
}

# ── Binary nötralize: rename + dummy ────────────────────────
function Lock-SystemBinary ([string]$path) {
    if (-not (Test-Path $path)) { return }
    $leaf = Split-Path $path -Leaf
    try {
        $bak = "$path.bak"
        if (Test-Path $bak) { Remove-Item $bak -Force -EA SilentlyContinue }
        Rename-Item $path $bak -Force -ErrorAction Stop
        New-Item $path -ItemType File -Force | Out-Null
        & icacls.exe $path /inheritance:r /deny "Everyone:(W,M,D,DC)" /deny "SYSTEM:(W,M,D,DC)" 2>$null | Out-Null
        Write-Step "locked: $leaf" 'ok'
    } catch {
        Write-Step "skipped (in use): $leaf" 'warn'
    }
}

# ── Servis durdur + disable ──────────────────────────────────
function Disable-SystemService ([string]$name, [switch]$Delete) {
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    try {
        Stop-Service -Name $name -Force -EA SilentlyContinue
        Set-Service  -Name $name -StartupType Disabled -ErrorAction Stop
        if ($Delete) { & sc.exe delete $name 2>$null | Out-Null }
        Write-Step "service disabled: $name" 'ok'
    } catch {
        Write-Step "service skip: $name" 'warn'
    }
}

# ── PageVisibility: Settings sayfalarını gizle ──────────────
function Set-PageVisibilityHide ([string[]]$pages) {
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    if (-not (Test-Path $regPath)) { New-Item $regPath -Force | Out-Null }
    $current  = (Get-ItemProperty $regPath -Name SettingsPageVisibility -EA SilentlyContinue).SettingsPageVisibility
    $existing = if ($current) { $current -replace '^hide:', '' -split ';' | Where-Object { $_ } } else { @() }
    $merged   = ($existing + $pages | Sort-Object -Unique) -join ';'
    Set-ItemProperty $regPath -Name SettingsPageVisibility -Value "hide:$merged" -Type String
    Write-Step "settings hidden: $($pages -join ', ')" 'ok'
}

# ── Optional Feature: durum kontrol + disable ───────────────
# FIX v3: null-safe parse, dism.exe direkt çağrı
function Remove-OptionalFeature ([string]$featureName, [string]$label) {
    $featLines = & dism.exe /Online /Get-FeatureInfo /FeatureName:$featureName 2>$null
    $stateLine = $featLines | Where-Object { $_ -match '^\s*State\s*:' } | Select-Object -First 1
    $state     = if ($stateLine) { ($stateLine -split ':\s*', 2)[1].Trim() } else { $null }

    if (-not $state) {
        Write-Step "not present: $label" 'skip'
        return
    }
    if ($state -eq 'Disabled' -or $state -eq 'DisabledWithPayloadRemoved') {
        Write-Step "already disabled: $label" 'skip'
        return
    }

    Write-Step "disabling [$state]: $label" 'run'

    # Yöntem 1 — PowerShell
    $r1 = Start-Process powershell.exe `
        -ArgumentList "-NonInteractive -Command `"Disable-WindowsOptionalFeature -Online -FeatureName '$featureName' -NoRestart -Remove`"" `
        -Wait -NoNewWindow -PassThru
    if ($r1.ExitCode -eq 0 -or $r1.ExitCode -eq 3010) {
        Write-Step "disabled (ps): $label" 'ok'; return
    }

    # Yöntem 2 — DISM fallback
    $r2 = Start-Process dism.exe `
        -ArgumentList "/Online /Disable-Feature /FeatureName:$featureName /NoRestart /Remove" `
        -Wait -NoNewWindow -PassThru
    if ($r2.ExitCode -eq 0 -or $r2.ExitCode -eq 3010) {
        Write-Step "disabled (dism): $label" 'ok'
    } else {
        Write-Step "failed (exit $($r2.ExitCode)): $label" 'warn'
    }
}

# ── DISM Remove-Package (CBS doğrulamalı, script scope) ─────
function Remove-WinSxSPackages ([string[]]$patterns, [ref]$removed, [ref]$skipped) {
    foreach ($pattern in $patterns) {
        $matched = $script:allPackages | Where-Object { $_ -match [regex]::Escape($pattern) }
        foreach ($pkg in $matched) {
            $shortName = $pkg.Split('~')[0].ToLower()
            $cbsOk = Test-CbsPackageInstalled -packageName ($pkg.Split('~')[0])
            if (-not $cbsOk) {
                Write-Step "already absent: $shortName" 'skip'
                $skipped.Value++
                continue
            }
            Write-Step "removing: $shortName" 'run'
            $r = Start-Process dism.exe `
                -ArgumentList "/Online /Remove-Package /PackageName:$pkg /NoRestart /Quiet" `
                -Wait -NoNewWindow -PassThru
            if ($r.ExitCode -eq 0) {
                Write-Step "removed: $shortName" 'ok'; $removed.Value++
            } else {
                Write-Step "skip (exit $($r.ExitCode)): $shortName" 'warn'
            }
        }
    }
}

#endregion

# ════════════════════════════════════════════════════════════
Write-Phase 'telemetry & ai purge — v3'

# ════════════════════════════════════════════════════════════
#  BÖLÜM 1 · SERVİSLER
# ════════════════════════════════════════════════════════════
Write-Phase 'services — stop & disable'

$purgeServices = @(
    @{ Name = 'DiagTrack';                                 Delete = $true  }
    @{ Name = 'dmwappushservice';                          Delete = $true  }
    @{ Name = 'WerSvc';                                    Delete = $false }
    @{ Name = 'wercplsupport';                             Delete = $false }
    @{ Name = 'WdiServiceHost';                            Delete = $false }
    @{ Name = 'WdiSystemHost';                             Delete = $false }
    @{ Name = 'diagnosticshub.standardcollector.service';  Delete = $true  }
    @{ Name = 'AIXService';                                Delete = $true  }
    @{ Name = 'CopilotService';                            Delete = $true  }
    @{ Name = 'wisvc';                                     Delete = $true  }
    @{ Name = 'RetailDemo';                                Delete = $true  }
    @{ Name = 'MapsBroker';                                Delete = $false }
    @{ Name = 'lfsvc';                                     Delete = $false }
    @{ Name = 'wlidsvc';                                   Delete = $false }
)
foreach ($s in $purgeServices) {
    Disable-SystemService -Name $s.Name -Delete:$s.Delete
}

# ════════════════════════════════════════════════════════════
#  BÖLÜM 2 · BINARY KİLİTLEME
# ════════════════════════════════════════════════════════════
Write-Phase 'binary lock (rename + dummy)'

$purgeBinaries = @(
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
    "$env:SystemRoot\System32\Copilot.exe"
    "$env:SystemRoot\SysWOW64\Copilot.exe"
    "$env:SystemRoot\System32\WindowsCopilotRuntimeActions.exe"
    "$env:SystemRoot\System32\smartscreen.exe"
)
foreach ($bin in $purgeBinaries) { Lock-SystemBinary -path $bin }

# ════════════════════════════════════════════════════════════
#  BÖLÜM 3 · AI / RECALL / COPILOT
# ════════════════════════════════════════════════════════════
Write-Phase 'ai & recall removal'

# Recall — 24H2'de iki farklı feature adı olabiliyor
Write-Step 'disabling Recall' 'run'
Remove-OptionalFeature 'Recall'        'Windows Recall'
Remove-OptionalFeature 'WindowsRecall' 'Windows Recall (alt)'

# Copilot AppX — geniş pattern
Write-Step 'removing AI/Copilot AppX' 'run'
$aiPkgs = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match 'Copilot|AIX|AIAssistant|WindowsAI' }
foreach ($pkg in $aiPkgs) {
    try {
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        Write-Step "appx removed: $($pkg.Name)" 'ok'
    } catch {
        Write-Step "appx skip: $($pkg.Name)" 'warn'
    }
}
if (-not $aiPkgs) { Write-Step 'no AI/Copilot AppX found' 'skip' }

Write-Step 'hiding AI settings pages' 'run'
Set-PageVisibilityHide -pages @('aicomponents', 'privacy-systemaimodels')

# ════════════════════════════════════════════════════════════
#  BÖLÜM 4 · DISM PACKAGE PURGE (CBS doğrulamalı)
# ════════════════════════════════════════════════════════════
Write-Phase 'dism package purge (cbs-verified)'

Write-Step 'querying installed dism packages' 'run'
$script:allPackages = & dism.exe /Online /Get-Packages 2>$null |
    Where-Object { $_ -match '^\s*Package Identity\s*:' } |
    ForEach-Object { ($_ -split ':\s*', 2)[1].Trim() }
Write-Step "total packages found: $($script:allPackages.Count)" 'ok'

$dismTargets = @(
    'DiagTrack','Telemetry','CEIP','CEIPEnable','SQM',
    'UsbCeip','TelemetryClient','Unified-Telemetry','Update-Aggregators',
    'DataCollection','SetupPlatform-Telemetry','SettingsHandlers-SIUF',
    'SettingsHandlers-Flights','Application-Experience','Compat-Appraiser',
    'Compat-CompatTelRunner','Compat-GeneralTel','OneCoreUAP-Feedback',
    'Diagnostics-Telemetry','Diagnostics-TraceReporting','BuildFlighting',
    'Flighting','Feedback','FeedbackNotifications','StringFeedbackEngine',
    'ErrorReporting','Microsoft-Copilot','SettingsHandlers-Copilot',
    'UserExperience-AIX','UserExperience-CoreAI','AI-MachineLearning',
    'BingSearch','Windows-UNP','Cortana','AdvertisingId','RetailDemo',
    'OneDrive','QuickAssist','PeopleExperienceHost','OOBE-FirstLogonAnim',
    'Skype-ORTC','FlipGridPWA','OutlookPWA','PortableWorkspaces',
    'StepsRecorder','Holographic','Adobe-Flash','Bubbles','Mystify',
    'PhotoScreensaver','scrnsave','ssText3d','Shell-SoundThemes',
    'KeyboardDiagnostic','SecureAssessment','InputCloudStore',
    'Windows-Ribbons','PhotoBasic','shimgvw'
)

$dismR = 0; $dismS = 0
Remove-WinSxSPackages -patterns $dismTargets -removed ([ref]$dismR) -skipped ([ref]$dismS)
if ($dismR -eq 0 -and $dismS -eq 0) {
    Write-Step 'no matching packages found' 'skip'
} else {
    Write-Step "dism complete — removed: $dismR  skipped: $dismS" 'ok'
}

# ════════════════════════════════════════════════════════════
#  BÖLÜM 5 · WINSXS MANIFEST DEAKTIVE
# ════════════════════════════════════════════════════════════
Write-Phase 'winsxs manifest deactivation'

$manifestPatterns = @(
    '*diagtrack*','*telemetry*','*ceip*','*diaghub*',
    '*wer*','*compattelrunner*','*devicecensus*',
    '*sqmclient*','*aggregatorhost*',
    '*copilot*','*cortana*','*bingsearch*',
    '*retaildemo*','*feedback*','*flighting*','*errorrepor*',
    '*recall*','*aicomponent*','*aix*'
)

$manifestDir = "$env:SystemRoot\WinSxS\Manifests"
$mOk = 0; $mErr = 0

foreach ($pattern in $manifestPatterns) {
    Get-ChildItem $manifestDir -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        $bakPath = "$($_.FullName).bak"
        if (Test-Path $bakPath) { return }   # zaten .bak varsa atla
        try {
            Rename-Item $_.FullName $bakPath -Force -ErrorAction Stop
            $mOk++
        } catch {
            $mErr++
            Write-Step "manifest locked: $($_.Name)" 'warn'
        }
    }
}
Write-Step "manifests renamed: $mOk  locked: $mErr" 'ok'

# ════════════════════════════════════════════════════════════
#  BÖLÜM 6 · LEGACY COMPONENT KALDIRMA
#  Win 11 24H2: IE, Fax, WMP artık Optional Features
# ════════════════════════════════════════════════════════════
Write-Phase 'legacy component removal (ie / fax-xps / wmp)'

# ── Internet Explorer ────────────────────────────────────────
Write-Step '--- internet explorer ---' 'run'
Remove-OptionalFeature 'Internet-Explorer-Optional-amd64' 'Internet Explorer x64'
Remove-OptionalFeature 'Internet-Explorer-Optional-x86'   'Internet Explorer x86'

$ieR = 0; $ieS = 0
Remove-WinSxSPackages -patterns @(
    'Microsoft-Windows-InternetExplorer'
    'Microsoft-Windows-IE-InternetExplorer'
    'Microsoft-Windows-IEOptional'
    'Microsoft-Windows-IEToEdge'
    'Microsoft-Windows-MSHTML'
    'Microsoft-Windows-jscript9'
    'Microsoft-Windows-vbscript'
    'Microsoft-Windows-MSHTMLDirectInvoke'
    'Microsoft-Windows-TridentAPICompat'
) -removed ([ref]$ieR) -skipped ([ref]$ieS)

# ── Fax · XPS · Print to PDF ────────────────────────────────
Write-Step '--- fax / xps / print to pdf ---' 'run'
Remove-OptionalFeature 'FaxServicesClientPackage'                       'Fax Services'
Remove-OptionalFeature 'Printing-XPS-Services-Driver'                   'XPS Driver'
Remove-OptionalFeature 'Microsoft-Windows-Printing-XPSServices-Package' 'XPS Services'

$faxR = 0; $faxS = 0
Remove-WinSxSPackages -patterns @(
    'Microsoft-Windows-FaxServicesClientPackage'
    'Microsoft-Windows-Fax-'
    'Microsoft-Windows-WFS'
    'Microsoft-Windows-XPS'
    'Microsoft-Windows-XPSViewer'
    'Microsoft-Windows-PrintToPDF'
    'Microsoft-Windows-Printing-XPSServices'
    'Microsoft-Windows-Printing-PMClient'
    'Microsoft-Windows-ScanManagement'
) -removed ([ref]$faxR) -skipped ([ref]$faxS)

# ── Windows Media Player ─────────────────────────────────────
Write-Step '--- windows media player ---' 'run'
Remove-OptionalFeature 'WindowsMediaPlayer' 'Windows Media Player'
Remove-OptionalFeature 'MediaPlayback'      'Media Playback Core'

$wmpR = 0; $wmpS = 0
Remove-WinSxSPackages -patterns @(
    'Microsoft-Windows-MediaPlayer-Package'
    'Microsoft-Windows-WMP'
    'Microsoft-Windows-WindowsMediaPlayer'
    'Microsoft-Windows-WMDRMDeviceApp'
    'Microsoft-Windows-WMSNSink'
) -removed ([ref]$wmpR) -skipped ([ref]$wmpS)

Write-Step "legacy done — ie:$ieR / fax:$faxR / wmp:$wmpR removed" 'ok'

# ════════════════════════════════════════════════════════════
#  BÖLÜM 7 · DISM COMPONENT STORE CLEANUP
# ════════════════════════════════════════════════════════════
Write-Phase 'dism component store cleanup'

Write-Step 'dism: StartComponentCleanup /ResetBase' 'run'
$r = Start-Process dism.exe -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup /ResetBase' -Wait -NoNewWindow -PassThru
if ($r.ExitCode -eq 0) { Write-Step 'dism: ResetBase ok' 'ok' }
else                   { Write-Step "dism: ResetBase exit $($r.ExitCode)" 'warn' }

# SPSuperseded yoksa zaten 0 döner, warn değil skip
Write-Step 'dism: SPSuperseded' 'run'
$r = Start-Process dism.exe -ArgumentList '/Online /Cleanup-Image /SPSuperseded' -Wait -NoNewWindow -PassThru
if ($r.ExitCode -eq 0) { Write-Step 'dism: SPSuperseded ok' 'ok' }
else                   { Write-Step 'dism: SPSuperseded — no SP backup (normal)' 'skip' }

# ════════════════════════════════════════════════════════════
Write-Done 'telemetry & ai purge — v3 complete'
# ════════════════════════════════════════════════════════════
