# =============================================================================================================================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Privilege = $Identity.Split('\')[-1]
[Console]::Title = "Albus Playbook - $Privilege"

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

$dest = "C:\Albus"
if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest | Out-Null }

if (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue) {
    Status "initializing dynamic payload retrieval..." "done"

    try {
        $braveRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/brave/brave-browser/releases/latest" -ErrorAction Stop
        $braveVer = $braveRelease.tag_name
        $braveUrl = "https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSetup.exe"
        
        Status "fetching brave browser ($braveVer)" "info"
        Invoke-WebRequest -Uri $braveUrl -OutFile "$dest\BraveSetup.exe" -UseBasicParsing -ErrorAction Stop
        
        Status "installing brave browser..." "info"
        Start-Process -Wait "$dest\BraveSetup.exe" -ArgumentList "/silent /install" -WindowStyle Hidden
        
        Status "applying browser hardening..." "info"
        reg.exe add "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" /v "HardwareAccelerationModeEnabled" /t REG_DWORD /d "0" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" /v "BackgroundModeEnabled" /t REG_DWORD /d "0" /f | Out-Null
        reg.exe add "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" /v "HighEfficiencyModeEnabled" /t REG_DWORD /d "1" /f | Out-Null
    } catch {
        Status "failed to retrieve brave browser package." "fail"
    }

    try {
        $7zRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/ip7z/7zip/releases/latest" -ErrorAction Stop
        $7zVer = $7zRelease.name
        $7zUrl = ($7zRelease.assets | Where-Object { $_.name -match "7z.*-x64\.exe" }).browser_download_url
        if ($7zUrl) {
            Status "fetching 7-zip ($7zVer)" "info"
            Invoke-WebRequest -Uri $7zUrl -OutFile "$dest\7zip.exe" -UseBasicParsing
            
            Status "extracting and installing 7-zip..." "info"
            Start-Process -Wait "$dest\7zip.exe" -ArgumentList "/S"
            reg.exe add "HKEY_CURRENT_USER\Software\7-Zip\Options" /v "ContextMenu" /t REG_DWORD /d "259" /f | Out-Null
            reg.exe add "HKEY_CURRENT_USER\Software\7-Zip\Options" /v "CascadedMenu" /t REG_DWORD /d "0" /f | Out-Null
            
            Move-Item -Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip\7-Zip File Manager.lnk" -Destination "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-Item "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\7-Zip" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Status "failed to retrieve 7-zip package." "fail"
    }

    try {
        Status "fetching visual c++ runtimes (latest)" "info"
        $vcLinks = @(
            "https://aka.ms/vs/17/release/vc_redist.x64.exe",
            "https://aka.ms/vs/17/release/vc_redist.x86.exe"
        )
        foreach ($vcLink in $vcLinks) {
            $arch = if ($vcLink -match "x64") { "x64" } else { "x86" }
            Status "downloading vc++ $arch..." "info"
            Invoke-WebRequest -Uri $vcLink -OutFile "$dest\vc_redist.$arch.exe" -UseBasicParsing
            
            Status "installing vc++ $arch..." "info"
            Start-Process -Wait "$dest\vc_redist.$arch.exe" -ArgumentList "/quiet /norestart" -WindowStyle Hidden
        }
    } catch {
        Status "failed to retrieve visual c++ packages." "fail"
    }

    try {
        Status "fetching directx end-user runtime (latest)" "info"
        $dxUrl = "https://download.microsoft.com/download/1/7/1/1718CCC4-6315-4D8E-9543-8E28A4E18C4C/dxwebsetup.exe"
        Status "downloading directx updater..." "info"
        Invoke-WebRequest -Uri $dxUrl -OutFile "$dest\dxwebsetup.exe" -UseBasicParsing -ErrorAction Stop
        
        Status "installing graphics api runtimes..." "info"
        Start-Process -Wait "$dest\dxwebsetup.exe" -ArgumentList "/Q" -WindowStyle Hidden
    } catch {
        Status "failed to retrieve directx." "fail"
    }

} else {
    Status "network interface unresponsive. bypassing payload retrieval." "fail"
}

# =============================================================================================================================================================================
