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

# ---- a whole window: Get-UiTexts walks the element tree and Set-UiTexts puts the language on it. Stand-ins
# for the WPF classes, so the real functions run on objects of the same shape: the list Get-UiTexts returns
# once made v4.2.0 / v4.3.0 stop at start ("Argument types do not match" - @() over a List[object] from New-Object).
Add-Type -TypeDefinition @'
using System.Collections.Generic;
namespace Windows {
    public class DependencyObject { public List<object> Kids = new List<object>(); }
    public class FrameworkElement : DependencyObject { public object ToolTip; public string Name = ""; }
    public class Window : Controls.ContentControl { }
    public static class LogicalTreeHelper { public static IEnumerable<object> GetChildren(object o) { var d = o as DependencyObject; return d == null ? new List<object>() : d.Kids; } }
}
namespace Windows.Automation {
    public static class AutomationProperties {
        static Dictionary<object, string> names = new Dictionary<object, string>();
        public static string GetName(DependencyObject o) { string v; return names.TryGetValue(o, out v) ? v : ""; }
        public static void SetName(DependencyObject o, string v) { names[o] = v; }
    }
}
namespace Windows.Documents {
    public class Run : DependencyObject { public string Text = ""; public string Name = ""; public object Parent; }
    public class InlineCollection { public List<Run> Items = new List<Run>(); public int Count { get { return Items.Count; } } public Run FirstInline { get { return Items.Count > 0 ? Items[0] : null; } } }
}
namespace Windows.Controls {
    public class TextBlock : FrameworkElement { public string Text = ""; public Windows.Documents.InlineCollection Inlines = new Windows.Documents.InlineCollection(); }
    public class ContentControl : FrameworkElement { public object Content; }
    public class Button : ContentControl { }
    public class HeaderedContentControl : ContentControl { public object Header; }
    public class HeaderedItemsControl : FrameworkElement { public object Header; }
    public class TextBox : FrameworkElement { public string Text = ""; }
    public class DataGridColumn { public string SortMemberPath = ""; public object Header; }
    public class DataGrid : FrameworkElement { public List<DataGridColumn> Columns = new List<DataGridColumn>(); }
}
'@
$win = New-Object Windows.Window
$tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'Ready'
$bt = New-Object Windows.Controls.Button; $bt.Content = 'Browse...'; $bt.ToolTip = 'Light theme'
[Windows.Automation.AutomationProperties]::SetName($bt, 'Switch to the light theme')
$tab = New-Object Windows.Controls.HeaderedContentControl; $tab.Header = 'Language'; $tab.Content = $tb
$box = New-Object Windows.Controls.TextBox; $box.ToolTip = 'SHA-256 of the ISO - select it to copy'
$dg = New-Object Windows.Controls.DataGrid; $col = New-Object Windows.Controls.DataGridColumn; $col.SortMemberPath = 'Edition'; $col.Header = 'Edition'; $dg.Columns.Add($col)
$win.Kids.AddRange([object[]]@($tab, $bt, $box, $dg)); $tab.Kids.Add($tb)
foreach ($i in 1..400) { $more = New-Object Windows.Controls.TextBlock; $more.Text = 'Ready'; $win.Kids.Add($more) }   # a window's worth of texts
$Script:LangNow = 'pt'
try {
    $wt = Get-UiTexts $win
    Set-UiTexts $wt
    $err = ''
} catch { $err = $_.Exception.Message }
Check "a whole window: texts read and put in Portuguese ($(if ($err) { $err } else { "$($tb.Text) | $($bt.Content) | $($tab.Header) | $($dg.Columns[0].Header)" }))" (-not $err -and $tb.Text -ceq (T 'Ready') -and $tb.Text -cne 'Ready' -and $bt.Content -ceq (T 'Browse...') -and $tab.Header -ceq (T 'Language') -and
    $bt.ToolTip -ceq (T 'Light theme') -and $box.ToolTip -ceq (T 'SHA-256 of the ISO - select it to copy') -and [Windows.Automation.AutomationProperties]::GetName($bt) -ceq (T 'Switch to the light theme') -and $dg.Columns[0].Header -ceq (T 'Edition'))
$Script:LangNow = 'en'
try { Set-UiTexts $wt; $err = '' } catch { $err = $_.Exception.Message }
Check "a whole window: back to English ($err)" (-not $err -and $tb.Text -eq 'Ready' -and $bt.Content -eq 'Browse...' -and $box.ToolTip -eq 'SHA-256 of the ISO - select it to copy')
$wl = New-Object System.Collections.Generic.List[object]; $wl.Add([pscustomobject]@{ El = $tb; Prop = 'Text'; En = 'Ready' })
$Script:LangNow = 'de'
try { Set-UiTexts $wl; Add-GridHeaderTranslation $wl; $err = '' } catch { $err = $_.Exception.Message }
Check "texts in a List[object] made by New-Object ($err)" (-not $err -and $tb.Text -eq 'Bereit')
$Script:LangNow = 'en'

# ---- the window code: no message or confirmation left as a bare English literal
$gui = (Get-Content (Join-Path $src '50_gui.ps1') -Raw) + (Get-Content (Join-Path $src '55_gui_main.ps1') -Raw)
$bare = @([regex]::Matches($gui, "(Show-Msg|Confirm-Ui|Select-Folder|Select-File)\s+['""][A-Za-z]") | ForEach-Object Value)
Check "every message, question and dialog title goes through T ($($bare -join ' | '))" ($bare.Count -eq 0)
$set = @([regex]::Matches($gui, "\.(Text|Content|ToolTip)\s*=\s*(if\s*\([^)]*\)\s*\{\s*)?['""][A-Za-z][a-z]+ [a-z]") | ForEach-Object Value)
Check "no English sentence set on a control directly ($($set -join ' | '))" ($set.Count -eq 0)

if ($fails) { exit 1 }
exit 0
