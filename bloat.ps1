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
    '*Microsoft.Windows.Photos*'
    '*Microsoft.Windows.ShellExperienceHost*'
    '*Microsoft.Windows.StartMenuExperienceHost*'
    '*Microsoft.WindowsNotepad*'
    '*Microsoft.WindowsStore*'
    '*Microsoft.ImmersiveControlPanel*'
    '*windows.immersivecontrolpanel*'
    '*Microsoft.WindowsCalculator*'
)

function Test-ShouldKeep {
    param([string]$Name)
    foreach ($p in $keepList) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

$baseRegistryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore"
$windowsAppsPath = "$env:ProgramFiles\WindowsApps"

# Framework paketlerini (IsFramework) es geçiyoruz ki koruduğumuz uygulamalar bozulmasın
$packagesToRemove = Get-AppxPackage -AllUsers | Where-Object { 
    $_.IsFramework -eq $false -and
    -not (Test-ShouldKeep $_.PackageFullName) -and 
    -not (Test-ShouldKeep $_.PackageFamilyName) 
}

foreach ($pkg in $packagesToRemove) {
    $fullPackageName = $pkg.PackageFullName
    $packageFamilyName = $pkg.PackageFamilyName

    Write-Host "Siliniyor: $($fullPackageName)" -ForegroundColor Yellow

    # 1. Standart Kaldırma (Hata fırlatmaması için try-catch ile sarıldı)
    try { Remove-AppxPackage -Package $fullPackageName -AllUsers -ErrorAction SilentlyContinue | Out-Null } catch {}
    
    # -NoRestart parametresi kaldırıldı
    try { Remove-AppxProvisionedPackage -Online -PackageName $fullPackageName -ErrorAction SilentlyContinue | Out-Null } catch {}

    # 2. Doğrudan Fiziksel İmha (TrustedInstaller yetkisiyle)
    $packageFolderPath = Join-Path -Path $windowsAppsPath -ChildPath $fullPackageName
    if (Test-Path $packageFolderPath) {
        try { Remove-Item -Path $packageFolderPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }

    # 3. Registry Temizliği
    $deprovisionedPath = "$baseRegistryPath\Deprovisioned\$packageFamilyName"
    if (-not (Test-Path -Path $deprovisionedPath)) {
        try { New-Item -Path $deprovisionedPath -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    }

    $inboxAppsPath = "$baseRegistryPath\InboxApplications\$fullPackageName"
    if (Test-Path $inboxAppsPath) {
        try { Remove-Item -Path $inboxAppsPath -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    }

    if ($null -ne $pkg.PackageUserInformation) {
        foreach ($userInfo in $pkg.PackageUserInformation) {
            $userSid = $userInfo.UserSecurityID.SID
            $endOfLifePath = "$baseRegistryPath\EndOfLife\$userSid\$fullPackageName"
            try { New-Item -Path $endOfLifePath -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
    }
}

Write-Host "İşlem hatasız tamamlandı." -ForegroundColor Green
