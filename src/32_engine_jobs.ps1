
#region ---------------------------------------------------------------- drivers: scan (worker) / commit (worker) / remove (GUI)
function Get-HostDriverScan {
    $hostArch = Get-HostArch
    if ($Script:S.Family -and $Script:S.Family.Arch -ne $hostArch) {
        throw "This PC is $hostArch but the ISO is $($Script:S.Family.Arch) - its drivers would not work in that image."
    }
    $exp = Join-Path $Script:P.Drivers 'host_export'
    Reset-Dir $exp
    Write-Step 'Exporting third-party drivers from this PC (1-3 minutes)'
    $drv = @(Export-WindowsDriver -Online -Destination $exp)
    if ($drv.Count -eq 0) { Write-Warn 'No third-party drivers found on this PC.'; return @() }
    $used = @{}
    $items = foreach ($d in $drv) {
        $inf = Split-Path $d.OriginalFileName -Leaf
        $folder = Split-Path (Split-Path $d.OriginalFileName -Parent) -Leaf
        $path = Join-Path $exp $folder
        if (-not (Test-Path -LiteralPath $path)) {
            $cand = Get-ChildItem -LiteralPath $exp -Directory | Where-Object { -not $used.ContainsKey($_.Name) -and (Test-Path -LiteralPath (Join-Path $_.FullName $inf)) } | Select-Object -First 1
            if (-not $cand) { continue }
            $folder = $cand.Name; $path = $cand.FullName
        }
        $used[$folder] = $true
        $size = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $date = ''
        try { $date = ([datetime]$d.Date).ToString('yyyy-MM-dd') } catch { }
        [pscustomobject]@{
            Class = [string]$d.ClassName; Provider = [string]$d.ProviderName; Version = [string]$d.Version; Date = $date; Arch = $hostArch
            'Size (MB)' = [math]::Round($size / 1MB, 1); Inf = $inf; Folder = $folder; FullDir = $path
        }
    }
    $items = @($items | Sort-Object Class, Provider)
    Write-Ok "$($items.Count) driver packages found on this PC."
    return $items
}
function Save-HostDrivers($Pick) {
    $pick = @($Pick)
    $exp = Join-Path $Script:P.Drivers 'host_export'
    if ($pick.Count -eq 0) { Remove-Item -LiteralPath $exp -Recurse -Force -ErrorAction SilentlyContinue; return }
    $hostDir = Join-Path $Script:P.DrvSel 'host'
    Reset-Dir $hostDir
    $keep = @($Script:S.Drivers | Where-Object { $_.Source -ne 'host' })
    foreach ($x in $pick) {
        Copy-Item -LiteralPath (Join-Path $exp $x.Folder) -Destination (Join-Path $hostDir $x.Folder) -Recurse -Force
        $keep += [ordered]@{ Source = 'host'; Folder = "host\$($x.Folder)"; Inf = $x.Inf; Class = $x.Class; Provider = $x.Provider; Version = $x.Version; SizeMB = $x.'Size (MB)' }
    }
    Remove-Item -LiteralPath $exp -Recurse -Force -ErrorAction SilentlyContinue
    $Script:S.Drivers = $keep
    Save-State
    Write-Ok "$($pick.Count) driver package(s) from this PC will be slipstreamed."
}
function Save-ImportDrivers([string]$Dir, $Pick) {
    $pick = @($Pick)
    $target = ''
    if ($Script:S.Family) { $target = [string]$Script:S.Family.Arch }
    $wrong = @($pick | Where-Object { -not (Test-DriverArch $_.Arch $target) })
    if ($wrong.Count -gt 0) {
        Write-Warn "$($wrong.Count) picked driver(s) are not built for $target and were left out."
        $pick = @($pick | Where-Object { Test-DriverArch $_.Arch $target })
    }
    if ($pick.Count -eq 0) { Write-Warn 'No drivers imported.'; return }
    $name = (Split-Path $Dir -Leaf) -replace '[^\w\.-]', '_'
    if (-not $name) { $name = 'drivers' }
    $base = Join-Path (Join-Path $Script:P.DrvSel 'import') $name
    Reset-Dir $base
    Write-Step "Copying $($pick.Count) driver(s) into the work folder"
    $rootTrim = $Dir.TrimEnd('\', '/')
    $dirs = @($pick | ForEach-Object { $_.FullDir } | Sort-Object -Unique | Sort-Object Length)
    $done = New-Object System.Collections.Generic.List[string]
    foreach ($d in $dirs) {
        $inside = $false
        foreach ($c in $done) { if ($d -eq $c -or $d.StartsWith($c.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break } }
        if ($inside) { continue }
        $rel = ''
        if ($d.Length -gt $rootTrim.Length) { $rel = $d.Substring($rootTrim.Length).TrimStart('\', '/') }
        $dest = if ($rel) { Join-Path $base $rel } else { $base }
        Copy-Tree $d $dest
        $done.Add($d)
    }
    $prefix = "import\$name"
    $keep = @($Script:S.Drivers | Where-Object { -not ([string]$_.Folder).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $seen = @{}
    foreach ($x in $pick) {
        $size = 0
        if (-not $seen.ContainsKey($x.FullDir)) { $size = $x.'Size (MB)'; $seen[$x.FullDir] = $true }
        $folder = if ($x.Folder) { "$prefix\$($x.Folder)" } else { $prefix }
        $keep += [ordered]@{ Source = 'import'; Folder = $folder; Inf = $x.Inf; Class = $x.Class; Provider = $x.Provider; Version = $x.Version; SizeMB = $size }
    }
    $Script:S.Drivers = $keep
    Save-State
    $Script:Cfg.LastDriverFolder = $Dir
    Save-Settings
    $boot = @($pick | Where-Object { $Script:BootClasses -contains $_.Class }).Count
    Write-Ok "$($pick.Count) driver(s) imported from $Dir ($boot storage/network also go into boot.wim and WinRE)."
}
function Remove-DriverEntries([int[]]$Numbers) {
    $d = @($Script:S.Drivers)
    $keep = @()
    for ($i = 0; $i -lt $d.Count; $i++) {
        if ($Numbers -contains ($i + 1)) {
            $folder = Join-Path $Script:P.DrvSel $d[$i].Folder
            if ($d[$i].Source -eq 'host') { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
            else { Remove-Item -LiteralPath (Join-Path $folder $d[$i].Inf) -Force -ErrorAction SilentlyContinue }
        } else { $keep += $d[$i] }
    }
    $Script:S.Drivers = $keep
    Save-State
    Write-Ok "$($d.Count - $keep.Count) driver(s) removed."
}
#endregion

#region ---------------------------------------------------------------- answer file
function Set-UnattendFile([string]$File) {
    [void](Test-UnattendFile $File)
    New-Item -ItemType Directory -Force -Path $Script:P.Work | Out-Null
    Copy-Item -LiteralPath $File -Destination $Script:P.Unattend -Force
    Remove-Item -LiteralPath (Join-Path $Script:P.Work 'autounattend.original.xml') -Force -ErrorAction SilentlyContinue
    $Script:S.Unattend = [ordered]@{ Source = $File; Added = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    Save-State
    Sync-Unattend
    Write-Ok "autounattend.xml added (from $File)"
}
function Clear-UnattendFile {
    if ($Script:S.Unattend) { Remove-Item -LiteralPath (Join-Path $Script:P.Media 'autounattend.xml') -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $Script:P.Unattend -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Script:P.Work 'autounattend.original.xml') -Force -ErrorAction SilentlyContinue
    $Script:S.Unattend = $null
    Save-State
    Write-Ok 'autounattend.xml removed.'
}
#endregion

#region ---------------------------------------------------------------- run everything / clean / job entry point
function Invoke-RunAll($A) {
    Write-Title "Run everything - $Script:AppName $Script:AppVersion"
    $iso = if ($A.Iso) { [string]$A.Iso } else { [string]$Script:S.SourceIso }
    $fresh = (-not $Script:S.Unpacked) -or $Script:S.Serviced -or ($iso -and $iso -ne $Script:S.SourceIso)
    if ($fresh) {
        if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { throw 'Choose the source ISO first (page 1).' }
        if ($Script:S.Serviced) { Write-Info 'The unpacked media was already serviced - unpacking a fresh copy.' }
        $Script:IsoPath = $iso
        $Script:NoAsk = $true
        Invoke-Unpack
        $Script:NoAsk = $false
    } else { Invoke-Analyze }
    $n = @($Script:S.Images).Count
    if (@($Script:S.Selected).Count -eq 0) {
        if ($n -gt 1 -and -not (Read-YesNo "No edition is ticked. Update and keep all $n editions? They are updated one after the other, so this takes about $n times as long as one edition - No stops here, so you can tick only the ones you need on page 2." $true)) { throw 'Tick the editions on page 2, then run again.' }
        $Script:S.Selected = @($Script:S.Images | ForEach-Object { [int]$_.Index })
        Save-State
    }
    if ($Script:S.Family.Supported) { Invoke-Download -Auto } else { Write-Warn 'Updates skipped (unsupported build).' }
    Invoke-Service -Auto
    Invoke-Build -Auto -OutIso $A.Out
    Write-Title 'Everything done'
    Write-Ok $Script:S.Iso
}
# Turns what is typed in "Output ISO" into a full file path: a folder gets the default file name,
# a bare name goes into the output folder, ".iso" is added. Bad input gets a clear message
# instead of .NET's "The path is not of a legal form".
function Resolve-OutIso([string]$Want, [string]$Default) {
    $w = ([string]$Want).Trim().Trim('"').Trim()
    if (-not $w) { return $Default }
    $hint = ' - clear the "Output ISO" box on the Build page to use the default name, or pick a file with "Save as...".'
    if ($w.IndexOfAny([char[]]'*?<>|"') -ge 0 -or $w.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { throw "The output ISO path has characters Windows does not allow: $w$hint" }
    $outDir = Split-Path $Default -Parent
    $isDir = $w -match '[\\/]$' -or (Test-Path -LiteralPath $w -PathType Container)
    if ($isDir) { $w = Join-Path $w (Split-Path $Default -Leaf) }
    elseif ($w -match '^[A-Za-z]:[^\\/]' -or -not [IO.Path]::IsPathRooted($w)) {
        # "Win10.iso" or "E:Win10.iso" - no folder given
        $w = Join-Path $outDir ($w -replace '^[A-Za-z]:', '')
    }
    if ($w -notmatch '(?i)\.iso$') { $w += '.iso' }
    try { $full = [IO.Path]::GetFullPath($w) } catch { throw "The output ISO path is not valid: $w$hint" }
    if ($full.Substring(2) -match ':') { throw "The output ISO path is not valid (':' inside the name): $w$hint" }
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -and -not (Test-Path -LiteralPath $root)) { throw "Drive $root does not exist (output ISO: $full)$hint" }
    return $full
}
function Invoke-CleanJob($A) {
    Write-Title 'Clean up'
    Clear-Mounts
    Remove-Item -LiteralPath $Script:P.Temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Script:P.Work 'mnt') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok 'Leftover mounts and temporary files removed.'
    if ($A.Updates -and (Test-Path -LiteralPath $Script:P.Updates)) {
        Remove-Item -LiteralPath $Script:P.Updates -Recurse -Force; $Script:S.Updates = @(); Write-Ok 'Downloaded updates deleted.'
    }
    if ($A.Media -and (Test-Path -LiteralPath $Script:P.Media)) {
        Remove-Item -LiteralPath $Script:P.Media -Recurse -Force
        $Script:S.Unpacked = $false; $Script:S.Serviced = $null; $Script:S.Images = @(); $Script:S.Family = $null; $Script:S.Selected = @(); $Script:S.OemSynced = $false
        Write-Ok 'Unpacked media deleted.'
    }
    if ($A.Output -and (Test-Path -LiteralPath $Script:P.Output)) {
        Remove-Item -LiteralPath $Script:P.Output -Recurse -Force; $Script:S.Iso = $null; Write-Ok 'Built ISOs deleted.'
    }
    if ($A.Signed -and (Test-Path -LiteralPath $Script:P.Signed)) {
        Remove-Item -LiteralPath $Script:P.Signed -Recurse -Force; $Script:S.Signed = @(); Write-Ok 'Re-signed driver copies deleted.'
    }
    if ($A.Drivers -and (Test-Path -LiteralPath $Script:P.Drivers)) {
        Remove-Item -LiteralPath $Script:P.Drivers -Recurse -Force; $Script:S.Drivers = @(); Write-Ok 'Copied drivers deleted (this PC / imported folder).'
    }
    if ($A.Extra) {
        $n = 0
        foreach ($f in @($Script:P.Unattend, (Join-Path $Script:P.Work 'autounattend.original.xml'), (Join-Path $Script:P.Work 'install-check.json'))) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; $n++ }
        }
        if ($Script:S.Unattend) { $Script:S.Unattend = $null; Write-Info 'The answer file is no longer added - choose it again on page 6 (your own file is not touched).' }
        $Script:S.Check = $null
        if ($n) { Write-Ok 'Answer file copy and install check results deleted.' }
    }
    if ($A.All) {
        # start from scratch: everything this tool keeps in the work folder goes, the state starts empty.
        # Only its own names are deleted - anything else in that folder is left alone.
        $own = @('media', 'updates', 'drivers', 'signed', 'output', 'temp', 'mnt', 'logs', 'state.json', 'autounattend.xml',
                 'autounattend.original.xml', 'install-check.json', 'defender-exclusion.txt')
        $Script:LogFile = $null
        foreach ($n in $own) {
            $f = Join-Path $Script:P.Work $n
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $Script:S = New-State
        $left = @($own | Where-Object { Test-Path -LiteralPath (Join-Path $Script:P.Work $_) })
        $other = @(Get-ChildItem -LiteralPath $Script:P.Work -Force -ErrorAction SilentlyContinue | Where-Object { $own -notcontains $_.Name.ToLower() })
        if ($left.Count) { Write-Warn "Could not delete: $($left -join ', ') (in use?)" }
        else { Write-Ok "Work folder $($Script:P.Work) is clean - settings and your signing certificate (next to the .cmd) are kept." }
        if ($other.Count) { Write-Info "Not made by this tool, left alone: $((@($other | ForEach-Object Name) | Select-Object -First 5) -join ', ')" }
        return
    }
    Save-State
    if ($A.Logs -and (Test-Path -LiteralPath $Script:P.Logs)) {
        Get-ChildItem -LiteralPath $Script:P.Logs -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $Script:LogFile = $null
        Write-Ok 'Logs deleted.'
    }
}
# Option "Let Windows Defender skip the work folder while a job runs": real-time scanning of
# every file DISM, robocopy and oscdimg touch slows servicing a lot. The exclusion is added for
# the job only and removed afterwards; a marker file makes sure a crash cannot leave it behind.
function Enable-DefenderSkip {
    if (-not $Script:Cfg.DefenderExclude) { return }
    $w = [IO.Path]::GetFullPath($Script:P.Work).TrimEnd('\')
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        if (@($pref.ExclusionPath) -contains $w) { Add-Log "Defender already excludes $w (left as it is)"; return }
        New-Item -ItemType Directory -Force -Path $w | Out-Null
        Add-MpPreference -ExclusionPath $w -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path $w 'defender-exclusion.txt') -Value $w -Encoding ASCII
        $Script:DefenderAdded = $w
        Write-Info "Windows Defender skips $w during this job (removed again at the end)."
    } catch { Write-Warn "Could not add the Defender exclusion ($($_.Exception.Message)) - normal scanning stays on." }
}
function Disable-DefenderSkip {
    $w = $Script:DefenderAdded
    $marker = $null
    if ($Script:P -and $Script:P.Work) { $marker = Join-Path $Script:P.Work 'defender-exclusion.txt' }
    if (-not $w -and $marker -and (Test-Path -LiteralPath $marker)) { $w = [string](Get-Content -LiteralPath $marker -TotalCount 1) }
    if (-not $w) { return }
    try { Remove-MpPreference -ExclusionPath $w -ErrorAction Stop; Add-Log "Defender exclusion removed: $w" }
    catch { Add-Log "Defender exclusion not removed: $($_.Exception.Message)" }
    if ($marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
    $Script:DefenderAdded = $null
}
# Entry point of the background worker. State is re-read from disk for every job.
function Invoke-Job([string]$Job, $A) {
    if ($null -eq $A) { $A = @{} }
    $Script:Cfg = Import-Settings
    Initialize-Paths
    $Script:S = Import-State
    $Script:Dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    if ($Script:S.Family -and $Script:S.Family.Build) { $Script:Dism = Get-ServicingDism ([int]$Script:S.Family.Build) }   # the ADK's DISM for Windows 11 on a Windows 10 PC
    $Script:NoAsk = [bool]$A.NoAsk
    $Script:Sync.Result = $null
    New-Item -ItemType Directory -Force -Path $Script:P.Logs | Out-Null
    $Script:LogFile = Join-Path $Script:P.Logs 'engine.log'
    $Script:DismLog = Join-Path $Script:P.Logs 'dism.log'
    Add-Log "---- $Script:AppName $Script:AppVersion  job=$Job"
    try {
        Disable-DefenderSkip       # leftover from a run that was killed
        if ($Job -in 'Unpack', 'Download', 'Sign', 'Service', 'Build', 'All') { Enable-DefenderSkip }
        switch ($Job) {
            'Unpack'       { $Script:IsoPath = [string]$A.Iso; Invoke-Unpack }
            'Analyze'      { Invoke-Analyze }
            'Download'     { Invoke-Download -Auto }
            'ScanHost'     { $Script:Sync.Result = @(Get-HostDriverScan) }
            'CommitHost'   { Save-HostDrivers $A.Pick }
            'ScanFolder'   {
                Write-Step "Scanning $($A.Dir)"
                $Script:Sync.Result = @(Get-DriverPackages $A.Dir | Sort-Object Class, Provider, Inf)
                Write-Ok "$(@($Script:Sync.Result).Count) driver(s) found."
            }
            'CommitImport' { Save-ImportDrivers $A.Dir $A.Pick }
            'Sign'         { Invoke-SignPackage $A.Source $A.Name $A.Password ([bool]$A.All) ([bool]$Script:Cfg.SignOnlyThisPc) ([bool]$Script:Cfg.SignIsolate) (Get-SignJobs) }
            'Service'      { Invoke-Service -Auto }
            'Build'        { Invoke-Build -Auto -OutIso ([string]$A.Out) }
            'All'          { Invoke-RunAll $A }
            'Tools'        { Get-AllTools }
            'Check'        { $Script:Sync.Result = @(Invoke-InstallCheck) }
            'Fix'          { Invoke-InstallFixes @($A.Fixes); $Script:Sync.Result = @(Invoke-InstallCheck) }
            'Clean'        { Invoke-CleanJob $A }
            default        { throw "Unknown job: $Job" }
        }
    } catch {
        Write-Err $_.Exception.Message
        Add-Log ($_ | Out-String)
        throw
    } finally {
        try { Disable-DefenderSkip } catch { }
        if ($Script:Sync) { $Script:Sync.Pct = -1; $Script:Sync.Status = ''; $Script:Sync.SideSync = $null }
    }
}
#endregion
#ENGINE-END

