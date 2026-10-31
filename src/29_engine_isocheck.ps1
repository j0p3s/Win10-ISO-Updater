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
# Checks $Iso; the result is in $Script:S.IsoCheck. Status: original / unknown. Online: $true (pages read),
# $false (not reachable - only the list in this file was used), $null (not needed: found in that list).
function Test-IsoOriginal([string]$Iso) {
    $f = Get-Item -LiteralPath $Iso -ErrorAction Stop
    $key = Get-IsoFileKey $f
    $prev = $Script:S.IsoCheck
    if ($prev -and [string]$prev.Key -eq $key -and [string]$prev.Status -eq 'original') {
        Write-Ok "Original Microsoft ISO: $($prev.Product) - $($prev.Label) (SHA-256 checked $($prev.When))."
        return $prev
    }
    Write-Step "SHA-256 of $($f.Name) ($(Format-Size $f.Length))"
    if ($prev -and [string]$prev.Key -eq $key -and [string]$prev.Sha256 -match '^[0-9A-F]{64}$') { $sha = [string]$prev.Sha256; Write-Info 'Already computed - looking it up again.' }
    else {
        Write-Host 'Reading the ISO to compute its SHA-256' -NoNewline
        $t0 = Get-Date
        $sha = Get-FileSha256 $f.FullName
        if ($Script:Sync) { $Script:Sync.Pct = -1 }
        Write-Info ('{0}  ({1:mm\:ss})' -f $sha, ((Get-Date) - $t0))
    }
    $r = [ordered]@{ Key = $key; Path = $f.FullName; Name = $f.Name; Size = $f.Length; Sha256 = $sha; Status = 'unknown'
                     Product = ''; Label = ''; Source = ''; Listed = ''; Online = $null; When = (Get-Date).ToString('yyyy-MM-dd HH:mm', $Script:Inv)
                     Subscription = (Test-SubscriptionIsoName $f.Name) }
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
        $from = if ($r.Source -eq 'list') { "Microsoft's list as of $($hit.Listed)" } else { 'microsoft.com' }
        Write-Ok "Original Microsoft ISO: $($r.Product) - $($r.Label) (SHA-256 found on $from)."
    } else {
        Write-Warn "The SHA-256 of $($f.Name) is not one Microsoft lists for its Windows 10 and 11 ISOs."
        if ($r.Online -eq $false) { Write-Warn 'microsoft.com could not be reached, so only the list in this program was used - check again when online for the newest ISOs.' }
        if ($r.Subscription) { Write-Info 'Its name is the one of a Visual Studio subscription / Volume Licensing download: compare the SHA-256 above with the one shown on that portal.' }
        Write-Info 'ISOs made with the Media Creation Tool are built on the PC and are never in the list, and an older ISO Microsoft no longer offers may be missing too. Otherwise it may be modified - download an original Windows 10 or 11 ISO from microsoft.com.'
    }
    $Script:S.IsoCheck = $r
    Save-State
    return $r
}
#endregion
