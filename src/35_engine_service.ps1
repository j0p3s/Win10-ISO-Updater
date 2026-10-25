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
    $set = [pscustomobject]@{ Folder = $null; Singles = @(); Count = @($Infs).Count }
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

function Set-BootLabel([string]$Text) { if ($Script:Sync) { $Script:Sync.Label = $Text } }
# ---- boot.wim (WinPE + Setup). Runs in its own runspace while install.wim is serviced
# (Options: "Update boot.wim at the same time"), or inline. Returns what the media step needs.
function Invoke-BootWimService($Ctx) {
    $res = [pscustomobject]@{ ExSaved = $false; Count = 0 }
    Write-Title 'Updating boot.wim (WinPE / Setup)'
    Copy-Item -LiteralPath (Join-Path $Ctx.Media 'sources\boot.wim') -Destination $Ctx.BootSt -Force
    (Get-Item -LiteralPath $Ctx.BootSt -Force).Attributes = 'Normal'
    $bootCount = @(Get-WindowsImage -ImagePath $Ctx.BootSt).Count
    $res.Count = $bootCount
    $upd = $Ctx.Upd
    for ($b = 1; $b -le $bootCount; $b++) {
        Set-BootLabel "boot.wim $b/$bootCount"
        if ($Ctx.SkipPE -and $b -eq 1 -and $bootCount -ge 2) {
            Write-Step "boot.wim index 1 of $bootCount (Windows PE) - kept as it is (option)"
            Export-Img $Ctx.BootSt $b $Ctx.BootFin
            continue
        }
        Write-Step "boot.wim index $b of $bootCount"
        Mount-Img $Ctx.BootSt $b $Ctx.MountPE
        foreach ($x in @($upd.SSU)) { Set-BootLabel "boot.wim $b/$bootCount servicing stack"; Add-Pkg $Ctx.MountPE $x 'Servicing stack' -Soft }
        foreach ($x in @($upd.LCU)) {
            Set-BootLabel "boot.wim $b/$bootCount cumulative update"
            Add-Pkg $Ctx.MountPE $x 'Servicing stack via LCU' -IgnoreHex @('8007007E', '800F081E') -Soft
            Add-Pkg $Ctx.MountPE $x 'Cumulative update' -IgnoreHex @('800F081E') -Soft
        }
        Set-BootLabel "boot.wim $b/$bootCount drivers"
        Add-BootDrivers $Ctx.MountPE $Ctx.BootSet $Ctx.Fu 'WinPE'
        Set-BootLabel "boot.wim $b/$bootCount cleanup"
        Invoke-ImageCleanup $Ctx.MountPE 'WinPE'
        if (Test-Path -LiteralPath (Join-Path $Ctx.MountPE 'sources\setup.exe')) {
            Copy-Item -LiteralPath (Join-Path $Ctx.MountPE 'sources\setup.exe') -Destination (Join-Path $Ctx.BfDir 'setup.exe') -Force
            foreach ($n in 'bootmgfw.efi', 'bootmgr.efi', 'boot.stl') {
                $f = Join-Path $Ctx.MountPE "Windows\Boot\EFI\$n"
                if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $Ctx.BfDir $n) -Force }
            }
        }
        if ($Ctx.Boot2023 -and -not $res.ExSaved) { $res.ExSaved = [bool](Save-BootFiles2023 $Ctx.MountPE $Ctx.ExDir) }
        Set-BootLabel "boot.wim $b/$bootCount saving"
        Dismount-Img $Ctx.MountPE -Commit
        Export-Img $Ctx.BootSt $b $Ctx.BootFin
    }
    Set-BootLabel ''
    return $res
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
function Start-BootWimJob($Ctx) {
    $engine = Get-EngineText
    if (-not $engine) { return $null }
    $sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = ''; Label = 'boot.wim starting' })
    $p = @{}; foreach ($k in $Script:P.Keys) { $p[$k] = $Script:P[$k] }
    $p.Scratch = Join-Path $Script:P.Temp 'scratch-pe'
    $rs = [runspacefactory]::CreateRunspace([Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $sync)
    $rs.SessionStateProxy.SetVariable('IsWorker', $false)       # no Yes/No questions from here
    $init = [PowerShell]::Create(); $init.Runspace = $rs
    $why = $null
    try { [void]$init.AddScript($engine).Invoke(); if ($init.HadErrors) { $why = [string]$init.Streams.Error[0] } }
    catch { $why = $_.Exception.Message }
    $init.Dispose()
    if ($why) { Add-Log "boot.wim background worker: $why"; $rs.Dispose(); return $null }
    $log = Join-Path $Script:P.Logs 'engine-boot.log'
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    foreach ($kv in @{ P = $p; Cfg = $Script:Cfg; S = $Script:S; Dism = $Script:Dism; LogFile = $log; DismLog = (Join-Path $Script:P.Logs 'dism-boot.log') }.GetEnumerator()) {
        $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
    }
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddCommand('Invoke-BootWimService').AddParameter('Ctx', $Ctx)
    $job = [pscustomobject]@{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke(); Sync = $sync; Log = $log; Start = (Get-Date) }
    if ($Script:Sync) { $Script:Sync.SideSync = $sync }
    Write-Info 'boot.wim is updated at the same time in the background - its log follows after install.wim.'
    return $job
}
function Receive-BootWimLines($Job) {
    $it = $null
    while ($Job.Sync.Queue.TryDequeue([ref]$it)) {
        if ($Script:Sync) { $Script:Sync.Queue.Enqueue($it) } else { Microsoft.PowerShell.Utility\Write-Host $it[1] }
    }
}
function Close-BootWimJob($Job) {
    if ($Script:Sync) { $Script:Sync.SideSync = $null }
    if ($Job.Log -and (Test-Path -LiteralPath $Job.Log) -and $Script:LogFile) {
        try {
            Add-Content -LiteralPath $Script:LogFile -Value ("---- boot.wim (background) log`r`n" + [IO.File]::ReadAllText($Job.Log) + "---- end of boot.wim log") -Encoding UTF8
            Remove-Item -LiteralPath $Job.Log -Force
        } catch { }
    }
    try { $Job.Ps.Dispose() } catch { }
    try { $Job.Rs.Dispose() } catch { }
}
# Waits for the background boot.wim job, shows its log, returns its result (or throws its error).
function Wait-BootWimJob($Job) {
    while (-not $Job.Handle.IsCompleted) {
        Receive-BootWimLines $Job
        $pct = [double]$Job.Sync.Pct
        $st = "waiting for $($Job.Sync.Label)"
        if ($pct -ge 0) { $st += (' {0:N0}%' -f $pct) }
        Write-Host $st -NoNewline
        Start-Sleep -Milliseconds 300
    }
    Receive-BootWimLines $Job
    if ($Script:Sync) { $Script:Sync.Status = '' }
    $err = $null; $out = $null
    try { $out = @($Job.Ps.EndInvoke($Job.Handle)) } catch { $err = $_.Exception }
    if (-not $err -and $Job.Ps.HadErrors -and $Job.Ps.Streams.Error.Count) { $err = $Job.Ps.Streams.Error[0].Exception }
    Receive-BootWimLines $Job
    Close-BootWimJob $Job
    if ($err) {
        $m = $err.Message
        if ($err.InnerException) { $m = $err.InnerException.Message }
        throw "boot.wim: $m"
    }
    Write-Ok ('boot.wim done (ran alongside install.wim, {0:mm\:ss} in total)' -f ((Get-Date) - $Job.Start))
    return @($out | Where-Object { $_ -and $_.PSObject.Properties['ExSaved'] })[0]
}
# Stops the background job after an error (its dism.exe is ended too, so the mounts can be discarded).
function Stop-BootWimJob($Job) {
    if (-not $Job) { return }
    try { [void]$Job.Ps.BeginStop($null, $null) } catch { }
    try {
        $rx = [regex]::Escape((Split-Path $Job.Log -Parent | Split-Path -Parent)) + '.*(boot_stage|boot_final|mnt\\pe|scratch-pe)'
        Get-CimInstance Win32_Process -Filter "Name='dism.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -match $rx } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
    $t = Get-Date
    while (-not $Job.Handle.IsCompleted -and ((Get-Date) - $t).TotalSeconds -lt 60) { Start-Sleep -Milliseconds 300 }
    Receive-BootWimLines $Job
    Close-BootWimJob $Job
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
    $updCount = 0; foreach ($k in $upd.Keys) { $updCount += @($upd[$k]).Count }
    if ($updCount -eq 0) {
        Write-Warn 'No updates downloaded - only drivers and options will be applied.'
        if (-not $Auto -and -not (Read-YesNo 'Continue?' $true)) { return }
    }
    Test-WorkDir 25
    Clear-Mounts
    Reset-Dir $P.Temp

    $t0 = Get-Date
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
    $lcuTip   = 'If this is a Windows 10 update newer than 2025-10, Microsoft blocks offline ESU integration - set the month back in Options.'
    New-Item -ItemType Directory -Force -Path $bfDir | Out-Null
    $bootSet  = New-BootDriverSet $bootInfs (Join-Path $P.Temp 'bootdrivers')
    $bootCtx  = @{
        Upd = $upd; Media = $P.Media; MountPE = $P.MountPE; BfDir = $bfDir; ExDir = (Join-Path $P.Temp 'boot2023_pe')
        BootSt = (Join-Path $P.Temp 'boot_stage.wim'); BootFin = (Join-Path $P.Temp 'boot_final.wim')
        BootSet = $bootSet; Fu = $fu; Boot2023 = [bool]$Cfg.Boot2023; SkipPE = [bool]$Cfg.BootSkipPE
    }

    $all = @($S.Images | ForEach-Object { [int]$_.Index })
    $exportIdx = @(if ($Cfg.KeepOnlySelected) { $S.Selected } else { $all })
    $reReady = $false; $exSaved = $false
    $bootJob = $null; $bootRes = $null

    try {
        # ---- boot.wim in the background (it does not depend on install.wim)
        if ($Cfg.ParallelBoot) {
            $bootJob = Start-BootWimJob $bootCtx
            if (-not $bootJob) { Write-Warn 'The background worker for boot.wim could not start - boot.wim is updated after install.wim.' }
        }

        # ---- stage editions (also converts install.esd -> wim)
        Write-Step "Staging $($exportIdx.Count) edition(s) from $(Split-Path $src -Leaf)"
        foreach ($i in $exportIdx) { Export-Img $src $i $stage -Max }

        # ---- WinRE + every selected edition
        for ($k = 1; $k -le $exportIdx.Count; $k++) {
            $orig = [int]$exportIdx[$k - 1]
            $info = $S.Images | Where-Object { $_.Index -eq $orig }
            if ($S.Selected -contains $orig) {
                Write-Title "Edition $k/$($exportIdx.Count): $($info.Name)"
                Mount-Img $stage $k $P.Mount

                if (-not $reReady) {
                    $reSrc = Join-Path $P.Mount 'Windows\System32\Recovery\winre.wim'
                    if (Test-Path -LiteralPath $reSrc) {
                        Write-Step 'Updating WinRE (recovery environment)'
                        try {
                            Copy-Item -LiteralPath $reSrc -Destination $reWim -Force
                            (Get-Item -LiteralPath $reWim -Force).Attributes = 'Normal'
                            Mount-Img $reWim 1 $P.MountRE
                            foreach ($x in $upd.SSU) { Add-Pkg $P.MountRE $x 'Servicing stack' -Soft }
                            foreach ($x in $upd.LCU) { Add-Pkg $P.MountRE $x 'Servicing stack via LCU' -IgnoreHex @('8007007E', '800F081E') -Soft }
                            foreach ($x in $upd.SAFEOS) { Add-Pkg $P.MountRE $x 'Safe OS Dynamic Update' -Soft }
                            Add-BootDrivers $P.MountRE $bootSet $fu 'WinRE'
                            Invoke-ImageCleanup $P.MountRE 'WinRE'
                            Dismount-Img $P.MountRE -Commit
                            Export-Img $reWim 1 $reNew
                            $reReady = $true
                        } catch {
                            Write-Warn "WinRE update skipped: $($_.Exception.Message)"
                            try { Dismount-Img $P.MountRE } catch { }
                            $reReady = $false
                        }
                    } else { Write-Warn 'No winre.wim in this edition - WinRE skipped.' }
                }
                if ($reReady) { Copy-Item -LiteralPath $reNew -Destination (Join-Path $P.Mount 'Windows\System32\Recovery\winre.wim') -Force }

                Write-Step 'Updating Windows'
                if ($hasDrv) {
                    Write-Sub "Drivers ($(@($S.Drivers).Count) packages)"
                    Invoke-Dism "/Image:$(Q $P.Mount) /Add-Driver /Driver:$(Q $P.DrvSel) /Recurse$fu" 'Add drivers' -Soft
                }
                foreach ($x in $upd.SSU) { Add-Pkg $P.Mount $x 'Servicing stack' -Soft }
                foreach ($x in $upd.LCU) {
                    try { Add-Pkg $P.Mount $x 'Cumulative update' -IgnoreHex @('800F081E') }
                    catch { Write-Err $lcuTip; throw }
                }
                foreach ($x in $upd.EKB) { Add-Pkg $P.Mount $x '22H2 enablement package' -IgnoreHex @('800F081E') -Soft }
                if ($Cfg.ResetBase) { Invoke-ImageCleanup $P.Mount 'Windows' }
                if ($Cfg.NetFx3) {
                    $sxs = Join-Path $P.Media 'sources\sxs'
                    if (Test-Path -LiteralPath $sxs) {
                        Write-Sub '.NET Framework 3.5 (from sources\sxs)'
                        Invoke-Dism "/Image:$(Q $P.Mount) /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$(Q $sxs)" 'Enable .NET 3.5' -Soft
                    } else { Write-Warn 'sources\sxs not found - .NET 3.5 skipped.' }
                }
                foreach ($x in $upd.NET481) { Add-Pkg $P.Mount $x '.NET Framework 4.8.1' -IgnoreHex @('800F081E') -Soft }
                foreach ($x in $upd.NET) { Add-Pkg $P.Mount $x '.NET cumulative update' -IgnoreHex @('800F081E') -Soft }
                if ($Cfg.Boot2023 -and -not $exSaved) { $exSaved = Save-BootFiles2023 $P.Mount $exDir }
                Dismount-Img $P.Mount -Commit
            }
            Write-Step "Exporting edition $k to the new install.wim"
            Export-Img $stage $k $final -Max
        }

        # ---- boot.wim: join the background job, or run it now
        if ($bootJob) { $j = $bootJob; $bootJob = $null; $bootRes = Wait-BootWimJob $j }
        else { $bootRes = Invoke-BootWimService $bootCtx }
        if ($bootRes -and $bootRes.ExSaved) { $exDir = $bootCtx.ExDir; $exSaved = $true }   # WinPE's 2023 boot files are preferred, as before
    } catch {
        Write-Err $_.Exception.Message
        if ($bootJob) { Write-Warn 'Stopping the boot.wim background job...'; Stop-BootWimJob $bootJob }
        Write-Warn 'Discarding mounted images - your unpacked media was not changed.'
        Clear-Mounts
        throw
    }
    $bootFin = $bootCtx.BootFin


    # ---- write results into the media folder
    Write-Title 'Updating the media folder'
    $srcDir = Join-Path $P.Media 'sources'
    foreach ($n in @('install.wim', 'install.esd')) { Remove-Item -LiteralPath (Join-Path $srcDir $n) -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $srcDir -Filter 'install*.swm' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Move-Item -LiteralPath $final -Destination (Join-Path $srcDir 'install.wim') -Force
    Move-Item -LiteralPath $bootFin -Destination (Join-Path $srcDir 'boot.wim') -Force
    Write-Ok 'install.wim and boot.wim replaced'

    foreach ($cab in $upd.SETUP) {
        Write-Sub "Setup Dynamic Update -> sources ($(Split-Path $cab -Leaf))"
        $code = Invoke-Exe (Join-Path $env:SystemRoot 'System32\expand.exe') ("$(Q $cab) -F:* $(Q $srcDir)")
        if ($code -ne 0) { Write-Warn "expand.exe exit $code" }
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
        Invoke-Dism "/Split-Image /ImageFile:$(Q (Join-Path $srcDir 'install.wim')) /SWMFile:$(Q (Join-Path $srcDir 'install.swm')) /FileSize:3800" 'Split image'
        Remove-Item -LiteralPath (Join-Path $srcDir 'install.wim') -Force
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

    Write-Title 'Slipstream finished'
    foreach ($n in $newList) { Write-Ok ('{0,-44} {1}' -f (Limit-Text $n.Name 44), $n.Version) }
    Write-Info ('install.wim: {0}   time: {1:hh\:mm\:ss}' -f (Format-Size $wimSize), ((Get-Date) - $t0))
}
#endregion
