
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
# ok | mismatch | catalog-missing | no-catalog-directive | unknown (no signtool to check)
function Get-InfState([string]$Inf) {
    $cats = @(Get-InfCatalogs $Inf)
    if ($cats.Count -eq 0) { return 'no-catalog-directive' }
    $dir = Split-Path -Parent $Inf
    foreach ($c in $cats) {
        $cp = Join-Path $dir $c
        if (-not (Test-Path -LiteralPath $cp)) { return 'catalog-missing' }
        if ($Script:SignTool) {
            & $Script:SignTool verify /pa /c $cp $Inf 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { return 'mismatch' }
        }
    }
    if ($Script:SignTool) { return 'ok' }
    return 'unknown'
}
function Invoke-SignCatalog([string]$CatFile, $Cert) {
    if ($Script:SignTool) {
        $o = & $Script:SignTool sign /fd SHA256 /sha1 $Cert.Thumbprint /s My $CatFile 2>&1
        Add-Log ($o | Out-String)
        return ($LASTEXITCODE -eq 0)
    }
    $r = Set-AuthenticodeSignature -FilePath $CatFile -Certificate $Cert -HashAlgorithm SHA256
    return ($null -ne $r.SignerCertificate)
}
function Test-SignedCatalog([string]$CatFile, [string]$Inf) {
    if ($Script:SignTool) {
        & $Script:SignTool verify /pa /c $CatFile $Inf 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    return ((Get-AuthenticodeSignature -FilePath $CatFile).Status -eq 'Valid')
}
function Invoke-SignFolder([string]$Root, $Cert, [string]$Inf2Cat, [bool]$All) {
    $os = if ($Script:S.Family -and $Script:S.Family.Arch -eq 'x86') { '10_X86' } else { '10_X64' }
    $pkgs = @(Get-InfFolders $Root)
    $states = @{}
    $n = 0
    foreach ($p in $pkgs) { foreach ($inf in $p.Infs) { $n++; Write-Host "checking INF $n" -NoNewline; $states[$inf] = Get-InfState $inf } }
    $bad = @($states.Keys | Where-Object { $states[$_] -in 'mismatch', 'catalog-missing', 'unknown' })
    Write-Info ("{0} INF file(s) in {1} folder(s) - {2} modified or without a valid catalog" -f @($states.Keys).Count, $pkgs.Count, $bad.Count)
    $res = [ordered]@{ Signed = 0; Failed = 0; Untouched = 0; Skipped = 0 }
    foreach ($p in $pkgs) {
        $rel = $p.Dir.Substring($Root.TrimEnd('\').Length).TrimStart('\'); if (-not $rel) { $rel = '.' }
        $withCat = @($p.Infs | Where-Object { $states[$_] -ne 'no-catalog-directive' })
        $need = @($p.Infs | Where-Object { $states[$_] -in 'mismatch', 'catalog-missing', 'unknown' })
        if ($withCat.Count -eq 0) { Write-Info "$rel : no CatalogFile= line in the INF - left as is"; $res.Skipped++; continue }
        if (-not $All -and $need.Count -eq 0) { $res.Untouched++; continue }
        Write-Sub $rel
        $start = Get-Date
        $o = & $Inf2Cat "/driver:$($p.Dir)" "/os:$os" /uselocaltime /verbose 2>&1
        $code = $LASTEXITCODE
        Add-Log ("[$rel] Inf2Cat exit $code`r`n" + ($o | Out-String))
        if ($code -ne 0) {
            Write-Err "Inf2Cat failed for $rel"
            @($o | Out-String -Stream | Where-Object { $_.Trim() } | Select-Object -Last 4) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
            if (($o | Out-String) -match 'Signability test failed') { Write-Info 'Hint: delete inf2cat.exe.manifest next to Inf2Cat.exe and try again.' }
            $res.Failed++
            continue
        }
        $cats = @(Get-ChildItem -LiteralPath $p.Dir -Filter *.cat -File | Where-Object { $_.LastWriteTime -ge $start.AddSeconds(-2) })
        $ok = $cats.Count -gt 0
        foreach ($c in $cats) { if (-not (Invoke-SignCatalog $c.FullName $Cert)) { $ok = $false; Write-Err "Signing failed: $($c.Name)" } }
        if ($ok) {
            foreach ($inf in $withCat) { foreach ($c in (Get-InfCatalogs $inf)) { if (-not (Test-SignedCatalog (Join-Path $p.Dir $c) $inf)) { $ok = $false; Write-Err "Verification failed: $c" } } }
        }
        if ($ok) { $res.Signed++; Write-Ok "$rel signed and verified" } else { $res.Failed++ }
    }
    if ($Script:Sync) { $Script:Sync.Status = '' }
    return $res
}
function Invoke-SignPackage([string]$Source, [string]$Name, $Password, [bool]$All) {
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
    try { $res = Invoke-SignFolder $dest $cert $tools.Inf2Cat $All }
    finally { if ($added.Count) { Remove-TempTrust $cer $added } }
    $rec = [ordered]@{
        Name = $Name; Source = $Source; Path = $dest; InstallDir = "C:\Drivers\$Name"; When = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Signed = [int]$res.Signed; Failed = [int]$res.Failed; Untouched = [int]$res.Untouched; Thumbprint = $cert.Thumbprint
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
