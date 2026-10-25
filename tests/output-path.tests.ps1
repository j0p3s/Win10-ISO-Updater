$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'w10u_out'; New-Item -ItemType Directory -Force "$tmp/output", "$tmp/isos" | Out-Null
$def = Join-Path $tmp 'output/Win10_22H2_19045.6456_x64_20261025.iso'
function Fails($w) { try { [void](Resolve-OutIso $w $def); return $false } catch { "  error: $($_.Exception.Message)"; return $true } }
Check 'empty -> default' ((Resolve-OutIso '  ' $def) -eq $def)
Check 'bare name -> output folder + .iso' ((Resolve-OutIso 'MyWin10' $def) -eq (Join-Path $tmp 'output/MyWin10.iso'))
Check 'existing folder -> default file name inside it' ((Resolve-OutIso "$tmp/isos" $def) -eq (Join-Path $tmp 'isos/Win10_22H2_19045.6456_x64_20261025.iso'))
Check 'folder with trailing slash -> default name' ((Resolve-OutIso "$tmp/new/" $def) -eq (Join-Path $tmp 'new/Win10_22H2_19045.6456_x64_20261025.iso'))
Check 'full path kept, quotes removed' ((Resolve-OutIso "`"$tmp/isos/A.iso`"" $def) -eq (Join-Path $tmp 'isos/A.iso'))
Check 'wildcards rejected with a clear message' (Fails "$tmp/isos/a*b.iso")
Check 'colon inside the name rejected' (Fails "$tmp/isos/Win10: custom.iso")
Remove-Item $tmp -Recurse -Force
if ($fails) { exit 1 }
exit 0
