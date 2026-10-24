$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
$Script:Sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = '' })
$Script:SignTool = "$PSScriptRoot/fake/signtool"; $Script:S = @{}
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'w10u_t7'; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$tmp/Display.Driver", "$tmp/HDAudio" | Out-Null
Set-Content "$tmp/Display.Driver/nv_disp.inf" "[Version]`nCatalogFile=nv_disp.cat"; Set-Content "$tmp/Display.Driver/nv_disp.cat" 'nvcleanstall-selfsigned'
Set-Content "$tmp/HDAudio/hda.inf" "[Version]`nCatalogFile=hda.cat"; Set-Content "$tmp/HDAudio/hda.cat" 'signed-whql'
Check 'catalog signed by an untrusted certificate (NVCleanstall) -> untrusted' ((Get-InfState "$tmp/Display.Driver/nv_disp.inf") -eq 'untrusted')
Check 'valid catalog -> ok' ((Get-InfState "$tmp/HDAudio/hda.inf") -eq 'ok')
$res = Invoke-SignFolder $tmp ([pscustomobject]@{ Thumbprint = 'AB' }) "$PSScriptRoot/fake/inf2cat" $false
Check "untrusted package re-signed, valid one untouched (signed=$($res.Signed) untouched=$($res.Untouched) failed=$($res.Failed))" ($res.Signed -eq 1 -and $res.Untouched -eq 1 -and $res.Failed -eq 0)
$it = $null; while ($Script:Sync.Queue.TryDequeue([ref]$it)) { "  log: $($it[1])" }
Remove-Item $tmp -Recurse -Force
if ($fails) { exit 1 }
exit 0
