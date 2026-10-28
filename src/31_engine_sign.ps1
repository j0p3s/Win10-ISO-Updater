
#region ---------------------------------------------------------------- re-signing modded drivers (NVCleanstall / edited INF)
function Get-StoreCert {
    $now = Get-Date
    return (Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $Script:CertSubject -and $_.HasPrivateKey -and $_.NotAfter -gt $now.AddDays(30) } |
            Sort-Object NotAfter -Descending | Select-Object -First 1)
}
function Find-Pfx {
    # signing\ is where this tool keeps it; Signing-Output\ is where Sign-Drivers.cmd kept it
    foreach ($p in @((Join-Path $Script:SignDir 'DriverSigning.pfx'), (Join-Path $Script:Root 'Signing-Output\DriverSigning.pfx'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
# ready = in the store and backed up | export = in the store, no .pfx yet
# import = .pfx found, password needed | create = nothing yet
function Get-CertStatus {
    $c = Get-StoreCert
    $pfx = Find-Pfx
    if ($c -and $pfx) { return 'ready' }
    if ($c) { return 'export' }
    if ($pfx) { return 'import' }
    return 'create'
}
function Get-SigningCert($Password) {
    New-Item -ItemType Directory -Force -Path $Script:SignDir | Out-Null
    $pfx = Join-Path $Script:SignDir 'DriverSigning.pfx'
    $cer = Join-Path $Script:SignDir 'DriverSigning.cer'
    $cert = Get-StoreCert
    if (-not $cert) {
        $have = Find-Pfx
        if ($have) {
            if (-not $Password) { throw 'The password of DriverSigning.pfx is needed.' }
            Write-Sub "Loading $have"
            try { $cert = Import-PfxCertificate -FilePath $have -CertStoreLocation Cert:\CurrentUser\My -Password $Password | Select-Object -First 1 }
            catch { throw 'Could not open DriverSigning.pfx - wrong password?' }
            if ($have -ne $pfx) { Copy-Item -LiteralPath $have -Destination $pfx -Force }
        } else {
            if (-not $Password) { throw 'A password for the new DriverSigning.pfx is needed.' }
            Write-Sub 'Creating a self-signed code-signing certificate (10 years)'
            $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Script:CertSubject -KeyAlgorithm RSA -KeyLength 3072 `
                    -HashAlgorithm SHA256 -KeyExportPolicy Exportable -KeyUsage DigitalSignature `
                    -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10) -FriendlyName 'Custom Driver Signing'
        }
    }
    if (-not (Test-Path -LiteralPath $pfx)) {
        if (-not $Password) { throw 'A password is needed to back up the certificate as DriverSigning.pfx.' }
        Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $Password | Out-Null
        Write-Ok "Certificate backed up to $pfx - keep it private."
    }
    Export-Certificate -Cert $cert -FilePath $cer -Type CERT | Out-Null
    return $cert
}
# Trusts the certificate on this PC for a moment (to verify catalogs) and returns the
# stores it was added to - stores that already trusted it are left alone afterwards.
function Add-TempTrust([string]$Cer) {
    $pub = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Cer
    $added = @()
    foreach ($name in 'Root', 'TrustedPublisher') {
        $st = New-Object Security.Cryptography.X509Certificates.X509Store -ArgumentList $name, 'LocalMachine'
        $st.Open('ReadWrite')
        if (-not @($st.Certificates | Where-Object { $_.Thumbprint -eq $pub.Thumbprint }).Count) { $st.Add($pub); $added += $name }
        $st.Close()
    }
    return $added
}
function Remove-TempTrust([string]$Cer, [string[]]$Stores) {
    $pub = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Cer
    foreach ($name in @($Stores)) {
        $st = New-Object Security.Cryptography.X509Certificates.X509Store -ArgumentList $name, 'LocalMachine'
        $st.Open('ReadWrite'); $st.Remove($pub); $st.Close()
    }
}
function Get-InfCatalogs([string]$Inf) {
    $names = @()
    foreach ($line in @(Get-Content -LiteralPath $Inf -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*CatalogFile(\.\w+)?\s*=\s*"?([^";\s]+)"?') { $names += $Matches[2] }
    }
    return @($names | Sort-Object -Unique)
}
function Get-InfFolders([string]$Root) {
    $list = @()
    $infs = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.inf' })
    foreach ($g in ($infs | Group-Object DirectoryName)) {
        $list += [pscustomobject]@{ Dir = $g.Name; Infs = @($g.Group | ForEach-Object { $_.FullName }) }
    }
    return $list
}
# Hardware + compatible IDs of every device present in this PC.
function Get-HostHardwareIds {
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
            foreach ($h in @($d.HardwareID) + @($d.CompatibleID)) { if ($h) { [void]$ids.Add(([string]$h).Trim()) } }
        }
    } catch { Add-Log "Hardware IDs of this PC could not be read: $($_.Exception.Message)" }
    return , $ids
}
# Device IDs an INF installs on (PCI\VEN_10DE&DEV_2206&SUBSYS_..., HDAUDIO\FUNC_01&VEN_10DE...).
function Get-InfDeviceIds([string]$Inf) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $text = ''
    try { $text = [IO.File]::ReadAllText($Inf) } catch { }
    foreach ($line in ($text -split "`r?`n")) {
        $l = $line -replace ';.*$', ''
        if ($l -notmatch '=') { continue }
        foreach ($m in [regex]::Matches($l, '(?i)(?<![\w\\])(?:PCI|HDAUDIO|USB|HID|ACPI|SWC|INTELAUDIO|BTHENUM)\\[^\s,;"]+')) { [void]$set.Add($m.Value) }
    }
    return , $set
}
function Get-InfIncludes([string]$Inf) {
    $names = @()
    foreach ($line in @(Get-Content -LiteralPath $Inf -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*Include\s*=\s*(.+)$') {
            $names += @(($Matches[1] -replace ';.*$', '') -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
        }
    }
    return @($names | Sort-Object -Unique)
}
# "Only this PC's hardware": in a folder with several INF files (NVIDIA Display.Driver has one per
# laptop / desktop maker), keeps the INF files that list a hardware ID of this PC and removes the
# others from the work copy, so Inf2Cat has a fraction of the work. INF files without device IDs
# (components, software) and INF files that a kept one includes stay. A folder where nothing
# matches this PC is left whole.
function Limit-InfsToHost([string]$Root, $Pkgs) {
    $res = [pscustomobject]@{ Removed = 0; Kept = @() }
    $hw = Get-HostHardwareIds
    if ($hw.Count -eq 0) { Write-Warn 'The hardware IDs of this PC could not be read - every INF file is kept.'; return $res }
    foreach ($p in @($Pkgs)) {
        if (@($p.Infs).Count -lt 2) { continue }
        $rel = $p.Dir.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/'); if (-not $rel) { $rel = '.' }
        $keep = New-Object System.Collections.Generic.List[string]
        $other = New-Object System.Collections.Generic.List[string]
        $hits = @()
        foreach ($inf in $p.Infs) {
            $ids = Get-InfDeviceIds $inf
            if ($ids.Count -eq 0) { $keep.Add($inf); continue }
            $hit = $null
            foreach ($id in $ids) { if ($hw.Contains($id)) { $hit = $id; break } }
            if ($hit) { $keep.Add($inf); $hits += ('{0} ({1})' -f (Split-Path $inf -Leaf), $hit) } else { $other.Add($inf) }
        }
        if ($hits.Count -eq 0) { Write-Info "$rel : no INF file lists this PC's hardware - all $(@($p.Infs).Count) are kept"; continue }
        if ($other.Count -eq 0) { continue }
        $more = $true
        while ($more) {
            $more = $false
            foreach ($k in @($keep)) {
                foreach ($inc in (Get-InfIncludes $k)) {
                    $o = @($other | Where-Object { (Split-Path $_ -Leaf) -ieq $inc }) | Select-Object -First 1
                    if ($o) { [void]$other.Remove($o); $keep.Add($o); $more = $true }
                }
            }
        }
        foreach ($o in $other) { Remove-Item -LiteralPath $o -Force }
        $p.Infs = @($keep)
        $res.Removed += $other.Count
        $res.Kept += @($keep | ForEach-Object { Split-Path $_ -Leaf })
        Write-Info ("{0} : kept {1} for this PC, removed {2} INF file(s) for other hardware from the work copy" -f $rel, (($hits | Select-Object -First 3) -join ', '), $other.Count)
    }
    return $res
}
# ok | mismatch | untrusted | catalog-missing | no-catalog-directive | unknown (no signtool to check)
function Get-InfState([string]$Inf) {
    $cats = @(Get-InfCatalogs $Inf)
    if ($cats.Count -eq 0) { return 'no-catalog-directive' }
    $dir = Split-Path -Parent $Inf
    foreach ($c in $cats) {
        $cp = Join-Path $dir $c
        if (-not (Test-Path -LiteralPath $cp)) { return 'catalog-missing' }
        if ($Script:SignTool) {
            $v = Get-VerifyState $cp $Inf
            if ($v -ne 'ok') { return $v }
        }
    }
    if ($Script:SignTool) { return 'ok' }
    return 'unknown'
}
function Invoke-SignCatalog([string]$CatFile, $Cert) {
    if ($Script:SignTool) {
        $r = Invoke-Native $Script:SignTool @('sign', '/fd', 'SHA256', '/sha1', $Cert.Thumbprint, '/s', 'My', $CatFile)
        Add-Log $r.Text
        if ($r.Code -ne 0) { @($r.Output | Where-Object { $_.Trim() } | Select-Object -Last 3) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow } }
        return ($r.Code -eq 0)
    }
    $r = Set-AuthenticodeSignature -FilePath $CatFile -Certificate $Cert -HashAlgorithm SHA256
    return ($null -ne $r.SignerCertificate)
}
# Signs up to 16 catalogs per signtool call instead of one call each. Returns the files that
# could not be signed (a batch that fails is signed again one file at a time to find them).
function Invoke-SignCatalogs([string[]]$Files, $Cert) {
    $Files = @($Files | Where-Object { $_ })
    $failed = @()
    if (-not $Files.Count) { return $failed }
    if (-not $Script:SignTool) {
        foreach ($s in @(Set-AuthenticodeSignature -FilePath $Files -Certificate $Cert -HashAlgorithm SHA256)) { if (-not $s.SignerCertificate) { $failed += $s.Path } }
        return $failed
    }
    for ($i = 0; $i -lt $Files.Count; $i += 16) {
        $chunk = @($Files[$i..([math]::Min($i + 15, $Files.Count - 1))])
        $r = Invoke-Native $Script:SignTool (@('sign', '/fd', 'SHA256', '/sha1', $Cert.Thumbprint, '/s', 'My') + $chunk)
        Add-Log $r.Text
        if ($r.Code -eq 0) { continue }
        foreach ($f in $chunk) { if (-not (Invoke-SignCatalog $f $Cert)) { $failed += $f } }
    }
    return $failed
}
function Test-SignedCatalog([string]$CatFile, [string]$Inf) {
    if ($Script:SignTool) {
        return ((Get-VerifyState $CatFile $Inf) -eq 'ok')
    }
    return ((Get-AuthenticodeSignature -FilePath $CatFile).Status -eq 'Valid')
}
# Inf2Cat runs at the same time: the setting, or the processor cores up to 4 (0 = automatic).
function Get-SignJobs {
    $n = 0
    if ($Script:Cfg) { $n = [int]$Script:Cfg.SignJobs }
    if ($n -lt 1) { $n = [math]::Min(4, [Environment]::ProcessorCount) }
    return [int][math]::Max(1, [math]::Min(8, $n))
}
# How fast Inf2Cat was in earlier runs, for the time estimate: MB of driver files x INF files per
# second (one INF checked against 1 GB at 12 per second takes about 85 s). Kept with the tools.
function Get-Inf2CatRate {
    try {
        $v = [double](Get-Content -LiteralPath (Join-Path $ToolsDir 'inf2cat-speed.json') -Raw | ConvertFrom-Json).Rate
        if ($v -gt 0) { return $v }
    } catch { }
    return 12.0
}
function Save-Inf2CatRate([double]$Rate) {
    $f = Join-Path $ToolsDir 'inf2cat-speed.json'
    $v = $Rate
    if (Test-Path -LiteralPath $f) { $v = 0.5 * (Get-Inf2CatRate) + 0.5 * $Rate }
    $v = [math]::Round([math]::Max(0.5, [math]::Min(2000.0, $v)), 2)
    try {
        New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
        ConvertTo-Json @{ Rate = $v } | Set-Content -LiteralPath $f -Encoding ASCII
    } catch { }
}
# Splits the INF files of one folder into groups that share a catalog (a new catalog has to cover
# every INF that names it), keeps the groups with an INF from $Need and spreads them over at most
# $Parts runs, the biggest group first. Returns one object per run with its INF files.
function Split-InfGroups([string[]]$Infs, [string[]]$Need, [int]$Parts) {
    $groups = New-Object System.Collections.Generic.List[object]
    foreach ($inf in $Infs) {
        $cats = @(Get-InfCatalogs $inf | ForEach-Object { $_.ToLowerInvariant() })
        $g = [pscustomobject]@{ Infs = @($inf); Cats = $cats }
        foreach ($o in $groups.ToArray()) {
            if (@($o.Cats | Where-Object { $cats -contains $_ }).Count) { $g.Infs += $o.Infs; $g.Cats = @(@($g.Cats) + @($o.Cats) | Sort-Object -Unique); [void]$groups.Remove($o) }
        }
        $groups.Add($g)
    }
    $keep = @($groups | Where-Object { $inf = $_; @($inf.Infs | Where-Object { $Need -contains $_ }).Count } | Sort-Object { @($_.Infs).Count } -Descending)
    $n = [math]::Max(1, [math]::Min($Parts, $keep.Count))
    $bins = @(1..$n | ForEach-Object { [pscustomobject]@{ Infs = @() } })
    foreach ($g in $keep) {
        $b = $bins | Sort-Object { @($_.Infs).Count } | Select-Object -First 1
        $b.Infs += $g.Infs
    }
    return @($bins | Where-Object { @($_.Infs).Count })
}
function New-HardLink([string]$Link, [string]$Target) {
    try {
        if (-not ('W10U.Fs' -as [type])) {
            Add-Type -Namespace W10U -Name Fs -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);'
        }
        return [W10U.Fs]::CreateHardLink($Link, $Target, [IntPtr]::Zero)
    } catch { return $false }
}
# A copy of a package folder for Inf2Cat with only some of its INF files: the driver files are hard
# links (instant, no extra space; copied where the drive has no hard links), no catalogs, and only
# the INF files given. Inf2Cat then checks those INF files instead of every INF in the folder.
function New-InfStage([string]$Dir, [string]$Stage, [string[]]$Infs) {
    New-Item -ItemType Directory -Force -Path $Stage | Out-Null
    $base = $Dir.TrimEnd('\', '/').Length
    $res = [pscustomobject]@{ Links = 0; Copies = 0 }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Extension -ieq '.inf' -or $f.Extension -ieq '.cat') { continue }
        $dst = Join-Path $Stage $f.FullName.Substring($base).TrimStart('\', '/')
        $pd = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Force -Path $pd | Out-Null }
        if (New-HardLink $dst $f.FullName) { $res.Links++ } else { Copy-Item -LiteralPath $f.FullName -Destination $dst -Force; $res.Copies++ }
    }
    foreach ($i in $Infs) { Copy-Item -LiteralPath $i -Destination $Stage -Force }
    return $res
}
# $Isolate: only the INF files that need a new signature (and the ones sharing their catalog) are
# catalogued, in copies of the folder - every other INF keeps its catalog and signature. $Jobs:
# Inf2Cat runs at the same time. A folder whose isolated run fails is catalogued whole, as before.
function Invoke-SignFolder([string]$Root, $Cert, [string]$Inf2Cat, [bool]$All, [bool]$OnlyThisPc = $false, [bool]$Isolate = $true, [int]$Jobs = 1) {
    $os = if ($Script:S.Family -and $Script:S.Family.Arch -eq 'x86') { '10_X86' } else { '10_X64' }
    $Jobs = [math]::Max(1, [math]::Min(8, $Jobs))
    $pkgs = @(Get-InfFolders $Root)
    $trim = [pscustomobject]@{ Removed = 0; Kept = @() }
    if ($OnlyThisPc) { $trim = Limit-InfsToHost $Root $pkgs }
    $states = @{}
    $total = 0; foreach ($p in $pkgs) { $total += @($p.Infs).Count }
    $n = 0
    foreach ($p in $pkgs) { foreach ($inf in $p.Infs) { $n++; Write-Host "checking the signature of INF $n of $total" -NoNewline; $states[$inf] = Get-InfState $inf } }
    if ($Script:Sync) { $Script:Sync.Status = '' }
    $bad = @($states.Keys | Where-Object { $states[$_] -in 'mismatch', 'untrusted', 'catalog-missing', 'unknown' })
    $untrusted = @($states.Keys | Where-Object { $states[$_] -eq 'untrusted' }).Count
    Write-Info ("{0} INF file(s) in {1} folder(s) - {2} need a new signature ({3} signed with a certificate Windows does not trust)" -f @($states.Keys).Count, $pkgs.Count, $bad.Count, $untrusted)
    $res = [ordered]@{ Signed = 0; Failed = 0; Untouched = 0; Skipped = 0; Removed = [int]$trim.Removed; Kept = @($trim.Kept) }
    $todo = @()
    foreach ($p in $pkgs) {
        $rel = $p.Dir.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/'); if (-not $rel) { $rel = '.' }
        $withCat = @($p.Infs | Where-Object { $states[$_] -ne 'no-catalog-directive' })
        $need = @($p.Infs | Where-Object { $states[$_] -in 'mismatch', 'untrusted', 'catalog-missing', 'unknown' })
        if ($withCat.Count -eq 0) { Write-Info "$rel : no CatalogFile= line in the INF - left as is"; $res.Skipped++; continue }
        if (-not $All -and $need.Count -eq 0) { $res.Untouched++; continue }
        $todo += [pscustomobject]@{ Pkg = $p; Rel = $rel; WithCat = $withCat; Need = $(if ($All) { $withCat } else { $need }); Staged = $false; Runs = @(); Check = $withCat; Cats = @(); Ok = $true; Start = $null; Mb = 1.0 }
    }
    $stageBase = $Root.TrimEnd('\', '/') + '~stage'
    if (Test-Path -LiteralPath $stageBase) { Remove-Item -LiteralPath $stageBase -Recurse -Force -ErrorAction SilentlyContinue }
    $rate = Get-Inf2CatRate
    try {
        # ---- what every Inf2Cat run gets
        $i = 0; $ns = 0
        foreach ($t in $todo) {
            $i++
            $p = $t.Pkg
            $cnt = @($p.Infs).Count
            Write-Sub ('{0}  ({1} INF file(s), folder {2} of {3})' -f $t.Rel, $cnt, $i, $todo.Count)
            $mb = [math]::Max(1.0, [double](@(Get-ChildItem -LiteralPath $p.Dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum)[0].Sum) / 1MB)
            $t.Mb = $mb
            $parts = @()
            if ($Isolate) { $parts = @(Split-InfGroups $t.WithCat $t.Need $Jobs) }
            $picked = 0; foreach ($x in $parts) { $picked += @($x.Infs).Count }
            if ($parts.Count -gt 1 -or ($parts.Count -eq 1 -and $picked -lt $t.WithCat.Count)) {
                try {
                    $runs = @()
                    foreach ($x in $parts) {
                        $ns++
                        $sd = Join-Path $stageBase $ns
                        $m = New-InfStage $p.Dir $sd @($x.Infs)
                        if ($m.Copies -gt 0) { Add-Log "$($t.Rel): $($m.Copies) file(s) copied for Inf2Cat (no hard links on this drive)" }
                        $lbl = if ($parts.Count -gt 1) { '{0} part {1}/{2}' -f $t.Rel, ($runs.Count + 1), $parts.Count } else { $t.Rel }
                        $runs += [pscustomobject]@{ Dir = $sd; Label = $lbl; Infs = @($x.Infs).Count; Est = (3 + @($x.Infs).Count * $mb / $rate); R = $null }
                    }
                    $t.Runs = $runs; $t.Staged = $true
                    $t.Check = @($parts | ForEach-Object { $_.Infs })
                    $msg = '{0} of {1} INF file(s) get a new catalog - the others keep their signature' -f $picked, $t.WithCat.Count
                    if ($parts.Count -gt 1) { $msg += " (in $($parts.Count) Inf2Cat runs at the same time)" }
                    Write-Info $msg
                } catch {
                    Add-Log "$($t.Rel): isolated copy not possible ($($_.Exception.Message)) - the whole folder is catalogued"
                    $t.Staged = $false; $t.Check = $t.WithCat
                }
            }
            if (-not $t.Staged) { $t.Runs = @([pscustomobject]@{ Dir = $p.Dir; Label = $t.Rel; Infs = $cnt; Est = (3 + $cnt * $mb / $rate); R = $null }) }
            if (@($t.Runs | Where-Object { $_.Infs -ge 10 }).Count) {
                Write-Info "Inf2Cat checks each of these INF files against every file of the package - this can take a long time (up to an hour for a full NVIDIA package). It is still working while the time in the status line keeps counting."
                if (-not $OnlyThisPc) { Write-Info 'Faster next time: "Only keep the INF files for this PC''s hardware" on this page.' }
            }
        }
        # ---- Inf2Cat, up to $Jobs runs at the same time; then the folders whose isolated run failed, whole
        $pending = @($todo | ForEach-Object { $_.Runs })
        while ($pending.Count) {
            $start = Get-Date
            foreach ($t in $todo) { if (@($t.Runs | Where-Object { $pending -contains $_ }).Count) { $t.Start = $start } }
            $est = Get-LaneTime @() @($pending | ForEach-Object { [double]$_.Est }) $Jobs
            $how = if ($pending.Count -eq 1) { '1 run' } else { '{0} runs, up to {1} at the same time' -f $pending.Count, [math]::Min($Jobs, $pending.Count) }
            Write-Info ('Inf2Cat: {0} - estimated time {1}' -f $how, (Format-Span ([timespan]::FromSeconds([math]::Ceiling($est)))))
            $out = @(Invoke-Inf2CatQueue $Inf2Cat $pending $os $Jobs)
            for ($k = 0; $k -lt $pending.Count; $k++) { $pending[$k].R = $out[$k] }
            $retry = @()
            foreach ($t in $todo) {
                $mine = @($t.Runs | Where-Object { $pending -contains $_ })
                foreach ($r in $mine) { Add-Log ("[$($r.Label)] Inf2Cat exit $($r.R.Code) after $(Format-Span $r.R.Time)`r`n" + ($r.R.Output | Out-String)) }
                if ($t.Staged -and @($mine | Where-Object { $_.R.Code -ne 0 }).Count) {
                    $f = @($mine | Where-Object { $_.R.Code -ne 0 })[0]
                    Write-Warn "$($t.Rel): Inf2Cat failed on the isolated INF file(s) - the whole folder is catalogued instead (slower)"
                    @($f.R.Output | Out-String -Stream | Where-Object { $_.Trim() } | Select-Object -Last 3) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
                    $cnt = @($t.Pkg.Infs).Count
                    $t.Staged = $false; $t.Check = $t.WithCat
                    $t.Runs = @([pscustomobject]@{ Dir = $t.Pkg.Dir; Label = $t.Rel; Infs = $cnt; Est = (3 + $cnt * $t.Mb / $rate); R = $null })
                    $retry += $t.Runs
                }
            }
            $pending = $retry
        }
        # learned speed for the next estimate (runs shorter than a few seconds say little)
        $work = 0.0; $secs = 0.0
        foreach ($t in $todo) { foreach ($r in $t.Runs) { if ($r.R -and $r.R.Code -eq 0 -and $r.R.Time.TotalSeconds -gt 8) { $work += $r.Infs * $t.Mb; $secs += $r.R.Time.TotalSeconds - 3 } } }
        if ($secs -gt 0) { Save-Inf2CatRate ($work / $secs) }

        # ---- the new catalogs, signed together
        $newCats = @()
        foreach ($t in $todo) {
            if (@($t.Runs | Where-Object { $_.R.Code -ne 0 }).Count) {
                $f = @($t.Runs | Where-Object { $_.R.Code -ne 0 })[0]
                Write-Err "Inf2Cat failed for $($t.Rel)"
                @($f.R.Output | Out-String -Stream | Where-Object { $_.Trim() } | Select-Object -Last 4) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
                if (($f.R.Output | Out-String) -match 'Signability test failed') { Write-Info 'Hint: delete inf2cat.exe.manifest next to Inf2Cat.exe and try again.' }
                $t.Ok = $false; continue
            }
            if ($t.Staged) {
                foreach ($r in $t.Runs) {
                    foreach ($c in @(Get-ChildItem -LiteralPath $r.Dir -Filter *.cat -File)) {
                        $dst = Join-Path $t.Pkg.Dir $c.Name
                        Copy-Item -LiteralPath $c.FullName -Destination $dst -Force
                        $t.Cats += $dst
                    }
                }
            } else {
                $t.Cats = @(Get-ChildItem -LiteralPath $t.Pkg.Dir -Filter *.cat -File | Where-Object { $_.LastWriteTime -ge $t.Start.AddSeconds(-2) } | ForEach-Object { $_.FullName })
            }
            if (-not $t.Cats.Count) { Write-Err "Inf2Cat wrote no catalog for $($t.Rel)"; $t.Ok = $false; continue }
            $newCats += $t.Cats
        }
        if ($newCats.Count) { Write-Host "signing $($newCats.Count) catalog(s)" -NoNewline }
        $failed = @(Invoke-SignCatalogs $newCats $Cert)
        if ($Script:Sync) { $Script:Sync.Status = '' }
        foreach ($t in $todo) {
            if (-not $t.Ok) { $res.Failed++; continue }
            $ok = $true
            foreach ($c in $t.Cats) { if ($failed -contains $c) { $ok = $false; Write-Err "Signing failed: $(Split-Path $c -Leaf)" } }
            if ($ok) {
                foreach ($inf in $t.Check) { foreach ($c in (Get-InfCatalogs $inf)) { if (-not (Test-SignedCatalog (Join-Path $t.Pkg.Dir $c) $inf)) { $ok = $false; Write-Err "Verification failed: $c" } } }
            }
            $runs = @($t.Runs)
            $longest = ($runs | ForEach-Object { $_.R.Time } | Sort-Object -Descending | Select-Object -First 1)
            $took = if ($runs.Count -eq 1) { "Inf2Cat took $(Format-Span $longest)" } else { "$($runs.Count) Inf2Cat runs, the longest took $(Format-Span $longest)" }
            if ($ok) { $res.Signed++; Write-Ok "$($t.Rel) signed and verified ($took)" } else { $res.Failed++ }
        }
    } finally {
        if (Test-Path -LiteralPath $stageBase) { Remove-Item -LiteralPath $stageBase -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($Script:Sync) { $Script:Sync.Status = '' }
    return $res
}
function Invoke-SignPackage([string]$Source, [string]$Name, $Password, [bool]$All, [bool]$OnlyThisPc = $false, [bool]$Isolate = $true, [int]$Jobs = 1) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Folder not found: $Source" }
    $Name = ($Name -replace '[^\w\.-]', '_').Trim('_')
    if (-not $Name) { $Name = 'Driver' }
    Write-Title "Re-sign modded drivers - $Name"
    $tools = Get-SignTools
    $Script:SignTool = $tools.SignTool
    $cert = Get-SigningCert $Password
    Write-Info ("Certificate: {0}  {1}  valid until {2:yyyy-MM-dd}" -f $cert.Subject, $cert.Thumbprint, $cert.NotAfter)
    $dest = Join-Path $Script:P.Signed $Name
    Write-Step "Copying $Source into the work folder (the original is not touched)"
    Reset-Dir $dest
    Copy-Tree $Source $dest
    $cer = Join-Path $Script:SignDir 'DriverSigning.cer'
    Write-Step 'Building new catalogs and signing them'
    $added = @(Add-TempTrust $cer)   # only while verifying - the ISO trusts it during setup
    if ($OnlyThisPc) { Write-Info 'Only the INF files for this PC''s hardware are kept - the ISO installs this driver on this PC only.' }
    Write-Info ('Inf2Cat: up to {0} run(s) at the same time{1}' -f $Jobs, $(if ($Isolate) { ', only the INF files that need a new catalog get one' } else { ', every folder that needs a new catalog is catalogued whole' }))
    try { $res = Invoke-SignFolder $dest $cert $tools.Inf2Cat $All $OnlyThisPc $Isolate $Jobs }
    finally { if ($added.Count) { Remove-TempTrust $cer $added } }
    $rec = [ordered]@{
        Name = $Name; Source = $Source; Path = $dest; InstallDir = "C:\Drivers\$Name"; When = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Signed = [int]$res.Signed; Failed = [int]$res.Failed; Untouched = [int]$res.Untouched; Thumbprint = $cert.Thumbprint
        OnlyThisPc = [bool]($OnlyThisPc -and $res.Removed -gt 0); Removed = [int]$res.Removed; Kept = @($res.Kept)
    }
    $Script:S.Signed = @(@($Script:S.Signed | Where-Object { $_ -and $_.Name -ne $Name }) + @($rec))
    Save-State
    if ($res.Failed -gt 0) { Write-Warn "$($res.Failed) package folder(s) failed - details in logs\engine.log. The rest is ready." }
    if ($res.Signed -eq 0 -and $res.Failed -eq 0) { Write-Warn 'Nothing needed a new signature (all catalogs were valid). Turn on "Re-sign every package" to sign anyway.' }
    Write-Ok "$Name is added to the ISO through `$OEM`$ and installs from $($rec.InstallDir) at the end of Windows setup."
}
function Remove-SignedPackage([string]$Name) {
    $x = @($Script:S.Signed | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
    if ($x -and $x.Path) { Remove-Item -LiteralPath $x.Path -Recurse -Force -ErrorAction SilentlyContinue }
    $Script:S.Signed = @($Script:S.Signed | Where-Object { $_ -and $_.Name -ne $Name })
    Save-State
}
function New-SetupCompleteDrivers($Packages, [bool]$Cleanup, $ExtraRoots = @()) {
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('@echo off')
    $l.Add('rem Generated by Win10-ISO-Updater: trusts the driver-signing certificate and installs the driver packages.')
    $l.Add('rem Called from SetupComplete.cmd and (optionally) from the specialize pass - it runs only once.')
    $l.Add('set "LOG=%windir%\Temp\SetupComplete-drivers.log"')
    $l.Add('set "DONE=%windir%\Setup\Scripts\drivers.done"')
    $l.Add('if exist "%DONE%" exit /b 0')
    $l.Add('set "CER=%SystemDrive%\Drivers\DriverSigning.cer"')
    $l.Add('echo %date% %time% trusting the driver-signing certificate>>"%LOG%"')
    $l.Add('if exist "%CER%" certutil -addstore -f Root "%CER%">>"%LOG%" 2>&1')
    $l.Add('if exist "%CER%" certutil -addstore -f TrustedPublisher "%CER%">>"%LOG%" 2>&1')
    foreach ($r in @($ExtraRoots)) {
        $l.Add("echo %date% %time% installing $r>>`"%LOG%`"")
        $l.Add("pnputil /add-driver `"%SystemDrive%\$r\*.inf`" /subdirs /install>>`"%LOG%`" 2>&1")
    }
    foreach ($x in @($Packages)) {
        $rel = ([string]$x.InstallDir) -replace '^[A-Za-z]:\\?', ''
        $l.Add("echo %date% %time% installing $($x.Name)>>`"%LOG%`"")
        $l.Add("pnputil /add-driver `"%SystemDrive%\$rel\*.inf`" /subdirs /install>>`"%LOG%`" 2>&1")
        if ($Cleanup) { $l.Add("rd /s /q `"%SystemDrive%\$rel`"") }
    }
    if ($Cleanup -and @($Packages).Count) { $l.Add('del /f /q "%CER%" >nul 2>&1') }
    $l.Add('echo %date% %time% done>"%DONE%"')
    $l.Add('echo %date% %time% done>>"%LOG%"')
    $l.Add('exit /b 0')
    return (($l -join "`r`n") + "`r`n")
}
# Rebuilds sources\$OEM$ on the media: your $OEM$ folder + the re-signed packages +
# SetupComplete-drivers.cmd (called from SetupComplete.cmd).
function Sync-Oem {
    $srcDir = Join-Path $Script:P.Media 'sources'
    if (-not (Test-Path -LiteralPath $srcDir)) { return }
    $oem = Join-Path $srcDir '$OEM$'
    $S = $Script:S
    $signed = @($S.Signed | Where-Object { $_ -and $_.Path -and (Test-Path -LiteralPath $_.Path) })
    $user = $null
    if ($S.Oem -and $S.Oem.Source -and (Test-Path -LiteralPath $S.Oem.Source)) { $user = [string]$S.Oem.Source }
    elseif ($S.Oem -and $S.Oem.Source) { Write-Warn "Your `$OEM`$ folder is gone: $($S.Oem.Source)" }
    $roots = @()
    if ($user -and $Script:Cfg.InstallOemDrivers) { $roots = @(Get-OemDriverRoots $user $signed) }
    if (-not $user -and $signed.Count -eq 0) {
        if ($S.OemSynced) {
            Remove-Item -LiteralPath $oem -Recurse -Force -ErrorAction SilentlyContinue
            $S.OemSynced = $false; Save-State
            Write-Info "`$OEM`$ removed from the media."
        }
        return
    }
    Write-Step "Updating sources\`$OEM`$ on the media"
    if (Test-Path -LiteralPath $oem) { Remove-Item -LiteralPath $oem -Recurse -Force }
    if ($user) { Copy-Tree $user $oem; Write-Sub "your `$OEM`$ folder ($user)" }
    else { New-Item -ItemType Directory -Force -Path $oem | Out-Null }
    if ($signed.Count -gt 0 -or $roots.Count -gt 0) {
        $cer = Join-Path $Script:SignDir 'DriverSigning.cer'
        if ($signed.Count -gt 0 -and -not (Test-Path -LiteralPath $cer)) { throw "DriverSigning.cer is missing from $($Script:SignDir) - sign the package again." }
        $one = Join-Path $oem '$1'
        foreach ($x in $signed) {
            $rel = ([string]$x.InstallDir) -replace '^[A-Za-z]:\\?', ''
            Copy-Tree $x.Path (Join-Path $one $rel)
            Write-Sub "$($x.Name) -> $($x.InstallDir)"
        }
        if (Test-Path -LiteralPath $cer) {
            New-Item -ItemType Directory -Force -Path (Join-Path $one 'Drivers') | Out-Null
            Copy-Item -LiteralPath $cer -Destination (Join-Path $one 'Drivers\DriverSigning.cer') -Force
        }
        foreach ($r in $roots) { Write-Sub "your drivers in C:\$r are installed with pnputil" }
        $scDir = Join-Path $oem '$$\Setup\Scripts'
        New-Item -ItemType Directory -Force -Path $scDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $scDir 'SetupComplete-drivers.cmd'), (New-SetupCompleteDrivers $signed ([bool]$Script:Cfg.SignCleanup) $roots), [Text.Encoding]::ASCII)
        $main = Join-Path $scDir 'SetupComplete.cmd'
        $call = 'call "%~dp0SetupComplete-drivers.cmd"'
        if (Test-Path -LiteralPath $main) {
            $lines = @([IO.File]::ReadAllLines($main))
            if (-not (($lines -join "`n") -match 'SetupComplete-drivers\.cmd')) {
                $at = if ($lines.Count -gt 0 -and $lines[0] -match '^\s*@?echo\s+off') { 1 } else { 0 }
                $new = New-Object System.Collections.Generic.List[string]
                for ($i = 0; $i -lt $lines.Count; $i++) { if ($i -eq $at) { $new.Add($call) }; $new.Add($lines[$i]) }
                if ($at -ge $lines.Count) { $new.Add($call) }
                [IO.File]::WriteAllText($main, (($new -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
                Write-Sub 'your SetupComplete.cmd now calls SetupComplete-drivers.cmd first'
            }
        } else {
            [IO.File]::WriteAllText($main, "@echo off`r`n$call`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
        }
        Write-Sub 'SetupComplete-drivers.cmd: trust certificate + pnputil /add-driver /install'
    }
    $S.OemSynced = $true
    Save-State
}
function Set-OemFolder([string]$Dir) {
    if ($Dir) {
        $d = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\')
        if ((Split-Path $d -Leaf) -ne '$OEM$' -and (Test-Path -LiteralPath (Join-Path $d '$OEM$'))) { $d = Join-Path $d '$OEM$' }
        if ((Split-Path $d -Leaf) -ne '$OEM$') { Write-Warn "This folder is not named `$OEM`$ - its contents are copied to sources\`$OEM`$ anyway." }
        $Script:S.Oem = [ordered]@{ Source = $d; Added = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
        Write-Ok "`$OEM`$ folder set: $d (copied into the media when the ISO is built)"
    } else {
        $Script:S.Oem = $null
        Write-Ok "`$OEM`$ folder removed (taken out of the media at the next build)."
    }
    Save-State
}
#endregion
