$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" -ForegroundColor Green } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n" -ForegroundColor Red; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
# top-level engine constants used by the check
foreach ($a in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$Script:(UnattendNs|WcmNs|GenericKeys|InstallerRx|BadSign|CertSubject)$'}, $true)) { . ([scriptblock]::Create($a.Extent.Text)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_t4_' + [guid]::NewGuid().ToString('N').Substring(0,6)); New-Item -ItemType Directory $tmp | Out-Null
$env:SystemDrive = $tmp
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:BootClasses = @('SCSIAdapter','HDC','Net')
$Script:Root = $tmp; $ToolsDir = Join-Path $tmp 'tools'; $Script:SignDir = Join-Path $tmp 'signing'
$Script:SettingsFile = Join-Path $tmp 'settings.json'
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = ''; Result = $null })
$Script:SignToolFake = "$PSScriptRoot/fake/signtool"
function Find-Tool([string]$Name) { if ($Name -eq 'signtool.exe') { return $Script:SignToolFake } }
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'
Initialize-Paths
$Script:S = New-State
New-Item -ItemType Directory -Force (Join-Path $Script:P.Media 'sources') | Out-Null
$Script:S.Unpacked = $true
$Script:S.Family = [ordered]@{ Arch = 'x64'; Supported = $true; Name = 'Windows 10 22H2' }
$Script:S.Images = @(
  [ordered]@{ Index = 1; Name = 'Windows 10 Home'; Edition = 'Core'; Arch = 'x64'; Langs = 'en-US'; Version = '19045.6456'; Size = 1 },
  [ordered]@{ Index = 2; Name = 'Windows 10 Education'; Edition = 'Education'; Arch = 'x64'; Langs = 'en-US'; Version = '19045.6456'; Size = 1 },
  [ordered]@{ Index = 3; Name = 'Windows 10 Pro'; Edition = 'Professional'; Arch = 'x64'; Langs = 'en-US'; Version = '19045.6456'; Size = 1 })
$Script:S.Selected = @(3)          # only Pro kept -> it becomes index 1
$Script:Cfg.KeepOnlySelected = $true

# ---- answer file with typical mistakes (made for the original ISO, index 3 = Pro)
$xml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="x86" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>pt-PT</UILanguage></SetupUILanguage>
      <UILanguage>pt-PT</UILanguage><SystemLocale>pt-PT</SystemLocale><UserLocale>pt-PT</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="x86" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
        <CreatePartitions>
          <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition>
          <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
          <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend><Size>50000</Size></CreatePartition>
        </CreatePartitions></Disk></DiskConfiguration>
      <ImageInstall><OSImage>
        <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>3</Value></MetaData></InstallFrom>
        <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
      </OSImage></ImageInstall>
      <UserData><ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key></ProductKey><AcceptEula>true</AcceptEula></UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="x86" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>MY_GAMING_LAPTOP_P775</ComputerName><TimeZone>Mars Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="x86" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideLocalAccountScreen>true</HideLocalAccountScreen></OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>Administrator</Name><Group>Administrators</Group></LocalAccount>
        <LocalAccount wcm:action="add"><Name>User</Name><Group>Administrators</Group></LocalAccount></LocalAccounts></UserAccounts>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c C:\Scripts\setup.cmd</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c D:\tools\x.cmd</CommandLine></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>cmd /c "%WINDIR%\Setup\Scripts\Tweaks.cmd"</CommandLine></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
'@
New-Item -ItemType Directory -Force $Script:P.Work | Out-Null
[IO.File]::WriteAllText($Script:P.Unattend, $xml)
$Script:S.Unattend = [ordered]@{ Source = 'D:\mine\autounattend.xml'; Added = 'x' }

# ---- $OEM$ with typical mistakes
$oem = Join-Path $tmp 'mine/$OEM$'
foreach ($d in '$1/Drivers/Laptop/Audio', '$1/Drivers/NVIDIA/Display.Driver', '$$/Setup/Scripts', 'Docs') { New-Item -ItemType Directory -Force (Join-Path $oem $d) | Out-Null }
Set-Content (Join-Path $oem '$1/Drivers/Laptop/Audio/rtk.inf') "[Version]`nClass=MEDIA`n[Manufacturer]`nR=R,NTamd64`n"                 # no CatalogFile -> unsigned
Set-Content (Join-Path $oem '$1/Drivers/NVIDIA/Display.Driver/nv_disp.inf') "[Version]`nCatalogFile=nv_disp.cat`n[Manufacturer]`nN=N,NTamd64`n"
Set-Content (Join-Path $oem '$1/Drivers/NVIDIA/Display.Driver/nv_disp.cat') 'whql-but-edited'                                       # mismatch
Set-Content (Join-Path $oem '$1/autounattend.xml') '<unattend/>'
$sc = [byte[]](0xEF,0xBB,0xBF) + [Text.Encoding]::ASCII.GetBytes("@echo off`r`ncall %~dp0missing.cmd`r`npause`r`nshutdown /r /t 0`r`n")
[IO.File]::WriteAllBytes((Join-Path $oem '$$/Setup/Scripts/SetupComplete.cmd'), $sc)
[IO.File]::WriteAllText((Join-Path $oem '$$/Setup/Scripts/Tweaks.cmd'), "@echo off`nreg add x`n")    # LF only
$Script:S.Oem = [ordered]@{ Source = $oem }

$Script:IsWorker = $false
$res = @(Invoke-InstallCheck -NoDownload)
function Has($lvl, $rx) { return @($res | Where-Object { $_.Level -eq $lvl -and $_.Finding -match $rx }).Count -gt 0 }
function FixOf($rx) { return (@($res | Where-Object { $_.Finding -match $rx }) | Select-Object -First 1).Fix }
Check 'arch x86 vs amd64 -> error + fix' ((Has 'Error' 'component\(s\) are for x86') -and (FixOf 'are for x86') -eq 'arch=amd64')
Check 'index 3 (Pro) -> new ISO has 1 edition -> fix index=1' ((Has 'Error' 'installs index 3') -and (FixOf 'installs index 3') -eq 'index=1')
Check 'generic Pro key matches the kept edition' (Has 'OK' 'Generic product key for Professional')
Check 'pt-PT setup language not in en-US ISO -> fix' ((Has 'Error' 'Setup language pt-PT') -and (FixOf 'Setup language') -eq 'lang=en-US')
Check 'computer name too long / underscore -> fix *' ((FixOf 'Computer name') -eq 'computername')
Check 'unknown time zone -> fix to local' ((Has 'Error' 'Mars Standard Time') -and (FixOf 'Mars') -like 'timezone=*')
Check 'reserved account name Administrator' (Has 'Error' 'reserved')
Check 'duplicate Order -> fix order' ((FixOf 'Order') -eq 'order')
Check 'Extend + Size -> fix' ((FixOf 'Extend=true and a Size') -eq 'extendsize')
Check 'WillWipeDisk warning' (Has 'Warning' 'Disk 0 is erased')
Check 'GPT layout info' (Has 'Info' 'GPT')
Check 'missing C:\Scripts\setup.cmd' (Has 'Warning' 'C:\\Scripts\\setup.cmd')
Check 'fixed drive letter D:' (Has 'Warning' 'fixed drive letter \(D:')
Check 'Tweaks.cmd LF line endings found through the answer file' (Has 'Warning' 'Tweaks.cmd.*LF')
Check 'SetupComplete BOM' (Has 'Warning' 'SetupComplete.cmd.*BOM')
Check 'SetupComplete pause' (Has 'Warning' 'waits for input')
Check 'SetupComplete restart' (Has 'Warning' 'restarts the PC')
Check 'SetupComplete calls a missing script' (Has 'Warning' 'missing.cmd')
Check 'ignored top-level folder Docs' (Has 'Warning' 'Folder "Docs"')
Check '$1\autounattend.xml is not used + fix' ((Has 'Warning' 'Setup never reads it') -and (FixOf 'Setup never reads') -like 'use-oem-unattend=*')
Check 'edited NVIDIA INF in $OEM$ -> error' (Has 'Error' 'NVIDIA.*refuse')
Check 'unsigned audio INF -> error' (Has 'Error' 'Audio.*refuse')
Check 'loose drivers -> warning + oem-drivers fix' ((FixOf 'nothing installs them') -eq 'oem-drivers')
Check 'own SetupComplete skipped on OEM-key PCs (info)' (Has 'Info' 'Your own SetupComplete.cmd')
Check 'summary saved to state' ($Script:S.Check.Errors -ge 8)
$before = $res

# ---- the signed copy of the NVIDIA folder now replaces the edited one
$pkg = Join-Path $tmp 'work/signed/NVIDIA'; New-Item -ItemType Directory -Force $pkg | Out-Null
$Script:S.Signed = @([ordered]@{ Name = 'NVIDIA'; Source = (Join-Path $oem '$1/Drivers/NVIDIA'); Path = $pkg; InstallDir = 'C:\Drivers\NVIDIA'; Signed = 1; Failed = 0 })
New-Item -ItemType Directory -Force $Script:SignDir | Out-Null; Set-Content (Join-Path $Script:SignDir 'DriverSigning.cer') 'x'
$res = @(Invoke-InstallCheck -NoDownload)
Check 'signed copy overlays the edited NVIDIA folder -> OK' (Has 'OK' 'NVIDIA.*replaced by your signed copy')
Check 'driver script needs the specialize fallback -> warning + fix' ((FixOf 'Windows skips SetupComplete.cmd') -eq 'specialize-drivers')

# ---- apply every fix, re-check
$fixes = @($res | Where-Object { $_.Fix -and $_.Fix -notlike 'use-oem-unattend=*' } | ForEach-Object { $_.Fix } | Sort-Object -Unique)
Invoke-InstallFixes $fixes
Check 'original kept as backup' (Test-Path (Join-Path $Script:P.Work 'autounattend.original.xml'))
Check 'InstallOemDrivers turned on' ($Script:Cfg.InstallOemDrivers -eq $true)
$res = @(Invoke-InstallCheck -NoDownload)
Check 'arch fixed' (Has 'OK' 'All components are for amd64')
Check 'index fixed' (Has 'OK' 'Installs index 1: Windows 10 Pro')
Check 'language fixed' (Has 'OK' 'Language settings match')
Check 'time zone fixed' (Has 'OK' 'Time zone')
Check 'no order / extend / computer name errors left' (-not (Has 'Error' 'Order|Extend=true|Computer name'))
Check 'specialize fallback present' (Has 'OK' 'also runs from the specialize pass')
Check 'loose drivers now covered' (Has 'OK' 'Every driver folder in \$OEM\$ is installed')
[xml]$fx = Get-Content $Script:P.Unattend -Raw
$ns = New-Object System.Xml.XmlNamespaceManager($fx.NameTable); $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend'); $ns.AddNamespace('wcm','http://schemas.microsoft.com/WMIConfig/2002/State')
$rs = $fx.SelectSingleNode("//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Deployment']/u:RunSynchronous/u:RunSynchronousCommand", $ns)
Check 'RunSynchronousCommand has wcm:action=add, Order 1, Path' ($rs -and $rs.GetAttribute('action','http://schemas.microsoft.com/WMIConfig/2002/State') -eq 'add' -and $rs.SelectSingleNode('u:Order',$ns).InnerText -eq '1' -and $rs.SelectSingleNode('u:Path',$ns).InnerText -match 'SetupComplete-drivers')
$orders = @($fx.SelectNodes('//u:FirstLogonCommands/u:SynchronousCommand/u:Order', $ns) | % InnerText) -join ','
Check "orders renumbered ($orders)" ($orders -eq '1,2,3')
Check 'Size gone from extended partition' (-not $fx.SelectSingleNode("//u:CreatePartition[u:Extend='true']/u:Size", $ns))
Check 'fixed copy still valid unattend xml' ($fx.DocumentElement.LocalName -eq 'unattend')
$d1 = New-SetupCompleteDrivers $Script:S.Signed $true @('Drivers\Laptop')
Check 'driver script: run-once marker, $OEM$ roots, signed package' ($d1 -match 'if exist "%DONE%" exit /b 0' -and $d1 -match [regex]::Escape('pnputil /add-driver "%SystemDrive%\Drivers\Laptop\*.inf"') -and $d1 -match [regex]::Escape('%SystemDrive%\Drivers\NVIDIA\*.inf') -and $d1 -match 'done>"%DONE%"')
$roots = @(Get-OemDriverRoots $oem $Script:S.Signed)
Check "driver roots skip the signed package ($($roots -join ';'))" ($roots.Count -eq 1 -and $roots[0] -eq 'Drivers\Laptop')
Remove-Item $tmp -Recurse -Force
Microsoft.PowerShell.Utility\Write-Host ''
if ($fails) { Microsoft.PowerShell.Utility\Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Microsoft.PowerShell.Utility\Write-Host 'ALL CHECK TESTS PASSED' -ForegroundColor Green; exit 0 }
