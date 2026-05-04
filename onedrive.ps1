# ════════════════════════════════════════════════════════════
#  PHASE 11 · DEBLOAT
#  UWP removal, Edge, WebView2, EdgeUpdate, OneDrive,
#  Copilot (appx + registry + policies + CBS + files),
#  Windows Backup, telemetry binaries, WinSxS cleanup.
#  Runs late — all services are stopped, state is clean.
# ════════════════════════════════════════════════════════════

Write-Phase 'debloat'

# ── helper: run as trustedinstaller ───────────────────────
function Invoke-AsTI {
    param([string]$Code)
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $regKey  = "Registry::HKU\$userSid\Volatile Environment"
    $bytes   = [System.Text.Encoding]::Unicode.GetBytes($Code)
    $b64     = [Convert]::ToBase64String($bytes)
    Set-ItemProperty $regKey '_AlbusTI' $b64 -Type 1 -ErrorAction SilentlyContinue
    try { Stop-Service TrustedInstaller -Force -ErrorAction Stop } catch { taskkill /im trustedinstaller.exe /f *>$null }
    $svc = Get-CimInstance Win32_Service -Filter "Name='TrustedInstaller'"
    $def = $svc.PathName
    sc.exe config TrustedInstaller binPath= "cmd.exe /c powershell -nop -ep bypass -enc $b64" | Out-Null
    sc.exe start  TrustedInstaller | Out-Null
    Start-Sleep 3
    sc.exe config TrustedInstaller binpath= "`"$def`"" | Out-Null
    try { Stop-Service TrustedInstaller -Force -ErrorAction SilentlyContinue } catch { taskkill /im trustedinstaller.exe /f *>$null }
    Remove-ItemProperty $regKey '_AlbusTI' -ErrorAction SilentlyContinue
}

# ── FIX: safe reg delete — key/value yoksa sessizce atlar ──
# $ErrorActionPreference='Stop' ortamında reg.exe query'nin non-zero exit code'u
# NativeCommandError fırlatır. cmd /c wrapper + *>$null ile hem stdout/stderr
# hem de PS hata akışı tamamen bastırılır; sadece $LASTEXITCODE kontrol edilir.
function Invoke-RegDelete {
    param(
        [string]$Path,
        [string]$Value = ''
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        if ($Value) {
            cmd /c "reg.exe query `"$Path`" /v `"$Value`"" *>$null
        } else {
            cmd /c "reg.exe query `"$Path`"" *>$null
        }
        if ($LASTEXITCODE -ne 0) { return }
        if ($Value) {
            cmd /c "reg.exe delete `"$Path`" /v `"$Value`" /f" *>$null
        } else {
            cmd /c "reg.exe delete `"$Path`" /f" *>$null
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# ── kill interfering processes ─────────────────────────────
Write-Step 'stopping ai & copilot processes'
@(
    'ai','Copilot','aihost','aicontext','ClickToDo','aixhost',
    'WorkloadsSessionHost','WebViewHost','aimgr','AppActions',
    'M365Copilot','VisualAssist','msedge','msedgewebview2',
    'MicrosoftEdgeUpdate','OneDrive','WindowsBackup','WindowsBackupClient'
) | ForEach-Object { Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue }

# ════════════════════════════════════════════════════════════
#  1 · UWP BLOAT
# ════════════════════════════════════════════════════════════
Write-Step 'removing uwp bloat'

$uwpKeep = @(
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
    '*Microsoft.Windows.Photos*'
    '*Microsoft.Windows.ShellExperienceHost*'
    '*Microsoft.Windows.StartMenuExperienceHost*'
    '*Microsoft.WindowsNotepad*'
    '*Microsoft.WindowsStore*'
    '*Microsoft.ImmersiveControlPanel*'
)

# ai/copilot packages that need eol trick
$aiPackages = @(
    'MicrosoftWindows.Client.AIX'
    'MicrosoftWindows.Client.CoPilot'
    'Microsoft.Windows.Ai.Copilot.Provider'
    'Microsoft.Copilot'
    'Microsoft.MicrosoftOfficeHub'
    'MicrosoftWindows.Client.CoreAI'
    'Microsoft.Edge.GameAssist'
    'Microsoft.Office.ActionsServer'
    'aimgr'
    'Microsoft.WritingAssistant'
    'Clipchamp.Clipchamp'
    'MicrosoftWindows.*.Voiess'
    'MicrosoftWindows.*.Speion'
    'MicrosoftWindows.*.Livtop'
    'MicrosoftWindows.*.InpApp'
    'MicrosoftWindows.*.Filons'
    'WindowsWorkload.*'
)

$store = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
$users = @('S-1-5-18')
if (Test-Path $store) {
    $users += (Get-ChildItem $store -ErrorAction SilentlyContinue |
               Where-Object { $_ -like '*S-1-5-21*' }).PSChildName
}

foreach ($choice in $aiPackages) {
    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                   Where-Object { $_.PackageName -like "*$choice*" }
    $appxpkg     = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
                   Where-Object { $_.PackageFullName -like "*$choice*" }

    foreach ($appx in $provisioned) {
        $pfn = ($appxpkg | Where-Object { $_.Name -eq $appx.DisplayName }).PackageFamilyName
        if ($pfn) {
            New-Item "$store\Deprovisioned\$pfn" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-NonRemovableAppsPolicy -Online -PackageFamilyName $pfn -NonRemovable 0 -ErrorAction SilentlyContinue
        }
        Remove-AppxProvisionedPackage -PackageName $appx.PackageName -Online -AllUsers -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($appx in $appxpkg) {
        New-Item "$store\Deprovisioned\$($appx.PackageFamilyName)" -Force -ErrorAction SilentlyContinue | Out-Null
        Set-NonRemovableAppsPolicy -Online -PackageFamilyName $appx.PackageFamilyName -NonRemovable 0 -ErrorAction SilentlyContinue
        Remove-Item "$store\InboxApplications\$($appx.PackageFullName)" -Force -ErrorAction SilentlyContinue
        foreach ($uid in $appx.PackageUserInformation) {
            New-Item "$store\EndOfLife\$($uid.UserSecurityID.SID)\$($appx.PackageFullName)" -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-AppxPackage -Package $appx.PackageFullName -User $uid.UserSecurityID.SID -ErrorAction SilentlyContinue | Out-Null
        }
        foreach ($sid in $users) {
            New-Item "$store\EndOfLife\$sid\$($appx.PackageFullName)" -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Remove-AppxPackage -Package $appx.PackageFullName -AllUsers -ErrorAction SilentlyContinue | Out-Null
    }
}

# ── FIX: genel bloat temizliği
# Client.CBS, ShellExperienceHost, StartMenuExperienceHost gibi sistem paketleri
# Remove-AppxPackage -AllUsers ile kaldırılamaz (0x80070032).
# $uwpKeep listesinde zaten korunuyorlar ama burada da açıkça kontrol ediyoruz.
$systemPackagePatterns = @(
    '*Client.CBS*'
    '*ShellExperienceHost*'
    '*StartMenuExperienceHost*'
    '*Microsoft.UI.Xaml*'
    '*VCLibs*'
)

Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
    $name = $_.Name
    $fullName = $_.PackageFullName
    # uwpKeep listesinde varsa atla
    $inKeep = $uwpKeep | Where-Object { $name -like $_ }
    # sistem paketi pattern'ına giriyorsa atla
    $isSystemPkg = $systemPackagePatterns | Where-Object { $fullName -like $_ }
    (-not $inKeep) -and (-not $isSystemPkg)
} | ForEach-Object {
    try {
        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # NonRemovable veya sistem paketi — sessizce geç, Write-Log ile kaydet
        Write-Log "SKIP (system/nonremovable appx): $($_.PackageFullName)"
    }
}

# group policy block — prevent reinstall
Write-Step 'blocking copilot reinstall via policy'
$blockPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Appx\RemoveDefaultMicrosoftStorePackages'
Set-Reg $blockPath 'Enabled' 1
@(
    'Microsoft.Copilot_8wekyb3d8bbwe'
    'Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe'
    'Clipchamp.Clipchamp_yxz26nhyzhsrt'
) | ForEach-Object {
    Set-Reg "$blockPath\$_" 'RemovePackage' 1
}
Set-ItemProperty $blockPath -Name 'DynamicRemovalList' -Value @('aimgr_8wekyb3d8bbwe','Microsoft.Edge.GameAssist_8wekyb3d8bbwe') -Type 7 -ErrorAction SilentlyContinue

# block pwa reinstall
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoInstalledPWAs' 'CopilotPWAPreinstallCompleted' 1
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoInstalledPWAs' 'Microsoft.Copilot_8wekyb3d8bbwe' 1

Write-Step 'copilot appx removed' 'ok'

# ════════════════════════════════════════════════════════════
#  2 · COPILOT REGISTRY & POLICIES
# ════════════════════════════════════════════════════════════
Write-Step 'disabling copilot via registry & policies'

# ── FIX: Invoke-RegDelete kullanımı — yoksa hata vermez
Invoke-RegDelete 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsAI\LastConfiguration'
Invoke-RegDelete 'HKCU\Software\Microsoft\Windows\Shell\Copilot' 'CopilotLogonTelemetryTime'
Invoke-RegDelete 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\Microsoft.Copilot_8wekyb3d8bbwe\Copilot.StartupTaskId'
Invoke-RegDelete 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe\WebViewHostStartupId'
Invoke-RegDelete 'HKCU\Software\Microsoft\Copilot' 'WakeApp'

# ai windows policies — Set-Reg kullanıyor, zaten güvenli
$aiPolicyValues = @(
    @{ Hive='HKLM'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableAIDataAnalysis';          Val=1 }
    @{ Hive='HKLM'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='AllowRecallEnablement';          Val=0 }
    @{ Hive='HKLM'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableClickToDo';               Val=1 }
    @{ Hive='HKLM'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='TurnOffSavingSnapshots';         Val=1 }
    @{ Hive='HKLM'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableSettingsAgent';           Val=1 }
    @{ Hive='HKLM'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableAgentConnectors';         Val=1 }
    @{ Hive='HKLM'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableAgentWorkspaces';         Val=1 }
    @{ Hive='HKLM'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableRemoteAgentConnectors';   Val=1 }
    @{ Hive='HKCU'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableAIDataAnalysis';          Val=1 }
    @{ Hive='HKCU'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableClickToDo';               Val=1 }
    @{ Hive='HKCU'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name='TurnOffWindowsCopilot';     Val=1 }
    @{ Hive='HKLM'; Key='SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name='TurnOffWindowsCopilot';     Val=1 }
)

foreach ($p in $aiPolicyValues) {
    Set-Reg "$(if($p.Hive -eq 'HKLM'){'HKLM:'}else{'HKCU:'})$($p.Key)" $p.Name $p.Val
}

foreach ($hive in @('HKLM:','HKCU:')) {
    Set-Reg "$hive\SOFTWARE\Microsoft\Windows\Shell\Copilot\BingChat" 'IsUserEligible'      0
    Set-Reg "$hive\SOFTWARE\Microsoft\Windows\Shell\Copilot"          'IsCopilotAvailable'  0
    Set-Reg "$hive\SOFTWARE\Microsoft\Windows\Shell\Copilot"          'CopilotDisabledReason' 'FeatureIsDisabled' 'String'
}

# taskbar & pin
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'       'ShowCopilotButton' 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'       'TaskbarCompanion'  0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband\AuxilliaryPins' 'CopilotPWAPin' 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband\AuxilliaryPins' 'RecallPin'     0
Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsCopilot'          'AllowCopilotRuntime' 0

# mic & ai model access deny
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\Microsoft.Copilot_8wekyb3d8bbwe' 'Value' 'Deny' 'String'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\systemAIModels' 'Value' 'Deny' 'String'
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\generativeAI'  'Value' 'Deny' 'String'
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessGenerativeAI'   2
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsAccessSystemAIModels' 2

# background access deny
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\Microsoft.Copilot_8wekyb3d8bbwe' 'DisabledByUser' 1
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\Microsoft.Copilot_8wekyb3d8bbwe' 'Disabled'       1
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe' 'DisabledByUser' 1
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications\Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe' 'Disabled'       1

# velocity feature overrides
$velocityOverrides = @(
    @{ Id='1853569164'; Val=1 }
    @{ Id='4098520719'; Val=1 }
    @{ Id='929719951';  Val=1 }
    @{ Id='2283032206'; Val=1 }
    @{ Id='502943886';  Val=1 }
    @{ Id='3389499533'; Val=1 }
    @{ Id='4027803789'; Val=1 }
    @{ Id='450471565';  Val=1 }
    @{ Id='1646260367'; Val=2 }
)
foreach ($v in $velocityOverrides) {
    Set-Reg "HKLM:\SYSTEM\ControlSet001\Control\FeatureManagement\Overrides\8\$($v.Id)" 'EnabledState' $v.Val
}

# .copilot file extension & uri handlers
Invoke-RegDelete 'HKCU\Software\Classes\.copilot'
Invoke-RegDelete 'HKCR\.copilot'
@('ms-office-ai','ms-copilot','ms-clicktodo') | ForEach-Object {
    Remove-Item "Registry::HKEY_CLASSES_ROOT\$_" -Recurse -Force -ErrorAction SilentlyContinue
}

# copilot update paths in edge
Invoke-RegDelete 'HKLM\SOFTWARE\Microsoft\EdgeUpdate'            'CopilotUpdatePath'
Invoke-RegDelete 'HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate' 'CopilotUpdatePath'

# hide ai components in settings
$existing = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
if ($existing -and $existing -notlike '*aicomponents*') {
    $sep = if ($existing.EndsWith(';')) { '' } else { ';' }
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' "$existing${sep}aicomponents;appactions;" 'String'
} elseif (-not $existing) {
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'hide:aicomponents;appactions;' 'String'
}

# paint ai disable
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableImageCreator'   1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableCocreator'      1
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableGenerativeFill' 1

# notepad ai disable
Set-Reg 'HKLM:\SOFTWARE\Policies\WindowsNotepad' 'DisableAIFeatures' 1

# voice access — disable
Set-Reg 'HKCU:\Software\Microsoft\VoiceAccess' 'RunningState'   0
Set-Reg 'HKCU:\Software\Microsoft\VoiceAccess' 'TextCorrection' 1

# apply to default user hive
[GC]::Collect()
Invoke-RegDelete 'HKU\DefaultUser'
try {
    reg.exe load 'HKU\DefaultUser' "$env:SystemDrive\Users\Default\NTUSER.DAT" *>$null
    Set-Reg 'Registry::HKU\DefaultUser\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'  'TurnOffWindowsCopilot'  1
    Set-Reg 'Registry::HKU\DefaultUser\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'       'DisableAIDataAnalysis'  1
    Set-Reg 'Registry::HKU\DefaultUser\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'       'AllowRecallEnablement'  0
    Set-Reg 'Registry::HKU\DefaultUser\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'       'DisableClickToDo'       1
    Set-Reg 'Registry::HKU\DefaultUser\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'       'TurnOffSavingSnapshots' 1
    Set-Reg 'Registry::HKU\DefaultUser\SOFTWARE\Microsoft\Windows\Shell\Copilot'            'IsCopilotAvailable'     0
    Set-Reg 'Registry::HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
    Set-Reg 'Registry::HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarCompanion'  0
    Set-Reg 'Registry::HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband\AuxilliaryPins' 'CopilotPWAPin' 0
    Set-Reg 'Registry::HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband\AuxilliaryPins' 'RecallPin'     0
} catch {}
reg.exe unload 'HKU\DefaultUser' *>$null

# copilot nudge registry keys (TI required)
Write-Step 'removing copilot nudge registry keys'
$nudgeKeys = @(
    'registry::HKCR\Extensions\ContractId\Windows.BackgroundTasks\PackageId\MicrosoftWindows.Client.Core_*.*.*.*_x64__cw5n1h2txyewy\ActivatableClassId\Global.CopilotNudges.AppX*.wwa'
    'registry::HKCR\Extensions\ContractId\Windows.Launch\PackageId\MicrosoftWindows.Client.Core_*.*.*.*_x64__cw5n1h2txyewy\ActivatableClassId\Global.CopilotNudges.wwa'
    'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages\MicrosoftWindows.Client.Core_*.*.*.*_x64__cw5n1h2txyewy\Applications\MicrosoftWindows.Client.Core_cw5n1h2txyewy!Global.CopilotNudges'
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup\MicrosoftWindows.Client.Core_cw5n1h2txyewy!Global.CopilotNudges'
)
foreach ($k in $nudgeKeys) {
    try {
        $resolved = Get-Item -Path $k -ErrorAction Stop
        if ($resolved) { Remove-Item -Path "registry::$resolved" -Recurse -Force -ErrorAction SilentlyContinue }
    } catch {}
}

# shell update packages cleanup
Invoke-RegDelete 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Update\Packages\Components' 'AIX'
Invoke-RegDelete 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Update\Packages\Components' 'CopilotNudges'
Invoke-RegDelete 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell\Update\Packages\Components' 'AIContext'
Invoke-RegDelete 'HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\ActionsMcpHost.exe'
Invoke-RegDelete 'HKLM\Software\Microsoft\Windows\CurrentVersion\App Paths\ActionsMcpHost.exe'

# recall tasks
Write-Step 'removing recall scheduled tasks'
$tiCode = @"
Get-ScheduledTask -TaskPath '*WindowsAI*' -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
Remove-Item "`$env:SystemRoot\System32\Tasks\Microsoft\Windows\WindowsAI" -Recurse -Force -ErrorAction SilentlyContinue
`$initID = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\WindowsAI\Recall\InitialConfiguration" -Name 'Id' -ErrorAction SilentlyContinue
`$polID  = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\WindowsAI\Recall\PolicyConfiguration"  -Name 'Id' -ErrorAction SilentlyContinue
if (`$initID) { Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\`$initID" -Recurse -Force -ErrorAction SilentlyContinue }
if (`$polID)  { Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tasks\`$polID"  -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\TaskCache\Tree\Microsoft\Windows\WindowsAI" -Recurse -Force -ErrorAction SilentlyContinue
Get-ScheduledTask -TaskName '*Office Actions Server*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:`$false -ErrorAction SilentlyContinue
"@
$tiPath = "$env:TEMP\albus_recall_tasks.ps1"
Set-Content $tiPath $tiCode -Force
Invoke-AsTI -Code (Get-Content $tiPath -Raw)
Remove-Item $tiPath -Force -ErrorAction SilentlyContinue

Write-Step 'copilot registry & policies applied' 'ok'

# ════════════════════════════════════════════════════════════
#  3 · RECALL OPTIONAL FEATURE
# ════════════════════════════════════════════════════════════
Write-Step 'removing recall optional feature'
try {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName 'Recall' -ErrorAction Stop).State
    if ($state -and $state -ne 'DisabledWithPayloadRemoved') {
        Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -NoRestart -ErrorAction Stop *>$null
        Write-Step 'recall feature removed' 'ok'
    } else {
        Write-Step 'recall already absent' 'skip'
    }
} catch {
    $dismOut = dism.exe /Online /Get-FeatureInfo /FeatureName:Recall
    if ($LASTEXITCODE -eq 0) {
        $removed = $dismOut | Select-String 'Disabled with Payload Removed'
        if (-not $removed) {
            dism.exe /Online /Disable-Feature /FeatureName:Recall /Remove /NoRestart /Quiet
            Write-Step 'recall removed via dism' 'ok'
        } else {
            Write-Step 'recall payload already removed' 'skip'
        }
    }
}

# ════════════════════════════════════════════════════════════
#  4 · COPILOT CBS PACKAGES (hidden component store)
# ════════════════════════════════════════════════════════════
Write-Step 'removing hidden ai cbs packages'
$cbsKeywords = @('*AIX*','*Recall*','*Copilot*','*CoreAI*')
$cbsRegPath  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
Get-ChildItem $cbsRegPath -ErrorAction SilentlyContinue | ForEach-Object {
    $match = $cbsKeywords | Where-Object { $_.PSChildName -like $_ }
    if (-not $match) { return }
    $vis = try { (Get-ItemPropertyValue $_.PSPath 'Visibility' -ErrorAction Stop) } catch { $null }
    if ($vis -eq 2) {
        Set-ItemProperty $_.PSPath -Name 'Visibility' -Value 1 -Force -ErrorAction SilentlyContinue
        New-ItemProperty $_.PSPath -Name 'DefVis' -PropertyType DWord -Value 2 -Force -ErrorAction SilentlyContinue | Out-Null
        Remove-Item "$($_.PSPath)\Owners" -Force -ErrorAction SilentlyContinue
        Remove-Item "$($_.PSPath)\Updates" -Force -ErrorAction SilentlyContinue
        try {
            Remove-WindowsPackage -Online -PackageName $_.PSChildName -NoRestart -ErrorAction Stop *>$null
        } catch {
            dism.exe /Online /Remove-Package /PackageName:$($_.PSChildName) /NoRestart /Quiet
        }
        $paths = Get-ChildItem "$env:SystemRoot\servicing\Packages" -Filter "*$($_.PSChildName)*" -ErrorAction SilentlyContinue
        foreach ($p in $paths) { Remove-Item $p.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# ════════════════════════════════════════════════════════════
#  5 · COPILOT FILE SYSTEM CLEANUP
# ════════════════════════════════════════════════════════════
Write-Step 'removing copilot files from disk'

$aiFilePaths = @(
    "$env:SystemRoot\SystemApps\MicrosoftWindows.Client.CoPilot_cw5n1h2txyewy"
    "$env:SystemRoot\SystemApps\Microsoft.Copilot_8wekyb3d8bbwe"
    "$env:ProgramFiles\WindowsApps\MicrosoftWindows.Client.AIX*"
    "$env:ProgramFiles\WindowsApps\MicrosoftWindows.Client.CoPilot*"
    "$env:ProgramFiles\WindowsApps\Microsoft.Windows.Ai.Copilot.Provider*"
    "$env:ProgramFiles\WindowsApps\MicrosoftWindows.Client.CoreAI*"
    "$env:ProgramFiles\WindowsApps\Microsoft.Copilot*"
    "$env:ProgramFiles\WindowsApps\Microsoft.Edge.GameAssist*"
    "$env:ProgramFiles\WindowsApps\aimgr*"
    "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.CoPilot*"
    "$env:LOCALAPPDATA\Packages\Microsoft.Copilot*"
    "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.AIX*"
    "$env:LOCALAPPDATA\Packages\MicrosoftWindows.Client.CoreAI*"
    "$env:LOCALAPPDATA\CoreAIPlatform*"
    "$env:SystemRoot\System32\Windows.AI.MachineLearning.dll"
    "$env:SystemRoot\SysWOW64\Windows.AI.MachineLearning.dll"
    "$env:SystemRoot\System32\Windows.AI.MachineLearning.Preview.dll"
    "$env:SystemRoot\SysWOW64\Windows.AI.MachineLearning.Preview.dll"
    "$env:SystemRoot\System32\SettingsHandlers_Copilot.dll"
    "$env:SystemRoot\System32\SettingsHandlers_A9.dll"
    "$env:SystemRoot\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\ActionUI"
    "$env:SystemRoot\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\VisualAssist"
    "$env:SystemRoot\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\AppActions.exe"
    "$env:SystemRoot\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\AppActions.dll"
    "$env:SystemRoot\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\VisualAssistExe.exe"
    "$env:SystemRoot\SystemApps\MicrosoftWindows.Client.CBS_cw5n1h2txyewy\VisualAssistExe.dll"
)

# edge copilot installers
$edgeDirs = @('Edge','EdgeCore','EdgeWebView')
foreach ($d in $edgeDirs) {
    $base = "${env:ProgramFiles(x86)}\Microsoft\$d"
    if ($d -eq 'EdgeCore') {
        $found = Get-ChildItem "$base\*.*.*.*\copilot_provider_msix" -ErrorAction SilentlyContinue
    } else {
        $found = Get-ChildItem "$base\Application\*.*.*.*\copilot_provider_msix" -ErrorAction SilentlyContinue
    }
    if ($found) { Remove-Item $found.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}

$edgeUpdateDir = "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate"
if (Test-Path $edgeUpdateDir) {
    Get-ChildItem $edgeUpdateDir -Recurse -Filter '*CopilotUpdate.exe*' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
}

$inboxApps = 'C:\Windows\InboxApps'
if (Test-Path $inboxApps) {
    Get-ChildItem $inboxApps -Filter '*Copilot*' -ErrorAction SilentlyContinue | ForEach-Object {
        takeown /f $_.FullName *>$null
        icacls $_.FullName /grant *S-1-5-32-544:F /t *>$null
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# onedrive copilot chat
if ($env:OneDrive -and (Test-Path "$env:OneDrive\Microsoft Copilot Chat Files")) {
    Remove-Item "$env:OneDrive\Microsoft Copilot Chat Files" -Recurse -Force -ErrorAction SilentlyContinue
}

# remove DLLs and folder paths via TI
$tiRemoveCode = ($aiFilePaths | ForEach-Object {
    $p = $_
    "Get-ChildItem '$p' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item `$_.FullName -Recurse -Force -ErrorAction SilentlyContinue }"
}) -join "`n"
$tiPath2 = "$env:TEMP\albus_ai_files.ps1"
Set-Content $tiPath2 $tiRemoveCode -Force
Invoke-AsTI -Code (Get-Content $tiPath2 -Raw)
Remove-Item $tiPath2 -Force -ErrorAction SilentlyContinue

Write-Step 'copilot files removed' 'ok'

# ════════════════════════════════════════════════════════════
#  6 · AI SERVICES (wsaifabricsvc, aarsvc)
# ════════════════════════════════════════════════════════════
Write-Step 'removing ai services'
try { Stop-Service -Name WSAIFabricSvc -Force -ErrorAction Stop } catch {}
sc.exe delete WSAIFabricSvc *>$null

$aarSvc = (Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*aarsvc*' }).Name
if ($aarSvc) {
    try { Stop-Service -Name $aarSvc -Force -ErrorAction SilentlyContinue } catch {}
    sc.exe delete AarSvc *>$null
}
Write-Step 'ai services removed' 'ok'

# ════════════════════════════════════════════════════════════
#  7 · EDGE REMOVAL
# ════════════════════════════════════════════════════════════
Write-Step 'removing microsoft edge'

function Invoke-EdgeUninstallProcess {
    param([string]$Key)
    $baseKey      = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate'
    $registryPath = "$baseKey\ClientState\$Key"
    if (!(Test-Path $registryPath)) { Write-Step "edge registry key not found: $Key" 'warn'; return }

    Remove-ItemProperty -Path $registryPath -Name 'experiment_control_labels' -ErrorAction SilentlyContinue | Out-Null

    try {
        $folderPath = "$env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
        if (!(Test-Path $folderPath)) { New-Item -ItemType Directory -Path $folderPath -Force | Out-Null }
        New-Item -ItemType File -Path $folderPath -Name 'MicrosoftEdge.exe' -Force | Out-Null
    } catch { Write-Step "failed to create fake microsoftedge.exe: $_" 'warn'; return }

    $env:windir         = ''
    $uninstallString    = (Get-ItemProperty -Path $registryPath -EA SilentlyContinue).UninstallString
    $uninstallArguments = (Get-ItemProperty -Path $registryPath -EA SilentlyContinue).UninstallArguments

    if ([string]::IsNullOrEmpty($uninstallString) -or [string]::IsNullOrEmpty($uninstallArguments)) {
        Write-Step "cannot find uninstall string for $Key" 'warn'; return
    }

    $uninstallArguments += ' --force-uninstall --delete-profile'
    if (!(Test-Path $uninstallString)) { Write-Step "setup.exe not found: $uninstallString" 'warn'; return }

    $spoofPath = "$env:SystemRoot\ImmersiveControlPanel\sihost.exe"
    try {
        Copy-Item "$env:SystemRoot\System32\cmd.exe" -Destination $spoofPath -Force
        $process = Start-Process -FilePath $spoofPath -ArgumentList "/c `"$uninstallString`" $uninstallArguments" -Wait -NoNewWindow -PassThru
        Write-Step "edge uninstall exit code: $($process.ExitCode)" 'ok'
    } catch {
        Write-Step "edge uninstall failed: $_" 'fail'
    } finally {
        Remove-Item $spoofPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-Edge {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge' `
        -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    [Microsoft.Win32.Registry]::SetValue(
        'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdateDev',
        'AllowUninstall', 1, [Microsoft.Win32.RegistryValueKind]::DWord) | Out-Null
    Invoke-EdgeUninstallProcess -Key '{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}'
    @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
      "$env:Public\Desktop", "$env:UserProfile\Desktop") | ForEach-Object {
        $lnk = Join-Path $_ 'Microsoft Edge.lnk'
        if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
    }
}

function Remove-WebView {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft EdgeWebView' `
        -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    Invoke-EdgeUninstallProcess -Key '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
}

function Remove-EdgeUpdate {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update' `
        -Name 'NoRemove' -ErrorAction SilentlyContinue | Out-Null
    $registryPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate'
    $uninstallCmd = (Get-ItemProperty -Path $registryPath -EA SilentlyContinue).UninstallCmdLine

    @('MicrosoftEdgeUpdate','msedgeupdate') | ForEach-Object {
        Stop-Process -Name $_ -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep 2

    if (-not [string]::IsNullOrEmpty($uninstallCmd)) {
        Start-Process cmd.exe "/c $uninstallCmd" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
    }

    @(
        "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate"
        "$env:ProgramFiles\Microsoft\EdgeUpdate"
    ) | ForEach-Object {
        if (Test-Path $_) {
            try {
                takeown /F $_ /R /D Y *>$null
                icacls $_ /grant Administrators:F /T /Q *>$null
                Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
                Write-Step "edge update folder removed: $_" 'ok'
            } catch {
                Write-Step "could not remove: $_" 'warn'
            }
        }
    }

    @('edgeupdate','edgeupdatem') | ForEach-Object {
        $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service $_ -Force -ErrorAction SilentlyContinue
            sc.exe delete $_ *>$null
            Write-Step "edge update service deleted: $_" 'ok'
        }
    }

    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like '*Edge*' -or $_.TaskName -like '*MicrosoftEdge*' } |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
}

Remove-Edge
Remove-WebView
Remove-EdgeUpdate

# ════════════════════════════════════════════════════════════
#  8 · ONEDRIVE REMOVAL
# ════════════════════════════════════════════════════════════
Write-Step 'removing onedrive'

function Remove-OneDrive {
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
    }
    $exePaths = New-Object System.Collections.Generic.List[string]
    @(
        "$env:SystemRoot\System32\OneDriveSetup.exe"
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    ) | Where-Object { Test-Path $_ } | ForEach-Object { $exePaths.Add($_) | Out-Null }

    Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.PSChildName
        if ($sid -notmatch '^S-1-5-21-') { return }
        $regPath = "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe"
        try {
            $str = (Get-ItemProperty $regPath -ErrorAction Stop).UninstallString
            $exe = if ($str -match '^"(.+?)"') { $matches[1] } else { $str.Split(' ')[0] }
            if ($exe -and (Test-Path $exe)) { $exePaths.Add($exe) | Out-Null }
        } catch {}
        Remove-ItemProperty "HKU:\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name 'OneDrive' -ErrorAction SilentlyContinue
        Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    ($exePaths | Select-Object -Unique) | ForEach-Object {
        try { Start-Process -FilePath $_ -ArgumentList '/uninstall' -Wait -NoNewWindow | Out-Null } catch {}
    }

    try {
        Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*OneDrive*' } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue }
    } catch {}
    try { Get-AppxPackage -AllUsers *OneDrive* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue } catch {}

    Get-ChildItem "$env:SystemDrive\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        @(
            "$($_.FullName)\OneDrive"
            "$($_.FullName)\AppData\Local\Microsoft\OneDrive"
            "$($_.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk"
        ) | Where-Object { Test-Path $_ } | ForEach-Object {
            Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $clsid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'
    foreach ($hkcr in @("HKCR:\CLSID\$clsid","HKCR:\Wow6432Node\CLSID\$clsid")) {
        try {
            New-Item $hkcr -Force | Out-Null
            Set-ItemProperty $hkcr -Name 'System.IsPinnedToNameSpaceTree' -Value 0 -Type DWord
        } catch {}
    }
    Write-Step 'onedrive removed' 'ok'
}
Remove-OneDrive

# ════════════════════════════════════════════════════════════
#  9 · WINDOWS BACKUP REMOVAL
# ════════════════════════════════════════════════════════════
Write-Step 'removing windows backup'

@('MicrosoftWindows.Client.CBS','WindowsBackup') | ForEach-Object {
    Get-AppxPackage -AllUsers *$_* -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue | Out-Null }
}

Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '*Windows Backup*' } |
    ForEach-Object {
        if ($_.UninstallString) {
            $args = if ($_.UninstallString -match '^msiexec') { "/x $($_.PSChildName) /qn /norestart" } else { '/uninstall /quiet' }
            Start-Process -FilePath ($_.UninstallString.Split(' ')[0]) -ArgumentList $args -Wait -NoNewWindow -ErrorAction SilentlyContinue
        }
    }

Stop-Process -Name 'WindowsBackupClient' -Force -ErrorAction SilentlyContinue
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -like '*WindowsBackup*' -or $_.TaskName -like '*BackupTask*' } |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

@('WbengEngine','SDRSVC','wbengine') | ForEach-Object {
    $s = Get-Service $_ -ErrorAction SilentlyContinue
    if ($s) {
        Stop-Service $_ -Force -ErrorAction SilentlyContinue
        Set-Service  $_ -StartupType Disabled -ErrorAction SilentlyContinue
    }
}

Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'    'DisableWindowsBackupSuggestions' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BackupAndRestore' 'DisableBackup'                  1

Write-Step 'windows backup removed' 'ok'

# ════════════════════════════════════════════════════════════
#  10 · WINDOWS CAPABILITIES CLEANUP
# ════════════════════════════════════════════════════════════
Write-Step 'removing windows capabilities'
try {
    Get-WindowsCapability -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Installed'             -and
        $_.Name -notlike '*Ethernet*'        -and
        $_.Name -notlike '*WiFi*'            -and
        $_.Name -notlike '*Notepad*'         -and
        $_.Name -notlike '*NetFX3*'          -and
        $_.Name -notlike '*VBSCRIPT*'        -and
        $_.Name -notlike '*WMIC*'            -and
        $_.Name -notlike '*ShellComponents*'
    } | ForEach-Object {
        try { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
} catch {}

# ════════════════════════════════════════════════════════════
#  11 · OPTIONAL FEATURES CLEANUP
# ════════════════════════════════════════════════════════════
Write-Step 'disabling optional features'
try {
    Get-WindowsOptionalFeature -Online -ErrorAction Stop | Where-Object {
        $_.State -eq 'Enabled'                          -and
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
        try { Disable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName -NoRestart -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
} catch {}

# ════════════════════════════════════════════════════════════
#  12 · TELEMETRY BINARIES NEUTRALIZE
# ════════════════════════════════════════════════════════════
Write-Step 'neutralizing telemetry binaries'
@(
    "$env:SystemRoot\System32\CompatTelRunner.exe"
    "$env:SystemRoot\System32\DeviceCensus.exe"
    "$env:SystemRoot\System32\AggregatorHost.exe"
    "$env:SystemRoot\System32\wsqmcons.exe"
    "$env:SystemRoot\System32\WerFault.exe"
    "$env:SystemRoot\System32\WerFaultSecure.exe"
    "$env:SystemRoot\System32\wermgr.exe"
    "$env:SystemRoot\System32\DiagSvcs\DiagnosticsHub.StandardCollector.Service.exe"
    "$env:SystemRoot\System32\omadmclient.exe"
    "$env:SystemRoot\SysWOW64\CompatTelRunner.exe"
    "$env:SystemRoot\SysWOW64\DeviceCensus.exe"
) | ForEach-Object {
    if (-not (Test-Path $_)) { return }
    try {
        Rename-Item -Path $_ -NewName "$_.bak" -Force -ErrorAction Stop
        Write-Step "neutralized: $(Split-Path $_ -Leaf)" 'ok'
    } catch {
        Write-Step "skipped (locked): $(Split-Path $_ -Leaf)" 'warn'
    }
}

# ════════════════════════════════════════════════════════════
#  13 · DISM + WINSXS CLEANUP
# ════════════════════════════════════════════════════════════
Write-Step 'dism component store cleanup'
try {
    foreach ($a in @('/Online /Cleanup-Image /StartComponentCleanup /ResetBase','/Online /Cleanup-Image /SPSuperseded')) {
        $r = Start-Process dism.exe -ArgumentList $a -Wait -NoNewWindow -PassThru
        if ($r.ExitCode -eq 0) { Write-Step "dism $($a.Split('/')[3].Trim()) done" 'ok' }
        else                   { Write-Step "dism exit: $($r.ExitCode)" 'warn' }
    }
} catch { Write-Step "dism cleanup failed: $_" 'fail' }

Write-Step 'removing ai & telemetry dism packages'
$dismPackages = @(
    'Microsoft-Windows-DiagTrack-Package*'
    'Microsoft-Windows-Telemetry-Package*'
    'Microsoft-Windows-CEIP-Package*'
    'Microsoft-OneCore-ApplicationModel-Cortana*'
    'Microsoft-Windows-AI-MachineLearning*'
    'Microsoft-Windows-BioEnrollment-Package*'
    'Microsoft-Windows-Holographic*'
    'Microsoft-Windows-QuickAssist*'
    'Microsoft-Windows-StepsRecorder*'
)
foreach ($pkg in $dismPackages) {
    $found = dism /Online /Get-Packages /Format:Table 2>$null |
             Where-Object { $_ -match [regex]::Escape($pkg.Replace('*','')) }
    if (-not $found) { continue }
    $found | ForEach-Object {
        $n = ($_ -split '\|')[0].Trim()
        if ([string]::IsNullOrWhiteSpace($n)) { return }
        $r = Start-Process dism -ArgumentList "/Online /Remove-Package /PackageName:$n /NoRestart /Quiet" -Wait -NoNewWindow -PassThru
        if ($r.ExitCode -eq 0) { Write-Step "removed: $n" 'ok' }
        else                   { Write-Step "skip (in-use?): $n" 'warn' }
    }
}

Write-Step 'disabling telemetry winsxs manifests'
@('*diagtrack*','*telemetry*','*ceip*','*diaghub*','*wer*') | ForEach-Object {
    Get-ChildItem "$env:SystemRoot\WinSxS\Manifests" -Filter $_ -ErrorAction SilentlyContinue
} | ForEach-Object {
    try {
        Rename-Item -Path $_.FullName -NewName "$($_.FullName).bak" -Force -ErrorAction Stop
        Write-Step "manifest disabled: $($_.Name)" 'ok'
    } catch {
        Write-Step "manifest skipped (in use): $($_.Name)" 'warn'
    }
}

# ════════════════════════════════════════════════════════════
#  14 · UPDATE HEALTH TOOLS + GAMEINPUT
# ════════════════════════════════════════════════════════════
Write-Step 'removing update health tools'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Update for x64-based Windows Systems|Microsoft Update Health Tools' } |
    ForEach-Object {
        if ($_.PSChildName) {
            Start-Process 'msiexec.exe' -ArgumentList "/x $($_.PSChildName) /qn /norestart" -Wait -NoNewWindow
        }
    }
sc.exe delete 'uhssvc' *>$null
Unregister-ScheduledTask -TaskName PLUGScheduler -Confirm:$false -ErrorAction SilentlyContinue

Write-Step 'removing microsoft gameinput'
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '*Microsoft GameInput*' } |
    ForEach-Object {
        Start-Process 'msiexec.exe' -ArgumentList "/x $($_.PSChildName) /qn /norestart" -Wait -NoNewWindow
    }

# ════════════════════════════════════════════════════════════
#  DONE
# ════════════════════════════════════════════════════════════
Write-Step 'debloat complete' 'ok'
Write-Done 'debloat'
pause
