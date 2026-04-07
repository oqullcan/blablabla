
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Privilege = $Identity.Split('\')[-1]
[Console]::Title = "Albus Playbook - $Privilege"

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference     = "SilentlyContinue"

function Write-Log {
    param ([string]$Message, [ConsoleColor]$Color = "Cyan")
    Write-Host "  :: $Message" -ForegroundColor $Color
}

$dest = "C:\Albus"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }

if (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue) {
    Write-Log "Initializing Dynamic Payload Retrieval..." "Green"

    try {
        $braveRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/brave/brave-browser/releases/latest" -ErrorAction Stop
        $braveVer = $braveRelease.tag_name
        $braveUrl = "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe"
        
        Write-Log "Fetching Brave Browser ($braveVer)" "Yellow"
        Invoke-WebRequest -Uri $braveUrl -OutFile "$dest\BraveSetup.exe" -UseBasicParsing -ErrorAction Stop
        
        Write-Log "Installing Brave Browser..." "DarkGray"
        Start-Process -Wait "$dest\BraveSetup.exe" -ArgumentList "/silent /install" -WindowStyle Hidden
        
        Write-Log "Applying Browser Hardening..." "DarkGray"
        reg.exe add "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" /v "HardwareAccelerationModeEnabled" /t REG_DWORD /d "0" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" /v "BackgroundModeEnabled" /t REG_DWORD /d "0" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" /v "HighEfficiencyModeEnabled" /t REG_DWORD /d "1" /f | Out-Null
    } catch {
        Write-Log "Failed to retrieve Brave Browser package." "Red"
    }

    try {
        $7zRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/ip7z/7zip/releases/latest" -ErrorAction Stop
        $7zVer = $7zRelease.name
        $7zUrl = ($7zRelease.assets | Where-Object { $_.name -match "7z.*-x64\.exe" }).browser_download_url
        if ($7zUrl) {
            Write-Log "Fetching 7-Zip ($7zVer)" "Yellow"
            Invoke-WebRequest -Uri $7zUrl -OutFile "$dest\7zip.exe" -UseBasicParsing
            
            Write-Log "Extracting and Installing 7-Zip..." "DarkGray"
            Start-Process -Wait "$dest\7zip.exe" -ArgumentList "/S"
            reg.exe add "HKEY_CURRENT_USER\Software\7-Zip\Options" /v "ContextMenu" /t REG_DWORD /d "259" /f | Out-Null
            reg.exe add "HKEY_CURRENT_USER\Software\7-Zip\Options" /v "CascadedMenu" /t REG_DWORD /d "0" /f | Out-Null
            
            Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip\7-Zip File Manager.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Write-Log "Failed to retrieve 7-Zip package." "Red"
    }

    try {
        Write-Log "Fetching Visual C++ Runtimes (Latest)" "Yellow"
        $vcLinks = @(
            "https://aka.ms/vs/17/release/vc_redist.x64.exe",
            "https://aka.ms/vs/17/release/vc_redist.x86.exe"
        )
        foreach ($vcLink in $vcLinks) {
            $arch = if ($vcLink -match "x64") { "x64" } else { "x86" }
            Write-Log "Downloading VC++ $arch..." "DarkGray"
            Invoke-WebRequest -Uri $vcLink -OutFile "$dest\vc_redist.$arch.exe" -UseBasicParsing
            
            Write-Log "Installing VC++ $arch..." "DarkGray"
            Start-Process -Wait "$dest\vc_redist.$arch.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
        }
    } catch {
        Write-Log "Failed to retrieve Visual C++ packages." "Red"
    }

    try {
        Write-Log "Fetching DirectX End-User Runtime (Latest)" "Yellow"
        $dxUrl = "https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe"
        Write-Log "Downloading DirectX Updater..." "DarkGray"
        Invoke-WebRequest -Uri $dxUrl -OutFile "$dest\dxwebsetup.exe" -UseBasicParsing -ErrorAction Stop
        
        Write-Log "Installing Graphics API Runtimes..." "DarkGray"
        Start-Process -Wait "$dest\dxwebsetup.exe" -ArgumentList "/Q" -WindowStyle Hidden
    } catch {
        Write-Log "Failed to retrieve DirectX." "Red"
    }

} else {
    Write-Log "Network interface unresponsive. Bypassing payload retrieval." "Red"
}


