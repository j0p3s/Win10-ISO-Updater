$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" -ForegroundColor Green } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n" -ForegroundColor Red; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$Script:(UnattendNs|WcmNs|GenericKeys|InstallerRx|BadSign|CertSubject)$'}, $true)) { . ([scriptblock]::Create($a.Extent.Text)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_t9_' + [guid]::NewGuid().ToString('N').Substring(0,6)); New-Item -ItemType Directory $tmp | Out-Null
$env:SystemDrive = $tmp; $Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:Root = $tmp; $ToolsDir = Join-Path $tmp 'tools'; $Script:SignDir = Join-Path $tmp 'signing'; $Script:SettingsFile = Join-Path $tmp 's.json'
$Script:BootClasses = @('SCSIAdapter','HDC','Net')
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = '' })
function Find-Tool { $null }
function Test-FirmwareOemKey { $false }
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'; Initialize-Paths
$Script:S = New-State
$Script:S.Unpacked = $true
$Script:S.Family = [ordered]@{ Arch = 'x64'; Supported = $true; Name = 'Windows 10 22H2' }
$names = 'Home','Home N','Home Single Language','Education','Education N','Pro','Pro N','Pro Education','Pro Education N','Pro for Workstations','Pro N for Workstations'
$eds = 'Core','CoreN','CoreSingleLanguage','Education','EducationN','Professional','ProfessionalN','ProfessionalEducation','ProfessionalEducationN','ProfessionalWorkstation','ProfessionalWorkstationN'
$i = 0; $Script:S.Images = @(foreach ($n in $names) { $i++; [ordered]@{ Index = $i; Name = "Windows 10 $n"; Edition = $eds[$i-1]; Arch = 'x64'; Langs = 'en-US'; Version = '19045.6456'; Size = 1 } })
$Script:S.Selected = @(1..11)
New-Item -ItemType Directory -Force $Script:P.Work | Out-Null
Copy-Item "$PSScriptRoot/fixtures/generator-autounattend.xml" $Script:P.Unattend
$Script:S.Unattend = [ordered]@{ Source = 'C:\Users\User\Desktop\autounattend.xml'; Added = 'x' }
# his $OEM$: SetupComplete.cmd calling a big menu script with a switch, plus one without
$oem = Join-Path $tmp 'Desktop/$OEM$'; New-Item -ItemType Directory -Force (Join-Path $oem '$$/Setup/Scripts') | Out-Null
[IO.File]::WriteAllText((Join-Path $oem '$$/Setup/Scripts/SetupComplete.cmd'), "@echo off`r`ncall `"%~dp0Menu_AIO.cmd`" /AUTO`r`ncall `"%~dp0Ask.cmd`"`r`nexit /b 0`r`n")
[IO.File]::WriteAllText((Join-Path $oem '$$/Setup/Scripts/Menu_AIO.cmd'), "@echo off`r`nif /i `"%1`"==`"/AUTO`" goto :auto`r`nchoice /C:12 /N`r`nset /p x=`r`n%SystemRoot%\Sysnative\reg.exe add x`r`n%SystemRoot%\Temp\%rnd%\a.txt`r`n:auto`r`nexit /b`r`n")
[IO.File]::WriteAllText((Join-Path $oem '$$/Setup/Scripts/Ask.cmd'), "@echo off`r`npause`r`n")
$Script:S.Oem = [ordered]@{ Source = $oem }
# signed NVIDIA package containing setup.exe, delete-copy option on (default)
$pkg = Join-Path $tmp 'work/signed/NVIDIA'; New-Item -ItemType Directory -Force $pkg | Out-Null; Set-Content (Join-Path $pkg 'setup.exe') x
$Script:S.Signed = @([ordered]@{ Name = 'NVIDIA'; Source = 'C:\Users\User\Desktop\NVCleanstall'; Path = $pkg; InstallDir = 'C:\Drivers\NVIDIA'; Signed = 3; Failed = 0 })
New-Item -ItemType Directory -Force $Script:SignDir | Out-Null; Set-Content (Join-Path $Script:SignDir 'DriverSigning.cer') 'x'

$res = @(Invoke-InstallCheck -NoDownload)
$res | % { '{0,-8}{1,-15}{2}' -f $_.Level, $_.Area, (Limit-Text $_.Finding 170) } | Out-File -Width 300 "$PSScriptRoot/findings.txt"
function Has($lvl, $rx) { return @($res | Where-Object { $_.Level -eq $lvl -and $_.Finding -match $rx }).Count -gt 0 }
function FixOf($rx) { return (@($res | Where-Object { $_.Finding -match $rx }) | Select-Object -First 1).Fix }
Check 'no Panther false positive' (-not (Has 'Warning' 'Panther'))
Check 'no Sysnative / Temp false positives' (-not (Has 'Warning' 'Sysnative|\\Temp\\'))
Check 'menu script called with a switch -> Info, not a warning' ((Has 'Info' 'Menu_AIO.cmd.*called with parameters') -and -not (Has 'Warning' 'Menu_AIO'))
Check 'script with pause called without switch -> Warning' (Has 'Warning' 'Ask.cmd.*waits for input')
Check 'embedded scripts checked' (Has 'OK' 'embedded in the answer file were checked')
Check 'firstboot.ps1 uses C:\Drivers\NVIDIA\setup.exe but the copy is deleted -> fix' ((FixOf 'deletes that folder') -eq 'keep-driver-copy')
Check 'specialize fallback offered' ((FixOf 'Windows skips SetupComplete.cmd') -eq 'specialize-drivers')
Check 'no errors in his answer file' (-not (Has 'Error' '.'))
Invoke-InstallFixes @('keep-driver-copy', 'specialize-drivers')
$res = @(Invoke-InstallCheck -NoDownload)
Check 'after fixes: driver copy kept' ((Has 'OK' 'signed copy stays in place') -and $Script:Cfg.SignCleanup -eq $false)
Check 'after fixes: fallback present' (Has 'OK' 'also runs from the specialize pass')
[xml]$fx = Get-Content $Script:P.Unattend -Raw
$ns = New-Object System.Xml.XmlNamespaceManager($fx.NameTable); $ns.AddNamespace('u','urn:schemas-microsoft-com:unattend')
$orders = @($fx.SelectNodes("//u:settings[@pass='specialize']/u:component[@name='Microsoft-Windows-Deployment']/u:RunSynchronous/u:RunSynchronousCommand/u:Order", $ns) | % InnerText) -join ','
Check "his specialize commands kept, ours appended as 4 ($orders)" ($orders -eq '1,2,3,4')
Check 'Extensions block untouched' ($fx.OuterXml -match 'WinTweaks-FirstBoot' -and @($fx.SelectNodes("//*[local-name()='File']")).Count -eq 3)
# package signed with "only this PC's hardware": reported, and firstboot.ps1 running setup.exe from it is flagged
$Script:S.Signed = @([ordered]@{ Name = 'NVIDIA'; Source = 'C:\Users\User\Desktop\NVCleanstall'; Path = $pkg; InstallDir = 'C:\Drivers\NVIDIA'; Signed = 3; Failed = 0
                                 OnlyThisPc = $true; Removed = 42; Kept = @('nvcvi.inf') })
$res = @(Invoke-InstallCheck -NoDownload)
Check 'this-PC-only package reported as Info' (Has 'Info' 'only the INF files for the PC it was signed on were kept \(nvcvi\.inf; 42 removed\)')
Check 'setup.exe from a trimmed package -> warning' (Has 'Warning' "setup\.exe - but NVIDIA only keeps the INF files for this PC")
$Script:S.Signed[0].OnlyThisPc = $false
"warnings left: " +(@($res | ? Level -eq 'Warning' | % { $_.Area + ': ' + (Limit-Text $_.Finding 110) }) -join "`n  ")
Remove-Item $tmp -Recurse -Force
if ($fails) { Microsoft.PowerShell.Utility\Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Microsoft.PowerShell.Utility\Write-Host 'ALL ANSWER-FILE TESTS PASSED' -ForegroundColor Green; exit 0 }
