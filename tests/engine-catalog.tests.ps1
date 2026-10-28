param([string]$Engine)
$ErrorActionPreference = 'Stop'
$fails = 0
function Check($name, $cond) { if ($cond) { Write-Host "PASS $name" -ForegroundColor Green } else { Write-Host "FAIL $name" -ForegroundColor Red; $script:fails++ } }

# ---- 1. parse
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Engine, [ref]$tokens, [ref]$errs)
Check 'parse: no syntax errors' ($errs.Count -eq 0)
foreach ($e in $errs) { Write-Host "  $($e.Extent.StartLineNumber): $($e.Message)" }

# load every function definition without running main
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $funcs) { . ([scriptblock]::Create($f.Extent.Text)) }
Check "functions loaded ($($funcs.Count))" ($funcs.Count -gt 40)

# duplicate function names?
$dups = $funcs | Group-Object Name | Where-Object Count -gt 1
Check 'no duplicate function names' (-not $dups)

# every called Verb-Noun function that is ours exists
$defined = @($funcs | ForEach-Object Name)
$cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique
$missing = @($cmds | Where-Object { $_ -match '^(Invoke|Write|Read|Format|Limit|Test|Select|ConvertFrom|ConvertTo|Get|Import|Save|Initialize|New|Mount|Dismount|Add|Clear|Reset|Find|Search|Resolve|Assert|Show|Remove|Sync|Set|Export|Q)(-|$)' -and $defined -notcontains $_ -and -not (Get-Command $_ -ErrorAction SilentlyContinue) })
$winOnly = @('Get-WindowsImage', 'Export-WindowsDriver', 'Mount-DiskImage', 'Dismount-DiskImage', 'Get-DiskImage', 'Get-Volume', 'Start-BitsTransfer', 'Out-GridView', 'Get-AuthenticodeSignature', 'Set-AuthenticodeSignature', 'New-SelfSignedCertificate', 'Import-PfxCertificate', 'Export-PfxCertificate', 'Export-Certificate', 'Get-CimInstance', 'Get-MpPreference', 'Add-MpPreference', 'Remove-MpPreference')
$missing = @($missing | Where-Object { $winOnly -notcontains $_ })
Check "all called functions defined ($($missing -join ', '))" ($missing.Count -eq 0)

# ---- script-scope setup (Linux test host: fake the Windows env vars)
$env:SystemDrive = '/tmp'
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:BootClasses = @('SCSIAdapter', 'HDC', 'Net')
$Script:CatalogBase = 'https://www.catalog.update.microsoft.com'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('w10u_test_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $tmp | Out-Null
$Script:Cfg = Get-DefaultSettings
$Script:Cfg.WorkDir = $tmp
Initialize-Paths
$Script:StatusFile = Join-Path $tmp 'status.cmd'

# ---- 2. selection parser

# ---- 3. months
Check 'month list' ((@(Get-MonthList '2025-02' 3) -join ',') -eq '2025-02,2025-01,2024-12')

# ---- 4. family resolution
function img($b, $ed = 'Professional', $arch = 'x64') { [ordered]@{ Index = 1; Name = 'x'; Edition = $ed; Build = $b; Revision = 1; Version = "$b.1"; Arch = $arch; Size = 1; Langs = 'en-US' } }
$f = Resolve-Family @((img 19045))
Check '22H2 family' ($f.Product -eq 'Windows 10 Version 22H2' -and $f.Supported -and -not $f.NeedsEkb -and $f.Cap -eq '2025-10' -and $f.Label -eq 'W10_22H2_X64')
$f = Resolve-Family @((img 19044 'EnterpriseS'))
Check 'LTSC 2021 family' ($f.Product -eq 'Windows 10 Version 21H2' -and -not $f.NeedsEkb)
$f = Resolve-Family @((img 19044 'Professional'))
Check '21H2 Pro -> 22H2 + eKB' ($f.Product -eq 'Windows 10 Version 22H2' -and $f.NeedsEkb)
$f = Resolve-Family @((img 17763 'EnterpriseS'))
Check 'LTSC 2019 family, no cap' ($f.Product -eq 'Windows 10 Version 1809' -and -not $f.Cap)
$f = Resolve-Family @((img 26100))
Check 'Win11 24H2 family' ($f.Os -eq '11' -and $f.Product -eq 'Windows 11 Version 24H2' -and $f.Supported -and $f.NoSsu -and -not $f.Cap -and -not $f.NeedsEkb -and $f.Label -eq 'W11_24H2_X64' -and $f.Name -eq 'Windows 11 24H2')
$f = Resolve-Family @((img 26100 'IoTEnterpriseS'))
Check 'Win11 LTSC 2024' ($f.Name -eq 'Windows 11 LTSC 2024 (24H2)' -and $f.Product -eq 'Windows 11 Version 24H2')
$f = Resolve-Family @((img 26200))
Check 'Win11 25H2 family' ($f.Product -eq 'Windows 11 Version 25H2' -and $f.Supported)
$f = Resolve-Family @((img 22631))
Check 'Win11 23H2 family' ($f.Product -eq 'Windows 11 Version 23H2' -and -not $f.NeedsEkb)
$f = Resolve-Family @((img 22621))
Check 'Win11 22H2 -> 23H2 + enablement package' ($f.Product -eq 'Windows 11 Version 23H2' -and $f.NeedsEkb -and $f.EkbKB -eq 'KB5027397' -and $f.EkbFor -eq '23H2')
$f = Resolve-Family @((img 22000))
Check 'Win11 21H2: last updates 2024-10' ($f.Product -eq 'Windows 11 Version 21H2' -and $f.Cap -eq '2024-10')
$f = Resolve-Family @((img 26300))
Check 'unknown Win11 build: no automatic updates' (-not $f.Supported -and $f.Os -eq '11' -and $f.Name -eq 'Windows 11 (build 26300)')
$f = Resolve-Family @((img 26100 'Professional' 'arm64'))
Check 'Win11 ARM64 arch title' ($f.ArchTitle -eq 'ARM64-based Systems' -and $f.Label -eq 'W11_24H2_ARM64')
$f = Resolve-Family @((img 19044 'Professional'))
Check 'Win10 eKB names its KB' ($f.Os -eq '10' -and $f.EkbKB -eq 'KB5015684' -and $f.EkbFor -eq '22H2' -and -not $f.NoSsu)
Check 'OS of an old saved family (no Os key)' ((Get-FamilyOs ([ordered]@{ Build = 26100 })) -eq '11' -and (Get-FamilyOs ([ordered]@{ Build = 19045 })) -eq '10' -and (Get-FamilyOs $null) -eq '10')
$f = Resolve-Family @((img 19045 'Professional' 'x86'))
Check 'x86 arch title' ($f.ArchTitle -eq 'x86-based Systems' -and $f.ArchToken -eq 'x86')

# ---- 5. catalog HTML parsing (synthetic page built like the real one)
function Row($g, $title, $prod, $date, $size) {
@"
<tr id="${g}_R1">
  <td class="resultsbottomBorder resultspadding resultsIconWidth" id="${g}_C0_R1"></td>
  <td class="resultsbottomBorder resultspadding" id="${g}_C1_R1">
      <a id='${g}_link' href="javascript:void(0);" onclick='goToDetails("$g");' class="contentTextItemSpacerNoBreakLink">
          $title
      </a>
  </td>
  <td class="resultsbottomBorder resultspadding" id="${g}_C2_R1">
      $prod
  </td>
  <td class="resultsbottomBorder resultspadding" id="${g}_C3_R1">Security Updates</td>
  <td class="resultsbottomBorder resultspadding" id="${g}_C4_R1">$date</td>
  <td class="resultsbottomBorder resultspadding" id="${g}_C5_R1">n/a</td>
  <td class="resultsbottomBorder resultspadding" id="${g}_C6_R1"><span id="${g}_size">$size</span> <span style="display:none" id="${g}_originalSize">767144652</span></td>
  <td class="resultsbottomBorder resultspadding"><input id="$g" class="flatBlueButtonDownload focus-only" type="button" value='Download' /></td>
</tr>
"@
}
$g1 = '11111111-2222-3333-4444-555555555555'; $g2 = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; $g3 = '99999999-8888-7777-6666-555555555555'; $g4 = '12345678-1234-1234-1234-123456789abc'
$page = '<html><table id="ctl00_catalogBody_updateMatches"><tr id="headerRow"><td><a onclick="javascript:sort();">Title</a></td><td>Products</td></tr>' +
(Row $g1 '2025-10 Cumulative Update for Windows 10 Version 22H2 for x64-based Systems (KB5066791)' 'Windows 10, version 1903 and later' '10/14/2025' '731.6 MB') +
(Row $g2 '2025-10 Cumulative Update Preview for Windows 10 Version 22H2 for x64-based Systems (KB5066999)' 'Windows 10, version 1903 and later' '10/28/2025' '731.9 MB') +
(Row $g3 '2025-10 Cumulative Update for .NET Framework 3.5, 4.8 and 4.8.1 for Windows 10 Version 22H2 for x64 (KB5066743)' 'Windows 10, version 1903 and later' '10/14/2025' '80.1 MB') +
(Row $g4 '2025-10 Dynamic Update for Windows 10 Version 22H2 for x64-based Systems (KB5067000)' 'Windows Safe OS Dynamic Update' '10/14/2025' '9.0 MB') +
'</table></html>'
function Invoke-Web([string]$Uri, [string]$Method = 'GET', [string]$Body) { $script:lastUri = $Uri; return $script:page }
$res = @(Search-Catalog 'test query')
Check "catalog rows parsed (4)" ($res.Count -eq 4)
Check 'catalog title/KB' ($res[0].Title -eq '2025-10 Cumulative Update for Windows 10 Version 22H2 for x64-based Systems (KB5066791)' -and $res[0].KB -eq 'KB5066791')
Check 'catalog date' ($res[0].Date -eq [datetime]'2025-10-14')
Check 'catalog size from first span' ($res[0].Size -eq '731.6 MB')
Check 'catalog guid' ($res[0].Guid -eq $g1)
Check 'catalog products' ($res[3].Products -eq 'Windows Safe OS Dynamic Update')
Check 'query url-encoded' ($script:lastUri -like '*Search.aspx?q=test%20query')

# ---- 6. Find-Update filters (mock Search-Catalog per query)
$fam = Resolve-Family @((img 19045))
$script:hitsByMonth = @{}
function Search-Catalog([string]$Query) { $ym = $Query.Substring(0, 7); if ($script:hitsByMonth.ContainsKey($ym)) { return $script:hitsByMonth[$ym] } }
function MkHit($t, $p, $d) { [pscustomobject]@{ Guid = [guid]::NewGuid().ToString(); Title = $t; Products = $p; Classification = 'x'; Date = [datetime]$d; Size = '1 MB'; KB = ([regex]::Match($t, 'KB\d+')).Value } }
$script:hitsByMonth['2025-10'] = @(
    (MkHit '2025-10 Cumulative Update for Windows 10 Version 22H2 for x64-based Systems (KB5066791)' 'Windows 10' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update Preview for Windows 10 Version 22H2 for x64-based Systems (KB5066999)' 'Windows 10' '2025-10-28'),
    (MkHit '2025-10 Cumulative Update for Windows 10 Version 22H2 for x86-based Systems (KB5066791)' 'Windows 10' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update for Windows 10 Version 21H2 for x64-based Systems (KB5066791)' 'Windows 10' '2025-10-14'),
    (MkHit '2025-10 Dynamic Cumulative Update for Windows 10 Version 22H2 for x64-based Systems (KB5066791)' 'Windows 10' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update for .NET Framework 3.5, 4.8 and 4.8.1 for Windows 10 Version 22H2 for x64 (KB5066743)' 'Windows 10' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update for .NET Framework 3.5, 4.8 and 4.8.1 for Windows 10 Version 22H2 for ARM64 (KB5066743)' 'Windows 10' '2025-10-14'),
    (MkHit '2025-10 Dynamic Update for Windows 10 Version 22H2 for x64-based Systems (KB5067000)' 'Windows Safe OS Dynamic Update' '2025-10-14'),
    (MkHit '2025-10 Dynamic Update for Windows 10 Version 22H2 for x64-based Systems (KB5067001)' 'Windows 10 and later Dynamic Update' '2025-10-14')
)
$script:hitsByMonth['2025-08'] = @((MkHit '2025-08 Servicing Stack Update for Windows 10 Version 22H2 for x64-based Systems (KB5050000)' 'Windows 10' '2025-08-12'))
function Get-CatalogDescription([string]$Guid) { return '' }
$lcu = Find-Update 'LCU' $fam '2025-10' 3
Check 'LCU picks x64 22H2, not preview/x86/21H2/dynamic' ($lcu.KB -eq 'KB5066791' -and $lcu.Title -like '*22H2 for x64*' -and $lcu.Title -notlike '*Dynamic*' -and $lcu.Title -notlike '*Preview*')
$lcu2 = Find-Update 'LCU' $fam '2026-01' 4
Check 'LCU walks back months' ($lcu2.Title -like '2025-10*')
$net = @(Find-Update 'NET' $fam '2025-10' 2)
Check '.NET picks x64 only' ($net.Count -eq 1 -and $net[0].KB -eq 'KB5066743' -and $net[0].Title -like '*for x64 (*')
$safe = Find-Update 'SAFEOS' $fam '2025-10' 2
Check 'Safe OS DU via product' ($safe.KB -eq 'KB5067000')
$setup = Find-Update 'SETUP' $fam '2025-10' 2
Check 'Setup DU via product fallback' ($setup.KB -eq 'KB5067001')
$ssu = Find-Update 'SSU' $fam '2025-10' 6
Check 'SSU found 2 months back' ($ssu.KB -eq 'KB5050000')
$none = Find-Update 'SSU' $fam '2025-10' 1
Check 'nothing found -> null' ($null -eq $none)
function Search-Catalog([string]$Query) { return @(
        (MkHit 'Microsoft .NET Framework 4.8.1 for Windows 10 Version 21H2 for x64 (KB5011048)' 'x' '2022-08-09'),
        (MkHit 'Microsoft .NET Framework 4.8.1 for Windows 10 Version 22H2 for x64 (KB5011048)' 'x' '2022-10-11'),
        (MkHit 'Microsoft .NET Framework 4.8.1 for Windows 10 Version 22H2 for ARM64 (KB5011048)' 'x' '2022-10-11')) }
$n481 = Find-ByKB 'KB5011048' $fam '\b22H2\b'
Check '.NET 4.8.1 by KB picks 22H2 x64' ($n481.Title -eq 'Microsoft .NET Framework 4.8.1 for Windows 10 Version 22H2 for x64 (KB5011048)')

# ---- 6b. Windows 11 catalog titles
$script:hitsByMonth = @{}
function Search-Catalog([string]$Query) { $ym = $Query.Substring(0, 7); if ($script:hitsByMonth.ContainsKey($ym)) { return $script:hitsByMonth[$ym] } }
$script:hitsByMonth['2025-10'] = @(
    (MkHit '2025-10 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5066835)' 'Microsoft Server operating system-24H2' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5066835)' 'Windows 11' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5066835)' 'Windows 11' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update Preview for Windows 11 Version 24H2 for x64-based Systems (KB5067036)' 'Windows 11' '2025-10-28'),
    (MkHit '2025-10 Cumulative Update for Windows 11 Version 24H2 for arm64-based Systems (KB5066835)' 'Windows 11' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update for Windows 10 Version 22H2 for x64-based Systems (KB5066791)' 'Windows 10' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 24H2 for x64 (KB5066128)' 'Windows 11' '2025-10-14'),
    (MkHit '2025-10 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 24H2 for ARM64 (KB5066128)' 'Windows 11' '2025-10-14'),
    (MkHit '2025-10 Safe OS Dynamic Update for Windows 11 Version 24H2 for x64-based Systems (KB5067039)' 'Windows Safe OS Dynamic Update' '2025-10-14'),
    (MkHit '2025-10 Setup Dynamic Update for Windows 11 Version 24H2 for x64-based Systems (KB5067040)' 'Windows 11 GDR-DU' '2025-10-14'),
    (MkHit '2025-10 Dynamic Update for Windows 10 Version 22H2 for x64-based Systems (KB5067000)' 'Windows Safe OS Dynamic Update' '2025-10-14')
)
$f11 = Resolve-Family @((img 26100))
$lcu = Find-Update 'LCU' $f11 '2025-10' 1
Check 'Win11 LCU: 24H2 x64, not 25H2 / Server / preview / Windows 10' ($lcu.Title -eq '2025-10 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5066835)')
$lcu = Find-Update 'LCU' (Resolve-Family @((img 26200))) '2025-10' 1
Check 'Win11 25H2 LCU' ($lcu.Title -like '*Windows 11 Version 25H2 for x64*')
$lcu = Find-Update 'LCU' (Resolve-Family @((img 26100 'Professional' 'arm64'))) '2025-10' 1
Check 'Win11 ARM64 LCU (catalog writes arm64 in lower case)' ($lcu.Title -like '*24H2 for arm64-based*')
$net = @(Find-Update 'NET' $f11 '2025-10' 1)
Check 'Win11 .NET: "Windows 11, version 24H2" x64 only' ($net.Count -eq 1 -and $net[0].Title -like '*Windows 11, version 24H2 for x64 (*')
$safe = Find-Update 'SAFEOS' $f11 '2025-10' 1
Check 'Win11 Safe OS DU' ($safe.KB -eq 'KB5067039')
$setup = Find-Update 'SETUP' $f11 '2025-10' 1
Check 'Win11 Setup DU (not the Windows 10 one)' ($setup.KB -eq 'KB5067040')
$lcu = Find-Update 'LCU' $fam '2025-10' 1
Check 'Windows 10 family still picks the Windows 10 LCU' ($lcu.KB -eq 'KB5066791')
function Search-Catalog([string]$Query) { return @(
        (MkHit '2023-10 Feature Update to Windows 11 Version 23H2 for x64-based Systems (KB5027397)' 'Windows 11' '2023-10-31'),
        (MkHit '2023-10 Feature Update to Windows 11 Version 23H2 for arm64-based Systems (KB5027397)' 'Windows 11' '2023-10-31')) }
$f22 = Resolve-Family @((img 22621))
$ekb = Find-ByKB $f22.EkbKB $f22 $f22.EkbFor
Check 'Win11 23H2 enablement package by KB, x64' ($ekb.Title -like '*23H2 for x64-based*')

# ---- 6c. 24H2 checkpoint update goes in first
$cp = Join-Path $tmp 'LCU'; New-Item -ItemType Directory -Force $cp | Out-Null
$newer = Join-Path $cp ('windows11.0-kb5066835-x64_' + ('a' * 40) + '.msu'); $older = Join-Path $cp ('windows11.0-kb5043080-x64_' + ('b' * 40) + '.msu')
Set-Content $newer 'x'; Set-Content $older 'x'
$Script:S = New-State
$Script:S.Updates = @([ordered]@{ Kind = 'LCU'; KB = 'KB5066835'; Title = 't'; Date = '2025-10-14'; Files = @($newer, $older) })
$uf = Get-UpdateFiles
Check 'checkpoint (older KB) before the cumulative update' ((@($uf.LCU | ForEach-Object { Get-FileKB $_ }) -join ',') -eq '5043080,5066835')
Check 'KB from file name' ((Get-FileKB 'C:\u\windows10.0-kb5066791-x64_ab.msu') -eq 5066791 -and (Get-FileKB 'ssu.cab') -eq 0)

# ---- 6d. DISM for the image (Windows only services an image with the same or a newer DISM)
Check 'base builds' ((Get-BaseBuild 19045) -eq 19041 -and (Get-BaseBuild 22631) -eq 22621 -and (Get-BaseBuild 26200) -eq 26100 -and (Get-BaseBuild 17763) -eq 17763)
$script:builds = @{ 'C:\sys\dism.exe' = 19041; 'C:\adk\dism.exe' = 26100 }
function Get-DismBuild([string]$Exe) { return [int]$script:builds[$Exe] }
$script:adkPath = 'C:\adk\dism.exe'; $script:asked = 0; $script:installed = 0; $script:answer = $true
function Find-AdkDism { return $script:adkPath }
function Read-YesNo([string]$Question, [bool]$Default = $true) { $script:asked++; return $script:answer }
function Install-AdkDeploymentTools { $script:installed++; $script:adkPath = 'C:\adk\dism.exe'; return 0 }
$Script:Dism = 'C:\sys\dism.exe'
Check 'Windows 10 image on Windows 10: this PC''s DISM' ((Get-ServicingDism 19045) -eq 'C:\sys\dism.exe' -and (Get-ServicingDism 17763) -eq 'C:\sys\dism.exe')
Check 'Windows 11 image on Windows 10: the ADK''s DISM' ((Get-ServicingDism 26100) -eq 'C:\adk\dism.exe' -and (Get-ServicingDism 22631) -eq 'C:\adk\dism.exe')
$script:adkPath = $null
Check 'no ADK, no -Install: this PC''s DISM, nothing asked' ((Get-ServicingDism 26100) -eq 'C:\sys\dism.exe' -and $script:asked -eq 0)
$d = Get-ServicingDism 26100 -Install 3>$null
Check 'no ADK, -Install, yes: ADK installed and used' ($d -eq 'C:\adk\dism.exe' -and $script:asked -eq 1 -and $script:installed -eq 1)
$script:adkPath = $null; $script:answer = $false
$d = Get-ServicingDism 26100 -Install 3>$null
Check 'no ADK, -Install, no: this PC''s DISM, nothing installed' ($d -eq 'C:\sys\dism.exe' -and $script:installed -eq 1)
$script:builds['C:\sys\dism.exe'] = 26100
Check 'Windows 11 host: its own DISM for 23H2 and 25H2' ((Get-ServicingDism 22631) -eq 'C:\sys\dism.exe' -and (Get-ServicingDism 26200) -eq 'C:\sys\dism.exe')
$Script:Dism = 'C:\fake\dism'
Check 'DISM version unreadable (0): kept as it is' ((Get-ServicingDism 26100 -Install) -eq 'C:\fake\dism')

# ---- 7. download-link extraction
$script:page = @"
<script>var downloadInformation = new Array();
downloadInformation[0] = new Object();
downloadInformation[0].files = new Array();
downloadInformation[0].files[0] = new Object();
downloadInformation[0].files[0].url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/abc/public/windows10.0-kb5066791-x64_0123456789abcdef0123456789abcdef01234567.msu';
downloadInformation[0].files[1] = new Object();
downloadInformation[0].files[1].url = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/software/secu/2025/10/ndp481-kb5066743-x64_fedcba9876543210fedcba9876543210fedcba98.msu';
</script>
"@
$urls = @(Get-CatalogFileUrls $g1)
Check "download urls extracted ($($urls.Count))" ($urls.Count -eq 2 -and $urls[0] -like '*kb5066791*')

# ---- 8. sha1-in-filename integrity check
$fileBody = [Text.Encoding]::ASCII.GetBytes('hello catalog')
$sha1 = [BitConverter]::ToString([Security.Cryptography.SHA1]::Create().ComputeHash($fileBody)).Replace('-', '').ToLower()
$good = Join-Path $tmp "windows10.0-kb1-x64_$sha1.msu"; [IO.File]::WriteAllBytes($good, $fileBody)
$bad = Join-Path $tmp ('windows10.0-kb2-x64_' + ('0' * 40) + '.msu'); [IO.File]::WriteAllBytes($bad, $fileBody)
Check 'hash ok' (Test-CatalogHash $good)
Check 'hash mismatch detected' (-not (Test-CatalogHash $bad))
Check 'no hash in name -> ok' (Test-CatalogHash (Join-Path $tmp 'x.msu'))

# ---- 9. state round trip
$Script:S = New-State
$Script:S.SourceIso = 'C:\iso\Win10_22H2_English_x64v1 (1).iso'
$Script:S.Unpacked = $true
$Script:S.Images = @((img 19045))
$Script:S.Family = Resolve-Family $Script:S.Images
$Script:S.Selected = @(6)
$Script:S.Updates = @([ordered]@{ Kind = 'LCU'; KB = 'KB5066791'; Title = 't'; Date = '2025-10-14'; Files = @('C:\a.msu') })
$Script:S.Drivers = @([ordered]@{ Source = 'host'; Folder = 'host\nv'; Inf = 'nv.inf'; Class = 'Display'; Provider = 'NVIDIA'; Version = '1'; SizeMB = 900.5 },
    [ordered]@{ Source = 'host'; Folder = 'host\rst'; Inf = 'iaStorVD.inf'; Class = 'SCSIAdapter'; Provider = 'Intel'; Version = '1'; SizeMB = 2.1 })
Save-State
$Script:S = Import-State
Check 'state: Selected stays an array' ($Script:S.Selected -is [array] -and $Script:S.Selected.Count -eq 1 -and $Script:S.Selected[0] -eq 6)
Check 'state: Images entry readable' ($Script:S.Images[0].Build -eq 19045 -and $Script:S.Images.Count -eq 1)
Check 'state: Updates Files array' (@($Script:S.Updates[0].Files).Count -eq 1 -and $Script:S.Updates[0].Kind -eq 'LCU')
# second round trip must be stable (no {"value":..,"Count":..} wrappers)
Save-State; $Script:S = Import-State; Save-State
$json = Get-Content $Script:P.State -Raw
Check 'state: stable after 2 round trips' ($json -notmatch '"value"\s*:' -and $json -match '"Files":\s*\[' -and $json -match '"Selected":\s*\[')
$Script:S = Import-State
Check 'state: Files still a 1-item array' (@($Script:S.Updates[0].Files).Count -eq 1 -and $Script:S.Updates[0].Files[0] -eq 'C:\a.msu')
Check 'state: Family dict' ($Script:S.Family.Product -eq 'Windows 10 Version 22H2')
$uf = Get-UpdateFiles 3>$null 6>$null
Check 'update files: missing file skipped' (@($uf.LCU).Count -eq 0)

$bi = Get-BootDriverInfs
Check 'boot infs filtered by class (none exist on disk -> 0)' ($bi.Count -eq 0)

Remove-Item $tmp -Recurse -Force
Write-Host ''
if ($fails -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green } else { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 }
exit 0
