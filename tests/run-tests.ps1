<#
    Runs every test suite against the PowerShell part of Win10-ISO-Updater.cmd.

    Needs PowerShell 7 on Linux or macOS: the stand-ins for signtool.exe and Inf2Cat.exe
    in tests/fake are sh scripts. Nothing here touches DISM, WPF or a real Windows install -
    the window controls are plain objects and Windows PowerShell 5.1 behaviour
    (ConvertFrom-Json, stderr of console tools) is simulated where it matters.

        pwsh tests/run-tests.ps1
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
$cmd  = [IO.File]::ReadAllText((Join-Path $root 'Win10-ISO-Updater.cmd'))
$i    = $cmd.IndexOf("`r`n#PS-BEGIN")
if ($i -lt 0) { throw '#PS-BEGIN not found in Win10-ISO-Updater.cmd' }
$body = Join-Path $here 'v2body.ps1'
[IO.File]::WriteAllText($body, $cmd.Substring($i + 2).Replace("`r`n", "`n"))
if (Get-Command chmod -ErrorAction SilentlyContinue) { chmod +x (Join-Path $here 'fake/inf2cat') (Join-Path $here 'fake/signtool') }

$suites = @(
    @{ File = 'engine-catalog.tests.ps1';        Args = @('-Engine', $body) }   # catalog parsing, families, state (v1 engine)
    @{ File = 'gui-engine.tests.ps1';            Args = @() }                   # log sink, live process output, signing, $OEM$
    @{ File = 'signing.tests.ps1';               Args = @() }                   # untrusted (NVCleanstall) catalogs, stderr handling
    @{ File = 'install-check.tests.ps1';         Args = @() }                   # install check findings + fixes
    @{ File = 'generator-answer-file.tests.ps1'; Args = @() }                   # a real autounattend-generator file
    @{ File = 'ui-refresh.tests.ps1';            Args = @() }                   # page refresh, check list, PS 5.1 JSON
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
