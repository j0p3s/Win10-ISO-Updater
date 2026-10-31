"""Assembles Windows-ISO-updater-GUI_v<version>.cmd (single file) from src/ parts + the v1.1 engine.

The version is read from $Script:AppVersion in src/10_engine_head.ps1 - the one place to change it.
It ends up in the file name, in the header of the .cmd and in the window.
Older builds (Windows-ISO-updater-GUI_v*.cmd, and the pre-3.4 Win10-ISO-Updater.cmd) are removed.
"""
import glob, json, os, re, sys

SRC = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SRC)

_head = open(os.path.join(SRC, '10_engine_head.ps1'), encoding='ascii').read()
_m = re.search(r"^\$Script:AppVersion\s*=\s*'(\d+\.\d+\.\d+)'", _head, re.M)
if not _m:
    sys.exit("$Script:AppVersion = 'X.Y.Z' not found in src/10_engine_head.ps1")
VERSION = _m.group(1)
FILENAME = f'Windows-ISO-updater-GUI_v{VERSION}.cmd'
OUT = os.path.join(ROOT, FILENAME)

v1 = open(os.path.join(SRC, 'engine_v1.ps1'), encoding='ascii').read().replace('\r\n', '\n').split('\n')

def rng(a, b):
    """1-based inclusive line range of the v1 engine."""
    return '\n'.join(v1[a - 1:b])

def edit(text, old, new, count=1):
    n = text.count(old)
    if n != count:
        sys.exit(f'edit failed ({n} matches, expected {count}): {old[:70]!r}')
    return text.replace(old, new)

# ---- kept regions of the v1 engine -----------------------------------------
settings = rng(162, 353)          # settings/state + process/DISM helpers
settings = edit(settings, "        LastDriverFolder = ''\n",
                "        LastDriverFolder = ''\n        SignCleanup      = $true\n        InstallOemDrivers = $false\n        SignOnlyThisPc   = $false\n        WinVersion       = '10'\n        UiTheme          = 'Dark'\n        UiZoom           = 100\n        UiFont           = 'Segoe UI'\n        SignIsolate      = $true\n        SignJobs         = 0\n        SignEngine       = 'makecat'\n        UiLanguage       = 'auto'\n        ParallelBoot     = $true\n        ParallelEditions = 0\n        BootSkipPE       = $false\n        DefenderExclude  = $false\n")
settings = edit(settings, "        Output   = Join-Path $w 'output'\n",
                "        Output   = Join-Path $w 'output'\n        Signed   = Join-Path $w 'signed'\n        Scratch  = Join-Path $w 'temp\\scratch'\n")
# servicing commands use a scratch folder inside the work folder (covered by the Defender option)
settings = edit(settings, "    $code = Invoke-Exe $Script:Dism ('/English /LogPath:' + (Q $Script:DismLog) + ' ' + $Arguments)",
                """    $sd = ''
    if ($Arguments -match '^/Image:' -and $Script:P -and $Script:P.Scratch) {
        New-Item -ItemType Directory -Force -Path $Script:P.Scratch | Out-Null
        $sd = ' /ScratchDir:' + (Q $Script:P.Scratch)
    }
    $code = Invoke-Exe $Script:Dism ('/English /LogPath:' + (Q $Script:DismLog) + $sd + ' ' + $Arguments)""")
settings = edit(settings, "        Updates = @(); Drivers = @(); Unattend = $null; Serviced = $null; Iso = $null\n",
                "        Updates = @(); Drivers = @(); Unattend = $null; Serviced = $null; Iso = $null\n"
                "        Oem = $null; Signed = @(); OemSynced = $false\n")
settings = edit(settings, "foreach ($k in 'Images', 'Selected', 'Updates', 'Drivers') {",
                "foreach ($k in 'Images', 'Selected', 'Updates', 'Drivers', 'Signed') {")
old_exe = rng(257, 261)
assert old_exe.startswith('function Invoke-Exe'), old_exe
settings = edit(settings, old_exe + '\n', '')          # replaced by the live-output version
settings = edit(settings, "use [C] Clean up in the menu first.", "use Clean up on the Options page first.")

# settings: the file name does not carry the version, so a new version keeps the options of the old one;
# the pre-3.4 name (Win10-ISO-Updater.settings.json) is read once when the new file does not exist yet
settings = edit(settings, """    if (Test-Path -LiteralPath $Script:SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $Script:SettingsFile -Raw | ConvertFrom-Json""",
"""    $sf = $Script:SettingsFile
    if (-not (Test-Path -LiteralPath $sf) -and $Script:LegacySettingsFile -and (Test-Path -LiteralPath $Script:LegacySettingsFile)) { $sf = $Script:LegacySettingsFile }
    if (Test-Path -LiteralPath $sf) {
        try {
            $j = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json""")
# a UNC work folder has no drive letter: say so instead of failing inside DriveInfo
settings = edit(settings, """    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($w))
    $drv = New-Object IO.DriveInfo($root)""",
"""    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($w))
    if ($root -notmatch '^[A-Za-z]:\\\\') { throw "The work folder must be on a local NTFS drive, not a network path ($w)." }
    $drv = New-Object IO.DriveInfo($root)""")

# v1 lines 401-431 (Resolve-Family), 508-537 (Find-Update, Find-ByKB) and 583-591 (Get-UpdateFiles)
# now live in src/38_engine_windows.ps1, with Windows 11 support
detect_catalog = rng(354, 400) + '\n' + rng(432, 507) + '\n' + rng(538, 582) + '\n#endregion'
detect_catalog = edit(detect_catalog, "if (-not $Script:S.Family -or @($Script:S.Images).Count -eq 0) { Invoke-Analyze }",
                      "if (-not $Script:S.Family -or -not $Script:S.Family.Os -or @($Script:S.Images).Count -eq 0) { Invoke-Analyze }")
detect_catalog = edit(detect_catalog,
    'Invoke-Exe $curl ("-L --fail --retry 3 --retry-delay 3 -C - --progress-bar -o $(Q $part) $(Q $Url)")',
    'Invoke-Exe $curl ("-L --fail --retry 3 --retry-delay 3 -C - --progress-bar -o $(Q $part) $(Q $Url)") -MergeErr')

unpack = rng(593, 645) + '\n#endregion'    # v1 lines 646-679 (Invoke-Analyze) now live in src/38_engine_windows.ps1
unpack = edit(unpack, """    if (-not $iso) {
        $start = if ($Script:S.SourceIso) { Split-Path $Script:S.SourceIso -Parent } else { Join-Path $env:USERPROFILE 'Downloads' }
        $iso = Select-FileDialog 'Select a Windows 10 ISO' 'ISO images (*.iso)|*.iso' $start
    }
""", '')
unpack = edit(unpack, "if (-not (Read-YesNo 'The work folder already has unpacked media. Replace it?' $true)) { return }",
              "if (-not $Script:NoAsk -and -not (Read-YesNo 'The work folder already has unpacked media. Replace it?' $true)) { return }")
unpack = edit(unpack, "    $Script:S.SourceIso = $iso\n", "    $prevIso = $Script:S.SourceIso\n    $Script:S.SourceIso = $iso\n")
unpack = edit(unpack, "    $Script:S.Selected  = @()\n", "    if ($prevIso -ne $iso) { $Script:S.Selected = @() }\n")
unpack = edit(unpack, "    $Script:S.Iso       = $null\n", "    $Script:S.Iso       = $null\n    $Script:S.OemSynced = $false\n")

# v1 lines 708-773 (download) now live in src/37_engine_download.ps1
detect_catalog = edit(detect_catalog, """        $name = [IO.Path]::GetFileName(([uri]$u).AbsolutePath)
        $dest = Join-Path $dir $name
        Save-Url $u $dest""", """        $name = [IO.Path]::GetFileName(([uri]$u).AbsolutePath)
        if ($Script:SavedFiles -and $Script:SavedFiles.ContainsKey($name.ToLower())) { Write-Info "Already included: $name"; continue }
        $dest = Join-Path $dir $name
        Save-Url $u $dest
        if ($Script:SavedFiles) { $Script:SavedFiles[$name.ToLower()] = $true }""")
drivers_a = rng(774, 836)        # INF parser, arch test, boot driver list
drivers_b = rng(909, 958)        # Get-DriverPackages, Find-DriverBackupFolders, Copy-Tree
drivers_b = edit(drivers_b, """        New-Item -ItemType Directory -Force -Path (Split-Path $Dest -Parent) | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Dest -Recurse -Force""", """        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Dest -Recurse -Force""")
unattend = rng(1103, 1138) + '\n#endregion'
# a non-numeric image INDEX in an answer file must not abort the analysis with a cast error
unattend = edit(unattend, """        if ($key -match '/IMAGE/INDEX' -and [int]$val -gt $img.Count) {""",
"""        $idx = 0
        if ($key -match '/IMAGE/INDEX' -and -not [int]::TryParse($val.Trim(), [ref]$idx)) {
            Write-Warn "autounattend.xml has an image INDEX that is not a number ('$val')."
        } elseif ($key -match '/IMAGE/INDEX' -and $idx -gt $img.Count) {""")
unattend = edit(unattend, "$_.ImageIndex -eq [int]$val })", "$_.ImageIndex -eq $idx })")

# v1 lines 1177-1419 (slipstream) now live in src/35_engine_service.ps1

# v1 lines 1420-1481 (ISO build) now live in src/36_engine_build.ps1

def part(name):
    return open(os.path.join(SRC, name), encoding='ascii').read().replace('\r\n', '\n').rstrip('\n')

# ---- SHA-256 of Microsoft's Windows ISOs (src/iso-hashes.json, collected by src/isohashes.py) become Get-KnownIsoHashes,
# one line per ISO "SHA256<TAB>product<TAB>label<TAB>first day listed".
def known_iso_hashes():
    known = json.load(open(os.path.join(SRC, 'iso-hashes.json'), encoding='utf-8'))
    esc = lambda v: ''.join(c if 32 <= ord(c) < 127 and c not in '&\t' else '&#x%X;' % ord(c) for c in v)
    lines = []
    for k in known:
        if not re.fullmatch(r'[0-9A-F]{64}', k['sha256']):
            sys.exit(f"iso-hashes.json: not a SHA-256: {k['sha256']!r}")
        lines.append('\t'.join([k['sha256'], esc(k['product']), esc(k['label']), k['listed']]))
    if len(set(l[:64] for l in lines)) != len(lines):
        sys.exit('iso-hashes.json: a SHA-256 is listed twice')
    return '\n'.join(['function Get-KnownIsoHashes {', "    return @'"] + lines + ["'@", '}'])

engine = '\n\n'.join([
    part('10_engine_head.ps1'),
    settings, detect_catalog, unpack, part('38_engine_windows.ps1'), part('37_engine_download.ps1'),
    part('29_engine_isocheck.ps1'), known_iso_hashes(),
    drivers_a, drivers_b, '#endregion', unattend, part('35_engine_service.ps1'), part('36_engine_build.ps1'),
    part('30_engine_tools.ps1'), part('31_engine_sign.ps1'), part('39_engine_catalogs.ps1'), part('33_engine_check.ps1'), part('34_engine_check2.ps1'), part('32_engine_jobs.ps1'),
])

# ---- interface languages: src/lang/<code>.json (English text -> translation, UTF-8) become Get-LangData,
# one line per text "English<TAB>translation", accented letters as &#xE9; so the .cmd stays ASCII.
sys.path.insert(0, os.path.join(SRC, 'lang'))
import keys as langkeys

def lang_data():
    ks = langkeys.keys()
    out = ['function Get-LangData([string]$Code) {', '    switch ($Code) {']
    for code in langkeys.LANGUAGES:
        t = langkeys.load(code)
        if not t:
            continue
        miss = [k for k in ks if k not in t]
        unused = [k for k in t if k not in ks]
        if miss:
            print(f'{code}: {len(miss)} of {len(ks)} texts not translated yet (shown in English) - python3 src/lang/keys.py --missing')
        if unused:
            print(f'{code}: {len(unused)} translation(s) for texts the interface no longer has: {unused[:3]}')
        esc = lambda v: ''.join(c if ord(c) < 128 else '&#x%X;' % ord(c) for c in v)
        lines = []
        for k in ks:
            if k in t:
                if '\t' in k + t[k] or '\n' in k + t[k]:
                    sys.exit(f'{code}: tab or line break in {k!r}')
                line = esc(k) + '\t' + esc(t[k])
                if line.startswith("'@"):
                    sys.exit(f'{code}: a line may not start with \'@: {k!r}')
                lines.append(line)
        out += [f"        '{code}' {{ return @'"] + lines + ["'@ }"]
    out += ['    }', "    return ''", '}']
    return '\n'.join(out)

pieces = [part('00_header.cmd'), engine]
for extra in ('40_gui_xaml.ps1', '45_gui_dialogs.ps1', '48_gui_lang.ps1', '50_gui.ps1', '55_gui_main.ps1'):
    if os.path.exists(os.path.join(SRC, extra)):
        pieces.append(part(extra))
    if extra == '48_gui_lang.ps1':
        pieces.append(lang_data())
text = '\n'.join(pieces) + '\n'
text = text.replace('@@VERSION@@', VERSION).replace('@@FILENAME@@', FILENAME)
if '@@' in text:
    sys.exit('unreplaced placeholder: ' + text[text.index('@@'):][:40])

bad = [(i + 1, l) for i, l in enumerate(text.split('\n')) if any(ord(c) > 127 for c in l)]
if bad:
    sys.exit(f'non-ASCII on line {bad[0][0]}: {bad[0][1][:80]}')

# one build in the repo root: drop older versions and the pre-3.4 file name
for old in glob.glob(os.path.join(ROOT, 'Windows-ISO-updater-GUI_v*.cmd')) + [os.path.join(ROOT, 'Win10-ISO-Updater.cmd')]:
    if os.path.exists(old) and os.path.abspath(old) != os.path.abspath(OUT):
        os.remove(old)
        print(f'removed {os.path.basename(old)}')
with open(OUT, 'wb') as f:
    f.write(text.replace('\n', '\r\n').encode('ascii'))
print(f'wrote {OUT}: {len(text.splitlines())} lines, {len(text)} chars')
