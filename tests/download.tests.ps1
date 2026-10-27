$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$bodyFile = "$PSScriptRoot/v2body.ps1"
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($bodyFile,[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
$body = [IO.File]::ReadAllText($bodyFile)
$b = $body.IndexOf('#ENGINE-BEGIN'); $e = $body.IndexOf('#ENGINE-END')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_dl_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory $tmp | Out-Null
$env:SystemDrive = $tmp; $env:SystemRoot = $tmp; $env:W10U_DL = $tmp; $env:W10U_SELF = Join-Path $tmp 'Win10-ISO-Updater.cmd'
# stand-ins for the catalog (main job and side job): each lookup and download leaves a timestamped line
$stubs = @'

function Mark([string]$What) { Add-Content -LiteralPath (Join-Path $env:W10U_DL 'marks.txt') -Value ('{0} {1}' -f [DateTime]::UtcNow.Ticks, $What) }
function MkHit([string]$Kind, [string]$KB) { [pscustomobject]@{ Guid = [guid]::NewGuid().ToString(); Title = "2025-10 $Kind ($KB)"; KB = $KB; Date = [datetime]'2025-10-14'; Size = '1 MB' } }
function Find-Update([string]$Kind, $Fam, [string]$MaxMonth, [int]$Lookback = 12) {
    if ($Kind -eq 'SSU') {
        Start-Sleep -Milliseconds 2000; Mark 'ssu-found'
        if ($env:W10U_SSU) { return (MkHit 'Servicing Stack Update' $env:W10U_SSU) }
        return
    }
    if ($Kind -eq 'SAFEOS' -and $env:W10U_FAIL) { throw 'Could not reach the Microsoft Update Catalog: timeout' }
    return (MkHit $Kind "KB$Kind")
}
function Find-ByKB([string]$KB, $Fam, [string]$MustMatch) { return (MkHit 'NET481' $KB) }
function Save-UpdateFiles($Hit, [string]$Kind) { Mark "save-$Kind"; return [ordered]@{ Kind = $Kind; KB = $Hit.KB; Title = $Hit.Title; Date = '2025-10-14'; Files = @() } }
'@
$Script:EngineText = $body.Substring($b, $e - $b) + $stubs
. ([scriptblock]::Create($stubs))
function Assert-Analyzed { }
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = ''; Result = $null })
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:SettingsFile = Join-Path $tmp 'settings.json'
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'
Initialize-Paths
New-Item -ItemType Directory -Force $Script:P.Logs | Out-Null
$Script:LogFile = Join-Path $Script:P.Logs 'engine.log'
function Drain { $it = $null; $l = @(); while ($Script:Sync.Queue.TryDequeue([ref]$it)) { $l += $it[1] }; return $l }
function Marks { @(Get-Content (Join-Path $tmp 'marks.txt') | ForEach-Object { $p = $_ -split ' ', 2; [pscustomobject]@{ T = [long]$p[0]; What = $p[1] } }) }
function New-Run {
    Remove-Item (Join-Path $tmp 'marks.txt') -ErrorAction SilentlyContinue
    $Script:S = New-State
    $Script:S.Unpacked = $true
    $Script:S.Family = Resolve-Family @([ordered]@{ Index = 1; Name = 'Windows 10 Pro'; Edition = 'Professional'; Build = 19045; Revision = 6456; Version = '19045.6456'; Arch = 'x64'; Size = 1; Langs = 'en-US' })
}

# ---- the servicing stack lookup (36 months of the catalog) runs while the rest is looked up and downloaded
New-Run
$env:W10U_SSU = 'KB5050000'
Invoke-Download -Auto
$m = Marks; $log = @(Drain)
$ssuAt = ($m | Where-Object What -eq 'ssu-found').T
$lcuAt = ($m | Where-Object What -eq 'save-LCU').T
$saved = @($m | Where-Object { $_.What -like 'save-*' } | ForEach-Object { $_.What })
Check 'servicing stack looked up in a side job' (@($log | Where-Object { $_ -match 'Servicing stack lookup: background job finished after' }).Count -eq 1)
Check 'the cumulative update was downloaded while the lookup was still running' ($lcuAt -gt 0 -and $lcuAt -lt $ssuAt)
Check "every update downloaded, the SSU after its lookup ($($saved -join ', '))" (($saved -join ',') -eq 'save-LCU,save-SAFEOS,save-SETUP,save-NET481,save-NET,save-SSU' -and ($m | Where-Object What -eq 'save-SSU').T -gt $ssuAt)
$kinds = @($Script:S.Updates | ForEach-Object { $_.Kind })
Check "state has every update incl. the SSU ($($kinds -join ','))" ($kinds -contains 'SSU' -and $kinds.Count -eq 6 -and (Import-State).Updates.Count -eq 6)
Check 'side status cleared, no side log left behind' ($null -eq $Script:Sync.SideSync -and -not (Test-Path (Join-Path $Script:P.Logs 'engine-ssu.log')))

# ---- no standalone SSU (the usual case)
New-Run
$env:W10U_SSU = ''
Invoke-Download -Auto
$log = @(Drain)
Check 'no SSU: noted, nothing extra downloaded' (@($log | Where-Object { $_ -match 'None needed - the LCU carries the servicing stack' }).Count -eq 1 -and @($Script:S.Updates | Where-Object { $_.Kind -eq 'SSU' }).Count -eq 0 -and @($Script:S.Updates).Count -eq 5)

# ---- a lookup in the main job fails: the side job is stopped, the error comes through
New-Run
$env:W10U_FAIL = '1'
$msg = $null
try { Invoke-Download -Auto } catch { $msg = $_.Exception.Message }
$env:W10U_FAIL = ''
$null = Drain
Check "catalog error reported ($msg)" ($msg -match 'Could not reach the Microsoft Update Catalog')
Check 'side job stopped and cleaned up after the error' ($null -eq $Script:Sync.SideSync -and -not (Test-Path (Join-Path $Script:P.Logs 'engine-ssu.log')))

Remove-Item Env:\W10U_SSU, Env:\W10U_FAIL, Env:\W10U_DL -ErrorAction SilentlyContinue
Remove-Item $tmp -Recurse -Force
if ($fails) { exit 1 }
exit 0
