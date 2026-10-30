$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
# the XAML strings and the theme tables (script-level assignments of the GUI part)
function Test-TopLevel($n) { for ($p = $n.Parent; $p; $p = $p.Parent) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false } }; return $true }
foreach ($a in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '^\$Script:(X(Res|Main|Pages|Picker|Pass)|LightColors|ThemeProps|ThemeKeys|ThemeNow)$' -and (Test-TopLevel $n)}, $true)) { . ([scriptblock]::Create($a.Extent.Text)) }
$gui = [IO.File]::ReadAllText("$PSScriptRoot/v2body.ps1")

# ---- the XAML stays well-formed and every brush colour becomes a theme resource
$wins = @{ Main = $Script:XMain; Picker = $Script:XPicker; Pass = $Script:XPass }
$keys = @()
foreach ($n in $wins.Keys) {
    $x = ConvertTo-ThemedXaml ($wins[$n].Replace('__PAGES__', $Script:XPages).Replace('__RES__', $Script:XRes))
    $ok = $true; try { [void][xml]$x } catch { $ok = $false; "  $n : $($_.Exception.Message)" }
    Check "$n window: well-formed XAML after the theme conversion" $ok
    $left = @([regex]::Matches($x, "\b($Script:ThemeProps)=`"#[0-9A-Fa-f]{6}`"") | ForEach-Object Value) + @([regex]::Matches($x, "Property=`"(?:$Script:ThemeProps)`"\s+Value=`"#[0-9A-Fa-f]{6}`"") | ForEach-Object Value)
    Check "$n window: no fixed colour left on a brush ($($left -join ' '))" ($left.Count -eq 0)
    $keys += @([regex]::Matches($x, 'DynamicResource T_([0-9A-F]{6})') | ForEach-Object { $_.Groups[1].Value })
}
$keys = @($keys | Sort-Object -Unique)
$fixed = @([regex]::Matches(($Script:XMain + $Script:XRes + $Script:XPages), 'Color="#([0-9A-Fa-f]{6})"') | ForEach-Object { $_.Groups[1].Value.ToUpper() } | Sort-Object -Unique)
Check "only the accent gradient keeps fixed colours ($($fixed -join ','))" (($fixed -join ',') -eq '2F9BFF,8B5CF6')
$codeHex = @([regex]::Matches($gui, "(?:New-Brush|Set-BusyDot|Set-Step \d+ '[^']*') '#([0-9A-Fa-f]{6})'") | ForEach-Object { $_.Groups[1].Value.ToUpper() })
$codeHex += @([regex]::Matches($gui, "(?s)function Get-LogBrush.*?^}" , 'Multiline').Value | ForEach-Object { [regex]::Matches($_, "'#([0-9A-Fa-f]{6})'") | ForEach-Object { $_.Groups[1].Value.ToUpper() } })
$codeHex += @([regex]::Matches($gui, "(?s)function Set-Step.*?^}", 'Multiline').Value | ForEach-Object { [regex]::Matches($_, "'#([0-9A-Fa-f]{6})'") | ForEach-Object { $_.Groups[1].Value.ToUpper() } })
$all = @($keys + $codeHex | Sort-Object -Unique)
$missing = @($all | Where-Object { -not $Script:LightColors.ContainsKey($_) })
Check "every colour ($($all.Count)) has a light-theme colour ($($missing -join ','))" ($missing.Count -eq 0 -and $all.Count -ge 30)
Check 'theme keys found in the windows' ($keys.Count -ge 25 -and $keys -contains 'E6EAF2' -and $keys -contains '141A27')

# ---- light theme: text is readable (WCAG AA, 4.5:1) on every background it sits on
function Lum([string]$h) {
    $c = @(0, 2, 4 | ForEach-Object { [Convert]::ToInt32($h.Substring($_, 2), 16) / 255.0 } | ForEach-Object { if ($_ -le 0.03928) { $_ / 12.92 } else { [math]::Pow(($_ + 0.055) / 1.055, 2.4) } })
    return 0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]
}
function Ratio([string]$a, [string]$b) { $x = Lum $a; $y = Lum $b; return ([math]::Max($x, $y) + 0.05) / ([math]::Min($x, $y) + 0.05) }
$L = $Script:LightColors
$bg = @{ window = '0B0E14'; card = '141A27'; sidebar = '0E121B'; activity = '0A0D13'; input = '0E131E'; row = '111726'; altrow = '141B2B'; button = '222B3F'; navsel = '1C2538'; header = '1A2133' }
$pairs = @(
    @('E6EAF2', 'window card sidebar activity input row altrow button navsel header'),   # main text
    @('F4F6FB', 'window card'), @('DCE3F0', 'card'),                                       # H1, H2
    @('A3ADC2', 'window card'), @('8A94A8', 'card sidebar activity row altrow'),          # help text, secondary
    @('6F7A90', 'card'), @('5B6478', 'sidebar card activity'),                            # labels, dim
    @('3DDC97', 'card activity sidebar'), @('FFC857', 'card activity sidebar'), @('FF5C7A', 'card activity sidebar'),
    @('AEB7C8', 'activity'), @('5CC8FF', 'activity'), @('3A8FB7', 'activity'), @('B48CFF', 'activity'), @('C9A043', 'activity')
)
$low = @()
foreach ($p in $pairs) { foreach ($b in ($p[1] -split ' ')) { $r = Ratio $L[$p[0]] $L[$bg[$b]]; if ($r -lt 4.5) { $low += ('{0} on {1} {2:N2}' -f $p[0], $b, $r) } } }
Check "light theme: all text pairs at least 4.5:1 ($($low -join '; '))" ($low.Count -eq 0)
$r = Ratio $L['232B3D'] $L['141A27']
Check ("light theme: card borders visible ({0:N2}:1)" -f $r) ($r -ge 1.2)

# ---- mapping, settings and the panel
$Script:ThemeNow = 'Dark'
Check 'dark theme keeps the colours' ((Get-ThemeHex '#e6eaf2') -eq '#E6EAF2')
$Script:ThemeNow = 'Light'
Check 'light theme maps them' ((Get-ThemeHex '#E6EAF2') -eq ('#' + $L['E6EAF2']) -and (Get-ThemeHex 'FFFFFF') -eq '#FFFFFF')
$Script:Cfg = @{ UiTheme = 'Light'; UiZoom = 100; UiFont = 'Segoe UI' }
function Test-WindowsLightTheme { $script:winLight }
Check 'theme: Light' ((Get-ThemeName) -eq 'Light')
$Script:Cfg.UiTheme = 'Dark'; Check 'theme: Dark' ((Get-ThemeName) -eq 'Dark')
$Script:Cfg.UiTheme = 'System'; $script:winLight = $true; $a = Get-ThemeName; $script:winLight = $false; $b = Get-ThemeName
Check 'theme: like Windows follows the app mode' ($a -eq 'Light' -and $b -eq 'Dark')
$Script:Cfg.UiTheme = 'Pink'; Check 'theme: unknown value -> Dark' ((Get-ThemeName) -eq 'Dark')
$Script:Cfg.UiZoom = 125; $Script:Cfg.UiFont = 'Comic Sans MS'
Check 'text size / font: unknown values -> 100 % / Segoe UI' ((Get-UiZoom) -eq 100 -and (Get-UiFont) -eq 'Segoe UI')
$script:saved = 0; $script:looks = 0
function Save-Settings { $script:saved++ }
function Set-UiLook { $script:looks++ }
$Script:Cfg.UiZoom = 100
Step-UiZoom 1; $z1 = Get-UiZoom; Step-UiZoom 1; Step-UiZoom 1; Step-UiZoom 1; $zmax = Get-UiZoom; Step-UiZoom -1; $zdown = Get-UiZoom; Step-UiZoom 0; $z0 = Get-UiZoom
Check "Ctrl+plus / minus / 0: $z1, max $zmax, $zdown, $z0" ($z1 -eq 115 -and $zmax -eq 150 -and $zdown -eq 130 -and $z0 -eq 100)
Check 'text size saved only when it changes' ($script:saved -eq 5 -and $script:looks -eq 5)
$names = @('ThemeDark', 'ThemeLight', 'ThemeSystem', 'Zoom100', 'Zoom115', 'Zoom130', 'Zoom150', 'FontSegoe', 'FontVerdana', 'FontTahoma', 'FontArial', 'LangAuto', 'LangEn', 'LangPt', 'LangEs', 'LangFr', 'LangDe', 'LangIt', 'ThemeBtn')
$Script:U = @{}; foreach ($n in $names) { $Script:U[$n] = [pscustomobject]@{ IsChecked = $false; Content = ''; ToolTip = '' } }
$Script:Cfg = @{ UiTheme = 'Light'; UiZoom = 130; UiFont = 'Verdana' }; $Script:ThemeNow = 'Light'
Update-A11yUi
$on = @($names | Where-Object { $Script:U[$_].IsChecked })
Check "panel shows the saved choices ($($on -join ','))" (($on -join ',') -eq 'ThemeLight,Zoom130,FontVerdana,LangAuto')
$Script:Cfg.UiLanguage = 'fr'; Update-A11yUi
Check 'panel shows the saved language' ($Script:U.LangFr.IsChecked -and -not $Script:U.LangAuto.IsChecked -and -not $Script:U.LangEn.IsChecked)
$Script:Cfg.UiLanguage = $null
Check 'light theme: the button offers the dark theme (moon)' ($Script:U.ThemeBtn.Content -eq [string][char]0xE708 -and $Script:U.ThemeBtn.ToolTip -eq 'Dark theme')
$Script:Cfg.UiTheme = 'Dark'; $Script:ThemeNow = 'Dark'; Update-A11yUi
Check 'dark theme: the button offers the light theme (sun)' ($Script:U.ThemeBtn.Content -eq [string][char]0xE706 -and $Script:U.ThemeDark.IsChecked)
if (-not $env:SystemDrive) { $env:SystemDrive = [IO.Path]::GetTempPath() }
$d = Get-DefaultSettings
Check 'defaults: dark, 100 %, Segoe UI' ($d.UiTheme -eq 'Dark' -and $d.UiZoom -eq 100 -and $d.UiFont -eq 'Segoe UI')
Check 'title bar: theme and accessibility buttons before minimize, with names for screen readers' ($Script:XMain -match '(?s)x:Name="ThemeBtn".*AutomationProperties\.Name=.*x:Name="A11yBtn".*AutomationProperties\.Name=.*x:Name="MinBtn"')

# ---- theme resources hold the .NET brush, not PowerShell's wrapper (v3.5.0 did not start on Windows PowerShell 5.1:
#      "'#FF0B0E14' is not a valid value for property 'Background'")
Add-Type -TypeDefinition 'public static class ResType { public static string Of(System.Collections.IDictionary d, object k) { return d[k].GetType().FullName; } }'
function New-Wrapped { $b = New-Object System.Text.StringBuilder 'brush'; return $b }
$res = New-Object System.Collections.Hashtable
$res['raw'] = New-Wrapped
Check 'PowerShell stores a PSObject wrapper when an object goes straight into a dictionary (the v3.5.0 bug)' ([ResType]::Of($res, 'raw') -eq 'System.Management.Automation.PSObject')
Set-Resource $res 'T_0B0E14' (New-Wrapped)
$gw = New-Object System.Text.StringBuilder 'gradient'
Set-Resource $res 'HeaderBg' $gw
Check 'Set-Resource stores the object itself' ([ResType]::Of($res, 'T_0B0E14') -eq 'System.Text.StringBuilder' -and [ResType]::Of($res, 'HeaderBg') -eq 'System.Text.StringBuilder')
$direct = @([regex]::Matches($gui, '\.Resources\[[^\]]+\]\s*=') | ForEach-Object Value)
Check "no resource is assigned directly - all go through Set-Resource ($($direct -join ' '))" ($direct.Count -eq 0)

if ($fails) { exit 1 }
exit 0
