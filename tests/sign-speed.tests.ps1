$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
$fnText = @($ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object { $_.Extent.Text })
foreach($f in $fnText){ . ([scriptblock]::Create($f)) }
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = '' })
$Script:SignTool = "$PSScriptRoot/fake/signtool"; $Script:S = @{}
$fake = "$PSScriptRoot/fake/inf2cat"
$cert = [pscustomobject]@{ Thumbprint = 'AB' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_sp_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory $tmp | Out-Null
$ToolsDir = Join-Path $tmp 'tools'
$env:FAKE_INF2CAT_LOG = Join-Path $tmp 'inf2cat.log'; $env:FAKE_SIGNTOOL_LOG = Join-Path $tmp 'signtool.log'
# hard links as on NTFS (CreateHardLink is Windows only)
$Script:Links = 0
function New-HardLink([string]$Link, [string]$Target) { New-Item -ItemType HardLink -Path $Link -Target $Target | Out-Null; $Script:Links++; return $true }
function Drain { $it = $null; $l = @(); while ($Script:Sync.Queue.TryDequeue([ref]$it)) { $l += $it[1] }; return $l }
function Runs { @(if (Test-Path $env:FAKE_INF2CAT_LOG) { Get-Content $env:FAKE_INF2CAT_LOG | ForEach-Object { $p = $_ -split ' ', 4; [pscustomobject]@{ Start = [long]$p[0]; End = [long]$p[1]; Dir = $p[2]; Infs = @(($p[3] -replace '^:\s*', '') -split ' ' | Where-Object { $_ }) } } }) }
function Signs { @(if (Test-Path $env:FAKE_SIGNTOOL_LOG) { Get-Content $env:FAKE_SIGNTOOL_LOG }) }
# an NVIDIA-like package: Display.Driver with one INF (and catalog) per maker, all pointing at the same driver files
function New-Pkg([string]$Name, [hashtable]$Cats, [string[]]$Edited, [string]$Missing = '') {
    $root = Join-Path $tmp $Name
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    $dd = Join-Path $root 'Display.Driver'
    New-Item -ItemType Directory -Force (Join-Path $dd 'bin'), (Join-Path $root 'HDAudio') | Out-Null
    Set-Content (Join-Path $dd 'nvlddmkm.sys') 'driver-binary'; Set-Content (Join-Path $dd 'bin/nvapi64.dll') 'api-binary'
    foreach ($inf in $Cats.Keys) {
        $extra = if ($Missing -and $inf -eq $Edited[0]) { "`n$Missing = 1" } else { '' }
        Set-Content (Join-Path $dd "$inf.inf") "[Version]`nSignature=`"`$Windows NT`$`"`nCatalogFile=$($Cats[$inf])`n[SourceDisksFiles]`nnvlddmkm.sys = 1`nnvapi64.dll = 1,bin$extra`n[Strings]`nX=1"
    }
    foreach ($c in @($Cats.Values | Sort-Object -Unique)) {
        $hit = @($Cats.Keys | Where-Object { $Cats[$_] -eq $c -and $Edited -contains $_ }).Count
        Set-Content (Join-Path $dd $c) $(if ($hit) { 'nvcleanstall-selfsigned' } else { 'signed-whql' })
    }
    Set-Content (Join-Path $root 'HDAudio/nvhda.inf') "[Version]`nCatalogFile=nvhda.cat"; Set-Content (Join-Path $root 'HDAudio/nvhda.cat') 'signed-whql'
    Remove-Item $env:FAKE_INF2CAT_LOG, $env:FAKE_SIGNTOOL_LOG -ErrorAction SilentlyContinue
    return $root
}
$six = @{ nv_dispi = 'nv_dispi.cat'; nvaci = 'nvaci.cat'; nvami = 'nvami.cat'; nvbli = 'nvbli.cat'; nvcvi = 'nvcvi.cat'; nvdmi = 'nvdmi.cat' }
function CatText($Root, $Name) { (Get-Content (Join-Path $Root "Display.Driver/$Name") -Raw).Trim() }

# ---- only the edited INF files are catalogued, in isolated copies, two at the same time
$root = New-Pkg 'iso' $six @('nv_dispi', 'nvaci')
$env:FAKE_INF2CAT_SLOW = '1'
$res = Invoke-SignFolder $root $cert $fake $false $false $true 2
Remove-Item Env:\FAKE_INF2CAT_SLOW
$log = @(Drain); $runs = Runs
"  runs: " + (($runs | ForEach-Object { "$(Split-Path $_.Dir -Leaf):$($_.Infs -join '+') $($_.Start % 100000)-$($_.End % 100000)" }) -join ' | ')
Check "edited package signed, HDAudio untouched (signed=$($res.Signed) untouched=$($res.Untouched) failed=$($res.Failed))" ($res.Signed -eq 1 -and $res.Untouched -eq 1 -and $res.Failed -eq 0)
Check 'two Inf2Cat runs, one edited INF each, in isolated copies' ($runs.Count -eq 2 -and (($runs | ForEach-Object { $_.Infs -join '+' } | Sort-Object) -join ',') -eq 'nv_dispi.inf,nvaci.inf' -and @($runs | Where-Object { $_.Dir -like '*~stage*' }).Count -eq 2)
Check 'the two runs ran at the same time' ($runs.Count -eq 2 -and $runs[0].Start -lt $runs[1].End -and $runs[1].Start -lt $runs[0].End)
Check 'new catalogs for the edited INF files, signed' ((CatText $root 'nv_dispi.cat') -eq 'signed' -and (CatText $root 'nvaci.cat') -eq 'signed')
Check 'the other INF files keep their original catalog' (@('nvami.cat', 'nvbli.cat', 'nvcvi.cat', 'nvdmi.cat' | Where-Object { (CatText $root $_) -eq 'signed-whql' }).Count -eq 4)
Check 'every INF file is still in the package' (@(Get-ChildItem (Join-Path $root 'Display.Driver') -Filter *.inf).Count -eq 6)
Check 'driver files reached Inf2Cat as hard links (2 per copy)' ($Script:Links -eq 4)
Check 'driver files themselves unchanged' ((Get-Content (Join-Path $root 'Display.Driver/nvlddmkm.sys') -Raw).Trim() -eq 'driver-binary' -and (Get-Content (Join-Path $root 'Display.Driver/bin/nvapi64.dll') -Raw).Trim() -eq 'api-binary')
Check 'isolated copies removed afterwards' (-not (Test-Path "$root~stage"))
Check 'both catalogs signed in one signtool call' ((Signs) -join ',' -eq 'sign 2')
Check 'log says which INF files get a new catalog' (@($log | Where-Object { $_ -match '2 of 6 INF file\(s\) get a new catalog - the others keep their signature \(in 2 Inf2Cat runs at the same time\)' }).Count -eq 1)
Check 'log gives the estimated time' (@($log | Where-Object { $_ -match 'Inf2Cat: 2 runs, up to 2 at the same time - estimated time \d+:\d\d:\d\d' }).Count -eq 1)
Check 'result line names the runs and the longest' (@($log | Where-Object { $_ -match 'Display\.Driver signed and verified \(2 Inf2Cat runs, the longest took 0:00:0\d\)' }).Count -eq 1)
Check 'no long-run warning for a few INF files' (@($log | Where-Object { $_ -match 'up to an hour' }).Count -eq 0)
Check 'status line cleared' ($Script:Sync.Status -eq '')

# ---- one run at a time: the edited INF files share one isolated copy
$root = New-Pkg 'iso1' $six @('nv_dispi', 'nvaci', 'nvcvi')
$Script:Links = 0
$res = Invoke-SignFolder $root $cert $fake $false $false $true 1
$null = Drain; $runs = Runs
Check "one job: one isolated run with the three edited INF files (signed=$($res.Signed))" ($res.Signed -eq 1 -and $runs.Count -eq 1 -and $runs[0].Infs.Count -eq 3 -and $runs[0].Dir -like '*~stage*' -and $Script:Links -eq 2)
Check 'one job: the three others keep their catalog' (@('nvami.cat', 'nvbli.cat', 'nvdmi.cat' | Where-Object { (CatText $root $_) -eq 'signed-whql' }).Count -eq 3)

# ---- a catalog shared by an edited and an unedited INF: both get the new catalog
$root = New-Pkg 'shared' @{ nv_dispi = 'nv_disp.cat'; nvaci = 'nv_disp.cat'; nvami = 'nvami.cat'; nvbli = 'nvbli.cat' } @('nv_dispi')
$res = Invoke-SignFolder $root $cert $fake $false $false $true 4
$null = Drain; $runs = Runs
Check "shared catalog: one run with both INF files that name it (signed=$($res.Signed))" ($res.Signed -eq 1 -and $runs.Count -eq 1 -and (($runs[0].Infs | Sort-Object) -join ',') -eq 'nv_dispi.inf,nvaci.inf')
Check 'shared catalog: re-signed, the unrelated ones untouched' ((CatText $root 'nv_disp.cat') -eq 'signed' -and (CatText $root 'nvami.cat') -eq 'signed-whql' -and (CatText $root 'nvbli.cat') -eq 'signed-whql')

# ---- every INF edited, one job: nothing to isolate, the folder is catalogued whole (as in 3.0)
$root = New-Pkg 'allin' @{ a = 'nv_disp.cat'; b = 'nv_disp.cat'; c = 'nv_disp.cat' } @('a', 'b', 'c')
$Script:Links = 0
$res = Invoke-SignFolder $root $cert $fake $false $false $true 1
$null = Drain; $runs = Runs
Check 'all INF files edited: whole folder, no copy' ($res.Signed -eq 1 -and $runs.Count -eq 1 -and $runs[0].Dir -notlike '*~stage*' -and $Script:Links -eq 0)

# ---- option off: the whole folder gets new catalogs (3.0 behaviour)
$root = New-Pkg 'off' $six @('nv_dispi')
$res = Invoke-SignFolder $root $cert $fake $false $false $false 4
$log = @(Drain); $runs = Runs
Check "option off: one run on the folder with all six INF files (signed=$($res.Signed))" ($res.Signed -eq 1 -and $runs.Count -eq 1 -and $runs[0].Infs.Count -eq 6 -and $runs[0].Dir -notlike '*~stage*')
Check 'option off: every catalog replaced and signed' (@($six.Values | Where-Object { (CatText $root $_) -eq 'signed' }).Count -eq 6)
Check 'option off: result line as before' (@($log | Where-Object { $_ -match 'Display\.Driver signed and verified \(Inf2Cat took 0:00:\d\d\)' }).Count -eq 1)

# ---- "re-sign every package" with isolation: every catalog group, spread over the runs
$root = New-Pkg 'every' $six @()
$res = Invoke-SignFolder $root $cert $fake $true $false $true 3
$null = Drain; $runs = Runs
Check "every package: Display.Driver in 3 runs of 2 INF files + HDAudio (signed=$($res.Signed))" ($res.Signed -eq 2 -and $runs.Count -eq 4 -and @($runs | Where-Object { $_.Infs.Count -eq 2 -and $_.Dir -like '*~stage*' }).Count -eq 3)
Check 'every package: all seven catalogs signed in one call' (@($six.Values | Where-Object { (CatText $root $_) -eq 'signed' }).Count -eq 6 -and ((Signs) -join ',') -eq 'sign 7')

# ---- Inf2Cat fails on the isolated copy: the folder is catalogued whole instead
$root = New-Pkg 'fallback' $six @('nv_dispi', 'nvaci')
$env:FAKE_INF2CAT_FAIL_STAGE = '1'
$res = Invoke-SignFolder $root $cert $fake $false $false $true 2
Remove-Item Env:\FAKE_INF2CAT_FAIL_STAGE
$log = @(Drain); $runs = Runs
Check "fallback: signed anyway (signed=$($res.Signed) failed=$($res.Failed))" ($res.Signed -eq 1 -and $res.Failed -eq 0)
Check 'fallback: two isolated runs, then one on the whole folder' ($runs.Count -eq 3 -and $runs[2].Dir -notlike '*~stage*' -and $runs[2].Infs.Count -eq 6)
Check 'fallback: explained in the log' (@($log | Where-Object { $_ -match 'Display\.Driver: Inf2Cat failed on the isolated INF file\(s\) - the whole folder is catalogued instead' }).Count -eq 1)
Check 'fallback: every catalog signed (whole folder)' (@($six.Values | Where-Object { (CatText $root $_) -eq 'signed' }).Count -eq 6 -and -not (Test-Path "$root~stage"))

# ---- a file the INF lists is really missing: the isolated run and the whole folder fail, the error is shown
$root = New-Pkg 'missing' $six @('nv_dispi') 'nvgone.dll'
$res = Invoke-SignFolder $root $cert $fake $false $false $true 2
$log = @(Drain)
Check "missing driver file: package failed (failed=$($res.Failed))" ($res.Failed -eq 1 -and $res.Signed -eq 0)
Check 'missing driver file: Inf2Cat error shown' (@($log | Where-Object { $_ -match 'Inf2Cat failed for Display\.Driver' }).Count -eq 1 -and @($log | Where-Object { $_ -match 'nvgone\.dll in \[SourceDisksFiles\]' }).Count -ge 1)
Check 'missing driver file: no catalog changed' (@($six.Values | Where-Object { (CatText $root $_) -eq 'signed' }).Count -eq 0)

# ---- a leftover copy from a run that was killed is removed first
$root = New-Pkg 'leftover' $six @('nvami')
New-Item -ItemType Directory -Force "$root~stage/9" | Out-Null; Set-Content "$root~stage/9/old.inf" 'x'
$res = Invoke-SignFolder $root $cert $fake $false $false $true 2
$null = Drain
Check 'leftover isolated copy cleaned up' ($res.Signed -eq 1 -and -not (Test-Path "$root~stage"))

# ---- catalogs are signed in batches; a file that fails is found and reported
$cats = 1..20 | ForEach-Object { $f = Join-Path $tmp "c$_.cat"; Set-Content $f 'x'; $f }
Remove-Item $env:FAKE_SIGNTOOL_LOG -ErrorAction SilentlyContinue
$failed = @(Invoke-SignCatalogs $cats $cert)
Check 'twenty catalogs: two signtool calls (16 + 4)' ($failed.Count -eq 0 -and ((Signs) -join ',') -eq 'sign 16,sign 4')
Remove-Item $env:FAKE_SIGNTOOL_LOG -ErrorAction SilentlyContinue
$env:FAKE_SIGNTOOL_FAIL = 'c3.cat'
$failed = @(Invoke-SignCatalogs $cats[0..4] $cert)
Remove-Item Env:\FAKE_SIGNTOOL_FAIL
Check "failing catalog reported, the others signed ($($failed -join ','))" ($failed.Count -eq 1 -and $failed[0] -like '*c3.cat' -and (Get-Content $cats[4] -Raw).Trim() -eq 'signed')

# ---- groups, runs and the estimate
$g = Join-Path $tmp 'groups'; New-Item -ItemType Directory -Force $g | Out-Null
foreach ($x in @(@('a', 'x.cat'), @('b', 'x.cat'), @('c', 'y.cat'), @('d', 'z.cat'), @('e', 'w.cat'))) { Set-Content "$g/$($x[0]).inf" "[Version]`nCatalogFile=$($x[1])" }
$infs = @('a', 'b', 'c', 'd', 'e' | ForEach-Object { "$g/$_.inf" })
$parts = @(Split-InfGroups $infs @("$g/a.inf", "$g/c.inf", "$g/d.inf") 2)
$desc = ($parts | ForEach-Object { (@($_.Infs | ForEach-Object { Split-Path $_ -LeafBase }) | Sort-Object) -join '+' } | Sort-Object) -join ','
Check "groups: a+b share a catalog, e is not needed, two runs ($desc)" ($desc -eq 'a+b,c+d')
Check 'groups: never more runs than groups' (@(Split-InfGroups $infs @("$g/c.inf") 4).Count -eq 1)
Check 'time left: three 10 s runs on two slots = 20 s' ((Get-LaneTime @() @(10, 10, 10) 2) -eq 20)
Check 'time left: running 5 s + waiting 10 s on two slots = 10 s' ((Get-LaneTime @(5) @(10) 2) -eq 10)
Check 'time left: nothing to do = 0' ((Get-LaneTime @() @() 3) -eq 0)
Check 'Inf2Cat speed: default without earlier runs' ((Get-Inf2CatRate) -eq 12)
Save-Inf2CatRate 20
Check 'Inf2Cat speed: first measurement kept' ((Get-Inf2CatRate) -eq 20)
Save-Inf2CatRate 40
Check 'Inf2Cat speed: then averaged with the new one' ((Get-Inf2CatRate) -eq 30)
$Script:Cfg = @{ SignJobs = 0 }
Check "jobs: automatic = processor cores up to 4 ($(Get-SignJobs))" ((Get-SignJobs) -eq [math]::Min(4, [Environment]::ProcessorCount))
$Script:Cfg.SignJobs = 3; $three = Get-SignJobs; $Script:Cfg.SignJobs = 20; $many = Get-SignJobs
Check 'jobs: setting used, at most 8' ($three -eq 3 -and $many -eq 8)

# ---- live status of several runs (worker runspace like the app, status polled from here)
$q = Join-Path $tmp 'queue'
foreach ($d in 'A', 'B', 'C') { New-Item -ItemType Directory -Force "$q/$d" | Out-Null; foreach ($n in 1..2) { Set-Content "$q/$d/$d$n.inf" "[Version]`nCatalogFile=$d.cat" } }
$items = @('A', 'B', 'C' | ForEach-Object { [pscustomobject]@{ Dir = "$q/$_"; Label = "Folder $_"; Est = 2.5 } })
$env:FAKE_INF2CAT_SLOW = '1'
$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript({
    param($Fns, $Sync, $Exe, $Items)
    foreach ($f in $Fns) { . ([scriptblock]::Create($f)) }
    $Script:Sync = $Sync
    Invoke-Inf2CatQueue $Exe $Items '10_X64' 2
}).AddArgument($fnText).AddArgument($Script:Sync).AddArgument($fake).AddArgument($items)
$h = $ps.BeginInvoke()
$seen = New-Object System.Collections.Generic.List[string]; $pcts = New-Object System.Collections.Generic.List[double]
while (-not $h.IsCompleted) {
    $s = [string]$Script:Sync.Status; if ($s -and -not $seen.Contains($s)) { $seen.Add($s) }
    $pc = [double]$Script:Sync.Pct; if ($pc -ge 0) { $pcts.Add($pc) }
    Start-Sleep -Milliseconds 100
}
$r = @($ps.EndInvoke($h))
$ps.Dispose(); $rs.Dispose(); Remove-Item Env:\FAKE_INF2CAT_SLOW
"  statuses seen: " + (($seen | Select-Object -First 4) -join ' | ')
Check 'queue: one result per folder, in order' ($r.Count -eq 3 -and $r[0].Dir -eq "$q/A" -and $r[2].Dir -eq "$q/C" -and @($r | Where-Object { $_.Code -eq 0 }).Count -eq 3)
Check 'queue: status shows two runs at the same time' (@($seen | Where-Object { $_ -match '^Inf2Cat 2 runs at the same time, [01] of 3 done  0:00:0\d  \(about 0:00:0\d left\)  - Folder [AB]: Processing INF: [AB][12]\.inf$' }).Count -gt 0)
Check 'queue: the last folder alone, with its own time' (@($seen | Where-Object { $_ -match '^Inf2Cat Folder C  0:00:0\d  \(about 0:00:0\d left\)  - ' }).Count -gt 0)
Check "queue: progress bar moves ($([int]($pcts | Measure-Object -Minimum).Minimum)..$([int]($pcts | Measure-Object -Maximum).Maximum)%)" ($pcts.Count -gt 0 -and ($pcts | Measure-Object -Maximum).Maximum -gt ($pcts | Measure-Object -Minimum).Minimum -and ($pcts | Measure-Object -Maximum).Maximum -le 99)
Check 'queue: status and progress reset at the end' ($Script:Sync.Status -eq '' -and $Script:Sync.Pct -eq -1)

Remove-Item Env:\FAKE_INF2CAT_LOG, Env:\FAKE_SIGNTOOL_LOG -ErrorAction SilentlyContinue
Remove-Item $tmp -Recurse -Force
if ($fails) { exit 1 }
exit 0
