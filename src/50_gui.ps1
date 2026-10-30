
#region ---------------------------------------------------------------- GUI helpers
function New-Xaml([string]$Text) {
    $x = ConvertTo-ThemedXaml ($Text.Replace('__PAGES__', $Script:XPages).Replace('__RES__', $Script:XRes))
    $win = [Windows.Markup.XamlReader]::Parse($x)
    foreach ($m in [regex]::Matches($x, 'DynamicResource T_([0-9A-F]{6})')) { if ($Script:ThemeKeys -notcontains $m.Groups[1].Value) { $Script:ThemeKeys += $m.Groups[1].Value } }
    Set-ThemeResources $win
    Set-WindowLook $win
    $names = @{}
    foreach ($m in [regex]::Matches($x, 'x:Name="([^"]+)"')) {
        $o = $win.FindName($m.Groups[1].Value)
        if ($o) { $names[$m.Groups[1].Value] = $o }
    }
    return @{ W = $win; U = $names }
}
function New-Brush([string]$Hex) {
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString((Get-ThemeHex $Hex)))
    $b.Freeze()
    return $b
}
function New-Table([string[]]$Cols, $Rows) {
    $t = New-Object System.Data.DataTable
    foreach ($c in $Cols) {
        $parts = $c -split ':'
        $type = switch ($parts[1]) { 'int' { [int] } 'bool' { [bool] } 'dbl' { [double] } default { [string] } }
        [void]$t.Columns.Add($parts[0], $type)
    }
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        $dr = $t.NewRow()
        for ($i = 0; $i -lt $Cols.Count; $i++) {
            $v = $r[$i]
            if ($null -eq $v -or "$v" -eq '') { if ($t.Columns[$i].DataType -eq [string]) { $v = '' } else { $v = [DBNull]::Value } }
            $dr[$i] = $v
        }
        [void]$t.Rows.Add($dr)
    }
    return , $t
}
function Show-Msg([string]$Text, [string]$Icon = 'Information') {
    [void][Windows.MessageBox]::Show($Script:W, $Text, $Script:AppTitle, 'OK', $Icon)
}
function Confirm-Ui([string]$Text, [string]$Icon = 'Question') {
    return ([Windows.MessageBox]::Show($Script:W, $Text, $Script:AppTitle, 'YesNo', $Icon) -eq 'Yes')
}
function Select-Folder([string]$Title, [string]$Start) {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = $Title
    $d.ShowNewFolderButton = $true
    if ($Start -and (Test-Path -LiteralPath $Start)) { $d.SelectedPath = $Start }
    $own = New-Object System.Windows.Forms.NativeWindow
    $own.AssignHandle((New-Object System.Windows.Interop.WindowInteropHelper $Script:W).Handle)
    try { $r = $d.ShowDialog($own) } finally { $own.ReleaseHandle() }
    if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    return $null
}
function Select-File([string]$Title, [string]$Filter, [string]$Start) {
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Title = $Title; $d.Filter = $Filter
    if ($Start -and (Test-Path -LiteralPath $Start)) { $d.InitialDirectory = $Start }
    if ($d.ShowDialog($Script:W)) { return $d.FileName }
    return $null
}
function Open-Path([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) { Start-Process explorer.exe "`"$Path`"" } else { Show-Msg "Not there yet: $Path" }
}
function Get-LogBrush([string]$Color) {
    if (-not $Script:LogBrushes) {
        $Script:LogBrushes = @{
            Cyan = (New-Brush '#5CC8FF'); DarkCyan = (New-Brush '#3A8FB7'); Green = (New-Brush '#3DDC97'); Yellow = (New-Brush '#FFC857')
            Red = (New-Brush '#FF5C7A'); Gray = (New-Brush '#AEB7C8'); DarkGray = (New-Brush '#5B6478'); White = (New-Brush '#E6EAF2')
            Magenta = (New-Brush '#B48CFF'); DarkYellow = (New-Brush '#C9A043')
        }
    }
    $b = $Script:LogBrushes[$Color]
    if (-not $b) { $b = $Script:LogBrushes.Gray }
    return $b
}
function Flush-Log {
    $doc = $Script:U.LogBox.Document
    $item = $null; $n = 0
    while ($n -lt 400 -and $Script:Sync.Queue.TryDequeue([ref]$item)) {
        $p = New-Object Windows.Documents.Paragraph
        $p.Margin = New-Object Windows.Thickness 0
        $r = New-Object Windows.Documents.Run ([string]$item[1])
        $r.Foreground = Get-LogBrush ([string]$item[0])
        $r.Tag = [string]$item[0]
        $p.Inlines.Add($r)
        $doc.Blocks.Add($p)
        $n++
    }
    if ($n -gt 0) {
        while ($doc.Blocks.Count -gt 4000) { [void]$doc.Blocks.Remove($doc.Blocks.FirstBlock) }
        $Script:U.LogBox.ScrollToEnd()
    }
}
#endregion

#region ---------------------------------------------------------------- theme, text size, font (title bar, top right)
# The XAML is written with the dark colours. When a window is loaded, every colour of a brush property
# becomes a resource (T_<hex>) that holds that colour in the current theme, so switching the theme swaps
# the resources and the window follows at once. Brushes made in code go through New-Brush, which maps too.
$Script:ThemeKeys = @()
$Script:ThemeNow = 'Dark'
$Script:ThemeProps = 'Foreground|Background|BorderBrush|Fill|Stroke|CaretBrush|SelectionBrush|RowBackground|AlternatingRowBackground'
# dark colour -> light colour (text >= 4.5:1 on its background, see tests/theme.tests.ps1)
$Script:LightColors = @{
    '0B0E14' = 'F3F5F9'; '0E121B' = 'E8ECF3'; '0A0D13' = 'EEF1F6'; '0E131E' = 'FFFFFF'; '141A27' = 'FFFFFF'; '111726' = 'FFFFFF'
    '141B2B' = 'F5F7FB'; '1A2133' = 'E1E6EF'; '1C2538' = 'D9E4F7'; '161D2C' = 'E3E9F3'; '222B3F' = 'E1E6EF'; '2A3348' = 'BCC5D3'
    '2A3142' = 'D3DAE5'; '232B3D' = 'D0D7E2'; '24406E' = 'CADDFA'
    'F4F6FB' = '0E1420'; 'E6EAF2' = '1B2230'; 'DCE3F0' = '222A38'; 'AEB7C8' = '404A5C'; 'A3ADC2' = '4B5568'; '8A94A8' = '505A6D'
    '6F7A90' = '535D70'; '5B6478' = '5A6478'
    '3DDC97' = '0B7A47'; 'FFC857' = '875600'; 'FF5C7A' = 'BA1F3A'; '2F9BFF' = '1A64C2'; '5CC8FF' = '0A5F8A'; '3A8FB7' = '245E7A'
    'B48CFF' = '6B3FC4'; 'C9A043' = '7A5C0C'
}
function ConvertTo-ThemedXaml([string]$X) {
    $p = $Script:ThemeProps
    $X = [regex]::Replace($X, "\b($p)=`"#([0-9A-Fa-f]{6})`"", { param($m) '{0}="{{DynamicResource T_{1}}}"' -f $m.Groups[1].Value, $m.Groups[2].Value.ToUpperInvariant() })
    $X = [regex]::Replace($X, "(Property=`"(?:$p)`"\s+Value=)`"#([0-9A-Fa-f]{6})`"", { param($m) '{0}"{{DynamicResource T_{1}}}"' -f $m.Groups[1].Value, $m.Groups[2].Value.ToUpperInvariant() })
    return $X
}
function Get-ThemeHex([string]$Hex) {
    $h = $Hex.TrimStart('#').ToUpperInvariant()
    if ($Script:ThemeNow -eq 'Light' -and $Script:LightColors.ContainsKey($h)) { return '#' + $Script:LightColors[$h] }
    return '#' + $h
}
function Test-WindowsLightTheme {
    try { return ((Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 1) }
    catch { return $false }
}
# Dark | Light; "System" follows the app mode set in Windows (Settings > Personalization > Colors)
function Get-ThemeName {
    switch ([string]$Script:Cfg.UiTheme) {
        'Light'  { return 'Light' }
        'System' { if (Test-WindowsLightTheme) { return 'Light' } else { return 'Dark' } }
        default  { return 'Dark' }
    }
}
function Get-UiZoom {
    $z = [int]$Script:Cfg.UiZoom
    if (@(100, 115, 130, 150) -notcontains $z) { $z = 100 }
    return $z
}
function Get-UiFont {
    $f = [string]$Script:Cfg.UiFont
    if (@('Segoe UI', 'Verdana', 'Tahoma', 'Arial') -notcontains $f) { $f = 'Segoe UI' }
    return $f
}
# Objects made with New-Object reach PowerShell code wrapped in a PSObject. A typed property (Foreground = ...)
# unwraps them, but a dictionary such as Window.Resources stores the wrapper as it is - and a DynamicResource
# then hands WPF a PSObject: "'#FF0B0E14' is not a valid value for property 'Background'" (v3.5.0 on Windows
# PowerShell 5.1). Resources are therefore always stored as the .NET object itself.
function Set-Resource($Dict, [string]$Key, $Value) {
    $o = $Value
    if ($null -ne $o -and $null -ne $o.psobject) { $o = $o.psobject.BaseObject }
    $Dict[$Key] = $o
}
function Set-ThemeResources($Win) {
    if (-not $Win) { return }
    foreach ($k in $Script:ThemeKeys) { Set-Resource $Win.Resources "T_$k" (New-Brush "#$k") }
    $stops = if ($Script:ThemeNow -eq 'Light') { @('#E4ECFA', '#EDE7FA') } else { @('#16213A', '#1B1733') }
    $c0 = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($stops[0])
    $c1 = [Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($stops[1])
    $g = New-Object Windows.Media.LinearGradientBrush $c0, $c1, (New-Object Windows.Point 0, 0), (New-Object Windows.Point 1, 0)
    $g.Freeze()
    Set-Resource $Win.Resources 'HeaderBg' $g
}
# Font for every text that has none of its own (the log keeps Consolas, icons their symbol font) and
# the text size as a zoom of the whole window content.
function Set-WindowLook($Win) {
    if (-not $Win) { return }
    $Win.FontFamily = New-Object Windows.Media.FontFamily (Get-UiFont)
    $z = (Get-UiZoom) / 100.0
    if ($Win.Content -is [Windows.FrameworkElement]) { $Win.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform $z, $z }
}
function Set-BusyDot([string]$Hex) {
    $Script:BusyHex = $Hex
    $Script:U.BusyDot.Fill = New-Brush $Hex
}
function Update-A11yUi {
    $U = $Script:U
    $t = [string]$Script:Cfg.UiTheme
    $U.ThemeDark.IsChecked = ($t -ne 'Light' -and $t -ne 'System'); $U.ThemeLight.IsChecked = ($t -eq 'Light'); $U.ThemeSystem.IsChecked = ($t -eq 'System')
    $z = Get-UiZoom
    foreach ($n in 100, 115, 130, 150) { $U["Zoom$n"].IsChecked = ($z -eq $n) }
    $f = Get-UiFont
    $U.FontSegoe.IsChecked = ($f -eq 'Segoe UI'); $U.FontVerdana.IsChecked = ($f -eq 'Verdana'); $U.FontTahoma.IsChecked = ($f -eq 'Tahoma'); $U.FontArial.IsChecked = ($f -eq 'Arial')
    $light = $Script:ThemeNow -eq 'Light'
    $U.ThemeBtn.Content = if ($light) { [string][char]0xE708 } else { [string][char]0xE706 }      # moon / sun
    $U.ThemeBtn.ToolTip = if ($light) { 'Dark theme' } else { 'Light theme' }
    try { [Windows.Automation.AutomationProperties]::SetName($U.ThemeBtn, $(if ($light) { 'Switch to the dark theme' } else { 'Switch to the light theme' })) } catch { }
}
function Set-Theme {
    $Script:ThemeNow = Get-ThemeName
    $Script:LogBrushes = $null
    Set-ThemeResources $Script:W
    # brushes made in code: the log lines (their colour name is in Tag), the busy dot; Update-Ui redraws the rest
    try { foreach ($b in @($Script:U.LogBox.Document.Blocks)) { foreach ($i in @($b.Inlines)) { if ($i.Tag) { $i.Foreground = Get-LogBrush ([string]$i.Tag) } } } } catch { }
    if ($Script:BusyHex) { Set-BusyDot $Script:BusyHex }
    Update-A11yUi
}
function Set-UiLook {
    Set-WindowLook $Script:W
    $z = (Get-UiZoom) / 100.0
    $Script:U.A11yPanel.LayoutTransform = New-Object Windows.Media.ScaleTransform $z, $z
    Update-A11yUi
}
# Ctrl + plus / minus: next / previous text size, Ctrl + 0: 100 %
function Step-UiZoom([int]$Dir) {
    $all = @(100, 115, 130, 150)
    $i = [array]::IndexOf($all, (Get-UiZoom))
    $z = if ($Dir -eq 0) { 100 } else { $all[[math]::Max(0, [math]::Min($all.Count - 1, $i + $Dir))] }
    if ($z -eq (Get-UiZoom)) { return }
    $Script:Cfg.UiZoom = $z; Save-Settings; Set-UiLook
}
#endregion

#region ---------------------------------------------------------------- background worker
# A slipstream runs for 30-90 minutes: Windows must not go to sleep in the middle (the screen may still
# turn off). Set on the window's thread, which lives as long as the program.
function Set-KeepAwake([bool]$On) {
    $flags = if ($On) { [uint32]2147483649 } else { [uint32]2147483648 }    # ES_CONTINUOUS (+ ES_SYSTEM_REQUIRED)
    try { [void][W10U.Con]::SetThreadExecutionState($flags) } catch { }
}
# The taskbar button shows the progress too, so a long job can be followed from another window.
function Set-TaskbarState([string]$State, [double]$Value = -1) {
    try {
        $tb = $Script:W.TaskbarItemInfo
        if (-not $tb) { return }
        if ([string]$tb.ProgressState -ne $State) { $tb.ProgressState = $State }
        if ($Value -ge 0) { $tb.ProgressValue = $Value }
    } catch { }
}
# Flashes the taskbar button until the window is in front again (a job ended or asks a question).
function Request-Attention {
    try {
        if ($Script:W.IsActive) { return }
        [void][W10U.Con]::Flash((New-Object System.Windows.Interop.WindowInteropHelper $Script:W).Handle)
    } catch { }
}
function Start-Work([string]$Job, $A = @{}, [scriptblock]$Then) {
    if ($Script:Busy) { Show-Msg 'Another job is still running.'; return }
    try { Save-Settings } catch { }
    $Script:Busy = $true
    $Script:JobName = $Job
    $Script:JobStart = Get-Date
    $Script:Then = $Then
    $Script:Sync.Pct = -1; $Script:Sync.Status = ''; $Script:Sync.Result = $null
    Set-KeepAwake $true
    Set-Busy $true
    $Script:Ps = [PowerShell]::Create()
    $Script:Ps.Runspace = $Script:RS
    [void]$Script:Ps.AddCommand('Invoke-Job').AddParameter('Job', $Job).AddParameter('A', $A)
    $Script:Handle = $Script:Ps.BeginInvoke()
}
function Complete-Work {
    $ok = $true
    try { [void]$Script:Ps.EndInvoke($Script:Handle) } catch { $ok = $false }
    try { $Script:Ps.Dispose() } catch { }
    $Script:Busy = $false
    Set-KeepAwake $false
    $took = (Get-Date) - $Script:JobStart
    Flush-Log
    $Script:Cfg = Import-Settings; Initialize-Paths; $Script:S = Import-State
    Set-Busy $false
    if ($ok) {
        $Script:U.BusyText.Text = ('{0} finished in {1:mm\:ss}' -f $Script:JobLabel, $took)
        Set-BusyDot '#3DDC97'
        Set-TaskbarState 'None'
    } else {
        $Script:U.BusyText.Text = "$($Script:JobLabel) stopped with an error - see the log"
        Set-BusyDot '#FF5C7A'
        Set-TaskbarState 'Error' 1      # red until the window is in front again
    }
    Request-Attention
    Update-Ui
    $then = $Script:Then
    $Script:Then = $null
    if ($ok -and $then) { & $then }
}
function Set-Busy([bool]$On) {
    $labels = @{ Unpack = 'Unpack'; Analyze = 'Analyze'; Download = 'Download updates'; ScanHost = 'Driver scan'; CommitHost = 'Copy drivers'
                 ScanFolder = 'Folder scan'; CommitImport = 'Import drivers'; Sign = 'Re-sign drivers'; Service = 'Slipstream'; Build = 'Build ISO'
                 All = 'Run everything'; Tools = 'Tools'; Clean = 'Clean up'; Check = 'Install check'; Fix = 'Apply fixes' }
    $Script:JobLabel = $labels[$Script:JobName]
    if (-not $Script:JobLabel) { $Script:JobLabel = $Script:JobName }
    $Script:U.Pages.IsEnabled = -not $On
    $Script:U.RunAll.IsEnabled = -not $On
    $Script:U.Prog.Visibility = if ($On) { 'Visible' } else { 'Hidden' }
    $Script:U.Prog.IsIndeterminate = $On
    $Script:U.StatusText.Text = ''
    if ($On) {
        Set-BusyDot '#FFC857'
        $Script:U.BusyText.Text = "$($Script:JobLabel)..."
        Set-TaskbarState 'Indeterminate'
    }
}
function Invoke-Tick {
    Flush-Log
    $q = $Script:Sync.Question
    if ($q) {
        $Script:Sync.Question = $null
        $Script:Timer.Stop()
        Set-TaskbarState 'Paused' 1     # yellow: the job waits for an answer
        Request-Attention
        $def = if ($q.Default) { 'Yes' } else { 'No' }
        $r = [Windows.MessageBox]::Show($Script:W, [string]$q.Text, $Script:AppTitle, 'YesNo', 'Question', $def)
        $Script:Sync.Answer = ($r -eq 'Yes')
        $Script:Timer.Start()
    }
    if ($Script:Busy) {
        $pct = [double]$Script:Sync.Pct
        if ($pct -ge 0) { $Script:U.Prog.IsIndeterminate = $false; $Script:U.Prog.Value = $pct; Set-TaskbarState 'Normal' ($pct / 100) }
        else { $Script:U.Prog.IsIndeterminate = $true; Set-TaskbarState 'Indeterminate' }
        $el = (Get-Date) - $Script:JobStart
        $Script:U.BusyText.Text = ('{0}  {1:hh\:mm\:ss}' -f $Script:JobLabel, $el)
        $st = [string]$Script:Sync.Status
        if ($pct -ge 0) { $st = ('{0:N1}%  {1}' -f $pct, $st) }
        foreach ($side in @($Script:Sync.SideSync)) {      # boot.wim / WinRE / servicing stack lookup in the background
            if (-not $side -or -not $side.Label) { continue }
            $sp = [double]$side.Pct
            $st = ('{0}    |    {1}{2}' -f $st, $side.Label, $(if ($sp -ge 0) { ' {0:N0}%' -f $sp } else { '' }))
        }
        $Script:U.StatusText.Text = $st
        if ($Script:Handle.IsCompleted) { Complete-Work }
    }
}
#endregion

#region ---------------------------------------------------------------- refresh
function Set-Step([int]$N, [string]$Text, [string]$Kind) {
    $Script:U["S$N"].Text = $Text
    $col = @{ ok = '#3DDC97'; todo = '#FFC857'; opt = '#5B6478'; warn = '#FF5C7A' }[$Kind]
    $Script:U["D$N"].BorderBrush = New-Brush $col
}
function Update-Status {
    $S = $Script:S; $U = $Script:U
    $U.HdrIso.Text = if ($S.SourceIso) { Split-Path $S.SourceIso -Leaf } else { 'no ISO yet' }
    $U.HdrImg.Text = if ($S.Family -and @($S.Images).Count -gt 0) { '{0}  |  {1}  |  {2}  |  {3} edition(s)' -f $S.Family.Name, $S.Images[0].Version, $S.Family.Arch, @($S.Images).Count } else { '-' }
    $free = ''
    try { $free = '  (' + (Format-Size (New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Script:P.Work)))).AvailableFreeSpace) + ' free)' } catch { }
    $U.HdrWork.Text = $Script:P.Work + $free

    if ($S.Unpacked) { Set-Step 1 'unpacked' 'ok' } else { Set-Step 1 'to do' 'todo' }
    $ns = @($S.Selected).Count
    if ($ns -gt 0) { Set-Step 2 "$ns of $(@($S.Images).Count) ticked" 'ok' } elseif ($S.Unpacked) { Set-Step 2 'tick at least one' 'todo' } else { Set-Step 2 'to do' 'todo' }
    $lcu = @($S.Updates | Where-Object { $_.Kind -eq 'LCU' }) | Select-Object -First 1
    if ($S.Family -and -not $S.Family.Supported) { Set-Step 3 'not available for this build' 'warn' }
    elseif ($lcu) { Set-Step 3 ('{0} ({1}) + {2} more' -f $lcu.KB, $lcu.Date.Substring(0, 7), (@($S.Updates).Count - 1)) 'ok' }
    else { Set-Step 3 'to do' 'todo' }
    $nd = @($S.Drivers).Count
    if ($nd -gt 0) { Set-Step 4 ('{0} packages ({1} for boot)' -f $nd, @($S.Drivers | Where-Object { $Script:BootClasses -contains $_.Class }).Count) 'ok' } else { Set-Step 4 'none (optional)' 'opt' }
    $sg = @($S.Signed | Where-Object { $_ })
    if ($sg.Count -gt 0) {
        $kind = if (@($sg | Where-Object { [int]$_.Failed -gt 0 }).Count) { 'warn' } else { 'ok' }
        Set-Step 5 (($sg | ForEach-Object { $_.Name }) -join ', ') $kind
    } else { Set-Step 5 'none (optional)' 'opt' }
    $p6 = @()
    if ($S.Unattend) { $p6 += 'autounattend' }
    if ($S.Oem) { $p6 += '$OEM$' }
    if ($p6.Count) { Set-Step 6 ($p6 -join ' + ') 'ok' } else { Set-Step 6 'none (optional)' 'opt' }
    if ($S.Check) {
        if ([int]$S.Check.Errors -gt 0) { Set-Step 8 ('{0} error(s), {1} warning(s)' -f $S.Check.Errors, $S.Check.Warnings) 'warn' }
        elseif ([int]$S.Check.Warnings -gt 0) { Set-Step 8 ('{0} warning(s)' -f $S.Check.Warnings) 'todo' }
        else { Set-Step 8 'all good' 'ok' }
    } else { Set-Step 8 'not run yet' 'opt' }
    if ($S.Iso -and (Test-Path -LiteralPath $S.Iso)) { Set-Step 7 'ISO ready' 'ok' }
    elseif ($S.Serviced) { Set-Step 7 "slipstreamed ($($S.Serviced.Build)) - build the ISO" 'todo' }
    else { Set-Step 7 'to do' 'todo' }
}
# Windows 10 / 11 on page 1: follows a newly unpacked ISO, otherwise the choice made there.
function Update-WinVersion {
    $S = $Script:S; $U = $Script:U; $Cfg = $Script:Cfg
    $isoOs = if ($S.Family) { Get-FamilyOs $S.Family } else { '' }
    $key = if ($S.Family) { '{0}|{1}' -f $S.SourceIso, $S.Family.Build } else { '' }
    if ($isoOs -and $key -ne $Script:WinVerKey -and [string]$Cfg.WinVersion -ne $isoOs) { $Cfg.WinVersion = $isoOs; Save-Settings }
    $Script:WinVerKey = $key
    $os = if ([string]$Cfg.WinVersion -eq '11') { '11' } else { '10' }
    $U.WinVer10.IsChecked = ($os -eq '10'); $U.WinVer11.IsChecked = ($os -eq '11')
    $note = if ($os -eq '11') { 'Updates for Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 and 25H2 (x64, ARM64). On a Windows 10 PC the slipstream uses the DISM of the Windows ADK Deployment Tools, installed from Microsoft when needed.' }
            else { 'Updates for Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 and LTSC 2021 (x64, x86, ARM64).' }
    if ($isoOs -and $isoOs -ne $os) { $note += " The unpacked ISO is Windows $isoOs - pick a Windows $os ISO and unpack it to switch." }
    $U.WinVerNote.Text = $note
    $U.GetIsoBtn.Content = "Download Windows $os from Microsoft"
    $U.CutoffRow.Visibility = if ($os -eq '10') { 'Visible' } else { 'Collapsed' }
    $U.CutoffNote.Text = if ($os -eq '10') { '2025-10 is the last Windows 10 update Microsoft allows offline. ESU updates (Nov 2025+) come from Windows Update after setup on enrolled PCs.' }
                         else { 'Windows 11: the newest updates in the Microsoft Update Catalog are used (21H2, which is out of servicing: its last ones, 2024-10).' }
}
function Update-Ui {
    $Script:Loading = $true
    try {
        $S = $Script:S; $U = $Script:U; $Cfg = $Script:Cfg
        Update-Status
        foreach ($k in $Script:CfgToggles) { $U["cfg_$k"].IsChecked = [bool]$Cfg[$k] }
        $U.CutoffBox.Text = [string]$Cfg.Win10Cutoff
        Update-WinVersion
        $U.SignJobsBox.Text = [string](Get-SignJobs)
        $U.EdJobsBox.Text = [string](Get-EditionJobs 4 1e6).Wanted
        $U.WorkBox.Text = [string]$Cfg.WorkDir
        if (-not $U.IsoBox.Text -and $S.SourceIso) { $U.IsoBox.Text = $S.SourceIso }

        # 1 source
        $imgs = @($S.Images)
        if ($S.Family -and $imgs.Count) {
            $U.ImgInfo.Text = '{0}  -  build {1}  -  {2}  -  {3} edition(s)' -f $S.Family.Name, $imgs[0].Version, $S.Family.Arch, $imgs.Count
            $U.ImgNote.Text = if (-not $S.Family.Supported) { 'No automatic updates for this build - drivers, signed packages, answer file and $OEM$ still work.' }
                              elseif ($S.Family.Cap -and (Get-FamilyOs $S.Family) -eq '10') { "Updates up to $($Cfg.Win10Cutoff) (the last month Microsoft allows offline for Windows 10)." }
                              elseif ($S.Family.Cap) { "Its last updates ($($S.Family.Cap)) - this version is out of servicing." }
                              else { 'Newest updates available in the Microsoft Update Catalog.' }
            if ($S.Family.Supported -and $S.Family.NeedsEkb) { $U.ImgNote.Text += " The $(if ($S.Family.EkbFor) { $S.Family.EkbFor } else { '22H2' }) enablement package is added too." }
        } else { $U.ImgInfo.Text = 'Nothing unpacked yet.'; $U.ImgNote.Text = '' }
        $U.ImgGrid.ItemsSource = (New-Table @('Index:int', 'Edition', 'EditionId', 'Build', 'Size', 'Language') @(foreach ($i in $imgs) { , @($i.Index, $i.Name, $i.Edition, $i.Version, (Format-Size $i.Size), $i.Langs) })).DefaultView

        # 2 editions
        $sel = @($S.Selected | ForEach-Object { [int]$_ })
        $Script:EdTable = New-Table @('Use:bool', 'Index:int', 'Edition', 'EditionId', 'Build', 'SizeGB:dbl') @(foreach ($i in $imgs) { , @(($sel -contains [int]$i.Index), $i.Index, $i.Name, $i.Edition, $i.Version, [math]::Round($i.Size / 1GB, 1)) })
        $Script:EdTable.add_ColumnChanged({ param($sender, $ev) if (-not $Script:Loading -and $ev.Column.ColumnName -eq 'Use') { Save-EditionPick } })
        $U.EdGrid.ItemsSource = $Script:EdTable.DefaultView

        # 3 updates
        $U.UpdGrid.ItemsSource = (New-Table @('Kind', 'KB', 'Date', 'Title') @(foreach ($upd in @($S.Updates)) { , @($upd.Kind, $upd.KB, $upd.Date, $upd.Title) })).DefaultView

        # 4 drivers
        $d = @($S.Drivers)
        $n = 0
        $U.DrvGrid.ItemsSource = (New-Table @('No:int', 'Source', 'Class', 'Provider', 'Version', 'Inf', 'SizeMB:dbl', 'Folder') @(foreach ($x in $d) { $n++; , @($n, $x.Source, $x.Class, $x.Provider, $x.Version, $x.Inf, [double]$x.SizeMB, $x.Folder) })).DefaultView
        if ($d.Count) {
            $mb = 0.0; foreach ($x in $d) { $mb += [double]$x.SizeMB }
            $boot = @($d | Where-Object { $Script:BootClasses -contains $_.Class }).Count
            $U.DrvSum.Text = '{0} driver package(s), {1} storage/network for boot.wim and WinRE, about {2:N0} MB' -f $d.Count, $boot, $mb
        } else { $U.DrvSum.Text = 'No drivers selected.' }

        # 5 signed
        $U.SignGrid.ItemsSource = (New-Table @('Name', 'InstallsFrom', 'Signed:int', 'Failed:int', 'INFs', 'Engine', 'When', 'Source') @(foreach ($x in @($S.Signed | Where-Object { $_ })) { , @($x.Name, $x.InstallDir, [int]$x.Signed, [int]$x.Failed, $(if ($x.OnlyThisPc) { "this PC only ($(@($x.Kept).Count) kept)" } else { 'all' }), $(if ($x.Engine) { [string]$x.Engine } else { 'Inf2Cat' }), $x.When, $x.Source) })).DefaultView
        Update-SignDest
        Update-SignEngine
        $cs = 'create'; $c = $null
        try { $cs = Get-CertStatus; $c = Get-StoreCert } catch { }
        $U.CertInfo.Text = switch ($cs) {
            'ready'  { 'Ready - {0}, valid until {1:yyyy-MM-dd} (backed up as DriverSigning.pfx)' -f $c.Subject, $c.NotAfter }
            'export' { 'In this PC''s certificate store, not backed up yet - you will be asked for a password to save DriverSigning.pfx.' }
            'import' { 'DriverSigning.pfx found - its password is asked when you sign.' }
            default  { 'None yet - one is created the first time you sign (you choose its password).' }
        }

        # 6 answer file + oem
        $U.UnaCur.Text = if ($S.Unattend) { "$($S.Unattend.Source)   (added $($S.Unattend.Added))" } else { 'none' }
        if ($S.Oem -and $S.Oem.Source) {
            $U.OemCur.Text = [string]$S.Oem.Source
            $U.OemInfo.Text = Get-OemSummary ([string]$S.Oem.Source)
        } else { $U.OemCur.Text = 'none'; $U.OemInfo.Text = '' }

        # 7 build
        if ($S.Iso -and (Test-Path -LiteralPath $S.Iso)) {
            $U.IsoInfo.Text = '{0}   ({1})' -f $S.Iso, (Format-Size (Get-Item -LiteralPath $S.Iso).Length)
            $h = "$($S.Iso).sha256"
            $U.IsoHash.Text = if (Test-Path -LiteralPath $h) { 'SHA-256  ' + ((Get-Content -LiteralPath $h -Raw) -split '\s')[0] } else { '' }
        } elseif ($S.Serviced) {
            $U.IsoInfo.Text = "Slipstreamed on $($S.Serviced.When) - build $($S.Serviced.Build). Build the ISO next."
            $U.IsoHash.Text = ''
        } else { $U.IsoInfo.Text = 'No ISO built yet.'; $U.IsoHash.Text = '' }

        Update-Tools
        Show-CheckResults
    } finally { $Script:Loading = $false }
}
function Show-CheckResults {
    $U = $Script:U
    $f = Join-Path $Script:P.Work 'install-check.json'
    $rows = @()
    if (Test-Path -LiteralPath $f) {
        # Windows PowerShell 5.1 returns a JSON array as ONE object - unroll it, or every
        # column shows System.Object[] and the fixes are sent as one meaningless string
        try { $parsed = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; $rows = @(foreach ($one in $parsed) { $one }) } catch { }
    }
    $Script:CheckRows = $rows
    $U.ChkGrid.ItemsSource = (New-Table @('Level', 'Area', 'Finding', 'FixText', 'Fix') @(foreach ($r in $rows) { , @($r.Level, $r.Area, $r.Finding, $r.FixText, $r.Fix) })).DefaultView
    $c = $Script:S.Check
    if ($c) {
        $U.ChkSum.Text = '{0} error(s), {1} warning(s), {2} check(s) passed   -   {3}' -f $c.Errors, $c.Warnings, $c.Passed, $c.When
        $U.ChkSum.Foreground = New-Brush $(if ([int]$c.Errors) { '#FF5C7A' } elseif ([int]$c.Warnings) { '#FFC857' } else { '#3DDC97' })
    } else { $U.ChkSum.Text = 'Not run yet.'; $U.ChkSum.Foreground = New-Brush '#E6EAF2' }
    $nf = @($rows | Where-Object { $_.Fix }).Count
    $U.ChkFix.IsEnabled = $nf -gt 0
    $U.ChkFix.Content = if ($nf) { "Apply $nf fix(es)" } else { 'Apply all fixes' }
    $fixed = $Script:S.Unattend -and $Script:S.Unattend.Fixed
    $U.ChkUndo.IsEnabled = [bool]$fixed
    $U.ChkSave.IsEnabled = [bool]$fixed
    $U.ChkNote.Text = if ($fixed) { "The ISO uses a fixed copy of your answer file (fixed $($Script:S.Unattend.Fixed)). Save it to update your own file too." } else { '' }
}
# A borderless WPF window maximizes over the taskbar, so "maximized" is done by hand:
# the window is sized to the working area of the monitor it is on.
function Set-WorkAreaMax([bool]$On) {
    $w = $Script:W
    if ($On) {
        $Script:NormalBounds = @($w.Left, $w.Top, $w.Width, $w.Height)
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $w).Handle
        $wa = [System.Windows.Forms.Screen]::FromHandle($h).WorkingArea
        $m = [System.Windows.PresentationSource]::FromVisual($w).CompositionTarget.TransformFromDevice
        $tl = $m.Transform((New-Object System.Windows.Point ($wa.Left, $wa.Top)))
        $br = $m.Transform((New-Object System.Windows.Point ($wa.Right, $wa.Bottom)))
        $w.Left = $tl.X; $w.Top = $tl.Y; $w.Width = $br.X - $tl.X; $w.Height = $br.Y - $tl.Y
        $Script:FakeMax = $true
        $Script:U.MaxBtn.Content = [string][char]0xE923
    } else {
        if ($Script:NormalBounds) { $w.Left = $Script:NormalBounds[0]; $w.Top = $Script:NormalBounds[1]; $w.Width = $Script:NormalBounds[2]; $w.Height = $Script:NormalBounds[3] }
        $Script:FakeMax = $false
        $Script:U.MaxBtn.Content = [string][char]0xE922
    }
}
function Get-OemSummary([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return 'folder not found' }
    if ($Script:OemCache -and $Script:OemCache[0] -eq $Dir) { return $Script:OemCache[1] }
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)
    $mb = ($files | Measure-Object -Property Length -Sum).Sum
    $parts = @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $txt = '{0} files, {1}   ({2})' -f $files.Count, (Format-Size ([double]$mb)), ($parts -join ', ')
    if (Test-Path -LiteralPath (Join-Path $Dir '$$\Setup\Scripts\SetupComplete.cmd')) { $txt += '   - has SetupComplete.cmd' }
    $Script:OemCache = @($Dir, $txt)
    return $txt
}
function Update-Tools {
    $U = $Script:U
    $ok = New-Brush '#3DDC97'; $no = New-Brush '#FFC857'
    $U.T_Dism.Text = $Script:Dism; $U.T_Dism.Foreground = $ok
    $set = {
        param($tb, $path, $missing)
        if ($path) { $tb.Text = $path; $tb.Foreground = $ok } else { $tb.Text = $missing; $tb.Foreground = $no }
    }
    $osc = Find-Oscdimg; $inf = Find-Tool 'Inf2Cat.exe'; $sig = Find-Tool 'signtool.exe'; $mkc = Find-Tool 'makecat.exe'
    $eng = Get-SignEngine
    & $set $U.T_Osc $osc 'missing - downloaded automatically when you build the ISO'
    & $set $U.T_Inf $inf $(if ($eng -eq 'inf2cat') { 'missing - downloaded automatically when you sign drivers' } else { 'missing - downloaded only if the signing engine needs Inf2Cat as fallback' })
    & $set $U.T_Sign $sig 'missing - downloaded automatically when you sign drivers'
    & $set $U.T_Mkc $mkc $(if ($eng -eq 'makecat') { 'missing - downloaded automatically when you sign drivers' } else { 'missing - only needed for the MakeCat signing engine' })
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    & $set $U.T_Curl $(if (Test-Path -LiteralPath $curl) { $curl }) 'missing - PowerShell / BITS downloads are used'
    $cat = switch ($eng) { 'inf2cat' { $inf } 'makecat' { $mkc } default { $true } }
    $U.ToolsDot.Text = if ($osc -and $cat -and $sig) { '' } else { [string][char]0x25CF }
}
function Save-EditionPick {
    $sel = @(foreach ($r in $Script:EdTable.Rows) { if ($r['Use'] -eq $true) { [int]$r['Index'] } })
    $Script:S.Selected = $sel
    Save-State
    Update-Status
}
# Page 5: the signing engine buttons and what the chosen engine does.
function Update-SignEngine {
    $U = $Script:U
    $e = Get-SignEngine
    $U.SignEngMakeCat.IsChecked = ($e -eq 'makecat'); $U.SignEngLibwdi.IsChecked = ($e -eq 'libwdi')
    $U.SignEngGenCat.IsChecked = ($e -eq 'gencat'); $U.SignEngInf2Cat.IsChecked = ($e -eq 'inf2cat')
    $U.SignEngNote.Text = switch ($e) {
        'makecat' { 'Default. makecat.exe (Windows SDK) builds one catalog per driver folder with the hash of every file in it, so each file is hashed once - about 20 s for NVIDIA''s 3 GB Display.Driver instead of minutes. Compressed files (name.dl_) are hashed expanded, the way Windows checks them. MakeCat does not parse the INF: every catalog is checked with signtool afterwards, and a folder MakeCat cannot do goes to Inf2Cat.' }
        'libwdi'  { 'Experimental. The catalog is built with the CryptCAT API of Windows itself, the way libwdi (Zadig) does it - nothing to download. One catalog per driver folder with the hash of every file in it (SHA-1). Checked with signtool afterwards; a folder it cannot do goes to Inf2Cat.' }
        'gencat'  { 'Experimental. LINBIT generate-cat-file (GPL-2.0): its source is downloaded from GitHub (one pinned commit, SHA-256 checked) and built inside WSL - needs WSL with a Linux distribution that has gcc and make. One catalog per driver folder; Inf2Cat signs when WSL or the build is missing.' }
        default   { 'Microsoft''s standard tool from the Windows Driver Kit: it parses every INF and checks it against every file of the package. The proven choice, but slow on big packages - the options below make it faster.' }
    }
}
function Update-SignDest {
    $n = ConvertTo-PackageName $Script:U.SignName.Text
    $Script:U.SignDest.Text = "installs from C:\Drivers\$n during Windows setup"
}
#endregion

#region ---------------------------------------------------------------- dialogs
function Show-DriverPicker($Items, [string]$Title, [string]$SubText) {
    $arch = if ($Script:S.Family) { [string]$Script:S.Family.Arch } else { '' }
    $D = New-Xaml $Script:XPicker
    $Script:PickD = $D
    $D.W.Owner = $Script:W
    $n = 0
    $Script:PickTable = New-Table @('Use:bool', 'No:int', 'Class', 'Provider', 'Version', 'Date', 'Arch', 'SizeMB:dbl', 'Older:bool', 'Inf', 'Folder') @(foreach ($x in @($Items)) {
        $n++; , @(((Test-DriverArch ([string]$x.Arch) $arch) -and -not [bool]$x.Older), $n, $x.Class, $x.Provider, $x.Version, $x.Date, [string]$x.Arch, [double]$x.'Size (MB)', [bool]$x.Older, $x.Inf, $x.Folder) })
    $old = @($Items | Where-Object { $_.Older }).Count
    if ($old) { $SubText += " $old older version(s) of drivers that are here in a newer version too are unticked (column Older) - Windows uses the newest one." }
    $Script:PickArch = $arch
    $D.U.PTitle.Text = $Title
    $D.U.PSub.Text = $SubText
    $D.U.PGrid.Add_AutoGeneratingColumn({ param($s, $e) if ($e.PropertyName -eq 'Use') { $e.Cancel = $true } else { $e.Column.IsReadOnly = $true } })
    $D.U.PGrid.ItemsSource = $Script:PickTable.DefaultView
    $count = { $c = @($Script:PickTable.Select('Use = true')).Count; $Script:PickD.U.PCount.Text = "$c of $($Script:PickTable.Rows.Count) ticked" }
    $Script:PickCount = $count
    & $count
    $Script:PickTable.add_ColumnChanged({ & $Script:PickCount })
    $D.U.PFilter.Add_TextChanged({
        $f = $Script:PickD.U.PFilter.Text.Replace("'", "''").Replace('[', '[[]').Replace('*', '[*]').Replace('%', '[%]')
        $Script:PickTable.DefaultView.RowFilter = if ($f) { "Class LIKE '*$f*' OR Provider LIKE '*$f*' OR Inf LIKE '*$f*' OR Folder LIKE '*$f*'" } else { '' }
    })
    $D.U.PFit.Add_Click({ foreach ($r in $Script:PickTable.Rows) { $r['Use'] = (Test-DriverArch ([string]$r['Arch']) $Script:PickArch) -and -not [bool]$r['Older'] } })
    $D.U.PShown.Add_Click({ foreach ($rv in $Script:PickTable.DefaultView) { $rv.Row['Use'] = $true } })
    $D.U.PNone.Add_Click({ foreach ($r in $Script:PickTable.Rows) { $r['Use'] = $false } })
    $D.U.POk.Add_Click({ $Script:PickD.W.DialogResult = $true })
    if (-not $D.W.ShowDialog()) { return @() }
    $items = @($Items)
    return @(foreach ($r in $Script:PickTable.Rows) { if ($r['Use'] -eq $true) { $items[[int]$r['No'] - 1] } })
}
function Show-PasswordDialog([string]$Mode) {
    $D = New-Xaml $Script:XPass
    $Script:PwD = $D
    $Script:PwMode = $Mode
    $D.W.Owner = $Script:W
    $D.U.PwText.Text = switch ($Mode) {
        'import' { 'DriverSigning.pfx was found next to this tool. Enter its password to load your signing certificate.' }
        'export' { 'Your signing certificate is in this PC''s store but has no backup yet. Choose a password to save it as DriverSigning.pfx - you need it to sign again after reinstalling Windows.' }
        default  { 'A new self-signed code-signing certificate will be created. Choose a password for its backup file DriverSigning.pfx - you need it to sign again after reinstalling Windows.' }
    }
    if ($Mode -eq 'import') { $D.U.Pw2Panel.Visibility = 'Collapsed' }
    $D.U.PwOk.Add_Click({
        $a = $Script:PwD.U.Pw1.Password
        if (-not $a) { $Script:PwD.U.PwErr.Text = 'Enter a password.'; return }
        if ($Script:PwMode -ne 'import' -and $a -cne $Script:PwD.U.Pw2.Password) { $Script:PwD.U.PwErr.Text = 'The passwords do not match.'; return }
        $Script:PwD.W.DialogResult = $true
    })
    $D.W.Add_ContentRendered({ [void]$Script:PwD.U.Pw1.Focus() })
    if ($D.W.ShowDialog()) { return $D.U.Pw1.SecurePassword }
    return $null
}
#endregion
