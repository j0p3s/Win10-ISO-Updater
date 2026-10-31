$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$Script:(X(Main|Pages)|IsoHashUA|Inv)$'}, $true)) { . ([scriptblock]::Create($a.Extent.Text)) }
function New-Brush([string]$Hex) { $Hex }
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'w10u_isocheck'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory $tmp | Out-Null
$Script:SettingsFile = Join-Path $tmp 's.json'; $env:SystemDrive = $tmp; $env:SystemRoot = $tmp
$Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = Join-Path $tmp 'work'; Initialize-Paths
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = '' })
$Script:S = New-State

# ---- the "Verify your download" table of Microsoft's pages
$row = { param($l, $h) "<tr><td>$l</td><td>$h</td></tr>" }
$h1 = 'a' * 64; $h2 = 'B' * 64
$html = "<h2>Windows 11 (multi-edition ISO for x64 devices)</h2><p>Version 26H2</p><table><tr><th>Language</th><th>Hash</th></tr>" +
        (& $row 'English International' $h1) + "`n<tr>`n  <td>Portuguese (Brazil)</td>`n  <td> $h2 </td>`n</tr>" + (& $row 'Chinese &amp; Test' ('c' * 63)) + '</table>'
$rows = @(Read-IsoHashPage $html @{ Name = 'Windows 11'; Arch = 'x64' })
Check "table rows read ($($rows.Count))" ($rows.Count -eq 2)
Check 'SHA-256 in capitals, label and product with the version' ($rows[0].Sha256 -ceq ('A' * 64) -and $rows[0].Label -eq 'English International' -and $rows[0].Product -eq 'Windows 11 26H2' -and $rows[1].Label -eq 'Portuguese (Brazil)')
$arm = @(Read-IsoHashPage $html @{ Name = 'Windows 11'; Arch = 'Arm64' })
Check 'Arm64 page named as such' ($arm[0].Product -eq 'Windows 11 26H2 Arm64')
Check 'page without a table: no rows' (@(Read-IsoHashPage '<html>Download Windows 10 with the Media Creation Tool</html>' @{ Name = 'Windows 10'; Arch = '' }).Count -eq 0)
$rr = @(Read-IsoHashPage ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/ms-windows11-hashes.html'))) @{ Name = 'Windows 11'; Arch = 'x64' })
Check "Microsoft's own markup: $($rr.Count) rows, $($rr[0].Product) - $($rr[0].Label)" ($rr.Count -eq 4 -and $rr[0].Product -eq 'Windows 11 26H2' -and $rr[0].Label -eq 'Arabic 64-bit' -and $rr[0].Sha256 -eq 'A75AE3F36CB9FFFFEDCB2D7DED9CEF83FFB710EB1376610D2220684D987CB9A5')
Check "Microsoft's own markup: the values are in the built-in list" (@($rr | Where-Object { (Get-Content -LiteralPath (Join-Path $root 'src/iso-hashes.json') -Raw) -notmatch $_.Sha256 }).Count -eq 0)

# ---- the list built into the .cmd from src/iso-hashes.json
$json = Get-Content -LiteralPath (Join-Path $root 'src/iso-hashes.json') -Raw | ConvertFrom-Json
$known = @(Get-KnownIsoHashList)
Check "built-in list: $($known.Count) ISOs, as in iso-hashes.json" ($known.Count -eq @($json).Count -and $known.Count -gt 100)
Check 'built-in list: every value a SHA-256, each once' (@($known | Where-Object { $_.Sha256 -notmatch '^[0-9A-F]{64}$' }).Count -eq 0 -and @($known.Sha256 | Sort-Object -Unique).Count -eq $known.Count)
$j0 = @($json)[0]
$k0 = $known | Where-Object { $_.Sha256 -eq $j0.sha256 }
Check "built-in list keeps product, label and date ($($k0.Product) - $($k0.Label) - $($k0.Listed))" ($k0.Product -eq $j0.product -and $k0.Label -eq $j0.label -and $k0.Listed -eq $j0.listed)
Check 'built-in list: Windows 10 and Windows 11 (x64 and Arm64)' (@($known | Where-Object Product -like 'Windows 10*').Count -gt 0 -and @($known | Where-Object Product -like 'Windows 11*Arm64').Count -gt 0 -and @($known | Where-Object { $_.Product -like 'Windows 11*' -and $_.Product -notlike '*Arm64' }).Count -gt 0)

# ---- SHA-256 of a file, read in parts, with progress
$isoA = Join-Path $tmp 'Win11_26H2_English_x64.iso'
$bytes = New-Object byte[] (9MB + 12345); (New-Object Random 7).NextBytes($bytes); [IO.File]::WriteAllBytes($isoA, $bytes)
$Script:Sync.Pct = -1
$shaA = Get-FileSha256 $isoA
Check 'SHA-256 as Get-FileHash' ($shaA -eq (Get-FileHash -LiteralPath $isoA -Algorithm SHA256).Hash)
Check 'progress reaches 100%' ($Script:Sync.Pct -eq 100)
Check 'SHA-256 of an empty file' ((Get-FileSha256 ((New-Item (Join-Path $tmp 'empty.iso') -ItemType File).FullName)) -eq 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855')

# ---- names of Visual Studio subscription / Volume Licensing downloads
Check 'subscription names recognised' ((Test-SubscriptionIsoName 'en-us_windows_10_consumer_editions_version_22h2_updated_oct_2025_x64_dvd_1a2b3c4d.iso') -and
    (Test-SubscriptionIsoName 'pt-pt_windows_11_business_editions_version_25h2_x64_dvd_0f0f0f0f.iso') -and (Test-SubscriptionIsoName 'SW_DVD9_Win_Pro_11_25H2_64BIT_English_Pro_Ent_EDU_N_MLF_X24-00000.ISO'))
Check 'download page names are not' (-not (Test-SubscriptionIsoName 'Win10_22H2_English_x64v1.iso') -and -not (Test-SubscriptionIsoName 'Win11_25H2_EnglishInternational_x64.iso') -and -not (Test-SubscriptionIsoName 'Windows.iso'))

# ---- the check: built-in list first, microsoft.com when not there, the result kept with the file's size and date
$isoB = Join-Path $tmp 'Win10_22H2_English_x64v1.iso'; $b2 = New-Object byte[] 70000; (New-Object Random 8).NextBytes($b2); [IO.File]::WriteAllBytes($isoB, $b2)
$isoC = Join-Path $tmp 'en-us_windows_11_consumer_editions_version_25h2_x64_dvd_89abcdef.iso'; [IO.File]::WriteAllBytes($isoC, [byte[]](1..200))
$shaB = (Get-FileHash -LiteralPath $isoB -Algorithm SHA256).Hash; $shaC = (Get-FileHash -LiteralPath $isoC -Algorithm SHA256).Hash
$keepKnown = ${function:Get-KnownIsoHashes}
function Get-KnownIsoHashes { "$($shaA)`tWindows 11 26H2`tEnglish International`t2026-10-31`n" + ('D' * 64) + "`tWindows 10 22H2`tFran&#xE7;ais 64-bit`t2025-09-01" }
Check 'built-in list: accented labels decoded' ((@(Get-KnownIsoHashList)[1].Label) -eq "Fran$([char]0xE7)ais 64-bit")
$Script:Web = @{ Calls = 0; Mode = 'ok'; Pages = @{} }
function Invoke-WebRequest {
    param($Uri, [switch]$UseBasicParsing, $UserAgent, $TimeoutSec, $Headers)
    $Script:Web.Calls++; $Script:Web.UA = $UserAgent
    if ($Script:Web.Mode -eq 'offline') { throw 'The remote name could not be resolved' }
    return [pscustomobject]@{ Content = [string]$Script:Web.Pages[[string]$Uri] }
}
$hashCalls = 0
$Script:RealHash = ${function:Get-FileSha256}
function Get-FileSha256([string]$Path) { $script:hashCalls++; & $Script:RealHash $Path }

$r = Test-IsoOriginal $isoA
Check "in the built-in list: original, microsoft.com not needed ($($r.Product) - $($r.Label))" ($r.Status -eq 'original' -and $r.Source -eq 'list' -and $null -eq $r.Online -and $Script:Web.Calls -eq 0 -and $r.Product -eq 'Windows 11 26H2' -and $r.Sha256 -eq $shaA)
$Script:S = Import-State
Check 'result kept in the state' ($Script:S.IsoCheck.Status -eq 'original' -and $Script:S.IsoCheck.Sha256 -eq $shaA -and $Script:S.IsoCheck.Path -eq (Get-Item $isoA).FullName)
$n = $hashCalls
$r = Test-IsoOriginal $isoA
Check 'checked again: the ISO is not read again' ($hashCalls -eq $n -and $r.Status -eq 'original')
(Get-Item $isoA).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-1)
$r = Test-IsoOriginal $isoA
Check 'a changed file (date) is read again' ($hashCalls -eq $n + 1 -and $r.Status -eq 'original')

$pages = @(Get-IsoHashPages)
$Script:Web.Pages = @{ $pages[0].Url = "Version 26H2 " + (& $row 'English' $h1); $pages[1].Url = "Version 26H2 " + (& $row 'English' $h2); $pages[2].Url = "Version 22H2 " + (& $row 'English 64-bit' $shaB.ToLower()) }
$r = Test-IsoOriginal $isoB
Check "not in the list, on microsoft.com: original ($($r.Product) - $($r.Label))" ($r.Status -eq 'original' -and $r.Source -eq 'microsoft.com' -and $r.Online -eq $true -and $r.Product -eq 'Windows 10 22H2' -and $r.Label -eq 'English 64-bit' -and $Script:Web.Calls -eq 3)
Check 'microsoft.com read as a browser that is not on Windows (the Windows 10 page lists the ISOs only then)' ($Script:Web.UA -notmatch 'Windows')

$Script:Web.Calls = 0
$r = Test-IsoOriginal $isoC
Check 'nowhere: unknown, pages were read' ($r.Status -eq 'unknown' -and $r.Online -eq $true -and $Script:Web.Calls -eq 3 -and $r.Sha256 -eq $shaC)
Check 'subscription download recognised by its name' ($r.Subscription -eq $true)
$log = @(); $item = $null; while ($Script:Sync.Queue.TryDequeue([ref]$item)) { $log += [string]$item[1] }
Check 'log: advice to download an original ISO' (@($log | Where-Object { $_ -match 'download an original Windows 10 or 11 ISO' }).Count -eq 1 -and @($log | Where-Object { $_ -match 'Visual Studio subscription' }).Count -eq 1)

$Script:Web.Mode = 'offline'
(Get-Item $isoC).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-2)
$n = $hashCalls
$r = Test-IsoOriginal $isoC
Check 'offline: unknown, Online false' ($r.Status -eq 'unknown' -and $r.Online -eq $false -and $hashCalls -eq $n + 1)
$Script:Web.Mode = 'ok'
$Script:Web.Pages[$pages[1].Url] = "Version 25H2 " + (& $row 'English' $shaC)
$r = Test-IsoOriginal $isoC
Check 'online again: found, without reading the ISO again' ($r.Status -eq 'original' -and $r.Product -eq 'Windows 11 25H2 Arm64' -and $hashCalls -eq $n + 1)
$Script:Web.Pages = @{}
$Script:S.IsoCheck = $null
$r = Test-IsoOriginal $isoB
$fl = @(Get-MicrosoftIsoHashes)
Check 'pages without a table count as not read' ($r.Status -eq 'unknown' -and $r.Online -eq $false -and $fl[0].Read -eq 0 -and @($fl[0].Failed).Count -eq 3)

# ---- the job
$Script:Web.Pages[$pages[2].Url] = "Version 22H2 " + (& $row 'English 64-bit' $shaB)
$Script:Sync.Result = $null
$env:SystemRoot = $tmp
Save-Settings
function Get-ServicingDism { 'dism.exe' }
function Disable-DefenderSkip { }
function Enable-DefenderSkip { $Script:DefenderOn = $true }
Invoke-Job 'CheckIso' @{ Iso = $isoB }
Check 'CheckIso job: result handed back, no Defender exclusion' ($Script:Sync.Result.Status -eq 'original' -and -not $Script:DefenderOn)
$resB = $Script:Sync.Result

# ---- page 1
$x = $Script:XMain.Replace('__PAGES__', $Script:XPages)
$Script:U = @{}
foreach ($m in [regex]::Matches($x, 'x:Name="([^"]+)"')) { $Script:U[$m.Groups[1].Value] = [pscustomobject]@{ Text=''; Foreground=$null; Visibility=''; IsChecked=$false; Content='' } }
Check 'page 1: SHA-256 button, result and hash box' ($Script:U.ContainsKey('IsoCheckBtn') -and $Script:U.ContainsKey('IsoCheckText') -and $Script:U.ContainsKey('IsoCheckNote') -and $Script:U.ContainsKey('IsoHashBox') -and $Script:U.ContainsKey('IsoCheckPanel'))
Check 'page 1: explains the check' ($Script:XPages -match 'its SHA-256 is compared with the ones Microsoft publishes')
$Script:S = Import-State
$Script:U.IsoBox.Text = Join-Path $tmp 'missing.iso'
Update-IsoCheck
Check 'no file: nothing shown' ($Script:U.IsoCheckPanel.Visibility -eq 'Collapsed')
$Script:U.IsoBox.Text = $isoA
Update-IsoCheck
Check 'another ISO than the one checked: not checked yet' ($Script:U.IsoCheckPanel.Visibility -eq 'Visible' -and $Script:U.IsoCheckText.Text -like 'SHA-256 not checked yet*' -and $Script:U.IsoHashBox.Visibility -eq 'Collapsed')
$Script:U.IsoBox.Text = "`"$isoB`""
Update-IsoCheck
Check "original: green, product and SHA-256 ($($Script:U.IsoCheckText.Text))" ($Script:U.IsoCheckText.Text -eq 'Original Microsoft ISO: Windows 10 22H2 - English 64-bit' -and $Script:U.IsoCheckText.Foreground -eq '#3DDC97' -and $Script:U.IsoHashBox.Text -eq $shaB -and $Script:U.IsoHashBox.Visibility -eq 'Visible' -and $Script:U.IsoCheckNote.Text -like "*download page (checked *")
$Script:Web.Mode = 'offline'
$Script:S.IsoCheck = $null; $resC = Test-IsoOriginal $isoC; $Script:S = Import-State
$Script:U.IsoBox.Text = $isoC
$Script:Cfg.WinVersion = '11'
Update-IsoCheck
$note = $Script:U.IsoCheckNote.Text
Check 'not verified: yellow, with the advice' ($Script:U.IsoCheckText.Text -like 'Not verified*' -and $Script:U.IsoCheckText.Foreground -eq '#FFC857' -and $note -match 'download an original Windows 11 ISO from Microsoft')
Check 'advice: offline and subscription download' ($note -match 'could not be reached' -and $note -match 'Visual Studio subscription')
$Script:LangNow = 'pt'
Update-IsoCheck
Check "advice translated ($($Script:U.IsoCheckText.Text))" ($Script:U.IsoCheckText.Text -like 'N*o verificada*' -and $Script:U.IsoCheckNote.Text -match 'transfira uma ISO original do Windows 11')
$Script:LangNow = 'en'

# ---- Unpack / Run everything: the check first, a question for an ISO Microsoft does not list
$Script:Jobs = @()
function Start-Work($Job, $A, $Then) { $Script:Jobs += $Job; $Script:LastA = $A; $Script:LastThen = $Then }
$Script:Answer = $false; $Script:Asked = @()
function Confirm-Ui($Text, $Icon) { $Script:Asked += $Text; return $Script:Answer }
function Show-Msg($Text) { $Script:Shown = $Text }
$Script:IsoAccepted = @{}
$Script:S.Unpacked = $false
$Script:S.IsoCheck = $resB
$Script:U.IsoBox.Text = $isoB
Invoke-UnpackClick
Check 'original ISO already checked: unpacked at once' (($Script:Jobs -join ',') -eq 'Unpack' -and $Script:LastA.Iso -eq $isoB -and $Script:Asked.Count -eq 0)
$Script:Jobs = @()
$Script:S.IsoCheck = $resC
$Script:U.IsoBox.Text = $isoC
Invoke-UnpackClick
Check 'ISO not verified yet: the check runs first' (($Script:Jobs -join ',') -eq 'CheckIso' -and $Script:LastA.Iso -eq $isoC)
& $Script:LastThen
Check 'not verified, answer No: not unpacked' (($Script:Jobs -join ',') -eq 'CheckIso' -and $Script:Asked.Count -eq 1 -and $Script:Asked[0] -match 'Unpack this ISO anyway\?' -and $Script:Asked[0] -match 'download an original')
$Script:Answer = $true
Invoke-UnpackClick
& $Script:LastThen
Check 'answer Yes: unpacked' (($Script:Jobs -join ',') -eq 'CheckIso,CheckIso,Unpack' -and $Script:LastA.Iso -eq $isoC)
$Script:Jobs = @(); $Script:Asked = @()
Invoke-UnpackClick
Check 'asked once per ISO while the program is open' (($Script:Jobs -join ',') -eq 'Unpack' -and $Script:Asked.Count -eq 0)

$Script:Jobs = @(); $Script:Asked = @(); $Script:IsoAccepted = @{}
$Script:U.OutBox = [pscustomobject]@{ Text = '' }
Invoke-RunAllClick
& $Script:LastThen
Check 'Run everything: check, question, then the run' (($Script:Jobs -join ',') -eq 'CheckIso,All' -and $Script:Asked.Count -eq 2 -and $Script:Asked[1] -match 'Run everything with this ISO anyway\?')
$Script:Jobs = @(); $Script:Asked = @()
$Script:S.Unpacked = $true; $Script:S.SourceIso = $isoA; $Script:S.Serviced = $null
$Script:U.IsoBox.Text = $isoA
Invoke-RunAllClick
Check 'Run everything on media already unpacked from that ISO: no check' (($Script:Jobs -join ',') -eq 'All')
$Script:Jobs = @()
$Script:U.IsoBox.Text = $isoC
Invoke-IsoCheckClick
Check 'Check SHA-256 button: only the check' (($Script:Jobs -join ',') -eq 'CheckIso' -and $null -eq $Script:LastThen)

Set-Item Function:\Get-KnownIsoHashes -Value $keepKnown
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($fails) { Microsoft.PowerShell.Utility\Write-Host "$fails FAILED"; exit 1 }
