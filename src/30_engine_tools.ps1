
#region ---------------------------------------------------------------- processes with live output
function Push-ExeLine([string]$Line) {
    $t = $Line.Trim()
    if (-not $t -or $t -match '^[#=O\-\s]+$') { return }
    # progress bars (DISM "[====  45.0%  ]", curl "####  45.0%") drive the GUI progress bar
    $m = [regex]::Match($t, '(\d{1,3}(?:[\.,]\d+)?)\s*%')
    if ($m.Success -and ($t -replace '[\d\.,%\[\]=#\-\sO>]', '').Length -lt 3) {
        $v = 0.0
        if ($Script:Sync -and [double]::TryParse(($m.Groups[1].Value -replace ',', '.'), [Globalization.NumberStyles]::Float, $Script:Inv, [ref]$v)) {
            $Script:Sync.Pct = [math]::Min(100.0, $v)
        }
        return
    }
    $col = if ($t -match '^(Error|ERROR)') { 'Red' } elseif ($t -match '^(Warning|WARNING)') { 'Yellow' } else { 'DarkGray' }
    Write-Host "       $t" -ForegroundColor $col
}
function Invoke-Exe([string]$File, [string]$Arguments, [switch]$MergeErr) {
    Add-Log "EXEC $File $Arguments"
    $psi = New-Object Diagnostics.ProcessStartInfo
    if ($MergeErr) {
        $psi.FileName  = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c "' + (Q $File) + ' ' + $Arguments + ' 2>&1"'
    } else {
        $psi.FileName  = $File
        $psi.Arguments = $Arguments
        $psi.RedirectStandardError = $true
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $null
    if (-not $MergeErr) { $errTask = $p.StandardError.ReadToEndAsync() }
    $sr = $p.StandardOutput
    $sb = New-Object Text.StringBuilder
    $buf = New-Object char[] 2048
    while (($n = $sr.Read($buf, 0, $buf.Length)) -gt 0) {
        for ($i = 0; $i -lt $n; $i++) {
            $ch = $buf[$i]
            if ($ch -eq [char]13 -or $ch -eq [char]10) {
                if ($sb.Length -gt 0) { Push-ExeLine $sb.ToString(); [void]$sb.Clear() }
            } else { [void]$sb.Append($ch) }
        }
    }
    if ($sb.Length -gt 0) { Push-ExeLine $sb.ToString() }
    $p.WaitForExit()
    if ($errTask) {
        foreach ($l in ($errTask.Result -split "`r?`n")) { if ($l.Trim()) { Write-Host "       $($l.Trim())" -ForegroundColor DarkYellow } }
    }
    if ($Script:Sync) { $Script:Sync.Pct = -1 }
    return [int]$p.ExitCode
}
#endregion

# Runs a console tool and returns exit code + output. Windows PowerShell 5.1 turns redirected
# stderr lines into errors, and with ErrorActionPreference = Stop one line on stderr would end
# the whole job - so it is relaxed for this call only.
function Invoke-Native([string]$File, [string[]]$ArgList) {
    $ErrorActionPreference = 'Continue'
    $out = @(& $File @ArgList 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out; Text = ($out -join "`r`n") }
}
# ok | untrusted (signed, but by a certificate Windows does not trust) | mismatch (edited / not in the catalog)
function Get-VerifyState([string]$Cat, [string]$Inf) {
    $r = Invoke-Native $Script:SignTool @('verify', '/pa', '/c', $Cat, $Inf)
    if ($r.Code -eq 0) { return 'ok' }
    if ($r.Text -match '(?i)terminated in a root|not trusted|untrusted') { return 'untrusted' }
    return 'mismatch'
}
#endregion

#region ---------------------------------------------------------------- tools (oscdimg, Inf2Cat, signtool)
function Test-MicrosoftSigned([string]$Path) {
    $s = Get-AuthenticodeSignature -LiteralPath $Path
    return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'O=Microsoft Corporation')
}
function Get-Oscdimg {
    $osc = Find-Oscdimg
    if ($osc) { return $osc }
    # Same source and hashes as Microsoft's Make2023BootableMedia.ps1
    $arch = Get-HostArch
    $src = @{
        x64   = @('https://msdl.microsoft.com/download/symbols/oscdimg.exe/9F01AFB765000/oscdimg.exe', 'ABCD07318EBD8CDBE274B46C9DE78820DCA9709D558CDBC1F5D1730924264D07')
        arm64 = @('https://msdl.microsoft.com/download/symbols/oscdimg.exe/2267BF2C66000/oscdimg.exe', 'CDAE3649F6A6DE45F50A0B5FB5E2BBC098503B9EEFB1AE6A398FC955B434F579')
        x86   = @('https://msdl.microsoft.com/download/symbols/oscdimg.exe/CFBCC93A60000/oscdimg.exe', '85AC2DDD96239D037560E5336727F9A8BE2B902734B9DD88264DD7DB5612EFB9')
    }[$arch]
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    $part = Join-Path $ToolsDir 'oscdimg.exe.part'
    Write-Step "Downloading oscdimg.exe ($arch) from the Microsoft symbol server"
    try { Invoke-WebRequest -Uri $src[0] -OutFile $part -UseBasicParsing } catch { Write-Warn "Download failed: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $part) {
        if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -eq $src[1]) {
            Move-Item -LiteralPath $part -Destination (Join-Path $ToolsDir 'oscdimg.exe') -Force
            Write-Ok 'oscdimg.exe saved to the tools folder (SHA-256 verified)'
            return (Find-Oscdimg)
        }
        Remove-Item -LiteralPath $part -Force
        Write-Warn 'SHA-256 mismatch - file deleted.'
    }
    Write-Step 'Installing the Windows ADK Deployment Tools instead (a few minutes)'
    $adk = Join-Path $env:TEMP 'adksetup.exe'
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2289980' -OutFile $adk -UseBasicParsing
    if (-not (Test-MicrosoftSigned $adk)) { Remove-Item -LiteralPath $adk -Force; throw 'The ADK installer failed the Microsoft signature check.' }
    $code = Invoke-Exe $adk '/quiet /norestart /ceip off /features OptionId.DeploymentTools'
    $osc = Find-Oscdimg
    if (-not $osc) { throw "oscdimg.exe could not be installed (ADK setup exit $code)." }
    Write-Ok "oscdimg.exe installed: $osc"
    return $osc
}
function Find-Tool([string]$Name) {
    if (Test-Path -LiteralPath $ToolsDir) {
        $f = Get-ChildItem -LiteralPath $ToolsDir -Recurse -Filter $Name -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (Test-Path -LiteralPath $kits) {
        $dirs = @(Get-ChildItem -LiteralPath $kits -Directory | Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
        foreach ($d in $dirs) {
            foreach ($a in 'x64', 'x86') {
                $p = Join-Path (Join-Path $d.FullName $a) $Name
                if (Test-Path -LiteralPath $p) { return $p }
            }
        }
    }
    return $null
}
function Save-NuPkg([string]$Id) {
    $lid = $Id.ToLowerInvariant()
    $idx = Invoke-RestMethod -Uri "https://api.nuget.org/v3-flatcontainer/$lid/index.json"
    $stable = @($idx.versions | Where-Object { $_ -notmatch '-' })
    $ver = @($stable | Sort-Object { try { [version]($_ -replace '^(\d+(\.\d+){1,3}).*', '$1') } catch { [version]'0.0' } } -Descending)[0]
    if (-not $ver) { throw "No stable version of $Id on nuget.org" }
    $dl = Join-Path $ToolsDir 'download'
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $file = Join-Path $dl "$lid.$ver.nupkg"
    if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -eq 0) {
        Write-Sub "downloading $Id $ver from nuget.org"
        Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/$lid/$ver/$lid.$ver.nupkg" -OutFile $file -UseBasicParsing
    }
    return $file
}
# Extracts the folder that holds $Exe (that folder's files only) from a .nupkg into $Dest.
function Expand-Tool([string]$Nupkg, [string]$Exe, [string]$Dest, [string]$Prefer) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Nupkg)
    try {
        $hits = @($zip.Entries | Where-Object { $_.Name -ieq $Exe })
        if ($hits.Count -eq 0) { return $false }
        $hit = @($hits | Sort-Object @{ Expression = { if ($_.FullName -match $Prefer) { 0 } else { 1 } } }, @{ Expression = { $_.FullName }; Descending = $true })[0]
        $prefix = $hit.FullName.Substring(0, $hit.FullName.Length - $hit.Name.Length)
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        foreach ($e in $zip.Entries) {
            if ($e.Name -and $e.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $e.FullName.IndexOf('/', $prefix.Length) -lt 0) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $Dest $e.Name), $true)
            }
        }
        return $true
    } finally { $zip.Dispose() }
}
function Get-FromNuGet([string]$Exe, [string[]]$Packages, [string]$Prefer) {
    foreach ($pkg in $Packages) {
        try {
            $nupkg = Save-NuPkg $pkg
            $dest = Join-Path $ToolsDir ([IO.Path]::GetFileNameWithoutExtension($Exe))
            if (Expand-Tool $nupkg $Exe $dest $Prefer) {
                $exePath = Join-Path $dest $Exe
                $sig = Get-AuthenticodeSignature -LiteralPath $exePath
                if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation') { Write-Ok "$Exe extracted from $pkg (Microsoft signature valid)"; return $exePath }
                if ($sig.Status -eq 'NotSigned') {
                    # Some kit tools (Inf2Cat is .NET) carry no Authenticode signature of their own; the package
                    # itself comes from nuget.org over HTTPS under Microsoft's reserved Microsoft.* prefix.
                    Write-Ok "$Exe extracted from $pkg (not signed itself - comes from Microsoft's NuGet package)"
                    return $exePath
                }
                Write-Warn "$Exe from $pkg failed the signature check (status: $($sig.Status)) - removed."
                Remove-Item -LiteralPath $dest -Recurse -Force
            } else { Write-Info "$Exe is not inside $pkg" }
        } catch { Write-Warn "$pkg : $($_.Exception.Message)" }
    }
    return $null
}
function Get-SignTools {
    $t = @{ Inf2Cat = (Find-Tool 'Inf2Cat.exe'); SignTool = (Find-Tool 'signtool.exe') }
    if (-not $t.SignTool) {
        Write-Step 'Getting signtool.exe (Windows SDK build tools)'
        $t.SignTool = Get-FromNuGet 'signtool.exe' @('Microsoft.Windows.SDK.BuildTools', 'Microsoft.Windows.WDK.x64') '(?i)/x64/'
    }
    if (-not $t.Inf2Cat) {
        Write-Step 'Getting Inf2Cat.exe (Windows Driver Kit, about 110 MB)'
        $t.Inf2Cat = Get-FromNuGet 'Inf2Cat.exe' @('Microsoft.Windows.WDK.x64') '(?i)/x86/'
    }
    if (-not $t.Inf2Cat) { throw 'Inf2Cat.exe could not be downloaded from nuget.org (see the lines above). Check the internet connection and try again - only the Inf2Cat folder of the package is kept, nothing is installed.' }
    Write-Info "Inf2Cat : $($t.Inf2Cat)"
    if ($t.SignTool) { Write-Info "signtool: $($t.SignTool)" } else { Write-Warn 'signtool.exe not available - PowerShell signing is used and every package is re-signed.' }
    return $t
}
function Get-AllTools {
    Write-Title 'Tools'
    $o = Get-Oscdimg
    Write-Ok "oscdimg.exe : $o"
    [void](Get-SignTools)
    Write-Ok 'All tools are ready.'
}
#endregion
