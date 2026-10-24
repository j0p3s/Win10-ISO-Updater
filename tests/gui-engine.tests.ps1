$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" -ForegroundColor Green } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n" -ForegroundColor Red; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_t3_' + [guid]::NewGuid().ToString('N').Substring(0,6)); New-Item -ItemType Directory $tmp | Out-Null
$env:SystemDrive = $tmp
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:BootClasses = @('SCSIAdapter','HDC','Net')
$Script:Root = $tmp; $ToolsDir = Join-Path $tmp 'tools'; $Script:SignDir = Join-Path $tmp 'signing'
$Script:SettingsFile = Join-Path $tmp 'settings.json'
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = ''; Result = $null })
function Drain { $o = @(); $it = $null; while ($Script:Sync.Queue.TryDequeue([ref]$it)) { $o += ,$it }; return ,$o }

# --- output sink
Write-Ok 'hello'; Write-Warn 'careful'; Write-Host 'progress 5/9' -NoNewline
$q = Drain
Check 'Write-Ok/Warn land in the GUI queue with colors' ($q.Count -eq 2 -and $q[0][0] -eq 'Green' -and $q[0][1] -match 'hello' -and $q[1][0] -eq 'Yellow')
Check '-NoNewline goes to the status line' ($Script:Sync.Status -eq 'progress 5/9')
Check 'Read-YesNo outside the worker returns the default' ((Read-YesNo 'x' $false) -eq $false)

# --- live process output
Push-ExeLine '[==========================45.0%                          ]'
Check 'DISM progress bar -> 45%' ($Script:Sync.Pct -eq 45)
Push-ExeLine '######################################################################## 100.0%'
Check 'curl progress bar -> 100%' ($Script:Sync.Pct -eq 100)
Push-ExeLine 'Error: 0x800f081e'; Push-ExeLine 'The operation completed successfully.'
$q = Drain
Check 'error lines red, others dim' ($q.Count -eq 2 -and $q[0][0] -eq 'Red' -and $q[1][0] -eq 'DarkGray')
$code = Invoke-Exe '/bin/sh' '-c "printf ''start\r[==  10.0%%  ]\r[==== 55.5%% ]\r\nline two\n''; echo oops 1>&2; exit 3"'
$q = Drain
Check "Invoke-Exe exit code 3 ($code)" ($code -eq 3)
Check 'Invoke-Exe streams lines + stderr, progress not logged' (($q | % { $_[1].Trim() }) -join '|' -eq 'start|line two|oops')
Check 'progress reset after the process' ($Script:Sync.Pct -eq -1)

# --- settings / state with the new keys
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'
Check 'new setting SignCleanup defaults on' ($Script:Cfg.SignCleanup -eq $true)
Initialize-Paths
$Script:S = New-State
Check 'new state keys' ($Script:S.Contains('Signed') -and $Script:S.Contains('Oem') -and $Script:S.Contains('OemSynced') -and $Script:P.Signed)
$Script:S.Signed = @([ordered]@{ Name = 'NVIDIA'; Path = 'x'; InstallDir = 'C:\Drivers\NVIDIA'; Signed = 2; Failed = 0 })
Save-State; $Script:S = Import-State; Save-State; $Script:S = Import-State
Check 'Signed list survives two JSON round trips' (@($Script:S.Signed).Count -eq 1 -and $Script:S.Signed[0].Name -eq 'NVIDIA')

# --- re-signing with fake Inf2Cat / signtool
$pkg = Join-Path $tmp 'nv'
foreach ($d in 'Display.Driver','HDAudio','PhysX','NVI2') { New-Item -ItemType Directory -Force (Join-Path $pkg $d) | Out-Null }
Set-Content (Join-Path $pkg 'Display.Driver/nv_disp.inf') "[Version]`nCatalogFile=nv_disp.cat`n"           # edited -> old catalog no longer valid
Set-Content (Join-Path $pkg 'Display.Driver/nv_disp.cat') 'old-whql'
Set-Content (Join-Path $pkg 'HDAudio/nvhda.inf') "[Version]`nCatalogFile = nvhda.cat ; c`n"             # untouched, valid
Set-Content (Join-Path $pkg 'HDAudio/nvhda.cat') 'signed-whql'
Set-Content (Join-Path $pkg 'NVI2/x.inf') "[Version]`nSignature=x`n"                                  # no CatalogFile line
$Script:SignTool = "$PSScriptRoot/fake/signtool"
$res = Invoke-SignFolder $pkg ([pscustomobject]@{ Thumbprint = 'AB' }) "$PSScriptRoot/fake/inf2cat" $false
Check "only the modified package is re-signed (signed=$($res.Signed) untouched=$($res.Untouched) skipped=$($res.Skipped) failed=$($res.Failed))" ($res.Signed -eq 1 -and $res.Untouched -eq 1 -and $res.Skipped -eq 1 -and $res.Failed -eq 0)
Check 'new catalog signed' ((Get-Content (Join-Path $pkg 'Display.Driver/nv_disp.cat') -Raw) -match '^signed')
Check 'valid catalog left alone' ((Get-Content (Join-Path $pkg 'HDAudio/nvhda.cat') -Raw) -match 'signed-whql')
$res2 = Invoke-SignFolder $pkg ([pscustomobject]@{ Thumbprint = 'AB' }) "$PSScriptRoot/fake/inf2cat" $true
Check "'re-sign every package' signs both ($($res2.Signed))" ($res2.Signed -eq 2)
$null = Drain

# --- SetupComplete-drivers.cmd
$sc = New-SetupCompleteDrivers @([ordered]@{ Name = 'NVIDIA'; InstallDir = 'C:\Drivers\NVIDIA' }) $true
Check 'trusts cert then installs with pnputil, CRLF' ($sc -match 'certutil -addstore -f Root "%CER%"' -and $sc -match 'certutil -addstore -f TrustedPublisher' -and
    $sc -match [regex]::Escape('pnputil /add-driver "%SystemDrive%\Drivers\NVIDIA\*.inf" /subdirs /install') -and $sc -match [regex]::Escape('rd /s /q "%SystemDrive%\Drivers\NVIDIA"') -and $sc -match "`r`n")
Check 'trust lines come before pnputil' ($sc.IndexOf('TrustedPublisher') -lt $sc.IndexOf('pnputil'))
$sc2 = New-SetupCompleteDrivers @([ordered]@{ Name = 'NVIDIA'; InstallDir = 'C:\Drivers\NVIDIA' }) $false
Check 'cleanup off keeps the files' ($sc2 -notmatch 'rd /s /q')

# --- $OEM$ assembly on the media
New-Item -ItemType Directory -Force (Join-Path $Script:P.Media 'sources') | Out-Null
$user = Join-Path $tmp 'mine/$OEM$'
$scDirName = '$$\Setup\Scripts'   # literal name on Linux, a path on Windows
New-Item -ItemType Directory -Force (Join-Path $user '$1/Drivers/Laptop'), (Join-Path $user $scDirName) | Out-Null
Set-Content (Join-Path $user '$1/Drivers/Laptop/a.inf') 'x'
[IO.File]::WriteAllText((Join-Path (Join-Path $user $scDirName) 'SetupComplete.cmd'), "@echo off`r`necho mine`r`n")
New-Item -ItemType Directory -Force $Script:SignDir | Out-Null; Set-Content (Join-Path $Script:SignDir 'DriverSigning.cer') 'cer'
$Script:S = New-State
Set-OemFolder (Join-Path $tmp 'mine')
Check 'parent folder -> its $OEM$ subfolder is used' ($Script:S.Oem.Source -like '*mine*$OEM$')
$Script:S.Signed = @([ordered]@{ Name = 'NVIDIA'; Path = $pkg; InstallDir = 'C:\Drivers\NVIDIA' })
Sync-Oem
$oem = Join-Path $Script:P.Media 'sources/$OEM$'
Check 'your $OEM$ copied' (Test-Path (Join-Path $oem '$1/Drivers/Laptop/a.inf'))
$rel = 'Drivers\NVIDIA'
$found = @(Get-ChildItem -Recurse -File $oem | ? { $_.Name -eq 'nv_disp.inf' }).Count
Check 'signed package copied into $1' ($found -eq 1)
$main = Get-ChildItem -Recurse -File $oem | ? { $_.Name -eq 'SetupComplete.cmd' } | Select-Object -First 1
$lines = [IO.File]::ReadAllLines($main.FullName)
Check "your SetupComplete.cmd calls the driver script right after @echo off ($($lines -join ' | '))" ($lines[0] -eq '@echo off' -and $lines[1] -eq 'call "%~dp0SetupComplete-drivers.cmd"' -and $lines[2] -eq 'echo mine')
Check 'original $OEM$ untouched' (([IO.File]::ReadAllText((Join-Path (Join-Path $user $scDirName) 'SetupComplete.cmd'))) -notmatch 'SetupComplete-drivers')
Sync-Oem
$lines = [IO.File]::ReadAllLines(($(Get-ChildItem -Recurse -File $oem | ? { $_.Name -eq 'SetupComplete.cmd' } | Select-Object -First 1)).FullName)
Check 'second sync does not add the call twice' (@($lines | ? { $_ -match 'SetupComplete-drivers' }).Count -eq 1)
Check 'cer + driver script on the media' ((@(Get-ChildItem -Recurse -File $oem | ? { $_.Name -in 'DriverSigning.cer','SetupComplete-drivers.cmd' }).Count) -eq 2)
$Script:S.Signed = @(); Set-OemFolder $null; Sync-Oem
Check 'removing both takes $OEM$ out of the media' (-not (Test-Path $oem) -and -not $Script:S.OemSynced)

# --- tables for the grids
Add-Type -AssemblyName System.Data
$t = New-Table @('Use:bool','No:int','Class','SizeMB:dbl') @(, @($true, 1, 'Display', 3.5))
Check 'New-Table single row keeps types' ($t.Rows.Count -eq 1 -and $t.Rows[0]['Use'] -eq $true -and $t.Columns['SizeMB'].DataType -eq [double])
$t2 = New-Table @('Use:bool','No:int','Class') @(foreach ($i in 1..3) { , @($false, $i, "C$i") })
$t2.DefaultView.RowFilter = "Class LIKE '*2*'"
Check 'row filter works' ($t2.DefaultView.Count -eq 1)
$t0 = New-Table @('A','B') @()
Check 'empty table' ($t0.Rows.Count -eq 0)

Remove-Item $tmp -Recurse -Force
Microsoft.PowerShell.Utility\Write-Host ''
if ($fails) { Microsoft.PowerShell.Utility\Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Microsoft.PowerShell.Utility\Write-Host 'ALL V2 TESTS PASSED' -ForegroundColor Green; exit 0 }
