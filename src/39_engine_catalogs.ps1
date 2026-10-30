#region ---------------------------------------------------------------- catalog engines (NVIDIA Modded Drivers Signer 2.3.0)
# Inf2Cat parses every INF and checks it against every file of the package, once per INF. The other
# engines do not parse the INF: they build ONE catalog per driver folder (<folder>_w10u.cat) that every
# INF needing a new signature in that folder points at. It holds the hash of those INF files and of every
# file of the folder, so the driver files are hashed once - about 20 s for NVIDIA's 3 GB Display.Driver
# instead of minutes. Windows checks every file it copies against the catalog, also the ones an INF
# copies as whole directories (ngx-builtins, NvCamera, ...), so all files of the folder go in.
#   makecat - makecat.exe from the Windows SDK / WDK and a generated .cdf (the default)
#   libwdi  - the CryptCAT API of wintrust.dll, the way libwdi (Zadig) builds its catalogs
#   gencat  - LINBIT generate-cat-file, built and run inside WSL
#   inf2cat - Microsoft's Inf2Cat, the standard tool, and the fallback for the others
function Get-SignEngine {
    $e = ''
    if ($Script:Cfg) { $e = ([string]$Script:Cfg.SignEngine).ToLowerInvariant() }
    if ($e -in 'makecat', 'libwdi', 'gencat', 'inf2cat') { return $e }
    return 'makecat'
}
function Get-SignEngineName([string]$Engine) {
    switch ($Engine) { 'makecat' { return 'MakeCat' } 'libwdi' { return 'libwdi-style' } 'gencat' { return 'generate-cat-file' } }
    return 'Inf2Cat'
}
# Encoding of an INF file: UTF-16 and UTF-8 by their byte order mark, anything else byte for byte
# (Latin-1 maps every byte to itself). Returns the encoding and the length of the byte order mark.
function Get-InfEncoding([byte[]]$Bytes) {
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return @((New-Object Text.UnicodeEncoding -ArgumentList $false, $true), 2) }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return @((New-Object Text.UnicodeEncoding -ArgumentList $true, $true), 2) }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return @((New-Object Text.UTF8Encoding -ArgumentList $true), 3) }
    return @([Text.Encoding]::GetEncoding(28591), 0)
}
function Read-InfText([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $enc, $off = Get-InfEncoding $bytes
    return $enc.GetString($bytes, $off, $bytes.Length - $off)
}
# Name Windows looks for when a file is stored compressed: the last character of the extension becomes
# "_" (nvngx_dlssd.dll -> nvngx_dlssd.dl_), a shorter extension gets "_" appended, no extension -> "._".
function Get-PackedName([string]$Leaf) {
    if (-not $Leaf) { return '' }
    $dot = $Leaf.LastIndexOf('.')
    if ($dot -lt 0) { return ($Leaf + '._') }
    if (($Leaf.Length - $dot - 1) -ge 3) { return ($Leaf.Substring(0, $Leaf.Length - 1) + '_') }
    return ($Leaf + '_')
}
# Files an INF names in [SourceDisksFiles] (plain, .nt and the image's architecture) that are in its folder.
# A file that is only there compressed (name.dl_) counts: Packed, Path is the compressed file and Name the
# name the INF uses (the one Windows checks against the catalog). Missing: named but not there; MissingUsed:
# of those, the ones a copy section names too - no catalog can hold the hash of a file that is not there.
function Get-InfSourceFiles([string]$Inf, [string]$Arch = 'amd64') {
    $dir = Split-Path -Parent $Inf
    $self = Split-Path -Leaf $Inf
    $text = Read-InfText $Inf
    $secs = [regex]::Matches($text, '(?m)^[ \t]*\[([^\]\r\n]+)\]')
    $split = New-Object Text.RegularExpressions.Regex -ArgumentList ',(?=(?:[^"]*"[^"]*")*[^"]*$)'
    $want = '^SourceDisks(Names|Files)(\.nt|\.(nt)?' + [regex]::Escape($Arch) + ')?$'
    $disks = @{}
    $entries = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $secs.Count; $i++) {
        $sname = $secs[$i].Groups[1].Value.Trim()
        if ($sname -notmatch $want) { continue }
        $isNames = $sname -match '^SourceDisksNames'
        $start = $secs[$i].Index + $secs[$i].Length
        $end = if (($i + 1) -lt $secs.Count) { $secs[$i + 1].Index } else { $text.Length }
        foreach ($line in ($text.Substring($start, $end - $start) -split "`r?`n")) {
            $l = $line.Trim()
            if ($l.Length -eq 0 -or $l[0] -eq ';') { continue }
            $eq = $l.IndexOf('=')
            if ($eq -lt 1) { continue }
            $key = $l.Substring(0, $eq).Trim().Trim('"')
            $parts = @($split.Split($l.Substring($eq + 1)) | ForEach-Object { $p = $_.Trim(); if ($p -notmatch '"') { $p = ($p -replace '\s*;.*$', '').Trim() }; $p })
            if ($isNames) { if ($parts.Count -ge 4) { $disks[$key] = $parts[3].Trim('"').Trim('\') } }
            else { $entries.Add([pscustomobject]@{ File = $key; Disk = $(if ($parts.Count -ge 1) { $parts[0] } else { '' }); Sub = $(if ($parts.Count -ge 2) { $parts[1].Trim('"').Trim('\') } else { '' }) }) }
        }
    }
    $seen = @{}
    $files = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($e in $entries) {
        if ($e.File -match '[%"*?<>|]') { continue }
        $pre = @()
        if ($disks.ContainsKey($e.Disk) -and $disks[$e.Disk]) { $pre += $disks[$e.Disk] }
        if ($e.Sub) { $pre += $e.Sub }
        $rel = ((@($pre) + $e.File) -join '\').TrimStart('\')
        if ($rel -match '\.\.') { continue }
        $leaf = Split-Path -Leaf $rel
        if ($leaf -ieq $self -or $leaf -match '(?i)\.cat$') { continue }
        $full = Join-Path $dir $rel
        $packed = $false
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $pfull = Join-Path (Split-Path -Parent $full) (Get-PackedName $leaf)
            if (Test-Path -LiteralPath $pfull -PathType Leaf) { $packed = $true; $full = $pfull }
            else { if (-not $missing.Contains($rel)) { $missing.Add($rel) }; continue }
        }
        $full = (Get-Item -LiteralPath $full -Force).FullName
        $lk = $leaf.ToLowerInvariant()
        if ($seen.ContainsKey($lk)) { continue }
        $seen[$lk] = $true
        $files.Add([pscustomobject]@{ Name = $leaf; Path = $full; Packed = $packed })
    }
    # a file only named in [SourceDisksFiles] is harmless when absent; one a copy section names is not
    $used = @()
    if ($missing.Count) {
        $other = New-Object Text.StringBuilder
        for ($i = 0; $i -lt $secs.Count; $i++) {
            if ($secs[$i].Groups[1].Value.Trim() -match '^SourceDisks(Names|Files)') { continue }
            $bs = $secs[$i].Index + $secs[$i].Length
            $be = if (($i + 1) -lt $secs.Count) { $secs[$i + 1].Index } else { $text.Length }
            [void]$other.Append($text.Substring($bs, $be - $bs)).Append("`n")
        }
        $ot = $other.ToString()
        foreach ($m in $missing) {
            $ml = $m.Substring($m.LastIndexOfAny([char[]]@([char]92, [char]47)) + 1)
            if ([regex]::IsMatch($ot, '(?im)^[^;\r\n]*(?<![A-Za-z0-9_.\-])' + [regex]::Escape($ml) + '(?![A-Za-z0-9_.\-])')) { $used += $m }
        }
    }
    return [pscustomobject]@{ Files = $files.ToArray(); Missing = $missing.ToArray(); MissingUsed = @($used) }
}
# Every file under the driver folder except .inf / .cat, sorted.
function Get-FolderFiles([string]$Dir) {
    return @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -ine '.inf' -and $_.Extension -ine '.cat' } | Sort-Object FullName |
             ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName } })
}
# Windows checks a compressed file (name.dl_) as the expanded file, so that is what goes into the catalog:
# expand.exe writes it to <stage>\_expanded\<name the INF uses>. Returns '' when that fails.
function Expand-PackedFile([string]$Src, [string]$Name, [string]$Stage) {
    $exe = if ($Script:ExpandExe) { $Script:ExpandExe } else { Join-Path $env:SystemRoot 'System32\expand.exe' }
    try {
        $xd = Join-Path $Stage '_expanded'
        New-Item -ItemType Directory -Force -Path $xd | Out-Null
        $dst = Join-Path $xd $Name
        if ((Test-Path -LiteralPath $dst -PathType Leaf) -and (Get-Item -LiteralPath $dst).Length -gt 0) { return $dst }
        $r = Invoke-Native $exe @($Src, $dst)
        Add-Log $r.Text
        if ((Test-Path -LiteralPath $dst -PathType Leaf) -and (Get-Item -LiteralPath $dst).Length -gt 0) { return $dst }
        # a cabinet with one file under another name: expand all of it, take that file
        $td = Join-Path $xd ('x_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $td | Out-Null
        $r = Invoke-Native $exe @($Src, '-F:*', $td)
        Add-Log $r.Text
        $one = Get-ChildItem -LiteralPath $td -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($one -and $one.Length -gt 0) { Move-Item -LiteralPath $one.FullName -Destination $dst -Force; return $dst }
    } catch { Add-Log "expand $Src : $($_.Exception.Message)" }
    return ''
}
# What goes into one folder's catalog: the staged INF files, the files they list (compressed ones expanded,
# under the name the INF uses) and every other file of the folder, each name once.
# $NameRx: file names the engine cannot take are skipped; $Lower: member names in lower case.
function Get-CatMembers([string]$Stage, [string]$Dir, [string[]]$Infs, [string[]]$Staged, [string]$NameRx, [bool]$Lower, [string]$Arch = 'amd64') {
    $mem = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $r = [pscustomobject]@{ Members = @(); InfCount = 0; FileCount = 0; ExtraCount = 0; PackedCount = 0; ExpandFailed = 0; Skipped = 0; Clashes = 0; Missing = 0; MissingUsed = @(); MB = 0.0 }
    $add = {
        param($Name, $Path, $Kind)
        $nm = if ($Lower) { $Name.ToLowerInvariant() } else { $Name }
        if ($NameRx -and $nm -notmatch $NameRx) { $r.Skipped++; return $false }
        $lk = $nm.ToLowerInvariant()
        if ($seen.ContainsKey($lk)) { if ($seen[$lk] -ne $Path) { $r.Clashes++ }; return $false }
        $seen[$lk] = $Path
        $mem.Add([pscustomobject]@{ Name = $nm; Path = $Path; Kind = $Kind })
        return $true
    }
    foreach ($s in @($Staged)) { if (& $add (Split-Path $s -Leaf) $s 'inf') { $r.InfCount++ } }
    $miss = @{}
    foreach ($inf in @($Infs)) {
        $l = Get-InfSourceFiles $inf $Arch
        foreach ($m in $l.Missing) { $miss[$m] = $true }
        $r.MissingUsed += @($l.MissingUsed)
        foreach ($f in $l.Files) {
            $p = $f.Path
            if ($f.Packed) {
                $nm = if ($Lower) { $f.Name.ToLowerInvariant() } else { $f.Name }
                if ($seen.ContainsKey($nm.ToLowerInvariant()) -or ($NameRx -and $nm -notmatch $NameRx)) { [void](& $add $f.Name $p 'file'); continue }
                $r.PackedCount++
                $x = Expand-PackedFile $p $f.Name $Stage
                if ($x) { $p = $x } else { $r.ExpandFailed++ }
            }
            [void](& $add $f.Name $p 'file')
        }
    }
    $listed = $mem.Count - $r.InfCount
    foreach ($f in (Get-FolderFiles $Dir)) { if (& $add $f.Name $f.Path 'file') { $r.ExtraCount++ } }
    $r.Members = $mem.ToArray()
    $r.FileCount = $listed + $r.ExtraCount
    $r.Missing = $miss.Count
    $r.MissingUsed = @($r.MissingUsed | Sort-Object -Unique)
    $sum = 0.0; foreach ($m in $r.Members) { try { $sum += (Get-Item -LiteralPath $m.Path).Length } catch { } }
    $r.MB = $sum / 1MB
    return $r
}
function Get-MemberNote($Info) {
    $s = '{0} member(s), {1:N0} MB: {2} INF + {3} file(s) the INF files list + {4} other file(s) of the folder' -f $Info.Members.Count, $Info.MB, $Info.InfCount, ($Info.FileCount - $Info.ExtraCount), $Info.ExtraCount
    if ($Info.PackedCount) {
        $s += '; {0} stored compressed (name.dl_): the expanded file is hashed under the name the INF uses' -f $Info.PackedCount
        if ($Info.ExpandFailed) { $s += ' ({0} could not be expanded - the compressed file is hashed instead)' -f $Info.ExpandFailed }
    }
    if ($Info.Skipped) { $s += '; {0} skipped (file name the engine cannot take)' -f $Info.Skipped }
    if ($Info.Clashes) { $s += '; {0} name clash(es), the first file kept' -f $Info.Clashes }
    if ($Info.Missing) { $s += '; {0} file(s) named in [SourceDisksFiles] are not in the folder' -f $Info.Missing }
    return $s
}
# One catalog per driver folder, named after it.
function Get-SharedCatName([string]$Dir) {
    $leaf = ((Split-Path -Leaf $Dir).ToLowerInvariant()) -replace '[^a-z0-9._\-]', '_'
    if (-not $leaf) { $leaf = 'driver' }
    return ($leaf + '_w10u.cat')
}
# The .cdf that makecat.exe reads: SHA-256, every member with its name and the Windows versions.
# INF files are named relative to the stage folder, where makecat runs and writes the catalog.
function New-MakeCatCdf([string]$Cat, $Members) {
    $os = @('6.0', '6.1', '6.2', '6.3', '6.4', '10.0')
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('[CatalogHeader]', "Name=$Cat", 'ResultDir=.', 'CatalogVersion=2', 'HashAlgorithms=SHA256', 'PageHashes=false', 'EncodingType=0x00010001')) { $l.Add($x) }
    for ($i = 0; $i -lt $os.Count; $i++) { $l.Add(('CATATTR{0}=0x10010001:OSAttr:2:{1}' -f ($i + 1), $os[$i])) }
    $l.Add('[CatalogFiles]')
    foreach ($m in @($Members)) {
        $tag = '<HASH>' + $m.Name
        $l.Add($tag + '=' + $(if ($m.Kind -eq 'inf') { $m.Name } else { $m.Path }))
        $l.Add($tag + 'ATTR1=0x10010001:File:' + $m.Name)
        for ($i = 0; $i -lt $os.Count; $i++) { $l.Add(('{0}ATTR{1}=0x10010001:OSAttr:2:{2}' -f $tag, ($i + 2), $os[$i])) }
    }
    return (($l -join "`r`n") + "`r`n")
}
# makecat.exe: installed Windows Kit or tools folder, else from Microsoft's NuGet packages.
function Get-MakeCat {
    $m = Find-Tool 'makecat.exe'
    if (-not $m) {
        Write-Step 'Getting makecat.exe (Windows SDK build tools / Windows Driver Kit)'
        $m = Get-FromNuGet 'makecat.exe' @('Microsoft.Windows.SDK.BuildTools', 'Microsoft.Windows.WDK.x64') '(?i)/x64/'
    }
    return $m
}
function Invoke-MakeCatGroups([string]$MakeCat, $Groups, [int]$Jobs) {
    $items = @()
    foreach ($g in @($Groups)) {
        $cdf = [IO.Path]::GetFileNameWithoutExtension($g.Cat) + '.cdf'
        # Windows PowerShell's default encoding is the ANSI code page, the one makecat reads a .cdf in
        [IO.File]::WriteAllText((Join-Path $g.Dir $cdf), (New-MakeCatCdf $g.Cat $g.Info.Members), [Text.Encoding]::Default)
        $items += [pscustomobject]@{ Dir = $g.Dir; WorkDir = $g.Dir; Label = $g.Label; Est = (2 + $g.Info.MB / 120.0); Args = @('-v', $cdf) }
    }
    $out = @(Invoke-ToolQueue $MakeCat $items ([math]::Max(1, [math]::Min(4, $Jobs))) 'MakeCat')
    for ($k = 0; $k -lt $items.Count; $k++) {
        $r = $out[$k]
        # makecat's exit code is not reliable: the catalog file tells (as in the signer)
        if (Test-Path -LiteralPath (Join-Path $Groups[$k].Dir $Groups[$k].Cat)) { $r.Code = 0 } elseif ($r.Code -eq 0) { $r.Code = 1 }
        # success: drop the line per member ("processing", "attribute", "opened")
        if ($r.Code -eq 0) { $r.Output = @($r.Output | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(attribute|processing|opened):' }); $r.Text = $r.Output -join "`r`n" }
        $Groups[$k].R = $r
    }
}
# ---- libwdi-style: the catalog is built with the CryptCAT API of wintrust.dll, following libwdi (pki.c):
# SHA-1 member hashes, PE files with SPC_PE_IMAGE_DATA, INF and other files with SPC_LINK.
function Get-NativeCatSource {
    return @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace W10U
{
    public static class NativeCat
    {
        [StructLayout(LayoutKind.Sequential)]
        struct BLOB { public uint cbData; public IntPtr pbData; }

        [StructLayout(LayoutKind.Sequential)]
        struct SIP_INDIRECT_DATA
        {
            public IntPtr DataObjId;
            public BLOB DataValue;
            public IntPtr AlgObjId;
            public BLOB AlgParams;
            public BLOB Digest;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PE_IMAGE_DATA
        {
            public uint FlagsCb;
            public IntPtr FlagsPb;
            public uint FlagsUnused;
            public IntPtr pFile;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CryptAcquireContextW(out IntPtr phProv, string pszContainer, string pszProvider, uint dwProvType, uint dwFlags);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool CryptReleaseContext(IntPtr hProv, uint dwFlags);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATOpen(string pwszFileName, uint fdwOpenFlags, IntPtr hProv, uint dwPublicVersion, uint dwEncodingType);
        [DllImport("wintrust.dll", SetLastError = true)]
        static extern bool CryptCATClose(IntPtr hCatalog);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATPutCatAttrInfo(IntPtr hCatalog, string pwszReferenceTag, uint dwAttrTypeAndAction, uint cbData, byte[] pbData);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATPutMemberInfo(IntPtr hCatalog, string pwszFileName, string pwszReferenceTag, ref Guid pgSubjectType, uint dwCertVersion, uint cbSIPIndirectData, IntPtr pbSIPIndirectData);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATPutAttrInfo(IntPtr hCatalog, IntPtr pCatMember, string pwszReferenceTag, uint dwAttrTypeAndAction, uint cbData, byte[] pbData);
        [DllImport("wintrust.dll", SetLastError = true)]
        static extern bool CryptCATPersistStore(IntPtr hCatalog);
        [DllImport("wintrust.dll", SetLastError = true)]
        static extern bool CryptCATAdminCalcHashFromFileHandle(IntPtr hFile, ref uint pcbHash, byte[] pbHash, uint dwFlags);
        [DllImport("crypt32.dll", SetLastError = true)]
        static extern bool CryptEncodeObject(uint dwCertEncodingType, [MarshalAs(UnmanagedType.LPStr)] string lpszStructType, IntPtr pvStructInfo, byte[] pbEncoded, ref uint pcbEncoded);

        const uint X509_ASN_ENCODING = 1;
        const uint CRYPTCAT_OPEN_CREATENEW = 1;
        const uint CATATTR = 0x10000000 | 0x1 | 0x10000;   // AUTHENTICATED | NAMEASCII | DATAASCII
        const uint PROV_RSA_FULL = 1;
        const uint CRYPT_VERIFYCONTEXT = 0xF0000000;
        const string OID_PE = "1.3.6.1.4.1.311.2.1.15";
        const string OID_CAB = "1.3.6.1.4.1.311.2.1.25";
        const string OID_SHA1 = "1.3.14.3.2.26";
        static readonly Guid FLAT_GUID = new Guid("DE351A42-8E59-11D0-8C47-00C04FC295EE");
        static readonly Guid PE_GUID = new Guid("C689AAB8-8E78-11D0-8C47-00C04FC295EE");

        public static bool IsPE(string path)
        {
            try
            {
                using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    byte[] b = new byte[64];
                    if (f.Read(b, 0, 64) < 64) return false;
                    if (b[0] != 0x4D || b[1] != 0x5A) return false;
                    int off = BitConverter.ToInt32(b, 60);
                    if (off < 0 || off > f.Length - 4) return false;
                    f.Seek(off, SeekOrigin.Begin);
                    byte[] s = new byte[4];
                    if (f.Read(s, 0, 4) < 4) return false;
                    return s[0] == 0x50 && s[1] == 0x45 && s[2] == 0 && s[3] == 0;
                }
            }
            catch (Exception) { return false; }
        }

        static byte[] UniZ(string s) { return Encoding.Unicode.GetBytes(s + "\0"); }

        public static string Create(string catPath, string hwid, string osString, string osAttr, string[] names, string[] paths, CatJob job)
        {
            IntPtr hProv = IntPtr.Zero;
            IntPtr hCat = IntPtr.Zero;
            try
            {
                if (File.Exists(catPath)) File.Delete(catPath);
                if (!CryptAcquireContextW(out hProv, null, null, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT))
                    return "CryptAcquireContext failed, Win32 error " + Marshal.GetLastWin32Error();
                hCat = CryptCATOpen(catPath, CRYPTCAT_OPEN_CREATENEW, hProv, 0, 0);
                if (hCat == IntPtr.Zero || hCat == new IntPtr(-1))
                {
                    int e = Marshal.GetLastWin32Error();
                    hCat = IntPtr.Zero;
                    return "CryptCATOpen failed, Win32 error " + e;
                }
                byte[] b;
                if (!String.IsNullOrEmpty(hwid))
                {
                    b = UniZ(hwid);
                    if (CryptCATPutCatAttrInfo(hCat, "HWID1", CATATTR, (uint)b.Length, b) == IntPtr.Zero)
                        return "Setting HWID1 failed, Win32 error " + Marshal.GetLastWin32Error();
                }
                if (!String.IsNullOrEmpty(osString))
                {
                    b = UniZ(osString);
                    if (CryptCATPutCatAttrInfo(hCat, "OS", CATATTR, (uint)b.Length, b) == IntPtr.Zero)
                        return "Setting OS failed, Win32 error " + Marshal.GetLastWin32Error();
                }
                for (int i = 0; i < names.Length; i++)
                {
                    string err = AddMember(hCat, names[i], paths[i], osAttr);
                    if (err != null) return names[i] + ": " + err;
                    if (job != null) job.Processed = i + 1;
                }
                if (!CryptCATPersistStore(hCat))
                    return "CryptCATPersistStore failed, Win32 error " + Marshal.GetLastWin32Error();
                return "";
            }
            finally
            {
                if (hCat != IntPtr.Zero) CryptCATClose(hCat);
                if (hProv != IntPtr.Zero) CryptReleaseContext(hProv, 0);
            }
        }

        static string AddMember(IntPtr hCat, string name, string path, string osAttr)
        {
            byte[] hash = new byte[20];
            uint cb = 20;
            bool pe = IsPE(path);
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                if (!CryptCATAdminCalcHashFromFileHandle(fs.SafeFileHandle.DangerousGetHandle(), ref cb, hash, 0))
                    return "hashing failed, Win32 error " + Marshal.GetLastWin32Error();
            }
            string hex = BitConverter.ToString(hash).Replace("-", "");

            IntPtr pLinkStr = IntPtr.Zero, pLink = IntPtr.Zero, pFlags = IntPtr.Zero, pImg = IntPtr.Zero;
            IntPtr pEnc = IntPtr.Zero, pOidData = IntPtr.Zero, pOidAlg = IntPtr.Zero, pDigest = IntPtr.Zero, pSip = IntPtr.Zero;
            try
            {
                // SPC_LINK { DWORD dwLinkChoice; union { LPWSTR pwszFile; ... } } - the union starts at pointer alignment
                pLinkStr = Marshal.StringToHGlobalUni("<<<Obsolete>>>");
                pLink = Marshal.AllocHGlobal(64);
                for (int i = 0; i < 64; i += 4) Marshal.WriteInt32(pLink, i, 0);
                Marshal.WriteInt32(pLink, 0, 3);                    // SPC_FILE_LINK_CHOICE
                Marshal.WriteIntPtr(pLink, IntPtr.Size, pLinkStr);  // pwszFile

                byte[] enc = new byte[256];
                uint cbEnc = (uint)enc.Length;
                if (pe)
                {
                    pFlags = Marshal.AllocHGlobal(1);
                    Marshal.WriteByte(pFlags, 0xA0);
                    PE_IMAGE_DATA img = new PE_IMAGE_DATA();
                    img.FlagsCb = 1;
                    img.FlagsPb = pFlags;
                    img.FlagsUnused = 0;
                    img.pFile = pLink;
                    pImg = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(PE_IMAGE_DATA)));
                    Marshal.StructureToPtr(img, pImg, false);
                    if (!CryptEncodeObject(X509_ASN_ENCODING, OID_PE, pImg, enc, ref cbEnc))
                        return "encoding SPC_PE_IMAGE_DATA failed, Win32 error " + Marshal.GetLastWin32Error();
                }
                else
                {
                    if (!CryptEncodeObject(X509_ASN_ENCODING, OID_CAB, pLink, enc, ref cbEnc))
                        return "encoding SPC_LINK failed, Win32 error " + Marshal.GetLastWin32Error();
                }

                pEnc = Marshal.AllocHGlobal((int)cbEnc);
                Marshal.Copy(enc, 0, pEnc, (int)cbEnc);
                pOidData = Marshal.StringToHGlobalAnsi(pe ? OID_PE : OID_CAB);
                pOidAlg = Marshal.StringToHGlobalAnsi(OID_SHA1);
                pDigest = Marshal.AllocHGlobal(20);
                Marshal.Copy(hash, 0, pDigest, 20);

                SIP_INDIRECT_DATA sip = new SIP_INDIRECT_DATA();
                sip.DataObjId = pOidData;
                sip.DataValue.cbData = cbEnc;
                sip.DataValue.pbData = pEnc;
                sip.AlgObjId = pOidAlg;
                sip.AlgParams.cbData = 0;
                sip.AlgParams.pbData = IntPtr.Zero;
                sip.Digest.cbData = 20;
                sip.Digest.pbData = pDigest;
                int sipSize = Marshal.SizeOf(typeof(SIP_INDIRECT_DATA));
                pSip = Marshal.AllocHGlobal(sipSize);
                Marshal.StructureToPtr(sip, pSip, false);

                Guid g = pe ? PE_GUID : FLAT_GUID;
                IntPtr member = CryptCATPutMemberInfo(hCat, null, hex, ref g, 0x200, (uint)sipSize, pSip);
                if (member == IntPtr.Zero)
                    return "CryptCATPutMemberInfo failed, Win32 error " + Marshal.GetLastWin32Error();

                byte[] b1 = UniZ(name.ToLowerInvariant());
                if (CryptCATPutAttrInfo(hCat, member, "File", CATATTR, (uint)b1.Length, b1) == IntPtr.Zero)
                    return "Setting File attribute failed, Win32 error " + Marshal.GetLastWin32Error();
                byte[] b2 = UniZ(osAttr);
                if (CryptCATPutAttrInfo(hCat, member, "OSAttr", CATATTR, (uint)b2.Length, b2) == IntPtr.Zero)
                    return "Setting OSAttr attribute failed, Win32 error " + Marshal.GetLastWin32Error();
                return null;
            }
            finally
            {
                if (pSip != IntPtr.Zero) Marshal.FreeHGlobal(pSip);
                if (pDigest != IntPtr.Zero) Marshal.FreeHGlobal(pDigest);
                if (pOidAlg != IntPtr.Zero) Marshal.FreeHGlobal(pOidAlg);
                if (pOidData != IntPtr.Zero) Marshal.FreeHGlobal(pOidData);
                if (pEnc != IntPtr.Zero) Marshal.FreeHGlobal(pEnc);
                if (pImg != IntPtr.Zero) Marshal.FreeHGlobal(pImg);
                if (pFlags != IntPtr.Zero) Marshal.FreeHGlobal(pFlags);
                if (pLink != IntPtr.Zero) Marshal.FreeHGlobal(pLink);
                if (pLinkStr != IntPtr.Zero) Marshal.FreeHGlobal(pLinkStr);
            }
        }
    }

    // NativeCat.Create on a thread of its own, so the job can show how many files are hashed.
    public class CatJob
    {
        public volatile bool Done;
        public string Error = "";
        public volatile int Processed;
        public int Total;
        string cat, hwid, os, osAttr;
        string[] names, paths;

        public CatJob(string cat, string hwid, string os, string osAttr, string[] names, string[] paths)
        {
            this.cat = cat; this.hwid = hwid; this.os = os; this.osAttr = osAttr;
            this.names = names; this.paths = paths; this.Total = names.Length;
        }

        public void Start()
        {
            Thread th = new Thread(new ThreadStart(Run));
            th.IsBackground = true;
            th.Start();
        }

        void Run()
        {
            try { Error = NativeCat.Create(cat, hwid, os, osAttr, names, paths, this); }
            catch (Exception ex) { Error = ex.GetType().Name + ": " + ex.Message; }
            Done = true;
        }
    }
}
'@
}
function Initialize-NativeCat {
    if (-not ('W10U.CatJob' -as [type])) { Add-Type -TypeDefinition (Get-NativeCatSource) -Language CSharp }
}
# Catalog attributes the native and WSL engines write (Windows 7 to 11, the image's architecture).
function Get-CatOs([string]$Engine, [string]$Arch) {
    $tok = switch ($Arch) { 'x86' { 'X86' } 'arm64' { 'ARM64' } default { 'X64' } }
    if ($Engine -eq 'gencat') {
        return [pscustomobject]@{ Os = ('7X64,8X64,_v100_X64,_v100_X64_RS5,_v100_X64_19H1,_v100_X64_Vb,_v100_X64_21H2,_v100_X64_22H2,_v100_X64_24H2' -replace 'X64', $tok); Attr = '2:6.1,2:6.2,2:6.3,2:6.4,2:10.0' }
    }
    return [pscustomobject]@{ Os = ('7_X64,8_X64,10_X64,10_RS5_X64,10_19H1_X64,10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64' -replace 'X64', $tok); Attr = '2:6.0,2:6.1,2:6.2,2:6.3,2:6.4,2:10.0' }
}
function Invoke-NativeCatGroups($Groups, [string]$Arch) {
    Initialize-NativeCat
    $os = Get-CatOs 'libwdi' $Arch
    foreach ($g in @($Groups)) {
        $t0 = Get-Date
        $catPath = Join-Path $g.Dir $g.Cat
        $job = [W10U.CatJob]::new($catPath, $g.Hwid, $os.Os, $os.Attr, [string[]]@($g.Info.Members | ForEach-Object { $_.Name }), [string[]]@($g.Info.Members | ForEach-Object { $_.Path }))
        $job.Start()
        $beat = 5
        while (-not $job.Done) {
            Start-Sleep -Milliseconds 200
            $e = (Get-Date) - $t0
            if ($Script:Sync) {
                $Script:Sync.Status = 'libwdi-style {0}  {1}  - {2} of {3} file(s) hashed' -f $g.Label, (Format-Span $e), $job.Processed, $job.Total
                if ($job.Total) { $Script:Sync.Pct = [math]::Min(99.0, 100.0 * $job.Processed / $job.Total) }
            }
            if ($e.TotalMinutes -ge $beat) { Add-Log ('libwdi-style {0} still running ({1}) - {2} of {3} file(s)' -f $g.Label, (Format-Span $e), $job.Processed, $job.Total); $beat += 5 }
        }
        $err = [string]$job.Error
        if (-not $err -and -not (Test-Path -LiteralPath $catPath)) { $err = 'the catalog file was not created' }
        if ($err) { Remove-Item -LiteralPath $catPath -Force -ErrorAction SilentlyContinue }
        $out = @($(if ($err) { $err } else { 'catalog written: {0} member(s)' -f $job.Total }))
        $g.R = [pscustomobject]@{ Code = $(if ($err) { 1 } else { 0 }); Output = $out; Text = ($out -join "`r`n"); Time = ((Get-Date) - $t0); Dir = $g.Dir }
    }
    if ($Script:Sync) { $Script:Sync.Status = ''; $Script:Sync.Pct = -1 }
}
# ---- generate-cat-file (LINBIT, GPL-2.0): its source, pinned to one commit and checked by SHA-256, is
# downloaded into the tools folder and built inside WSL (needs a Linux distribution with gcc and make).
function Get-GenCatPin {
    return [pscustomobject]@{
        Commit = '65ebf4de79a42b0a1104fbef37b1c207ff13e1e9'
        Sha256 = @{
            'generate-cat-file.c' = '45afc2c933849e5cb4dfd7eadd2300bac993e721dc8f4ac902eed5808845d607'
            'strip-pe-image.c'    = 'b5fe83eecea5d6ef4b6fb185a79069db9a468bda7e92d34f09e70df9ffccb8da'
            'gencat.sh'           = 'b922bd15f7be71ab07e9329ac593176cb37ee2dddefd0e0050e6eae2296882d1'
            'Makefile'            = '198357b8b2c4ecfd5b463fc2266621a9036c8663071c15819903425f182d7ae3'
        }
    }
}
function ConvertTo-ShQuoted([string]$S) { return ("'" + $S.Replace("'", "'\''") + "'") }
# Runs a shell script in WSL (stdin, UTF-8). Returns Code, Output, Text.
function Invoke-WslScript([string]$Text, [int]$TimeoutSec = 600) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = if ($Script:WslExe) { $Script:WslExe } else { 'wsl.exe' }
    $psi.Arguments = '-e sh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    Add-Log "EXEC $($psi.FileName) -e sh"
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $b = (New-Object Text.UTF8Encoding -ArgumentList $false).GetBytes(($Text -replace "`r`n", "`n"))
    $p.StandardInput.BaseStream.Write($b, 0, $b.Length); $p.StandardInput.Close()
    $late = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $late = $true; try { $p.Kill() } catch { }; [void]$p.WaitForExit(5000) }
    $lines = @((($o.Result + "`n" + $e.Result) -replace "`0", '') -split "`r?`n" | Where-Object { $_.Trim() })
    if ($late) { $lines += "(stopped after $TimeoutSec s)" }
    $code = if ($late) { -1 } else { [int]$p.ExitCode }
    return [pscustomobject]@{ Code = $code; Output = $lines; Text = ($lines -join "`r`n") }
}
function Initialize-GenCat {
    $pin = Get-GenCatPin
    try { $chk = Invoke-WslScript "echo W10U_WSL_OK`nuname -sr`n" 120 } catch { $chk = [pscustomobject]@{ Text = $_.Exception.Message; Output = @() } }
    if ($chk.Text -notmatch 'W10U_WSL_OK') { throw ('WSL is not available or has no Linux distribution (run "wsl --install" as administrator). ' + $chk.Text).Trim() }
    Write-Info ('WSL: ' + @($chk.Output | Where-Object { $_ -notmatch 'W10U_WSL_OK' })[0])
    $src = Join-Path $ToolsDir 'gencat\src'
    $ok = { foreach ($k in $pin.Sha256.Keys) { $f = Join-Path $src $k; if (-not (Test-Path -LiteralPath $f) -or (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.Sha256[$k]) { return $false } }; return $true }
    if (-not (& $ok)) {
        Write-Step 'Getting generate-cat-file (LINBIT, GPL-2.0) - source, pinned commit'
        New-Item -ItemType Directory -Force -Path $src, (Join-Path $ToolsDir 'download') | Out-Null
        $zip = Join-Path $ToolsDir 'download\generate-cat-file.zip'
        Invoke-WebRequest -Uri "https://github.com/LINBIT/generate-cat-file/archive/$($pin.Commit).zip" -OutFile $zip -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($x in $z.Entries) {
                if (@($x.FullName.Split('/')).Count -eq 2 -and ($pin.Sha256.ContainsKey($x.Name) -or $x.Name -eq 'COPYING')) {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($x, (Join-Path $src $x.Name), $true)
                }
            }
        } finally { $z.Dispose() }
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (-not (& $ok)) { throw 'The generate-cat-file source failed the SHA-256 check (not the pinned commit) - nothing was built.' }
        Write-Ok 'generate-cat-file source verified (SHA-256)'
    }
    $build = @'
set -e
SRC="$(wslpath -a @SRC@)"
DST="$HOME/.w10u-gencat"
if [ -x "$DST/generate-cat-file" ] && [ -x "$DST/strip-pe-image" ] && [ -f "$DST/gencat.sh" ] && [ "$(cat "$DST/COMMIT" 2>/dev/null)" = "@COMMIT@" ]; then echo W10U_BUILD_OK; exit 0; fi
for t in gcc make sha1sum getopt bash sort cut tr basename dirname sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing inside WSL: $t (sudo apt install build-essential)"; exit 90; }
done
rm -rf "$DST"; mkdir -p "$DST"
cp "$SRC/generate-cat-file.c" "$SRC/strip-pe-image.c" "$SRC/gencat.sh" "$SRC/Makefile" "$DST/"
cd "$DST"
sed -i 's/\r$//' gencat.sh Makefile generate-cat-file.c strip-pe-image.c
make >build.log 2>&1 || { echo "build failed"; tail -n 20 build.log; exit 94; }
chmod +x gencat.sh generate-cat-file strip-pe-image
echo "@COMMIT@" > COMMIT
echo W10U_BUILD_OK
'@
    $r = Invoke-WslScript ($build.Replace('@SRC@', (ConvertTo-ShQuoted $src)).Replace('@COMMIT@', $pin.Commit)) 900
    Add-Log $r.Text
    if ($r.Text -notmatch 'W10U_BUILD_OK') { throw ('Building generate-cat-file inside WSL failed: ' + $r.Text).Trim() }
    Write-Info 'generate-cat-file: built inside WSL'
}
function Invoke-GenCatGroups($Groups, [string]$Arch) {
    $os = Get-CatOs 'gencat' $Arch
    $tpl = @'
set -e
D="$HOME/.w10u-gencat"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
@LINKS@cd "$W"
bash "$D/gencat.sh" -o "$W/out.cat" -h @HWID@ -O @OS@ -A @OSATTR@ @NAMES@ </dev/null
cp "$W/out.cat" "$(wslpath -a @OUTCAT@)"
echo W10U_RUN_OK
'@
    foreach ($g in @($Groups)) {
        $t0 = Get-Date
        $links = New-Object Text.StringBuilder
        foreach ($m in $g.Info.Members) { [void]$links.Append(('ln -s "$(wslpath -a {0})" "$W/{1}"' -f (ConvertTo-ShQuoted $m.Path), $m.Name)).Append("`n") }
        $sh = $tpl.Replace('@LINKS@', $links.ToString()).Replace('@HWID@', (ConvertTo-ShQuoted $(if ($g.Hwid) { $g.Hwid } else { 'w10u' }))).Replace('@OS@', (ConvertTo-ShQuoted $os.Os)).Replace('@OSATTR@', (ConvertTo-ShQuoted $os.Attr))
        $sh = $sh.Replace('@NAMES@', (@($g.Info.Members | ForEach-Object { $_.Name }) -join ' ')).Replace('@OUTCAT@', (ConvertTo-ShQuoted (Join-Path $g.Dir $g.Cat)))
        if ($Script:Sync) { $Script:Sync.Status = 'generate-cat-file (WSL) {0} - {1} member(s), {2:N0} MB' -f $g.Label, $g.Info.Members.Count, $g.Info.MB }
        $r = Invoke-WslScript $sh 1800
        if ($r.Text -match 'W10U_RUN_OK' -and (Test-Path -LiteralPath (Join-Path $g.Dir $g.Cat))) { $r.Code = 0 } elseif ($r.Code -eq 0) { $r.Code = 1 }
        $g.R = [pscustomobject]@{ Code = $r.Code; Output = $r.Output; Text = $r.Text; Time = ((Get-Date) - $t0); Dir = $g.Dir }
    }
    if ($Script:Sync) { $Script:Sync.Status = '' }
}
# Finds / downloads / builds what an engine needs: the makecat.exe path, or a marker.
function Initialize-SignEngine([string]$Engine) {
    switch ($Engine) {
        'makecat' { $m = Get-MakeCat; if (-not $m) { throw 'makecat.exe could not be found or downloaded (see the lines above).' }; Write-Info "MakeCat : $m"; return $m }
        'libwdi'  { Initialize-NativeCat; return 'native' }
        'gencat'  { Initialize-GenCat; return 'wsl' }
    }
    return ''
}
# MakeCat / libwdi-style / generate-cat-file for the folders in $Todo (the work items of Invoke-SignFolder).
# Each folder is prepared in <Root>~stage\gN: its INF files pointing at <folder>_w10u.cat (+ expanded
# copies of compressed files). The package changes only once its catalog is built: then the INF files and
# the catalog are copied in, and the item gets Cats / Check / Runs / Engine. Returns the items it could
# not build a catalog for - Inf2Cat builds theirs.
function Invoke-CatalogEngine([string]$Engine, [string]$Tool, $Todo, [bool]$Isolate, [int]$Jobs, [string]$StageBase, [string]$Arch) {
    $name = Get-SignEngineName $Engine
    $infArch = switch ($Arch) { 'x86' { 'x86' } 'arm64' { 'arm64' } default { 'amd64' } }
    $rx = switch ($Engine) { 'makecat' { '^[A-Za-z0-9._\-]+$' } 'gencat' { '^[a-z0-9._\-]+$' } default { '' } }
    $groups = @(); $back = @()
    $n = 0
    foreach ($t in @($Todo)) {
        $n++
        Write-Sub ('{0}  ({1}, folder {2} of {3})' -f $t.Rel, $name, $n, @($Todo).Count)
        $cat = Get-SharedCatName $t.Pkg.Dir
        $infs = @(if ($Isolate) { $t.Need } else { $t.WithCat })
        # an INF already pointing at that catalog name (signed by this tool before) has to stay in it
        $infs = @($infs + @($t.WithCat | Where-Object { $infs -notcontains $_ -and @(Get-InfCatalogs $_) -contains $cat }))
        try {
            $sd = Join-Path $StageBase ('g{0}' -f $n)
            New-Item -ItemType Directory -Force -Path $sd | Out-Null
            $staged = @()
            foreach ($inf in $infs) { $s = Join-Path $sd (Split-Path $inf -Leaf); Set-InfCatalog $inf $s $cat; $staged += $s }
            $info = Get-CatMembers $sd $t.Pkg.Dir $infs $staged $rx ($Engine -eq 'gencat') $infArch
            $hw = ''
            foreach ($inf in $infs) { foreach ($id in (Get-InfDeviceIds $inf)) { $hw = $id.ToLowerInvariant(); break }; if ($hw) { break } }
            $groups += [pscustomobject]@{ T = $t; Dir = $sd; Cat = $cat; Infs = $infs; Staged = $staged; Info = $info; Label = $t.Rel; Hwid = $hw; R = $null }
            $what = if ($infs.Count -lt $t.WithCat.Count) { '{0} of {1} INF file(s) point at it - the others keep their signature' -f $infs.Count, $t.WithCat.Count } else { 'all {0} INF file(s) point at it' -f $infs.Count }
            Write-Info ('one catalog for the folder, {0}: {1}' -f $cat, $what)
            Write-Info (Get-MemberNote $info)
            if (@($info.MissingUsed).Count) { Write-Warn ('{0} file(s) the INF files copy are not in the folder ({1}) - no catalog can hold their hash, Windows will refuse the driver' -f @($info.MissingUsed).Count, ((@($info.MissingUsed) | Select-Object -First 3) -join ', ')) }
        } catch {
            Write-Warn "$($t.Rel): $name could not be prepared ($($_.Exception.Message)) - Inf2Cat builds its catalog"
            $back += $t
        }
    }
    if ($groups.Count) {
        $mb = 0.0; foreach ($g in $groups) { $mb += $g.Info.MB }
        Write-Info ('{0}: {1} catalog(s), {2:N0} MB to hash' -f $name, $groups.Count, $mb)
        switch ($Engine) {
            'makecat' { Invoke-MakeCatGroups $Tool $groups $Jobs }
            'libwdi'  { Invoke-NativeCatGroups $groups $Arch }
            'gencat'  { Invoke-GenCatGroups $groups $Arch }
        }
    }
    foreach ($g in $groups) {
        $t = $g.T
        $built = Join-Path $g.Dir $g.Cat
        Add-Log ("[$($g.Label)] $name exit $($g.R.Code) after $(Format-Span $g.R.Time)`r`n" + $g.R.Text)
        if ($g.R.Code -ne 0 -or -not (Test-Path -LiteralPath $built)) {
            Write-Warn "$($t.Rel): $name could not build the catalog - Inf2Cat builds it instead"
            @($g.R.Output | Where-Object { $_.Trim() } | Select-Object -Last 3) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
            $back += $t; continue
        }
        for ($k = 0; $k -lt $g.Infs.Count; $k++) { Copy-Item -LiteralPath $g.Staged[$k] -Destination $g.Infs[$k] -Force }
        $dst = Join-Path $t.Pkg.Dir $g.Cat
        Copy-Item -LiteralPath $built -Destination $dst -Force
        $t.Cats = @($dst); $t.Check = $g.Infs; $t.Engine = $Engine; $t.Staged = $true
        $t.Runs = @([pscustomobject]@{ Dir = $g.Dir; Label = $g.Label; Infs = $g.Infs.Count; Est = 0; R = $g.R })
    }
    return $back
}
#endregion
