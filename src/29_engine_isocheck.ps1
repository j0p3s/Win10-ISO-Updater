#region ---------------------------------------------------------------- is the ISO an original from Microsoft? (SHA-256)
# Microsoft lists the SHA-256 of every ISO on its download pages ("Verify your download"). An ISO is original when
# its SHA-256 is one of them: the values in Get-KnownIsoHashes (built from src/iso-hashes.json, which keeps the ISOs
# Microsoft no longer lists) or, when it is not there, on the pages themselves. No other source is trusted.
# The result is kept in the state (IsoCheck) with the file's size and date, so an ISO is read only once.
$Script:IsoHashUA = 'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0'   # the Windows 10 page lists the ISOs only for browsers that are not on Windows
function Get-IsoHashPages {
    return @(
        @{ Name = 'Windows 11'; Arch = 'x64';   Url = 'https://www.microsoft.com/en-us/software-download/windows11' }
        @{ Name = 'Windows 11'; Arch = 'Arm64'; Url = 'https://www.microsoft.com/en-us/software-download/windows11arm64' }
        @{ Name = 'Windows 10'; Arch = '';      Url = 'https://www.microsoft.com/en-us/software-download/windows10ISO' }
    )
}
# The "Verify your download" table of one page -> Sha256 / Product / Label ("English 64-bit").
function Read-IsoHashPage([string]$Html, $Page) {
    $prod = [string]$Page.Name
    $v = [regex]::Match([string]$Html, 'Version (\d{2}H\d)')
    if ($v.Success) { $prod += ' ' + $v.Groups[1].Value }
    if ($Page.Arch -eq 'Arm64') { $prod += ' Arm64' }
    $rows = [regex]::Matches([string]$Html, '<tr>\s*<td>([^<]+)</td>\s*<td>\s*([0-9A-Fa-f]{64})\s*</td>\s*</tr>', 'IgnoreCase')
    return @(foreach ($r in $rows) {
        [pscustomobject]@{
            Sha256 = $r.Groups[2].Value.ToUpperInvariant(); Product = $prod; Listed = ''
            Label  = ([regex]::Replace([Net.WebUtility]::HtmlDecode($r.Groups[1].Value), '\s+', ' ')).Trim()
        }
    })
}
# The tables on microsoft.com now. Read = pages read, Failed = pages that could not be read (offline, blocked, changed).
function Get-MicrosoftIsoHashes {
    $out = @(); $read = 0; $failed = @()
    foreach ($pg in Get-IsoHashPages) {
        try {
            $html = (Invoke-WebRequest -Uri $pg.Url -UseBasicParsing -UserAgent $Script:IsoHashUA -TimeoutSec 45 -Headers @{ 'Accept-Language' = 'en-US,en;q=0.9' }).Content
            $rows = @(Read-IsoHashPage $html $pg)
            if ($rows.Count -eq 0) { $failed += "$($pg.Url) (no SHA-256 table on the page)"; continue }
            $out += $rows; $read++
        } catch { $failed += "$($pg.Url) ($($_.Exception.Message))" }
    }
    return @{ Hashes = $out; Read = $read; Failed = $failed }
}
# The list in this file (src/iso-hashes.json at build time): Sha256 / Product / Label / Listed (first day Microsoft showed it).
function Get-KnownIsoHashList {
    if (-not (Get-Command Get-KnownIsoHashes -ErrorAction SilentlyContinue)) { return @() }
    return @(foreach ($l in ((Get-KnownIsoHashes) -split "`r?`n")) {
        $f = $l -split "`t"
        if ($f.Count -lt 4 -or $f[0] -notmatch '^[0-9A-F]{64}$') { continue }
        [pscustomobject]@{ Sha256 = $f[0]; Product = [Net.WebUtility]::HtmlDecode($f[1]); Label = [Net.WebUtility]::HtmlDecode($f[2]); Listed = $f[3] }
    })
}
function Get-FileSha256([string]$Path) {
    $alg = $null
    try { $alg = New-Object Security.Cryptography.SHA256Cng } catch { $alg = [Security.Cryptography.SHA256]::Create() }
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 1MB, [IO.FileOptions]::SequentialScan)
    try {
        $len = $fs.Length; $buf = New-Object byte[] (4MB); $done = 0L; $last = -1
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$alg.TransformBlock($buf, 0, $n, $null, 0)
            $done += $n
            if ($Script:Sync -and $len -gt 0) {
                $p = [math]::Floor(1000.0 * $done / $len) / 10
                if ($p -ne $last) { $Script:Sync.Pct = $p; $last = $p }
            }
        }
        [void]$alg.TransformFinalBlock($buf, 0, 0)
        return ([BitConverter]::ToString($alg.Hash) -replace '-', '')
    } finally { $fs.Dispose(); $alg.Dispose() }
}
# File names of the Visual Studio subscription / Volume Licensing downloads (en-us_windows_10_..._dvd_1a2b3c4d.iso,
# SW_DVD9_Win_Pro_10_22H2...ISO): those ISOs are original too, but Microsoft lists their SHA-256 only on that portal.
function Test-SubscriptionIsoName([string]$Name) {
    return ($Name -match '^[a-z]{2}(-[a-z]{2,4})?_windows_(10|11|server)_.*_dvd_[0-9a-f]{8}\.iso$' -or $Name -match '^SW_DVD\d')
}
function Get-IsoFileKey($File) {
    return '{0}|{1}|{2}' -f $File.FullName.ToLowerInvariant(), $File.Length, $File.LastWriteTimeUtc.Ticks
}
# The files of the setup media that carry Microsoft's own (embedded) signature: setup and the boot managers.
# An ISO the Media Creation Tool made on the PC can't be in Microsoft's SHA-256 list, but these files in it are
# Microsoft's. They don't cover the Windows image (install.esd / install.wim), which isn't signed as a whole.
$Script:IsoSignedFiles = @('setup.exe', 'sources\setup.exe', 'sources\setupprep.exe', 'sources\setuphost.exe', 'bootmgr.efi',
                           'efi\boot\bootx64.efi', 'efi\boot\bootaa64.efi', 'efi\boot\bootia32.efi', 'efi\microsoft\boot\cdboot.efi')
# Checked / Bad (file and why) / Esd: install.esd, the Windows image of an ISO built from Microsoft's download
# files (the Media Creation Tool) - the ISOs Microsoft offers for download have install.wim.
function Test-IsoFolderSignatures([string]$Root) {
    $checked = @(); $bad = @()
    foreach ($rel in $Script:IsoSignedFiles) {
        $p = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $sig = Get-AuthenticodeSignature -LiteralPath $p
        $st = [string]$sig.Status
        if ($st -eq 'NotSupportedFileFormat') { Add-Log "ISO check: $rel - signature can't be read on this Windows"; continue }
        $subj = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
        $checked += $rel
        if ($st -ne 'Valid') { $bad += "$rel ($st)" }
        elseif ($subj -notmatch 'O=Microsoft Corporation') { $bad += "$rel (signed by $($subj -replace '^CN=([^,]+).*$', '$1'))" }
    }
    if (-not (@($checked) -match '^(sources\\)?setup\.exe$') -and -not (@($bad) -match '^(sources\\)?setup\.exe ')) { $bad += 'setup.exe (missing)' }
    if (-not (@($checked) -match '\.efi$') -and -not (@($bad) -match '\.efi ')) { $bad += 'efi\boot\boot*.efi (missing)' }
    return [pscustomobject]@{ Checked = @($checked); Bad = @($bad); Esd = (Test-Path -LiteralPath (Join-Path $Root 'sources\install.esd') -PathType Leaf) }
}
# Runs $Do with the root of the mounted ISO ("E:\"); an ISO that was already mounted stays mounted.
function Invoke-WithMountedIso([string]$Iso, [scriptblock]$Do) {
    $img = Get-DiskImage -ImagePath $Iso
    $was = [bool]$img.Attached
    if (-not $was) { $img = Mount-DiskImage -ImagePath $Iso -PassThru; Start-Sleep -Seconds 2 }
    try {
        $vol = $img | Get-Volume
        if (-not $vol.DriveLetter) { throw 'The ISO mounted without a drive letter (auto-mount disabled?).' }
        return (& $Do "$($vol.DriveLetter):\")
    } finally {
        if (-not $was) { Dismount-DiskImage -ImagePath $Iso | Out-Null }
    }
}
# Checks $Iso; the result is in $Script:S.IsoCheck. Status:
#   original - its SHA-256 is one Microsoft lists
#   mct      - not listed, built from Microsoft's download files (install.esd, the Media Creation Tool) and its
#              setup and boot files are signed by Microsoft
#   badsig   - not listed, and setup or boot files are not signed by Microsoft (or are missing): modified
#   unknown  - not listed; its signatures are in SigChecked / SigBad when the ISO could be opened (SigDone)
# Online: $true (pages read), $false (not reachable - only the list in this file was used), $null (not needed).
function Test-IsoOriginal([string]$Iso) {
    $f = Get-Item -LiteralPath $Iso -ErrorAction Stop
    $key = Get-IsoFileKey $f
    $prev = $Script:S.IsoCheck
    $same = $prev -and [string]$prev.Key -eq $key
    if ($same -and [string]$prev.Status -in 'original', 'mct', 'badsig') {
        Write-IsoCheckResult $prev
        return $prev
    }
    Write-Step "SHA-256 of $($f.Name) ($(Format-Size $f.Length))"
    if ($same -and [string]$prev.Sha256 -match '^[0-9A-F]{64}$') { $sha = [string]$prev.Sha256; Write-Info 'Already computed - looking it up again.' }
    else {
        Write-Host 'Reading the ISO to compute its SHA-256' -NoNewline
        $t0 = Get-Date
        $sha = Get-FileSha256 $f.FullName
        if ($Script:Sync) { $Script:Sync.Pct = -1 }
        Write-Info ('{0}  ({1:mm\:ss})' -f $sha, ((Get-Date) - $t0))
    }
    $r = [ordered]@{ Key = $key; Path = $f.FullName; Name = $f.Name; Size = $f.Length; Sha256 = $sha; Status = 'unknown'
                     Product = ''; Label = ''; Source = ''; Listed = ''; Online = $null; When = (Get-Date).ToString('yyyy-MM-dd HH:mm', $Script:Inv)
                     Subscription = (Test-SubscriptionIsoName $f.Name); SigDone = $false; SigChecked = @(); SigBad = @(); Esd = $false }
    $hit = @(Get-KnownIsoHashList | Where-Object { $_.Sha256 -eq $sha }) | Select-Object -First 1
    if ($hit) { $r.Source = 'list' }
    else {
        Write-Host 'Reading the SHA-256 lists on microsoft.com' -NoNewline
        $ms = Get-MicrosoftIsoHashes
        foreach ($e in @($ms.Failed)) { Add-Log "ISO check: could not read $e" }
        $r.Online = ($ms.Read -gt 0)
        $hit = @($ms.Hashes | Where-Object { $_.Sha256 -eq $sha }) | Select-Object -First 1
        if ($hit) { $r.Source = 'microsoft.com' }
    }
    if ($hit) {
        $r.Status = 'original'; $r.Product = $hit.Product; $r.Label = $hit.Label; $r.Listed = $hit.Listed
    } else {
        if ($same -and $prev.SigDone) { $r.SigDone = $true; $r.SigChecked = @($prev.SigChecked | Where-Object { $_ }); $r.SigBad = @($prev.SigBad | Where-Object { $_ }); $r.Esd = [bool]$prev.Esd }
        else {
            Write-Host 'Checking the Microsoft signatures of the setup and boot files in the ISO' -NoNewline
            try {
                $sig = Invoke-WithMountedIso $f.FullName { param($Root) Test-IsoFolderSignatures $Root }
                $r.SigDone = $true; $r.SigChecked = @($sig.Checked); $r.SigBad = @($sig.Bad); $r.Esd = [bool]$sig.Esd
            } catch { Write-Warn "The ISO could not be opened to check the signatures of its files: $($_.Exception.Message)" }
        }
        if ($r.SigDone -and @($r.SigBad).Count) { $r.Status = 'badsig' }
        elseif ($r.SigDone -and $r.Esd -and -not $r.Subscription) { $r.Status = 'mct' }
    }
    Write-IsoCheckResult $r
    $Script:S.IsoCheck = $r
    Save-State
    return $r
}
function Write-IsoCheckResult($R) {
    $ok = @($R.SigChecked | Where-Object { $_ }); $bad = @($R.SigBad | Where-Object { $_ })      # a list read back from state.json may be $null
    $signed = if ($ok.Count) { 'Setup and boot files signed by Microsoft: ' + ($ok -join ', ') + '.' } else { '' }
    switch ([string]$R.Status) {
        'original' {
            $from = if ($R.Source -eq 'list') { "Microsoft's list as of $($R.Listed)" } else { 'microsoft.com' }
            Write-Ok "Original Microsoft ISO: $($R.Product) - $($R.Label) (SHA-256 found on $from)."
        }
        'mct' {
            Write-Info "$($R.Name) was made with the Media Creation Tool (its Windows image is install.esd): it is built on the PC, so its SHA-256 is never in Microsoft's list - nothing wrong."
            Write-Ok $signed
            Write-Info 'The Windows image itself (install.esd) is not signed as a whole, so it is not covered by this check.'
        }
        'badsig' {
            Write-Warn "Not signed by Microsoft: $($bad -join ', ')."
            Write-Warn "$($R.Name) has been modified - download an original Windows 10 or 11 ISO from microsoft.com."
        }
        default {
            Write-Warn "The SHA-256 of $($R.Name) is not one Microsoft lists for its Windows 10 and 11 ISOs."
            if ($R.Online -eq $false) { Write-Warn 'microsoft.com could not be reached, so only the list in this program was used - check again when online for the newest ISOs.' }
            if ($signed) { Write-Ok "$signed The Windows image itself is not covered by this check." }
            if ($R.Subscription) { Write-Info 'Its name is the one of a Visual Studio subscription / Volume Licensing download: compare the SHA-256 above with the one shown on that portal.' }
            Write-Info 'An older ISO Microsoft no longer offers may be missing from the list too. Otherwise it may be modified - download an original Windows 10 or 11 ISO from microsoft.com.'
        }
    }
}
#endregion
