<#
    Runs every test suite against the PowerShell part of Windows-ISO-updater-GUI_vX.X.X.cmd (the one build in the repo root).

    Needs PowerShell 7 on Linux or macOS: the stand-ins for signtool.exe and Inf2Cat.exe
    in tests/fake are sh scripts. Nothing here touches DISM, WPF or a real Windows install -
    the window controls are plain objects and Windows PowerShell 5.1 behaviour
    (ConvertFrom-Json, stderr of console tools) is simulated where it matters.

        pwsh tests/run-tests.ps1
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$built = @(Get-ChildItem -LiteralPath $root -Filter 'Windows-ISO-updater-GUI_v*.cmd' -File)
if ($built.Count -ne 1) { throw "Expected exactly one Windows-ISO-updater-GUI_vX.X.X.cmd in $root (run python src/build.py), found $($built.Count)." }
$cmd  = [IO.File]::ReadAllText($built[0].FullName)
$i    = $cmd.IndexOf("`r`n#PS-BEGIN")
if ($i -lt 0) { throw "#PS-BEGIN not found in $($built[0].Name)" }
$body = Join-Path $here 'v2body.ps1'
[IO.File]::WriteAllText($body, $cmd.Substring($i + 2).Replace("`r`n", "`n"))
if (Get-Command chmod -ErrorAction SilentlyContinue) { chmod +x @('inf2cat', 'signtool', 'dism', 'makecat', 'expand', 'wsl', 'wslpath' | ForEach-Object { Join-Path $here "fake/$_" }) }

$suites = @(
    @{ File = 'engine-catalog.tests.ps1';        Args = @('-Engine', $body) }   # catalog parsing, families, state (v1 engine)
    @{ File = 'gui-engine.tests.ps1';            Args = @() }                   # log sink, live process output, signing, $OEM$
    @{ File = 'signing.tests.ps1';               Args = @() }                   # untrusted (NVCleanstall) catalogs, stderr handling
    @{ File = 'sign-speed.tests.ps1';            Args = @() }                   # isolated INF copies, parallel Inf2Cat, batched signing, time estimate
    @{ File = 'sign-engines.tests.ps1';          Args = @() }                   # MakeCat / libwdi-style / generate-cat-file, Inf2Cat fallback, engine choice
    @{ File = 'install-check.tests.ps1';         Args = @() }                   # install check findings + fixes
    @{ File = 'generator-answer-file.tests.ps1'; Args = @() }                   # a real autounattend-generator file
    @{ File = 'ui-refresh.tests.ps1';            Args = @() }                   # page refresh, check list, PS 5.1 JSON
    @{ File = 'theme.tests.ps1';                 Args = @() }                   # dark / light theme (XAML, palette, contrast), text size, font
    @{ File = 'lang.tests.ps1';                  Args = @() }                   # interface languages: every text translated, placeholders, switching
    @{ File = 'service.tests.ps1';               Args = @() }                   # boot.wim in the background, driver set, Defender option
    @{ File = 'output-path.tests.ps1';           Args = @() }                   # output ISO path from the Build page
    @{ File = 'build.tests.ps1';                 Args = @() }                   # ISO build: .part file, old ISO kept, ISO in use, free space
    @{ File = 'download.tests.ps1';              Args = @() }                   # servicing stack lookup in a side job while the rest downloads
    @{ File = 'isocheck.tests.ps1';              Args = @() }                   # SHA-256 of the ISO against Microsoft's lists, page 1, check before unpacking
)
$failed = @()
foreach ($s in $suites) {
    Write-Host ''
    Write-Host "=== $($s.File)" -ForegroundColor Cyan
    $out = & pwsh -NoProfile -File (Join-Path $here $s.File) @($s.Args) 2>&1 | ForEach-Object { "$_" }
    $out | Where-Object { $_ -notmatch '^PASS ' } | ForEach-Object { Write-Host "  $_" }
    $pass = @($out | Where-Object { $_ -match '^PASS ' }).Count
    if ($LASTEXITCODE -ne 0 -or @($out | Where-Object { $_ -cmatch '^FAIL |\bFAILED\b' }).Count) { $failed += $s.File; Write-Host "  -> FAILED ($pass checks passed)" -ForegroundColor Red }
    else { Write-Host "  -> ok ($pass checks passed)" -ForegroundColor Green }
}
Remove-Item -LiteralPath $body -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($failed.Count) { Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'All test suites passed.' -ForegroundColor Green
