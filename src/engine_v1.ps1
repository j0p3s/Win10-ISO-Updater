<#
    Windows-ISO-Updater engine  (v1.1.0, history)
    -------------------------------------------------------------------------
    Unpacks a Windows 10 ISO, detects its build, downloads the matching
    updates from the Microsoft Update Catalog (SSU, LCU, Safe OS + Setup
    Dynamic Updates, .NET), slipstreams them together with optional drivers
    exported from this PC and an autounattend.xml, then rebuilds a bootable
    BIOS + UEFI ISO.

    Normally started from Windows-ISO-updater-GUI_vX.X.X.cmd. Direct use:
        powershell -ExecutionPolicy Bypass -File Windows-ISO-Updater.ps1 -Action All

    Actions: Status, Unpack, Analyze, Editions, Download, Drivers, ImportDrivers,
             Unattend, Service, Build, All, Options, Clean

    Import a drivers folder directly (e.g. Drivers-Backup from Drivers.cmd):
        ... -File Windows-ISO-Updater.ps1 -Action ImportDrivers -DriverPath D:\Drivers-Backup

    Servicing order follows Microsoft's "Update Windows installation media
    with Dynamic Update" guide (WinRE -> install.wim -> boot.wim -> media).
#>
[CmdletBinding()]
param(
    [ValidateSet('Status','Unpack','Analyze','Editions','Download','Drivers','ImportDrivers','Unattend','Service','Build','All','Options','Clean')]
    [string]$Action = 'Status',
    [string]$IsoPath,
    [string]$DriverPath,
    [string]$ToolsDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Script:AppName      = 'Windows-ISO-Updater'
$Script:AppVersion   = '1.1.0'
$Script:Root         = $PSScriptRoot
if (-not $ToolsDir) { $ToolsDir = Join-Path $Script:Root 'tools' }
$Script:SettingsFile = Join-Path $Script:Root 'Windows-ISO-Updater.settings.json'
$Script:StatusFile   = Join-Path $env:TEMP 'Windows-ISO-Updater.status.cmd'
$Script:GeneratorUrl = 'https://github.com/j0p3s/autounattended-generator'
$Script:CatalogBase  = 'https://www.catalog.update.microsoft.com'
$Script:Dism         = Join-Path $env:SystemRoot 'System32\dism.exe'
$Script:Inv          = [Globalization.CultureInfo]::InvariantCulture
$Script:UA           = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$Script:BootClasses  = @('SCSIAdapter', 'HDC', 'Net')
$Script:LogFile      = $null
$Script:DismLog      = $null
$Script:LastDism     = 0
$Script:GridUsed     = $false

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

#region ---------------------------------------------------------------- UI helpers
function Add-Log([string]$Text) {
    if (-not $Script:LogFile) { return }
    try { Add-Content -LiteralPath $Script:LogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -Encoding UTF8 } catch { }
}
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('  ' + ('=' * 70)) -ForegroundColor DarkCyan
    Write-Host ('   ' + $Text) -ForegroundColor Cyan
    Write-Host ('  ' + ('=' * 70)) -ForegroundColor DarkCyan
    Add-Log "== $Text"
}
function Write-Step([string]$Text) { Write-Host ''; Write-Host "  >> $Text" -ForegroundColor Cyan; Add-Log ">> $Text" }
function Write-Sub([string]$Text)  { Write-Host "     - $Text" -ForegroundColor White; Add-Log "   - $Text" }
function Write-Info([string]$Text) { Write-Host "     $Text" -ForegroundColor Gray; Add-Log "   $Text" }
function Write-Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green; Add-Log "OK $Text" }
function Write-Warn([string]$Text) { Write-Host "  [!!] $Text" -ForegroundColor Yellow; Add-Log "WARN $Text" }
function Write-Err([string]$Text)  { Write-Host "  [XX] $Text" -ForegroundColor Red; Add-Log "ERROR $Text" }

function Read-YesNo([string]$Question, [bool]$Default = $true) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $a = Read-Host "  $Question $hint"
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        switch -Regex ($a.Trim()) {
            '^(y|yes|s|sim)$' { return $true }
            '^(n|no|nao)$'    { return $false }
        }
    }
}
function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}
function Limit-Text([string]$Text, [int]$Max) {
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 3) + '...'
}
function Q([string]$Text) { return '"' + $Text + '"' }

function Test-Gui {
    try { return [bool](Get-Command Out-GridView -ErrorAction Stop) } catch { return $false }
}
function Select-Grid($Items, [string]$Title) {
    # Returns the picked rows. $Script:GridUsed tells the caller whether the window was shown.
    $Script:GridUsed = $false
    if (-not (Test-Gui)) { return }
    try {
        $picked = @($Items | Out-GridView -Title $Title -PassThru | Where-Object { $null -ne $_ })
        $Script:GridUsed = $true
        return $picked
    } catch {
        Write-Warn 'The selection window is not available here - switching to the console.'
    }
}
function ConvertFrom-Selection([string]$Text, [int]$Max) {
    $t = "$Text".Trim()
    if ($t -match '^(a|all)$') { return @(1..$Max) }
    $set = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($t -split '[,; ]+')) {
        if ($part -match '^(\d+)-(\d+)$') {
            foreach ($n in ([int]$Matches[1])..([int]$Matches[2])) { if ($n -ge 1 -and $n -le $Max) { $set.Add($n) } }
        } elseif ($part -match '^\d+$') {
            $n = [int]$part
            if ($n -ge 1 -and $n -le $Max) { $set.Add($n) }
        }
    }
    return @($set | Sort-Object -Unique)
}
function Select-FileDialog([string]$Title, [string]$Filter, [string]$InitialDir) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Title = $Title
        $d.Filter = $Filter
        if ($InitialDir -and (Test-Path -LiteralPath $InitialDir)) { $d.InitialDirectory = $InitialDir }
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $r = $d.ShowDialog($owner)
        $owner.Dispose()
        if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $d.FileName }
        return $null
    } catch {
        $p = Read-Host "  $Title - paste the full path"
        if ($p) { return $p.Trim().Trim('"') }
        return $null
    }
}
function Select-FolderDialog([string]$Title) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = $Title
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true
        $r = $d.ShowDialog($owner)
        $owner.Dispose()
        if ($r -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
        return $null
    } catch {
        $p = Read-Host "  $Title - paste the full path"
        if ($p) { return $p.Trim().Trim('"') }
        return $null
    }
}
#endregion

#region ---------------------------------------------------------------- settings / state
function Get-DefaultSettings {
    return [ordered]@{
        WorkDir          = (Join-Path $env:SystemDrive 'W10U')
        KeepOnlySelected = $true
        NetFx3           = $true
        NetFx481         = $true
        ResetBase        = $true
        BootDrivers      = $true
        ForceUnsigned    = $false
        NoPrompt         = $true
        Boot2023         = $false
        SplitFat32       = $false
        Win10Cutoff      = '2025-10'
        LastDriverFolder = ''
    }
}
function Import-Settings {
    $s = Get-DefaultSettings
    if (Test-Path -LiteralPath $Script:SettingsFile) {
        try {
            $j = Get-Content -LiteralPath $Script:SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { if ($s.Contains($p.Name)) { $s[$p.Name] = $p.Value } }
        } catch { Write-Warn 'Settings file is unreadable - using defaults.' }
    }
    return $s
}
function Save-Settings {
    $Script:Cfg | ConvertTo-Json | Set-Content -LiteralPath $Script:SettingsFile -Encoding UTF8
}
function Initialize-Paths {
    $w = [string]$Script:Cfg.WorkDir
    $Script:P = @{
        Work     = $w
        Media    = Join-Path $w 'media'
        Mount    = Join-Path $w 'mnt\os'
        MountRE  = Join-Path $w 'mnt\re'
        MountPE  = Join-Path $w 'mnt\pe'
        Temp     = Join-Path $w 'temp'
        Updates  = Join-Path $w 'updates'
        Drivers  = Join-Path $w 'drivers'
        DrvSel   = Join-Path $w 'drivers\selected'
        Logs     = Join-Path $w 'logs'
        Output   = Join-Path $w 'output'
        State    = Join-Path $w 'state.json'
        Unattend = Join-Path $w 'autounattend.xml'
    }
}
function ConvertTo-HashtableDeep($Obj) {
    # Arrays are rebuilt in place with @(foreach ...) and never returned with the unary
    # comma: Windows PowerShell 5.1 ConvertTo-Json would write those as {"value":[..],"Count":n}.
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Obj.PSObject.Properties) {
            $val = $p.Value
            if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                $h[$p.Name] = @(foreach ($i in $val) { ConvertTo-HashtableDeep $i })
            } else {
                $h[$p.Name] = ConvertTo-HashtableDeep $val
            }
        }
        return $h
    }
    if ($Obj -is [string]) { return [string]$Obj }
    return $Obj
}
function New-State {
    return [ordered]@{
        SourceIso = $null; Unpacked = $false; Images = @(); Family = $null; Selected = @()
        Updates = @(); Drivers = @(); Unattend = $null; Serviced = $null; Iso = $null
    }
}
function Import-State {
    $s = New-State
    if (Test-Path -LiteralPath $Script:P.State) {
        try {
            $j = ConvertTo-HashtableDeep (Get-Content -LiteralPath $Script:P.State -Raw | ConvertFrom-Json)
            foreach ($k in @($j.Keys)) { $s[$k] = $j[$k] }
        } catch { Write-Warn 'state.json is unreadable - starting fresh.' }
    }
    foreach ($k in 'Images', 'Selected', 'Updates', 'Drivers') { if ($null -eq $s[$k]) { $s[$k] = @() } else { $s[$k] = @($s[$k]) } }
    return $s
}
function Save-State {
    New-Item -ItemType Directory -Force -Path $Script:P.Work | Out-Null
    $Script:S | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Script:P.State -Encoding UTF8
}
#endregion

#region ---------------------------------------------------------------- process / DISM helpers
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Invoke-Exe([string]$File, [string]$Arguments) {
    Add-Log "EXEC $File $Arguments"
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
    return [int]$p.ExitCode
}
function Invoke-Dism {
    # Runs dism.exe with live progress in the console. Exit code lands in $Script:LastDism.
    param([string]$Arguments, [string]$What = 'DISM', [string[]]$OkHex = @(), [switch]$Soft)
    $ok = @(0, 3010)
    foreach ($h in $OkHex) { $ok += [Convert]::ToInt32($h, 16) }
    $code = Invoke-Exe $Script:Dism ('/English /LogPath:' + (Q $Script:DismLog) + ' ' + $Arguments)
    $Script:LastDism = $code
    if ($ok -contains $code) { return }
    $msg = "$What failed - DISM error 0x$($code.ToString('X8'))"
    if ($Soft) { Write-Warn $msg; return }
    throw $msg
}
function Mount-Img([string]$ImageFile, [int]$Index, [string]$MountDir) {
    if (Test-Path -LiteralPath $MountDir) {
        if (@(Get-ChildItem -LiteralPath $MountDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            throw "Mount folder $MountDir is not empty - use [C] Clean up in the menu first."
        }
    } else { New-Item -ItemType Directory -Force -Path $MountDir | Out-Null }
    Write-Sub "Mounting $(Split-Path $ImageFile -Leaf) index $Index"
    Invoke-Dism "/Mount-Image /ImageFile:$(Q $ImageFile) /Index:$Index /MountDir:$(Q $MountDir)" "Mount $(Split-Path $ImageFile -Leaf) #$Index"
}
function Dismount-Img([string]$MountDir, [switch]$Commit) {
    $mode = if ($Commit) { '/Commit' } else { '/Discard' }
    Write-Sub ('Unmounting ' + $(if ($Commit) { '(saving changes)' } else { '(discarding)' }))
    Invoke-Dism "/Unmount-Image /MountDir:$(Q $MountDir) $mode" 'Unmount'
}
function Add-Pkg([string]$MountDir, [string]$Package, [string]$Label, [string[]]$IgnoreHex = @(), [switch]$Soft) {
    Write-Sub "$Label : $(Split-Path $Package -Leaf)"
    Invoke-Dism "/Image:$(Q $MountDir) /Add-Package /PackagePath:$(Q $Package)" $Label -OkHex $IgnoreHex -Soft:$Soft
}
function Invoke-ImageCleanup([string]$MountDir, [string]$Label) {
    Write-Sub "$Label : component cleanup /ResetBase"
    Invoke-Dism "/Image:$(Q $MountDir) /Cleanup-Image /StartComponentCleanup /ResetBase" "$Label cleanup" -OkHex @('800F0806') -Soft
}
function Export-Img([string]$Source, [int]$Index, [string]$Destination, [switch]$Max) {
    # /Compress only applies to the first export into a new file; appends inherit it.
    $c = if ($Max -and -not (Test-Path -LiteralPath $Destination)) { ' /Compress:max' } else { '' }
    Invoke-Dism "/Export-Image /SourceImageFile:$(Q $Source) /SourceIndex:$Index /DestinationImageFile:$(Q $Destination)$c /CheckIntegrity" "Export $(Split-Path $Source -Leaf) #$Index"
}
function Clear-Mounts {
    $work = [IO.Path]::GetFullPath($Script:P.Work).TrimEnd('\')
    $mounted = @()
    try { $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop) } catch { }
    foreach ($m in $mounted) {
        $mp = [string]$m.Path
        if (-not $mp) { $mp = [string]$m.MountPath }
        if ($mp -and $mp.StartsWith($work, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Warn "Discarding leftover mount: $mp"
            Invoke-Dism "/Unmount-Image /MountDir:$(Q $mp) /Discard" 'Unmount leftover' -Soft
        }
    }
    Invoke-Dism '/Cleanup-Mountpoints' 'Cleanup mount points' -Soft
    foreach ($d in @($Script:P.Mount, $Script:P.MountRE, $Script:P.MountPE)) {
        if ((Test-Path -LiteralPath $d) -and @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
        }
    }
}
function Reset-Dir([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}
function Test-WorkDir([double]$NeedGB = 30) {
    $w = $Script:P.Work
    if ($w -match '\s') { Write-Warn "The work folder has spaces in its path ($w). A short path like C:\W10U is safer for DISM." }
    New-Item -ItemType Directory -Force -Path $w | Out-Null
    $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($w))
    $drv = New-Object IO.DriveInfo($root)
    if ($drv.DriveFormat -ne 'NTFS') { throw "The work folder must be on an NTFS drive ($root is $($drv.DriveFormat))." }
    if ($drv.AvailableFreeSpace -lt ($NeedGB * 1GB)) {
        Write-Warn ('Only {0} free on {1} - about {2} GB is recommended.' -f (Format-Size $drv.AvailableFreeSpace), $root, $NeedGB)
        if (-not (Read-YesNo 'Continue anyway?' $false)) { throw 'Not enough free space.' }
    }
}
function Get-HostArch {
    $a = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $a = $env:PROCESSOR_ARCHITEW6432 }
    switch ($a) { 'AMD64' { return 'x64' } 'ARM64' { return 'arm64' } default { return 'x86' } }
}
function Find-Oscdimg {
    $c = @()
    if ($ToolsDir) { $c += (Join-Path $ToolsDir 'oscdimg.exe') }
    $adk = switch (Get-HostArch) { 'x64' { 'amd64' } 'arm64' { 'arm64' } default { 'x86' } }
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($pf) { $c += (Join-Path $pf "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$adk\Oscdimg\oscdimg.exe") }
    }
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { $c += $cmd.Source }
    foreach ($x in $c) { if ($x -and (Test-Path -LiteralPath $x)) { return $x } }
    return $null
}
#endregion

#region ---------------------------------------------------------------- image detection
function Assert-Unpacked {
    if (-not $Script:S.Unpacked -or -not (Test-Path -LiteralPath (Join-Path $Script:P.Media 'sources'))) {
        throw 'No unpacked ISO yet - run step [1] first.'
    }
}
function Assert-Analyzed {
    Assert-Unpacked
    if (-not $Script:S.Family -or @($Script:S.Images).Count -eq 0) { Invoke-Analyze }
}
function Get-SourceImage {
    foreach ($n in 'install.wim', 'install.esd') {
        $f = Join-Path $Script:P.Media "sources\$n"
        if (Test-Path -LiteralPath $f) { return $f }
    }
    if (Test-Path -LiteralPath (Join-Path $Script:P.Media 'sources\install.swm')) {
        throw 'This media has a split install.swm - unpack the original ISO again (step 1) to service it.'
    }
    throw 'No install.wim / install.esd found in the unpacked media.'
}
function ConvertTo-ArchName($Arch) {
    switch ("$Arch") {
        '0' { return 'x86' } '9' { return 'x64' } '12' { return 'arm64' } '5' { return 'arm' }
        'amd64' { return 'x64' } 'x64' { return 'x64' } 'x86' { return 'x86' } 'arm64' { return 'arm64' }
        default { return "$Arch".ToLower() }
    }
}
function Get-ImageList([string]$ImageFile) {
    $out = @()
    foreach ($i in @(Get-WindowsImage -ImagePath $ImageFile)) {
        $d = Get-WindowsImage -ImagePath $ImageFile -Index $i.ImageIndex
        $v = [version]$d.Version
        $out += [ordered]@{
            Index    = [int]$d.ImageIndex
            Name     = [string]$d.ImageName
            Edition  = [string]$d.EditionId
            Build    = [int]$v.Build
            Revision = [int]$d.SPBuild
            Version  = '{0}.{1}' -f $v.Build, $d.SPBuild
            Arch     = ConvertTo-ArchName $d.Architecture
            Size     = [int64]$d.ImageSize
            Langs    = (@($d.Languages) -join ',')
        }
    }
    return , $out
}
function Resolve-Family($Images) {
    $first = $Images[0]
    $b = [int]$first.Build
    $arch = [string]$first.Arch
    if (@($Images | ForEach-Object { "$($_.Build)/$($_.Arch)" } | Select-Object -Unique).Count -gt 1) {
        Write-Warn 'This image mixes builds/architectures - updates are picked for the first edition.'
    }
    $archTitle = @{ x64 = 'x64-based Systems'; x86 = 'x86-based Systems'; arm64 = 'ARM64-based Systems' }[$arch]
    $archTok   = @{ x64 = 'x64'; x86 = 'x86'; arm64 = 'ARM64' }[$arch]
    $ltsc = @($Images | Where-Object { $_.Edition -match 'EnterpriseS|IoTEnterpriseS' }).Count -gt 0
    $f = [ordered]@{
        Build = $b; Arch = $arch; ArchTitle = $archTitle; ArchToken = $archTok; Product = $null; VerToken = $null
        Cap = $null; NeedsEkb = $false; Supported = $true; Name = $null; IsLtsc = $ltsc; Label = $null
    }
    if ($b -ge 19041 -and $b -le 19045) {
        if ($b -eq 19044 -and $ltsc) { $f.VerToken = '21H2'; $f.Name = 'Windows 10 LTSC 2021 (21H2)' }
        else {
            $f.VerToken = '22H2'; $f.Name = 'Windows 10 22H2'
            if ($b -lt 19045) { $f.NeedsEkb = $true; $f.Name = "Windows 10 build $b -> 22H2" }
        }
        $f.Cap = [string]$Script:Cfg.Win10Cutoff
    } elseif ($b -eq 17763) { $f.VerToken = '1809'; $f.Name = 'Windows 10 1809 / LTSC 2019' }
    elseif ($b -eq 14393) { $f.VerToken = '1607'; $f.Name = 'Windows 10 1607 / LTSB 2016' }
    elseif ($b -ge 22000) { $f.Supported = $false; $f.Name = "Windows 11 (build $b)" }
    else { $f.Supported = $false; $f.Name = "Windows 10 build $b (out of support)" }
    if ($f.VerToken) { $f.Product = "Windows 10 Version $($f.VerToken)" }
    if (-not $archTitle) { $f.Supported = $false }
    $tag = if ($f.VerToken) { $f.VerToken } else { "$b" }
    $f.Label = ('W10_' + $tag + '_' + $arch).ToUpper()
    return $f
}
#endregion

#region ---------------------------------------------------------------- Microsoft Update Catalog
function Invoke-Web([string]$Uri, [string]$Method = 'GET', [string]$Body) {
    $prm = @{ Uri = $Uri; UseBasicParsing = $true; UserAgent = $Script:UA; TimeoutSec = 90; Headers = @{ 'Accept-Language' = 'en-US,en;q=0.9' } }
    if ($Method -eq 'POST') { $prm.Method = 'POST'; $prm.Body = $Body; $prm.ContentType = 'application/x-www-form-urlencoded' }
    for ($try = 1; $try -le 3; $try++) {
        try { return (Invoke-WebRequest @prm).Content }
        catch { if ($try -eq 3) { throw "Could not reach the Microsoft Update Catalog: $($_.Exception.Message)" }; Start-Sleep -Seconds (3 * $try) }
    }
}
function ConvertFrom-HtmlText([string]$Html) {
    $t = [regex]::Replace($Html, '<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    return ([regex]::Replace($t, '\s+', ' ')).Trim()
}
function Search-Catalog([string]$Query) {
    $html = Invoke-Web ($Script:CatalogBase + '/Search.aspx?q=' + [uri]::EscapeDataString($Query))
    $out = New-Object System.Collections.ArrayList
    if (-not $html) { return }
    $guidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    foreach ($row in [regex]::Matches($html, '<tr[^>]*>(?<r>.*?)</tr>', 'Singleline, IgnoreCase')) {
        $r = $row.Groups['r'].Value
        $g = [regex]::Match($r, "goToDetails\(\s*[`"']?(?<g>$guidRx)")
        if (-not $g.Success) { continue }
        $cells = @([regex]::Matches($r, '<td[^>]*>(?<c>.*?)</td>', 'Singleline, IgnoreCase') | ForEach-Object { $_.Groups['c'].Value })
        $ti = -1
        for ($i = 0; $i -lt $cells.Count; $i++) { if ($cells[$i] -match 'goToDetails') { $ti = $i; break } }
        if ($ti -lt 0 -or $cells.Count -lt ($ti + 6)) { continue }
        $title = ConvertFrom-HtmlText $cells[$ti]
        $sm = [regex]::Match($cells[$ti + 5], '<span[^>]*>(?<s>[^<]*)</span>')
        $size = if ($sm.Success) { $sm.Groups['s'].Value.Trim() } else { ConvertFrom-HtmlText $cells[$ti + 5] }
        $date = [datetime]::MinValue
        [void][datetime]::TryParseExact((ConvertFrom-HtmlText $cells[$ti + 3]), [string[]]@('M/d/yyyy', 'MM/dd/yyyy'), $Script:Inv, [Globalization.DateTimeStyles]::None, [ref]$date)
        [void]$out.Add([pscustomobject]@{
            Guid           = $g.Groups['g'].Value
            Title          = $title
            Products       = ConvertFrom-HtmlText $cells[$ti + 1]
            Classification = ConvertFrom-HtmlText $cells[$ti + 2]
            Date           = $date
            Size           = $size
            KB             = ([regex]::Match($title, 'KB\d{6,8}')).Value
        })
    }
    return $out.ToArray()
}
function Get-CatalogFileUrls([string]$Guid) {
    $json = '[{"size":0,"languages":"","uidInfo":"' + $Guid + '","updateID":"' + $Guid + '"}]'
    $html = Invoke-Web -Uri ($Script:CatalogBase + '/DownloadDialog.aspx') -Method POST -Body ('updateIDs=' + [uri]::EscapeDataString($json))
    $urls = @([regex]::Matches($html, "\.url\s*=\s*'(?<u>https?://[^']+)'") | ForEach-Object { $_.Groups['u'].Value })
    if ($urls.Count -eq 0) {
        $urls = @([regex]::Matches($html, 'https?://[^''"\s<>]+\.(?:msu|cab|exe)') | ForEach-Object { $_.Value })
    }
    return @($urls | Select-Object -Unique)
}
function Get-CatalogDescription([string]$Guid) {
    try {
        $html = Invoke-Web ($Script:CatalogBase + '/ScopedViewInline.aspx?updateid=' + $Guid)
        $m = [regex]::Match($html, '(?s)id="ScopedViewHandler_desc"[^>]*>(?<d>.*?)</span>')
        if ($m.Success) { return (ConvertFrom-HtmlText $m.Groups['d'].Value) }
    } catch { }
    return ''
}
function Get-DuKind($Hit) {
    if ($Hit.Title -match 'Safe OS' -or $Hit.Products -match 'Safe OS') { return 'SAFEOS' }
    if ($Hit.Title -match 'Setup Dynamic') { return 'SETUP' }
    $d = Get-CatalogDescription $Hit.Guid
    if ($d -match 'ComponentUpdate') { return 'SAFEOS' }
    if ($d -match 'SetupUpdate') { return 'SETUP' }
    if (-not $d -and $Hit.Products -match 'Dynamic Update|GDR-DU' -and $Hit.Products -notmatch '\bLP\b') { return 'SETUP' }
    return 'OTHER'
}
function Get-MonthList([string]$From, [int]$Count) {
    $d = [datetime]::ParseExact($From + '-01', 'yyyy-MM-dd', $Script:Inv)
    for ($i = 0; $i -lt $Count; $i++) { $d.AddMonths(-$i).ToString('yyyy-MM') }
}
function Find-Update {
    # Walks back month by month ("YYYY-MM ..." titles) and returns the newest match.
    param([string]$Kind, $Fam, [string]$MaxMonth, [int]$Lookback = 12)
    $p = [regex]::Escape($Fam.Product); $a = [regex]::Escape($Fam.ArchTitle)
    $v = [regex]::Escape($Fam.VerToken); $t = [regex]::Escape($Fam.ArchToken)
    foreach ($ym in (Get-MonthList $MaxMonth $Lookback)) {
        $y = [regex]::Escape($ym)
        switch ($Kind) {
            'LCU'   { $q = "$ym Cumulative Update for $($Fam.Product) for $($Fam.ArchTitle)"; $rx = "^$y Cumulative Update for $p for $a" }
            'SSU'   { $q = "$ym Servicing Stack Update for $($Fam.Product) for $($Fam.ArchTitle)"; $rx = "^$y Servicing Stack Update for $p for $a" }
            'NET'   { $q = "$ym Cumulative Update for .NET Framework $($Fam.Product) $($Fam.ArchToken)"; $rx = "^$y Cumulative Update for \.NET Framework .*Windows 10.*\b$v\b.*\b$t\b" }
            default { $q = "$ym Dynamic Update for $($Fam.Product) for $($Fam.ArchTitle)"; $rx = "^$y (Safe OS |Setup )?Dynamic Update for Windows 10.*\b$v\b.*$a" }
        }
        Write-Host "     . catalog: $ym" -ForegroundColor DarkGray
        $hits = @(Search-Catalog $q | Where-Object { $_.Title -match $rx -and $_.Title -notmatch 'Preview' })
        if ($Kind -eq 'SAFEOS' -or $Kind -eq 'SETUP') { $hits = @($hits | Where-Object { (Get-DuKind $_) -eq $Kind }) }
        if ($hits.Count -gt 0) {
            $sorted = @($hits | Sort-Object Date -Descending)
            if ($Kind -eq 'NET') { return $sorted }
            return $sorted[0]
        }
    }
}
function Find-ByKB([string]$KB, $Fam, [string]$MustMatch) {
    $t = [regex]::Escape($Fam.ArchToken)
    $hits = @(Search-Catalog $KB | Where-Object {
            $_.Title -match "\b$t\b" -and $_.Title -match 'Windows 10' -and (-not $MustMatch -or $_.Title -match $MustMatch)
        })
    if ($hits.Count -gt 0) { return (@($hits | Sort-Object Date -Descending))[0] }
}
function Test-CatalogHash([string]$File) {
    # Catalog file names end with _<sha1>.msu/.cab - use it as a free integrity check.
    $n = [IO.Path]::GetFileNameWithoutExtension($File)
    if ($n -match '_(?<h>[0-9a-fA-F]{40})$') {
        $want = $Matches['h']
        return ((Get-FileHash -LiteralPath $File -Algorithm SHA1).Hash -eq $want)
    }
    return $true
}
function Save-Url([string]$Url, [string]$Dest) {
    $leaf = Split-Path $Dest -Leaf
    if ((Test-Path -LiteralPath $Dest) -and (Test-CatalogHash $Dest)) { Write-Info "Already downloaded: $leaf"; return }
    $part = "$Dest.part"
    Write-Sub "Downloading $leaf"
    $done = $false
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        $code = Invoke-Exe $curl ("-L --fail --retry 3 --retry-delay 3 -C - --progress-bar -o $(Q $part) $(Q $Url)")
        if ($code -eq 0) { $done = $true } else { Write-Warn "curl exit $code - retrying with BITS"; Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    }
    if (-not $done) {
        try { Start-BitsTransfer -Source $Url -Destination $part -DisplayName $Script:AppName -Priority Foreground; $done = $true }
        catch { Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing; $done = $true }
    }
    Move-Item -LiteralPath $part -Destination $Dest -Force
    if (-not (Test-CatalogHash $Dest)) {
        Remove-Item -LiteralPath $Dest -Force
        throw "Integrity check failed for $leaf - run Download again."
    }
}
function Save-UpdateFiles($Hit, [string]$Kind) {
    $urls = @(Get-CatalogFileUrls $Hit.Guid)
    if ($urls.Count -eq 0) { throw "The catalog returned no download link for: $($Hit.Title)" }
    $tag = if ($Hit.KB) { $Hit.KB } else { $Hit.Guid.Substring(0, 8) }
    $dir = Join-Path $Script:P.Updates ("{0}_{1}_{2}" -f $Kind, $tag, $Script:S.Family.Arch)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $files = @()
    foreach ($u in $urls) {
        $name = [IO.Path]::GetFileName(([uri]$u).AbsolutePath)
        $dest = Join-Path $dir $name
        Save-Url $u $dest
        $files += $dest
    }
    return [ordered]@{ Kind = $Kind; KB = $Hit.KB; Title = $Hit.Title; Date = $Hit.Date.ToString('yyyy-MM-dd'); Files = $files }
}
function Get-UpdateFiles {
    $h = @{ SSU = @(); LCU = @(); EKB = @(); SAFEOS = @(); SETUP = @(); NET = @(); NET481 = @() }
    foreach ($u in @($Script:S.Updates)) {
        foreach ($f in @($u.Files)) {
            if (Test-Path -LiteralPath $f) { $h[$u.Kind] += $f } else { Write-Warn "Missing $f - run Download again." }
        }
    }
    return $h
}
#endregion

#region ---------------------------------------------------------------- [1] Unpack / Analyze
function Invoke-Unpack {
    Write-Title 'Unpack ISO'
    $iso = $IsoPath
    if (-not $iso) {
        $start = if ($Script:S.SourceIso) { Split-Path $Script:S.SourceIso -Parent } else { Join-Path $env:USERPROFILE 'Downloads' }
        $iso = Select-FileDialog 'Select a Windows 10 ISO' 'ISO images (*.iso)|*.iso' $start
    }
    if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { throw 'No ISO selected.' }
    $iso = (Resolve-Path -LiteralPath $iso).Path
    Write-Info "ISO  : $iso  ($(Format-Size (Get-Item -LiteralPath $iso).Length))"
    Write-Info "Work : $($Script:P.Work)"
    Test-WorkDir 30
    Clear-Mounts

    if ((Test-Path -LiteralPath $Script:P.Media) -and @(Get-ChildItem -LiteralPath $Script:P.Media -Force).Count -gt 0) {
        if (-not (Read-YesNo 'The work folder already has unpacked media. Replace it?' $true)) { return }
    }
    Reset-Dir $Script:P.Media
    Reset-Dir $Script:P.Temp

    $img = Get-DiskImage -ImagePath $iso
    $wasAttached = [bool]$img.Attached
    if (-not $wasAttached) { $img = Mount-DiskImage -ImagePath $iso -PassThru; Start-Sleep -Seconds 2 }
    try {
        $vol = $img | Get-Volume
        if (-not $vol.DriveLetter) { throw 'The ISO mounted without a drive letter (auto-mount disabled?).' }
        $drive = "$($vol.DriveLetter):"
        Write-Step "Copying files from $drive (a few minutes)"
        $t0 = Get-Date
        $code = Invoke-Exe 'robocopy.exe' ("$drive\ $(Q $Script:P.Media) /E /J /R:1 /W:1 /NDL /NFL /NJH /NP")
        if ($code -ge 8) { throw "robocopy failed (exit $code)." }
        Write-Ok ('Copied in {0:mm\:ss}' -f ((Get-Date) - $t0))
    } finally {
        if (-not $wasAttached) { Dismount-DiskImage -ImagePath $iso | Out-Null }
    }
    Invoke-Exe 'attrib.exe' ("-R $(Q (Join-Path $Script:P.Media '*')) /S /D") | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $Script:P.Media 'sources'))) { throw 'This does not look like Windows setup media (no \sources folder).' }

    $Script:S.SourceIso = $iso
    $Script:S.Unpacked  = $true
    $Script:S.Selected  = @()
    $Script:S.Updates   = @()
    $Script:S.Serviced  = $null
    $Script:S.Iso       = $null
    $Script:S.Images    = @()
    $Script:S.Family    = $null
    Save-State
    Invoke-Analyze
    Sync-Unattend
}

function Invoke-Analyze {
    Assert-Unpacked
    $src = Get-SourceImage
    Write-Step "Reading $(Split-Path $src -Leaf)"
    $imgs = Get-ImageList $src
    if ($imgs.Count -eq 0) { throw 'The image file has no editions.' }
    $fam = Resolve-Family $imgs
    $Script:S.Images = @(foreach ($i in $imgs) { $i })
    $Script:S.Family = $fam
    if ($imgs.Count -eq 1) { $Script:S.Selected = @(1) }
    $Script:S.Selected = @($Script:S.Selected | Where-Object { $_ -le $imgs.Count })
    Save-State

    Write-Host ''
    $color = if ($fam.Supported) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0}  |  build {1}  |  {2}  |  {3} edition(s)  |  {4}" -f $fam.Name, $imgs[0].Version, $fam.Arch, $imgs.Count, (Split-Path $src -Leaf)) -ForegroundColor $color
    Write-Host ''
    Write-Host ('   {0,-3} {1,-42} {2,-14} {3,-11} {4}' -f '#', 'Edition', 'Build', 'Size', 'Language') -ForegroundColor DarkGray
    foreach ($i in $imgs) {
        $mark = if ($Script:S.Selected -contains $i.Index) { '*' } else { ' ' }
        Write-Host ('  {0}{1,-3} {2,-42} {3,-14} {4,-11} {5}' -f $mark, $i.Index, (Limit-Text $i.Name 42), $i.Version, (Format-Size $i.Size), $i.Langs)
    }
    Write-Host ''
    if (-not $fam.Supported) {
        Write-Warn "$($fam.Name) is not supported for automatic updates (supported: Windows 10 1607/LTSB 2016, 1809/LTSC 2019, 2004-22H2/LTSC 2021)."
        Write-Info 'You can still inject drivers / autounattend.xml and rebuild the ISO.'
    } elseif ($fam.Cap) {
        Write-Info "Update target: newest updates up to $($Script:Cfg.Win10Cutoff). Microsoft blocks offline integration of the"
        Write-Info 'Windows 10 ESU-era updates (Nov 2025+); enrolled PCs get those from Windows Update after setup.'
        if ($fam.NeedsEkb) { Write-Info 'The 22H2 enablement package (KB5015684) will be added to bring this build to 22H2.' }
    } else {
        Write-Info 'Update target: newest updates available in the catalog.'
    }
}
#endregion

#region ---------------------------------------------------------------- [2] Editions
function Invoke-Editions {
    Assert-Analyzed
    Write-Title 'Choose editions'
    $imgs = @($Script:S.Images)
    $rows = foreach ($i in $imgs) {
        [pscustomobject]@{ Index = $i.Index; Edition = $i.Name; EditionId = $i.Edition; Build = $i.Version; Arch = $i.Arch; 'Size (GB)' = [math]::Round($i.Size / 1GB, 1) }
    }
    Write-Info 'A window opens - Ctrl+click to pick one or more editions, then OK.'
    $pick = @(Select-Grid $rows 'Pick the editions to update and keep (Ctrl+click for several, then OK)')
    $sel = @()
    if ($Script:GridUsed) {
        $sel = @($pick | ForEach-Object { [int]$_.Index })
        if ($sel.Count -eq 0) { Write-Warn 'Nothing picked - keeping the previous selection.'; $sel = @($Script:S.Selected) }
    } else {
        foreach ($i in $imgs) { Write-Host ('   {0,3}  {1,-44} {2}' -f $i.Index, (Limit-Text $i.Name 44), $i.Version) }
        $ans = Read-Host '  Editions to keep (e.g. 6  or  1,6  or  2-4,  A = all)'
        $sel = @(ConvertFrom-Selection $ans $imgs.Count)
    }
    $Script:S.Selected = @($sel | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    if ($Script:S.Selected.Count -eq 0) { throw 'No edition selected.' }
    Save-State
    foreach ($n in $Script:S.Selected) { Write-Ok ($imgs | Where-Object { $_.Index -eq $n }).Name }
    if (-not $Script:Cfg.KeepOnlySelected) { Write-Info 'Other editions stay in the ISO un-updated (Options > Keep only selected editions = OFF).' }
}
#endregion

#region ---------------------------------------------------------------- [3] Download
function Invoke-Download([switch]$Auto) {
    Assert-Analyzed
    $f = $Script:S.Family
    Write-Title "Download updates - $($f.Name) $($f.Arch)"
    if (-not $f.Supported) { throw "$($f.Name) is not supported for automatic updates." }

    $max = (Get-Date).ToString('yyyy-MM')
    $cap = if ($f.Build -ge 19041 -and $f.Build -le 19045) { [string]$Script:Cfg.Win10Cutoff } else { '' }
    if ($cap -and [string]::CompareOrdinal($cap, $max) -lt 0) {
        $max = $cap
        Write-Warn "Capped at $max (Windows 10 ESU cutoff - change it in Options if you want to experiment)."
    }
    $found = @()

    Write-Step 'Latest cumulative update (LCU)'
    $lcu = Find-Update 'LCU' $f $max 24
    if (-not $lcu) { throw "No cumulative update found for $($f.Product) $($f.ArchTitle)." }
    Write-Ok $lcu.Title
    $found += , @('LCU', $lcu)
    $month = $lcu.Title.Substring(0, 7)

    Write-Step 'Standalone servicing stack update (only published when needed)'
    $ssu = Find-Update 'SSU' $f $month 36
    if ($ssu) { Write-Ok $ssu.Title; $found += , @('SSU', $ssu) } else { Write-Info 'None needed - the LCU carries the servicing stack.' }

    Write-Step 'Safe OS Dynamic Update (WinRE)'
    $safe = Find-Update 'SAFEOS' $f $month 12
    if ($safe) { Write-Ok $safe.Title; $found += , @('SAFEOS', $safe) } else { Write-Warn 'Not found - WinRE gets the servicing stack only.' }

    Write-Step 'Setup Dynamic Update (setup binaries on the media)'
    $setup = Find-Update 'SETUP' $f $month 12
    if ($setup) { Write-Ok $setup.Title; $found += , @('SETUP', $setup) } else { Write-Warn 'Not found - skipping.' }

    if ($f.NeedsEkb) {
        Write-Step '22H2 enablement package'
        $ekb = Find-ByKB 'KB5015684' $f '22H2'
        if ($ekb) { Write-Ok $ekb.Title; $found += , @('EKB', $ekb) } else { Write-Warn 'KB5015684 not found - the image keeps its current version number.' }
    }

    if ($Script:Cfg.NetFx481 -and $f.Build -ge 19041 -and $f.Build -le 19045) {
        Write-Step '.NET Framework 4.8.1'
        $n481 = Find-ByKB 'KB5011048' $f "\b$($f.VerToken)\b"
        if ($n481) { Write-Ok $n481.Title; $found += , @('NET481', $n481) } else { Write-Warn '.NET 4.8.1 package not found - skipping.' }
    }

    Write-Step '.NET Framework cumulative update'
    $net = @(Find-Update 'NET' $f $month 12)
    if ($net.Count -gt 0) { foreach ($n in $net) { Write-Ok $n.Title; $found += , @('NET', $n) } } else { Write-Warn 'Not found - skipping.' }

    Write-Host ''
    Write-Host '  Packages to download:' -ForegroundColor Cyan
    foreach ($x in $found) { Write-Host ('   {0,-7} {1,-11} {2,10}  {3}' -f $x[0], $x[1].KB, $x[1].Size, $x[1].Date.ToString('yyyy-MM-dd')) }
    if (-not $Auto -and -not (Read-YesNo 'Download them now?' $true)) { return }

    $records = @()
    foreach ($x in $found) {
        Write-Step "$($x[0]) $($x[1].KB)"
        $records += Save-UpdateFiles $x[1] $x[0]
    }
    $Script:S.Updates = $records
    Save-State
    Write-Ok "All packages are in $($Script:P.Updates)"
}
#endregion

#region ---------------------------------------------------------------- [4] Drivers
function Resolve-InfToken([string]$Value, $Strings) {
    $v = "$Value".Trim()
    if ($v -match '^%([^%]+)%$') {
        $k = $Matches[1].ToLower()
        if ($Strings.ContainsKey($k)) { return $Strings[$k] }
    }
    return $v.Trim('"')
}
function Get-InfInfo([string]$Inf) {
    # Reads [Version] (Class, Provider, DriverVer), [Strings] and the [Manufacturer]
    # decorations (NTamd64 / NTx86 / NTarm64) to tell which architecture a driver is for.
    $info = [ordered]@{ Class = 'Unknown'; Provider = ''; Version = ''; Date = ''; Arch = 'any' }
    try { $lines = [IO.File]::ReadAllLines($Inf) } catch { return $info }
    $section = ''
    $ver = @{}; $str = @{}
    $mfg = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $lines) {
        $l = $raw.Trim()
        if (-not $l -or $l.StartsWith(';')) { continue }
        if ($l -match '^\[\s*([^\]]+?)\s*\]') { $section = $Matches[1].ToLower(); continue }
        if ($section -eq 'version' -or $section -like 'strings*') {
            if ($l -match '^([^=]+?)\s*=\s*(.*)$') {
                $k = $Matches[1].Trim().ToLower()
                $val = $Matches[2]
                if ($val -match '^"([^"]*)"') { $val = $Matches[1] } else { $val = ($val -replace '\s*;.*$', '').Trim() }
                if ($section -eq 'version') { $ver[$k] = $val } elseif (-not $str.ContainsKey($k)) { $str[$k] = $val }
            }
        } elseif ($section -eq 'manufacturer') { $mfg.Add($l) }
    }
    if ($ver.ContainsKey('class')) { $info.Class = Resolve-InfToken $ver['class'] $str }
    if ($ver.ContainsKey('provider')) { $info.Provider = Resolve-InfToken $ver['provider'] $str }
    if ($ver.ContainsKey('driverver')) {
        $dv = @((Resolve-InfToken $ver['driverver'] $str) -split '\s*,\s*')
        $d = [datetime]::MinValue
        if ([datetime]::TryParseExact($dv[0].Trim(), [string[]]@('M/d/yyyy', 'MM/dd/yyyy'), $Script:Inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { $info.Date = $d.ToString('yyyy-MM-dd') }
        if ($dv.Count -gt 1) { $info.Version = $dv[1].Trim() }
    }
    if ($mfg.Count -gt 0) {
        $m = $mfg -join ' '
        $a = @()
        if ($m -match '(?i)NTamd64') { $a += 'x64' }
        if ($m -match '(?i)NTarm64') { $a += 'arm64' }
        if ($m -match '(?i)NTx86' -or $a.Count -eq 0) { $a += 'x86' }
        $info.Arch = $a -join ','
    }
    return $info
}
function Test-DriverArch([string]$Arch, [string]$Target) {
    if (-not $Target -or -not $Arch -or $Arch -eq 'any') { return $true }
    return (@($Arch -split ',') -contains $Target)
}
function Get-BootDriverInfs {
    $list = @()
    foreach ($d in @($Script:S.Drivers)) {
        if ($Script:BootClasses -contains $d.Class) {
            $inf = Join-Path (Join-Path $Script:P.DrvSel $d.Folder) $d.Inf
            if (Test-Path -LiteralPath $inf) { $list += $inf }
        }
    }
    return , $list
}
function Show-Drivers {
    $d = @($Script:S.Drivers | ForEach-Object { [pscustomobject]$_ })
    if ($d.Count -eq 0) { Write-Info 'No drivers selected.'; return }
    $boot = @($d | Where-Object { $Script:BootClasses -contains $_.Class }).Count
    $mb = ($d | Measure-Object -Property SizeMB -Sum).Sum
    Write-Info ("{0} driver package(s) selected, {1} storage/network for boot.wim, ~{2:N0} MB" -f $d.Count, $boot, $mb)
    $d | Group-Object Class | Sort-Object Count -Descending | ForEach-Object { Write-Info ('  {0,-22} {1}' -f $_.Name, $_.Count) }
}
function Add-HostDrivers {
    $hostArch = Get-HostArch
    if ($Script:S.Family -and $Script:S.Family.Arch -ne $hostArch) {
        Write-Warn "This PC is $hostArch but the ISO is $($Script:S.Family.Arch) - its drivers would not work in that image."
        return
    }
    $exp = Join-Path $Script:P.Drivers 'host_export'
    Reset-Dir $exp
    Write-Step 'Exporting third-party drivers from this PC (1-3 minutes)'
    $drv = @(Export-WindowsDriver -Online -Destination $exp)
    if ($drv.Count -eq 0) { Write-Warn 'No third-party drivers found on this PC.'; return }

    $used = @{}
    $items = foreach ($d in $drv) {
        $inf = Split-Path $d.OriginalFileName -Leaf
        $folder = Split-Path (Split-Path $d.OriginalFileName -Parent) -Leaf
        $path = Join-Path $exp $folder
        if (-not (Test-Path -LiteralPath $path)) {
            $cand = Get-ChildItem -LiteralPath $exp -Directory | Where-Object { -not $used.ContainsKey($_.Name) -and (Test-Path -LiteralPath (Join-Path $_.FullName $inf)) } | Select-Object -First 1
            if (-not $cand) { continue }
            $folder = $cand.Name; $path = $cand.FullName
        }
        $used[$folder] = $true
        $size = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $date = ''
        try { $date = ([datetime]$d.Date).ToString('yyyy-MM-dd') } catch { }
        [pscustomobject]@{
            Class = [string]$d.ClassName; Provider = [string]$d.ProviderName; Version = [string]$d.Version; Date = $date
            'Size (MB)' = [math]::Round($size / 1MB, 1); BootCritical = [bool]$d.BootCritical; Inf = $inf; Folder = $folder
        }
    }
    $items = @($items | Sort-Object Class, Provider)
    Write-Ok "$($items.Count) driver packages found."

    Write-Info 'A window opens - select the drivers to include (Ctrl+A = all), then OK.'
    $pick = @(Select-Grid $items 'Drivers to slipstream into the ISO (Ctrl+A = all, Ctrl+click = several, then OK)')
    if (-not $Script:GridUsed) {
        for ($i = 0; $i -lt $items.Count; $i++) {
            $x = $items[$i]
            Write-Host ('   {0,3}  {1,-16} {2,-24} {3,-16} {4,7} MB' -f ($i + 1), (Limit-Text $x.Class 16), (Limit-Text $x.Provider 24), (Limit-Text $x.Version 16), $x.'Size (MB)')
        }
        Write-Host '  Type numbers (1,4,7-9), A for all, C:<class,...> by class (e.g. C:Display,Net,SCSIAdapter) or Enter for none.'
        $ans = Read-Host '  Drivers'
        if ($ans -match '^\s*c:(?<c>.+)$') {
            $classes = $Matches['c'] -split '\s*,\s*'
            $pick = @($items | Where-Object { $classes -contains $_.Class })
        } elseif ($ans) {
            $pick = @(ConvertFrom-Selection $ans $items.Count | ForEach-Object { $items[$_ - 1] })
        } else { $pick = @() }
    }
    if ($pick.Count -eq 0) { Write-Warn 'No drivers picked.'; Remove-Item -LiteralPath $exp -Recurse -Force -ErrorAction SilentlyContinue; return }

    $hostDir = Join-Path $Script:P.DrvSel 'host'
    Reset-Dir $hostDir
    $keep = @($Script:S.Drivers | Where-Object { $_.Source -ne 'host' })
    foreach ($x in $pick) {
        Copy-Item -LiteralPath (Join-Path $exp $x.Folder) -Destination (Join-Path $hostDir $x.Folder) -Recurse -Force
        $keep += [ordered]@{ Source = 'host'; Folder = "host\$($x.Folder)"; Inf = $x.Inf; Class = $x.Class; Provider = $x.Provider; Version = $x.Version; SizeMB = $x.'Size (MB)' }
    }
    Remove-Item -LiteralPath $exp -Recurse -Force -ErrorAction SilentlyContinue
    $Script:S.Drivers = $keep
    Save-State
    Write-Ok "$($pick.Count) driver package(s) from this PC will be slipstreamed."
}
function Get-DriverPackages([string]$Root) {
    # One row per .inf found under $Root (any depth). Works with the layout made by
    # Drivers.cmd / "dism /online /export-driver" (one folder per driver) and with vendor packs.
    $rootTrim = $Root.TrimEnd('\', '/')
    $infs = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.inf' })
    $sizes = @{}
    $n = 0
    foreach ($f in $infs) {
        $n++
        if ($n % 20 -eq 0 -or $n -eq $infs.Count) { Write-Host ("`r     reading INF files: {0} / {1}" -f $n, $infs.Count) -NoNewline -ForegroundColor DarkGray }
        $info = Get-InfInfo $f.FullName
        $dir = $f.DirectoryName
        if (-not $sizes.ContainsKey($dir)) {
            $sizes[$dir] = [double](Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        }
        $rel = ''
        if ($dir.Length -gt $rootTrim.Length) { $rel = $dir.Substring($rootTrim.Length).TrimStart('\', '/') }
        [pscustomobject]@{
            Class = $info.Class; Provider = $info.Provider; Version = $info.Version; Date = $info.Date; Arch = $info.Arch
            'Size (MB)' = [math]::Round($sizes[$dir] / 1MB, 1); Inf = $f.Name; Folder = $rel; FullDir = $dir
        }
    }
    if ($infs.Count -gt 0) { Write-Host '' }
}
function Find-DriverBackupFolders {
    $list = New-Object System.Collections.Generic.List[string]
    $cands = @((Join-Path $Script:Root 'Drivers-Backup'), [string]$Script:Cfg.LastDriverFolder)
    try {
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            if ($d.IsReady -and ($d.DriveType -eq 'Fixed' -or $d.DriveType -eq 'Removable')) { $cands += (Join-Path $d.RootDirectory.FullName 'Drivers-Backup') }
        }
    } catch { }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Container)) {
            $full = (Resolve-Path -LiteralPath $c).ProviderPath.TrimEnd('\')
            if (-not $list.Contains($full)) { $list.Add($full) }
        }
    }
    return , $list.ToArray()
}
function Copy-Tree([string]$Source, [string]$Dest) {
    if (Get-Command robocopy.exe -ErrorAction SilentlyContinue) {
        $src = if ($Source.EndsWith('\')) { $Source + '.' } else { $Source }
        $code = Invoke-Exe 'robocopy.exe' ("$(Q $src) $(Q $Dest) /E /R:1 /W:1 /NDL /NFL /NJH /NJS /NP")
        if ($code -ge 8) { throw "Copy failed (robocopy exit $code): $Source" }
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $Dest -Parent) | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Dest -Recurse -Force
    }
}
function Import-DriverFolder([string]$Path) {
    Write-Title 'Import a drivers folder'
    $dir = $Path
    if (-not $dir) {
        $found = Find-DriverBackupFolders
        if ($found.Count -gt 0) {
            Write-Info 'Driver folders found:'
            for ($i = 0; $i -lt $found.Count; $i++) { Write-Host ('   [{0}] {1}' -f ($i + 1), $found[$i]) }
            Write-Host '   [B] Browse for another folder'
            $a = Read-Host '  Choice (Enter = 1)'
            if (-not $a) { $a = '1' }
            if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $found.Count) { $dir = $found[[int]$a - 1] }
        }
        if (-not $dir) { $dir = Select-FolderDialog 'Pick the drivers folder (e.g. Drivers-Backup made by Drivers.cmd, or any folder with .inf drivers)' }
    }
    if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Warn 'No folder selected.'; return }
    $dir = (Resolve-Path -LiteralPath $dir).ProviderPath
    Write-Step "Scanning $dir"
    $items = @(Get-DriverPackages $dir | Sort-Object Class, Provider, Inf)
    if ($items.Count -eq 0) { Write-Warn 'No .inf driver files in that folder.'; return }

    $target = ''
    if ($Script:S.Family) { $target = [string]$Script:S.Family.Arch }
    $fit = @($items | Where-Object { Test-DriverArch $_.Arch $target })
    $tgtText = if ($target) { "the $target ISO" } else { 'any ISO (arch unknown - unpack the ISO first to check)' }
    Write-Ok ('{0} driver(s) found, {1} usable for {2}' -f $items.Count, $fit.Count, $tgtText)
    $mb = ($items | Group-Object FullDir | ForEach-Object { $_.Group[0].'Size (MB)' } | Measure-Object -Sum).Sum
    Write-Info ('Total size about {0:N0} MB' -f $mb)
    $items | Group-Object Class | Sort-Object Count -Descending | Select-Object -First 12 | ForEach-Object { Write-Info ('  {0,-22} {1}' -f $_.Name, $_.Count) }

    Write-Info 'A window opens - select the drivers to include (Ctrl+A = all), then OK.'
    $pick = @(Select-Grid $items "Drivers in $(Split-Path $dir -Leaf) - Ctrl+A = all, Ctrl+click = several, then OK")
    if (-not $Script:GridUsed) {
        for ($i = 0; $i -lt $items.Count; $i++) {
            $x = $items[$i]
            $mark = if (Test-DriverArch $x.Arch $target) { ' ' } else { '!' }
            Write-Host ('  {0}{1,3}  {2,-16} {3,-22} {4,-16} {5,-9} {6,7} MB' -f $mark, ($i + 1), (Limit-Text $x.Class 16), (Limit-Text $x.Provider 22), (Limit-Text $x.Version 16), (Limit-Text $x.Arch 9), $x.'Size (MB)')
        }
        Write-Host '  Enter numbers (1,4,7-9), A = all that fit the ISO, C:<class,...> by class (e.g. C:Display,Net,SCSIAdapter), Enter = cancel.'
        $ans = Read-Host '  Drivers'
        if ($ans -match '^\s*c:(?<c>.+)$') {
            $classes = $Matches['c'] -split '\s*,\s*'
            $pick = @($items | Where-Object { $classes -contains $_.Class })
        } elseif ($ans -match '^\s*(a|all)\s*$') {
            $pick = $fit
        } elseif ($ans) {
            $pick = @(ConvertFrom-Selection $ans $items.Count | ForEach-Object { $items[$_ - 1] })
        } else { $pick = @() }
    }
    $wrong = @($pick | Where-Object { -not (Test-DriverArch $_.Arch $target) })
    if ($wrong.Count -gt 0) {
        Write-Warn "$($wrong.Count) picked driver(s) are not built for $target and were left out."
        $pick = @($pick | Where-Object { Test-DriverArch $_.Arch $target })
    }
    if ($pick.Count -eq 0) { Write-Warn 'No drivers imported.'; return }

    $name = (Split-Path $dir -Leaf) -replace '[^\w\.-]', '_'
    if (-not $name) { $name = 'drivers' }
    $base = Join-Path (Join-Path $Script:P.DrvSel 'import') $name
    Reset-Dir $base
    Write-Step "Copying $($pick.Count) driver(s) into the work folder"
    $dirs = @($pick | ForEach-Object { $_.FullDir } | Sort-Object -Unique | Sort-Object Length)
    $done = New-Object System.Collections.Generic.List[string]
    foreach ($d in $dirs) {
        $inside = $false
        foreach ($c in $done) { if ($d -eq $c -or $d.StartsWith($c.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break } }
        if ($inside) { continue }
        $rel = ''
        $rootTrim = $dir.TrimEnd('\', '/')
        if ($d.Length -gt $rootTrim.Length) { $rel = $d.Substring($rootTrim.Length).TrimStart('\', '/') }
        $dest = if ($rel) { Join-Path $base $rel } else { $base }
        Copy-Tree $d $dest
        $done.Add($d)
    }

    $prefix = "import\$name"
    $keep = @($Script:S.Drivers | Where-Object { -not ([string]$_.Folder).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
    $seen = @{}
    foreach ($x in $pick) {
        $size = 0
        if (-not $seen.ContainsKey($x.FullDir)) { $size = $x.'Size (MB)'; $seen[$x.FullDir] = $true }
        $folder = if ($x.Folder) { "$prefix\$($x.Folder)" } else { $prefix }
        $keep += [ordered]@{ Source = 'import'; Folder = $folder; Inf = $x.Inf; Class = $x.Class; Provider = $x.Provider; Version = $x.Version; SizeMB = $size }
    }
    $Script:S.Drivers = $keep
    Save-State
    $Script:Cfg.LastDriverFolder = $dir
    Save-Settings
    $boot = @($pick | Where-Object { $Script:BootClasses -contains $_.Class }).Count
    Write-Ok "$($pick.Count) driver(s) imported from $dir ($boot storage/network also go into boot.wim and WinRE)."
}
function Remove-SelectedDrivers {
    $d = @($Script:S.Drivers)
    if ($d.Count -eq 0) { Write-Info 'Nothing to remove.'; return }
    $rows = for ($i = 0; $i -lt $d.Count; $i++) {
        [pscustomobject]@{ Id = $i + 1; Class = $d[$i].Class; Provider = $d[$i].Provider; Version = $d[$i].Version; Inf = $d[$i].Inf; 'Size (MB)' = $d[$i].SizeMB; Folder = $d[$i].Folder }
    }
    $pick = @(Select-Grid $rows 'Select the drivers to REMOVE, then OK')
    if (-not $Script:GridUsed) {
        foreach ($r in $rows) { Write-Host ('   {0,3}  {1,-16} {2,-26} {3}' -f $r.Id, (Limit-Text $r.Class 16), (Limit-Text $r.Provider 26), $r.Inf) }
        $ans = Read-Host '  Numbers to remove (e.g. 2,5-7)'
        $pick = @(ConvertFrom-Selection $ans $rows.Count | ForEach-Object { $rows[$_ - 1] })
    }
    if ($pick.Count -eq 0) { return }
    $drop = @($pick | ForEach-Object { $_.Id - 1 })
    $keep = @()
    for ($i = 0; $i -lt $d.Count; $i++) {
        if ($drop -contains $i) {
            $folder = Join-Path $Script:P.DrvSel $d[$i].Folder
            if ($d[$i].Source -eq 'host') { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
            else { Remove-Item -LiteralPath (Join-Path $folder $d[$i].Inf) -Force -ErrorAction SilentlyContinue }
        } else { $keep += $d[$i] }
    }
    $Script:S.Drivers = $keep
    Save-State
    Write-Ok "$($pick.Count) removed."
}
function Invoke-Drivers {
    while ($true) {
        Write-Title 'Drivers to slipstream'
        Show-Drivers
        Write-Host ''
        Write-Host '   [1] Scan THIS PC and choose drivers to include'
        Write-Host '   [2] Import a drivers folder - Drivers-Backup from Drivers.cmd, another PC, a vendor pack'
        Write-Host '   [3] Review / remove selected drivers'
        Write-Host '   [4] Clear all selected drivers'
        Write-Host '   [0] Back'
        $c = Read-Host '  Choice'
        switch ($c) {
            '1' { Add-HostDrivers }
            '2' { Import-DriverFolder }
            '3' { Remove-SelectedDrivers }
            '4' {
                if (Read-YesNo 'Remove every selected driver?' $false) {
                    Remove-Item -LiteralPath $Script:P.DrvSel -Recurse -Force -ErrorAction SilentlyContinue
                    $Script:S.Drivers = @(); Save-State; Write-Ok 'Cleared.'
                }
            }
            '0' { return }
            default { return }
        }
    }
}
#endregion

#region ---------------------------------------------------------------- [5] autounattend.xml
function Sync-Unattend {
    if (-not (Test-Path -LiteralPath (Join-Path $Script:P.Media 'sources'))) { return }
    if ($Script:S.Unattend -and (Test-Path -LiteralPath $Script:P.Unattend)) {
        Copy-Item -LiteralPath $Script:P.Unattend -Destination (Join-Path $Script:P.Media 'autounattend.xml') -Force
    }
}
function Test-UnattendFile([string]$File) {
    try { [xml]$x = Get-Content -LiteralPath $File -Raw } catch { throw "Not valid XML: $($_.Exception.Message)" }
    if ($x.DocumentElement.LocalName -ne 'unattend') { throw 'This XML is not an unattend answer file (root element is not <unattend>).' }
    $raw = $x.OuterXml
    if ($raw -match '<WillWipeDisk>\s*true') { Write-Warn 'This answer file WIPES a disk automatically - double-check the disk ID before using the ISO.' }
    if ($raw -match '<PlainText>\s*true') { Write-Info 'Note: it contains plain-text passwords - keep the ISO private.' }
    return $x
}
function Test-UnattendSelection {
    $file = Join-Path $Script:P.Media 'autounattend.xml'
    if (-not (Test-Path -LiteralPath $file)) { return }
    try { [xml]$x = Get-Content -LiteralPath $file -Raw } catch { Write-Warn 'autounattend.xml on the media is not valid XML.'; return }
    $nodes = @($x.SelectNodes("//*[local-name()='MetaData']"))
    if ($nodes.Count -eq 0) { return }
    $img = $null
    try { $img = @(Get-WindowsImage -ImagePath (Get-SourceImage)) } catch { return }
    foreach ($n in $nodes) {
        $key = ''; $val = ''
        foreach ($c in $n.ChildNodes) { if ($c.LocalName -eq 'Key') { $key = $c.InnerText } elseif ($c.LocalName -eq 'Value') { $val = $c.InnerText } }
        if ($key -match '/IMAGE/INDEX' -and [int]$val -gt $img.Count) {
            Write-Warn "autounattend.xml installs image INDEX $val but the new install.wim has $($img.Count) edition(s)."
        } elseif ($key -match '/IMAGE/INDEX') {
            Write-Info "autounattend.xml picks index $val = $(($img | Where-Object { $_.ImageIndex -eq [int]$val }).ImageName)"
        } elseif ($key -match '/IMAGE/NAME' -and -not ($img | Where-Object { $_.ImageName -eq $val })) {
            Write-Warn "autounattend.xml installs '$val' but that edition is not in the new install.wim."
        }
    }
}
function Select-UnattendFile {
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    $recent = Get-ChildItem -LiteralPath $dl -Filter 'autounattend*.xml' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $file = $null
    if ($recent -and (Read-YesNo ("Use {0} from Downloads ({1:yyyy-MM-dd HH:mm})?" -f $recent.Name, $recent.LastWriteTime) $true)) { $file = $recent.FullName }
    if (-not $file) { $file = Select-FileDialog 'Select your autounattend.xml' 'Answer files (*.xml)|*.xml' $dl }
    if (-not $file) { return }
    [void](Test-UnattendFile $file)
    New-Item -ItemType Directory -Force -Path $Script:P.Work | Out-Null
    Copy-Item -LiteralPath $file -Destination $Script:P.Unattend -Force
    $Script:S.Unattend = [ordered]@{ Source = $file; Added = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    Save-State
    Sync-Unattend
    Write-Ok "autounattend.xml added (from $file)"
}
function Invoke-Unattend {
    while ($true) {
        Write-Title 'autounattend.xml'
        if ($Script:S.Unattend) { Write-Info "Current: $($Script:S.Unattend.Source)  (added $($Script:S.Unattend.Added))" } else { Write-Info 'Current: none' }
        Write-Host ''
        Write-Host '   [1] Choose an autounattend.xml'
        Write-Host '   [2] Open the autounattend generator'
        Write-Host '   [3] Remove it from the ISO'
        Write-Host '   [0] Back'
        $c = Read-Host '  Choice'
        switch ($c) {
            '1' { Select-UnattendFile }
            '2' { Start-Process $Script:GeneratorUrl; Write-Info 'Generate and download the file, then use option 1.' }
            '3' {
                if ($Script:S.Unattend) { Remove-Item -LiteralPath (Join-Path $Script:P.Media 'autounattend.xml') -Force -ErrorAction SilentlyContinue }
                Remove-Item -LiteralPath $Script:P.Unattend -Force -ErrorAction SilentlyContinue
                $Script:S.Unattend = $null; Save-State; Write-Ok 'Removed.'
            }
            default { return }
        }
    }
}
#endregion

#region ---------------------------------------------------------------- [6] Slipstream
function Save-BootFiles2023([string]$MountDir, [string]$Dest) {
    $boot = Join-Path $MountDir 'Windows\Boot'
    $need = @('EFI_EX', 'FONTS_EX', 'DVD_EX')
    foreach ($n in $need) { if (-not (Test-Path -LiteralPath (Join-Path $boot $n))) { return $false } }
    Reset-Dir $Dest
    foreach ($n in $need) { Copy-Item -LiteralPath (Join-Path $boot $n) -Destination (Join-Path $Dest $n) -Recurse -Force }
    return $true
}
function Set-Boot2023([string]$Src) {
    # Same file swaps as Microsoft's Make2023BootableMedia.ps1
    $m = $Script:P.Media
    $efiBoot = Join-Path $m 'efi\boot'
    $bootName = if (Test-Path -LiteralPath (Join-Path $efiBoot 'bootaa64.efi')) { 'bootaa64.efi' } else { 'bootx64.efi' }
    Copy-Item -LiteralPath (Join-Path $Src 'EFI_EX\bootmgfw_EX.efi') -Destination (Join-Path $efiBoot $bootName) -Force
    if (Test-Path -LiteralPath (Join-Path $Src 'EFI_EX\bootmgr_EX.efi')) {
        Copy-Item -LiteralPath (Join-Path $Src 'EFI_EX\bootmgr_EX.efi') -Destination (Join-Path $m 'bootmgr.efi') -Force
    }
    $msBoot = Join-Path $m 'efi\microsoft\boot'
    $bins = @(Get-ChildItem -LiteralPath (Join-Path $Src 'DVD_EX') -Recurse -Filter 'efisys*_EX.bin' -File)
    $pref = @($bins | Where-Object { $_.DirectoryName -match '\\en-US$' })
    if ($pref.Count -gt 0) { $bins = $pref }
    $one = $bins | Where-Object { $_.Name -ieq 'efisys_EX.bin' } | Select-Object -First 1
    if (-not $one) { throw 'efisys_EX.bin was not found in the updated image.' }
    Copy-Item -LiteralPath $one.FullName -Destination (Join-Path $msBoot 'efisys_ex.bin') -Force
    $np = $bins | Where-Object { $_.Name -ieq 'efisys_noprompt_EX.bin' } | Select-Object -First 1
    if ($np) { Copy-Item -LiteralPath $np.FullName -Destination (Join-Path $msBoot 'efisys_noprompt_ex.bin') -Force }
    $fonts = Join-Path $msBoot 'fonts'
    New-Item -ItemType Directory -Force -Path $fonts | Out-Null
    foreach ($ttf in @(Get-ChildItem -LiteralPath (Join-Path $Src 'FONTS_EX') -File)) {
        Copy-Item -LiteralPath $ttf.FullName -Destination (Join-Path $fonts ($ttf.Name -replace '_EX', '')) -Force
    }
}
function Invoke-Service([switch]$Auto) {
    Assert-Analyzed
    $S = $Script:S; $P = $Script:P; $Cfg = $Script:Cfg
    Write-Title 'Slipstream updates, drivers and options'
    if (@($S.Selected).Count -eq 0) { Invoke-Editions }
    if ($S.Serviced -and -not $Auto) {
        Write-Warn "This media was already serviced on $($S.Serviced.When). For a clean result unpack the ISO again (step 1)."
        if (-not (Read-YesNo 'Service it again anyway?' $false)) { return }
    }
    $upd = Get-UpdateFiles
    $updCount = 0; foreach ($k in $upd.Keys) { $updCount += @($upd[$k]).Count }
    if ($updCount -eq 0) {
        Write-Warn 'No updates downloaded - only drivers and options will be applied.'
        if (-not $Auto -and -not (Read-YesNo 'Continue?' $true)) { return }
    }
    Test-WorkDir 25
    Clear-Mounts
    Reset-Dir $P.Temp

    $t0 = Get-Date
    $src      = Get-SourceImage
    $stage    = Join-Path $P.Temp 'install_stage.wim'
    $final    = Join-Path $P.Temp 'install_final.wim'
    $reWim    = Join-Path $P.Temp 'winre.wim'
    $reNew    = Join-Path $P.Temp 'winre_new.wim'
    $bootSt   = Join-Path $P.Temp 'boot_stage.wim'
    $bootFin  = Join-Path $P.Temp 'boot_final.wim'
    $bfDir    = Join-Path $P.Temp 'bootfiles'
    $exDir    = Join-Path $P.Temp 'boot2023'
    $hasDrv   = @($S.Drivers).Count -gt 0 -and (Test-Path -LiteralPath $P.DrvSel)
    $bootInfs = if ($Cfg.BootDrivers -and $hasDrv) { Get-BootDriverInfs } else { @() }
    $fu       = if ($Cfg.ForceUnsigned) { ' /ForceUnsigned' } else { '' }
    $lcuTip   = 'If this is a Windows 10 update newer than 2025-10, Microsoft blocks offline ESU integration - set the month back in Options.'
    New-Item -ItemType Directory -Force -Path $bfDir | Out-Null

    $all = @($S.Images | ForEach-Object { [int]$_.Index })
    $exportIdx = @(if ($Cfg.KeepOnlySelected) { $S.Selected } else { $all })
    $reReady = $false; $exSaved = $false

    try {
        # ---- stage editions (also converts install.esd -> wim)
        Write-Step "Staging $($exportIdx.Count) edition(s) from $(Split-Path $src -Leaf)"
        foreach ($i in $exportIdx) { Export-Img $src $i $stage -Max }

        # ---- WinRE + every selected edition
        for ($k = 1; $k -le $exportIdx.Count; $k++) {
            $orig = [int]$exportIdx[$k - 1]
            $info = $S.Images | Where-Object { $_.Index -eq $orig }
            if ($S.Selected -contains $orig) {
                Write-Title "Edition $k/$($exportIdx.Count): $($info.Name)"
                Mount-Img $stage $k $P.Mount

                if (-not $reReady) {
                    $reSrc = Join-Path $P.Mount 'Windows\System32\Recovery\winre.wim'
                    if (Test-Path -LiteralPath $reSrc) {
                        Write-Step 'Updating WinRE (recovery environment)'
                        try {
                            Copy-Item -LiteralPath $reSrc -Destination $reWim -Force
                            (Get-Item -LiteralPath $reWim -Force).Attributes = 'Normal'
                            Mount-Img $reWim 1 $P.MountRE
                            foreach ($x in $upd.SSU) { Add-Pkg $P.MountRE $x 'Servicing stack' -Soft }
                            foreach ($x in $upd.LCU) { Add-Pkg $P.MountRE $x 'Servicing stack via LCU' -IgnoreHex @('8007007E', '800F081E') -Soft }
                            foreach ($x in $upd.SAFEOS) { Add-Pkg $P.MountRE $x 'Safe OS Dynamic Update' -Soft }
                            if ($bootInfs.Count -gt 0) {
                                Write-Sub "Storage/network drivers ($($bootInfs.Count))"
                                foreach ($inf in $bootInfs) { Invoke-Dism "/Image:$(Q $P.MountRE) /Add-Driver /Driver:$(Q $inf)$fu" 'WinRE driver' -Soft }
                            }
                            Invoke-ImageCleanup $P.MountRE 'WinRE'
                            Dismount-Img $P.MountRE -Commit
                            Export-Img $reWim 1 $reNew
                            $reReady = $true
                        } catch {
                            Write-Warn "WinRE update skipped: $($_.Exception.Message)"
                            try { Dismount-Img $P.MountRE } catch { }
                            $reReady = $false
                        }
                    } else { Write-Warn 'No winre.wim in this edition - WinRE skipped.' }
                }
                if ($reReady) { Copy-Item -LiteralPath $reNew -Destination (Join-Path $P.Mount 'Windows\System32\Recovery\winre.wim') -Force }

                Write-Step 'Updating Windows'
                if ($hasDrv) {
                    Write-Sub "Drivers ($(@($S.Drivers).Count) packages)"
                    Invoke-Dism "/Image:$(Q $P.Mount) /Add-Driver /Driver:$(Q $P.DrvSel) /Recurse$fu" 'Add drivers' -Soft
                }
                foreach ($x in $upd.SSU) { Add-Pkg $P.Mount $x 'Servicing stack' -Soft }
                foreach ($x in $upd.LCU) {
                    try { Add-Pkg $P.Mount $x 'Cumulative update' -IgnoreHex @('800F081E') }
                    catch { Write-Err $lcuTip; throw }
                }
                foreach ($x in $upd.EKB) { Add-Pkg $P.Mount $x '22H2 enablement package' -IgnoreHex @('800F081E') -Soft }
                if ($Cfg.ResetBase) { Invoke-ImageCleanup $P.Mount 'Windows' }
                if ($Cfg.NetFx3) {
                    $sxs = Join-Path $P.Media 'sources\sxs'
                    if (Test-Path -LiteralPath $sxs) {
                        Write-Sub '.NET Framework 3.5 (from sources\sxs)'
                        Invoke-Dism "/Image:$(Q $P.Mount) /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$(Q $sxs)" 'Enable .NET 3.5' -Soft
                    } else { Write-Warn 'sources\sxs not found - .NET 3.5 skipped.' }
                }
                foreach ($x in $upd.NET481) { Add-Pkg $P.Mount $x '.NET Framework 4.8.1' -IgnoreHex @('800F081E') -Soft }
                foreach ($x in $upd.NET) { Add-Pkg $P.Mount $x '.NET cumulative update' -IgnoreHex @('800F081E') -Soft }
                if ($Cfg.Boot2023 -and -not $exSaved) { $exSaved = Save-BootFiles2023 $P.Mount $exDir }
                Dismount-Img $P.Mount -Commit
            }
            Write-Step "Exporting edition $k to the new install.wim"
            Export-Img $stage $k $final -Max
        }

        # ---- boot.wim (WinPE + Setup)
        Write-Title 'Updating boot.wim (WinPE / Setup)'
        Copy-Item -LiteralPath (Join-Path $P.Media 'sources\boot.wim') -Destination $bootSt -Force
        (Get-Item -LiteralPath $bootSt -Force).Attributes = 'Normal'
        $bootCount = @(Get-WindowsImage -ImagePath $bootSt).Count
        for ($b = 1; $b -le $bootCount; $b++) {
            Write-Step "boot.wim index $b of $bootCount"
            Mount-Img $bootSt $b $P.MountPE
            foreach ($x in $upd.SSU) { Add-Pkg $P.MountPE $x 'Servicing stack' -Soft }
            foreach ($x in $upd.LCU) {
                Add-Pkg $P.MountPE $x 'Servicing stack via LCU' -IgnoreHex @('8007007E', '800F081E') -Soft
                Add-Pkg $P.MountPE $x 'Cumulative update' -IgnoreHex @('800F081E') -Soft
            }
            if ($bootInfs.Count -gt 0) {
                Write-Sub "Storage/network drivers ($($bootInfs.Count))"
                foreach ($inf in $bootInfs) { Invoke-Dism "/Image:$(Q $P.MountPE) /Add-Driver /Driver:$(Q $inf)$fu" 'WinPE driver' -Soft }
            }
            Invoke-ImageCleanup $P.MountPE 'WinPE'
            if (Test-Path -LiteralPath (Join-Path $P.MountPE 'sources\setup.exe')) {
                Copy-Item -LiteralPath (Join-Path $P.MountPE 'sources\setup.exe') -Destination (Join-Path $bfDir 'setup.exe') -Force
                foreach ($n in 'bootmgfw.efi', 'bootmgr.efi', 'boot.stl') {
                    $f = Join-Path $P.MountPE "Windows\Boot\EFI\$n"
                    if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $bfDir $n) -Force }
                }
            }
            if ($Cfg.Boot2023 -and $b -eq 1) {
                $ok = Save-BootFiles2023 $P.MountPE $exDir
                if ($ok) { $exSaved = $true }
            }
            Dismount-Img $P.MountPE -Commit
            Export-Img $bootSt $b $bootFin
        }
    } catch {
        Write-Err $_.Exception.Message
        Write-Warn 'Discarding mounted images - your unpacked media was not changed.'
        Clear-Mounts
        throw
    }

    # ---- write results into the media folder
    Write-Title 'Updating the media folder'
    $srcDir = Join-Path $P.Media 'sources'
    foreach ($n in @('install.wim', 'install.esd')) { Remove-Item -LiteralPath (Join-Path $srcDir $n) -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $srcDir -Filter 'install*.swm' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Move-Item -LiteralPath $final -Destination (Join-Path $srcDir 'install.wim') -Force
    Move-Item -LiteralPath $bootFin -Destination (Join-Path $srcDir 'boot.wim') -Force
    Write-Ok 'install.wim and boot.wim replaced'

    foreach ($cab in $upd.SETUP) {
        Write-Sub "Setup Dynamic Update -> sources ($(Split-Path $cab -Leaf))"
        $code = Invoke-Exe (Join-Path $env:SystemRoot 'System32\expand.exe') ("$(Q $cab) -F:* $(Q $srcDir)")
        if ($code -ne 0) { Write-Warn "expand.exe exit $code" }
    }
    $setupExe = Join-Path $bfDir 'setup.exe'
    if (Test-Path -LiteralPath $setupExe) { Copy-Item -LiteralPath $setupExe -Destination (Join-Path $srcDir 'setup.exe') -Force; Write-Sub 'setup.exe synced with boot.wim' }
    foreach ($f in @(Get-ChildItem -LiteralPath $P.Media -Recurse -Filter 'b*.efi' -File -Force)) {
        if (@('bootmgfw.efi', 'bootx64.efi', 'bootia32.efi', 'bootaa64.efi') -contains $f.Name.ToLower() -and (Test-Path -LiteralPath (Join-Path $bfDir 'bootmgfw.efi'))) {
            Copy-Item -LiteralPath (Join-Path $bfDir 'bootmgfw.efi') -Destination $f.FullName -Force
        } elseif ($f.Name -ieq 'bootmgr.efi' -and (Test-Path -LiteralPath (Join-Path $bfDir 'bootmgr.efi'))) {
            Copy-Item -LiteralPath (Join-Path $bfDir 'bootmgr.efi') -Destination $f.FullName -Force
        }
    }
    if (Test-Path -LiteralPath (Join-Path $bfDir 'boot.stl')) {
        Copy-Item -LiteralPath (Join-Path $bfDir 'boot.stl') -Destination (Join-Path $P.Media 'efi\microsoft\boot\boot.stl') -Force
    }
    Write-Sub 'Boot manager files refreshed'

    $b2023 = $false
    if ($Cfg.Boot2023) {
        if ($exSaved) {
            try { Set-Boot2023 $exDir; $b2023 = $true; Write-Ok 'Media now boots with the Windows UEFI CA 2023 signed boot manager' }
            catch { Write-Warn "2023 boot files not applied: $($_.Exception.Message)" }
        } else { Write-Warn '2023-signed boot files not found in the updated image (needs the 2024-04 update or newer) - standard boot files kept.' }
    }
    Sync-Unattend

    $newList = Get-ImageList (Join-Path $srcDir 'install.wim')
    $wimSize = (Get-Item -LiteralPath (Join-Path $srcDir 'install.wim')).Length
    if ($Cfg.SplitFat32 -and $wimSize -gt 3900MB) {
        Write-Step 'Splitting install.wim into 3.8 GB .swm parts (FAT32)'
        Invoke-Dism "/Split-Image /ImageFile:$(Q (Join-Path $srcDir 'install.wim')) /SWMFile:$(Q (Join-Path $srcDir 'install.swm')) /FileSize:3800" 'Split image'
        Remove-Item -LiteralPath (Join-Path $srcDir 'install.wim') -Force
    }

    $S.Serviced = [ordered]@{
        When     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Build    = $newList[0].Version
        Editions = @($newList | ForEach-Object { "$($_.Name) ($($_.Version))" })
        Boot2023 = $b2023
        Updates  = @($S.Updates | ForEach-Object { $_.KB })
    }
    $S.Iso = $null
    Save-State
    Remove-Item -LiteralPath $P.Temp -Recurse -Force -ErrorAction SilentlyContinue
    Clear-Mounts

    Write-Title 'Slipstream finished'
    foreach ($n in $newList) { Write-Ok ('{0,-44} {1}' -f (Limit-Text $n.Name 44), $n.Version) }
    Write-Info ('install.wim: {0}   time: {1:hh\:mm\:ss}' -f (Format-Size $wimSize), ((Get-Date) - $t0))
}
#endregion

#region ---------------------------------------------------------------- [7] Build ISO
function Invoke-Build([switch]$Auto) {
    Assert-Unpacked
    $S = $Script:S; $P = $Script:P; $Cfg = $Script:Cfg
    Write-Title 'Build ISO'
    $osc = Find-Oscdimg
    if (-not $osc) { throw 'oscdimg.exe not found - use [T] Tools in the menu to download it.' }
    Write-Info "oscdimg: $osc"
    if (-not $S.Serviced -and -not $Auto) {
        Write-Warn 'The media has not been slipstreamed yet (step 6).'
        if (-not (Read-YesNo 'Build the ISO anyway?' $false)) { return }
    }
    Sync-Unattend
    Test-UnattendSelection

    $m = $P.Media
    $etfs = Join-Path $m 'boot\etfsboot.com'
    $ms = Join-Path $m 'efi\microsoft\boot'
    $order = @()
    if ($S.Serviced -and $S.Serviced.Boot2023) {
        if ($Cfg.NoPrompt) { $order += 'efisys_noprompt_ex.bin' }
        $order += 'efisys_ex.bin'
    }
    if ($Cfg.NoPrompt) { $order += 'efisys_noprompt.bin' }
    $order += 'efisys.bin'
    $efi = $null
    foreach ($n in $order) { $c = Join-Path $ms $n; if (Test-Path -LiteralPath $c) { $efi = $c; break } }
    if (-not $efi) { throw "No UEFI boot image (efisys*.bin) found in $ms." }
    Write-Info "UEFI boot image: $(Split-Path $efi -Leaf)"

    $build = if ($S.Serviced) { $S.Serviced.Build } elseif (@($S.Images).Count -gt 0) { $S.Images[0].Version } else { 'unknown' }
    $tag = if ($S.Family -and $S.Family.VerToken) { $S.Family.VerToken } else { 'custom' }
    $arch = if ($S.Family) { $S.Family.Arch } else { 'x64' }
    $label = if ($S.Family -and $S.Family.Label) { $S.Family.Label } else { 'WIN10_CUSTOM' }
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
    New-Item -ItemType Directory -Force -Path $P.Output | Out-Null
    $iso = Join-Path $P.Output ('Win10_{0}_{1}_{2}_{3:yyyyMMdd}.iso' -f $tag, $build, $arch, (Get-Date))
    if (-not $Auto) {
        $ans = Read-Host "  Output file (Enter = $iso)"
        if ($ans) { $iso = $ans.Trim().Trim('"'); if ($iso -notmatch '\.iso$') { $iso += '.iso' } }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $iso -Parent) | Out-Null
    if (Test-Path -LiteralPath $iso) { Remove-Item -LiteralPath $iso -Force }

    if (Test-Path -LiteralPath $etfs) { $bootdata = "-bootdata:2#p0,e,b$(Q $etfs)#pEF,e,b$(Q $efi)" }
    else { $bootdata = "-bootdata:1#pEF,e,b$(Q $efi)"; Write-Info 'No etfsboot.com - building a UEFI-only ISO.' }
    Write-Step 'Writing ISO (BIOS + UEFI, UDF)'
    $code = Invoke-Exe $osc ("-m -o -u2 -udfver102 -l$label $bootdata $(Q $m) $(Q $iso)")
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $iso)) { throw "oscdimg failed (exit $code)." }

    $size = (Get-Item -LiteralPath $iso).Length
    Write-Ok "ISO ready: $iso ($(Format-Size $size))"
    Write-Info 'Calculating SHA-256...'
    $hash = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
    Set-Content -LiteralPath "$iso.sha256" -Value "$hash *$(Split-Path $iso -Leaf)" -Encoding ASCII
    Write-Info "SHA-256: $hash"
    $S.Iso = $iso
    Save-State
    if (-not $Auto -and (Read-YesNo 'Open the output folder?' $true)) { Start-Process explorer.exe "/select,`"$iso`"" }
}
#endregion

#region ---------------------------------------------------------------- Run everything / options / clean
function Invoke-All {
    Write-Title "Full run - $Script:AppName $Script:AppVersion"
    Write-Info 'Questions first, then everything else runs on its own.'
    if ($Script:S.Unpacked -and $Script:S.SourceIso -and -not $Script:S.Serviced -and
        (Read-YesNo "Use the ISO that is already unpacked ($(Split-Path $Script:S.SourceIso -Leaf))?" $true)) {
        Invoke-Analyze
    } else {
        if ($Script:S.Serviced -and $Script:S.SourceIso -and (Test-Path -LiteralPath $Script:S.SourceIso)) {
            Write-Info 'The unpacked media was already serviced - a fresh copy is needed.'
            if (Read-YesNo "Start again from $(Split-Path $Script:S.SourceIso -Leaf)?" $true) { $Script:IsoPath = $Script:S.SourceIso }
        }
        Invoke-Unpack
    }
    Invoke-Editions

    $nd = @($Script:S.Drivers).Count
    if ($nd -gt 0) {
        if (-not (Read-YesNo "Keep the $nd driver package(s) already selected?" $true)) { $Script:S.Drivers = @(); Save-State; $nd = 0 }
    }
    if ($nd -eq 0) {
        $found = Find-DriverBackupFolders
        if ($found.Count -gt 0 -and (Read-YesNo "Import the drivers in $($found[0])?" $true)) {
            Import-DriverFolder $found[0]
        } else {
            Write-Host '   Drivers: [1] from THIS PC   [2] import a drivers folder   [Enter] none'
            switch ((Read-Host '  Choice').Trim()) {
                '1' { Add-HostDrivers }
                '2' { Import-DriverFolder }
            }
        }
    }

    if (-not $Script:S.Unattend -and (Read-YesNo 'Add an autounattend.xml?' $true)) { Select-UnattendFile }

    Write-Host ''
    Write-Host '  All set - downloading, slipstreaming and building now. This takes a while (30-90 min).' -ForegroundColor Magenta
    if ($Script:S.Family.Supported) { Invoke-Download -Auto } else { Write-Warn 'Updates skipped (unsupported build).' }
    Invoke-Service -Auto
    Invoke-Build -Auto
    Write-Title 'Everything done'
    Write-Ok $Script:S.Iso
}
function Invoke-Options {
    $items = @(
        @('1', 'KeepOnlySelected', 'Keep only the selected editions in the new ISO'),
        @('2', 'NetFx3', 'Enable .NET Framework 3.5 (from the ISO''s sources\sxs)'),
        @('3', 'NetFx481', 'Add .NET Framework 4.8.1 (Windows 10 2004-22H2)'),
        @('4', 'ResetBase', 'Component cleanup /ResetBase (smaller image, updates can''t be removed)'),
        @('5', 'BootDrivers', 'Also put storage + network drivers into boot.wim and WinRE'),
        @('6', 'ForceUnsigned', 'Allow unsigned / modified drivers (/ForceUnsigned)'),
        @('7', 'NoPrompt', 'UEFI boot without "Press any key to boot from CD or DVD"'),
        @('8', 'Boot2023', 'Boot manager signed by Windows UEFI CA 2023 (see note)'),
        @('9', 'SplitFat32', 'Split install.wim into 3.8 GB .swm parts (FAT32 USB sticks)')
    )
    while ($true) {
        Write-Title 'Options'
        foreach ($it in $items) {
            $on = [bool]$Script:Cfg[$it[1]]
            $tagText = if ($on) { ' ON ' } else { ' OFF' }
            $col = if ($on) { 'Green' } else { 'DarkGray' }
            Write-Host "   [$($it[0])] " -NoNewline
            Write-Host "[$tagText]" -ForegroundColor $col -NoNewline
            Write-Host " $($it[2])"
        }
        Write-Host ''
        Write-Host "   [W] Work folder ............ $($Script:Cfg.WorkDir)"
        Write-Host "   [M] Win10 update cutoff .... $($Script:Cfg.Win10Cutoff)  (2004-22H2 / LTSC 2021)"
        Write-Host '   [D] Restore defaults'
        Write-Host '   [0] Save and go back'
        $c = (Read-Host '  Choice').Trim().ToUpper()
        $hit = $items | Where-Object { $_[0] -eq $c }
        if ($hit) {
            $name = $hit[1]
            $Script:Cfg[$name] = -not [bool]$Script:Cfg[$name]
            if ($name -eq 'Boot2023' -and $Script:Cfg[$name]) {
                Write-Warn 'With Secure Boot ON, this ISO only boots on PCs whose UEFI db already trusts "Windows UEFI CA 2023".'
                Write-Warn 'Older firmware needs that Secure Boot update first (or Secure Boot off). Needs a 2024-04+ update in the image.'
                Read-Host '  Press Enter' | Out-Null
            }
            continue
        }
        switch ($c) {
            'W' {
                $w = Read-Host '  New work folder (short NTFS path without spaces, e.g. D:\W10U)'
                if ($w) {
                    $Script:Cfg.WorkDir = $w.Trim().Trim('"').TrimEnd('\')
                    Write-Info 'The new folder starts empty - unpack the ISO again there.'
                }
            }
            'M' {
                $mth = Read-Host '  Newest month to integrate (YYYY-MM). Default 2025-10 = last non-ESU update'
                if ($mth -match '^\d{4}-\d{2}$') { $Script:Cfg.Win10Cutoff = $mth } elseif ($mth) { Write-Warn 'Use the YYYY-MM format.' }
            }
            'D' { $Script:Cfg = Get-DefaultSettings; Write-Ok 'Defaults restored.' }
            '0' { Save-Settings; Write-Ok 'Saved.'; return }
            ''  { Save-Settings; return }
        }
    }
}
function Invoke-Clean {
    Write-Title 'Clean up'
    Clear-Mounts
    Remove-Item -LiteralPath $Script:P.Temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Script:P.Work 'mnt') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok 'Mounts and temporary files removed.'
    if ((Test-Path -LiteralPath $Script:P.Updates) -and (Read-YesNo 'Delete downloaded updates too?' $false)) {
        Remove-Item -LiteralPath $Script:P.Updates -Recurse -Force; $Script:S.Updates = @(); Write-Ok 'Updates deleted.'
    }
    if ((Test-Path -LiteralPath $Script:P.Media) -and (Read-YesNo 'Delete the unpacked media folder?' $false)) {
        Remove-Item -LiteralPath $Script:P.Media -Recurse -Force
        $Script:S.Unpacked = $false; $Script:S.Serviced = $null; $Script:S.Images = @(); $Script:S.Family = $null; $Script:S.Selected = @()
        Write-Ok 'Media deleted.'
    }
    if ((Test-Path -LiteralPath $Script:P.Output) -and (Read-YesNo 'Delete built ISOs in the output folder?' $false)) {
        Remove-Item -LiteralPath $Script:P.Output -Recurse -Force; $Script:S.Iso = $null; Write-Ok 'Output deleted.'
    }
    Save-State
}
#endregion

#region ---------------------------------------------------------------- status file for the .cmd menu
function Write-StatusFile {
    $S = $Script:S
    $v = [ordered]@{}
    $v.S_WORKPATH = $Script:P.Work
    $free = ''
    try { $free = ' (free ' + (Format-Size (New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Script:P.Work)))).AvailableFreeSpace) + ')' } catch { }
    $v.S_WORK = $Script:P.Work + $free
    $v.S_ISO = if ($S.SourceIso) { Split-Path $S.SourceIso -Leaf } else { 'none yet' }
    $v.S_IMAGE = if ($S.Family -and @($S.Images).Count -gt 0) { '{0} - build {1} - {2} - {3} edition(s)' -f $S.Family.Name, $S.Images[0].Version, $S.Family.Arch, @($S.Images).Count } else { '-' }

    if ($S.Unpacked) { $v.S_1 = 'done'; $v.C_1 = 'ok' } else { $v.S_1 = 'to do'; $v.C_1 = 'todo' }
    $ns = @($S.Selected).Count
    if ($ns -gt 0) { $v.S_2 = "$ns of $(@($S.Images).Count) selected"; $v.C_2 = 'ok' } else { $v.S_2 = 'to do'; $v.C_2 = 'todo' }
    $lcu = @($S.Updates | Where-Object { $_.Kind -eq 'LCU' }) | Select-Object -First 1
    if ($S.Family -and -not $S.Family.Supported) { $v.S_3 = 'not available for this build'; $v.C_3 = 'warn' }
    elseif ($lcu) { $v.S_3 = '{0} {1} + {2} more' -f $lcu.KB, $lcu.Date.Substring(0, 7), (@($S.Updates).Count - 1); $v.C_3 = 'ok' }
    else { $v.S_3 = 'to do'; $v.C_3 = 'todo' }
    $nd = @($S.Drivers).Count
    if ($nd -gt 0) { $v.S_4 = '{0} packages ({1} for boot)' -f $nd, @($S.Drivers | Where-Object { $Script:BootClasses -contains $_.Class }).Count; $v.C_4 = 'ok' } else { $v.S_4 = 'none (optional)'; $v.C_4 = 'opt' }
    if ($S.Unattend) { $v.S_5 = Split-Path $S.Unattend.Source -Leaf; $v.C_5 = 'ok' } else { $v.S_5 = 'none (optional)'; $v.C_5 = 'opt' }
    if ($S.Serviced) { $v.S_6 = "done - build $($S.Serviced.Build)"; $v.C_6 = 'ok' } else { $v.S_6 = 'to do'; $v.C_6 = 'todo' }
    if ($S.Iso -and (Test-Path -LiteralPath $S.Iso)) { $v.S_7 = Split-Path $S.Iso -Leaf; $v.C_7 = 'ok' } else { $v.S_7 = 'to do'; $v.C_7 = 'todo' }

    $lines = @('@echo off')
    foreach ($k in $v.Keys) { $lines += ('set "{0}={1}"' -f $k, ([string]$v[$k] -replace '[%!^&|<>"]', '')) }
    Set-Content -LiteralPath $Script:StatusFile -Value $lines -Encoding ASCII
}
#endregion

#region ---------------------------------------------------------------- main
$exitCode = 0
try {
    $Script:Cfg = Import-Settings
    Initialize-Paths
    $Script:S = Import-State
    if ($Action -ne 'Status') {
        if (-not (Test-Admin)) { throw 'Run this as administrator (the .cmd launcher does that for you).' }
        New-Item -ItemType Directory -Force -Path $Script:P.Logs | Out-Null
        $Script:LogFile = Join-Path $Script:P.Logs 'engine.log'
        $Script:DismLog = Join-Path $Script:P.Logs 'dism.log'
        Add-Log "---- $Script:AppName $Script:AppVersion  action=$Action"
    }
    switch ($Action) {
        'Status'   { }
        'Unpack'   { Invoke-Unpack }
        'Analyze'  { Invoke-Analyze }
        'Editions' { Invoke-Editions }
        'Download' { Invoke-Download }
        'Drivers'  { Invoke-Drivers }
        'ImportDrivers' { Import-DriverFolder $DriverPath }
        'Unattend' { Invoke-Unattend }
        'Service'  { Invoke-Service }
        'Build'    { Invoke-Build }
        'All'      { Invoke-All }
        'Options'  { Invoke-Options; Initialize-Paths; $Script:S = Import-State }
        'Clean'    { Invoke-Clean }
    }
} catch {
    Write-Err $_.Exception.Message
    Add-Log ($_ | Out-String)
    $exitCode = 1
} finally {
    try { Write-StatusFile } catch { }
}
exit $exitCode
#endregion
