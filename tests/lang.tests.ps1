$ErrorActionPreference = 'Stop'
$fails = 0
function Check($n, $c) { if ($c) { Microsoft.PowerShell.Utility\Write-Host "PASS $n" } else { Microsoft.PowerShell.Utility\Write-Host "FAIL $n"; $script:fails++ } }
$tokens=$null;$errs=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/v2body.ps1",[ref]$tokens,[ref]$errs)
foreach($f in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){ . ([scriptblock]::Create($f.Extent.Text)) }
$src = Join-Path (Split-Path -Parent $PSScriptRoot) 'src'

# ---- every interface text, from the XAML, the T '...' calls and the list columns (src/lang/keys.py)
$keys = @(& python3 (Join-Path $src 'lang/keys.py') | Where-Object { $_ })
Check "interface texts found: $($keys.Count)" ($keys.Count -gt 300 -and $keys -contains 'Source ISO' -and $keys -contains 'Download Windows {0} from Microsoft' -and $keys -contains 'Edition')
$codes = @(Get-LanguageList | ForEach-Object { $_.Code })
Check "languages: $($codes -join ', ')" (($codes -join ',') -eq 'en,pt,es,fr,de,it')

# ---- each language: every text translated, placeholders kept, and the formatted text works
function Get-Args([string]$Text) {
    $out = @{}
    foreach ($m in [regex]::Matches($Text, '\{(\d+)(?::([^}]*))?\}')) {
        $f = $m.Groups[2].Value
        $out[[int]$m.Groups[1].Value] = if ($f -cmatch 'yyyy') { [datetime]'2026-10-30' } elseif ($f -cmatch 'mm|ss|hh') { [timespan]::FromSeconds(75) } elseif ($f -cmatch '^N') { 1234.5 } else { 'x' }
    }
    if (-not $out.Count) { return @() }
    return @(0..(($out.Keys | Measure-Object -Maximum).Maximum) | ForEach-Object { $out[$_] })
}
$ph = { param($s) (@([regex]::Matches($s, '\{\d+(?::[^}]*)?\}') | ForEach-Object Value | Sort-Object)) -join ' ' }
foreach ($c in @($codes | Where-Object { $_ -ne 'en' })) {
    $t = Get-LangTable $c
    $miss = @($keys | Where-Object { -not $t.ContainsKey($_) })
    Check "${c}: every text translated ($($miss.Count) missing: $(($miss | Select-Object -First 3) -join ' | '))" ($miss.Count -eq 0)
    $badPh = @($keys | Where-Object { $t.ContainsKey($_) -and (& $ph $_) -ne (& $ph $t[$_]) })
    Check "${c}: placeholders and formats kept ($($badPh.Count) differ: $(($badPh | Select-Object -First 2) -join ' | '))" ($badPh.Count -eq 0)
    $badFmt = @()
    foreach ($k in @($keys | Where-Object { $_ -match '\{\d' -and $t.ContainsKey($_) })) {
        $a = Get-Args $k
        try { [void]($t[$k] -f $a) } catch { $badFmt += $k }
    }
    Check "${c}: every text with values formats ($($badFmt.Count) fail)" ($badFmt.Count -eq 0)
    $same = @($keys | Where-Object { $t.ContainsKey($_) -and $t[$_] -ceq $_ }).Count
    Check "${c}: translated, not copied ($same of $($keys.Count) the same as English)" ($same -lt ($keys.Count * 0.05))
    $empty = @($keys | Where-Object { $t.ContainsKey($_) -and -not $t[$_].Trim() }).Count
    Check "${c}: no empty translation" ($empty -eq 0)
}

# ---- lookups, accents and the language in use
Check 'accented letters decoded' ((ConvertFrom-LangText 'Fran&#xE7;ais / Portugu&#xEA;s / &#xDC;ber') -eq "Fran$([char]0xE7)ais / Portugu$([char]0xEA)s / $([char]0xDC)ber")
$Script:LangNow = 'pt'
Check "Portuguese: '$(T 'Slipstream + build ISO')', '$(T 'Drivers')'" ((T 'Slipstream + build ISO') -eq 'Integrar + criar ISO' -and (T 'Drivers') -eq 'Controladores')
Check 'Portuguese: accents in the text' ((T 'Answer file') -eq "Ficheiro de respostas" -and (T 'Unpack') -eq 'Extrair' -and (T 'Language') -eq 'Idioma' -and (T 'Windows version') -eq "Vers$([char]0xE3)o do Windows")
Check 'a text without translation stays English; empty stays empty' ((T 'Some text nobody wrote') -eq 'Some text nobody wrote' -and (T '') -eq '' -and $null -eq (T $null) -or (T $null) -eq '')
Check 'formatted text' (((T '{0} of {1} ticked') -f 2, 5) -eq '2 de 5 marcadas')
$Script:LangNow = 'en'
Check 'English: the text as written' ((T 'Slipstream + build ISO') -eq 'Slipstream + build ISO')
$Script:Cfg = @{ UiLanguage = 'de' }; $a = Get-UiLanguage
$Script:Cfg.UiLanguage = 'xx'; $b = Get-UiLanguage
$keep = [Globalization.CultureInfo]::CurrentUICulture
$Script:Cfg.UiLanguage = 'auto'
[Globalization.CultureInfo]::CurrentUICulture = 'es-ES'; $c1 = Get-UiLanguage
[Globalization.CultureInfo]::CurrentUICulture = 'ja-JP'; $c2 = Get-UiLanguage
$Script:Cfg.UiLanguage = $null; [Globalization.CultureInfo]::CurrentUICulture = 'fr-CA'; $c3 = Get-UiLanguage
[Globalization.CultureInfo]::CurrentUICulture = $keep
Check "language in use: setting ($a), unknown ($b), like Windows es-ES ($c1), ja-JP ($c2), nothing set fr-CA ($c3)" ($a -eq 'de' -and $b -eq 'en' -and $c1 -eq 'es' -and $c2 -eq 'en' -and $c3 -eq 'fr')
if (-not $env:SystemDrive) { $env:SystemDrive = [IO.Path]::GetTempPath() }
Check 'default setting: like Windows' ((Get-DefaultSettings).UiLanguage -eq 'auto')

# ---- switching: the window's texts and list columns follow (stand-ins for the WPF elements)
$el = [pscustomobject]@{ Text = 'Ready' }; $btn = [pscustomobject]@{ Content = 'Browse...' }
$grid = [pscustomobject]@{ Columns = @([pscustomobject]@{ SortMemberPath = 'Edition'; Header = 'Edition' }, [pscustomobject]@{ SortMemberPath = 'KB'; Header = 'KB' }) }
$texts = @([pscustomobject]@{ El = $el; Prop = 'Text'; En = 'Ready' }, [pscustomobject]@{ El = $btn; Prop = 'Content'; En = 'Browse...' }, [pscustomobject]@{ El = $grid; Prop = 'Columns'; En = '' })
$Script:LangNow = 'fr'; Set-UiTexts $texts
$fr = "$($el.Text) | $($btn.Content) | $($grid.Columns[0].Header) | $($grid.Columns[1].Header)"
$Script:LangNow = 'de'; Set-UiTexts $texts
$de = "$($el.Text) | $($btn.Content) | $($grid.Columns[0].Header)"
$Script:LangNow = 'en'; Set-UiTexts $texts
Check "switching French -> German -> English ($fr / $de / $($el.Text))" ($fr -eq "Pr$([char]0xEA)t | Parcourir... | $([char]0xC9)dition | KB" -and $de -eq 'Bereit | Durchsuchen... | Edition' -and $el.Text -eq 'Ready' -and $btn.Content -eq 'Browse...')

# ---- the window code: no message or confirmation left as a bare English literal
$gui = (Get-Content (Join-Path $src '50_gui.ps1') -Raw) + (Get-Content (Join-Path $src '55_gui_main.ps1') -Raw)
$bare = @([regex]::Matches($gui, "(Show-Msg|Confirm-Ui|Select-Folder|Select-File)\s+['""][A-Za-z]") | ForEach-Object Value)
Check "every message, question and dialog title goes through T ($($bare -join ' | '))" ($bare.Count -eq 0)
$set = @([regex]::Matches($gui, "\.(Text|Content|ToolTip)\s*=\s*(if\s*\([^)]*\)\s*\{\s*)?['""][A-Za-z][a-z]+ [a-z]") | ForEach-Object Value)
Check "no English sentence set on a control directly ($($set -join ' | '))" ($set.Count -eq 0)

if ($fails) { exit 1 }
exit 0
