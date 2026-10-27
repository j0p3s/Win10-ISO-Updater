$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$Script:X(Res|Main|Pages)$'}, $true)) { . ([scriptblock]::Create($a.Extent.Text)) }
Add-Type -AssemblyName System.Data
function New-Brush([string]$Hex) { $Hex }
function Get-CertStatus { 'create' }
# behave like Windows PowerShell 5.1: a JSON array comes back as ONE object
function ConvertFrom-Json { param([Parameter(ValueFromPipeline)]$InputObject) process { Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $InputObject -NoEnumerate } }
function Confirm-Ui { $true }
function Start-Work($Job, $A, $Then) { $Script:Started = @{ Job = $Job; A = $A } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'w10u_t6'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $tmp | Out-Null
${env:ProgramFiles(x86)} = $tmp; $env:SystemRoot = $tmp; $env:SystemDrive = $tmp; $ToolsDir = Join-Path $tmp 'tools'; $Script:SignDir = Join-Path $tmp 'signing'; $Script:Dism = 'dism.exe'
$Script:BootClasses = @('SCSIAdapter','HDC','Net'); $Script:SettingsFile = Join-Path $tmp 's.json'
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') })
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'; Initialize-Paths
$Script:CfgToggles = @('KeepOnlySelected','NetFx3','NetFx481','ResetBase','BootDrivers','ForceUnsigned','NoPrompt','Boot2023','SplitFat32','SignCleanup','InstallOemDrivers')
# every control in the window as a plain object
$x = $Script:XMain.Replace('__PAGES__', $Script:XPages)
$Script:U = @{}
foreach ($m in [regex]::Matches($x, 'x:Name="([^"]+)"')) { $Script:U[$m.Groups[1].Value] = [pscustomobject]@{ Text=''; ItemsSource=$null; IsChecked=$false; BorderBrush=$null; Foreground=$null; IsEnabled=$true; Content=''; Visibility='' } }
# a state like the user's: updates downloaded, drivers, a signed package, check results
$S = New-State
$S.Unpacked = $true; $S.SourceIso = 'E:\ISO\win10.iso'
$S.Family = [ordered]@{ Arch='x64'; Supported=$true; Name='Windows 10 22H2'; Cap='2025-10'; NeedsEkb=$false }
$S.Images = @([ordered]@{ Index=1; Name='Windows 10 Pro'; Edition='Professional'; Version='19045.6456'; Size=1GB; Langs='en-US' })
$S.Selected = @(1)
$S.Updates = @([ordered]@{ Kind='LCU'; KB='KB5066791'; Date='2025-10-14'; Title='2025-10 CU'; Files=@() }, [ordered]@{ Kind='NET'; KB='KB5066747'; Date='2025-10-14'; Title='.NET'; Files=@() })
$S.Drivers = @([ordered]@{ Source='host'; Folder='host\a'; Inf='a.inf'; Class='Net'; Provider='Intel'; Version='1'; SizeMB=2.5 })
$S.Signed = @([ordered]@{ Name='NVIDIA'; Path='x'; InstallDir='C:\Drivers\NVIDIA'; Signed=3; Failed=0; When='now'; Source='C:\nv' })
$S.Check = [ordered]@{ When='now'; Errors=1; Warnings=2; Passed=5 }
$Script:S = $S; Save-State; $Script:S = Import-State
ConvertTo-Json -InputObject @(
  [pscustomobject]@{ Level='Error'; Area='Answer file'; Finding='x'; Fix='arch=amd64'; FixText='fix arch' },
  [pscustomobject]@{ Level='Error'; Area='Answer file'; Finding='y'; Fix='order'; FixText='renumber' },
  [pscustomobject]@{ Level='Warning'; Area='Scripts'; Finding='z'; Fix=''; FixText='Remove the prompts' }) -Depth 3 | Set-Content (Join-Path $Script:P.Work 'install-check.json')
Update-Ui
Check 'updates list filled (no $u / $U clash)' ($Script:U.UpdGrid.ItemsSource.Count -eq 2)
Check 'drivers list filled' ($Script:U.DrvGrid.ItemsSource.Count -eq 1)
Check 'signed packages list filled' ($Script:U.SignGrid.ItemsSource.Count -eq 1)
Check 'check list: one row per finding with PS 5.1 JSON' ($Script:U.ChkGrid.ItemsSource.Count -eq 3 -and $Script:U.ChkFix.Content -eq 'Apply 2 fix(es)')
$v = $Script:U.ChkGrid.ItemsSource
Check 'check rows hold text, not System.Object[]' ($v[0].Row['Level'] -eq 'Error' -and $v[1].Row['Area'] -eq 'Answer file')
Invoke-FixClick
Check 'Apply sends each fix separately' (($Script:Started.A.Fixes -join '|') -eq 'arch=amd64|order')
Check 'sidebar status lines' ($Script:U.S3.Text -like 'KB5066791*' -and $Script:U.S5.Text -eq 'NVIDIA' -and $Script:U.S8.Text -like '1 error*')
# the taskbar button follows the progress bar; keep-awake and the taskbar flash are harmless where Windows is missing
$Script:W = [pscustomobject]@{ TaskbarItemInfo = [pscustomobject]@{ ProgressState = 'None'; ProgressValue = 0.0 }; IsActive = $false }
$Script:U.Prog | Add-Member -NotePropertyMembers @{ IsIndeterminate = $true; Value = 0.0 } -Force
$Script:Busy = $true; $Script:JobLabel = 'Slipstream'; $Script:JobStart = Get-Date; $Script:Handle = [pscustomobject]@{ IsCompleted = $false }
$Script:Sync.Pct = 42.0; $Script:Sync.Status = 'install.wim'
Invoke-Tick
$tb = $Script:W.TaskbarItemInfo
Check 'taskbar shows the job percentage' ($tb.ProgressState -eq 'Normal' -and [math]::Abs($tb.ProgressValue - 0.42) -lt 0.0001 -and $Script:U.Prog.Value -eq 42.0)
$Script:Sync.Pct = -1
Invoke-Tick
Check 'taskbar is indeterminate without a percentage' ($tb.ProgressState -eq 'Indeterminate' -and $Script:U.Prog.IsIndeterminate)
$Script:Sync.SideSync = @([hashtable]::Synchronized(@{ Label = 'boot.wim 1/2 cumulative update'; Pct = 45.0 }), [hashtable]::Synchronized(@{ Label = 'WinRE cleanup'; Pct = -1 }))
Invoke-Tick
Check "status line shows every background job ($($Script:U.StatusText.Text))" ($Script:U.StatusText.Text -match '\|    boot\.wim 1/2 cumulative update 45%    \|    WinRE cleanup$')
$Script:Sync.SideSync = $null
$ok = $true
try { Set-KeepAwake $true; Set-KeepAwake $false; Request-Attention; $Script:W = $null; Set-TaskbarState 'Error' 1 } catch { $ok = $false }
Check 'keep-awake, taskbar flash and a window without a taskbar button never throw' $ok
Remove-Item $tmp -Recurse -Force
if ($fails) { exit 1 }
exit 0
