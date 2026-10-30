$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$bodyFile = "$PSScriptRoot/v2body.ps1"
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($bodyFile,[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
$body = [IO.File]::ReadAllText($bodyFile)
$b = $body.IndexOf('#ENGINE-BEGIN'); $e = $body.IndexOf('#ENGINE-END')
# engine for the background runspace + the stand-ins Linux needs
$stubs = @'

function Get-WindowsImage { param($ImagePath, $Index, [switch]$Mounted, $ErrorAction) if ($Mounted) { return @() }; if ($Index -and $env:FAKE_IMG_VER) { return [pscustomobject]@{ ImageIndex = $Index; Version = $env:FAKE_IMG_VER; SPBuild = [int]$env:FAKE_IMG_SP } }; return @(1, 2) }
'@
$Script:EngineText = $body.Substring($b, $e - $b) + $stubs
. ([scriptblock]::Create($stubs))
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_svc_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory $tmp | Out-Null
$env:W10U_SELF = Join-Path $tmp 'Windows-ISO-updater-GUI_v0.0.0.cmd'
$env:SystemDrive = $tmp; $env:SystemRoot = $tmp
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = ''; Result = $null })
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:Dism = "$PSScriptRoot/fake/dism"
$Script:SettingsFile = Join-Path $tmp 'settings.json'
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'
Initialize-Paths
$P = $Script:P
New-Item -ItemType Directory -Force $P.Logs, (Join-Path $P.Media 'sources'), $P.Temp | Out-Null
$Script:LogFile = Join-Path $P.Logs 'engine.log'; $Script:DismLog = Join-Path $P.Logs 'dism.log'
Set-Content (Join-Path $P.Media 'sources/boot.wim') 'bootwim'
$Script:S = New-State
$dlog = Join-Path $tmp 'dism-calls.txt'; $env:FAKE_DISM_LOG = $dlog
function Drain { $it = $null; $l = @(); while ($Script:Sync.Queue.TryDequeue([ref]$it)) { $l += $it[1] }; return $l }
function Calls { if (Test-Path $dlog) { return @(Get-Content $dlog) } else { return @() } }

# ---- one driver set for WinRE / boot.wim
$drv = Join-Path $tmp 'drv'
New-Item -ItemType Directory -Force "$drv/a", "$drv/b/sub", "$drv/c" | Out-Null
Set-Content "$drv/a/iastorac.inf" 'x'; Set-Content "$drv/a/iastorac.sys" 'x'
Set-Content "$drv/b/netwtw08.inf" 'x'; Set-Content "$drv/b/other.inf" 'x'; Set-Content "$drv/b/sub/extra.inf" 'x'; Set-Content "$drv/b/sub/fw.bin" 'x'
Set-Content "$drv/c/e2f.inf" 'x'
$set = New-BootDriverSet @("$drv/a/iastorac.inf", "$drv/b/netwtw08.inf", "$drv/c/e2f.inf") (Join-Path $P.Temp 'bootdrivers')
$infs = @(Get-ChildItem $set.Folder -Recurse -Filter *.inf | ForEach-Object { $_.Name } | Sort-Object)
Check 'driver set: one folder per driver, only the wanted INF kept' (($infs -join ',') -eq 'e2f.inf,iastorac.inf,netwtw08.inf' -and $set.Count -eq 3)
Check 'driver set: the driver files stay' ((Test-Path (Join-Path $set.Folder '001/iastorac.sys')) -and (Test-Path (Join-Path $set.Folder '002/sub/fw.bin')))
Remove-Item $dlog -ErrorAction SilentlyContinue
Add-BootDrivers (Join-Path $tmp 'mnt') $set '' 'WinPE'
$c = @(Calls)
Check 'storage/network drivers added with one DISM call' ($c.Count -eq 1 -and $c[0] -match '/Add-Driver /Driver:.*bootdrivers /Recurse')
Check 'servicing commands use the scratch folder in the work folder' ($c[0] -match '/ScratchDir:.*temp.scratch')
$null = Drain

# ---- boot.wim inline (option off)
function New-Ctx([bool]$SkipPE) {
    $bf = Join-Path $P.Temp 'bootfiles'; New-Item -ItemType Directory -Force $bf | Out-Null
    return @{ Upd = @{ SSU = @('/u/ssu.msu'); LCU = @('/u/lcu.msu') }; Media = $P.Media; MountPE = $P.MountPE; BfDir = $bf; ExDir = (Join-Path $P.Temp 'boot2023_pe')
              BootSt = (Join-Path $P.Temp 'boot_stage.wim'); BootFin = (Join-Path $P.Temp 'boot_final.wim'); BootSet = $set; Fu = ''; Boot2023 = $true; SkipPE = $SkipPE }
}
Remove-Item $dlog -ErrorAction SilentlyContinue
$ctx = New-Ctx $false
$r = Invoke-BootWimService $ctx
$c = @(Calls)
Check 'inline: both indexes mounted, updated and exported' (@($c | Where-Object { $_ -match '/Mount-Image' }).Count -eq 2 -and @($c | Where-Object { $_ -match '/Export-Image' }).Count -eq 2)
Check 'inline: the LCU installed in its first pass is not added a second time (one pass per index)' (@($c | Where-Object { $_ -match 'lcu\.msu' }).Count -eq 2)
Check 'inline: setup.exe and boot files saved for the media' ((Test-Path (Join-Path $ctx.BfDir 'setup.exe')) -and (Test-Path (Join-Path $ctx.BfDir 'bootmgfw.efi')))
Check 'inline: 2023 boot files saved' ($r.ExSaved -and (Test-Path (Join-Path $ctx.ExDir 'EFI_EX')))
$null = Drain

# ---- the first pass did not install the update: the second pass runs (Microsoft's way for WinPE)
Remove-Item $dlog, $ctx.BootFin -ErrorAction SilentlyContinue
$env:FAKE_DISM_FAIL = 'lcu.msu'
$r = Invoke-BootWimService (New-Ctx $false)
$env:FAKE_DISM_FAIL = ''
$c = @(Calls); $log = @(Drain)
Check 'first LCU pass failed: second pass run for each index' (@($c | Where-Object { $_ -match 'lcu\.msu' }).Count -eq 4 -and @($log | Where-Object { $_ -match 'no second pass' }).Count -eq 0)

# ---- option: leave index 1 (Windows PE) as it is
Remove-Item $dlog, $ctx.BootFin -ErrorAction SilentlyContinue
$ctx = New-Ctx $true
$r = Invoke-BootWimService $ctx
$c = @(Calls)
$log = @(Drain)
Check 'skip PE: only index 2 mounted' (@($c | Where-Object { $_ -match '/Mount-Image' }).Count -eq 1 -and @($c | Where-Object { $_ -match '/Mount-Image.*/Index:2' }).Count -eq 1)
Check 'skip PE: index 1 still exported into the new boot.wim' (@($c | Where-Object { $_ -match '/Export-Image.*/SourceIndex:1' }).Count -eq 1)
Check 'skip PE: noted in the log' (@($log | Where-Object { $_ -match 'index 1 of 2 \(Windows PE\) - kept as it is' }).Count -eq 1)

# ---- background job (option on): runs while this thread keeps working
Remove-Item $dlog, $ctx.BootFin -ErrorAction SilentlyContinue
$env:FAKE_DISM_SLEEP = '0.3'
$ctx = New-Ctx $false
$t = Get-Date
$job = Start-BootWimJob $ctx
Check 'background job started' ($null -ne $job)
$started = ((Get-Date) - $t).TotalSeconds
Check "start returns at once ($([math]::Round($started,1)) s), not after boot.wim" ($started -lt 3 -and -not $job.Handle.IsCompleted)
Start-Sleep -Milliseconds 900
$side = @($Script:Sync.SideSync)[0]
Check "side status visible to the window ($($side.Label))" ($side -and $side.Label -match '^boot\.wim [12]/2')
$r = Wait-SideJob $job
$log = @(Drain)
$c = @(Calls)
Check 'background: result returned (2023 boot files saved)' ($r -and $r.ExSaved)
Check 'background: boot.wim log shown in the Activity log' (@($log | Where-Object { $_ -match 'Updating boot\.wim' }).Count -eq 1 -and @($log | Where-Object { $_ -match 'boot\.wim: background job finished after' }).Count -eq 1)
Check 'background: own DISM log and scratch folder' (@($c | Where-Object { $_ -match 'dism-boot\.log' -and $_ -match '/Image:' -and $_ -match 'scratch-pe' }).Count -gt 0)
Check 'background: its engine log is merged into engine.log' ((Get-Content $Script:LogFile -Raw) -match 'boot\.wim \(background\) log' -and -not (Test-Path (Join-Path $P.Logs 'engine-boot.log')))
Check 'background: side status cleared' ($null -eq $Script:Sync.SideSync)

# ---- background job error is reported by the main job
Remove-Item $dlog, $ctx.BootFin -ErrorAction SilentlyContinue
$env:FAKE_DISM_SLEEP = ''; $env:FAKE_DISM_FAIL = 'boot_stage.wim'
$job = Start-BootWimJob (New-Ctx $false)
$msg = $null
try { [void](Wait-SideJob $job) } catch { $msg = $_.Exception.Message }
Check "background error surfaces as 'boot.wim: ...' ($msg)" ($msg -match '^boot\.wim: Mount boot_stage\.wim #1 failed')
$env:FAKE_DISM_FAIL = ''
$null = Drain

# ---- updates the image already has: the build an update brings, from the XML inside the .msu
$xml = '<?xml version="1.0" encoding="utf-8" standalone="yes"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><servicing><package action="install"><assemblyIdentity name="Package_for_ServicingStack_6449" version="19041.6449.1.3" processorArchitecture="amd64" language="neutral" buildType="release" publicKeyToken="31bf3856ad364e35" /><source location="%configsetroot%\SSU-19041.6449-x64.cab" /></package><package action="install"><assemblyIdentity buildType="release" language="neutral" name="Package_for_RollupFix" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" version="19041.6456.1.21" /><source location="%configsetroot%\Windows10.0-KB5066791-x64.cab" /></package></servicing></unattend>'
$ids = @(Read-MsuXml $xml)
Check 'msu XML: packages and versions read, in any attribute order' ($ids.Count -eq 2 -and $ids[1].Name -eq 'Package_for_RollupFix' -and $ids[1].Version -eq '19041.6456.1.21')
$msu = Join-Path $tmp 'windows10.0-kb5066791-x64.msu'; Set-Content $msu 'msu'; [IO.File]::WriteAllText("$msu.xml", $xml, [Text.Encoding]::Unicode)
$Script:ExpandExe = "$PSScriptRoot/fake/expand"
$ub = Get-UpdateBuild $msu
Check "update build from the .msu: $($ub.Build).$($ub.Rev)" ($ub -and $ub.Build -eq 19041 -and $ub.Rev -eq 6456 -and @(Get-ChildItem $P.Temp -Filter 'msuxml_*').Count -eq 0)
Check 'no XML in the update: nothing known, nothing skipped' ($null -eq (Get-UpdateBuild (Join-Path $tmp 'other.msu')) -and $null -eq (Get-UpdateBuild '/u/x.cab'))
$Script:ExpandExe = $null
Check 'image at the build of the update (19045 / WinPE 19041 share the servicing base): skipped' ((Test-UpdateInImage $ub '19045.6456') -and (Test-UpdateInImage $ub '19041.6456') -and (Test-UpdateInImage $ub '19045.6500'))
Check 'older image, other Windows, unknown version: not skipped' (-not (Test-UpdateInImage $ub '19045.6093') -and -not (Test-UpdateInImage $ub '22631.6456') -and -not (Test-UpdateInImage $ub '') -and -not (Test-UpdateInImage $null '19045.6456'))
$env:FAKE_IMG_VER = '10.0.19041.6456'; $env:FAKE_IMG_SP = '6456'
Check "image version from the WIM: $(Get-ImageVersion 'x.wim' 2)" ((Get-ImageVersion 'x.wim' 2) -eq '19041.6456')
$env:FAKE_IMG_VER = ''
Check 'image version unknown: empty' ((Get-ImageVersion 'x.wim' 2) -eq '')

# ---- older versions of the same driver are unticked in the picker
$dv = @(
    [pscustomobject]@{ Inf = 'nvcvi.inf'; Provider = 'NVIDIA'; Class = 'Display'; Version = '32.0.15.6094'; Date = '2024-08-14'; Folder = 'nvcvi.inf_amd64_a' }
    [pscustomobject]@{ Inf = 'nvcvi.inf'; Provider = 'NVIDIA'; Class = 'Display'; Version = '32.0.15.8180'; Date = '2025-09-30'; Folder = 'nvcvi.inf_amd64_b' }
    [pscustomobject]@{ Inf = 'NVCVI.INF'; Provider = 'NVIDIA'; Class = 'Display'; Version = '32.0.15.7680'; Date = '2025-06-02'; Folder = 'nvcvi.inf_amd64_c' }
    [pscustomobject]@{ Inf = 'ibtusb.inf'; Provider = 'Intel'; Class = 'Bluetooth'; Version = '23.100.0.4'; Date = '2025-01-10'; Folder = 'ibtusb.inf_amd64_a' }
    [pscustomobject]@{ Inf = 'ibtusb.inf'; Provider = 'Intel'; Class = 'Bluetooth'; Version = '23.110.0.1'; Date = '2025-01-10'; Folder = 'ibtusb.inf_amd64_b' }
    [pscustomobject]@{ Inf = 'heci.inf'; Provider = 'Intel'; Class = 'System'; Version = '2406.5.5.0'; Date = '2024-03-01'; Folder = 'heci.inf_amd64_a' }
    [pscustomobject]@{ Inf = 'heci.inf'; Provider = 'Other'; Class = 'System'; Version = '1.0'; Date = '2020-01-01'; Folder = 'heci.inf_amd64_b' }
)
$dv = @(Set-OlderDrivers $dv)
$kept = @($dv | Where-Object { -not $_.Older } | ForEach-Object Folder | Sort-Object) -join ','
Check "drivers: newest of each kind kept, by date then version, other providers apart ($kept)" ($kept -eq 'heci.inf_amd64_a,heci.inf_amd64_b,ibtusb.inf_amd64_b,nvcvi.inf_amd64_b' -and @($dv | Where-Object Older).Count -eq 3)

# ---- Defender option: exclusion only for the job, never left behind
$Script:Excl = New-Object System.Collections.Generic.List[string]
function Get-MpPreference { [pscustomobject]@{ ExclusionPath = @($Script:Excl) } }
function Add-MpPreference { param($ExclusionPath) $Script:Excl.Add($ExclusionPath) }
function Remove-MpPreference { param($ExclusionPath) [void]$Script:Excl.Remove($ExclusionPath) }
$w = [IO.Path]::GetFullPath($P.Work).TrimEnd('\')
$Script:Cfg.DefenderExclude = $false
Enable-DefenderSkip
Check 'option off: nothing added' ($Script:Excl.Count -eq 0)
$Script:Cfg.DefenderExclude = $true
Enable-DefenderSkip
Check 'option on: work folder excluded, marker written' ($Script:Excl -contains $w -and (Test-Path (Join-Path $P.Work 'defender-exclusion.txt')))
Disable-DefenderSkip
Check 'removed at the end, marker gone' ($Script:Excl.Count -eq 0 -and -not (Test-Path (Join-Path $P.Work 'defender-exclusion.txt')))
Enable-DefenderSkip; $Script:DefenderAdded = $null          # program closed during a job
Disable-DefenderSkip
Check 'leftover from a killed run removed at the next start' ($Script:Excl.Count -eq 0)
$Script:Excl.Add($w)                                          # the user excluded it himself
Enable-DefenderSkip; Disable-DefenderSkip
Check "the user's own exclusion is left alone" ($Script:Excl -contains $w -and $Script:Excl.Count -eq 1)
$null = Drain
function Get-MpPreference { throw 'Operation failed with the following error: 0x800106ba. Operation: MpPreference. Target: ConfigListExtension.' }
Enable-DefenderSkip
$log = @(Drain)
Check 'Defender not running (0x800106ba): a note, not a warning' (@($log | Where-Object { $_ -match 'Defender is not running on this PC' }).Count -eq 1 -and @($log | Where-Object { $_ -match '\[!!\]' }).Count -eq 0)
function Get-MpPreference { [pscustomobject]@{ ExclusionPath = @($Script:Excl) } }

# ---- whole slipstream with stand-ins: background boot.wim runs during install.wim
function Assert-Analyzed { }
function Test-WorkDir { }
function Get-UpdateFiles { return @{ SSU = @('/u/ssu.msu'); LCU = @('/u/lcu.msu'); EKB = @(); SAFEOS = @('/u/safeos.cab'); SETUP = @(); NET = @(); NET481 = @() } }
function Get-ImageList { return @([ordered]@{ Index = 1; Name = 'Windows 10 Pro'; Version = '19045.6456' }) }
$Script:Cfg.ParallelEditions = 1           # editions one after the other here; several at the same time further down
foreach ($parallel in $true, $false) {
    Remove-Item $dlog -ErrorAction SilentlyContinue
    $env:FAKE_DISM_SLEEP = '0.2'
    Set-Content (Join-Path $P.Media 'sources/install.wim') 'installwim'; Set-Content (Join-Path $P.Media 'sources/boot.wim') 'bootwim'
    $Script:S = New-State
    $Script:S.Unpacked = $true; $Script:S.Family = [ordered]@{ Arch = 'x64'; Supported = $true }
    $Script:S.Images = @([ordered]@{ Index = 1; Name = 'Windows 10 Pro'; Edition = 'Professional'; Arch = 'x64'; Version = '19045.6456'; Size = 1 })
    $Script:S.Selected = @(1)
    $Script:Cfg.ParallelBoot = $parallel; $Script:Cfg.Boot2023 = $false; $Script:Cfg.NetFx3 = $false; $Script:Cfg.BootDrivers = $false
    $t = Get-Date
    Invoke-Service -Auto
    $took = ((Get-Date) - $t).TotalSeconds
    $c = @(Calls); $log = @(Drain)
    $firstBoot = [array]::FindIndex([string[]]$c, [Predicate[string]]{ param($x) $x -match 'boot_stage\.wim' -and $x -match '/Mount-Image' })
    $lastInstall = [array]::FindLastIndex([string[]]$c, [Predicate[string]]{ param($x) $x -match 'install_stage\.wim' -and $x -match '/Export-Image' })
    "  parallel=$parallel took $([math]::Round($took,1)) s, $($c.Count) DISM calls"
    Check "parallel=${parallel}: new install.wim and boot.wim in the media" ((Test-Path (Join-Path $P.Media 'sources/install.wim')) -and (Get-Content (Join-Path $P.Media 'sources/boot.wim') -Raw) -match 'wim' -and $Script:S.Serviced)
    if ($parallel) {
        Check 'parallel: boot.wim started before install.wim was finished' ($firstBoot -ge 0 -and $firstBoot -lt $lastInstall)
        $tPar = $took
    } else {
        Check 'sequential: boot.wim only after install.wim (as before)' ($firstBoot -gt $lastInstall)
        Check "parallel run was faster ($([math]::Round($tPar,1)) s vs $([math]::Round($took,1)) s)" ($tPar -lt $took)
    }
    Check "parallel=${parallel}: slipstream finished" (@($log | Where-Object { $_ -match 'Slipstream finished' }).Count -eq 1)
    $tt = [array]::IndexOf([string[]]$log, @($log | Where-Object { $_ -match '>> Time per step' })[0])
    $table = if ($tt -ge 0) { @($log[$tt..($log.Count - 1)]) } else { @() }
    Check "parallel=${parallel}: time per step at the end (staging, the edition's update, WinRE, boot.wim, total)" ($tt -ge 0 -and @($table | Where-Object { $_ -match '^\s+Staging\s+\d+:\d\d:\d\d' }).Count -eq 1 -and @($table | Where-Object { $_ -match 'Edition 1: Windows 10 Pro' }).Count -eq 1 -and @($table | Where-Object { $_ -match '^\s+cumulative update\s+\d+:\d\d:\d\d' }).Count -eq 1 -and @($table | Where-Object { $_ -match '^\s+WinRE\s' }).Count -eq 1 -and @($table | Where-Object { $_ -match '^\s+boot\.wim\s' }).Count -eq 1 -and @($table | Where-Object { $_ -match '^\s+Total\s+\d+:\d\d:\d\d' }).Count -eq 1)
    $reExport = [array]::FindIndex([string[]]$c, [Predicate[string]]{ param($x) $x -match '/Export-Image' -and $x -match 'winre_new\.wim' })
    $osCommit = [array]::FindIndex([string[]]$c, [Predicate[string]]{ param($x) $x -match '/Unmount-Image' -and $x -match 'mnt.os' -and $x -match '/Commit' })
    Check "parallel=${parallel}: WinRE updated and copied into the edition before it is saved" ($reExport -ge 0 -and $reExport -lt $osCommit -and @($log | Where-Object { $_ -match 'Updated WinRE copied into the image' }).Count -eq 1)
    $reOwn = @($c | Where-Object { $_ -match 'dism-re\.log' -and $_ -match 'scratch-re' }).Count
    if ($parallel) {
        Check 'parallel: WinRE ran in its own runspace (own DISM log and scratch folder)' ($reOwn -gt 0 -and @($log | Where-Object { $_ -match 'WinRE: background job finished after' }).Count -eq 1)
        $reMount = [array]::FindIndex([string[]]$c, [Predicate[string]]{ param($x) $x -match '/Mount-Image' -and $x -match 'winre\.wim' })
        $osAfter = @($c[($reMount + 1)..($reExport - 1)] | Where-Object { $_ -match 'mnt.os' }).Count
        Check "parallel: install.wim kept being serviced while WinRE was ($osAfter install.wim calls in between)" ($reMount -ge 0 -and $osAfter -gt 0)
    } else {
        Check 'sequential: WinRE inline, as before' ($reOwn -eq 0 -and @($c | Where-Object { $_ -match '/Mount-Image' -and $_ -match 'winre\.wim' -and $_ -match 'dism\.log' }).Count -eq 1)
    }
}
$env:FAKE_DISM_SLEEP = ''

# ---- WinRE fails: warned once, not tried again for the next edition, the slipstream goes on
foreach ($parallel in $true, $false) {
    Remove-Item $dlog -ErrorAction SilentlyContinue
    $env:FAKE_DISM_FAIL = 'winre.wim'
    Set-Content (Join-Path $P.Media 'sources/install.wim') 'installwim'; Set-Content (Join-Path $P.Media 'sources/boot.wim') 'bootwim'
    $Script:S = New-State
    $Script:S.Unpacked = $true; $Script:S.Family = [ordered]@{ Arch = 'x64'; Supported = $true }
    $Script:S.Images = @([ordered]@{ Index = 1; Name = 'Windows 10 Home'; Edition = 'Core'; Arch = 'x64'; Version = '19045.6456'; Size = 1 },
                         [ordered]@{ Index = 2; Name = 'Windows 10 Pro'; Edition = 'Professional'; Arch = 'x64'; Version = '19045.6456'; Size = 1 })
    $Script:S.Selected = @(1, 2)
    $Script:Cfg.ParallelBoot = $parallel
    Invoke-Service -Auto
    $env:FAKE_DISM_FAIL = ''
    $c = @(Calls); $log = @(Drain)
    Check "parallel=${parallel}: failed WinRE tried once for 2 editions, both editions still saved" (@($c | Where-Object { $_ -match '/Mount-Image' -and $_ -match 'winre\.wim' }).Count -eq 1 -and @($c | Where-Object { $_ -match '/Unmount-Image' -and $_ -match 'mnt.os' -and $_ -match '/Commit' }).Count -eq 2)
    Check "parallel=${parallel}: failed WinRE is a warning, the original WinRE stays" (@($log | Where-Object { $_ -match 'WinRE update skipped' }).Count -eq 1 -and @($log | Where-Object { $_ -match 'Updated WinRE copied' }).Count -eq 0 -and $Script:S.Serviced)
}

# ---- an ISO that already has the cumulative update: it is not unpacked again for any image
$realUpdateBuild = ${function:Get-UpdateBuild}
function Get-UpdateBuild { param($Msu) if ($Msu -match 'lcu') { return [pscustomobject]@{ Build = 19041; Rev = [int]$env:FAKE_LCU_REV } } }
$env:FAKE_IMG_VER = '10.0.19041.6456'; $env:FAKE_IMG_SP = '6456'
foreach ($case in @(@{ Rev = 6456; Jobs = 1 }, @{ Rev = 6456; Jobs = 2 }, @{ Rev = 6500; Jobs = 1 })) {
    Remove-Item $dlog -ErrorAction SilentlyContinue
    $env:FAKE_LCU_REV = [string]$case.Rev
    Set-Content (Join-Path $P.Media 'sources/install.wim') 'installwim'; Set-Content (Join-Path $P.Media 'sources/boot.wim') 'bootwim'
    $Script:S = New-State
    $Script:S.Unpacked = $true; $Script:S.Family = [ordered]@{ Arch = 'x64'; Supported = $true }
    $Script:S.Images = @([ordered]@{ Index = 1; Name = 'Windows 10 Home'; Edition = 'Core'; Arch = 'x64'; Version = '19045.6456'; Size = 1 },
                         [ordered]@{ Index = 2; Name = 'Windows 10 Pro'; Edition = 'Professional'; Arch = 'x64'; Version = '19045.6456'; Size = 1 })
    $Script:S.Selected = @(1, 2)
    $Script:Cfg.ParallelBoot = $true; $Script:Cfg.ParallelEditions = $case.Jobs
    Invoke-Service -Auto
    $c = @(Calls); $log = @(Drain)
    $lcuCalls = @($c | Where-Object { $_ -match '/Add-Package' -and $_ -match 'lcu\.msu' }).Count
    $tag = "update $($case.Rev), editions at once $($case.Jobs)"
    if ($case.Rev -eq 6456) {
        Check "${tag}: the update the images already have is skipped everywhere ($lcuCalls LCU calls)" ($lcuCalls -eq 0 -and @($log | Where-Object { $_ -match 'already at build 19045\.6456, skipped' }).Count -eq 2 -and @($log | Where-Object { $_ -match 'WinRE is already at build 19041\.6456, skipped' }).Count -eq 1 -and @($log | Where-Object { $_ -match 'boot\.wim index [12] is already at build 19041\.6456, skipped' }).Count -eq 2)
        Check "${tag}: the servicing stack still goes in, slipstream finished" (@($c | Where-Object { $_ -match '/Add-Package' -and $_ -match 'ssu\.msu' }).Count -eq 5 -and $Script:S.Serviced)
    } else {
        Check "${tag}: a newer update goes into every image, boot.wim in one pass ($lcuCalls LCU calls)" ($lcuCalls -eq 5 -and @($log | Where-Object { $_ -match 'skipped' -and $_ -match 'already at build' }).Count -eq 0)
    }
}
$env:FAKE_IMG_VER = ''; $env:FAKE_LCU_REV = ''
Set-Item Function:\Get-UpdateBuild $realUpdateBuild

# ---- several editions at the same time
$cores = [Environment]::ProcessorCount
$Script:Cfg.ParallelEditions = 0
$auto = (Get-EditionJobs 4 1000).Jobs
Check "editions at once, automatic: $auto on $cores core(s)" ($auto -eq $(if ($cores -ge 8) { 3 } elseif ($cores -ge 4) { 2 } else { 1 }))
$Script:Cfg.ParallelEditions = 3
$a = (Get-EditionJobs 2 1000).Jobs; $b = (Get-EditionJobs 4 60).Jobs; $c1 = (Get-EditionJobs 4 10).Jobs
$Script:Cfg.ParallelEditions = 9; $d = (Get-EditionJobs 9 1000).Jobs
Check "editions at once: never more than ticked ($a), about 25 GB each ($b, $c1), at most 4 ($d)" ($a -eq 2 -and $b -eq 2 -and $c1 -eq 1 -and $d -eq 4)
$realFreeGB = ${function:Get-FreeGB}
function Get-FreeGB { return 500.0 }
function New-Editions {
    Set-Content (Join-Path $P.Media 'sources/install.wim') 'installwim'; Set-Content (Join-Path $P.Media 'sources/boot.wim') 'bootwim'
    $Script:S = New-State
    $Script:S.Unpacked = $true; $Script:S.Family = [ordered]@{ Arch = 'x64'; Supported = $true }
    $Script:S.Images = @([ordered]@{ Index = 1; Name = 'Windows 10 Home'; Edition = 'Core'; Arch = 'x64'; Version = '19045.6456'; Size = 1 },
                         [ordered]@{ Index = 2; Name = 'Windows 10 Home N'; Edition = 'CoreN'; Arch = 'x64'; Version = '19045.6456'; Size = 1 },
                         [ordered]@{ Index = 3; Name = 'Windows 10 Pro'; Edition = 'Professional'; Arch = 'x64'; Version = '19045.6456'; Size = 1 },
                         [ordered]@{ Index = 4; Name = 'Windows 10 Education'; Edition = 'Education'; Arch = 'x64'; Version = '19045.6456'; Size = 1 })
    $Script:S.Selected = @(1, 3, 4)
}
$Script:Cfg.ParallelBoot = $true; $Script:Cfg.KeepOnlySelected = $false
$runTimes = @{}
foreach ($jobs in 2, 1) {
    Remove-Item $dlog -ErrorAction SilentlyContinue
    $env:FAKE_DISM_SLEEP = '0.3'
    New-Editions
    $Script:Cfg.ParallelEditions = $jobs
    $t = Get-Date
    Invoke-Service -Auto
    $runTimes[$jobs] = ((Get-Date) - $t).TotalSeconds
    $c = @(Calls); $log = @(Drain)
    "  editions at once=$jobs took $([math]::Round($runTimes[$jobs],1)) s, $($c.Count) DISM calls"
    if ($jobs -eq 2) {
        $open = 0; $max = 0
        foreach ($x in $c) {
            if ($x -match '/Mount-Image' -and $x -match 'mnt.os\d') { $open++; if ($open -gt $max) { $max = $open } }
            if ($x -match '/Unmount-Image' -and $x -match 'mnt.os\d') { $open-- }
        }
        Check "3 editions, 2 at once: at most 2 mounted together, and 2 were ($max)" ($max -eq 2)
        Check 'each ticked edition staged into a WIM of its own' (@(1, 3, 4 | Where-Object { $k = $_; @($c | Where-Object { $_ -match '/Export-Image' -and $_ -match "SourceIndex:$k " -and $_ -match "DestinationImageFile:\S*install_stage$k\.wim" }).Count -eq 1 }).Count -eq 3)
        $fin = @($c | Where-Object { $_ -match '/Export-Image' -and $_ -match 'install_final\.wim' } | ForEach-Object { if ($_ -match 'install_stage(\d)\.wim') { "ed$($Matches[1])" } elseif ($_ -match 'SourceIndex:(\d)') { "src$($Matches[1])" } })
        Check "new install.wim in the original order, the unticked edition taken as it is ($($fin -join ','))" (($fin -join ',') -eq 'ed1,src2,ed3,ed4')
        Check 'every edition in its own background job (own DISM log and scratch folder)' (@(1, 3, 4 | Where-Object { $k = $_; @($c | Where-Object { $_ -match "dism-ed$k\.log" -and $_ -match "scratch-ed$k" -and $_ -match '/Add-Package' }).Count -ge 2 }).Count -eq 3)
        $reExport = [array]::FindIndex([string[]]$c, [Predicate[string]]{ param($x) $x -match '/Export-Image' -and $x -match 'winre_new\.wim' })
        $commits = @(for ($i = 0; $i -lt $c.Count; $i++) { if ($c[$i] -match '/Unmount-Image' -and $c[$i] -match 'mnt.os\d' -and $c[$i] -match '/Commit') { $i } })
        Check 'WinRE updated once, before any edition was saved, and copied into all three' (@($c | Where-Object { $_ -match '/Mount-Image' -and $_ -match 'winre\.wim' }).Count -eq 1 -and $reExport -ge 0 -and $commits.Count -eq 3 -and @($commits | Where-Object { $_ -lt $reExport }).Count -eq 0 -and @($log | Where-Object { $_ -match 'Updated WinRE copied into the image' }).Count -eq 3)
        Check 'the logs of the three editions, WinRE and boot.wim follow' (@($log | Where-Object { $_ -match '^\s+Edition [134]: background job finished after' }).Count -eq 3 -and @($log | Where-Object { $_ -match 'WinRE: background job finished' }).Count -eq 1 -and @($log | Where-Object { $_ -match 'boot\.wim: background job finished' }).Count -eq 1)
        Check 'log says how many editions run at once' (@($log | Where-Object { $_ -match '2 of the 3 editions are updated at the same time' }).Count -eq 1)
        $tt = [array]::IndexOf([string[]]$log, @($log | Where-Object { $_ -match '>> Time per step' })[0])
        $table = if ($tt -ge 0) { @($log[$tt..($log.Count - 1)]) } else { @() }
        $order = @($table | Where-Object { $_ -match '^\s{5}\S' -and $_ -notmatch 'Time per step|^\s+\(parts' } | ForEach-Object { ($_.Trim() -split '\s{2,}')[0] })
        Check "time per step: editions in order, then the others, WinRE, boot.wim, media ($($order -join ' | '))" (($order -join '|') -match '^Edition 1: Windows 10 Home\|Edition 3: Windows 10 Pro\|Edition 4: Windows 10 Education\|Other editions \(not updated\)\|WinRE\|boot\.wim\|Media folder\|Total$')
        Check 'time per step: an edition shows stage, cumulative update, waiting for WinRE or not, save, export' (@($table | Where-Object { $_ -match '^\s+stage \(export into its own WIM\)' }).Count -eq 3 -and @($table | Where-Object { $_ -match '^\s+export into install\.wim' }).Count -eq 3 -and @($table | Where-Object { $_ -match '^\s+save\s+\d+:' }).Count -eq 3 -and @($table | Where-Object { $_ -match 'add up to more than the total' }).Count -eq 1)
        $table | ForEach-Object { "  | $_" }
        Check 'edition WIM files and mount folders removed, media serviced' (-not (Test-Path $P.Temp) -and @(Get-ChildItem (Split-Path $P.Mount -Parent) -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^os\d+$' }).Count -eq 0 -and $Script:S.Serviced -and $null -eq $Script:Sync.SideSync)
    } else {
        Check 'editions at once = 1: one after the other in one stage WIM, as before' (@($c | Where-Object { $_ -match 'install_stage\d\.wim' }).Count -eq 0 -and @($c | Where-Object { $_ -match '/Mount-Image' -and $_ -match 'install_stage\.wim' }).Count -eq 3)
        Check "3 editions: 2 at once was faster ($([math]::Round($runTimes[2],1)) s vs $([math]::Round($runTimes[1],1)) s)" ($runTimes[2] -lt $runTimes[1])
    }
}
# an edition fails: the others are stopped, mounts discarded, the media stays as it was
Remove-Item $dlog -ErrorAction SilentlyContinue
$env:FAKE_DISM_SLEEP = '0.2'; $env:FAKE_DISM_FAIL = 'os3'
New-Editions
$Script:Cfg.ParallelEditions = 2
$msg = $null
try { Invoke-Service -Auto } catch { $msg = $_.Exception.Message }
$env:FAKE_DISM_FAIL = ''
$log = @(Drain)
Check "an edition fails: the error names it ($msg)" ($msg -match '^Edition 3: Mount install_stage3\.wim #1 failed')
Check 'an edition fails: the other jobs are stopped, nothing left running' (@($log | Where-Object { $_ -match 'Stopping edition 1 in the background' }).Count -eq 1 -and $null -eq $Script:Sync.SideSync)
Check 'an edition fails: media not changed, not marked serviced' ((Get-Content (Join-Path $P.Media 'sources/install.wim') -Raw).Trim() -eq 'installwim' -and -not $Script:S.Serviced)
Remove-Item (Split-Path $P.Mount -Parent) -Recurse -Force -ErrorAction SilentlyContinue    # the stand-in has no real mounts for Clear-Mounts to discard
# no background worker: the editions are updated one after the other
Remove-Item $dlog -ErrorAction SilentlyContinue
$env:FAKE_DISM_SLEEP = ''
New-Editions
$keepEngine = $Script:EngineText; $Script:EngineText = $null
Invoke-Service -Auto
$Script:EngineText = $keepEngine
$c = @(Calls); $log = @(Drain)
Check 'no background worker: warned, editions one after the other, slipstream finished' (@($log | Where-Object { $_ -match 'background workers for the editions could not start' }).Count -eq 1 -and @($c | Where-Object { $_ -match '/Mount-Image' -and $_ -match 'install_stage\.wim' }).Count -eq 3 -and $Script:S.Serviced)
Set-Item Function:\Get-FreeGB $realFreeGB
$Script:Cfg.ParallelEditions = 0; $Script:Cfg.KeepOnlySelected = $true

# ---- Clean up: the new options leave nothing behind
function New-WorkLeftovers {
    foreach ($d in 'drivers/selected/host/x', 'logs', 'signed/NVIDIA', 'output', 'updates/LCU') { New-Item -ItemType Directory -Force (Join-Path $P.Work $d) | Out-Null }
    foreach ($f in 'autounattend.xml', 'autounattend.original.xml', 'install-check.json', 'logs/engine.log', 'logs/dism.log') { Set-Content (Join-Path $P.Work $f) 'x' }
    $Script:S = New-State; $Script:S.Drivers = @(@{ Inf = 'a.inf' }); $Script:S.Unattend = @{ Source = 'C:\Users\User\Desktop\autounattend.xml' }; $Script:S.Check = @{ Errors = 0 }
    Save-State
}
New-WorkLeftovers
Invoke-CleanJob @{ Drivers = $true; Extra = $true; Logs = $true }
$st = Import-State
Check 'clean: copied drivers deleted and forgotten' (-not (Test-Path (Join-Path $P.Work 'drivers')) -and @($st.Drivers).Count -eq 0)
Check 'clean: answer file copy + check results deleted, answer file must be chosen again' (-not (Test-Path (Join-Path $P.Work 'autounattend.xml')) -and -not (Test-Path (Join-Path $P.Work 'install-check.json')) -and -not $st.Unattend -and -not $st.Check)
Check 'clean: logs emptied' (@(Get-ChildItem (Join-Path $P.Work 'logs')).Count -eq 0)
Check 'clean: other parts kept when not ticked' ((Test-Path (Join-Path $P.Work 'signed/NVIDIA')) -and (Test-Path (Join-Path $P.Work 'updates/LCU')))
New-WorkLeftovers
Set-Content (Join-Path $P.Work 'notes-of-mine.txt') 'keep me'
Invoke-CleanJob @{ Updates = $true; Media = $true; Output = $true; Signed = $true; Drivers = $true; Extra = $true; Logs = $true; All = $true }
$left = @(Get-ChildItem $P.Work -Force | ForEach-Object Name)
Check "everything: only a file the tool did not make is left ($($left -join ', '))" (($left -join ',') -eq 'notes-of-mine.txt')
Check 'everything: state starts empty' (-not (Test-Path $P.State) -and @((Import-State).Drivers).Count -eq 0)
$null = Drain
New-Item -ItemType Directory -Force $P.Logs | Out-Null

Remove-Item Env:\FAKE_DISM_LOG, Env:\FAKE_DISM_SLEEP, Env:\FAKE_DISM_FAIL -ErrorAction SilentlyContinue
Remove-Item $tmp -Recurse -Force
if ($fails) { exit 1 }
exit 0
