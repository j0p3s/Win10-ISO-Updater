"""Assembles Win10-ISO-Updater.cmd (single file) from src/ parts + the v1.1 engine."""
import os, sys

SRC = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(SRC), 'Win10-ISO-Updater.cmd')

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
                "        LastDriverFolder = ''\n        SignCleanup      = $true\n        InstallOemDrivers = $false\n        SignOnlyThisPc   = $false\n        ParallelBoot     = $true\n        BootSkipPE       = $false\n        DefenderExclude  = $false\n")
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

detect_catalog = rng(354, 592)
detect_catalog = edit(detect_catalog,
    'Invoke-Exe $curl ("-L --fail --retry 3 --retry-delay 3 -C - --progress-bar -o $(Q $part) $(Q $Url)")',
    'Invoke-Exe $curl ("-L --fail --retry 3 --retry-delay 3 -C - --progress-bar -o $(Q $part) $(Q $Url)") -MergeErr')

unpack = rng(593, 680)
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

download = rng(708, 773)
download = edit(download, "    $records = @()\n", "    $records = @()\n    $Script:SavedFiles = @{}\n")
download = edit(download, 'ESU cutoff - change it in Options if you want to experiment', 'ESU cutoff - change it on the Windows updates page if you want to experiment')
detect_catalog = edit(detect_catalog, """        $name = [IO.Path]::GetFileName(([uri]$u).AbsolutePath)
        $dest = Join-Path $dir $name
        Save-Url $u $dest""", """        $name = [IO.Path]::GetFileName(([uri]$u).AbsolutePath)
        if ($Script:SavedFiles -and $Script:SavedFiles.ContainsKey($name.ToLower())) { Write-Info "Already included: $name"; continue }
        $dest = Join-Path $dir $name
        Save-Url $u $dest
        if ($Script:SavedFiles) { $Script:SavedFiles[$name.ToLower()] = $true }""")
detect_catalog = edit(detect_catalog, """            if (Test-Path -LiteralPath $f) { $h[$u.Kind] += $f } else { Write-Warn "Missing $f - run Download again." }""", """            if (-not (Test-Path -LiteralPath $f)) { Write-Warn "Missing $f - run Download again."; continue }
            $leaf = (Split-Path $f -Leaf).ToLower()
            if ($seenLeaf.ContainsKey($leaf)) { continue }
            $seenLeaf[$leaf] = $true
            $h[$u.Kind] += $f""")
detect_catalog = edit(detect_catalog, """    $h = @{ SSU = @(); LCU = @(); EKB = @(); SAFEOS = @(); SETUP = @(); NET = @(); NET481 = @() }""", """    $h = @{ SSU = @(); LCU = @(); EKB = @(); SAFEOS = @(); SETUP = @(); NET = @(); NET481 = @() }
    $seenLeaf = @{}""")
drivers_a = rng(774, 836)        # INF parser, arch test, boot driver list
drivers_b = rng(909, 958)        # Get-DriverPackages, Find-DriverBackupFolders, Copy-Tree
drivers_b = edit(drivers_b, """        New-Item -ItemType Directory -Force -Path (Split-Path $Dest -Parent) | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Dest -Recurse -Force""", """        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Dest -Recurse -Force""")
unattend = rng(1103, 1138) + '\n#endregion'

# v1 lines 1177-1419 (slipstream) now live in src/35_engine_service.ps1

# v1 lines 1420-1481 (ISO build) now live in src/36_engine_build.ps1

def part(name):
    return open(os.path.join(SRC, name), encoding='ascii').read().replace('\r\n', '\n').rstrip('\n')

engine = '\n\n'.join([
    part('10_engine_head.ps1'),
    settings, detect_catalog, unpack, download,
    drivers_a, drivers_b, '#endregion', unattend, part('35_engine_service.ps1'), part('36_engine_build.ps1'),
    part('30_engine_tools.ps1'), part('31_engine_sign.ps1'), part('33_engine_check.ps1'), part('34_engine_check2.ps1'), part('32_engine_jobs.ps1'),
])

pieces = [part('00_header.cmd'), engine]
for extra in ('40_gui_xaml.ps1', '45_gui_dialogs.ps1', '50_gui.ps1', '55_gui_main.ps1'):
    if os.path.exists(os.path.join(SRC, extra)):
        pieces.append(part(extra))
text = '\n'.join(pieces) + '\n'

bad = [(i + 1, l) for i, l in enumerate(text.split('\n')) if any(ord(c) > 127 for c in l)]
if bad:
    sys.exit(f'non-ASCII on line {bad[0][0]}: {bad[0][1][:80]}')
with open(OUT, 'wb') as f:
    f.write(text.replace('\n', '\r\n').encode('ascii'))
print(f'wrote {OUT}: {len(text.splitlines())} lines, {len(text)} chars')
