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

function Get-WindowsImage { param($ImagePath, [switch]$Mounted) if ($Mounted) { return @() }; return @(1, 2) }
'@
$Script:EngineText = $body.Substring($b, $e - $b) + $stubs
. ([scriptblock]::Create($stubs))
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_svc_' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory $tmp | Out-Null
$env:W10U_SELF = Join-Path $tmp 'Win10-ISO-Updater.cmd'
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
Check 'inline: LCU added twice per index (servicing stack + update)' (@($c | Where-Object { $_ -match 'lcu\.msu' }).Count -eq 4)
Check 'inline: setup.exe and boot files saved for the media' ((Test-Path (Join-Path $ctx.BfDir 'setup.exe')) -and (Test-Path (Join-Path $ctx.BfDir 'bootmgfw.efi')))
Check 'inline: 2023 boot files saved' ($r.ExSaved -and (Test-Path (Join-Path $ctx.ExDir 'EFI_EX')))
$null = Drain

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
$side = $Script:Sync.SideSync
Check "side status visible to the window ($($side.Label))" ($side -and $side.Label -match '^boot\.wim [12]/2')
$r = Wait-BootWimJob $job
$log = @(Drain)
$c = @(Calls)
Check 'background: result returned (2023 boot files saved)' ($r -and $r.ExSaved)
Check 'background: boot.wim log shown in the Activity log' (@($log | Where-Object { $_ -match 'Updating boot\.wim' }).Count -eq 1 -and @($log | Where-Object { $_ -match 'boot\.wim done \(ran alongside install\.wim' }).Count -eq 1)
Check 'background: own DISM log and scratch folder' (@($c | Where-Object { $_ -match 'dism-boot\.log' -and $_ -match '/Image:' -and $_ -match 'scratch-pe' }).Count -gt 0)
Check 'background: its engine log is merged into engine.log' ((Get-Content $Script:LogFile -Raw) -match 'boot\.wim \(background\) log' -and -not (Test-Path (Join-Path $P.Logs 'engine-boot.log')))
Check 'background: side status cleared' ($null -eq $Script:Sync.SideSync)

# ---- background job error is reported by the main job
Remove-Item $dlog, $ctx.BootFin -ErrorAction SilentlyContinue
$env:FAKE_DISM_SLEEP = ''; $env:FAKE_DISM_FAIL = 'boot_stage.wim'
$job = Start-BootWimJob (New-Ctx $false)
$msg = $null
try { [void](Wait-BootWimJob $job) } catch { $msg = $_.Exception.Message }
Check "background error surfaces as 'boot.wim: ...' ($msg)" ($msg -match '^boot\.wim: Mount boot_stage\.wim #1 failed')
$env:FAKE_DISM_FAIL = ''
$null = Drain

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

# ---- whole slipstream with stand-ins: background boot.wim runs during install.wim
function Assert-Analyzed { }
function Test-WorkDir { }
function Get-UpdateFiles { return @{ SSU = @('/u/ssu.msu'); LCU = @('/u/lcu.msu'); EKB = @(); SAFEOS = @('/u/safeos.cab'); SETUP = @(); NET = @(); NET481 = @() } }
function Get-ImageList { return @([ordered]@{ Index = 1; Name = 'Windows 10 Pro'; Version = '19045.6456' }) }
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
}
$env:FAKE_DISM_SLEEP = ''

Remove-Item Env:\FAKE_DISM_LOG, Env:\FAKE_DISM_SLEEP, Env:\FAKE_DISM_FAIL -ErrorAction SilentlyContinue
Remove-Item $tmp -Recurse -Force
if ($fails) { exit 1 }
exit 0
