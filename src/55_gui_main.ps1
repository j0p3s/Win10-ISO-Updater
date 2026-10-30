
#region ---------------------------------------------------------------- page actions
function Test-Unpacked {
    if ($Script:S.Unpacked) { return $true }
    Show-Msg 'Unpack an ISO first (page 1).'
    $Script:U.Nav1.IsChecked = $true
    return $false
}
function Invoke-UnpackClick {
    $iso = $Script:U.IsoBox.Text.Trim().Trim('"')
    if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { Show-Msg 'Choose an existing .iso file first.' 'Warning'; return }
    if ($Script:S.Unpacked -and (Test-Path -LiteralPath (Join-Path $Script:P.Media 'sources'))) {
        if (-not (Confirm-Ui "The work folder already has unpacked media ($(Split-Path ([string]$Script:S.SourceIso) -Leaf)). Replace it with a fresh copy of this ISO?")) { return }
    }
    Start-Work 'Unpack' @{ Iso = $iso; NoAsk = $true } { if (@($Script:S.Images).Count -gt 1) { $Script:U.Nav2.IsChecked = $true } }
}
function Invoke-HostDriversClick {
    Start-Work 'ScanHost' @{} {
        $items = @($Script:Sync.Result)
        if ($items.Count -eq 0) { return }
        $pick = @(Show-DriverPicker $items 'Drivers installed on this PC' 'Third-party drivers exported from this PC. Ticked ones are slipstreamed into the ISO.')
        Start-Work 'CommitHost' @{ Pick = $pick }
    }
}
function Invoke-ImportDriversClick {
    $start = @(Find-DriverBackupFolders) | Select-Object -First 1
    $dir = Select-Folder 'Pick the drivers folder - Drivers-Backup made by Drivers.cmd, a folder from another PC or a vendor pack. All subfolders are scanned.' $start
    if (-not $dir) { return }
    $Script:ImportDir = $dir
    Start-Work 'ScanFolder' @{ Dir = $dir } {
        $items = @($Script:Sync.Result)
        if ($items.Count -eq 0) { Show-Msg 'No .inf drivers in that folder.' 'Warning'; return }
        $pick = @(Show-DriverPicker $items "Drivers in $($Script:ImportDir)" 'Drivers built for another architecture than the ISO are unticked and left out.')
        if ($pick.Count -gt 0) { Start-Work 'CommitImport' @{ Dir = $Script:ImportDir; Pick = $pick } }
    }
}
function Invoke-SignClick {
    $src = $Script:U.SignSrc.Text.Trim().Trim('"')
    if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Container)) { Show-Msg 'Choose the driver folder first (for example the folder NVCleanstall extracted).' 'Warning'; return }
    $hasInf = Get-ChildItem -LiteralPath $src -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hasInf) { Show-Msg 'There are no .inf files in that folder or its subfolders.' 'Warning'; return }
    $name = ConvertTo-PackageName $Script:U.SignName.Text
    $mode = Get-CertStatus
    $pw = $null
    if ($mode -ne 'ready') {
        $pw = Show-PasswordDialog $mode
        if (-not $pw) { return }
    }
    Start-Work 'Sign' @{ Source = $src; Name = $name; Password = $pw; All = [bool]$Script:U.SignAll.IsChecked }
}
function Invoke-ServiceClick {
    if (-not (Test-Unpacked)) { return }
    if (@($Script:S.Selected).Count -eq 0) { Show-Msg 'Tick at least one edition first.'; $Script:U.Nav2.IsChecked = $true; return }
    if ($Script:S.Serviced -and -not (Confirm-Ui "This media was already slipstreamed on $($Script:S.Serviced.When). For a clean result unpack the ISO again (page 1). Slipstream again anyway?" 'Warning')) { return }
    if (@($Script:S.Updates).Count -eq 0 -and $Script:S.Family.Supported -and
        -not (Confirm-Ui 'No updates are downloaded (page 3). Continue with drivers and options only?')) { return }
    Start-Work 'Service' @{} { $Script:U.Nav7.IsChecked = $true }
}
function Invoke-BuildClick {
    if (-not (Test-Unpacked)) { return }
    if (-not $Script:S.Serviced -and -not (Confirm-Ui 'The media has not been slipstreamed yet. Build the ISO anyway (drivers, updates and options are then missing)?' 'Warning')) { return }
    Start-Work 'Build' @{ Out = $Script:U.OutBox.Text.Trim().Trim('"') }
}
function Invoke-FixClick {
    $fixes = @($Script:CheckRows | Where-Object { $_.Fix } )
    if ($fixes.Count -eq 0) { Show-Msg 'Nothing to fix automatically - run the check first. Findings without a fix need a change on the page they mention.'; return }
    $txt = ($fixes | ForEach-Object { '- ' + $_.FixText } | Sort-Object -Unique) -join "`n"
    if (-not (Confirm-Ui ("Apply these fixes? They change the copies that go into the ISO, not your own files.`n`n" + $txt))) { return }
    Start-Work 'Fix' @{ Fixes = @($fixes | ForEach-Object { [string]$_.Fix } | Sort-Object -Unique) } { Show-CheckResults }
}
function Invoke-RunAllClick {
    $iso = $Script:U.IsoBox.Text.Trim().Trim('"')
    if (-not $iso) { $iso = [string]$Script:S.SourceIso }
    if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { Show-Msg 'Choose the source ISO on page 1 first.' 'Warning'; $Script:U.Nav1.IsChecked = $true; return }
    $lines = @("Source: $(Split-Path $iso -Leaf)")
    $lines += "Editions: $(if (@($Script:S.Selected).Count) { "$(@($Script:S.Selected).Count) ticked" } else { 'asked after unpacking' })"
    $lines += "Drivers: $(@($Script:S.Drivers).Count)   Signed packages: $(@($Script:S.Signed | Where-Object { $_ }).Count)"
    $lines += "Answer file: $(if ($Script:S.Unattend) { 'yes' } else { 'no' })   `$OEM`$: $(if ($Script:S.Oem) { 'yes' } else { 'no' })"
    if (-not (Confirm-Ui ("Run everything now? It takes 30-90 minutes - the PC is kept awake until it is done.`n`n" + ($lines -join "`n")))) { return }
    Start-Work 'All' @{ Iso = $iso; Out = $Script:U.OutBox.Text.Trim().Trim('"') }
}
#endregion

#region ---------------------------------------------------------------- main
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Data
    $Sync = [hashtable]::Synchronized(@{
        Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = ''
        Question = $null; Answer = $null; Result = $null
    })
    $Script:Busy = $false
    $Script:CfgToggles = @('KeepOnlySelected', 'NetFx3', 'NetFx481', 'ResetBase', 'BootDrivers', 'ForceUnsigned', 'NoPrompt', 'Boot2023', 'SplitFat32', 'SignCleanup', 'InstallOemDrivers', 'SignOnlyThisPc', 'SignIsolate', 'ParallelBoot', 'DefenderExclude', 'BootSkipPE')
    $Script:Cfg = Import-Settings
    Initialize-Paths
    $Script:S = Import-State
    try { Disable-DefenderSkip } catch { }     # exclusion left behind if the program was closed during a job

    # background worker with its own copy of the engine
    $all = [IO.File]::ReadAllText($env:W10U_SELF)
    $b = $all.IndexOf('#ENGINE-' + 'BEGIN'); $e = $all.IndexOf('#ENGINE-' + 'END')
    if ($b -lt 0 -or $e -lt $b) { throw 'Engine section not found in this file.' }
    $Script:RS = [runspacefactory]::CreateRunspace([Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
    $Script:RS.Open()
    $Script:RS.SessionStateProxy.SetVariable('Sync', $Sync)
    $Script:RS.SessionStateProxy.SetVariable('IsWorker', $true)
    $init = [PowerShell]::Create(); $init.Runspace = $Script:RS
    [void]$init.AddScript($all.Substring($b, $e - $b)).Invoke()
    if ($init.HadErrors) { throw "Worker failed to start: $($init.Streams.Error[0])" }
    $init.Dispose()

    $Script:ThemeNow = Get-ThemeName          # the window is built in the saved theme, font and text size
    $M = New-Xaml $Script:XMain
    $Script:W = $M.W; $Script:U = $M.U
    $W = $Script:W; $U = $Script:U
    $U.VerRun.Text = "  v$Script:AppVersion"
    Set-UiLook
    try { $W.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo } catch { }
    $W.Add_Activated({ if (-not $Script:Busy) { Set-TaskbarState 'None' } })

    # title bar
    $U.MinBtn.Add_Click({ $Script:W.WindowState = 'Minimized' })
    $U.MaxBtn.Add_Click({ Set-WorkAreaMax (-not $Script:FakeMax) })
    $U.CloseBtn.Add_Click({ $Script:W.Close() })
    # top right: theme switch, and the display / accessibility panel (theme, text size, font)
    $U.ThemeBtn.Add_Click({
        $Script:Cfg.UiTheme = if ($Script:ThemeNow -eq 'Light') { 'Dark' } else { 'Light' }
        Save-Settings; Set-Theme; Update-Ui
    })
    $Script:A11yClosed = [datetime]::MinValue
    $U.A11yPop.Add_Closed({ $Script:A11yClosed = Get-Date })
    $U.A11yBtn.Add_Click({
        if (((Get-Date) - $Script:A11yClosed).TotalMilliseconds -lt 300) { return }     # this click just closed it
        $Script:U.A11yPop.IsOpen = $true
        $first = @($Script:U.ThemeDark, $Script:U.ThemeLight, $Script:U.ThemeSystem) | Where-Object { $_.IsChecked } | Select-Object -First 1
        if ($first) { [void]$first.Focus() }
    })
    $U.A11yPanel.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $Script:U.A11yPop.IsOpen = $false; [void]$Script:U.A11yBtn.Focus(); $e.Handled = $true } })
    foreach ($x in @(@('ThemeDark', 'Dark'), @('ThemeLight', 'Light'), @('ThemeSystem', 'System'))) {
        $U[$x[0]].Tag = $x[1]
        $U[$x[0]].Add_Click({ $Script:Cfg.UiTheme = [string]$this.Tag; Save-Settings; Set-Theme; Update-Ui })
    }
    foreach ($n in 100, 115, 130, 150) {
        $U["Zoom$n"].Tag = $n
        $U["Zoom$n"].Add_Click({ $Script:Cfg.UiZoom = [int]$this.Tag; Save-Settings; Set-UiLook })
    }
    foreach ($x in @(@('FontSegoe', 'Segoe UI'), @('FontVerdana', 'Verdana'), @('FontTahoma', 'Tahoma'), @('FontArial', 'Arial'))) {
        $U[$x[0]].Tag = $x[1]
        $U[$x[0]].Add_Click({ $Script:Cfg.UiFont = [string]$this.Tag; Save-Settings; Set-UiLook })
    }
    # Ctrl + plus / minus / 0 and Ctrl + mouse wheel change the text size anywhere in the window
    $W.Add_PreviewKeyDown({ param($s, $e)
        if (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -eq 0) { return }
        $dir = switch ([string]$e.Key) { 'OemPlus' { 1 } 'Add' { 1 } 'OemMinus' { -1 } 'Subtract' { -1 } 'D0' { 0 } 'NumPad0' { 0 } default { $null } }
        if ($null -ne $dir) { Step-UiZoom $dir; $e.Handled = $true }
    })
    $W.Add_PreviewMouseWheel({ param($s, $e)
        if (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -eq 0) { return }
        Step-UiZoom $(if ($e.Delta -gt 0) { 1 } else { -1 }); $e.Handled = $true
    })
    # double-click on the title bar, Win+Up or Aero Snap ask Windows to maximize - redirect that to the work area
    $W.Add_StateChanged({
        if ($Script:W.WindowState -eq 'Maximized') { $Script:W.WindowState = 'Normal'; Set-WorkAreaMax (-not $Script:FakeMax) }
    })
    # never start taller / wider than the screen minus the taskbar
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($W.Height -gt $wa.Height - 16) { $W.Height = [math]::Max(600, $wa.Height - 16) }
    if ($W.Width -gt $wa.Width - 16) { $W.Width = [math]::Max(900, $wa.Width - 16) }
    if ($W.MinHeight -gt $W.Height) { $W.MinHeight = $W.Height }

    # navigation
    for ($i = 1; $i -le 10; $i++) { $nb = $U["Nav$i"]; $nb.Tag = $i - 1; $nb.Add_Checked({ $Script:U.Pages.SelectedIndex = [int]$this.Tag }) }
    $U.Pages.SelectedIndex = 0

    # option toggles (saved instantly)
    foreach ($k in $Script:CfgToggles) {
        $cb = $U["cfg_$k"]; $cb.Tag = $k
        $cb.Add_Click({
            $Script:Cfg[$this.Tag] = [bool]$this.IsChecked
            Save-Settings
            if ($this.Tag -eq 'DefenderExclude' -and $this.IsChecked) {
                Show-Msg ("While a job runs (unpack, download, sign, slipstream, build), Windows Defender does not scan the work folder " +
                          "($($Script:P.Work)). The exclusion is removed when the job ends, and at the next start if the program was closed during a job. " +
                          'Everything in there comes from Microsoft, your drivers and this tool - do not put other downloads in that folder.') 'Information'
            }
            if ($this.Tag -eq 'SignOnlyThisPc' -and $this.IsChecked) {
                Show-Msg ("Use this only when the ISO is for this PC. INF files for other hardware are removed from the signed copy, so the driver " +
                          "installs only on hardware that matches this PC. NVIDIA's own setup.exe may refuse to run from that copy - pnputil installs " +
                          'the driver anyway. Sign the package again for it to take effect.') 'Information'
            }
            if ($this.Tag -eq 'Boot2023' -and $this.IsChecked) {
                Show-Msg ("With Secure Boot on, this ISO only boots on PCs whose UEFI already trusts 'Windows UEFI CA 2023'. Older firmware needs that " +
                          'Secure Boot update first (or Secure Boot off). The image also needs a 2024-04 or newer update.') 'Warning'
            }
        })
    }
    $U.CutoffBox.Add_LostFocus({
        $v = $Script:U.CutoffBox.Text.Trim()
        if ($v -match '^\d{4}-\d{2}$') { $Script:Cfg.Win10Cutoff = $v; Save-Settings }
        else { $Script:U.CutoffBox.Text = [string]$Script:Cfg.Win10Cutoff; if ($v) { Show-Msg 'Use the YYYY-MM format, e.g. 2025-10.' } }
    })
    $U.SignJobsBox.Add_LostFocus({
        $v = $Script:U.SignJobsBox.Text.Trim()
        if (-not $v) { $Script:Cfg.SignJobs = 0; Save-Settings }
        elseif ($v -match '^[1-8]$') { if ([int]$v -ne (Get-SignJobs)) { $Script:Cfg.SignJobs = [int]$v; Save-Settings } }
        else { Show-Msg 'Use a number from 1 to 8 (or leave it empty for the number of processor cores, up to 8).' }
        $Script:U.SignJobsBox.Text = [string](Get-SignJobs)
    })

    # 1 source
    $U.IsoBrowse.Add_Click({
        $start = if ($Script:S.SourceIso) { Split-Path ([string]$Script:S.SourceIso) -Parent } else { Join-Path $env:USERPROFILE 'Downloads' }
        $f = Select-File "Select a Windows $(if ($Script:Cfg.WinVersion -eq '11') { '11' } else { '10' }) ISO" 'ISO images (*.iso)|*.iso' $start
        if ($f) { $Script:U.IsoBox.Text = $f }
    })
    $U.UnpackBtn.Add_Click({ Invoke-UnpackClick })
    $U.AnalyzeBtn.Add_Click({ if (Test-Unpacked) { Start-Work 'Analyze' } })
    $U.GetIsoBtn.Add_Click({ Start-Process $(if ($Script:Cfg.WinVersion -eq '11') { $Script:IsoPageUrl11 } else { $Script:IsoPageUrl }) })
    foreach ($rb in @($U.WinVer10, $U.WinVer11)) {
        $rb.Add_Click({
            $Script:Cfg.WinVersion = if ($Script:U.WinVer11.IsChecked) { '11' } else { '10' }
            Save-Settings
            Update-WinVersion
        })
    }
    # 2 editions
    $U.EdGrid.Add_AutoGeneratingColumn({ param($s, $e) if ($e.PropertyName -eq 'Use') { $e.Cancel = $true } else { $e.Column.IsReadOnly = $true } })
    $U.EdAll.Add_Click({ $Script:Loading = $true; foreach ($r in $Script:EdTable.Rows) { $r['Use'] = $true }; $Script:Loading = $false; Save-EditionPick })
    $U.EdNone.Add_Click({ $Script:Loading = $true; foreach ($r in $Script:EdTable.Rows) { $r['Use'] = $false }; $Script:Loading = $false; Save-EditionPick })
    # 3 updates
    $U.UpdBtn.Add_Click({ if (Test-Unpacked) { Start-Work 'Download' } })
    # 4 drivers
    $U.DrvHost.Add_Click({ Invoke-HostDriversClick })
    $U.DrvImport.Add_Click({ Invoke-ImportDriversClick })
    $U.DrvRemove.Add_Click({
        $nums = @($Script:U.DrvGrid.SelectedItems | ForEach-Object { [int]$_.Row['No'] })
        if ($nums.Count -eq 0) { Show-Msg 'Select the drivers to remove in the list first (Ctrl+click for several).'; return }
        Remove-DriverEntries $nums; Update-Ui
    })
    $U.DrvClear.Add_Click({
        if (@($Script:S.Drivers).Count -and (Confirm-Ui 'Remove every selected driver?')) {
            Remove-Item -LiteralPath $Script:P.DrvSel -Recurse -Force -ErrorAction SilentlyContinue
            $Script:S.Drivers = @(); Save-State; Update-Ui
        }
    })
    # 5 signed drivers
    $U.SignBrowse.Add_Click({
        $d = Select-Folder 'Pick the modded driver folder (e.g. the folder NVCleanstall extracted). All subfolders are scanned.' $Script:U.SignSrc.Text
        if ($d) {
            $Script:U.SignSrc.Text = $d
            $leaf = Split-Path $d -Leaf
            $Script:U.SignName.Text = if ($leaf -match '(?i)nvidia|nvcleanstall|geforce|^\d{3}\.\d{2}') { 'NVIDIA' } else { ConvertTo-PackageName $leaf }
        }
    })
    $U.SignName.Add_TextChanged({ Update-SignDest })
    foreach ($x in @(@('SignEngMakeCat', 'makecat'), @('SignEngLibwdi', 'libwdi'), @('SignEngGenCat', 'gencat'), @('SignEngInf2Cat', 'inf2cat'))) {
        $rb = $U[$x[0]]; $rb.Tag = $x[1]
        $rb.Add_Click({
            $Script:Cfg.SignEngine = [string]$this.Tag
            Save-Settings
            Update-SignEngine
            Update-Tools
        })
    }
    $U.SignBtn.Add_Click({ Invoke-SignClick })
    $U.SignOpen.Add_Click({ New-Item -ItemType Directory -Force -Path $Script:SignDir | Out-Null; Open-Path $Script:SignDir })
    $U.SignRemove.Add_Click({
        $names = @($Script:U.SignGrid.SelectedItems | ForEach-Object { [string]$_.Row['Name'] })
        if ($names.Count -eq 0) { Show-Msg 'Select a package in the list first.'; return }
        foreach ($n in $names) { Remove-SignedPackage $n }
        Write-Ok "Removed: $($names -join ', ') (taken out of the media at the next build)"
        Update-Ui
    })
    # 6 answer file + oem
    $U.UnaPick.Add_Click({
        $f = Select-File 'Select your autounattend.xml' 'Answer files (*.xml)|*.xml' (Join-Path $env:USERPROFILE 'Downloads')
        if ($f) { try { Set-UnattendFile $f } catch { Show-Msg $_.Exception.Message 'Error' }; Update-Ui }
    })
    $U.UnaGen.Add_Click({ Start-Process $Script:GeneratorUrl })
    $U.UnaRemove.Add_Click({ Clear-UnattendFile; Update-Ui })
    $U.OemPick.Add_Click({
        $start = if ($Script:S.Oem) { [string]$Script:S.Oem.Source } else { $null }
        $d = Select-Folder 'Pick your $OEM$ folder (the one that contains $1 and/or $$)' $start
        if ($d) { $Script:OemCache = $null; Set-OemFolder $d; Update-Ui }
    })
    $U.OemOpen.Add_Click({ if ($Script:S.Oem) { Open-Path ([string]$Script:S.Oem.Source) } })
    $U.OemRemove.Add_Click({ Set-OemFolder $null; Update-Ui })
    # 7 build
    $U.OutBrowse.Add_Click({
        $d = New-Object Microsoft.Win32.SaveFileDialog
        $d.Filter = 'ISO image (*.iso)|*.iso'; $d.FileName = if ($Script:S -and $Script:S.Family) { 'Win' + (Get-FamilyOs $Script:S.Family) + '_custom.iso' } else { 'Windows_custom.iso' }
        if ($d.ShowDialog($Script:W)) { $Script:U.OutBox.Text = $d.FileName }
    })
    $U.SvcBtn.Add_Click({ Invoke-ServiceClick })
    $U.BuildBtn.Add_Click({ Invoke-BuildClick })
    $U.OpenOut.Add_Click({
        if ($Script:S.Iso -and (Test-Path -LiteralPath $Script:S.Iso)) { Start-Process explorer.exe "/select,`"$($Script:S.Iso)`"" } else { Open-Path $Script:P.Output }
    })
    # 8 options
    $U.WorkBrowse.Add_Click({ $d = Select-Folder 'Pick or create the work folder (NTFS, no spaces, ~30 GB free)' $Script:Cfg.WorkDir; if ($d) { $Script:U.WorkBox.Text = $d } })
    $U.WorkApply.Add_Click({
        $w = $Script:U.WorkBox.Text.Trim().Trim('"').TrimEnd('\')
        if (-not $w) { return }
        if ($w -match '\s' -and -not (Confirm-Ui 'The path has spaces - a short path like D:\W10U is safer for DISM. Use it anyway?' 'Warning')) { return }
        $Script:Cfg.WorkDir = $w; Save-Settings; Initialize-Paths; $Script:S = Import-State
        Write-Ok "Work folder: $w"
        Update-Ui
    })
    $U.WorkOpen.Add_Click({ Open-Path $Script:P.Work })
    $U.ClnAll.Add_Click({
        foreach ($n in 'ClnUpd', 'ClnMedia', 'ClnOut', 'ClnSigned', 'ClnDrivers', 'ClnExtra', 'ClnLogs') {
            $Script:U[$n].IsChecked = $Script:U.ClnAll.IsChecked; $Script:U[$n].IsEnabled = -not $Script:U.ClnAll.IsChecked
        }
    })
    $U.ClnBtn.Add_Click({
        $a = [ordered]@{ Updates = [bool]$Script:U.ClnUpd.IsChecked; Media = [bool]$Script:U.ClnMedia.IsChecked; Output = [bool]$Script:U.ClnOut.IsChecked; Signed = [bool]$Script:U.ClnSigned.IsChecked
                         Drivers = [bool]$Script:U.ClnDrivers.IsChecked; Extra = [bool]$Script:U.ClnExtra.IsChecked; Logs = [bool]$Script:U.ClnLogs.IsChecked; All = [bool]$Script:U.ClnAll.IsChecked }
        $names = @{ Updates = 'downloaded updates'; Media = 'unpacked media'; Output = 'built ISOs'; Signed = 're-signed driver copies'; Drivers = 'copied drivers'
                    Extra = 'answer file copy and check results'; Logs = 'logs'; All = 'EVERYTHING in the work folder' }
        $what = @('mounted images and temp files') + @($a.Keys | Where-Object { $a[$_] } | ForEach-Object { $names[$_] })
        if (Confirm-Ui ("Delete: " + ($what -join ', ') + '?') 'Warning') { Start-Work 'Clean' $a }
    })
    $U.DefBtn.Add_Click({
        if (-not (Confirm-Ui 'Restore the default options? The work folder is kept.')) { return }
        $keep = $Script:Cfg.WorkDir; $last = $Script:Cfg.LastDriverFolder
        $Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = $keep; $Script:Cfg.LastDriverFolder = $last
        Save-Settings; Update-Ui; Write-Ok 'Default options restored.'
    })
    # install check
    $U.ChkBtn.Add_Click({ Start-Work 'Check' @{} { Show-CheckResults } })
    $U.ChkFix.Add_Click({ Invoke-FixClick })
    $U.ChkSave.Add_Click({
        if (-not (Test-Path -LiteralPath $Script:P.Unattend)) { Show-Msg 'There is no answer file yet (page 6).'; return }
        $d = New-Object Microsoft.Win32.SaveFileDialog
        $d.Filter = 'Answer file (*.xml)|*.xml'; $d.FileName = 'autounattend.xml'
        if ($Script:S.Unattend -and $Script:S.Unattend.Source) { $d.InitialDirectory = Split-Path ([string]$Script:S.Unattend.Source) -Parent }
        if ($d.ShowDialog($Script:W)) { Copy-Item -LiteralPath $Script:P.Unattend -Destination $d.FileName -Force; Write-Ok "Saved: $($d.FileName)" }
    })
    $U.ChkUndo.Add_Click({
        $bak = Join-Path $Script:P.Work 'autounattend.original.xml'
        if (-not (Test-Path -LiteralPath $bak)) { Show-Msg 'No answer file fixes to undo.'; return }
        if (-not (Confirm-Ui 'Put the answer file back the way it was before the fixes?')) { return }
        Copy-Item -LiteralPath $bak -Destination $Script:P.Unattend -Force; Remove-Item -LiteralPath $bak -Force
        if ($Script:S.Unattend) { $Script:S.Unattend.Remove('Fixed') }
        Save-State; Sync-Unattend; Write-Ok 'Answer file fixes undone.'; Update-Ui
    })
    # 9 tools
    $U.ToolsBtn.Add_Click({ Start-Work 'Tools' })
    $U.ToolsOpen.Add_Click({ New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null; Open-Path $ToolsDir })
    # activity panel + run everything
    $U.LogOpen.Add_Click({ Open-Path $Script:P.Logs })
    $U.LogClear.Add_Click({ $Script:U.LogBox.Document.Blocks.Clear() })
    $U.RunAll.Add_Click({ Invoke-RunAllClick })

    $W.Add_Closing({
        param($s, $ev)
        if ($Script:Busy) {
            $r = [Windows.MessageBox]::Show($Script:W, "'$($Script:JobLabel)' is still running. Closing now can leave a mounted image behind (run Clean up next time). Close anyway?", $Script:AppTitle, 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $ev.Cancel = $true; return }
            try { [void]$Script:Ps.BeginStop($null, $null) } catch { }
        }
        $Script:Timer.Stop()
    })

    $W.Dispatcher.Add_UnhandledException({
        param($sender, $ev)
        $ev.Handled = $true
        $msg = $ev.Exception.Message
        if ($ev.Exception.InnerException) { $msg = $ev.Exception.InnerException.Message }
        try { Write-Err "Interface error: $msg" } catch { }
    })
    $Script:Timer = New-Object Windows.Threading.DispatcherTimer
    $Script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $Script:Timer.Add_Tick({
        try { Invoke-Tick }
        catch {
            $m = $_.Exception.Message
            if ($m -ne $Script:LastTickError) { $Script:LastTickError = $m; try { Write-Err "Interface error: $m" } catch { } }
        }
    })
    $Script:Timer.Start()

    try { Update-Ui } catch { Write-Err "Could not refresh every page: $($_.Exception.Message)" }
    Write-Title "$Script:AppTitle v$Script:AppVersion"
    Write-Info "Work folder: $($Script:P.Work)"
    if ($Script:S.Unpacked) { Write-Info "Unpacked media: $(Split-Path ([string]$Script:S.SourceIso) -Leaf) - pick up where you left off." }
    else { Write-Info 'Start on page 1: choose Windows 10 or 11, pick its ISO and unpack it - or set everything up and press Run everything.' }

    try {
        # console window, keep-awake during jobs (Set-KeepAwake), taskbar flash (Request-Attention)
        Add-Type -Namespace W10U -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
[StructLayout(LayoutKind.Sequential)] public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
[DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO fi);
public static bool Flash(IntPtr h) {
    FLASHWINFO fi = new FLASHWINFO();
    fi.cbSize = (uint)Marshal.SizeOf(fi); fi.hwnd = h;
    fi.dwFlags = 2 | 12;    // FLASHW_TRAY | FLASHW_TIMERNOFG: the taskbar button, until the window is in front
    return FlashWindowEx(ref fi);
}
'@
        [void][W10U.Con]::ShowWindow([W10U.Con]::GetConsoleWindow(), 0)
    } catch { }
    [void]$W.ShowDialog()
    if ($Script:Busy) { [Environment]::Exit(0) }
    try { $Script:RS.Close() } catch { }
    exit 0
} catch {
    try { [void][W10U.Con]::ShowWindow([W10U.Con]::GetConsoleWindow(), 5) } catch { }
    Microsoft.PowerShell.Utility\Write-Host ''
    Microsoft.PowerShell.Utility\Write-Host "  $Script:AppTitle could not start: $($_.Exception.Message)" -ForegroundColor Red
    Microsoft.PowerShell.Utility\Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    exit 1
}
#endregion
