$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = '' })
$Script:SignTool = "$PSScriptRoot/fake/signtool"; $Script:S = @{}
$Script:ExpandExe = "$PSScriptRoot/fake/expand"; $Script:WslExe = "$PSScriptRoot/fake/wsl"
$inf2cat = "$PSScriptRoot/fake/inf2cat"; $makecat = "$PSScriptRoot/fake/makecat"
$cert = [pscustomobject]@{ Thumbprint = 'AB' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_se_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory $tmp | Out-Null
$ToolsDir = Join-Path $tmp 'tools'
$env:FAKE_INF2CAT_LOG = Join-Path $tmp 'inf2cat.log'; $env:FAKE_SIGNTOOL_LOG = Join-Path $tmp 'signtool.log'; $env:FAKE_MAKECAT_LOG = Join-Path $tmp 'makecat.log'
function New-HardLink([string]$Link, [string]$Target) { New-Item -ItemType HardLink -Path $Link -Target $Target | Out-Null; return $true }
function Drain { $it = $null; $l = @(); while ($Script:Sync.Queue.TryDequeue([ref]$it)) { $l += $it[1] }; return $l }
function Lines($f) { @(if (Test-Path $f) { Get-Content $f }) }
# NVIDIA-like package: Display.Driver with four INF files sharing nv_dispi.cat (WHQL), nv_dispi.inf edited after
# it was made. $Packed: a file the INF lists that is only there compressed (ngx-builtins\nvngx_dlssd.dl_), and
# a folder the INF copies whole without listing its files (NvCamera).
function New-Pkg([string]$Name, [bool]$Packed = $true, [string]$Cat = 'nv_dispi.cat') {
    $root = Join-Path $tmp $Name
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    $dd = Join-Path $root 'Display.Driver'
    New-Item -ItemType Directory -Force (Join-Path $dd 'bin'), (Join-Path $dd 'NvCamera'), (Join-Path $root 'HDAudio') | Out-Null
    Set-Content (Join-Path $dd 'nvlddmkm.sys') 'driver-binary'; Set-Content (Join-Path $dd 'bin/nvapi64.dll') 'api-binary'
    Set-Content (Join-Path $dd 'NvCamera/cam.dll') 'camera'; Set-Content (Join-Path $dd 'setup.cfg') 'cfg'
    $pk = ''
    if ($Packed) {
        New-Item -ItemType Directory -Force (Join-Path $dd 'ngx-builtins') | Out-Null
        Set-Content (Join-Path $dd 'ngx-builtins/nvngx_dlssd.dl_') 'packed-dlss'
        $pk = "`nnvngx_dlssd.dll = 1,ngx-builtins"
    }
    foreach ($inf in 'nv_dispi', 'nvaci', 'nvami', 'nvbli') {
        $c = if ($inf -eq 'nv_dispi') { $Cat } else { 'nv_dispi.cat' }
        $mod = if ($inf -eq 'nv_dispi') { "`n; edited`n%NEW% = Section001, PCI\VEN_10DE&DEV_2206" } else { '' }
        Set-Content (Join-Path $dd "$inf.inf") "[Version]`nSignature=`"`$Windows NT`$`"`nCatalogFile=$c`n[SourceDisksFiles]`nnvlddmkm.sys = 1`nnvapi64.dll = 1,bin$pk`n[Strings]`nX=1$mod"
    }
    Set-Content (Join-Path $dd 'nv_dispi.cat') 'signed-whql'
    if ($Cat -ne 'nv_dispi.cat') { Set-Content (Join-Path $dd $Cat) 'signed-whql' }
    Set-Content (Join-Path $root 'HDAudio/nvhda.inf') "[Version]`nCatalogFile=nvhda.cat"; Set-Content (Join-Path $root 'HDAudio/nvhda.cat') 'signed-whql'
    Remove-Item $env:FAKE_INF2CAT_LOG, $env:FAKE_SIGNTOOL_LOG, $env:FAKE_MAKECAT_LOG -ErrorAction SilentlyContinue
    return $root
}
function Text($Root, $Rel) { (Get-Content (Join-Path $Root $Rel) -Raw).Trim() }
function CatOf($Root, $Inf) { @(Get-InfCatalogs (Join-Path $Root "Display.Driver/$Inf")) -join ',' }

# ---- the setting
$Script:Cfg = @{}
Check 'engine: MakeCat when nothing is set' ((Get-SignEngine) -eq 'makecat')
$Script:Cfg.SignEngine = 'Inf2Cat'; $a = Get-SignEngine; $Script:Cfg.SignEngine = 'libwdi'; $b = Get-SignEngine; $Script:Cfg.SignEngine = 'nonsense'; $c = Get-SignEngine
Check "engine: saved value, any case; unknown -> MakeCat ($a, $b, $c)" ($a -eq 'inf2cat' -and $b -eq 'libwdi' -and $c -eq 'makecat')
Check 'engine names' ((@('makecat', 'libwdi', 'gencat', 'inf2cat') | ForEach-Object { Get-SignEngineName $_ }) -join ',' -eq 'MakeCat,libwdi-style,generate-cat-file,Inf2Cat')
if (-not $env:SystemDrive) { $env:SystemDrive = [IO.Path]::GetTempPath() }
Check 'default settings: MakeCat' ((Get-DefaultSettings).SignEngine -eq 'makecat')

# ---- INF parsing: compressed files, missing files, folder files
Check 'packed names (dll -> dl_, sy -> sy_, no extension -> ._)' ((Get-PackedName 'nvngx_dlssd.dll') -eq 'nvngx_dlssd.dl_' -and (Get-PackedName 'a.sy') -eq 'a.sy_' -and (Get-PackedName 'README') -eq 'README._')
Check 'shared catalog name from the folder' ((Get-SharedCatName '/x/Display.Driver') -eq 'display.driver_w10u.cat' -and (Get-SharedCatName '/x/My Drv+1') -eq 'my_drv_1_w10u.cat')
$root = New-Pkg 'parse'
$dd = Join-Path $root 'Display.Driver'
Add-Content (Join-Path $dd 'nvaci.inf') "[SourceDisksFiles.amd64]`ngone.dll = 1`nnotcopied.dll = 1`n[Nv_Copy]`ngone.dll`n[SourceDisksFiles.x86]`nx86only.dll = 1"
$l = Get-InfSourceFiles (Join-Path $dd 'nvaci.inf')
$names = @($l.Files | ForEach-Object { $_.Name }) -join ','
Check "listed files found, the compressed one under the INF name ($names)" ($names -eq 'nvlddmkm.sys,nvapi64.dll,nvngx_dlssd.dll' -and @($l.Files | Where-Object Packed).Count -eq 1 -and (@($l.Files | Where-Object Packed)[0].Path -like '*nvngx_dlssd.dl_'))
Check "missing files: other architectures ignored, copied ones flagged ($($l.Missing -join ',') / $($l.MissingUsed -join ','))" (($l.Missing -join ',') -eq 'gone.dll,notcopied.dll' -and ($l.MissingUsed -join ',') -eq 'gone.dll')
$ff = @(Get-FolderFiles $dd | ForEach-Object { $_.Name } | Sort-Object) -join ','
Check "folder files: everything but .inf / .cat, subfolders too ($ff)" ($ff -eq 'cam.dll,nvapi64.dll,nvlddmkm.sys,nvngx_dlssd.dl_,setup.cfg')
$st = Join-Path $tmp 'st'; New-Item -ItemType Directory -Force $st | Out-Null
Set-InfCatalog (Join-Path $dd 'nv_dispi.inf') (Join-Path $st 'nv_dispi.inf') 'display.driver_w10u.cat'
$info = Get-CatMembers $st $dd @((Join-Path $dd 'nv_dispi.inf')) @((Join-Path $st 'nv_dispi.inf')) '^[A-Za-z0-9._\-]+$' $false
$mn = @($info.Members | ForEach-Object { $_.Name }) -join ','
Check "members: INF, listed files, the rest of the folder ($mn)" ($mn -eq 'nv_dispi.inf,nvlddmkm.sys,nvapi64.dll,nvngx_dlssd.dll,nvngx_dlssd.dl_,cam.dll,setup.cfg' -and $info.InfCount -eq 1 -and $info.ExtraCount -eq 3 -and $info.PackedCount -eq 1)
$x = @($info.Members | Where-Object { $_.Name -eq 'nvngx_dlssd.dll' })[0]
Check 'the compressed file is hashed expanded, from the stage folder' ($x.Path -like "*_expanded*nvngx_dlssd.dll" -and (Get-Content $x.Path -Raw).Trim() -eq 'expanded:packed-dlss')
Check 'the staged INF is the member, not the original' (@($info.Members)[0].Path -eq (Join-Path $st 'nv_dispi.inf'))
Set-Content (Join-Path $dd 'NvCamera/bad name.dll') 'x'; Set-Content (Join-Path $dd 'bin/cam.dll') 'other'
$info2 = Get-CatMembers $st $dd @((Join-Path $dd 'nv_dispi.inf')) @((Join-Path $st 'nv_dispi.inf')) '^[A-Za-z0-9._\-]+$' $false
Check "names MakeCat cannot take are skipped, name clashes counted ($($info2.Skipped), $($info2.Clashes))" ($info2.Skipped -eq 1 -and $info2.Clashes -eq 1)
Check 'member note says what went in' ((Get-MemberNote $info2) -match '1 INF \+ 3 file\(s\) the INF files list \+ 3 other file\(s\).*1 stored compressed.*1 skipped.*1 name clash')
$low = Get-CatMembers $st $dd @((Join-Path $dd 'nv_dispi.inf')) @((Join-Path $st 'nv_dispi.inf')) '^[a-z0-9._\-]+$' $true
Check 'generate-cat-file: names in lower case' (@($low.Members | Where-Object { $_.Name -cne $_.Name.ToLowerInvariant() }).Count -eq 0 -and $low.Members.Count -ge 6)

# ---- the .cdf
$cdf = New-MakeCatCdf 'display.driver_w10u.cat' $info.Members
$cl = $cdf -split "`r`n"
Check 'cdf: header (SHA-256, catalog version 2, result in the stage folder)' ($cl[0] -eq '[CatalogHeader]' -and $cl -contains 'Name=display.driver_w10u.cat' -and $cl -contains 'ResultDir=.' -and $cl -contains 'HashAlgorithms=SHA256' -and $cl -contains 'CatalogVersion=2' -and $cl -contains 'CATATTR6=0x10010001:OSAttr:2:10.0')
Check 'cdf: INF by name (relative), files by full path' ($cl -contains '<HASH>nv_dispi.inf=nv_dispi.inf' -and @($cl | Where-Object { $_ -like '<HASH>nvlddmkm.sys=*' -and $_ -like "*$([IO.Path]::DirectorySeparatorChar)nvlddmkm.sys" }).Count -eq 1)
Check 'cdf: File and OSAttr attributes per member' ($cl -contains '<HASH>nv_dispi.infATTR1=0x10010001:File:nv_dispi.inf' -and $cl -contains '<HASH>nv_dispi.infATTR7=0x10010001:OSAttr:2:10.0' -and $cdf.EndsWith("`r`n"))

# ---- MakeCat: one catalog for the folder, only the edited INF points at it
$root = New-Pkg 'mk'
$res = Invoke-SignFolder $root $cert $inf2cat $false $false $true 2 'makecat' $makecat
$log = @(Drain)
$mem = Lines $env:FAKE_MAKECAT_LOG
Check "MakeCat: Display.Driver signed, HDAudio untouched (signed=$($res.Signed) untouched=$($res.Untouched) failed=$($res.Failed))" ($res.Signed -eq 1 -and $res.Untouched -eq 1 -and $res.Failed -eq 0 -and $res.Engine -eq 'MakeCat')
Check 'MakeCat: one run, no Inf2Cat' (@($mem | Where-Object { $_ -eq '--' }).Count -eq 1 -and (Lines $env:FAKE_INF2CAT_LOG).Count -eq 0)
Check "MakeCat: members are the edited INF and every file of the folder ($((@($mem | ForEach-Object { ($_ -split '=')[0] })) -join ','))" ((@($mem | Where-Object { $_ -ne '--' } | ForEach-Object { ($_ -split '=')[0] }) -join ',') -eq 'nv_dispi.inf,nvlddmkm.sys,nvapi64.dll,nvngx_dlssd.dll,nvngx_dlssd.dl_,cam.dll,setup.cfg')
Check 'MakeCat: the new catalog is in the package, signed' ((Text $root 'Display.Driver/display.driver_w10u.cat') -eq 'signed' -and ((Lines $env:FAKE_SIGNTOOL_LOG) -join ',') -eq 'sign 1')
Check "MakeCat: the edited INF points at it, the others keep nv_dispi.cat ($(CatOf $root 'nv_dispi.inf'), $(CatOf $root 'nvaci.inf'))" ((CatOf $root 'nv_dispi.inf') -eq 'display.driver_w10u.cat' -and (CatOf $root 'nvaci.inf') -eq 'nv_dispi.cat' -and (CatOf $root 'nvbli.inf') -eq 'nv_dispi.cat')
Check 'MakeCat: the shared WHQL catalog and the driver files are unchanged' ((Text $root 'Display.Driver/nv_dispi.cat') -eq 'signed-whql' -and (Text $root 'Display.Driver/ngx-builtins/nvngx_dlssd.dl_') -eq 'packed-dlss' -and -not (Test-Path (Join-Path $root 'Display.Driver/nvngx_dlssd.dll')))
Check 'MakeCat: no .cdf or expanded file left in the package, stage removed' (@(Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -eq '.cdf' -or $_.FullName -like '*_expanded*' }).Count -eq 0 -and -not (Test-Path "$root~stage"))
Check 'MakeCat: log names the catalog and the members' (@($log | Where-Object { $_ -match 'one catalog for the folder, display\.driver_w10u\.cat: 1 of 4 INF file\(s\) point at it - the others keep their signature' }).Count -eq 1 -and @($log | Where-Object { $_ -match '7 member\(s\).*1 INF \+ 3 file\(s\) the INF files list \+ 3 other file\(s\) of the folder; 1 stored compressed' }).Count -eq 1)
Check 'MakeCat: result line names the engine' (@($log | Where-Object { $_ -match 'Display\.Driver signed and verified \(MakeCat took 0:00:0\d\)' }).Count -eq 1)
Check 'MakeCat: status line cleared' ($Script:Sync.Status -eq '')

# ---- every INF of the folder when "only the INF files that need one" is off
$root = New-Pkg 'mkall'
$res = Invoke-SignFolder $root $cert $inf2cat $false $false $false 2 'makecat' $makecat
$null = Drain
$infs = @(Lines $env:FAKE_MAKECAT_LOG | Where-Object { $_ -like '*.inf=*' }).Count
Check "MakeCat, isolation off: all four INF files in the one catalog ($infs)" ($res.Signed -eq 1 -and $infs -eq 4 -and @('nv_dispi.inf', 'nvaci.inf', 'nvami.inf', 'nvbli.inf' | Where-Object { (CatOf $root $_) -eq 'display.driver_w10u.cat' }).Count -eq 4)

# ---- an INF that already points at that catalog (signed by this tool before) stays in it
$root = New-Pkg 'mkagain' $true 'display.driver_w10u.cat'
Set-Content (Join-Path $root 'Display.Driver/nvaci.inf') "[Version]`nCatalogFile=display.driver_w10u.cat`n[SourceDisksFiles]`nnvlddmkm.sys = 1"
$res = Invoke-SignFolder $root $cert $inf2cat $false $false $true 2 'makecat' $makecat
$null = Drain
$in = @(Lines $env:FAKE_MAKECAT_LOG | Where-Object { $_ -like '*.inf=*' } | ForEach-Object { ($_ -split '=')[0] } | Sort-Object) -join ','
Check "MakeCat: an INF already using the folder catalog is hashed again ($in)" ($res.Signed -eq 1 -and $in -eq 'nv_dispi.inf,nvaci.inf')

# ---- MakeCat fails: Inf2Cat builds that folder's catalog
$root = New-Pkg 'mkfail' $false
$env:FAKE_MAKECAT_FAIL = '1'
$res = Invoke-SignFolder $root $cert $inf2cat $false $false $true 2 'makecat' $makecat
Remove-Item Env:\FAKE_MAKECAT_FAIL
$log = @(Drain)
Check "MakeCat failed: Inf2Cat signs instead (signed=$($res.Signed) failed=$($res.Failed) engine=$($res.Engine))" ($res.Signed -eq 1 -and $res.Failed -eq 0 -and $res.Engine -eq 'Inf2Cat' -and (Lines $env:FAKE_INF2CAT_LOG).Count -ge 1)
Check 'MakeCat failed: the log says so' (@($log | Where-Object { $_ -match 'MakeCat could not build the catalog - Inf2Cat builds it instead' }).Count -eq 1)
Check 'MakeCat failed: no folder catalog left, the edited INF unchanged' (-not (Test-Path (Join-Path $root 'Display.Driver/display.driver_w10u.cat')) -and (CatOf $root 'nvaci.inf') -eq 'nv_dispi.cat')

# ---- the queue runs MakeCat in the stage folder and keeps only the useful output
$g = [pscustomobject]@{ Dir = (Join-Path $tmp 'q1'); Cat = 'q_w10u.cat'; Label = 'Q'; R = $null; Info = [pscustomobject]@{ MB = 1.0; Members = @([pscustomobject]@{ Name = 'a.inf'; Path = 'a.inf'; Kind = 'inf' }) } }
New-Item -ItemType Directory -Force $g.Dir | Out-Null; Set-Content (Join-Path $g.Dir 'a.inf') 'x'
Invoke-MakeCatGroups $makecat @($g) 2
Check "MakeCat queue: catalog written in the stage folder, member chatter dropped ($($g.R.Text))" ($g.R.Code -eq 0 -and (Test-Path (Join-Path $g.Dir 'q_w10u.cat')) -and $g.R.Text -eq 'Succeeded')

# ---- libwdi-style (CryptCAT is Windows only: a stand-in class with the same constructor)
Add-Type -TypeDefinition @'
namespace W10U {
    public class CatJob {
        public volatile bool Done; public string Error = ""; public volatile int Processed; public int Total;
        string cat, hwid, os; string[] names, paths;
        public CatJob(string cat, string hwid, string os, string osAttr, string[] names, string[] paths) { this.cat = cat; this.hwid = hwid; this.os = os; this.names = names; this.paths = paths; Total = names.Length; }
        public void Start() {
            foreach (string p in paths) if (!System.IO.File.Exists(p)) { Error = p + ": not found"; Done = true; return; }
            System.IO.File.WriteAllText(cat, "libwdi-unsigned hwid=" + hwid + " os=" + os + "\n" + string.Join("\n", names));
            Processed = Total; Done = true;
        }
    }
}
'@
$root = New-Pkg 'lw'
$res = Invoke-SignFolder $root $cert '' $false $false $true 2 'libwdi' 'native'
$log = @(Drain)
Check "libwdi-style: signed, one folder catalog (signed=$($res.Signed) engine=$($res.Engine))" ($res.Signed -eq 1 -and $res.Engine -eq 'libwdi-style' -and (CatOf $root 'nv_dispi.inf') -eq 'display.driver_w10u.cat' -and (Text $root 'Display.Driver/display.driver_w10u.cat') -eq 'signed')
Check 'libwdi-style: result line' (@($log | Where-Object { $_ -match 'Display\.Driver signed and verified \(libwdi-style took' }).Count -eq 1)
$g = [pscustomobject]@{ Dir = (Join-Path $tmp 'lw1'); Cat = 'x.cat'; Label = 'X'; Hwid = 'pci\ven_10de&dev_2206'; R = $null; Info = $info }
New-Item -ItemType Directory -Force $g.Dir | Out-Null
Invoke-NativeCatGroups @($g) 'x64'
$lc = Get-Content (Join-Path $g.Dir 'x.cat')
Check 'libwdi-style: hardware ID, Windows versions and member names reach the catalog' ($g.R.Code -eq 0 -and $lc[0] -match 'hwid=pci\\ven_10de&dev_2206 os=7_X64,8_X64,10_X64' -and ($lc[1..($lc.Count - 1)] -join ',') -eq $mn)
Invoke-NativeCatGroups @($g) 'x86'
Check 'libwdi-style: x86 image -> X86 in the OS list' ((Get-Content (Join-Path $g.Dir 'x.cat'))[0] -match 'os=7_X86,8_X86,10_X86')
$real = (Get-NativeCatSource) -replace 'namespace W10U', 'namespace W10UReal'
$ok = $true; try { Add-Type -TypeDefinition $real -Language CSharp } catch { $ok = $false; "  $($_.Exception.Message)" }
Check 'libwdi-style: the CryptCAT source compiles' $ok
$pe = Join-Path $tmp 'pe.bin'; $b = New-Object byte[] 256; $b[0] = 0x4D; $b[1] = 0x5A; $b[60] = 0x80; $b[0x80] = 0x50; $b[0x81] = 0x45; [IO.File]::WriteAllBytes($pe, $b)
if ($ok) { Check 'libwdi-style: PE files told apart from flat files' ([W10UReal.NativeCat]::IsPE($pe) -and -not [W10UReal.NativeCat]::IsPE((Join-Path $dd 'nvaci.inf'))) }

# ---- generate-cat-file through WSL (stand-in wsl.exe runs the script here; gencat.sh stand-in)
$env:HOME = Join-Path $tmp 'home'
$gd = Join-Path $env:HOME '.w10u-gencat'; New-Item -ItemType Directory -Force $gd | Out-Null
Set-Content (Join-Path $gd 'gencat.sh') @'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; -h) hw="$2"; shift 2;; -O) os="$2"; shift 2;; -A) shift 2;; *) break;; esac; done
for f in "$@"; do [ -f "$f" ] || { echo "$f: not a regular file"; exit 1; }; done
{ echo "gencat-unsigned hwid=$hw os=$os"; for f in "$@"; do echo "$f"; done; } > "$out"
'@
$root = New-Pkg 'gc'
$res = Invoke-SignFolder $root $cert '' $false $false $true 2 'gencat' 'wsl'
$log = @(Drain)
Check "generate-cat-file: signed, one folder catalog (signed=$($res.Signed) failed=$($res.Failed))" ($res.Signed -eq 1 -and $res.Engine -eq 'generate-cat-file' -and (CatOf $root 'nv_dispi.inf') -eq 'display.driver_w10u.cat')
$g = [pscustomobject]@{ Dir = (Join-Path $tmp "it's here"); Cat = 'g.cat'; Label = 'G'; Hwid = ''; R = $null; Info = $low }
New-Item -ItemType Directory -Force $g.Dir | Out-Null
Invoke-GenCatGroups @($g) 'x64'
$gl = @(Get-Content (Join-Path $g.Dir 'g.cat'))
Check "generate-cat-file: every member linked by name, paths with quotes survive ($($g.R.Text))" ($g.R.Code -eq 0 -and $gl[0] -match '^gencat-unsigned hwid=w10u os=7X64,8X64,_v100_X64' -and ($gl[1..($gl.Count - 1)] -join ',') -eq (@($low.Members | ForEach-Object { $_.Name }) -join ','))
Set-Content (Join-Path $gd 'gencat.sh') "#!/bin/bash`necho 'gencat failed'; exit 3"
$root = New-Pkg 'gcfail' $false
$res = Invoke-SignFolder $root $cert $inf2cat $false $false $true 2 'gencat' 'wsl'
$log = @(Drain)
Check "generate-cat-file failed: Inf2Cat signs instead (signed=$($res.Signed) engine=$($res.Engine))" ($res.Signed -eq 1 -and $res.Engine -eq 'Inf2Cat' -and @($log | Where-Object { $_ -match 'generate-cat-file could not build the catalog' }).Count -eq 1)
Check 'WSL check: a missing WSL is an error with the fix' ($(try { $Script:WslExe = "$PSScriptRoot/fake/nothing-here"; Initialize-GenCat; $false } catch { $_.Exception.Message -match 'wsl --install' } finally { $Script:WslExe = "$PSScriptRoot/fake/wsl" }))

# ---- verification failure with a folder engine: hint to use Inf2Cat
$root = New-Pkg 'mkbad'
function Test-SignedCatalog([string]$CatFile, [string]$Inf) { return $false }
$res = Invoke-SignFolder $root $cert $inf2cat $false $false $true 2 'makecat' $makecat
$log = @(Drain)
Check 'verification failed: counted as failed, with the Inf2Cat hint' ($res.Failed -eq 1 -and @($log | Where-Object { $_ -match 'choose the Inf2Cat engine on this page' }).Count -eq 1)

# ---- the GUI: four engine buttons on page 5, the chosen one checked, its note shown
. ([scriptblock]::Create((@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Script:XPages'}, $true))[0].Extent.Text)))
foreach ($n in 'SignEngMakeCat', 'SignEngLibwdi', 'SignEngGenCat', 'SignEngInf2Cat') { Check "page 5 has $n" ($Script:XPages -match "x:Name=`"$n`"[^>]*GroupName=`"signeng`"") }
Check 'tools page lists makecat.exe' ($Script:XPages -match 'x:Name="T_Mkc"')
$Script:U = @{ SignEngNote = [pscustomobject]@{ Text = '' } }
foreach ($n in 'SignEngMakeCat', 'SignEngLibwdi', 'SignEngGenCat', 'SignEngInf2Cat') { $Script:U[$n] = [pscustomobject]@{ IsChecked = $false } }
$Script:Cfg = @{ SignEngine = 'gencat' }; Update-SignEngine
Check 'GUI: the saved engine is checked, with its note' ($Script:U.SignEngGenCat.IsChecked -and -not $Script:U.SignEngMakeCat.IsChecked -and $Script:U.SignEngNote.Text -match 'WSL')
$Script:Cfg = @{}; Update-SignEngine
Check 'GUI: MakeCat when nothing is saved' ($Script:U.SignEngMakeCat.IsChecked -and $Script:U.SignEngNote.Text -match '^Default\.')

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($fails) { exit 1 }
exit 0
