#region ---------------------------------------------------------------- [7] Build ISO
# Free bytes on the drive that holds $Path, or -1 when that can't be told (network share).
function Get-FreeBytes([string]$Path) {
    try { return [double](New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)))).AvailableFreeSpace }
    catch { return -1 }
}
# An ISO that is mounted in Explorer or open in a virtual machine can't be replaced - better to
# say so before oscdimg writes 5 GB than after.
function Test-FileInUse([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None').Dispose(); return $false }
    catch [IO.IOException] { return $true }
    catch { return $false }
}
function Invoke-Build([switch]$Auto, [string]$OutIso) {
    Assert-Unpacked
    $S = $Script:S; $P = $Script:P; $Cfg = $Script:Cfg
    Write-Title 'Build ISO'
    $osc = Find-Oscdimg
    if (-not $osc) { $osc = Get-Oscdimg }
    Write-Info "oscdimg: $osc"
    if (-not $S.Serviced -and -not $Auto) {
        Write-Warn 'The media has not been slipstreamed yet (step 6).'
        if (-not (Read-YesNo 'Build the ISO anyway?' $false)) { return }
    }
    Sync-Oem
    Sync-Unattend
    Test-UnattendSelection
    Write-Step 'Install check (answer file, $OEM$, drivers)'
    $chk = @(Invoke-InstallCheck -NoDownload -Quiet)
    $bad = @($chk | Where-Object { $_.Level -eq 'Error' })
    if ($bad.Count -and -not (Read-YesNo "The install check found $($bad.Count) problem(s) that can break Windows setup (details in the log and on the Install check page). Build the ISO anyway?" $false)) {
        throw 'Build stopped - open the Install check page to see and fix the problems.'
    }

    $m = $P.Media
    $etfs = Join-Path $m 'boot\etfsboot.com'
    $ms = Join-Path $m 'efi\microsoft\boot'
    $order = @()
    if ($S.Serviced -and $S.Serviced.Boot2023) {
        if ($Cfg.NoPrompt) { $order += 'efisys_noprompt_ex.bin' }
        $order += 'efisys_ex.bin'
    }
    if ($Cfg.NoPrompt) { $order += 'efisys_noprompt.bin' }
    $order += 'efisys.bin'
    $efi = $null
    foreach ($n in $order) { $c = Join-Path $ms $n; if (Test-Path -LiteralPath $c) { $efi = $c; break } }
    if (-not $efi) { throw "No UEFI boot image (efisys*.bin) found in $ms." }
    Write-Info "UEFI boot image: $(Split-Path $efi -Leaf)"

    $build = if ($S.Serviced) { $S.Serviced.Build } elseif (@($S.Images).Count -gt 0) { $S.Images[0].Version } else { 'unknown' }
    $tag = if ($S.Family -and $S.Family.VerToken) { $S.Family.VerToken } else { 'custom' }
    $arch = if ($S.Family) { $S.Family.Arch } else { 'x64' }
    $label = if ($S.Family -and $S.Family.Label) { $S.Family.Label } else { 'WIN10_CUSTOM' }
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
    New-Item -ItemType Directory -Force -Path $P.Output | Out-Null
    $iso = Join-Path $P.Output ('Win{0}_{1}_{2}_{3}_{4:yyyyMMdd}.iso' -f (Get-FamilyOs $S.Family), $tag, $build, $arch, (Get-Date))
    if ($OutIso) { $iso = Resolve-OutIso $OutIso $iso }
    Write-Info "Output: $iso"
    New-Item -ItemType Directory -Force -Path (Split-Path $iso -Parent) | Out-Null
    if (Test-FileInUse $iso) {
        throw "$iso is in use - it is probably mounted in Explorer (right-click its drive, Eject) or open in a virtual machine. Close it, or choose another name under Output ISO."
    }

    # oscdimg writes into a .part file: an ISO of the same name is only replaced once the new one is complete
    $part = "$iso.part"
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    $need = [double](Get-ChildItem -LiteralPath $m -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum + 100MB
    $free = Get-FreeBytes $iso
    $old = if (Test-Path -LiteralPath $iso -PathType Leaf) { [double](Get-Item -LiteralPath $iso).Length } else { 0 }
    if ($free -ge 0 -and $free -lt $need -and $old -gt 0 -and $free + $old -ge $need) {
        Write-Info 'Not enough room for the new ISO next to the old one of the same name - the old one is deleted first.'
        Remove-Item -LiteralPath $iso, "$iso.sha256" -Force -ErrorAction SilentlyContinue
        $free += $old
    }
    if ($free -ge 0 -and $free -lt $need) {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($iso))
        $short = 'Only {0} free on {1} - the ISO needs about {2}.' -f (Format-Size $free), $root, (Format-Size $need)
        Write-Warn $short
        if (-not (Read-YesNo "$short Build it anyway?" $false)) {
            throw "Not enough free space for the ISO on $root - free some space, or choose a folder on another drive under Output ISO."
        }
    }

    if (Test-Path -LiteralPath $etfs) { $bootdata = "-bootdata:2#p0,e,b$(Q $etfs)#pEF,e,b$(Q $efi)" }
    else { $bootdata = "-bootdata:1#pEF,e,b$(Q $efi)"; Write-Info 'No etfsboot.com - building a UEFI-only ISO.' }
    Write-Step 'Writing ISO (BIOS + UEFI, UDF)'
    $code = Invoke-Exe $osc ("-m -o -u2 -udfver102 -l$label $bootdata $(Q $m) $(Q $part)") -MergeErr
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $part)) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $kept = if (Test-Path -LiteralPath $iso) { ' The previous ISO of that name is unchanged.' } else { '' }
        throw "oscdimg failed (exit $code).$kept"
    }
    try { Move-Item -LiteralPath $part -Destination $iso -Force }
    catch { throw "The new ISO could not replace $iso ($($_.Exception.Message)). It is saved as $part - rename it once the old file is free." }

    $size = (Get-Item -LiteralPath $iso).Length
    Write-Ok "ISO ready: $iso ($(Format-Size $size))"
    Write-Info 'Calculating SHA-256...'
    $hash = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
    Set-Content -LiteralPath "$iso.sha256" -Value "$hash *$(Split-Path $iso -Leaf)" -Encoding ASCII
    Write-Info "SHA-256: $hash"
    $S.Iso = $iso
    Save-State
    if (-not $Auto -and (Read-YesNo 'Open the output folder?' $true)) { Start-Process explorer.exe "/select,`"$iso`"" }
}
#endregion
