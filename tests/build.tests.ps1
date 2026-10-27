$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_build_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory $tmp | Out-Null
$env:SystemDrive = $tmp; $env:SystemRoot = $tmp
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = '' })
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:SettingsFile = Join-Path $tmp 'settings.json'
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'
Initialize-Paths
$P = $Script:P
New-Item -ItemType Directory -Force (Join-Path $P.Media 'sources'), (Join-Path $P.Media 'boot'), (Join-Path $P.Media 'efi/microsoft/boot'), $P.Logs | Out-Null
Set-Content (Join-Path $P.Media 'sources/install.wim') 'installwim'
Set-Content (Join-Path $P.Media 'boot/etfsboot.com') 'etfs'
Set-Content (Join-Path $P.Media 'efi/microsoft/boot/efisys_noprompt.bin') 'efi'
$Script:LogFile = Join-Path $P.Logs 'engine.log'
$Script:S = New-State
$Script:S.Unpacked = $true
$Script:S.Family = [ordered]@{ Arch = 'x64'; VerToken = '22H2'; Label = 'W10_22H2_X64'; Supported = $true }
$Script:S.Serviced = [ordered]@{ When = 'now'; Build = '19045.6456'; Boot2023 = $false }
function Drain { $it = $null; $l = @(); while ($Script:Sync.Queue.TryDequeue([ref]$it)) { $l += $it[1] }; return $l }

# stand-ins: oscdimg writes its target (the last quoted argument), or fails half way
function Find-Oscdimg { 'oscdimg.exe' }
function Sync-Oem { }
function Sync-Unattend { }
function Test-UnattendSelection { }
function Invoke-InstallCheck { @() }
$Script:Osc = New-Object System.Collections.Generic.List[string]
function Invoke-Exe([string]$File, [string]$Arguments, [switch]$MergeErr) {
    $q = @([regex]::Matches($Arguments, '"([^"]+)"'))
    $target = $q[$q.Count - 1].Groups[1].Value
    $Script:Osc.Add($target)
    if ($env:FAKE_OSC_FAIL) { Set-Content -LiteralPath $target 'half an iso'; return 5 }
    Set-Content -LiteralPath $target 'new iso'; return 0
}
$RealFree = ${function:Get-FreeBytes}
$Script:Free = -1
function Get-FreeBytes { $Script:Free }
function Build([string]$Out) {
    $Script:Osc.Clear(); $Script:Err = $null
    try { Invoke-Build -Auto -OutIso $Out } catch { $Script:Err = $_.Exception.Message; "  error: $($Script:Err)" }
}
$iso = Join-Path $tmp 'out/Win10.iso'

# ---- a normal build: oscdimg writes a .part file that becomes the ISO
Build $iso
Check 'oscdimg writes into Win10.iso.part, not the ISO itself' ($Script:Osc.Count -eq 1 -and $Script:Osc[0] -eq "$iso.part")
Check 'the finished ISO is in place, no .part left' ((Get-Content $iso -Raw) -match 'new iso' -and -not (Test-Path "$iso.part") -and -not $Script:Err)
$h = (Get-FileHash $iso -Algorithm SHA256).Hash
Check '.sha256 written for the new ISO' ((Get-Content "$iso.sha256" -Raw).Trim() -eq "$h *Win10.iso")
Check 'state points at the new ISO' ((Import-State).Iso -eq $iso)

# ---- oscdimg fails: the ISO of the same name and its .sha256 stay as they were
Set-Content $iso 'old iso'; Set-Content "$iso.sha256" 'OLDHASH *Win10.iso'
$env:FAKE_OSC_FAIL = '1'
Build $iso
$env:FAKE_OSC_FAIL = ''
Check "failed build is reported ($($Script:Err))" ($Script:Err -match '^oscdimg failed \(exit 5\)\. The previous ISO of that name is unchanged\.$')
Check 'failed build: the previous ISO is kept' ((Get-Content $iso -Raw).Trim() -eq 'old iso')
Check 'failed build: its .sha256 still matches it' ((Get-Content "$iso.sha256" -Raw).Trim() -eq 'OLDHASH *Win10.iso')
Check 'failed build: the half-written .part is removed' (-not (Test-Path "$iso.part"))
Set-Content "$iso.part" 'left over from a crash'
Build $iso
Check 'a .part left from an earlier run does not get in the way' ((Get-Content $iso -Raw).Trim() -eq 'new iso' -and -not (Test-Path "$iso.part"))

# ---- the ISO is mounted / open somewhere: stop before oscdimg runs
$lock = [IO.File]::Open($iso, 'Open', 'Read', 'Read')
try { Build $iso } finally { $lock.Dispose() }
Check "ISO in use: clear message ($($Script:Err))" ($Script:Err -match 'is in use - it is probably mounted in Explorer')
Check 'ISO in use: oscdimg did not run' ($Script:Osc.Count -eq 0)

# ---- free space on the output drive
$Script:Free = 1KB
Build (Join-Path $tmp 'out/Other.iso')
Check "not enough space: stopped before oscdimg ($($Script:Err))" ($Script:Err -match '^Not enough free space for the ISO' -and $Script:Osc.Count -eq 0)
Check 'not enough space: the reason is in the log' (@(Drain | Where-Object { $_ -match 'Only 1 KB free on .* - the ISO needs about' }).Count -eq 1)
$fs = [IO.File]::Open($iso, 'Create'); $fs.SetLength(150MB); $fs.Dispose()     # an older 150 MB ISO of the same name
$Script:Free = 60MB                                                               # 60 MB + 150 MB is enough, 60 MB alone is not
Build $iso
Check 'tight space: the old ISO of the same name is deleted first, then the build runs' (-not $Script:Err -and (Get-Content $iso -Raw).Trim() -eq 'new iso')
Check 'tight space: noted in the log' (@(Drain | Where-Object { $_ -match 'the old one is deleted first' }).Count -eq 1)
$Script:Free = -1
Build (Join-Path $tmp 'out/Share.iso')
Check 'free space unknown (network share): the build runs' (-not $Script:Err -and (Test-Path (Join-Path $tmp 'out/Share.iso')))

# ---- helpers on a real drive
Check 'Get-FreeBytes reads the drive the ISO goes to' ((& $RealFree $iso) -gt 0)
Check 'Test-FileInUse: a closed file is free, a missing file is not in use' (-not (Test-FileInUse $iso) -and -not (Test-FileInUse (Join-Path $tmp 'nope.iso')))

Remove-Item Env:\FAKE_OSC_FAIL -ErrorAction SilentlyContinue
Remove-Item $tmp -Recurse -Force
if ($fails) { exit 1 }
exit 0
