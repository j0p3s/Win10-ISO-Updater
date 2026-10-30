#region ---------------------------------------------------------------- [6] Slipstream
function Save-BootFiles2023([string]$MountDir, [string]$Dest) {
    $boot = Join-Path $MountDir 'Windows\Boot'
    $need = @('EFI_EX', 'FONTS_EX', 'DVD_EX')
    foreach ($n in $need) { if (-not (Test-Path -LiteralPath (Join-Path $boot $n))) { return $false } }
    Reset-Dir $Dest
    foreach ($n in $need) { Copy-Item -LiteralPath (Join-Path $boot $n) -Destination (Join-Path $Dest $n) -Recurse -Force }
    return $true
}
function Set-Boot2023([string]$Src) {
    # Same file swaps as Microsoft's Make2023BootableMedia.ps1
    $m = $Script:P.Media
    $efiBoot = Join-Path $m 'efi\boot'
    $bootName = if (Test-Path -LiteralPath (Join-Path $efiBoot 'bootaa64.efi')) { 'bootaa64.efi' } else { 'bootx64.efi' }
    Copy-Item -LiteralPath (Join-Path $Src 'EFI_EX\bootmgfw_EX.efi') -Destination (Join-Path $efiBoot $bootName) -Force
    if (Test-Path -LiteralPath (Join-Path $Src 'EFI_EX\bootmgr_EX.efi')) {
        Copy-Item -LiteralPath (Join-Path $Src 'EFI_EX\bootmgr_EX.efi') -Destination (Join-Path $m 'bootmgr.efi') -Force
    }
    $msBoot = Join-Path $m 'efi\microsoft\boot'
    $bins = @(Get-ChildItem -LiteralPath (Join-Path $Src 'DVD_EX') -Recurse -Filter 'efisys*_EX.bin' -File)
    $pref = @($bins | Where-Object { $_.DirectoryName -match '\\en-US$' })
    if ($pref.Count -gt 0) { $bins = $pref }
    $one = $bins | Where-Object { $_.Name -ieq 'efisys_EX.bin' } | Select-Object -First 1
    if (-not $one) { throw 'efisys_EX.bin was not found in the updated image.' }
    Copy-Item -LiteralPath $one.FullName -Destination (Join-Path $msBoot 'efisys_ex.bin') -Force
    $np = $bins | Where-Object { $_.Name -ieq 'efisys_noprompt_EX.bin' } | Select-Object -First 1
    if ($np) { Copy-Item -LiteralPath $np.FullName -Destination (Join-Path $msBoot 'efisys_noprompt_ex.bin') -Force }
    $fonts = Join-Path $msBoot 'fonts'
    New-Item -ItemType Directory -Force -Path $fonts | Out-Null
    foreach ($ttf in @(Get-ChildItem -LiteralPath (Join-Path $Src 'FONTS_EX') -File)) {
        Copy-Item -LiteralPath $ttf.FullName -Destination (Join-Path $fonts ($ttf.Name -replace '_EX', '')) -Force
    }
}

# ---- storage / network drivers for WinRE and boot.wim: one DISM call instead of one per driver
# Each driver folder is copied into one set (only its own INF kept), so /Recurse adds exactly
# those drivers. Very big folders (vendor packs) are added one INF at a time instead.
function New-BootDriverSet([string[]]$Infs, [string]$Dest) {
    $Infs = @($Infs | Where-Object { $_ })
    $set = [pscustomobject]@{ Folder = $null; Singles = @(); Count = $Infs.Count }
    if ($set.Count -eq 0) { return $set }
    Reset-Dir $Dest
    $n = 0
    foreach ($inf in $Infs) {
        $dir = Split-Path $inf -Parent
        $size = [double](Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($size -gt 300MB) { $set.Singles += $inf; continue }
        $n++
        $to = Join-Path $Dest ('{0:D3}' -f $n)
        New-Item -ItemType Directory -Force -Path $to | Out-Null
        Get-ChildItem -LiteralPath $dir -Force | Copy-Item -Destination $to -Recurse -Force
        $keep = Split-Path $inf -Leaf
        Get-ChildItem -LiteralPath $to -Recurse -File -Force | Where-Object { $_.Extension -ieq '.inf' -and -not ($_.DirectoryName -eq $to -and $_.Name -ieq $keep) } | Remove-Item -Force
    }
    if ($n -gt 0) { $set.Folder = $Dest }
    return $set
}
function Add-BootDrivers([string]$MountDir, $Set, [string]$Fu, [string]$Label) {
    if (-not $Set -or $Set.Count -eq 0) { return }
    Write-Sub "Storage/network drivers ($($Set.Count))"
    if ($Set.Folder) { Invoke-Dism "/Image:$(Q $MountDir) /Add-Driver /Driver:$(Q $Set.Folder) /Recurse$Fu" "$Label drivers" -Soft }
    foreach ($inf in @($Set.Singles)) { Invoke-Dism "/Image:$(Q $MountDir) /Add-Driver /Driver:$(Q $inf)$Fu" "$Label driver" -Soft }
}

function Set-SideLabel([string]$Text) { if ($Script:Sync) { $Script:Sync.Label = $Text } }
# ---- time per step: every job of the slipstream (also the background ones) adds its steps to one queue,
# shown as a table at the end, so it is plain where the time goes on this PC.
function Add-Timing($Times, [string]$Part, [string]$Step, [datetime]$Start) {
    if ($null -eq $Times) { return }
    $Times.Enqueue([pscustomobject]@{ Part = $Part; Step = $Step; Secs = ((Get-Date) - $Start).TotalSeconds })
}
function Write-TimingTable($Times, [TimeSpan]$Total) {
    $rows = @($Times.ToArray())
    if (-not $rows.Count) { return }
    $rank = {
        param($p)
        if ($p -match '^Staging') { return 0 }
        if ($p -match '^Edition (\d+)') { return [int]$Matches[1] }
        switch -regex ($p) { '^Other' { return 900 } '^WinRE' { return 1000 } '^boot' { return 1001 } }
        return 1002
    }
    $parts = @($rows | ForEach-Object { $_.Part } | Select-Object -Unique | Sort-Object { & $rank $_ })
    Write-Step 'Time per step'
    foreach ($p in $parts) {
        $mine = @($rows | Where-Object { $_.Part -eq $p })
        $sum = 0.0; foreach ($r in $mine) { $sum += $r.Secs }
        Write-Info ('{0,-46} {1}' -f (Limit-Text $p 46), (Format-Span ([timespan]::FromSeconds([math]::Round($sum)))))
        foreach ($r in $mine) { Write-Info ('   {0,-43} {1}' -f (Limit-Text $r.Step 43), (Format-Span ([timespan]::FromSeconds([math]::Round($r.Secs))))) }
    }
    Write-Info ('{0,-46} {1}' -f 'Total', (Format-Span ([timespan]::FromSeconds([math]::Round($Total.TotalSeconds)))))
    if (@($parts | Where-Object { $_ -match '^(boot|WinRE|Edition)' }).Count -gt 1) { Write-Info '(parts that run at the same time add up to more than the total)' }
}
function Get-FreeGB([string]$Path) {
    try { return (New-Object IO.DriveInfo -ArgumentList ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)))).AvailableFreeSpace / 1GB } catch { return 0.0 }
}
# Editions updated at the same time: the setting (1-4), or automatic - 2 on 4+ processor cores, 3 on 8+ -
# never more than the editions ticked, and about 25 GB free on the work drive for each.
function Get-EditionJobs([int]$Count, [double]$FreeGB) {
    $n = 0
    if ($Script:Cfg) { $n = [int]$Script:Cfg.ParallelEditions }
    if ($n -lt 1) { $c = [Environment]::ProcessorCount; $n = if ($c -ge 8) { 3 } elseif ($c -ge 4) { 2 } else { 1 } }
    $n = [int][math]::Max(1, [math]::Min([math]::Min(4, $n), $Count))
    $space = [int][math]::Max(1, [math]::Floor($FreeGB / 25))
    return [pscustomobject]@{ Jobs = [int][math]::Min($n, $space); Wanted = $n; Space = $space }
}
# ---- updates the image already has. An ISO that Microsoft refreshed ("updated Oct 2025") already carries
# the cumulative update, and DISM unpacks the whole .msu (3-4 minutes per image) only to report "already in
# the correct state". The build an update brings is in the XML inside the .msu (Package_for_RollupFix
# version), the build of an image in its WIM metadata - an update the image is already at is skipped.
function Read-MsuXml([string]$Text) {
    $out = @()
    foreach ($m in [regex]::Matches($Text, '<assemblyIdentity\b[^>]*>')) {
        $n = [regex]::Match($m.Value, '\bname="([^"]+)"').Groups[1].Value
        $v = [regex]::Match($m.Value, '\bversion="([^"]+)"').Groups[1].Value
        if ($n -and $v) { $out += [pscustomobject]@{ Name = $n; Version = $v } }
    }
    return $out
}
# Build and revision of the cumulative update in a .msu (19041.6456), or $null when it cannot be read.
function Get-UpdateBuild([string]$Msu) {
    if ($Msu -notmatch '(?i)\.msu$') { return $null }
    $dir = Join-Path $Script:P.Temp ('msuxml_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $exe = if ($Script:ExpandExe) { $Script:ExpandExe } else { Join-Path $env:SystemRoot 'System32\expand.exe' }
        $r = Invoke-Native $exe @($Msu, '-F:*.xml', $dir)
        Add-Log $r.Text
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.xml -File -Recurse -ErrorAction SilentlyContinue)) {
            foreach ($x in @(Read-MsuXml ([IO.File]::ReadAllText($f.FullName)))) {
                if ($x.Name -like 'Package_for_RollupFix*') { $v = [version]$x.Version; return [pscustomobject]@{ Build = $v.Major; Rev = $v.Minor } }
            }
        }
    } catch { Add-Log "Build of $Msu not read: $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    return $null
}
# "19041.6456" for one image of a WIM file, '' when it cannot be read.
function Get-ImageVersion([string]$ImageFile, [int]$Index) {
    try {
        $d = Get-WindowsImage -ImagePath $ImageFile -Index $Index -ErrorAction Stop
        if ($d.Version -and $null -ne $d.SPBuild) { return ('{0}.{1}' -f ([version]$d.Version).Build, [int]$d.SPBuild) }
    } catch { }
    return ''
}
# $true when the image ("19045.6456") is already at the build the update brings (same servicing base).
function Test-UpdateInImage($Update, [string]$ImgVersion) {
    if (-not $Update -or $ImgVersion -notmatch '^(\d+)\.(\d+)$') { return $false }
    return ((Get-BaseBuild ([int]$Matches[1])) -eq (Get-BaseBuild ([int]$Update.Build)) -and [int]$Matches[2] -ge [int]$Update.Rev)
}
# ---- the updates of one mounted edition (the same in the main job and in an edition job)
function Add-EditionUpdates([string]$MountDir, $Upd, [string]$Fu, [string]$LcuTip, [bool]$HasDrv, $Times, [string]$Part, [string]$ImgVersion = '', $LcuBuild = @{}) {
    $Cfg = $Script:Cfg
    Write-Step 'Updating Windows'
    if ($HasDrv) {
        $t = Get-Date
        Write-Sub "Drivers ($(@($Script:S.Drivers).Count) packages)"
        Invoke-Dism "/Image:$(Q $MountDir) /Add-Driver /Driver:$(Q $Script:P.DrvSel) /Recurse$Fu" 'Add drivers' -Soft
        Add-Timing $Times $Part 'drivers' $t
    }
    $t = Get-Date
    foreach ($x in @($Upd.SSU)) { Set-SideLabel "$Part servicing stack"; Add-Pkg $MountDir $x 'Servicing stack' -Soft }
    if (@($Upd.SSU).Count) { Add-Timing $Times $Part 'servicing stack' $t }
    $t = Get-Date; $done = 0
    foreach ($x in @($Upd.LCU)) {
        if ($LcuBuild -and (Test-UpdateInImage $LcuBuild[$x] $ImgVersion)) { Write-Sub "Cumulative update : $(Split-Path $x -Leaf) - this edition is already at build $ImgVersion, skipped"; continue }
        Set-SideLabel "$Part cumulative update"
        try { Add-Pkg $MountDir $x 'Cumulative update' -IgnoreHex @('800F081E') }
        catch { Write-Err $LcuTip; throw }
        $done++
    }
    if ($done) { Add-Timing $Times $Part 'cumulative update' $t }
    $t = Get-Date
    foreach ($x in @($Upd.EKB)) { Set-SideLabel "$Part enablement package"; Add-Pkg $MountDir $x 'Enablement package' -IgnoreHex @('800F081E') -Soft }
    if (@($Upd.EKB).Count) { Add-Timing $Times $Part 'enablement package' $t }
    if ($Cfg.ResetBase) { $t = Get-Date; Set-SideLabel "$Part component cleanup"; Invoke-ImageCleanup $MountDir 'Windows'; Add-Timing $Times $Part 'component cleanup (/ResetBase)' $t }
    if ($Cfg.NetFx3) {
        $sxs = Join-Path $Script:P.Media 'sources\sxs'
        if (Test-Path -LiteralPath $sxs) {
            $t = Get-Date
            Set-SideLabel "$Part .NET 3.5"
            Write-Sub '.NET Framework 3.5 (from sources\sxs)'
            Invoke-Dism "/Image:$(Q $MountDir) /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$(Q $sxs)" 'Enable .NET 3.5' -Soft
            Add-Timing $Times $Part '.NET Framework 3.5' $t
        } else { Write-Warn 'sources\sxs not found - .NET 3.5 skipped.' }
    }
    $t = Get-Date
    foreach ($x in @($Upd.NET481)) { Set-SideLabel "$Part .NET 4.8.1"; Add-Pkg $MountDir $x '.NET Framework 4.8.1' -IgnoreHex @('800F081E') -Soft }
    foreach ($x in @($Upd.NET)) { Set-SideLabel "$Part .NET update"; Add-Pkg $MountDir $x '.NET cumulative update' -IgnoreHex @('800F081E') -Soft }
    if (@($Upd.NET481).Count + @($Upd.NET).Count) { Add-Timing $Times $Part '.NET updates' $t }
}
# ---- boot.wim (WinPE + Setup). Runs in its own runspace while install.wim is serviced
# (Options: "Update boot.wim and WinRE at the same time"), or inline. Returns what the media step needs.
function Invoke-BootWimService($Ctx) {
    $res = [pscustomobject]@{ ExSaved = $false; Count = 0 }
    Write-Title 'Updating boot.wim (WinPE / Setup)'
    Copy-Item -LiteralPath (Join-Path $Ctx.Media 'sources\boot.wim') -Destination $Ctx.BootSt -Force
    (Get-Item -LiteralPath $Ctx.BootSt -Force).Attributes = 'Normal'
    $bootCount = @(Get-WindowsImage -ImagePath $Ctx.BootSt).Count
    $res.Count = $bootCount
    $upd = $Ctx.Upd
    $tq = $Ctx.Times
    for ($b = 1; $b -le $bootCount; $b++) {
        Set-SideLabel "boot.wim $b/$bootCount"
        $t = Get-Date
        if ($Ctx.SkipPE -and $b -eq 1 -and $bootCount -ge 2) {
            Write-Step "boot.wim index 1 of $bootCount (Windows PE) - kept as it is (option)"
            Export-Img $Ctx.BootSt $b $Ctx.BootFin
            Add-Timing $tq 'boot.wim' 'index 1: kept as it is, export' $t
            continue
        }
        Write-Step "boot.wim index $b of $bootCount"
        $iv = Get-ImageVersion $Ctx.BootSt $b
        Mount-Img $Ctx.BootSt $b $Ctx.MountPE
        Add-Timing $tq 'boot.wim' "index ${b}: mount" $t
        $t = Get-Date
        foreach ($x in @($upd.SSU)) { Set-SideLabel "boot.wim $b/$bootCount servicing stack"; Add-Pkg $Ctx.MountPE $x 'Servicing stack' -Soft }
        foreach ($x in @($upd.LCU)) {
            if ($Ctx.LcuBuild -and (Test-UpdateInImage $Ctx.LcuBuild[$x] $iv)) { Write-Sub "Cumulative update : $(Split-Path $x -Leaf) - boot.wim index $b is already at build $iv, skipped"; continue }
            Set-SideLabel "boot.wim $b/$bootCount cumulative update"
            # Microsoft's way for WinPE: the first pass installs the servicing stack in the update and may stop
            # with 0x8007007E; the second one installs the rest. When the first pass installed it all, or the
            # update does not apply, a second pass only unpacks the whole update again.
            Add-Pkg $Ctx.MountPE $x 'Servicing stack via LCU' -IgnoreHex @('8007007E', '800F081E') -Soft
            if (@(0, 3010, [Convert]::ToInt32('800F081E', 16)) -contains $Script:LastDism) { Write-Sub 'Cumulative update installed (or not needed) in that pass - no second pass'; continue }
            Add-Pkg $Ctx.MountPE $x 'Cumulative update' -IgnoreHex @('800F081E') -Soft
        }
        Add-Timing $tq 'boot.wim' "index ${b}: updates" $t
        Set-SideLabel "boot.wim $b/$bootCount drivers"
        $t = Get-Date
        Add-BootDrivers $Ctx.MountPE $Ctx.BootSet $Ctx.Fu 'WinPE'
        if ($Ctx.BootSet -and ($Ctx.BootSet.Folder -or @($Ctx.BootSet.Singles).Count)) { Add-Timing $tq 'boot.wim' "index ${b}: drivers" $t }
        Set-SideLabel "boot.wim $b/$bootCount cleanup"
        $t = Get-Date
        Invoke-ImageCleanup $Ctx.MountPE 'WinPE'
        Add-Timing $tq 'boot.wim' "index ${b}: cleanup" $t
        if (Test-Path -LiteralPath (Join-Path $Ctx.MountPE 'sources\setup.exe')) {
            Copy-Item -LiteralPath (Join-Path $Ctx.MountPE 'sources\setup.exe') -Destination (Join-Path $Ctx.BfDir 'setup.exe') -Force
            foreach ($n in 'bootmgfw.efi', 'bootmgr.efi', 'boot.stl') {
                $f = Join-Path $Ctx.MountPE "Windows\Boot\EFI\$n"
                if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $Ctx.BfDir $n) -Force }
            }
        }
        if ($Ctx.Boot2023 -and -not $res.ExSaved) { $res.ExSaved = [bool](Save-BootFiles2023 $Ctx.MountPE $Ctx.ExDir) }
        Set-SideLabel "boot.wim $b/$bootCount saving"
        $t = Get-Date
        Dismount-Img $Ctx.MountPE -Commit
        Export-Img $Ctx.BootSt $b $Ctx.BootFin
        Add-Timing $tq 'boot.wim' "index ${b}: save and export" $t
    }
    Set-SideLabel ''
    return $res
}
# ---- WinRE (recovery environment, taken from the first edition). Runs in its own runspace while that
# edition is serviced (same option as boot.wim), or inline. $true = $Ctx.ReNew is ready for every edition.
function Invoke-WinReService($Ctx) {
    Write-Step 'Updating WinRE (recovery environment)'
    $ok = $false
    $tq = $Ctx.Times
    try {
        Set-SideLabel 'WinRE mounting'
        $t = Get-Date
        $iv = Get-ImageVersion $Ctx.ReWim 1
        Mount-Img $Ctx.ReWim 1 $Ctx.MountRE
        Add-Timing $tq 'WinRE' 'mount' $t
        $t = Get-Date
        foreach ($x in @($Ctx.Upd.SSU)) { Set-SideLabel 'WinRE servicing stack'; Add-Pkg $Ctx.MountRE $x 'Servicing stack' -Soft }
        foreach ($x in @($Ctx.Upd.LCU)) {
            if ($Ctx.LcuBuild -and (Test-UpdateInImage $Ctx.LcuBuild[$x] $iv)) { Write-Sub "Cumulative update : $(Split-Path $x -Leaf) - WinRE is already at build $iv, skipped"; continue }
            Set-SideLabel 'WinRE servicing stack'; Add-Pkg $Ctx.MountRE $x 'Servicing stack via LCU' -IgnoreHex @('8007007E', '800F081E') -Soft
        }
        foreach ($x in @($Ctx.Upd.SAFEOS)) { Set-SideLabel 'WinRE Safe OS update'; Add-Pkg $Ctx.MountRE $x 'Safe OS Dynamic Update' -Soft }
        Add-Timing $tq 'WinRE' 'updates' $t
        Set-SideLabel 'WinRE drivers'
        $t = Get-Date
        Add-BootDrivers $Ctx.MountRE $Ctx.BootSet $Ctx.Fu 'WinRE'
        if ($Ctx.BootSet -and ($Ctx.BootSet.Folder -or @($Ctx.BootSet.Singles).Count)) { Add-Timing $tq 'WinRE' 'drivers' $t }
        Set-SideLabel 'WinRE cleanup'
        $t = Get-Date
        Invoke-ImageCleanup $Ctx.MountRE 'WinRE'
        Add-Timing $tq 'WinRE' 'cleanup' $t
        Set-SideLabel 'WinRE saving'
        $t = Get-Date
        Dismount-Img $Ctx.MountRE -Commit
        Export-Img $Ctx.ReWim 1 $Ctx.ReNew
        Add-Timing $tq 'WinRE' 'save and export' $t
        $ok = $true
    } catch {
        Write-Warn "WinRE update skipped: $($_.Exception.Message)"
        try { Dismount-Img $Ctx.MountRE } catch { }
    }
    Set-SideLabel ''
    # editions updated at the same time wait for this before they are saved
    if ($Ctx.Shared) { $Ctx.Shared.Re = $(if ($ok) { 'ready' } else { 'failed' }) }
    return $ok
}
# The engine text (to load it into another runspace): this file, between the engine markers.
function Get-EngineText {
    if ($Script:EngineText) { return $Script:EngineText }
    try {
        $all = [IO.File]::ReadAllText($env:W10U_SELF)
        $b = $all.IndexOf('#ENGINE-' + 'BEGIN'); $e = $all.IndexOf('#ENGINE-' + 'END')
        if ($b -ge 0 -and $e -gt $b) { return $all.Substring($b, $e - $b) }
    } catch { }
    return $null
}
# ---- side jobs: boot.wim, WinRE and the servicing stack lookup run in a runspace of their own (with the
# engine loaded) while the main job goes on. Each has its own engine log, DISM log and scratch folder;
# its Activity lines follow when it is joined, and the window shows its status next to the main one.
# $Spec: Name (shown), Command (takes -Ctx), Tag (log names), Scratch (folder name), DismMatch (to end its dism.exe).
function Start-SideJob($Spec, $Ctx) {
    $engine = Get-EngineText
    if (-not $engine) { return $null }
    $sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = ''; Label = "$($Spec.Name) starting" })
    $p = @{}; foreach ($k in $Script:P.Keys) { $p[$k] = $Script:P[$k] }
    $p.Scratch = Join-Path $Script:P.Temp $Spec.Scratch
    $rs = [runspacefactory]::CreateRunspace([Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $sync)
    $rs.SessionStateProxy.SetVariable('IsWorker', $false)       # no Yes/No questions from here
    $init = [PowerShell]::Create(); $init.Runspace = $rs
    $why = $null
    try { [void]$init.AddScript($engine).Invoke(); if ($init.HadErrors) { $why = [string]$init.Streams.Error[0] } }
    catch { $why = $_.Exception.Message }
    $init.Dispose()
    if ($why) { Add-Log "$($Spec.Name) background worker: $why"; $rs.Dispose(); return $null }
    $log = Join-Path $Script:P.Logs "engine-$($Spec.Tag).log"
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    foreach ($kv in @{ P = $p; Cfg = $Script:Cfg; S = $Script:S; Dism = $Script:Dism; LogFile = $log; DismLog = (Join-Path $Script:P.Logs "dism-$($Spec.Tag).log") }.GetEnumerator()) {
        $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
    }
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddCommand($Spec.Command).AddParameter('Ctx', $Ctx)
    $job = [pscustomobject]@{ Name = $Spec.Name; DismMatch = $Spec.DismMatch; Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke(); Sync = $sync; Log = $log; Start = (Get-Date) }
    if ($Script:Sync) { $Script:Sync.SideSync = @(@($Script:Sync.SideSync) | Where-Object { $_ }) + @($sync) }
    return $job
}
function Start-BootWimJob($Ctx) {
    $job = Start-SideJob @{ Name = 'boot.wim'; Command = 'Invoke-BootWimService'; Tag = 'boot'; Scratch = 'scratch-pe'; DismMatch = '(boot_stage|boot_final|mnt\\pe|scratch-pe)' } $Ctx
    if ($job) { Write-Info 'boot.wim is updated at the same time in the background - its log follows after install.wim.' }
    return $job
}
function Receive-SideLines($Job) {
    $it = $null
    while ($Job.Sync.Queue.TryDequeue([ref]$it)) {
        if ($Script:Sync) { $Script:Sync.Queue.Enqueue($it) } else { Microsoft.PowerShell.Utility\Write-Host $it[1] }
    }
}
function Close-SideJob($Job) {
    if ($Script:Sync) {
        $left = @(@($Script:Sync.SideSync) | Where-Object { $_ -and -not [object]::ReferenceEquals($_, $Job.Sync) })
        $Script:Sync.SideSync = if ($left.Count) { $left } else { $null }
    }
    if ($Job.Log -and (Test-Path -LiteralPath $Job.Log) -and $Script:LogFile) {
        try {
            Add-Content -LiteralPath $Script:LogFile -Value ("---- $($Job.Name) (background) log`r`n" + [IO.File]::ReadAllText($Job.Log) + "---- end of $($Job.Name) log") -Encoding UTF8
            Remove-Item -LiteralPath $Job.Log -Force
        } catch { }
    }
    try { $Job.Ps.Dispose() } catch { }
    try { $Job.Rs.Dispose() } catch { }
}
# Waits for a side job, shows its log, returns its result (or throws its error).
function Wait-SideJob($Job) {
    while (-not $Job.Handle.IsCompleted) {
        Receive-SideLines $Job
        $pct = [double]$Job.Sync.Pct
        $st = "waiting for $($Job.Sync.Label)"
        if ($pct -ge 0) { $st += (' {0:N0}%' -f $pct) }
        Write-Host $st -NoNewline
        Start-Sleep -Milliseconds 300
    }
    Receive-SideLines $Job
    if ($Script:Sync) { $Script:Sync.Status = '' }
    $err = $null; $out = $null
    try { $out = @($Job.Ps.EndInvoke($Job.Handle)) } catch { $err = $_.Exception }
    if (-not $err -and $Job.Ps.HadErrors -and $Job.Ps.Streams.Error.Count) { $err = $Job.Ps.Streams.Error[0].Exception }
    Receive-SideLines $Job
    Close-SideJob $Job
    if ($err) {
        $m = $err.Message
        if ($err.InnerException) { $m = $err.InnerException.Message }
        throw "$($Job.Name): $m"
    }
    Write-Info ('{0}: background job finished after {1:mm\:ss}' -f $Job.Name, ((Get-Date) - $Job.Start))
    return (@($out | Where-Object { $null -ne $_ }) | Select-Object -Last 1)
}
# Stops a side job after an error (its dism.exe is ended too, so the mounts can be discarded).
function Stop-SideJob($Job) {
    if (-not $Job) { return }
    try { [void]$Job.Ps.BeginStop($null, $null) } catch { }
    if ($Job.DismMatch) {
        try {
            $rx = [regex]::Escape((Split-Path $Job.Log -Parent | Split-Path -Parent)) + '.*' + $Job.DismMatch
            Get-CimInstance Win32_Process -Filter "Name='dism.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -match $rx } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    $t = Get-Date
    while (-not $Job.Handle.IsCompleted -and ((Get-Date) - $t).TotalSeconds -lt 60) { Start-Sleep -Milliseconds 300 }
    Receive-SideLines $Job
    Close-SideJob $Job
}

# ---- one edition in a runspace of its own (Options: editions at the same time): its own WIM file
# (install_stageN.wim), mount folder, scratch folder and logs. The first one hands its winre.wim to the main
# job (Shared.ReSrc); every one waits for the updated WinRE (Shared.Re) just before it is saved.
function Invoke-EditionJob($Ctx) {
    $res = [pscustomobject]@{ ExSaved = $false }
    Write-Title $Ctx.Title
    Set-SideLabel "$($Ctx.Part) mounting"
    $t = Get-Date
    Mount-Img $Ctx.Wim 1 $Ctx.Mount
    Add-Timing $Ctx.Times $Ctx.Part 'mount' $t
    if ($Ctx.TakeRe) {
        $reSrc = Join-Path $Ctx.Mount 'Windows\System32\Recovery\winre.wim'
        if (Test-Path -LiteralPath $reSrc) {
            Copy-Item -LiteralPath $reSrc -Destination $Ctx.ReWim -Force
            (Get-Item -LiteralPath $Ctx.ReWim -Force).Attributes = 'Normal'
            $Ctx.Shared.ReSrc = 'copied'
        } else {
            Write-Warn 'No winre.wim in this edition - WinRE skipped.'
            $Ctx.Shared.Re = 'none'; $Ctx.Shared.ReSrc = 'none'
        }
    }
    Add-EditionUpdates $Ctx.Mount $Ctx.Upd $Ctx.Fu $Ctx.LcuTip ([bool]$Ctx.HasDrv) $Ctx.Times $Ctx.Part ([string]$Ctx.ImgVersion) $Ctx.LcuBuild
    if ($Ctx.Shared.Re -eq 'pending') {
        $t = Get-Date
        Set-SideLabel "$($Ctx.Part) waiting for WinRE"
        while ($Ctx.Shared.Re -eq 'pending') { Start-Sleep -Milliseconds 300 }
        Add-Timing $Ctx.Times $Ctx.Part 'waiting for WinRE' $t
    }
    if ($Ctx.Shared.Re -eq 'ready') {
        Copy-Item -LiteralPath $Ctx.ReNew -Destination (Join-Path $Ctx.Mount 'Windows\System32\Recovery\winre.wim') -Force
        Write-Sub 'Updated WinRE copied into the image'
    }
    if ($Ctx.Boot2023) { $res.ExSaved = [bool](Save-BootFiles2023 $Ctx.Mount $Ctx.ExDir) }
    Set-SideLabel "$($Ctx.Part) saving"
    $t = Get-Date
    Dismount-Img $Ctx.Mount -Commit
    Add-Timing $Ctx.Times $Ctx.Part 'save' $t
    Set-SideLabel ''
    return $res
}
# Several editions at the same time. The main job stages each ticked edition into a WIM file of its own and
# starts an edition job for it (up to $Ctx.Jobs at once); it starts WinRE as soon as the first edition handed
# over its winre.wim, and writes the new install.wim in the original edition order as editions finish.
# Returns $null when no background worker could start (then the editions are updated one after the other).
function Invoke-EditionsParallel($Ctx) {
    $idx = @($Ctx.ExportIdx)
    $n = $idx.Count
    $shared = [hashtable]::Synchronized(@{ ReSrc = 'pending'; Re = 'pending' })
    $Ctx.ReCtx.Shared = $shared
    $toStart = New-Object 'System.Collections.Generic.Queue[int]'
    for ($k = 1; $k -le $n; $k++) { if (@($Ctx.Selected) -contains [int]$idx[$k - 1]) { $toStart.Enqueue($k) } }
    $first = $toStart.Peek()
    $running = New-Object System.Collections.Generic.List[object]
    $done = @{}
    $res = [pscustomobject]@{ ExDir = $null }
    $reJob = $null; $reState = 'wait'
    $next = 1
    try {
        while ($next -le $n) {
            # WinRE: updated once, as soon as the first edition handed over its winre.wim
            if ($reState -eq 'wait' -and $shared.ReSrc -ne 'pending') {
                $reState = 'done'
                if ($shared.ReSrc -eq 'copied') {
                    if ($Ctx.ParallelRe) { $reJob = Start-SideJob $Ctx.ReSpec $Ctx.ReCtx }
                    if ($reJob) { $reState = 'running'; Write-Info 'WinRE is updated at the same time in the background - its log follows when it is done.' }
                    else { [void](Invoke-WinReService $Ctx.ReCtx) }
                }
            }
            if ($reState -eq 'running' -and $reJob.Handle.IsCompleted) {
                $j = $reJob; $reJob = $null; $reState = 'done'
                try { [void](Wait-SideJob $j) } catch { Write-Warn "WinRE update skipped: $($_.Exception.Message)" }
                if ($shared.Re -eq 'pending') { $shared.Re = 'failed' }
            }
            # start the next edition when a slot is free
            if ($running.Count -lt $Ctx.Jobs -and $toStart.Count) {
                $k = $toStart.Dequeue()
                $orig = [int]$idx[$k - 1]
                $info = @($Ctx.Images | Where-Object { $_.Index -eq $orig })[0]
                $part = "Edition ${k}: $($info.Name)"
                $wim = Join-Path $Ctx.Temp "install_stage$k.wim"
                Write-Step "Staging edition $k of $n ($($info.Name)) from $(Split-Path $Ctx.Src -Leaf)"
                $t = Get-Date
                Export-Img $Ctx.Src $orig $wim -Max
                Add-Timing $Ctx.Times $part 'stage (export into its own WIM)' $t
                $ec = @{
                    Title = "Edition $k/${n}: $($info.Name) (in the background)"; Part = $part; Wim = $wim; Mount = (Join-Path $Ctx.MountBase "os$k")
                    Upd = $Ctx.Upd; Fu = $Ctx.Fu; LcuTip = $Ctx.LcuTip; HasDrv = $Ctx.HasDrv; Times = $Ctx.Times; Shared = $shared
                    ImgVersion = [string]$info.Version; LcuBuild = $Ctx.LcuBuild
                    TakeRe = ($k -eq $first); ReWim = $Ctx.ReCtx.ReWim; ReNew = $Ctx.ReCtx.ReNew; Boot2023 = ($Ctx.Boot2023 -and $k -eq $first); ExDir = $Ctx.ExDir
                }
                $job = Start-SideJob @{ Name = "Edition $k"; Command = 'Invoke-EditionJob'; Tag = "ed$k"; Scratch = "scratch-ed$k"; DismMatch = "(install_stage$k\.wim|mnt\\os$k\b|scratch-ed$k\b)" } $ec
                if (-not $job) {
                    if ($k -eq $first) { Remove-Item -LiteralPath $wim -Force -ErrorAction SilentlyContinue; $Ctx.ReCtx.Shared = $null; return $null }
                    throw "The background worker for edition $k could not start."
                }
                Write-Info "Edition $k ($($info.Name)) is updated in the background - its log follows when it is done."
                $running.Add([pscustomobject]@{ K = $k; Job = $job })
                continue
            }
            # the new install.wim, in the original edition order
            $orig = [int]$idx[$next - 1]
            $info = @($Ctx.Images | Where-Object { $_.Index -eq $orig })[0]
            if (@($Ctx.Selected) -notcontains $orig) {
                Write-Step "Exporting edition $next ($($info.Name), not updated) to the new install.wim"
                $t = Get-Date
                Export-Img $Ctx.Src $orig $Ctx.Final -Max
                Add-Timing $Ctx.Times 'Other editions (not updated)' "export $($info.Name)" $t
                $next++; continue
            }
            if ($done[$next]) {
                Write-Step "Exporting edition $next to the new install.wim"
                $wim = Join-Path $Ctx.Temp "install_stage$next.wim"
                $t = Get-Date
                Export-Img $wim 1 $Ctx.Final -Max
                Add-Timing $Ctx.Times "Edition ${next}: $($info.Name)" 'export into install.wim' $t
                Remove-Item -LiteralPath $wim -Force -ErrorAction SilentlyContinue
                $next++; continue
            }
            # wait until an edition (or WinRE) is done
            $fin = @($running | Where-Object { $_.Job.Handle.IsCompleted }) | Select-Object -First 1
            if (-not $fin) {
                Write-Host ('{0} edition(s) being updated, {1} still to start - waiting' -f $running.Count, $toStart.Count) -NoNewline
                Start-Sleep -Milliseconds 300
                continue
            }
            [void]$running.Remove($fin)
            $r = Wait-SideJob $fin.Job
            $done[$fin.K] = $true
            if ($r -and $r.ExSaved) { $res.ExDir = $Ctx.ExDir }
        }
        if ($reJob) { $j = $reJob; $reJob = $null; try { [void](Wait-SideJob $j) } catch { Write-Warn "WinRE update skipped: $($_.Exception.Message)" } }
        if ($Script:Sync) { $Script:Sync.Status = '' }
        return $res
    } catch {
        foreach ($x in $running) { Write-Warn "Stopping edition $($x.K) in the background..."; Stop-SideJob $x.Job }
        if ($reJob) { Write-Warn 'Stopping the WinRE background job...'; Stop-SideJob $reJob }
        throw
    }
}

function Invoke-Service([switch]$Auto) {
    Assert-Analyzed
    $S = $Script:S; $P = $Script:P; $Cfg = $Script:Cfg
    Write-Title 'Slipstream updates, drivers and options'
    if (@($S.Selected).Count -eq 0) { throw 'No edition selected - tick at least one on the Editions page.' }
    if ($S.Serviced -and -not $Auto) {
        Write-Warn "This media was already serviced on $($S.Serviced.When). For a clean result unpack the ISO again (step 1)."
        if (-not (Read-YesNo 'Service it again anyway?' $false)) { return }
    }
    $upd = Get-UpdateFiles
    $Script:Dism = Get-ServicingDism ([int]$S.Family.Build) -Install       # a newer DISM for Windows 11 on a Windows 10 PC
    if ($Script:Dism -match '(?i)Assessment and Deployment Kit') { Write-Info "DISM of the Windows ADK: $($Script:Dism)" }
    $updCount = 0; foreach ($k in $upd.Keys) { $updCount += @($upd[$k]).Count }
    if ($updCount -eq 0) {
        Write-Warn 'No updates downloaded - only drivers and options will be applied.'
        if (-not $Auto -and -not (Read-YesNo 'Continue?' $true)) { return }
    }
    Test-WorkDir 25
    Clear-Mounts
    Reset-Dir $P.Temp

    $t0 = Get-Date
    $times    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $src      = Get-SourceImage
    $stage    = Join-Path $P.Temp 'install_stage.wim'
    $final    = Join-Path $P.Temp 'install_final.wim'
    $reWim    = Join-Path $P.Temp 'winre.wim'
    $reNew    = Join-Path $P.Temp 'winre_new.wim'
    $bfDir    = Join-Path $P.Temp 'bootfiles'
    $exDir    = Join-Path $P.Temp 'boot2023'
    $hasDrv   = @($S.Drivers).Count -gt 0 -and (Test-Path -LiteralPath $P.DrvSel)
    $bootInfs = if ($Cfg.BootDrivers -and $hasDrv) { Get-BootDriverInfs } else { @() }
    $fu       = if ($Cfg.ForceUnsigned) { ' /ForceUnsigned' } else { '' }
    $lcuTip   = if ((Get-FamilyOs $S.Family) -eq '10') { 'If this is a Windows 10 update newer than 2025-10, Microsoft blocks offline ESU integration - set the month back on the Windows updates page.' }
                else { 'See logs\dism.log. A Windows 11 image needs a DISM of the same or a newer Windows (the Windows ADK Deployment Tools have one).' }
    New-Item -ItemType Directory -Force -Path $bfDir | Out-Null
    $lcuBuild = @{}
    foreach ($x in @($upd.LCU)) {
        $ub = Get-UpdateBuild $x
        if ($ub) { $lcuBuild[$x] = $ub; Write-Info ('{0} brings build {1}.{2} - an image already at that build skips it' -f (Split-Path $x -Leaf), $ub.Build, $ub.Rev) }
    }
    $bootSet  = New-BootDriverSet $bootInfs (Join-Path $P.Temp 'bootdrivers')
    $bootCtx  = @{
        Upd = $upd; Media = $P.Media; MountPE = $P.MountPE; BfDir = $bfDir; ExDir = (Join-Path $P.Temp 'boot2023_pe')
        BootSt = (Join-Path $P.Temp 'boot_stage.wim'); BootFin = (Join-Path $P.Temp 'boot_final.wim')
        BootSet = $bootSet; Fu = $fu; Boot2023 = [bool]$Cfg.Boot2023; SkipPE = [bool]$Cfg.BootSkipPE; Times = $times; LcuBuild = $lcuBuild
    }
    $reCtx    = @{ Upd = $upd; ReWim = $reWim; ReNew = $reNew; MountRE = $P.MountRE; BootSet = $bootSet; Fu = $fu; Times = $times; LcuBuild = $lcuBuild }
    $reSpec   = @{ Name = 'WinRE'; Command = 'Invoke-WinReService'; Tag = 're'; Scratch = 'scratch-re'; DismMatch = '(winre|mnt\\re|scratch-re)' }

    $all = @($S.Images | ForEach-Object { [int]$_.Index })
    $exportIdx = @(if ($Cfg.KeepOnlySelected) { $S.Selected } else { $all })
    $selCount = @($exportIdx | Where-Object { @($S.Selected) -contains $_ }).Count
    $edJobs = 1
    if ($selCount -gt 1) {
        $free = Get-FreeGB $P.Work
        $ej = Get-EditionJobs $selCount $free
        $edJobs = $ej.Jobs
        if ($edJobs -gt 1) { Write-Info ('{0} of the {1} editions are updated at the same time (Options: editions at the same time).' -f $edJobs, $selCount) }
        elseif ($ej.Wanted -gt 1) { Write-Warn ('The editions are updated one after the other: {0:N0} GB free on the work drive, and each edition updated at the same time needs about 25 GB.' -f $free) }
    }
    $reReady = $false; $reTried = $false; $exSaved = $false
    $bootJob = $null; $bootRes = $null; $reJob = $null

    try {
        # ---- boot.wim in the background (it does not depend on install.wim)
        if ($Cfg.ParallelBoot) {
            $bootJob = Start-BootWimJob $bootCtx
            if (-not $bootJob) { Write-Warn 'The background worker for boot.wim could not start - boot.wim is updated after install.wim.' }
        }

        # ---- several editions at the same time, each in a background job
        $parDone = $false
        if ($edJobs -gt 1) {
            $pr = @(Invoke-EditionsParallel @{
                Src = $src; ExportIdx = $exportIdx; Selected = @($S.Selected); Images = @($S.Images); Jobs = $edJobs; Final = $final; Temp = $P.Temp
                MountBase = (Split-Path $P.Mount -Parent); Upd = $upd; Fu = $fu; LcuTip = $lcuTip; HasDrv = $hasDrv; Times = $times; LcuBuild = $lcuBuild
                ReCtx = $reCtx; ReSpec = $reSpec; ParallelRe = [bool]$Cfg.ParallelBoot; Boot2023 = [bool]$Cfg.Boot2023; ExDir = $exDir
            }) | Select-Object -Last 1
            if ($pr) { $parDone = $true; if ($pr.ExDir) { $exSaved = $true } }
            else { Write-Warn 'The background workers for the editions could not start - they are updated one after the other.' }
        }

        if (-not $parDone) {
            # ---- stage editions (also converts install.esd -> wim)
            Write-Step "Staging $($exportIdx.Count) edition(s) from $(Split-Path $src -Leaf)"
            $t = Get-Date
            foreach ($i in $exportIdx) { Export-Img $src $i $stage -Max }
            Add-Timing $times 'Staging' "export $($exportIdx.Count) edition(s) from $(Split-Path $src -Leaf)" $t

            # ---- WinRE + every selected edition
            for ($k = 1; $k -le $exportIdx.Count; $k++) {
                $orig = [int]$exportIdx[$k - 1]
                $info = $S.Images | Where-Object { $_.Index -eq $orig }
                $part = "Edition ${k}: $($info.Name)"
                if ($S.Selected -contains $orig) {
                    Write-Title "Edition $k/$($exportIdx.Count): $($info.Name)"
                    $t = Get-Date
                    Mount-Img $stage $k $P.Mount
                    Add-Timing $times $part 'mount' $t

                    # WinRE comes from the first edition that has one and is updated once, in the background
                    # while this edition is serviced (same option as boot.wim); it goes into every edition before saving.
                    if (-not $reTried) {
                        $reSrc = Join-Path $P.Mount 'Windows\System32\Recovery\winre.wim'
                        if (Test-Path -LiteralPath $reSrc) {
                            $reTried = $true
                            Copy-Item -LiteralPath $reSrc -Destination $reWim -Force
                            (Get-Item -LiteralPath $reWim -Force).Attributes = 'Normal'
                            if ($Cfg.ParallelBoot) {
                                $reJob = Start-SideJob $reSpec $reCtx
                                if ($reJob) { Write-Info 'WinRE is updated at the same time in the background - its log follows before this edition is saved.' }
                            }
                            if (-not $reJob) { $reReady = (@(Invoke-WinReService $reCtx) | Select-Object -Last 1) -eq $true }
                        } else { Write-Warn 'No winre.wim in this edition - WinRE skipped.' }
                    }

                    Add-EditionUpdates $P.Mount $upd $fu $lcuTip $hasDrv $times $part ([string]$info.Version) $lcuBuild
                    if ($reJob) {
                        $j = $reJob; $reJob = $null
                        $t = Get-Date
                        try { $reReady = (Wait-SideJob $j) -eq $true } catch { Write-Warn "WinRE update skipped: $($_.Exception.Message)"; $reReady = $false }
                        Add-Timing $times $part 'waiting for WinRE' $t
                    }
                    if ($reReady) {
                        Copy-Item -LiteralPath $reNew -Destination (Join-Path $P.Mount 'Windows\System32\Recovery\winre.wim') -Force
                        Write-Sub 'Updated WinRE copied into the image'
                    }
                    if ($Cfg.Boot2023 -and -not $exSaved) { $exSaved = Save-BootFiles2023 $P.Mount $exDir }
                    $t = Get-Date
                    Dismount-Img $P.Mount -Commit
                    Add-Timing $times $part 'save' $t
                }
                Write-Step "Exporting edition $k to the new install.wim"
                $t = Get-Date
                Export-Img $stage $k $final -Max
                if ($S.Selected -contains $orig) { Add-Timing $times $part 'export into install.wim' $t }
                else { Add-Timing $times 'Other editions (not updated)' "export $($info.Name)" $t }
            }
        }

        # ---- boot.wim: join the background job, or run it now
        if ($bootJob) { $j = $bootJob; $bootJob = $null; $bootRes = Wait-SideJob $j }
        else { $bootRes = Invoke-BootWimService $bootCtx }
        if ($bootRes -and $bootRes.ExSaved) { $exDir = $bootCtx.ExDir; $exSaved = $true }   # WinPE's 2023 boot files are preferred, as before
    } catch {
        Write-Err $_.Exception.Message
        if ($reJob) { Write-Warn 'Stopping the WinRE background job...'; Stop-SideJob $reJob }
        if ($bootJob) { Write-Warn 'Stopping the boot.wim background job...'; Stop-SideJob $bootJob }
        Write-Warn 'Discarding mounted images - your unpacked media was not changed.'
        Clear-Mounts
        throw
    }
    $bootFin = $bootCtx.BootFin


    # ---- write results into the media folder
    Write-Title 'Updating the media folder'
    $t = Get-Date
    $srcDir = Join-Path $P.Media 'sources'
    foreach ($n in @('install.wim', 'install.esd')) { Remove-Item -LiteralPath (Join-Path $srcDir $n) -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $srcDir -Filter 'install*.swm' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Move-Item -LiteralPath $final -Destination (Join-Path $srcDir 'install.wim') -Force
    Move-Item -LiteralPath $bootFin -Destination (Join-Path $srcDir 'boot.wim') -Force
    Write-Ok 'install.wim and boot.wim replaced'

    foreach ($cab in $upd.SETUP) {
        Write-Sub "Setup Dynamic Update -> sources ($(Split-Path $cab -Leaf))"
        $r = Invoke-Native (Join-Path $env:SystemRoot 'System32\expand.exe') @($cab, '-F:*', $srcDir)
        Add-Log $r.Text
        $n = [regex]::Match($r.Text, '(\d+) files? total').Groups[1].Value
        if ($r.Code -ne 0) { Write-Warn "expand.exe exit $($r.Code)" } elseif ($n) { Write-Sub "$n setup files updated" }
    }
    $setupExe = Join-Path $bfDir 'setup.exe'
    if (Test-Path -LiteralPath $setupExe) { Copy-Item -LiteralPath $setupExe -Destination (Join-Path $srcDir 'setup.exe') -Force; Write-Sub 'setup.exe synced with boot.wim' }
    foreach ($f in @(Get-ChildItem -LiteralPath $P.Media -Recurse -Filter 'b*.efi' -File -Force)) {
        if (@('bootmgfw.efi', 'bootx64.efi', 'bootia32.efi', 'bootaa64.efi') -contains $f.Name.ToLower() -and (Test-Path -LiteralPath (Join-Path $bfDir 'bootmgfw.efi'))) {
            Copy-Item -LiteralPath (Join-Path $bfDir 'bootmgfw.efi') -Destination $f.FullName -Force
        } elseif ($f.Name -ieq 'bootmgr.efi' -and (Test-Path -LiteralPath (Join-Path $bfDir 'bootmgr.efi'))) {
            Copy-Item -LiteralPath (Join-Path $bfDir 'bootmgr.efi') -Destination $f.FullName -Force
        }
    }
    if (Test-Path -LiteralPath (Join-Path $bfDir 'boot.stl')) {
        Copy-Item -LiteralPath (Join-Path $bfDir 'boot.stl') -Destination (Join-Path $P.Media 'efi\microsoft\boot\boot.stl') -Force
    }
    Write-Sub 'Boot manager files refreshed'
    Add-Timing $times 'Media folder' 'new install.wim / boot.wim, setup files' $t

    $b2023 = $false
    if ($Cfg.Boot2023) {
        if ($exSaved) {
            try { Set-Boot2023 $exDir; $b2023 = $true; Write-Ok 'Media now boots with the Windows UEFI CA 2023 signed boot manager' }
            catch { Write-Warn "2023 boot files not applied: $($_.Exception.Message)" }
        } else { Write-Warn '2023-signed boot files not found in the updated image (needs the 2024-04 update or newer) - standard boot files kept.' }
    }
    Sync-Unattend

    $newList = Get-ImageList (Join-Path $srcDir 'install.wim')
    $wimSize = (Get-Item -LiteralPath (Join-Path $srcDir 'install.wim')).Length
    if ($Cfg.SplitFat32 -and $wimSize -gt 3900MB) {
        Write-Step 'Splitting install.wim into 3.8 GB .swm parts (FAT32)'
        $t = Get-Date
        Invoke-Dism "/Split-Image /ImageFile:$(Q (Join-Path $srcDir 'install.wim')) /SWMFile:$(Q (Join-Path $srcDir 'install.swm')) /FileSize:3800" 'Split image'
        Remove-Item -LiteralPath (Join-Path $srcDir 'install.wim') -Force
        Add-Timing $times 'Media folder' 'split install.wim (FAT32)' $t
    }

    $S.Serviced = [ordered]@{
        When     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Build    = $newList[0].Version
        Editions = @($newList | ForEach-Object { "$($_.Name) ($($_.Version))" })
        Boot2023 = $b2023
        Updates  = @($S.Updates | ForEach-Object { $_.KB })
    }
    $S.Iso = $null
    Save-State
    Remove-Item -LiteralPath $P.Temp -Recurse -Force -ErrorAction SilentlyContinue
    Clear-Mounts
    Get-ChildItem -LiteralPath (Split-Path $P.Mount -Parent) -Directory -Filter 'os*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^os\d+$' -and @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0 } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Title 'Slipstream finished'
    foreach ($n in $newList) { Write-Ok ('{0,-44} {1}' -f (Limit-Text $n.Name 44), $n.Version) }
    Write-Info ('install.wim: {0}   time: {1:hh\:mm\:ss}' -f (Format-Size $wimSize), ((Get-Date) - $t0))
    Write-TimingTable $times ((Get-Date) - $t0)
}
#endregion
