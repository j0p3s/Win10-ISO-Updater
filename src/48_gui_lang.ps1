#region ---------------------------------------------------------------- interface language
# The texts are written in English in the code and the XAML. Every other language is a table English ->
# translation (src/lang/<code>.json, built into Get-LangData by build.py, with accented letters written as
# &#xE9; so this file stays ASCII). T 'English' returns the text in the language in use, or the English text
# when the table has none. The Activity log and the Install check findings stay in English: they come from
# the engine, and they are what a bug report or a search needs.
function Get-LanguageList {
    return @(
        [pscustomobject]@{ Code = 'en'; Button = 'LangEn' }
        [pscustomobject]@{ Code = 'pt'; Button = 'LangPt' }
        [pscustomobject]@{ Code = 'es'; Button = 'LangEs' }
        [pscustomobject]@{ Code = 'fr'; Button = 'LangFr' }
        [pscustomobject]@{ Code = 'de'; Button = 'LangDe' }
        [pscustomobject]@{ Code = 'it'; Button = 'LangIt' }
    )
}
# The language in use: the setting, or - "Like Windows" (auto) - Windows' display language when there is a
# table for it, English otherwise.
function Get-UiLanguage {
    $codes = @(Get-LanguageList | ForEach-Object { $_.Code })
    $c = ([string]$Script:Cfg.UiLanguage).ToLowerInvariant()
    if (-not $c -or $c -eq 'auto') { $c = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
    if ($codes -contains $c) { return $c }
    return 'en'
}
function ConvertFrom-LangText([string]$Text) {
    return [regex]::Replace($Text, '&#x([0-9A-Fa-f]{2,4});', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}
# One line per text: English, a tab, the translation.
function Get-LangTable([string]$Code) {
    if (-not $Script:LangTables) { $Script:LangTables = @{} }
    if ($Script:LangTables.ContainsKey($Code)) { return $Script:LangTables[$Code] }
    $t = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    foreach ($line in ((Get-LangData $Code) -split "`r?`n")) {
        $i = $line.IndexOf("`t")
        if ($i -gt 0) { $t[(ConvertFrom-LangText $line.Substring(0, $i))] = ConvertFrom-LangText $line.Substring($i + 1) }
    }
    $Script:LangTables[$Code] = $t
    return $t
}
function T([string]$Text) {
    if (-not $Text -or -not $Script:LangNow -or $Script:LangNow -eq 'en') { return $Text }
    $t = Get-LangTable $Script:LangNow
    $v = $null
    if ($t.TryGetValue($Text, [ref]$v)) { return $v }
    return $Text
}
# Every text a window shows from its XAML: element, property and the English text. Kept for the main
# window, so the language can change at once without building the window again.
function Get-UiTexts($Root) {
    $list = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count) {
        $o = $stack.Pop()
        if ($o -isnot [Windows.DependencyObject]) { continue }
        $add = { param($Prop, $Val) if ($Val -is [string] -and $Val -match '[A-Za-z]{2}') { $list.Add([pscustomobject]@{ El = $o; Prop = $Prop; En = $Val }) } }
        if ($o -is [Windows.Controls.TextBlock]) {
            if ($o.Inlines.Count -le 1 -and -not ($o.Inlines.Count -eq 1 -and $o.Inlines.FirstInline.Name)) { & $add 'Text' $o.Text }
        } elseif ($o -is [Windows.Documents.Run]) {
            if (-not $o.Name -and $o.Parent -is [Windows.Controls.TextBlock] -and $o.Parent.Inlines.Count -gt 1) { & $add 'Text' $o.Text }
        }
        if ($o -is [Windows.Controls.HeaderedContentControl] -or $o -is [Windows.Controls.HeaderedItemsControl]) { & $add 'Header' $o.Header }
        if ($o -is [Windows.Controls.ContentControl] -and $o -isnot [Windows.Window]) { & $add 'Content' $o.Content }
        if ($o -is [Windows.FrameworkElement]) { & $add 'ToolTip' $o.ToolTip }
        $an = [Windows.Automation.AutomationProperties]::GetName($o)
        if ($an) { & $add 'AutomationName' $an }
        if ($o -is [Windows.Controls.DataGrid]) { $list.Add([pscustomobject]@{ El = $o; Prop = 'Columns'; En = '' }) }
        foreach ($c in [Windows.LogicalTreeHelper]::GetChildren($o)) { $stack.Push($c) }
    }
    return , $list
}
# Puts the texts in the language in use. List columns are named after their data (Edition, Size ...),
# translated when they are made and here when the language changes.
function Set-UiTexts($Texts) {
    foreach ($x in @($Texts)) {
        switch ($x.Prop) {
            'AutomationName' { [Windows.Automation.AutomationProperties]::SetName($x.El, (T $x.En)) }
            'Columns' { foreach ($c in @($x.El.Columns)) { if ($c.SortMemberPath) { $c.Header = T $c.SortMemberPath } } }
            default { $x.El.($x.Prop) = [string](T $x.En) }
        }
    }
}
# New list columns get their header in the language in use (added before the page's own handlers).
function Add-GridHeaderTranslation($Texts) {
    foreach ($x in @($Texts | Where-Object { $_.Prop -eq 'Columns' })) {
        $x.El.Add_AutoGeneratingColumn({ param($s, $e) $e.Column.Header = T ([string]$e.PropertyName) })
    }
}
function Set-UiLanguage {
    $Script:LangNow = Get-UiLanguage
    Set-UiTexts $Script:UiTexts
    Update-A11yUi
    Update-Ui
}
#endregion
