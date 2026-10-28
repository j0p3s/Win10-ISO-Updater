#region ---------------------------------------------------------------- [3] Download
# The standalone servicing stack lookup walks back up to 36 months of the catalog, one search per month,
# and mostly finds nothing - it runs as a side job while the other updates are looked up and downloaded.
function Find-UpdateJob($Ctx) {
    Set-SideLabel 'servicing stack lookup'
    return (Find-Update $Ctx.Kind $Ctx.Fam $Ctx.MaxMonth $Ctx.Lookback)
}
function Invoke-Download([switch]$Auto) {
    Assert-Analyzed
    $f = $Script:S.Family
    Write-Title "Download updates - $($f.Name) $($f.Arch)"
    if (-not $f.Supported) { throw "$($f.Name) is not supported for automatic updates." }

    $max = (Get-Date).ToString('yyyy-MM')
    $win10 = (Get-FamilyOs $f) -eq '10'
    $cap = if ($win10 -and $f.Build -ge 19041 -and $f.Build -le 19045) { [string]$Script:Cfg.Win10Cutoff } elseif ($f.Cap) { [string]$f.Cap } else { '' }
    if ($cap -and [string]::CompareOrdinal($cap, $max) -lt 0) {
        $max = $cap
        if ($win10) { Write-Warn "Capped at $max (Windows 10 ESU cutoff - change it on the Windows updates page if you want to experiment)." }
        else { Write-Info "Up to $max - the last updates for $($f.Name), which is out of servicing." }
    }
    $found = @()

    Write-Step 'Latest cumulative update (LCU)'
    $lcu = Find-Update 'LCU' $f $max 24
    if (-not $lcu) { throw "No cumulative update found for $($f.Product) $($f.ArchTitle)." }
    Write-Ok $lcu.Title
    $found += , @('LCU', $lcu)
    $month = $lcu.Title.Substring(0, 7)

    Write-Step 'Standalone servicing stack update (only published when needed)'
    $ssuJob = $null
    if ($f.NoSsu) { Write-Info "None needed - $($f.Name) cumulative updates include the servicing stack." }
    elseif ($Auto) {
        $ssuJob = Start-SideJob @{ Name = 'Servicing stack lookup'; Command = 'Find-UpdateJob'; Tag = 'ssu'; Scratch = 'scratch-ssu'; DismMatch = '' } @{ Kind = 'SSU'; Fam = $f; MaxMonth = $month; Lookback = 36 }
    }
    if ($ssuJob) { Write-Info 'Looked up in the background (up to 36 months of the catalog) while the other updates are found and downloaded.' }
    elseif (-not $f.NoSsu) {
        $ssu = Find-Update 'SSU' $f $month 36
        if ($ssu) { Write-Ok $ssu.Title; $found += , @('SSU', $ssu) } else { Write-Info 'None needed - the LCU carries the servicing stack.' }
    }

    try {
        Write-Step 'Safe OS Dynamic Update (WinRE)'
        $safe = Find-Update 'SAFEOS' $f $month 12
        if ($safe) { Write-Ok $safe.Title; $found += , @('SAFEOS', $safe) } else { Write-Warn 'Not found - WinRE gets the servicing stack only.' }

        Write-Step 'Setup Dynamic Update (setup binaries on the media)'
        $setup = Find-Update 'SETUP' $f $month 12
        if ($setup) { Write-Ok $setup.Title; $found += , @('SETUP', $setup) } else { Write-Warn 'Not found - skipping.' }

        if ($f.NeedsEkb) {
            Write-Step "$($f.EkbFor) enablement package"
            $ekb = Find-ByKB $f.EkbKB $f $f.EkbFor
            if ($ekb) { Write-Ok $ekb.Title; $found += , @('EKB', $ekb) } else { Write-Warn "$($f.EkbKB) not found - the image keeps its current version number." }
        }

        if ($Script:Cfg.NetFx481 -and $win10 -and $f.Build -ge 19041 -and $f.Build -le 19045) {
            Write-Step '.NET Framework 4.8.1'
            $n481 = Find-ByKB 'KB5011048' $f "\b$($f.VerToken)\b"
            if ($n481) { Write-Ok $n481.Title; $found += , @('NET481', $n481) } else { Write-Warn '.NET 4.8.1 package not found - skipping.' }
        }

        Write-Step '.NET Framework cumulative update'
        $net = @(Find-Update 'NET' $f $month 12)
        if ($net.Count -gt 0) { foreach ($n in $net) { Write-Ok $n.Title; $found += , @('NET', $n) } } else { Write-Warn 'Not found - skipping.' }

        Write-Host ''
        Write-Host '  Packages to download:' -ForegroundColor Cyan
        foreach ($x in $found) { Write-Host ('   {0,-7} {1,-11} {2,10}  {3}' -f $x[0], $x[1].KB, $x[1].Size, $x[1].Date.ToString('yyyy-MM-dd')) }
        if ($ssuJob) { Write-Host '   SSU     (still being looked up in the background)' }
        if (-not $Auto -and -not (Read-YesNo 'Download them now?' $true)) { return }

        $records = @()
        $Script:SavedFiles = @{}
        foreach ($x in $found) {
            Write-Step "$($x[0]) $($x[1].KB)"
            $records += Save-UpdateFiles $x[1] $x[0]
        }
        if ($ssuJob) {
            Write-Step 'Standalone servicing stack update'
            $j = $ssuJob; $ssuJob = $null
            $ssu = Wait-SideJob $j
            if ($ssu) {
                Write-Ok $ssu.Title
                Write-Step "SSU $($ssu.KB)"
                $records += Save-UpdateFiles $ssu 'SSU'
            } else { Write-Info 'None needed - the LCU carries the servicing stack.' }
        }
    } catch {
        if ($ssuJob) { Stop-SideJob $ssuJob }
        throw
    }
    $Script:S.Updates = $records
    Save-State
    Write-Ok "All packages are in $($Script:P.Updates)"
}
#endregion
