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
function Drain { $it = $null; $l = @(); while ($Script:Sync.Queue.TryDequeue([ref]$it)) { $l += $it[1] }; return $l }

# ---- untrusted (NVCleanstall) catalog is re-signed, a valid one is left alone
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'w10u_t7'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$tmp/Display.Driver", "$tmp/HDAudio" | Out-Null
Set-Content "$tmp/Display.Driver/nv_disp.inf" "[Version]`nCatalogFile=nv_disp.cat"; Set-Content "$tmp/Display.Driver/nv_disp.cat" 'nvcleanstall-selfsigned'
Set-Content "$tmp/HDAudio/hda.inf" "[Version]`nCatalogFile=hda.cat"; Set-Content "$tmp/HDAudio/hda.cat" 'signed-whql'
Check 'catalog signed by an untrusted certificate (NVCleanstall) -> untrusted' ((Get-InfState "$tmp/Display.Driver/nv_disp.inf") -eq 'untrusted')
Check 'valid catalog -> ok' ((Get-InfState "$tmp/HDAudio/hda.inf") -eq 'ok')
$res = Invoke-SignFolder $tmp ([pscustomobject]@{ Thumbprint = 'AB' }) $fake $false
Check "untrusted package re-signed, valid one untouched (signed=$($res.Signed) untouched=$($res.Untouched) failed=$($res.Failed))" ($res.Signed -eq 1 -and $res.Untouched -eq 1 -and $res.Failed -eq 0)
$log = @(Drain)
Check 'log shows the folder with its INF count' (@($log | Where-Object { $_ -match 'Display\.Driver  \(1 INF file\(s\), folder 1 of 1\)' }).Count -eq 1)
Check 'log shows how long Inf2Cat took' (@($log | Where-Object { $_ -match 'signed and verified \(Inf2Cat took 0:00:\d\d\)' }).Count -eq 1)
Check 'status line is cleared afterwards (no "checking INF" leftover)' ($Script:Sync.Status -eq '')
Remove-Item $tmp -Recurse -Force

# ---- argument quoting for Inf2Cat
Check 'plain argument stays as is' ((ConvertTo-ArgText '/os:10_X64') -eq '/os:10_X64')
Check 'argument with spaces is quoted' ((ConvertTo-ArgText '/driver:C:\My Drivers\NVIDIA') -eq '"/driver:C:\My Drivers\NVIDIA"')
Check 'trailing backslash is doubled inside quotes' ((ConvertTo-ArgText 'C:\a b\') -eq '"C:\a b\\"')
Check 'embedded quote is escaped' ((ConvertTo-ArgText 'a"b') -eq '"a\"b"')
Check 'time format h:mm:ss' ((Format-Span ([timespan]::FromSeconds(3725))) -eq '1:02:05' -and (Format-Span ([timespan]::FromSeconds(59))) -eq '0:00:59')

# ---- live status while Inf2Cat runs (worker runspace like the app, status polled from here)
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'w10u_t8'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$tmp/Display.Driver" | Out-Null
foreach ($n in 'nvaci', 'nvcvi', 'nvdmi') { Set-Content "$tmp/Display.Driver/$n.inf" "[Version]`nCatalogFile=nv_disp.cat" }
$env:FAKE_INF2CAT_SLOW = '1'
$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript({
    param($Fns, $Sync, $Exe, $Dir)
    foreach ($f in $Fns) { . ([scriptblock]::Create($f)) }
    $Script:Sync = $Sync
    Invoke-Inf2Cat $Exe $Dir '10_X64' 'Display.Driver (1 of 5)'
}).AddArgument($fnText).AddArgument($Script:Sync).AddArgument($fake).AddArgument("$tmp/Display.Driver")
$h = $ps.BeginInvoke()
$seen = New-Object System.Collections.Generic.List[string]
while (-not $h.IsCompleted) { $s = [string]$Script:Sync.Status; if ($s -and -not $seen.Contains($s)) { $seen.Add($s) }; Start-Sleep -Milliseconds 100 }
$r = @($ps.EndInvoke($h))[0]
$ps.Dispose(); $rs.Dispose(); Remove-Item Env:\FAKE_INF2CAT_SLOW
"  statuses seen: " + ($seen -join ' | ')
Check 'Inf2Cat exit code and output returned' ($r.Code -eq 0 -and $r.Text -match 'Signability test complete')
Check 'status names the folder and its position' (@($seen | Where-Object { $_ -like 'Inf2Cat Display.Driver (1 of 5)  0:00:0*' }).Count -gt 0)
Check 'status shows the current INF by file name (path removed)' (@($seen | Where-Object { $_ -match 'Processing INF: nvcvi\.inf$' }).Count -gt 0)
Check 'dot-only progress lines are not shown' (@($seen | Where-Object { $_ -match '- \.+$' }).Count -eq 0)
Check 'elapsed time keeps counting' (@($seen | ForEach-Object { if ($_ -match '  (\d+:\d\d:\d\d)  ') { $Matches[1] } } | Sort-Object -Unique).Count -ge 2)
Check 'status cleared when Inf2Cat ends' ($Script:Sync.Status -eq '')
Check 'all three INF files were processed' ($r.Time.TotalSeconds -ge 2.5)
Remove-Item $tmp -Recurse -Force

# ---- "only this PC's hardware": keep the matching INF (+ what it needs), remove the rest
$hostIds = @('PCI\VEN_10DE&DEV_2206&SUBSYS_65A11558&REV_A1', 'PCI\VEN_10DE&DEV_2206&SUBSYS_65A11558', 'PCI\VEN_10DE&DEV_2206&REV_A1', 'PCI\VEN_10DE&DEV_2206',
             'HDAUDIO\FUNC_01&VEN_10DE&DEV_009A&SUBSYS_15586511', 'PCI\VEN_8086&DEV_A36D')
function Get-HostHardwareIds { $s = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase); foreach ($i in $hostIds) { [void]$s.Add($i) }; return , $s }
function New-Inf($Path, $Ids, $Extra = '') {
    $models = ($Ids | ForEach-Object -Begin { $k = 0 } -Process { $k++; "%DEV$k% = Section001, $_" }) -join "`n"
    Set-Content $Path "[Version]`nSignature=`"`$Windows NT`$`"`nCatalogFile=nv_disp.cat`n$Extra`n[NVIDIA_Devices.NTamd64.10.0]`n$models`n; %OLD% = Section001, PCI\VEN_10DE&DEV_2206&SUBSYS_00000000"
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'w10u_t9'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
$dd = "$tmp/Display.Driver"; New-Item -ItemType Directory -Force $dd, "$tmp/HDAudio", "$tmp/PhysX" | Out-Null
New-Inf "$dd/nvcvi.inf" @('PCI\VEN_10DE&DEV_1E87&SUBSYS_95011558', 'pci\ven_10de&dev_2206&subsys_65a11558') "[DDInstall]`nInclude = nvshared.inf, machine.inf"   # Clevo + the NVCleanstall-added 3080
New-Inf "$dd/nvaci.inf" @('PCI\VEN_10DE&DEV_2206&SUBSYS_12341025')            # Acer
New-Inf "$dd/nvdmi.inf" @('PCI\VEN_10DE&DEV_2206&SUBSYS_0A1B1028')            # Dell
New-Inf "$dd/nvshared.inf" @('PCI\VEN_10DE&DEV_9999')                         # other IDs, but included by nvcvi.inf
Set-Content "$dd/nvcomp.inf" "[Version]`nCatalogFile=nv_disp.cat`n[Comp]`nAddComponent = NvTelemetry,,Comp_Inst"      # no device IDs
Set-Content "$dd/nv_disp.cat" 'nvcleanstall-selfsigned'
New-Inf "$tmp/HDAudio/nvhda.inf" @('HDAUDIO\FUNC_01&VEN_10DE&DEV_009A&SUBSYS_15586511'); Set-Content "$tmp/HDAudio/nv_disp.cat" 'nvcleanstall-selfsigned'
New-Inf "$tmp/PhysX/a.inf" @('PCI\VEN_1234&DEV_0001'); New-Inf "$tmp/PhysX/b.inf" @('PCI\VEN_1234&DEV_0002'); Set-Content "$tmp/PhysX/nv_disp.cat" 'nvcleanstall-selfsigned'
$ids = Get-InfDeviceIds "$dd/nvcvi.inf"
Check 'device IDs read from the models section, comments ignored' ($ids.Count -eq 2 -and -not $ids.Contains('PCI\VEN_10DE&DEV_2206&SUBSYS_00000000'))
Check 'Include= lines read' ((@(Get-InfIncludes "$dd/nvcvi.inf") -join ',') -eq 'machine.inf,nvshared.inf')
$res = Invoke-SignFolder $tmp ([pscustomobject]@{ Thumbprint = 'AB' }) $fake $false $true
$left = @(Get-ChildItem $dd -Filter *.inf | ForEach-Object Name | Sort-Object) -join ','
$log = @(Drain)
"  kept in Display.Driver: $left"
Check 'matching INF kept (case-insensitive ID match)' ($left -match 'nvcvi\.inf')
Check 'INF included by the kept one stays' ($left -match 'nvshared\.inf')
Check 'INF without device IDs stays' ($left -match 'nvcomp\.inf')
Check 'INF files for other hardware removed' ($left -notmatch 'nvaci|nvdmi' -and $res.Removed -eq 2)
Check 'single-INF folder untouched' (Test-Path "$tmp/HDAudio/nvhda.inf")
Check 'folder with no match for this PC is kept whole' ((Test-Path "$tmp/PhysX/a.inf") -and (Test-Path "$tmp/PhysX/b.inf"))
Check 'log names the kept INF and the matching device' (@($log | Where-Object { $_ -match 'Display\.Driver : kept nvcvi\.inf \(PCI\\VEN_10DE&DEV_2206&SUBSYS_65A11558\).*removed 2 INF' }).Count -eq 1)
Check 'log explains the folder kept whole' (@($log | Where-Object { $_ -match "PhysX : no INF file lists this PC's hardware - all 2 are kept" }).Count -eq 1)
Check "everything still signed (signed=$($res.Signed) failed=$($res.Failed))" ($res.Signed -eq 3 -and $res.Failed -eq 0)
Check 'kept list recorded' ((@($res.Kept) -join ',') -match 'nvcvi\.inf')
Check 'no long-run warning for a trimmed folder' (@($log | Where-Object { $_ -match 'up to an hour' }).Count -eq 0)
Remove-Item $tmp -Recurse -Force

# ---- big folder without the option: the log explains the wait and points to the option
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'w10u_t10'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$tmp/Display.Driver" | Out-Null
1..12 | ForEach-Object { New-Inf "$tmp/Display.Driver/nv$_.inf" @("PCI\VEN_10DE&DEV_2206&SUBSYS_$($_)0001028") }
Set-Content "$tmp/Display.Driver/nv_disp.cat" 'nvcleanstall-selfsigned'
$res = Invoke-SignFolder $tmp ([pscustomobject]@{ Thumbprint = 'AB' }) $fake $false
$log = @(Drain)
Check 'long-run note for a folder with many INF files' (@($log | Where-Object { $_ -match 'up to an hour' }).Count -eq 1)
Check 'tip about the faster option' (@($log | Where-Object { $_ -match "Only keep the INF files for this PC's hardware" }).Count -eq 1)
Check 'nothing removed without the option' (@(Get-ChildItem "$tmp/Display.Driver" -Filter *.inf).Count -eq 12)
Remove-Item $tmp -Recurse -Force

# ---- hardware IDs unreadable -> nothing removed
function Get-HostHardwareIds { return , (New-Object 'System.Collections.Generic.HashSet[string]') }
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'w10u_t11'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$tmp/D" | Out-Null
New-Inf "$tmp/D/a.inf" @('PCI\VEN_10DE&DEV_0001'); New-Inf "$tmp/D/b.inf" @('PCI\VEN_10DE&DEV_0002')
$t = Limit-InfsToHost $tmp @(Get-InfFolders $tmp)
$log = @(Drain)
Check 'no hardware IDs -> warning, every INF kept' ($t.Removed -eq 0 -and @(Get-ChildItem "$tmp/D" -Filter *.inf).Count -eq 2 -and @($log | Where-Object { $_ -match 'could not be read' }).Count -eq 1)
Remove-Item $tmp -Recurse -Force

if ($fails) { exit 1 }
exit 0
