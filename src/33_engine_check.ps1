
#region ---------------------------------------------------------------- install check: helpers
$Script:UnattendNs = 'urn:schemas-microsoft-com:unattend'
$Script:WcmNs      = 'http://schemas.microsoft.com/WMIConfig/2002/State'
# Generic install keys (they pick an edition, they don't activate)
$Script:GenericKeys = @{
    'YTMG3-N6DKC-DKB77-7M9GQ-8MKC8' = 'Core'; '4CPRK-NM3K3-X6XXQ-RXX86-WXCHW' = 'CoreN'; 'BT79Q-G7N6G-PGBYW-4YWX6-6F4BT' = 'CoreSingleLanguage'
    'VK7JG-NPHTM-C97JM-9MPGT-3V66T' = 'Professional'; '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT' = 'ProfessionalN'
    'DXG7C-N36C4-C4HTG-X4T3X-2YV77' = 'ProfessionalWorkstation'; 'YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY' = 'Education'
    'NPPR9-FWDCX-D2C8J-H872K-2YT43' = 'Enterprise'
}
$Script:InstallerRx = '(?i)\b(pnputil|drvload|dpinst|devcon)\b|/add-driver'

function Add-Finding([string]$Level, [string]$Area, [string]$Text, [string]$Fix = '', [string]$FixText = '') {
    $Script:Findings.Add([pscustomobject]@{ Level = $Level; Area = $Area; Finding = $Text; Fix = $Fix; FixText = $FixText })
}
function Get-UnattendDoc([string]$File) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($File)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('u', $Script:UnattendNs)
    $ns.AddNamespace('wcm', $Script:WcmNs)
    return @{ Doc = $doc; Ns = $ns }
}
function Get-XNodes($X, [string]$XPath) { return @($X.Doc.SelectNodes($XPath, $X.Ns)) }
function Get-XText($X, $Node, [string]$Child) {
    $n = $Node.SelectSingleNode($Child, $X.Ns)
    if ($n) { return $n.InnerText.Trim() }
    return ''
}
function Get-XPass($Node) {
    $p = $Node
    while ($p -and $p.LocalName -ne 'settings') { $p = $p.ParentNode }
    if ($p) { return [string]$p.GetAttribute('pass') }
    return ''
}
# Editions in the ISO that will be built (index = position in the new install.wim)
function Get-FinalEditions {
    $wim = Join-Path $Script:P.Media 'sources\install.wim'
    if ($Script:S.Serviced -and (Test-Path -LiteralPath $wim)) {
        try { return @(Get-ImageList $wim) } catch { }
    }
    $imgs = @($Script:S.Images)
    $sel = @($Script:S.Selected)
    $keep = if ($Script:Cfg.KeepOnlySelected -and $sel.Count -gt 0) { @($imgs | Where-Object { $sel -contains [int]$_.Index }) } else { $imgs }
    $n = 0
    return @(foreach ($i in $keep) { $n++; [ordered]@{ Index = $n; Name = $i.Name; Edition = $i.Edition; Arch = $i.Arch; Langs = $i.Langs; Size = $i.Size } })
}
function Test-FirmwareOemKey {
    if ($null -eq $Script:OemKeyHere) {
        $Script:OemKeyHere = $false
        try { $Script:OemKeyHere = [bool]((Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey) } catch { }
    }
    return $Script:OemKeyHere
}
# What will be inside sources\$OEM$ once the ISO is built (your folder + generated files)
function Get-OemDriverRoots([string]$OemDir, $Signed) {
    $one = Join-Path $OemDir '$1'
    if (-not (Test-Path -LiteralPath $one)) { return @() }
    $skip = @(foreach ($x in @($Signed)) { (([string]$x.InstallDir) -replace '^[A-Za-z]:\\?', '').ToLower() })
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $one -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue)) {
        $rel = $f.DirectoryName.Substring($one.Length).TrimStart('\', '/')
        $seg = @($rel -split '[\\/]' | Where-Object { $_ })
        $root = if ($seg.Count -ge 2) { $seg[0] + '\' + $seg[1] } elseif ($seg.Count -eq 1) { $seg[0] } else { '' }
        if ($root -and $skip -notcontains $root.ToLower() -and -not $roots.Contains($root)) { $roots.Add($root) }
    }
    return @($roots)
}
function Get-OemContext {
    $S = $Script:S
    $user = $null
    if ($S.Oem -and $S.Oem.Source -and (Test-Path -LiteralPath $S.Oem.Source)) { $user = [string]$S.Oem.Source }
    $signed = @($S.Signed | Where-Object { $_ -and $_.Path -and (Test-Path -LiteralPath $_.Path) })
    $roots = @()
    if ($user -and $Script:Cfg.InstallOemDrivers) { $roots = @(Get-OemDriverRoots $user $signed) }
    $script = ($signed.Count -gt 0 -or $roots.Count -gt 0)
    $gen = @{}
    if ($script) {
        $gen['$$\setup\scripts\setupcomplete-drivers.cmd'] = $true
        $gen['$$\setup\scripts\setupcomplete.cmd'] = $true
        $gen['$1\drivers\driversigning.cer'] = $true
    }
    return @{
        User = $user; Signed = $signed; Roots = $roots; Generated = $gen; DriverScript = $script; Fallback = $false
        PkgDirs = @(foreach ($x in $signed) { '$1\' + (([string]$x.InstallDir) -replace '^[A-Za-z]:\\?', '') })
        Installers = New-Object System.Collections.Generic.List[object]; OemInfDirs = @()
    }
}
function Test-OemRel($Ctx, [string]$Rel) {
    $r = $Rel.TrimStart('\')
    if ($Ctx.Generated.ContainsKey($r.ToLower())) { return $true }
    foreach ($d in $Ctx.PkgDirs) { if ($r -ieq $d -or $r.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    if ($Ctx.User) { return (Test-Path -LiteralPath (Join-Path $Ctx.User $r)) }
    return $false
}
function Test-BuiltinRel([string]$Rel) {
    return ($Rel -match '(?i)^\$\$\\(System32|SysWOW64|SystemApps|WinSxS|Microsoft\.NET)\\' -or $Rel -match '(?i)^\$\$\\[^\\]+\.exe$' -or
            $Rel -match '(?i)^\$1\\(Program Files|ProgramData|Users)\b')
}
# File paths used in a command / script line, mapped into $OEM$ ($1 = C:\, $$ = C:\Windows)
function Get-CommandRefs([string]$Text, [string]$ScriptDirRel, [switch]$Dirs) {
    $t = $Text
    if ($ScriptDirRel) { $t = [regex]::Replace($t, '(?i)%~dp0\\?', '%OEMDIR%\') }
    $head = '(%SystemDrive%|%WINDIR%|%SystemRoot%|%OEMDIR%|(?<![\w%])[A-Za-z]:)'
    $ext = if ($Dirs) { '' } else { '\.(?:cmd|bat|ps1|exe|reg|vbs|msi|inf|xml|cer|ini|json|txt|zip)' }
    $rxQ = '"' + $head + '\\([^"]*?' + $ext + ')"'
    $rxU = '(?<!")' + $head + '\\([^\s"<>|&%:]*' + $(if ($Dirs) { '' } else { '?' }) + $ext + ')' + $(if ($Dirs) { '' } else { '(?=$|[\s"''),;])' })
    $out = @()
    $seen = @{}
    foreach ($rx in @($rxQ, $rxU)) {
        foreach ($m in [regex]::Matches($t, $rx)) {
            $h = $m.Groups[1].Value; $rest = $m.Groups[2].Value.TrimEnd('\')
            $raw = $h + '\' + $rest
            if ($seen.ContainsKey($raw.ToLower())) { continue }
            $seen[$raw.ToLower()] = $true
            $rel = $null; $kind = 'oem'
            if ($h -ieq '%OEMDIR%') { $rel = $ScriptDirRel + '\' + $rest; $raw = '%~dp0' + $rest }
            elseif ($h -ieq '%SystemDrive%' -or $h -ieq 'C:') { if ($rest -match '(?i)^Windows\\(.+)$') { $rel = '$$\' + $Matches[1] } elseif ($rest -ieq 'Windows') { $rel = '$$' } else { $rel = '$1\' + $rest } }
            elseif ($h -ieq '%WINDIR%' -or $h -ieq '%SystemRoot%') { $rel = '$$\' + $rest }
            elseif ($h -ieq 'X:') { $kind = 'winpe' }
            else { $kind = 'drive' }
            $out += [pscustomobject]@{ Raw = $raw; Rel = $rel; Kind = $kind }
        }
    }
    return $out
}
# Catalog state of one INF: ok | own | unchecked | mismatch | untrusted | catalog-missing | no-catalog | unsigned | other-cert
function Get-DriverSignState([string]$Inf, [string]$OwnThumb) {
    $cats = @(Get-InfCatalogs $Inf)
    if ($cats.Count -eq 0) { return 'no-catalog' }
    $dir = Split-Path -Parent $Inf
    $own = $false
    foreach ($c in $cats) {
        $cp = Join-Path $dir $c
        if (-not (Test-Path -LiteralPath $cp)) { return 'catalog-missing' }
        $sig = $null
        try { $sig = Get-AuthenticodeSignature -LiteralPath $cp } catch { }
        if ($sig -and $sig.SignerCertificate -and $sig.SignerCertificate.Subject -eq $Script:CertSubject) {
            if (-not $OwnThumb -or $sig.SignerCertificate.Thumbprint -ne $OwnThumb) { return 'other-cert' }
            $own = $true
        }
        if ($Script:SignTool) {
            $v = Get-VerifyState $cp $Inf
            if ($v -ne 'ok') { return $v }
        } elseif (-not $own -and (-not $sig -or $sig.Status -ne 'Valid')) { return 'unsigned' }
    }
    if ($own) { return 'own' }
    if ($Script:SignTool) { return 'ok' }
    return 'unchecked'
}
$Script:BadSign = @('mismatch', 'untrusted', 'catalog-missing', 'no-catalog', 'unsigned', 'other-cert')
function Get-SignText([string]$State) {
    switch ($State) {
        'mismatch'        { 'the INF was edited after signing, so its catalog no longer matches' }
        'untrusted'       { 'its catalog is signed with a certificate Windows does not trust (NVCleanstall''s own, for example)' }
        'catalog-missing' { 'its .cat catalog file is missing' }
        'no-catalog'      { 'the INF names no catalog file, so it is unsigned' }
        'unsigned'        { 'its catalog is not validly signed' }
        'other-cert'      { 'signed with a different "Custom Driver Signing" certificate than yours' }
        default           { $State }
    }
}
#endregion

#region ---------------------------------------------------------------- install check: scripts in $OEM$
function Test-SetupScript($Ctx, [string]$Rel, [string]$Why, [hashtable]$Seen, [bool]$Hidden, [int]$Depth = 0) {
    $key = $Rel.ToLower()
    if ($Seen.ContainsKey($key)) { return }
    $Seen[$key] = $true
    if (-not $Ctx.User) { return }
    $full = Join-Path $Ctx.User $Rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
    $bytes = [IO.File]::ReadAllBytes($full)
    $name = '{0} ({1})' -f $Rel, $Why
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        Add-Finding 'Error' 'Scripts' ('{0} is saved as UTF-16 - cmd.exe cannot run it. Save it as ANSI or UTF-8 without BOM.' -f $name) '' 'Re-save the file (Notepad: Save as > Encoding ANSI)'
        return
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Add-Finding 'Warning' 'Scripts' ('{0} starts with a UTF-8 BOM - cmd.exe misreads its first line (for example @echo off).' -f $name) '' 'Re-save it as ANSI / UTF-8 without BOM'
    }
    $text = [Text.Encoding]::Default.GetString($bytes)
    if ($text.Contains("`n") -and -not $text.Contains("`r`n")) {
        Add-Finding 'Warning' 'Scripts' ('{0} has Unix (LF) line endings - labels and goto can break in cmd.exe.' -f $name) '' 'Re-save it with Windows (CRLF) line endings'
    }
    $dir = Split-Path $Rel -Parent
    $no = 0
    $waits = @(); $restarts = @(); $drives = @(); $missing = @(); $calls = @()
    foreach ($line in ($text -split "`r?`n")) {
        $no++
        $l = $line.Trim()
        if (-not $l -or $l -match '^(?i)(@?rem\b|::)') { continue }
        if ($Hidden -and $l -match '(?i)(^|[&|(]\s*)@?(pause\b|set\s+/p\b|choice\b(?!.*\s/t))') { $waits += $no }
        if ($Hidden -and $l -match '(?i)\bshutdown(\.exe)?\s+[/-][rsg]\b') { $restarts += $no }
        if ($l -match $Script:InstallerRx) { $Ctx.Installers.Add([pscustomobject]@{ Text = $l; Dir = $dir }) }
        foreach ($r in @(Get-CommandRefs $l $dir)) {
            if ($r.Kind -eq 'drive') { if ($drives -notcontains $r.Raw) { $drives += $r.Raw }; continue }
            if (-not $r.Rel -or $r.Rel -match '\*' -or (Test-BuiltinRel $r.Rel)) { continue }
            if (-not (Test-OemRel $Ctx $r.Rel)) { if ($missing -notcontains $r.Raw) { $missing += $r.Raw } }
            elseif ($Depth -lt 2 -and $r.Rel -match '(?i)\.(cmd|bat)$' -and $calls -notcontains $r.Rel) { $calls += $r.Rel }
        }
    }
    # one finding per script and problem, not one per line
    $lines = { param($l) $t = (@($l | Select-Object -First 8) -join ', '); if (@($l).Count -gt 8) { $t += ', ...' }; $t }
    if ($waits.Count) {
        Add-Finding 'Warning' 'Scripts' ('{0} waits for a key on {1} line(s) (line {2}) - pause / set /p / choice. It runs hidden during setup, so setup hangs there.' -f $name, $waits.Count, (& $lines $waits)) '' 'Remove the prompts, or run this script from FirstLogonCommands (visible) instead'
    }
    if ($restarts.Count) {
        Add-Finding 'Warning' 'Scripts' ('{0} restarts the PC (line {1}) - that can cut setup short.' -f $name, (& $lines $restarts)) '' 'Restart from FirstLogonCommands instead'
    }
    if ($drives.Count) {
        Add-Finding 'Warning' 'Scripts' ('{0} uses fixed drive letters ({1}) - USB stick and disk letters differ between PCs.' -f $name, (& $lines $drives)) '' 'Use %SystemDrive%, %~dp0 or search for the drive'
    }
    if ($missing.Count) {
        Add-Finding 'Warning' 'Scripts' ('{0} uses files that are not in your $OEM$: {1}' -f $name, (& $lines $missing)) '' 'Add the files to $OEM$ or fix the paths'
    }
    foreach ($c in $calls) { Test-SetupScript $Ctx $c ('called by ' + (Split-Path $Rel -Leaf)) $Seen $Hidden ($Depth + 1) }
}
#endregion

#region ---------------------------------------------------------------- install check: $OEM$, drivers, signed packages
function Test-OemFolder($Ctx, [string]$OwnThumb, [string]$Arch) {
    $u = $Ctx.User
    $S = $Script:S
    if ($S.Oem -and $S.Oem.Source -and -not $u) { Add-Finding 'Error' '$OEM$' ('Your $OEM$ folder is gone: {0}' -f $S.Oem.Source) '' 'Choose it again on page 6' }
    if (-not $u) {
        if ($Ctx.DriverScript) { Add-Finding 'OK' '$OEM$' 'The ISO gets a $OEM$ folder with your signed driver package(s) and SetupComplete-drivers.cmd.' }
        else { Add-Finding 'Info' '$OEM$' 'No $OEM$ folder - nothing extra is copied to C:\.' }
        return
    }
    foreach ($i in @(Get-ChildItem -LiteralPath $u -Force -ErrorAction SilentlyContinue)) {
        if ($i.PSIsContainer -and @('$$', '$1') -notcontains $i.Name) {
            Add-Finding 'Warning' '$OEM$' ('Folder "{0}" at the top of $OEM$ is ignored by Windows 10 Setup - only $$ (C:\Windows) and $1 (C:\) are copied.' -f $i.Name) '' 'Move its contents into $1 or $$'
        } elseif (-not $i.PSIsContainer) {
            Add-Finding 'Warning' '$OEM$' ('File "{0}" at the top of $OEM$ is ignored - put it in $1 or $$.' -f $i.Name)
        }
    }
    $files = @(Get-ChildItem -LiteralPath $u -Recurse -File -Force -ErrorAction SilentlyContinue)
    $rels = @{}
    foreach ($f in $files) { $rels[$f.FullName.Substring($u.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('/', '\')] = $f }
    $total = ($files | Measure-Object -Property Length -Sum).Sum
    Add-Finding 'Info' '$OEM$' ('{0}: {1} files, {2}' -f $u, $files.Count, (Format-Size ([double]$total)))

    foreach ($r in @($rels.Keys)) {
        $leaf = Split-Path $r -Leaf
        if ($r -match '(?i)^\$1\\(auto)?unattend\.xml$') {
            $fix = ''; $ft = ''
            if (-not $S.Unattend -or [string]$S.Unattend.Source -ne $rels[$r].FullName) { $fix = 'use-oem-unattend=' + $rels[$r].FullName; $ft = 'Use it as the ISO''s answer file' }
            Add-Finding 'Warning' '$OEM$' ('{0} is only copied to C:\ - Setup never reads it from there. The answer file must be in the ISO root (page 6).' -f $r) $fix $ft
        }
        if ($r -match '(?i)^\$\$\\Panther\\(auto)?unattend\.xml$') {
            Add-Finding 'Warning' '$OEM$' ('{0} lands in C:\Windows\Panther, where Setup looks for its answer file in later passes - it can override your autounattend.xml.' -f $r) '' 'Remove it from $OEM$'
        }
        if ($leaf -ieq 'SetupComplete.cmd' -and $r -notmatch '(?i)^\$\$\\Setup\\Scripts\\SetupComplete\.cmd$') {
            Add-Finding 'Error' '$OEM$' ('{0} is in the wrong place - Windows only runs $$\Setup\Scripts\SetupComplete.cmd.' -f $r) '' 'Move it to $OEM$\$$\Setup\Scripts'
        }
        if ($Script:Cfg.SplitFat32 -and $rels[$r].Length -ge 4GB) {
            Add-Finding 'Warning' '$OEM$' ('{0} is larger than 4 GB - it does not fit on a FAT32 USB stick.' -f $r)
        }
        if (('C:\' + ($r -replace '^\$1\\', '')).Length -gt 240) {
            Add-Finding 'Warning' '$OEM$' ('Path too long for Setup to copy reliably (over 240 characters): {0}' -f (Limit-Text $r 90))
        }
    }

    # scripts that run during setup
    $seen = @{}
    $sc = '$$\Setup\Scripts\SetupComplete.cmd'
    if ($rels.ContainsKey($sc)) { Test-SetupScript $Ctx $sc 'runs at the end of setup' $seen $true }
    foreach ($r in @($rels.Keys | Where-Object { $_ -match '(?i)\.(cmd|bat)$' -and -not $seen.ContainsKey($_.ToLower()) })) {
        # other scripts: only collect driver-install lines for the coverage check
        try {
            foreach ($l in [IO.File]::ReadAllLines($rels[$r].FullName)) { if ($l -match $Script:InstallerRx) { $Ctx.Installers.Add([pscustomobject]@{ Text = $l.Trim(); Dir = (Split-Path $r -Parent) }) } }
        } catch { }
    }

    # drivers inside $OEM$\$1
    $one = Join-Path $u '$1'
    if (-not (Test-Path -LiteralPath $one)) { return }
    $infs = @(Get-ChildItem -LiteralPath $one -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | Select-Object -First 400)
    if ($infs.Count -eq 0) { return }
    $byDir = @{}
    $n = 0
    foreach ($f in $infs) {
        $n++
        Write-Host ('checking $OEM$ drivers {0}/{1}' -f $n, $infs.Count) -NoNewline
        $rel = '$1\' + $f.DirectoryName.Substring($one.Length).TrimStart('\', '/').Replace('/', '\')
        if (-not $byDir.ContainsKey($rel)) { $byDir[$rel] = @{ Full = $f.DirectoryName; Bad = @(); Arch = @(); N = 0 } }
        $e = $byDir[$rel]
        $e.N++
        $info = Get-InfInfo $f.FullName
        if ($Arch -and -not (Test-DriverArch $info.Arch $Arch)) { $e.Arch += $f.Name }
        $st = Get-DriverSignState $f.FullName $OwnThumb
        if ($Script:BadSign -contains $st) { $e.Bad += ('{0} ({1})' -f $f.Name, (Get-SignText $st)) }
    }
    $Ctx.OemInfDirs = @($byDir.Keys)
    $okDirs = 0
    foreach ($rel in @($byDir.Keys | Sort-Object)) {
        $e = $byDir[$rel]
        if ($e.Arch.Count) { Add-Finding 'Warning' 'Drivers in $OEM$' ('{0}: {1} not built for {2} - Windows skips it.' -f $rel, ($e.Arch -join ', '), $Arch) }
        if ($e.Bad.Count -eq 0) { $okDirs++; continue }
        $overlay = @($Ctx.PkgDirs | Where-Object { $rel -ieq $_ -or $rel.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($overlay.Count) {
            Add-Finding 'OK' 'Drivers in $OEM$' ('{0}: the unsigned files are replaced by your signed copy at build time.' -f $rel)
            continue
        }
        $from = @($Ctx.Signed | Where-Object { $e.Full -ieq [string]$_.Source -or $e.Full.StartsWith(([string]$_.Source).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($from.Count) {
            Add-Finding 'Warning' 'Drivers in $OEM$' ('{0}: the unsigned original stays in the ISO - your signed copy installs from {1}. Installing the original fails.' -f $rel, $from[0].InstallDir) '' ('Remove it from $OEM$ or name the signed package "{0}"' -f (Split-Path $rel -Leaf))
            continue
        }
        Add-Finding 'Error' 'Drivers in $OEM$' ('{0}: Windows will refuse it - {1}.' -f $rel, (($e.Bad | Select-Object -First 3) -join '; ')) '' 'Sign this folder on page 5 (it is then copied and installed automatically)'
    }
    if ($okDirs) { Add-Finding 'OK' 'Drivers in $OEM$' ('{0} driver folder(s) in $OEM$ have valid signatures.' -f $okDirs) }
    if ($Script:Sync) { $Script:Sync.Status = '' }
}
function Test-SlipstreamDrivers([string]$OwnThumb) {
    $d = @($Script:S.Drivers)
    if ($d.Count -eq 0) { return }
    $bad = @(); $nums = @()
    for ($i = 0; $i -lt $d.Count; $i++) {
        Write-Host ('checking slipstreamed drivers {0}/{1}' -f ($i + 1), $d.Count) -NoNewline
        $inf = Join-Path (Join-Path $Script:P.DrvSel $d[$i].Folder) $d[$i].Inf
        if (-not (Test-Path -LiteralPath $inf)) { $bad += ('{0} (file missing)' -f $d[$i].Inf); $nums += ($i + 1); continue }
        $st = Get-DriverSignState $inf $OwnThumb
        if ($Script:BadSign -contains $st -or $st -eq 'own') {
            $why = if ($st -eq 'own') { 'signed with your certificate - only trusted after SetupComplete runs' } else { Get-SignText $st }
            $bad += ('{0} {1} {2} ({3})' -f $d[$i].Class, $d[$i].Provider, $d[$i].Inf, $why); $nums += ($i + 1)
        }
    }
    if ($Script:Sync) { $Script:Sync.Status = '' }
    if ($bad.Count -eq 0) { Add-Finding 'OK' 'Drivers' ('{0} slipstreamed driver package(s) have valid catalogs.' -f $d.Count); return }
    $lvl = if ($Script:Cfg.ForceUnsigned) { 'Warning' } else { 'Error' }
    $what = if ($Script:Cfg.ForceUnsigned) { 'DISM adds them with /ForceUnsigned, but 64-bit Windows will not load them' } else { 'DISM refuses them, so these devices stay without a driver' }
    Add-Finding $lvl 'Drivers' ('{0} slipstreamed driver(s) are not validly signed - {1}: {2}' -f $bad.Count, $what, (($bad | Select-Object -First 5) -join '; ')) ('drop-bad-drivers=' + ($nums -join ',')) 'Remove them from the slipstream list (sign modded ones on page 5)'
}
function Test-SignedPackages([string]$OwnThumb) {
    $all = @($Script:S.Signed | Where-Object { $_ })
    if ($all.Count -eq 0) { return }
    $cer = Join-Path $Script:SignDir 'DriverSigning.cer'
    if (-not (Test-Path -LiteralPath $cer)) { Add-Finding 'Error' 'Signed drivers' 'DriverSigning.cer is missing from the signing folder - the ISO cannot trust your packages.' '' 'Sign the package(s) again on page 5'; return }
    try {
        $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $cer
        if ($c.NotAfter -lt (Get-Date).AddDays(30)) { Add-Finding 'Warning' 'Signed drivers' ('Your signing certificate expires on {0:yyyy-MM-dd}.' -f $c.NotAfter) }
    } catch { }
    foreach ($x in $all) {
        if (-not $x.Path -or -not (Test-Path -LiteralPath $x.Path)) { Add-Finding 'Error' 'Signed drivers' ('{0}: the signed copy is gone from the work folder.' -f $x.Name) '' 'Sign it again on page 5'; continue }
        if ($OwnThumb -and $x.Thumbprint -and $x.Thumbprint -ne $OwnThumb) { Add-Finding 'Error' 'Signed drivers' ('{0} was signed with another certificate than the one in the signing folder.' -f $x.Name) '' 'Sign it again on page 5'; continue }
        if ([int]$x.Failed -gt 0) { Add-Finding 'Warning' 'Signed drivers' ('{0}: {1} folder(s) failed to sign - those parts will not install.' -f $x.Name, $x.Failed) '' 'See logs\engine.log, then sign again' }
        else { Add-Finding 'OK' 'Signed drivers' ('{0}: {1} package folder(s) signed with your certificate, installs from {2}.' -f $x.Name, $x.Signed, $x.InstallDir) }
    }
}
function Test-DriverCoverage($Ctx) {
    if (-not $Ctx.User -or -not $Ctx.OemInfDirs) { return }
    $cover = @()
    foreach ($i in $Ctx.Installers) {
        foreach ($r in @(Get-CommandRefs $i.Text $i.Dir -Dirs)) {
            if (-not $r.Rel) { continue }
            $p = ($r.Rel -replace '\\\*(\.inf)?$', '' -replace '\\[^\\]*\.inf$', '').TrimEnd('\')
            $cover += [pscustomobject]@{ Path = $p; Sub = ($i.Text -match '(?i)/subdirs|/recurse') }
        }
    }
    foreach ($r in $Ctx.Roots) { $cover += [pscustomobject]@{ Path = '$1\' + $r; Sub = $true } }
    foreach ($d in $Ctx.PkgDirs) { $cover += [pscustomobject]@{ Path = $d; Sub = $true } }
    $loose = @()
    foreach ($dir in $Ctx.OemInfDirs) {
        $hit = @($cover | Where-Object { $dir -ieq $_.Path -or ($_.Sub -and $dir.StartsWith($_.Path + '\', [StringComparison]::OrdinalIgnoreCase)) })
        if ($hit.Count -eq 0) { $loose += $dir }
    }
    if ($loose.Count -eq 0) { Add-Finding 'OK' 'Drivers in $OEM$' 'Every driver folder in $OEM$ is installed by a command (pnputil / dism / your signed package).'; return }
    $show = @($loose | ForEach-Object { 'C:\' + ($_ -replace '^\$1\\', '') } | Select-Object -First 6)
    Add-Finding 'Warning' 'Drivers in $OEM$' ('{0} driver folder(s) are only copied to C:\ - nothing installs them: {1}' -f $loose.Count, ($show -join ', ')) 'oem-drivers' 'Install them with pnputil from SetupComplete-drivers.cmd'
}
#endregion
