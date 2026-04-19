$ErrorActionPreference = 'Stop'
Clear-Host

# albus status engine
function status ($msg, $type = "info") {
    $p, $c = switch ($type) {
        "info"    { "info", "Cyan" }
        "done"    { "done", "Green" }
        "warn"    { "warn", "Red" }
        "fail"    { "fail", "Red" }
        "step"    { "step", "Magenta" }
        "ask"     { "ask ", "Yellow" }
        Default   { "albus", "Gray" }
    }
    Write-Host "$p - " -NoNewline -ForegroundColor $c
    Write-Host $msg.ToLower()
}

$host.UI.RawUI.WindowTitle = "albus usb creator"
status "initializing ventoy & albus usb automatic builder..." "step"

# 1. usb selection
$USBs = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter -ne $null }
if ($USBs.Count -eq 0) { 
    status "no usb drive detected. please plug in a usb and try again." "fail"
    Pause; Exit
}

status "scanning for available usb drives..." "info"
Write-Host ""
$USBs | Select-Object @{N='letter';E={$_.DriveLetter}}, @{N='label';E={$_.FileSystemLabel}}, @{N='free(gb)';E={[math]::Round($_.SizeRemaining/1GB, 2)}}, @{N='total(gb)';E={[math]::Round($_.Size/1GB, 2)}} | Format-Table -AutoSize
Write-Host ""

Write-Host "ask  - " -NoNewline -ForegroundColor Yellow
$ans = Read-Host "enter the drive letter of the usb you want to format (e.g. e)"
$DriveLetter = $ans.Trim().Replace(":", "").ToUpper()

if (-not ($USBs.DriveLetter -contains $DriveLetter)) {
    status "invalid drive letter selected. aborting." "fail"
    Pause; Exit
}

status "warning: all data on drive ${DriveLetter}:\ will be permanently erased." "warn"
Write-Host "ask  - " -NoNewline -ForegroundColor Yellow
$confirm = Read-Host "are you sure? type 'yes' to continue"
if ($confirm.ToLower() -ne 'yes') { 
    status "operation cancelled by user." "info"
    Exit 
}

# 2. download ventoy
status "fetching latest ventoy release from github..." "step"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Rel = Invoke-RestMethod "https://api.github.com/repos/ventoy/Ventoy/releases/latest" -UseBasicParsing
$Asset = $Rel.assets | Where-Object Name -match "windows.zip$"
$Zip = "$env:TEMP\ventoy.zip"
$Extract = "$env:TEMP\ventoy_extract"

status "downloading $($Asset.name)..." "info"
Invoke-WebRequest $Asset.browser_download_url -OutFile $Zip -UseBasicParsing
if (Test-Path $Extract) { Remove-Item $Extract -Recurse -Force }
Expand-Archive -Path $Zip -DestinationPath $Extract -Force
$V2D = Get-ChildItem "$Extract\*\Ventoy2Disk.exe" | Select-Object -First 1

# 3. install ventoy
status "installing ventoy to drive ${DriveLetter}:\ (this may take a few moments)..." "step"
$ArgList = "VTOYCLI /I /Drive:${DriveLetter}"
$Process = Start-Process -FilePath $V2D.FullName -ArgumentList $ArgList -NoNewWindow -Wait -PassThru

status "waiting for ventoy volume to initialize..." "info"
Start-Sleep -Seconds 12

$VentoyVol = Get-Volume | Where-Object { $_.FileSystemLabel -match "Ventoy" } | Select-Object -First 1
if (-not $VentoyVol) {
    status "ventoy installation volume not found. creating config locally as fallback." "fail"
    $BuildDir = "$PSScriptRoot\ventoy-albus-usb"
} else {
    $BuildDir = "$($VentoyVol.DriveLetter):\"
    status "ventoy successfully installed. config will be applied to $($BuildDir)" "done"
}

# 4. write albus config
status "writing albus zero-touch xml configuration..." "step"

if (-not (Test-Path $BuildDir)) { New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null }
New-Item -Path "$BuildDir\ventoy\albus" -ItemType Directory -Force | Out-Null
New-Item -Path "$BuildDir\ISOs" -ItemType Directory -Force | Out-Null

$VentoyJson = @'
{
  "auto_install": [
    {
      "parent": "/ISOs",
      "template": ["/ventoy/albus/autounattend.xml"],
      "autosel": 1
    }
  ]
}
'@
$VentoyJson | Set-Content -Path "$BuildDir\ventoy\ventoy.json" -Encoding UTF8

$AutoUnattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Reseal>
                <Mode>OOBE</Mode>
            </Reseal>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Home</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Group>Administrator</Group>
                        <Name>Albus</Name>
                        <Password>
                            <PlainText>true</PlainText>
                            <Value></Value>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Enabled>true</Enabled>
                <LogonCount>9999999</LogonCount>
                <Username>Albus</Username>
                <Password>
                    <PlainText>true</PlainText>
                    <Value></Value>
                </Password>
            </AutoLogon>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>Albus Playbook Shortcut.</Description>
                    <CommandLine>powershell -NoProfile -Command "$wshell = New-Object -ComObject WScript.Shell; $s = $wshell.CreateShortcut('C:\Users\Public\Desktop\Albus-PB.lnk'); $s.TargetPath = 'powershell.exe'; $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command &quot;irm https://raw.githubusercontent.com/oqullcan/albuswin/refs/heads/main/run.ps1 | iex&quot;'; $s.IconLocation = 'powershell.exe,0'; $s.Save()"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-SQMApi" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <CEIPEnabled>0</CEIPEnabled>
        </component>
        <component name="Microsoft-Windows-ErrorReportingCore" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DisableWER>1</DisableWER>
        </component>
        <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SkipAutoActivation>true</SkipAutoActivation>
        </component>
        <component name="Microsoft-Windows-UnattendedJoin" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <Identification>
                <JoinWorkgroup>WORKGROUP</JoinWorkgroup>
            </Identification>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>net accounts /maxpwage:unlimited</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Control\BitLocker" /v "PreventDeviceEncryption" /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Update" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\PolicyManager\default\Update" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>6</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v "ExcludeWUDriversInQualityUpdate" /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>7</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\PolicyManager\default\Update\ExcludeWUDriversInQualityUpdate" /v "value" /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>8</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeviceMetadata" /v "PreventDeviceMetadataFromNetwork" /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>9</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" /v "SearchOrderConfig" /t REG_DWORD /d 0 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>10</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" /v "DontSearchWindowsUpdate" /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>11</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v "NoAutoUpdate" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>12</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "FlightSettingsMaxPauseDays" /t REG_DWORD /d "5269" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>13</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseFeatureUpdatesStartTime" /t REG_SZ /d "2023-08-17T12:47:51Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>14</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseFeatureUpdatesEndTime" /t REG_SZ /d "2038-01-19T03:14:07Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>15</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseQualityUpdatesStartTime" /t REG_SZ /d "2023-08-17T12:47:51Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>16</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseQualityUpdatesEndTime" /t REG_SZ /d "2038-01-19T03:14:07Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>17</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseUpdatesStartTime" /t REG_SZ /d "2023-08-17T12:47:51Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>18</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v "PauseUpdatesExpiryTime" /t REG_SZ /d "2038-01-19T03:14:07Z" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>19</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PreviewBuilds" /v "EnableConfigFlighting" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>20</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Services\DiagTrack" /v "Start" /t REG_DWORD /d "4" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>22</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>23</Order><Path>reg add "HKCU\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>24</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>25</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>26</Order><Path>reg add "HKLM\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v "AllowTelemetry" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>27</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\PolicyManager\default\System\AllowTelemetry" /v "value" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>28</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\DevicePolicy\AllowTelemetry" /v "DefaultValue" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>29</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CPSS\Store\AllowTelemetry" /v "Value" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>30</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowCommercialDataPipeline" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>31</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowDeviceNameInTelemetry" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>32</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "DisableEnterpriseAuthProxy" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>33</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "MicrosoftEdgeDataOptIn" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>34</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "DisableTelemetryOptInChangeNotification" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>35</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "DisableTelemetryOptInSettingsUx" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>36</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "DoNotShowFeedbackNotifications" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>37</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "LimitEnhancedDiagnosticDataWindowsAnalytics" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>38</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "AllowBuildPreview" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>39</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "LimitDiagnosticLogCollection" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>40</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v "LimitDumpCollection" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>41</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\System" /v "AllowExperimentation" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>42</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Control\WMI\Autologger\Diagtrack-Listener" /v "Start" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>43</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Control\WMI\Autologger\SQMLogger" /v "Start" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>44</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Control\WMI\Autologger\SetupPlatformTel" /v "Start" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>45</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Control\Session Manager" /v "DisableWpbtExecution" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>46</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Control\CI\Policy" /v "VerifiedAndReputablePolicyState" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>47</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "AutoApproveOSDumps" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>48</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "LoggingDisabled" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>49</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>50</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" /v "Disabled" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>51</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\Consent" /v "DefaultConsent" /t REG_DWORD /d "0" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>52</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\Consent" /v "DefaultOverrideBehavior" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>53</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "DontSendAdditionalData" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>54</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" /v "DontShowUI" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>55</Order><Path>reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting\Consent" /v "0" /t REG_SZ /d "" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>56</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules" /v "Block-Unified-Telemetry-Client" /t REG_SZ /d "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>57</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Services\SharedAccess\Defaults\FirewallPolicy\FirewallRules" /v "Block-Windows-Error-Reporting" /t REG_SZ /d "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Error-Reporting|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>58</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules" /v "Block-Unified-Telemetry-Client" /t REG_SZ /d "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=DiagTrack|Name=Block-Unified-Telemetry-Client|Desc=Block-Unified-Telemetry-Client|EmbedCtxt=DiagTrack|" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>59</Order><Path>reg add "HKLM\SYSTEM\ControlSet001\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules" /v "Block-Windows-Error-Reporting" /t REG_SZ /d "v2.31|Action=Block|Active=TRUE|Dir=Out|RA42=IntErnet|RA62=IntErnet|App=%SystemRoot%\system32\svchost.exe|Svc=WerSvc|Name=Block-Unified-Error-Reporting|Desc=Block-Windows-Error-Reporting|EmbedCtxt=WerSvc|" /f</Path></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>60</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "MSAOptional" /t REG_DWORD /d "1" /f</Path></RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassSecureBootCheck" /t REG_DWORD /d 1 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassTPMCheck" /t REG_DWORD /d 1 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassCPUCheck" /t REG_DWORD /d 1 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassRAMCheck" /t REG_DWORD /d 1 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassStorageCheck" /t REG_DWORD /d 1 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>6</Order><Path>reg add "HKLM\SYSTEM\Setup\MoSetup" /v "AllowUpgradesWithUnsupportedTPMOrCPU" /t REG_DWORD /d 1 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>7</Order><Path>reg add "HKCU\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>8</Order><Path>reg add "HKCU\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>9</Order><Path>reg add "HKU\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV1" /t REG_DWORD /d 0 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>10</Order><Path>reg add "HKU\.DEFAULT\Control Panel\UnsupportedHardwareNotificationCache" /v "SV2" /t REG_DWORD /d 0 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add"><Order>11</Order><Path>reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d 1 /f</Path><Description>Bypass requirements for Windows 11 installation, most of them are only for boot.wim</Description></RunSynchronousCommand>
            </RunSynchronous>
            <Diagnostics>
                <OptIn>false</OptIn>
            </Diagnostics>
            <DynamicUpdate>
                <Enable>false</Enable>
                <WillShowUI>Never</WillShowUI>
            </DynamicUpdate>
            <UserData>
                <ProductKey>
                    <Key></Key>
                    <WillShowUI>Never</WillShowUI>
                </ProductKey>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
    </settings>
</unattend>
'@
$AutoUnattendXml | Set-Content -Path "$BuildDir\ventoy\albus\autounattend.xml" -Encoding UTF8

status "operation completed successfully." "done"
status "ventoy & albus usb is ready for deployment." "done"
if ($VentoyVol) {
    status "please place your windows .iso files into $($BuildDir)isos" "info"
} else {
    status "config was placed in $BuildDir. move folders to your ventoy root." "info"
}

Write-Host ""
status "cleaning up temporary files..." "info"
if (Test-Path $Zip) { Remove-Item -Path $Zip -Force -ErrorAction SilentlyContinue }
if (Test-Path $Extract) { Remove-Item -Path $Extract -Recurse -Force -ErrorAction SilentlyContinue }
if ($VentoyVol -and (Test-Path "$PSScriptRoot\Ventoy-Albus-USB")) { Remove-Item -Path "$PSScriptRoot\Ventoy-Albus-USB" -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
status "exiting in 10 seconds..." "info"
Start-Sleep -Seconds 10
Exit
