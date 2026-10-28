#region ---------------------------------------------------------------- Windows 10 / Windows 11
# Which Windows the image is and how its updates are named in the Microsoft Update Catalog.
#   Windows 10: 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 / LTSC 2021 (2004-21H2 get the 22H2 enablement package)
#   Windows 11: 21H2, 22H2 / 23H2 (22H2 gets the 23H2 enablement package), 24H2 / LTSC 2024, 25H2
function Resolve-Family($Images) {
    $first = $Images[0]
    $b = [int]$first.Build
    $arch = [string]$first.Arch
    if (@($Images | ForEach-Object { "$($_.Build)/$($_.Arch)" } | Select-Object -Unique).Count -gt 1) {
        Write-Warn 'This image mixes builds/architectures - updates are picked for the first edition.'
    }
    $archTitle = @{ x64 = 'x64-based Systems'; x86 = 'x86-based Systems'; arm64 = 'ARM64-based Systems' }[$arch]
    $archTok   = @{ x64 = 'x64'; x86 = 'x86'; arm64 = 'ARM64' }[$arch]
    $ltsc = @($Images | Where-Object { $_.Edition -match 'EnterpriseS|IoTEnterpriseS' }).Count -gt 0
    $f = [ordered]@{
        Os = '10'; Build = $b; Arch = $arch; ArchTitle = $archTitle; ArchToken = $archTok; Product = $null; VerToken = $null
        Cap = $null; NeedsEkb = $false; EkbKB = ''; EkbFor = ''; NoSsu = $false; Supported = $true; Name = $null; IsLtsc = $ltsc; Label = $null
    }
    if ($b -ge 22000) {
        # Windows 11 cumulative updates carry the servicing stack - there is no standalone SSU to look for
        $f.Os = '11'; $f.NoSsu = $true
        if ($b -eq 22000) { $f.VerToken = '21H2'; $f.Name = 'Windows 11 21H2'; $f.Cap = '2024-10' }     # end of servicing
        elseif ($b -eq 22621) { $f.VerToken = '23H2'; $f.Name = 'Windows 11 build 22621 -> 23H2'; $f.NeedsEkb = $true; $f.EkbKB = 'KB5027397'; $f.EkbFor = '23H2' }
        elseif ($b -eq 22631) { $f.VerToken = '23H2'; $f.Name = 'Windows 11 23H2' }
        elseif ($b -eq 26100) { $f.VerToken = '24H2'; $f.Name = $(if ($ltsc) { 'Windows 11 LTSC 2024 (24H2)' } else { 'Windows 11 24H2' }) }
        elseif ($b -eq 26200) { $f.VerToken = '25H2'; $f.Name = 'Windows 11 25H2' }
        else { $f.Supported = $false; $f.Name = "Windows 11 (build $b)" }
    } elseif ($b -ge 19041 -and $b -le 19045) {
        if ($b -eq 19044 -and $ltsc) { $f.VerToken = '21H2'; $f.Name = 'Windows 10 LTSC 2021 (21H2)' }
        else {
            $f.VerToken = '22H2'; $f.Name = 'Windows 10 22H2'
            if ($b -lt 19045) { $f.NeedsEkb = $true; $f.EkbKB = 'KB5015684'; $f.EkbFor = '22H2'; $f.Name = "Windows 10 build $b -> 22H2" }
        }
        $f.Cap = [string]$Script:Cfg.Win10Cutoff
    } elseif ($b -eq 17763) { $f.VerToken = '1809'; $f.Name = 'Windows 10 1809 / LTSC 2019' }
    elseif ($b -eq 14393) { $f.VerToken = '1607'; $f.Name = 'Windows 10 1607 / LTSB 2016' }
    else { $f.Supported = $false; $f.Name = "Windows 10 build $b (out of support)" }
    if ($f.VerToken) { $f.Product = "Windows $($f.Os) Version $($f.VerToken)" }
    if (-not $archTitle) { $f.Supported = $false }
    $tag = if ($f.VerToken) { $f.VerToken } else { "$b" }
    $f.Label = ('W' + $f.Os + '_' + $tag + '_' + $arch).ToUpper()
    return $f
}
function Get-FamilyOs($Fam) {
    if ($Fam -and $Fam.Os) { return [string]$Fam.Os }
    if ($Fam -and [int]$Fam.Build -ge 22000) { return '11' }
    return '10'
}
function Find-Update {
    # Walks back month by month ("YYYY-MM ..." titles) and returns the newest match.
    param([string]$Kind, $Fam, [string]$MaxMonth, [int]$Lookback = 12)
    $p = [regex]::Escape($Fam.Product); $a = [regex]::Escape($Fam.ArchTitle)
    $v = [regex]::Escape($Fam.VerToken); $t = [regex]::Escape($Fam.ArchToken)
    $o = [regex]::Escape('Windows ' + (Get-FamilyOs $Fam))
    foreach ($ym in (Get-MonthList $MaxMonth $Lookback)) {
        $y = [regex]::Escape($ym)
        switch ($Kind) {
            'LCU'   { $q = "$ym Cumulative Update for $($Fam.Product) for $($Fam.ArchTitle)"; $rx = "^$y Cumulative Update for $p for $a" }
            'SSU'   { $q = "$ym Servicing Stack Update for $($Fam.Product) for $($Fam.ArchTitle)"; $rx = "^$y Servicing Stack Update for $p for $a" }
            'NET'   { $q = "$ym Cumulative Update for .NET Framework $($Fam.Product) $($Fam.ArchToken)"; $rx = "^$y Cumulative Update for \.NET Framework .*$o.*\b$v\b.*\b$t\b" }
            default { $q = "$ym Dynamic Update for $($Fam.Product) for $($Fam.ArchTitle)"; $rx = "^$y (Safe OS |Setup )?Dynamic Update for $o.*\b$v\b.*$a" }
        }
        Write-Host "     . catalog: $ym" -ForegroundColor DarkGray
        $hits = @(Search-Catalog $q | Where-Object { $_.Title -match $rx -and $_.Title -notmatch 'Preview' })
        if ($Kind -eq 'SAFEOS' -or $Kind -eq 'SETUP') { $hits = @($hits | Where-Object { (Get-DuKind $_) -eq $Kind }) }
        if ($hits.Count -gt 0) {
            $sorted = @($hits | Sort-Object Date -Descending)
            if ($Kind -eq 'NET') { return $sorted }
            return $sorted[0]
        }
    }
}
function Find-ByKB([string]$KB, $Fam, [string]$MustMatch) {
    $t = [regex]::Escape($Fam.ArchToken)
    $o = 'Windows ' + (Get-FamilyOs $Fam)
    $hits = @(Search-Catalog $KB | Where-Object {
            $_.Title -match "\b$t\b" -and $_.Title -match [regex]::Escape($o) -and (-not $MustMatch -or $_.Title -match $MustMatch)
        })
    if ($hits.Count -gt 0) { return (@($hits | Sort-Object Date -Descending))[0] }
}
# The KB number in a catalog file name (windows11.0-kb5043080-x64_<sha1>.msu -> 5043080), 0 if none.
function Get-FileKB([string]$File) {
    $m = [regex]::Match((Split-Path $File -Leaf), '(?i)kb(\d{6,8})')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}
function Get-UpdateFiles {
    $h = @{ SSU = @(); LCU = @(); EKB = @(); SAFEOS = @(); SETUP = @(); NET = @(); NET481 = @() }
    $seenLeaf = @{}
    foreach ($u in @($Script:S.Updates)) {
        $files = @($u.Files)
        # Windows 11 24H2 and later: the catalog entry of a cumulative update also holds the checkpoint
        # update it builds on (an older KB) - that one has to go in first.
        if ($u.Kind -eq 'LCU') { $files = @($files | Sort-Object { Get-FileKB $_ }) }
        foreach ($f in $files) {
            if (-not (Test-Path -LiteralPath $f)) { Write-Warn "Missing $f - run Download again."; continue }
            $leaf = (Split-Path $f -Leaf).ToLower()
            if ($seenLeaf.ContainsKey($leaf)) { continue }
            $seenLeaf[$leaf] = $true
            $h[$u.Kind] += $f
        }
    }
    return $h
}
#endregion

#region ---------------------------------------------------------------- DISM for the image
# Windows supports servicing an image only with a DISM of the same or a newer Windows. Builds that share
# one code base count as one (Windows 10 2004-22H2, Windows 11 22H2 / 23H2, 24H2 / 25H2).
function Get-BaseBuild([int]$Build) {
    if ($Build -ge 26100 -and $Build -le 26200) { return 26100 }
    if ($Build -ge 22621 -and $Build -le 22631) { return 22621 }
    if ($Build -ge 19041 -and $Build -le 19045) { return 19041 }
    return $Build
}
function Get-DismBuild([string]$Exe) {
    try { return [int](Get-Item -LiteralPath $Exe -ErrorAction Stop).VersionInfo.FileBuildPart } catch { return 0 }
}
function Find-AdkDism {
    $arch = switch (Get-HostArch) { 'x64' { 'amd64' } 'arm64' { 'arm64' } default { 'x86' } }
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $pf) { continue }
        $d = Join-Path $pf "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$arch\DISM\dism.exe"
        if (Test-Path -LiteralPath $d) { return $d }
    }
    return $null
}
# The DISM to service an image of $ImageBuild: $Current (by default the one in use, normally this PC's), or -
# for a newer Windows, such as Windows 11 from a Windows 10 PC - the one of the Windows ADK Deployment Tools.
# -Install offers to install those.
function Get-ServicingDism([int]$ImageBuild, [switch]$Install, [string]$Current = $Script:Dism) {
    $sys = $Current
    if (-not $sys) { $sys = Join-Path $env:SystemRoot 'System32\dism.exe' }
    $need = Get-BaseBuild $ImageBuild
    $sysBuild = Get-DismBuild $sys
    if ($sysBuild -eq 0 -or (Get-BaseBuild $sysBuild) -ge $need) { return $sys }      # 0 = version unreadable: keep it
    $adk = Find-AdkDism
    if ($adk -and (Get-BaseBuild (Get-DismBuild $adk)) -ge $need) { return $adk }
    if (-not $Install) { return $sys }
    Write-Warn "This PC's DISM (build $sysBuild) is older than the image (build $ImageBuild). Windows supports servicing an image only with the same or a newer DISM - the Windows ADK Deployment Tools have one."
    if (Read-YesNo "Install the Windows ADK Deployment Tools from Microsoft now (a few minutes)? They are used for this image only; this PC's DISM is not changed." $true) {
        Install-AdkDeploymentTools
        $adk = Find-AdkDism
        if ($adk -and (Get-BaseBuild (Get-DismBuild $adk)) -ge $need) { return $adk }
        Write-Warn "The ADK's DISM is not new enough for this image either - this PC's DISM is used, which can fail."
    } else {
        Write-Warn "Continuing with this PC's DISM - it can fail on this image."
    }
    return $sys
}
#endregion

#region ---------------------------------------------------------------- [1] Analyze
function Invoke-Analyze {
    Assert-Unpacked
    $src = Get-SourceImage
    Write-Step "Reading $(Split-Path $src -Leaf)"
    $imgs = Get-ImageList $src
    if ($imgs.Count -eq 0) { throw 'The image file has no editions.' }
    $fam = Resolve-Family $imgs
    $Script:S.Images = @(foreach ($i in $imgs) { $i })
    $Script:S.Family = $fam
    if ($imgs.Count -eq 1) { $Script:S.Selected = @(1) }
    $Script:S.Selected = @($Script:S.Selected | Where-Object { $_ -le $imgs.Count })
    Save-State

    Write-Host ''
    $color = if ($fam.Supported) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0}  |  build {1}  |  {2}  |  {3} edition(s)  |  {4}" -f $fam.Name, $imgs[0].Version, $fam.Arch, $imgs.Count, (Split-Path $src -Leaf)) -ForegroundColor $color
    Write-Host ''
    Write-Host ('   {0,-3} {1,-42} {2,-14} {3,-11} {4}' -f '#', 'Edition', 'Build', 'Size', 'Language') -ForegroundColor DarkGray
    foreach ($i in $imgs) {
        $mark = if ($Script:S.Selected -contains $i.Index) { '*' } else { ' ' }
        Write-Host ('  {0}{1,-3} {2,-42} {3,-14} {4,-11} {5}' -f $mark, $i.Index, (Limit-Text $i.Name 42), $i.Version, (Format-Size $i.Size), $i.Langs)
    }
    Write-Host ''
    if ($Script:Cfg.WinVersion -and [string]$Script:Cfg.WinVersion -ne $fam.Os) {
        Write-Info "This ISO is Windows $($fam.Os) - the Windows version on page 1 is switched to it."
    }
    if (-not $fam.Supported) {
        Write-Warn "$($fam.Name) is not supported for automatic updates (supported: Windows 10 1607/LTSB 2016, 1809/LTSC 2019, 2004-22H2/LTSC 2021; Windows 11 21H2, 22H2/23H2, 24H2/LTSC 2024, 25H2)."
        Write-Info 'You can still inject drivers / autounattend.xml and rebuild the ISO.'
    } elseif ($fam.Os -eq '10' -and $fam.Cap) {
        Write-Info "Update target: newest updates up to $($Script:Cfg.Win10Cutoff). Microsoft blocks offline integration of the"
        Write-Info 'Windows 10 ESU-era updates (Nov 2025+); enrolled PCs get those from Windows Update after setup.'
    } elseif ($fam.Cap) {
        Write-Info "Update target: the last updates for $($fam.Name) ($($fam.Cap) - it is out of servicing)."
    } else {
        Write-Info 'Update target: newest updates available in the catalog.'
    }
    if ($fam.NeedsEkb) { Write-Info "The $($fam.EkbFor) enablement package ($($fam.EkbKB)) will be added to bring this build to $($fam.EkbFor)." }
    if ($fam.Os -eq '11') {
        $dism = Get-ServicingDism $fam.Build
        if ((Get-BaseBuild (Get-DismBuild $dism)) -lt (Get-BaseBuild $fam.Build)) {
            Write-Info "This PC's DISM is older than Windows 11 $($fam.VerToken) - the slipstream offers to install the Windows ADK Deployment Tools, whose DISM can service it."
        }
    }
}
#endregion
