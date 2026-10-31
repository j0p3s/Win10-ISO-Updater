@echo off
:: ===========================================================================
::  Windows-ISO-updater-GUI_v4.4.0.cmd  -  one file, graphical interface
::  Windows ISO Updater: the file name carries the version (vX.X.X).
::  - unpacks a Windows 10 or Windows 11 ISO and detects its build
::  - downloads its updates from the Microsoft Update Catalog
::  - slipstreams updates and drivers (this PC or a Drivers-Backup folder)
::  - re-signs modded drivers (NVCleanstall / edited INF, e.g. NVIDIA) with your
::    own certificate and installs them through $OEM$ + SetupComplete.cmd
::  - adds autounattend.xml and your own $OEM$ folder
::  - rebuilds a bootable BIOS + UEFI ISO
::  Tools it needs (oscdimg, Inf2Cat, signtool) are downloaded automatically.
::  Just double-click this file.
:: ===========================================================================
setlocal EnableExtensions DisableDelayedExpansion
title Windows ISO Updater
:: Windows PowerShell by its full path: cmd.exe looks in the current folder first, so a plain "powershell"
:: would run a powershell.exe lying next to this file - and with administrator rights.
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
fltmc >nul 2>&1 && goto :admin_ok
echo Requesting administrator rights...
set "W10U_SELF=%~f0"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:W10U_SELF -Verb RunAs"
exit /b

:admin_ok
set "W10U_SELF=%~f0"
echo Starting Windows ISO Updater v4.4.0 ...  (this window hides when the program opens)
"%PSEXE%" -NoProfile -STA -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:W10U_SELF);$i=$t.IndexOf('#'+'PS-BEGIN');Invoke-Expression $t.Substring($i)"
if errorlevel 1 pause
exit /b
#PS-BEGIN
#ENGINE-BEGIN
# ============================================================================
#  Engine - loaded into the GUI runspace and into the background worker.
#  Servicing order follows Microsoft's "Update Windows installation media with
#  Dynamic Update" guide (WinRE -> install.wim -> boot.wim -> media).
# ============================================================================
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Script:AppName      = 'Windows-ISO-Updater'
$Script:AppTitle     = 'Windows ISO Updater'
$Script:AppVersion   = '4.4.0'
$Script:Root         = Split-Path -Parent $env:W10U_SELF
$ToolsDir            = Join-Path $Script:Root 'tools'
$IsoPath             = $null
$Script:NoAsk        = $false
# The file name carries the version (Windows-ISO-updater-GUI_vX.X.X.cmd), so the settings file does not:
# a new version picks up the options of the old one. Win10-ISO-Updater.settings.json (3.3 and older) is read once.
$Script:SettingsFile = Join-Path $Script:Root 'Windows-ISO-Updater.settings.json'
$Script:LegacySettingsFile = Join-Path $Script:Root 'Win10-ISO-Updater.settings.json'
$Script:SignDir      = Join-Path $Script:Root 'signing'
$Script:CertSubject  = 'CN=Custom Driver Signing'
$Script:GeneratorUrl = 'https://github.com/j0p3s/autounattended-generator'
$Script:IsoPageUrl   = 'https://www.microsoft.com/software-download/windows10ISO'
$Script:IsoPageUrl11 = 'https://www.microsoft.com/software-download/windows11'
$Script:CatalogBase  = 'https://www.catalog.update.microsoft.com'
$Script:Dism         = Join-Path $env:SystemRoot 'System32\dism.exe'
$Script:Inv          = [Globalization.CultureInfo]::InvariantCulture
$Script:UA           = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$Script:BootClasses  = @('SCSIAdapter', 'HDC', 'Net')
$Script:LogFile      = $null
$Script:DismLog      = $null
$Script:LastDism     = 0
$Script:SignTool     = $null

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

#region ---------------------------------------------------------------- output (goes to the GUI log)
function Add-Log([string]$Text) {
    if (-not $Script:LogFile) { return }
    try { Add-Content -LiteralPath $Script:LogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Text) -Encoding UTF8 } catch { }
}
# Every Write-Host of the engine lands in the GUI log (color kept). -NoNewline text
# becomes the status line under the progress bar instead.
function Write-Host {
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)]$Object, $ForegroundColor, $BackgroundColor, [switch]$NoNewline, $Separator)
    $text = (@($Object) | ForEach-Object { "$_" }) -join ' '
    if (-not $Script:Sync) {
        $prm = @{ Object = $text; NoNewline = $NoNewline }
        if ($ForegroundColor) { $prm.ForegroundColor = $ForegroundColor }
        Microsoft.PowerShell.Utility\Write-Host @prm
        return
    }
    if ($NoNewline) { $Script:Sync.Status = $text.Trim(); return }
    $c = if ($ForegroundColor) { [string]$ForegroundColor } else { 'Gray' }
    $Script:Sync.Queue.Enqueue(@($c, $text))
}
function Write-Title([string]$Text) { Write-Host ''; Write-Host "==  $Text" -ForegroundColor Cyan; Add-Log "== $Text" }
function Write-Step([string]$Text) { Write-Host "  >> $Text" -ForegroundColor Cyan; Add-Log ">> $Text" }
function Write-Sub([string]$Text)  { Write-Host "     - $Text" -ForegroundColor White; Add-Log "   - $Text" }
function Write-Info([string]$Text) { Write-Host "     $Text" -ForegroundColor Gray; Add-Log "   $Text" }
function Write-Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green; Add-Log "OK $Text" }
function Write-Warn([string]$Text) { Write-Host "  [!!] $Text" -ForegroundColor Yellow; Add-Log "WARN $Text" }
function Write-Err([string]$Text)  { Write-Host "  [XX] $Text" -ForegroundColor Red; Add-Log "ERROR $Text" }

# Questions from the background worker are shown by the GUI as a Yes/No box.
function Read-YesNo([string]$Question, [bool]$Default = $true) {
    if (-not $Script:IsWorker -or -not $Script:Sync) { return $Default }
    $Script:Sync.Answer = $null
    $Script:Sync.Question = @{ Text = $Question; Default = $Default }
    while ($null -eq $Script:Sync.Answer) { Start-Sleep -Milliseconds 150 }
    $a = [bool]$Script:Sync.Answer
    $Script:Sync.Answer = $null
    Add-Log "ASK $Question -> $a"
    return $a
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
        SignCleanup      = $true
        InstallOemDrivers = $false
        SignOnlyThisPc   = $false
        WinVersion       = '10'
        UiTheme          = 'Dark'
        UiZoom           = 100
        UiFont           = 'Segoe UI'
        SignIsolate      = $true
        SignJobs         = 0
        SignEngine       = 'makecat'
        UiLanguage       = 'auto'
        ParallelBoot     = $true
        ParallelEditions = 0
        BootSkipPE       = $false
        DefenderExclude  = $false
    }
}
function Import-Settings {
    $s = Get-DefaultSettings
    $sf = $Script:SettingsFile
    if (-not (Test-Path -LiteralPath $sf) -and $Script:LegacySettingsFile -and (Test-Path -LiteralPath $Script:LegacySettingsFile)) { $sf = $Script:LegacySettingsFile }
    if (Test-Path -LiteralPath $sf) {
        try {
            $j = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json
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
        Signed   = Join-Path $w 'signed'
        Scratch  = Join-Path $w 'temp\scratch'
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
        Oem = $null; Signed = @(); OemSynced = $false
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
    foreach ($k in 'Images', 'Selected', 'Updates', 'Drivers', 'Signed') { if ($null -eq $s[$k]) { $s[$k] = @() } else { $s[$k] = @($s[$k]) } }
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
function Invoke-Dism {
    # Runs dism.exe with live progress in the console. Exit code lands in $Script:LastDism.
    param([string]$Arguments, [string]$What = 'DISM', [string[]]$OkHex = @(), [switch]$Soft)
    $ok = @(0, 3010)
    foreach ($h in $OkHex) { $ok += [Convert]::ToInt32($h, 16) }
    $sd = ''
    if ($Arguments -match '^/Image:' -and $Script:P -and $Script:P.Scratch) {
        New-Item -ItemType Directory -Force -Path $Script:P.Scratch | Out-Null
        $sd = ' /ScratchDir:' + (Q $Script:P.Scratch)
    }
    $code = Invoke-Exe $Script:Dism ('/English /LogPath:' + (Q $Script:DismLog) + $sd + ' ' + $Arguments)
    $Script:LastDism = $code
    if ($ok -contains $code) { return }
    $msg = "$What failed - DISM error 0x$($code.ToString('X8'))"
    if ($Soft) { Write-Warn $msg; return }
    throw $msg
}
function Mount-Img([string]$ImageFile, [int]$Index, [string]$MountDir) {
    if (Test-Path -LiteralPath $MountDir) {
        if (@(Get-ChildItem -LiteralPath $MountDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            throw "Mount folder $MountDir is not empty - use Clean up on the Options page first."
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
    if ($root -notmatch '^[A-Za-z]:\\') { throw "The work folder must be on a local NTFS drive, not a network path ($w)." }
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
    if (-not $Script:S.Family -or -not $Script:S.Family.Os -or @($Script:S.Images).Count -eq 0) { Invoke-Analyze }
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
        $code = Invoke-Exe $curl ("-L --fail --retry 3 --retry-delay 3 -C - --progress-bar -o $(Q $part) $(Q $Url)") -MergeErr
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
        if ($Script:SavedFiles -and $Script:SavedFiles.ContainsKey($name.ToLower())) { Write-Info "Already included: $name"; continue }
        $dest = Join-Path $dir $name
        Save-Url $u $dest
        if ($Script:SavedFiles) { $Script:SavedFiles[$name.ToLower()] = $true }
        $files += $dest
    }
    return [ordered]@{ Kind = $Kind; KB = $Hit.KB; Title = $Hit.Title; Date = $Hit.Date.ToString('yyyy-MM-dd'); Files = $files }
}
#endregion


#region ---------------------------------------------------------------- [1] Unpack / Analyze
function Invoke-Unpack {
    Write-Title 'Unpack ISO'
    $iso = $IsoPath
    if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { throw 'No ISO selected.' }
    $iso = (Resolve-Path -LiteralPath $iso).Path
    Write-Info "ISO  : $iso  ($(Format-Size (Get-Item -LiteralPath $iso).Length))"
    Write-Info "Work : $($Script:P.Work)"
    Test-WorkDir 30
    Clear-Mounts

    if ((Test-Path -LiteralPath $Script:P.Media) -and @(Get-ChildItem -LiteralPath $Script:P.Media -Force).Count -gt 0) {
        if (-not $Script:NoAsk -and -not (Read-YesNo 'The work folder already has unpacked media. Replace it?' $true)) { return }
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

    $prevIso = $Script:S.SourceIso
    $Script:S.SourceIso = $iso
    $Script:S.Unpacked  = $true
    if ($prevIso -ne $iso) { $Script:S.Selected = @() }
    $Script:S.Updates   = @()
    $Script:S.Serviced  = $null
    $Script:S.Iso       = $null
    $Script:S.OemSynced = $false
    $Script:S.Images    = @()
    $Script:S.Family    = $null
    Save-State
    Invoke-Analyze
    Sync-Unattend
}

#endregion

#region ---------------------------------------------------------------- Windows 10 / Windows 11
# Which Windows the image is and how its updates are named in the Microsoft Update Catalog.
#   Windows 10: 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 / LTSC 2021 (2004-21H2 get the 22H2 enablement package)
#   Windows 11: 21H2, 22H2 / 23H2 (22H2 gets the 23H2 enablement package), 24H2 / LTSC 2024, 25H2
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
        Os = '10'; Build = $b; Arch = $arch; ArchTitle = $archTitle; ArchToken = $archTok; Product = $null; VerToken = $null
        Cap = $null; NeedsEkb = $false; EkbKB = ''; EkbFor = ''; NoSsu = $false; Supported = $true; Name = $null; IsLtsc = $ltsc; Label = $null
    }
    if ($b -ge 22000) {
        # Windows 11 cumulative updates carry the servicing stack - there is no standalone SSU to look for
        $f.Os = '11'; $f.NoSsu = $true
        if ($b -eq 22000) { $f.VerToken = '21H2'; $f.Name = 'Windows 11 21H2'; $f.Cap = '2024-10' }     # end of servicing
        elseif ($b -eq 22621) { $f.VerToken = '23H2'; $f.Name = 'Windows 11 build 22621 -> 23H2'; $f.NeedsEkb = $true; $f.EkbKB = 'KB5027397'; $f.EkbFor = '23H2' }
        elseif ($b -eq 22631) { $f.VerToken = '23H2'; $f.Name = 'Windows 11 23H2' }
        elseif ($b -eq 26100) { $f.VerToken = '24H2'; $f.Name = $(if ($ltsc) { 'Windows 11 LTSC 2024 (24H2)' } else { 'Windows 11 24H2' }) }
        elseif ($b -eq 26200) { $f.VerToken = '25H2'; $f.Name = 'Windows 11 25H2' }
        else { $f.Supported = $false; $f.Name = "Windows 11 (build $b)" }
    } elseif ($b -ge 19041 -and $b -le 19045) {
        if ($b -eq 19044 -and $ltsc) { $f.VerToken = '21H2'; $f.Name = 'Windows 10 LTSC 2021 (21H2)' }
        else {
            $f.VerToken = '22H2'; $f.Name = 'Windows 10 22H2'
            if ($b -lt 19045) { $f.NeedsEkb = $true; $f.EkbKB = 'KB5015684'; $f.EkbFor = '22H2'; $f.Name = "Windows 10 build $b -> 22H2" }
        }
        $f.Cap = [string]$Script:Cfg.Win10Cutoff
    } elseif ($b -eq 17763) { $f.VerToken = '1809'; $f.Name = 'Windows 10 1809 / LTSC 2019' }
    elseif ($b -eq 14393) { $f.VerToken = '1607'; $f.Name = 'Windows 10 1607 / LTSB 2016' }
    else { $f.Supported = $false; $f.Name = "Windows 10 build $b (out of support)" }
    if ($f.VerToken) { $f.Product = "Windows $($f.Os) Version $($f.VerToken)" }
    if (-not $archTitle) { $f.Supported = $false }
    $tag = if ($f.VerToken) { $f.VerToken } else { "$b" }
    $f.Label = ('W' + $f.Os + '_' + $tag + '_' + $arch).ToUpper()
    return $f
}
function Get-FamilyOs($Fam) {
    if ($Fam -and $Fam.Os) { return [string]$Fam.Os }
    if ($Fam -and [int]$Fam.Build -ge 22000) { return '11' }
    return '10'
}
function Find-Update {
    # Walks back month by month ("YYYY-MM ..." titles) and returns the newest match.
    param([string]$Kind, $Fam, [string]$MaxMonth, [int]$Lookback = 12)
    $p = [regex]::Escape($Fam.Product); $a = [regex]::Escape($Fam.ArchTitle)
    $v = [regex]::Escape($Fam.VerToken); $t = [regex]::Escape($Fam.ArchToken)
    $o = [regex]::Escape('Windows ' + (Get-FamilyOs $Fam))
    foreach ($ym in (Get-MonthList $MaxMonth $Lookback)) {
        $y = [regex]::Escape($ym)
        switch ($Kind) {
            'LCU'   { $q = "$ym Cumulative Update for $($Fam.Product) for $($Fam.ArchTitle)"; $rx = "^$y Cumulative Update for $p for $a" }
            'SSU'   { $q = "$ym Servicing Stack Update for $($Fam.Product) for $($Fam.ArchTitle)"; $rx = "^$y Servicing Stack Update for $p for $a" }
            'NET'   { $q = "$ym Cumulative Update for .NET Framework $($Fam.Product) $($Fam.ArchToken)"; $rx = "^$y Cumulative Update for \.NET Framework .*$o.*\b$v\b.*\b$t\b" }
            default { $q = "$ym Dynamic Update for $($Fam.Product) for $($Fam.ArchTitle)"; $rx = "^$y (Safe OS |Setup )?Dynamic Update for $o.*\b$v\b.*$a" }
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
    $o = 'Windows ' + (Get-FamilyOs $Fam)
    $hits = @(Search-Catalog $KB | Where-Object {
            $_.Title -match "\b$t\b" -and $_.Title -match [regex]::Escape($o) -and (-not $MustMatch -or $_.Title -match $MustMatch)
        })
    if ($hits.Count -gt 0) { return (@($hits | Sort-Object Date -Descending))[0] }
}
# The KB number in a catalog file name (windows11.0-kb5043080-x64_<sha1>.msu -> 5043080), 0 if none.
function Get-FileKB([string]$File) {
    $m = [regex]::Match((Split-Path $File -Leaf), '(?i)kb(\d{6,8})')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 0
}
function Get-UpdateFiles {
    $h = @{ SSU = @(); LCU = @(); EKB = @(); SAFEOS = @(); SETUP = @(); NET = @(); NET481 = @() }
    $seenLeaf = @{}
    foreach ($u in @($Script:S.Updates)) {
        $files = @($u.Files)
        # Windows 11 24H2 and later: the catalog entry of a cumulative update also holds the checkpoint
        # update it builds on (an older KB) - that one has to go in first.
        if ($u.Kind -eq 'LCU') { $files = @($files | Sort-Object { Get-FileKB $_ }) }
        foreach ($f in $files) {
            if (-not (Test-Path -LiteralPath $f)) { Write-Warn "Missing $f - run Download again."; continue }
            $leaf = (Split-Path $f -Leaf).ToLower()
            if ($seenLeaf.ContainsKey($leaf)) { continue }
            $seenLeaf[$leaf] = $true
            $h[$u.Kind] += $f
        }
    }
    return $h
}
#endregion

#region ---------------------------------------------------------------- DISM for the image
# Windows supports servicing an image only with a DISM of the same or a newer Windows. Builds that share
# one code base count as one (Windows 10 2004-22H2, Windows 11 22H2 / 23H2, 24H2 / 25H2).
function Get-BaseBuild([int]$Build) {
    if ($Build -ge 26100 -and $Build -le 26200) { return 26100 }
    if ($Build -ge 22621 -and $Build -le 22631) { return 22621 }
    if ($Build -ge 19041 -and $Build -le 19045) { return 19041 }
    return $Build
}
function Get-DismBuild([string]$Exe) {
    try { return [int](Get-Item -LiteralPath $Exe -ErrorAction Stop).VersionInfo.FileBuildPart } catch { return 0 }
}
function Find-AdkDism {
    $arch = switch (Get-HostArch) { 'x64' { 'amd64' } 'arm64' { 'arm64' } default { 'x86' } }
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $pf) { continue }
        $d = Join-Path $pf "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$arch\DISM\dism.exe"
        if (Test-Path -LiteralPath $d) { return $d }
    }
    return $null
}
# The DISM to service an image of $ImageBuild: $Current (by default the one in use, normally this PC's), or -
# for a newer Windows, such as Windows 11 from a Windows 10 PC - the one of the Windows ADK Deployment Tools.
# -Install offers to install those.
function Get-ServicingDism([int]$ImageBuild, [switch]$Install, [string]$Current = $Script:Dism) {
    $sys = $Current
    if (-not $sys) { $sys = Join-Path $env:SystemRoot 'System32\dism.exe' }
    $need = Get-BaseBuild $ImageBuild
    $sysBuild = Get-DismBuild $sys
    if ($sysBuild -eq 0 -or (Get-BaseBuild $sysBuild) -ge $need) { return $sys }      # 0 = version unreadable: keep it
    $adk = Find-AdkDism
    if ($adk -and (Get-BaseBuild (Get-DismBuild $adk)) -ge $need) { return $adk }
    if (-not $Install) { return $sys }
    Write-Warn "This PC's DISM (build $sysBuild) is older than the image (build $ImageBuild). Windows supports servicing an image only with the same or a newer DISM - the Windows ADK Deployment Tools have one."
    if (Read-YesNo "Install the Windows ADK Deployment Tools from Microsoft now (a few minutes)? They are used for this image only; this PC's DISM is not changed." $true) {
        Install-AdkDeploymentTools
        $adk = Find-AdkDism
        if ($adk -and (Get-BaseBuild (Get-DismBuild $adk)) -ge $need) { return $adk }
        Write-Warn "The ADK's DISM is not new enough for this image either - this PC's DISM is used, which can fail."
    } else {
        Write-Warn "Continuing with this PC's DISM - it can fail on this image."
    }
    return $sys
}
#endregion

#region ---------------------------------------------------------------- [1] Analyze
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
    if ($Script:Cfg.WinVersion -and [string]$Script:Cfg.WinVersion -ne $fam.Os) {
        Write-Info "This ISO is Windows $($fam.Os) - the Windows version on page 1 is switched to it."
    }
    if (-not $fam.Supported) {
        Write-Warn "$($fam.Name) is not supported for automatic updates (supported: Windows 10 1607/LTSB 2016, 1809/LTSC 2019, 2004-22H2/LTSC 2021; Windows 11 21H2, 22H2/23H2, 24H2/LTSC 2024, 25H2)."
        Write-Info 'You can still inject drivers / autounattend.xml and rebuild the ISO.'
    } elseif ($fam.Os -eq '10' -and $fam.Cap) {
        Write-Info "Update target: newest updates up to $($Script:Cfg.Win10Cutoff). Microsoft blocks offline integration of the"
        Write-Info 'Windows 10 ESU-era updates (Nov 2025+); enrolled PCs get those from Windows Update after setup.'
    } elseif ($fam.Cap) {
        Write-Info "Update target: the last updates for $($fam.Name) ($($fam.Cap) - it is out of servicing)."
    } else {
        Write-Info 'Update target: newest updates available in the catalog.'
    }
    if ($fam.NeedsEkb) { Write-Info "The $($fam.EkbFor) enablement package ($($fam.EkbKB)) will be added to bring this build to $($fam.EkbFor)." }
    if ($fam.Os -eq '11') {
        $dism = Get-ServicingDism $fam.Build
        if ((Get-BaseBuild (Get-DismBuild $dism)) -lt (Get-BaseBuild $fam.Build)) {
            Write-Info "This PC's DISM is older than Windows 11 $($fam.VerToken) - the slipstream offers to install the Windows ADK Deployment Tools, whose DISM can service it."
        }
    }
}
#endregion

#region ---------------------------------------------------------------- [3] Download
# The standalone servicing stack lookup walks back up to 36 months of the catalog, one search per month,
# and mostly finds nothing - it runs as a side job while the other updates are looked up and downloaded.
function Find-UpdateJob($Ctx) {
    Set-SideLabel 'servicing stack lookup'
    return (Find-Update $Ctx.Kind $Ctx.Fam $Ctx.MaxMonth $Ctx.Lookback)
}
function Invoke-Download([switch]$Auto) {
    Assert-Analyzed
    $f = $Script:S.Family
    Write-Title "Download updates - $($f.Name) $($f.Arch)"
    if (-not $f.Supported) { throw "$($f.Name) is not supported for automatic updates." }

    $max = (Get-Date).ToString('yyyy-MM')
    $win10 = (Get-FamilyOs $f) -eq '10'
    $cap = if ($win10 -and $f.Build -ge 19041 -and $f.Build -le 19045) { [string]$Script:Cfg.Win10Cutoff } elseif ($f.Cap) { [string]$f.Cap } else { '' }
    if ($cap -and [string]::CompareOrdinal($cap, $max) -lt 0) {
        $max = $cap
        if ($win10) { Write-Warn "Capped at $max (Windows 10 ESU cutoff - change it on the Windows updates page if you want to experiment)." }
        else { Write-Info "Up to $max - the last updates for $($f.Name), which is out of servicing." }
    }
    $found = @()

    Write-Step 'Latest cumulative update (LCU)'
    $lcu = Find-Update 'LCU' $f $max 24
    if (-not $lcu) { throw "No cumulative update found for $($f.Product) $($f.ArchTitle)." }
    Write-Ok $lcu.Title
    $found += , @('LCU', $lcu)
    $month = $lcu.Title.Substring(0, 7)

    Write-Step 'Standalone servicing stack update (only published when needed)'
    $ssuJob = $null
    if ($f.NoSsu) { Write-Info "None needed - $($f.Name) cumulative updates include the servicing stack." }
    elseif ($Auto) {
        $ssuJob = Start-SideJob @{ Name = 'Servicing stack lookup'; Command = 'Find-UpdateJob'; Tag = 'ssu'; Scratch = 'scratch-ssu'; DismMatch = '' } @{ Kind = 'SSU'; Fam = $f; MaxMonth = $month; Lookback = 36 }
    }
    if ($ssuJob) { Write-Info 'Looked up in the background (up to 36 months of the catalog) while the other updates are found and downloaded.' }
    elseif (-not $f.NoSsu) {
        $ssu = Find-Update 'SSU' $f $month 36
        if ($ssu) { Write-Ok $ssu.Title; $found += , @('SSU', $ssu) } else { Write-Info 'None needed - the LCU carries the servicing stack.' }
    }

    try {
        Write-Step 'Safe OS Dynamic Update (WinRE)'
        $safe = Find-Update 'SAFEOS' $f $month 12
        if ($safe) { Write-Ok $safe.Title; $found += , @('SAFEOS', $safe) } else { Write-Warn 'Not found - WinRE gets the servicing stack only.' }

        Write-Step 'Setup Dynamic Update (setup binaries on the media)'
        $setup = Find-Update 'SETUP' $f $month 12
        if ($setup) { Write-Ok $setup.Title; $found += , @('SETUP', $setup) } else { Write-Warn 'Not found - skipping.' }

        if ($f.NeedsEkb) {
            Write-Step "$($f.EkbFor) enablement package"
            $ekb = Find-ByKB $f.EkbKB $f $f.EkbFor
            if ($ekb) { Write-Ok $ekb.Title; $found += , @('EKB', $ekb) } else { Write-Warn "$($f.EkbKB) not found - the image keeps its current version number." }
        }

        if ($Script:Cfg.NetFx481 -and $win10 -and $f.Build -ge 19041 -and $f.Build -le 19045) {
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
        if ($ssuJob) { Write-Host '   SSU     (still being looked up in the background)' }
        if (-not $Auto -and -not (Read-YesNo 'Download them now?' $true)) { return }

        $records = @()
        $Script:SavedFiles = @{}
        foreach ($x in $found) {
            Write-Step "$($x[0]) $($x[1].KB)"
            $records += Save-UpdateFiles $x[1] $x[0]
        }
        if ($ssuJob) {
            Write-Step 'Standalone servicing stack update'
            $j = $ssuJob; $ssuJob = $null
            $ssu = Wait-SideJob $j
            if ($ssu) {
                Write-Ok $ssu.Title
                Write-Step "SSU $($ssu.KB)"
                $records += Save-UpdateFiles $ssu 'SSU'
            } else { Write-Info 'None needed - the LCU carries the servicing stack.' }
        }
    } catch {
        if ($ssuJob) { Stop-SideJob $ssuJob }
        throw
    }
    $Script:S.Updates = $records
    Save-State
    Write-Ok "All packages are in $($Script:P.Updates)"
}
#endregion

#region ---------------------------------------------------------------- is the ISO an original from Microsoft? (SHA-256)
# Microsoft lists the SHA-256 of every ISO on its download pages ("Verify your download"). An ISO is original when
# its SHA-256 is one of them: the values in Get-KnownIsoHashes (built from src/iso-hashes.json, which keeps the ISOs
# Microsoft no longer lists) or, when it is not there, on the pages themselves. No other source is trusted.
# The result is kept in the state (IsoCheck) with the file's size and date, so an ISO is read only once.
$Script:IsoHashUA = 'Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0'   # the Windows 10 page lists the ISOs only for browsers that are not on Windows
function Get-IsoHashPages {
    return @(
        @{ Name = 'Windows 11'; Arch = 'x64';   Url = 'https://www.microsoft.com/en-us/software-download/windows11' }
        @{ Name = 'Windows 11'; Arch = 'Arm64'; Url = 'https://www.microsoft.com/en-us/software-download/windows11arm64' }
        @{ Name = 'Windows 10'; Arch = '';      Url = 'https://www.microsoft.com/en-us/software-download/windows10ISO' }
    )
}
# The "Verify your download" table of one page -> Sha256 / Product / Label ("English 64-bit").
function Read-IsoHashPage([string]$Html, $Page) {
    $prod = [string]$Page.Name
    $v = [regex]::Match([string]$Html, 'Version (\d{2}H\d)')
    if ($v.Success) { $prod += ' ' + $v.Groups[1].Value }
    if ($Page.Arch -eq 'Arm64') { $prod += ' Arm64' }
    $rows = [regex]::Matches([string]$Html, '<tr>\s*<td>([^<]+)</td>\s*<td>\s*([0-9A-Fa-f]{64})\s*</td>\s*</tr>', 'IgnoreCase')
    return @(foreach ($r in $rows) {
        [pscustomobject]@{
            Sha256 = $r.Groups[2].Value.ToUpperInvariant(); Product = $prod; Listed = ''
            Label  = ([regex]::Replace([Net.WebUtility]::HtmlDecode($r.Groups[1].Value), '\s+', ' ')).Trim()
        }
    })
}
# The tables on microsoft.com now. Read = pages read, Failed = pages that could not be read (offline, blocked, changed).
function Get-MicrosoftIsoHashes {
    $out = @(); $read = 0; $failed = @()
    foreach ($pg in Get-IsoHashPages) {
        try {
            $html = (Invoke-WebRequest -Uri $pg.Url -UseBasicParsing -UserAgent $Script:IsoHashUA -TimeoutSec 45 -Headers @{ 'Accept-Language' = 'en-US,en;q=0.9' }).Content
            $rows = @(Read-IsoHashPage $html $pg)
            if ($rows.Count -eq 0) { $failed += "$($pg.Url) (no SHA-256 table on the page)"; continue }
            $out += $rows; $read++
        } catch { $failed += "$($pg.Url) ($($_.Exception.Message))" }
    }
    return @{ Hashes = $out; Read = $read; Failed = $failed }
}
# The list in this file (src/iso-hashes.json at build time): Sha256 / Product / Label / Listed (first day Microsoft showed it).
function Get-KnownIsoHashList {
    if (-not (Get-Command Get-KnownIsoHashes -ErrorAction SilentlyContinue)) { return @() }
    return @(foreach ($l in ((Get-KnownIsoHashes) -split "`r?`n")) {
        $f = $l -split "`t"
        if ($f.Count -lt 4 -or $f[0] -notmatch '^[0-9A-F]{64}$') { continue }
        [pscustomobject]@{ Sha256 = $f[0]; Product = [Net.WebUtility]::HtmlDecode($f[1]); Label = [Net.WebUtility]::HtmlDecode($f[2]); Listed = $f[3] }
    })
}
function Get-FileSha256([string]$Path) {
    $alg = $null
    try { $alg = New-Object Security.Cryptography.SHA256Cng } catch { $alg = [Security.Cryptography.SHA256]::Create() }
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 1MB, [IO.FileOptions]::SequentialScan)
    try {
        $len = $fs.Length; $buf = New-Object byte[] (4MB); $done = 0L; $last = -1
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$alg.TransformBlock($buf, 0, $n, $null, 0)
            $done += $n
            if ($Script:Sync -and $len -gt 0) {
                $p = [math]::Floor(1000.0 * $done / $len) / 10
                if ($p -ne $last) { $Script:Sync.Pct = $p; $last = $p }
            }
        }
        [void]$alg.TransformFinalBlock($buf, 0, 0)
        return ([BitConverter]::ToString($alg.Hash) -replace '-', '')
    } finally { $fs.Dispose(); $alg.Dispose() }
}
# File names of the Visual Studio subscription / Volume Licensing downloads (en-us_windows_10_..._dvd_1a2b3c4d.iso,
# SW_DVD9_Win_Pro_10_22H2...ISO): those ISOs are original too, but Microsoft lists their SHA-256 only on that portal.
function Test-SubscriptionIsoName([string]$Name) {
    return ($Name -match '^[a-z]{2}(-[a-z]{2,4})?_windows_(10|11|server)_.*_dvd_[0-9a-f]{8}\.iso$' -or $Name -match '^SW_DVD\d')
}
function Get-IsoFileKey($File) {
    return '{0}|{1}|{2}' -f $File.FullName.ToLowerInvariant(), $File.Length, $File.LastWriteTimeUtc.Ticks
}
# The files of the setup media that carry Microsoft's own (embedded) signature: setup and the boot managers.
# An ISO the Media Creation Tool made on the PC can't be in Microsoft's SHA-256 list, but these files in it are
# Microsoft's. They don't cover the Windows image (install.esd / install.wim), which isn't signed as a whole.
$Script:IsoSignedFiles = @('setup.exe', 'sources\setup.exe', 'sources\setupprep.exe', 'sources\setuphost.exe', 'bootmgr.efi',
                           'efi\boot\bootx64.efi', 'efi\boot\bootaa64.efi', 'efi\boot\bootia32.efi', 'efi\microsoft\boot\cdboot.efi')
# Checked / Bad (file and why) / Esd: install.esd, the Windows image of an ISO built from Microsoft's download
# files (the Media Creation Tool) - the ISOs Microsoft offers for download have install.wim.
function Test-IsoFolderSignatures([string]$Root) {
    $checked = @(); $bad = @()
    foreach ($rel in $Script:IsoSignedFiles) {
        $p = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $sig = Get-AuthenticodeSignature -LiteralPath $p
        $st = [string]$sig.Status
        if ($st -eq 'NotSupportedFileFormat') { Add-Log "ISO check: $rel - signature can't be read on this Windows"; continue }
        $subj = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
        $checked += $rel
        if ($st -ne 'Valid') { $bad += "$rel ($st)" }
        elseif ($subj -notmatch 'O=Microsoft Corporation') { $bad += "$rel (signed by $($subj -replace '^CN=([^,]+).*$', '$1'))" }
    }
    if (-not (@($checked) -match '^(sources\\)?setup\.exe$') -and -not (@($bad) -match '^(sources\\)?setup\.exe ')) { $bad += 'setup.exe (missing)' }
    if (-not (@($checked) -match '\.efi$') -and -not (@($bad) -match '\.efi ')) { $bad += 'efi\boot\boot*.efi (missing)' }
    return [pscustomobject]@{ Checked = @($checked); Bad = @($bad); Esd = (Test-Path -LiteralPath (Join-Path $Root 'sources\install.esd') -PathType Leaf) }
}
# Runs $Do with the root of the mounted ISO ("E:\"); an ISO that was already mounted stays mounted.
function Invoke-WithMountedIso([string]$Iso, [scriptblock]$Do) {
    $img = Get-DiskImage -ImagePath $Iso
    $was = [bool]$img.Attached
    if (-not $was) { $img = Mount-DiskImage -ImagePath $Iso -PassThru; Start-Sleep -Seconds 2 }
    try {
        $vol = $img | Get-Volume
        if (-not $vol.DriveLetter) { throw 'The ISO mounted without a drive letter (auto-mount disabled?).' }
        return (& $Do "$($vol.DriveLetter):\")
    } finally {
        if (-not $was) { Dismount-DiskImage -ImagePath $Iso | Out-Null }
    }
}
# Checks $Iso; the result is in $Script:S.IsoCheck. Status:
#   original - its SHA-256 is one Microsoft lists
#   mct      - not listed, built from Microsoft's download files (install.esd, the Media Creation Tool) and its
#              setup and boot files are signed by Microsoft
#   badsig   - not listed, and setup or boot files are not signed by Microsoft (or are missing): modified
#   unknown  - not listed; its signatures are in SigChecked / SigBad when the ISO could be opened (SigDone)
# Online: $true (pages read), $false (not reachable - only the list in this file was used), $null (not needed).
function Test-IsoOriginal([string]$Iso) {
    $f = Get-Item -LiteralPath $Iso -ErrorAction Stop
    $key = Get-IsoFileKey $f
    $prev = $Script:S.IsoCheck
    $same = $prev -and [string]$prev.Key -eq $key
    if ($same -and [string]$prev.Status -in 'original', 'mct', 'badsig') {
        Write-IsoCheckResult $prev
        return $prev
    }
    Write-Step "SHA-256 of $($f.Name) ($(Format-Size $f.Length))"
    if ($same -and [string]$prev.Sha256 -match '^[0-9A-F]{64}$') { $sha = [string]$prev.Sha256; Write-Info 'Already computed - looking it up again.' }
    else {
        Write-Host 'Reading the ISO to compute its SHA-256' -NoNewline
        $t0 = Get-Date
        $sha = Get-FileSha256 $f.FullName
        if ($Script:Sync) { $Script:Sync.Pct = -1 }
        Write-Info ('{0}  ({1:mm\:ss})' -f $sha, ((Get-Date) - $t0))
    }
    $r = [ordered]@{ Key = $key; Path = $f.FullName; Name = $f.Name; Size = $f.Length; Sha256 = $sha; Status = 'unknown'
                     Product = ''; Label = ''; Source = ''; Listed = ''; Online = $null; When = (Get-Date).ToString('yyyy-MM-dd HH:mm', $Script:Inv)
                     Subscription = (Test-SubscriptionIsoName $f.Name); SigDone = $false; SigChecked = @(); SigBad = @(); Esd = $false }
    $hit = @(Get-KnownIsoHashList | Where-Object { $_.Sha256 -eq $sha }) | Select-Object -First 1
    if ($hit) { $r.Source = 'list' }
    else {
        Write-Host 'Reading the SHA-256 lists on microsoft.com' -NoNewline
        $ms = Get-MicrosoftIsoHashes
        foreach ($e in @($ms.Failed)) { Add-Log "ISO check: could not read $e" }
        $r.Online = ($ms.Read -gt 0)
        $hit = @($ms.Hashes | Where-Object { $_.Sha256 -eq $sha }) | Select-Object -First 1
        if ($hit) { $r.Source = 'microsoft.com' }
    }
    if ($hit) {
        $r.Status = 'original'; $r.Product = $hit.Product; $r.Label = $hit.Label; $r.Listed = $hit.Listed
    } else {
        if ($same -and $prev.SigDone) { $r.SigDone = $true; $r.SigChecked = @($prev.SigChecked | Where-Object { $_ }); $r.SigBad = @($prev.SigBad | Where-Object { $_ }); $r.Esd = [bool]$prev.Esd }
        else {
            Write-Host 'Checking the Microsoft signatures of the setup and boot files in the ISO' -NoNewline
            try {
                $sig = Invoke-WithMountedIso $f.FullName { param($Root) Test-IsoFolderSignatures $Root }
                $r.SigDone = $true; $r.SigChecked = @($sig.Checked); $r.SigBad = @($sig.Bad); $r.Esd = [bool]$sig.Esd
            } catch { Write-Warn "The ISO could not be opened to check the signatures of its files: $($_.Exception.Message)" }
        }
        if ($r.SigDone -and @($r.SigBad).Count) { $r.Status = 'badsig' }
        elseif ($r.SigDone -and $r.Esd -and -not $r.Subscription) { $r.Status = 'mct' }
    }
    Write-IsoCheckResult $r
    $Script:S.IsoCheck = $r
    Save-State
    return $r
}
function Write-IsoCheckResult($R) {
    $ok = @($R.SigChecked | Where-Object { $_ }); $bad = @($R.SigBad | Where-Object { $_ })      # a list read back from state.json may be $null
    $signed = if ($ok.Count) { 'Setup and boot files signed by Microsoft: ' + ($ok -join ', ') + '.' } else { '' }
    switch ([string]$R.Status) {
        'original' {
            $from = if ($R.Source -eq 'list') { "Microsoft's list as of $($R.Listed)" } else { 'microsoft.com' }
            Write-Ok "Original Microsoft ISO: $($R.Product) - $($R.Label) (SHA-256 found on $from)."
        }
        'mct' {
            Write-Info "$($R.Name) was made with the Media Creation Tool (its Windows image is install.esd): it is built on the PC, so its SHA-256 is never in Microsoft's list - nothing wrong."
            Write-Ok $signed
            Write-Info 'The Windows image itself (install.esd) is not signed as a whole, so it is not covered by this check.'
        }
        'badsig' {
            Write-Warn "Not signed by Microsoft: $($bad -join ', ')."
            Write-Warn "$($R.Name) has been modified - download an original Windows 10 or 11 ISO from microsoft.com."
        }
        default {
            Write-Warn "The SHA-256 of $($R.Name) is not one Microsoft lists for its Windows 10 and 11 ISOs."
            if ($R.Online -eq $false) { Write-Warn 'microsoft.com could not be reached, so only the list in this program was used - check again when online for the newest ISOs.' }
            if ($signed) { Write-Ok "$signed The Windows image itself is not covered by this check." }
            if ($R.Subscription) { Write-Info 'Its name is the one of a Visual Studio subscription / Volume Licensing download: compare the SHA-256 above with the one shown on that portal.' }
            Write-Info 'An older ISO Microsoft no longer offers may be missing from the list too. Otherwise it may be modified - download an original Windows 10 or 11 ISO from microsoft.com.'
        }
    }
}
#endregion

function Get-KnownIsoHashes {
    return @'
964F2D179FA13670285B8A2DB7F0CD72983E8BC5DF8554F547550486AD8AFEAB	Windows 10 22H2	Arabic 32-bit	2026-10-31
237FCBAA234166A836260DFA760F71F1211A6C573130C75D4CCDCA9D7D29F69A	Windows 10 22H2	Arabic 64-bit	2026-10-31
69E4B7ED9E5D7CEA72C075E63A493C867275608B8F9E9D1FE7D711459B32D1BE	Windows 10 22H2	Brazilian Portuguese 32-bit	2026-10-31
0CA714572FCB5B8CE480ACC3C93EAF2F34CC6507DF5F693CFF021BF4A32FAC68	Windows 10 22H2	Brazilian Portuguese 64-bit	2026-10-31
93C43C0F17AB17671EE16F321C0FA5E1506AAADAD0BD84A4207AD8692B78554E	Windows 10 22H2	Bulgarian 32-bit	2026-10-31
1DFC04F3EC68602B547961A5AFD3758164E0C36A6BF420C564B1B44B375E6070	Windows 10 22H2	Bulgarian 64-bit	2026-10-31
C828ACCB08886622F5E1A127BB83070BAE0E9235EF0E31573ABC6A8A5CB55286	Windows 10 22H2	Chinese Simplified 32-bit	2026-10-31
D485D370406CBCB68959718817BD12ED87E537A14C885F84962E07136FC4A049	Windows 10 22H2	Chinese Simplified 64-bit	2026-10-31
62E61916A5BC6F6B7EB75D132583C4131AB81E4A19038DE527918324585720EE	Windows 10 22H2	Chinese Traditional 32-bit	2026-10-31
C9594113B52F96783FB6CA8248EBBC972277E26FB215C302BFCCE50DF6C21A79	Windows 10 22H2	Chinese Traditional 64-bit	2026-10-31
5451422072BF6A231F2CA8CA865B89077EB2E5084DDFAFAD6B1F7949732B25B8	Windows 10 22H2	Croatian 32-bit	2026-10-31
140462535A28CD006CD97055DABB086F8511F52BEFEECDF8BCB5ADEB64CED3AB	Windows 10 22H2	Croatian 64-bit	2026-10-31
AF1A11BEA0BA0EC789C546EE0BA0740489065CBBC0B329CC4B00B9214C23E42B	Windows 10 22H2	Czech 32-bit	2026-10-31
AD5EAAD75971D22C84F433854FE9671EFC360E9EB501F3B2E94A72E74C78F6FE	Windows 10 22H2	Czech 64-bit	2026-10-31
A2F4C905A75B87372BEC9DA81EDC521EBA16FA0832C269FE7F71B5DA34FE6EFF	Windows 10 22H2	Danish 32-bit	2026-10-31
74CF090D3F881F1EFCD597E01DC3FA4C6BFC2F5D3CD141CF68C92034E0BA6A57	Windows 10 22H2	Danish 64-bit	2026-10-31
AC09A473E97864F6DD4E0AF4038BECF7A43FEF790F9AF9802CEF5530DFB69BCE	Windows 10 22H2	Dutch 32-bit	2026-10-31
51B2F525CF7426FEFD1EF0813C4C07E7D772C61C712E20C879D8ED568D2ABCC9	Windows 10 22H2	Dutch 64-bit	2026-10-31
AC0B7045B6C3A72A4D46DAAB0944E109A55D9EDE3A11B775FDB57C2DD3FCA2EF	Windows 10 22H2	English 32-bit	2026-10-31
A6F470CA6D331EB353B815C043E327A347F594F37FF525F17764738FE812852E	Windows 10 22H2	English 64-bit	2026-10-31
38D093AE08BF80302B900BC91A2CE5205C5086DDEEFAB29E8D529D5607B6B4DB	Windows 10 22H2	English International 32-bit	2026-10-31
EDC53C5C5FE6926DEA23FC3E884FBCF78CC2B9E76364BE968F806FC6D42B59D2	Windows 10 22H2	English International 64-bit	2026-10-31
6B59D1F6C02C5215384E5BD1D16B2591710D9F6C430F8C4C1F554973672458F1	Windows 10 22H2	Estonian 32-bit	2026-10-31
AF649CE2920C4AFF96EF954C1B598C6DEE3E705EDC074565DDDCE3294D29F859	Windows 10 22H2	Estonian 64-bit	2026-10-31
64F6427BB981BBADC0731AA686D62F157174A638EE9F2E10DF582753085B4E12	Windows 10 22H2	Finnish 32-bit	2026-10-31
C17F3CFA9EC971DCD64B4A1152A7B563ADE165FB9DEB941F7C791E0F722D2D2F	Windows 10 22H2	Finnish 64-bit	2026-10-31
F3E3C0EF680B4C0E03A4E7601A4B00F1EA13B8EED501F16B3E0610014E788AB9	Windows 10 22H2	French 32-bit	2026-10-31
7B7F99E804B50F5E738FFDFC571803CCDCFE139599392496048FD32C5EAEDFF9	Windows 10 22H2	French 64-bit	2026-10-31
E6E6A19346298D95FBC3D472AF5784755C6F510233B56FE330AD4C7AC3D2F957	Windows 10 22H2	French Canadian 32-bit	2026-10-31
B8C09E172DBDE8E3DB14E110857AE8724D9BDB73F5B4D37D75929FF394B5CC6B	Windows 10 22H2	French Canadian 64-bit	2026-10-31
B0BFC1B9B176DF0303ED3A91E7332CD1A8B57B07F25752CEC9493E1333F88075	Windows 10 22H2	German 32-bit	2026-10-31
D1A41A09E9AE09631A087EDF95D7F4EECAB622F88B3C824D856CFEA47FCC0B4C	Windows 10 22H2	German 64-bit	2026-10-31
E7F77D3D5D81D4BF7C1EDA65ED2B163DF20265D667577C859F10765E750921F2	Windows 10 22H2	Greek 32-bit	2026-10-31
EE069CD752B140EFC9AF0A413313C637E13CCCB69225ED9FEDCCEB634B905EC7	Windows 10 22H2	Greek 64-bit	2026-10-31
6E6FBC9A161BBAA41978466000F30ED363D536F86A337259E0B67A7A55539A3C	Windows 10 22H2	Hebrew 32-bit	2026-10-31
15CBC5E2CFCE6987892A4466C55F079B77A6EAA862A519F701B3F68661299979	Windows 10 22H2	Hebrew 64-bit	2026-10-31
F9AC230B1F3908F1883D257EF68E450FE47FE87D59FE84B57AE0EBFBEF3BEFB9	Windows 10 22H2	Hungarian 32-bit	2026-10-31
DF28F3E76FA2A8D7B05531D2F1E697B877ADEFEB1311A4FCB62692D48235830B	Windows 10 22H2	Hungarian 64-bit	2026-10-31
DC902370B6C81CF7B48D381E1CE377187668358BE821504FDBF8FFAC3763DD09	Windows 10 22H2	Italian 32-bit	2026-10-31
99D0376562919567F0BDDDCD43721CCA6B2834FC4EF93E0DB9F05ED26AB1A3DE	Windows 10 22H2	Italian 64-bit	2026-10-31
1570135083774BB43DB979261312803DAE5112FF94515FC6C35CAD7274518945	Windows 10 22H2	Japanese 32-bit	2026-10-31
4949E32D1B96C66C79BB8F2227624E74B5DBDA485CA0D4F8A32852F51E67AEA8	Windows 10 22H2	Japanese 64-bit	2026-10-31
2ECA27FE084B53E7AF674688DCCB8AC5FA4D31DD0B97F372BFEDB75D16B0EE82	Windows 10 22H2	Korean 32-bit	2026-10-31
C1F5310B1DF11A1B80B6656DFB9A22A3A2D0D427E87F6BF62933C4E0C9584B4F	Windows 10 22H2	Korean 64-bit	2026-10-31
2CE48FF1506AFDD27F6850C91B7ABF39833D7C6F69F79690A1D6DD7F919E11B2	Windows 10 22H2	Latvian 32-bit	2026-10-31
6CD568D60EF842C485C38E06D9D2162977AE9A699FA0C09CEC0C0733F30E295C	Windows 10 22H2	Latvian 64-bit	2026-10-31
3D7B3BB75C50A58D8DEAAB5E057B38DF006732ED57E5C680144B95E172313595	Windows 10 22H2	Lithuanian 32-bit	2026-10-31
AD62769CAA6C13646E0C6529042FD8C0A53A1A2E71F371079749210261166C5F	Windows 10 22H2	Lithuanian 64-bit	2026-10-31
B49A74D5202B1B21094CE7101ABE505FA9C0F8B15605F85EC517B39B1B6175D8	Windows 10 22H2	Norwegian 32-bit	2026-10-31
3C0865B12E9B81E6D138F8CA46F91BCD810CA3583D75F3458237AF65D93D7609	Windows 10 22H2	Norwegian 64-bit	2026-10-31
78E404ED9EC4BEAFE1161ADDBEC70899547483E592DE609CB6FC64DEA5A004F7	Windows 10 22H2	Polish 32-bit	2026-10-31
96AAD9E4B20B6E3F5FEA40B981263E854F6C879472369D5CE8324AAE1F6B7556	Windows 10 22H2	Polish 64-bit	2026-10-31
F889BCE09E2117F32679D41DBD4F4CE7178A5ACC96057928A2836BBB6D7C4FB6	Windows 10 22H2	Portuguese 32-bit	2026-10-31
83F83B5A9101F5FA21DE4E925ABC7693478D84CD5FBF02CB019393048B5BDBBB	Windows 10 22H2	Portuguese 64-bit	2026-10-31
E3EBB528AFDD8C946FC5AA4D19B5AAA0CAE6AECB5C6F53A45334A3999E5550FA	Windows 10 22H2	Romanian 32-bit	2026-10-31
E7D3C523D17468E83D100E5D40C9334ACB49469DB6C2685267F03AE72E2D2544	Windows 10 22H2	Romanian 64-bit	2026-10-31
7B339135C62CB06C8EB8748922659FC36FBE1DB08C2749B036C00676455A5D00	Windows 10 22H2	Russian 32-bit	2026-10-31
2A7C440C984EB018F513901E8ED96405213D237938C410C5089C0FAC7BA01898	Windows 10 22H2	Russian 64-bit	2026-10-31
55B5CB316402BA4A2EE77F3E9FCC5A256F809C79B6BEBF0310014365C3C60DF9	Windows 10 22H2	Serbian Latin 32-bit	2026-10-31
2A23BE419AB5B2D52E2A69CC3AE39973C565363E81CAD875DD23D8A81E4AC35A	Windows 10 22H2	Serbian Latin 64-bit	2026-10-31
8950648926476B04367A08F53233664AC325CA6632BEB8DED727BA8638818D52	Windows 10 22H2	Slovak 32-bit	2026-10-31
68CBE54D09FB3BC3C5C3BF93AB912F3225FF036D2FD2F9E0513D418955521329	Windows 10 22H2	Slovak 64-bit	2026-10-31
634B23B37068119A974F6E6155EC663974048A51D0A440B2E6FB8F84E4EEE8E5	Windows 10 22H2	Slovenian 32-bit	2026-10-31
5B44E6EC11915ABEF9EC63756001CEED815216A2E8D0E2A8F8F24C54FB819B20	Windows 10 22H2	Slovenian 64-bit	2026-10-31
C91F1C1EE9CCD88215CE9AD3EF4303997C78715C5A84C8A4D8C9F67D307A3633	Windows 10 22H2	Spanish (Mexico) 32-bit	2026-10-31
BF02C401644A4A9249EE206FAA9FD1691F4EC18BB37A9EA4FFE5C010DC147492	Windows 10 22H2	Spanish (Mexico) 64-bit	2026-10-31
DB414636D7EC65B1AEFCC1242D323E839823DB21FD25A2A9C5DCECC3C16C3309	Windows 10 22H2	Spanish 32-bit	2026-10-31
0D48C6F236CA9F966ECCD84D9BE01B038516567AABF1C46DCBEE785556B19813	Windows 10 22H2	Spanish 64-bit	2026-10-31
9B1788454A42E1CA2196E2633DCD7C0BD3F94A9F8D29C60EB064CFA8A966EBD3	Windows 10 22H2	Swedish 32-bit	2026-10-31
72A5EB42D5824FEE11B1708AED2526B2C3A73A6EC5E0D9C7CDD9552CB3C25BCA	Windows 10 22H2	Swedish 64-bit	2026-10-31
84D93E48EA10AB2D766F17DA242379146F8395BDCA7F860755B27AF7DBD0F6C3	Windows 10 22H2	Thai 32-bit	2026-10-31
D823AA445C4B575775918301948A44B7666FC1044CC9BB53B2EE981E9A01FD15	Windows 10 22H2	Thai 64-bit	2026-10-31
57B51F3F9F36DD2A1586745751218D16ABACD8703A60FF9368C32CCA3CF0C5E9	Windows 10 22H2	Turkish 32-bit	2026-10-31
F66AD547FB42F9D37DC8E86214E1E326E515AA20843F734C7F8F947E967BEE53	Windows 10 22H2	Turkish 64-bit	2026-10-31
CEF1AAA637AC8F0E563244DEA7EFBDCF6C85288B131943DABD108182D9B0656C	Windows 10 22H2	Ukrainian 32-bit	2026-10-31
2AE3B2DCCF609DC3C149FF344AB73B4E8E0B12BF7C97489B64DFC7A162A7C7D9	Windows 10 22H2	Ukrainian 64-bit	2026-10-31
A75AE3F36CB9FFFFEDCB2D7DED9CEF83FFB710EB1376610D2220684D987CB9A5	Windows 11 26H2	Arabic 64-bit	2026-10-31
D9AC87C1E9E47E0EB34EED443E5691C31781074E67608A51AEE50D7C7039F684	Windows 11 26H2	Brazilian Portuguese 64-bit	2026-10-31
FE219A43A408534FB79B170925E750289DE0D80CA52D297B0977DCF5E71B6D87	Windows 11 26H2	Bulgarian 64-bit	2026-10-31
B795B52D598BF8FDEA5975844731F4A50C5713876CEFC513884354272B023AF0	Windows 11 26H2	Chinese Simplified 64-bit	2026-10-31
E951AB4EAD95D45E00CDFF6C9C05836F9499D3FD2FDEEAE0E709549F12F9B5DC	Windows 11 26H2	Chinese Traditional 64-bit	2026-10-31
3874FB17B092E6470D5B5F0175BBB69B228619ABA5DA1612905F6960A2F9EAF6	Windows 11 26H2	Croatian 64-bit	2026-10-31
9C616600B6845DBD24EB705E35D0EEC4311D0F6A88A35CB2B134FA487244796A	Windows 11 26H2	Czech 64-bit	2026-10-31
C03816ABF43F868381C3AAF9940E8FB33CB54D244A88E182BFBD1F887F1D74C9	Windows 11 26H2	Danish 64-bit	2026-10-31
34B3FD033F10560F48366940768AEA5AD5198407BEC3E2EEB9BD730A80D39F26	Windows 11 26H2	Dutch 64-bit	2026-10-31
BD4307DF32BC8AF33B39CCECB1174AEB345386630F89A2B86C7A4E36B55EA650	Windows 11 26H2	English 64-bit	2026-10-31
7E3F373BD3C2321B5D5125DFCF718DFBF1A0ABC50A267118669951890DF98A5D	Windows 11 26H2	English International 64-bit	2026-10-31
2CD0558801F831D0315897BA5C989B9A8192BC975F4E8D5F0C4E51EA0817196B	Windows 11 26H2	Estonian 64-bit	2026-10-31
32B9D11B13E1A200ED7C08D2E495C4B57C6B38150C8DFC679C5E80BC7A5F8767	Windows 11 26H2	Finnish 64-bit	2026-10-31
AA515279F02FB2B425EFF341F0A1F158D61288C72CCA5F9D87B79B5A23F7F918	Windows 11 26H2	French 64-bit	2026-10-31
F32E5538EE3F73206294378109501C9E2E2DA78DCDE66C43F4610B18CEEBC0A7	Windows 11 26H2	French Canadian 64-bit	2026-10-31
193BBDE65EC84E298A1C798959489C8375ED501CF973C6D37FA52BB22EE8D43B	Windows 11 26H2	German 64-bit	2026-10-31
40BE4F83598455D8606D442B740AA2942740BC9F6104ADC5D7320651D61DCBC0	Windows 11 26H2	Greek 64-bit	2026-10-31
6458F3C2458790E0D78436574894F39B455924E83937E7C166D656730C441D29	Windows 11 26H2	Hebrew 64-bit	2026-10-31
614ACD776E654B26255F0CFCFAC509217E6F98B6FE949FA478AB5514A7697B5F	Windows 11 26H2	Hungarian 64-bit	2026-10-31
4A155CFF6748F433B017761FF0B5B6029878EC6EF267674418D65E0FED7D0520	Windows 11 26H2	Italian 64-bit	2026-10-31
923EC1A2EC46CCBE607FC81BEAF9753BFBB6FC62220B7B8BFFD56E66F6DE3A0C	Windows 11 26H2	Japanese 64-bit	2026-10-31
EC4C80AA16C1910562EA8EEA82B86CCF2012375E0492B180178BB605DE308292	Windows 11 26H2	Korean 64-bit	2026-10-31
91E8ED6BA3DBFAB3CBE9977C5484572759D57ECBE8B25B7A9E208A4F1594AB7E	Windows 11 26H2	Latvian 64-bit	2026-10-31
C66F9D4A83E334E528180534E13BE58CAC052E1621408B065BF242E2977A8769	Windows 11 26H2	Lithuanian 64-bit	2026-10-31
1802913B75B2CF54AB7CCC0A01426C6B5C94BA144A4777DBF37A67CEEB071B25	Windows 11 26H2	Norwegian 64-bit	2026-10-31
0EADDDD47A6D6D4524DF40CBD9B779C32DF222F7D2000DE2B82A000CA9C5470F	Windows 11 26H2	Polish 64-bit	2026-10-31
62C0C3B067C9ADAC99DDBD8A98EEF6C7A51D5FFCCC3D97BD02DACCF1D6DFEDB9	Windows 11 26H2	Portuguese 64-bit	2026-10-31
F29EB5D997A7822AD8E7D6AF2B9D23C9484AC86BDFD17F61CB287797CDA66B13	Windows 11 26H2	Romanian 64-bit	2026-10-31
3DD71E8F84BFDC0054E1C4383DB2EAC921D21952AC03B2231CB6E9610A2F7423	Windows 11 26H2	Russian 64-bit	2026-10-31
AA646F5C7E9D2B78208154F21A8EC2A18E7B72998B6F2C022B5FFBBB305EBFA5	Windows 11 26H2	Serbian Latin 64-bit	2026-10-31
ED796F19C1B2FC0912F4BC3BFE854425C760FB08946D4EE88BC1C3FAB1D1862B	Windows 11 26H2	Slovak 64-bit	2026-10-31
4702A4052A3E2ECFF5665F84E766EF4CB4A660C712427A8BA083B121840E6D6A	Windows 11 26H2	Slovenian 64-bit	2026-10-31
83231BCD4C509CFA51EB9A79056C6F1CA40DF09110267832E780A881B9EE8F9E	Windows 11 26H2	Spanish (Mexico) 64-bit	2026-10-31
9828703784880421E6602504DFD99064E4CB739CC9B20ABA22E3934372A14F9A	Windows 11 26H2	Spanish 64-bit	2026-10-31
D0E4704500012ACF3551B6C394503638D21C4F1E58B410E7F8FA5D8D61BF3B8B	Windows 11 26H2	Swedish 64-bit	2026-10-31
127DCC66ED7C1A797863FD3573EF5F2F17BDECB72425E74B7AA5186F50FADA4A	Windows 11 26H2	Thai 64-bit	2026-10-31
6BE8412702B2C56099A98FD8FD058FFB869DC54035FC54A3BDFCE99ABB631FAF	Windows 11 26H2	Turkish 64-bit	2026-10-31
2C2C6889E47273690842F8867539D204D3814820E235C520BF63A6140D7CEFE3	Windows 11 26H2	Ukrainian 64-bit	2026-10-31
92775CAD76E5B90B6BC0D2F7ADA982B5E399CBB59BFA797320872016927848DD	Windows 11 26H2 Arm64	Arabic 64-bit	2026-10-31
48EEC10EAFF055A62A1516CE83E103DFDBE72A4AAF12A221E99ECB29CAA3FB77	Windows 11 26H2 Arm64	Brazilian Portuguese 64-bit	2026-10-31
A56988DAE9BE80F1D5737E5F5066260110ED175B02F5ED849CA5BAA99321CC1B	Windows 11 26H2 Arm64	Bulgarian 64-bit	2026-10-31
CD573DF724862300895D0F5D0836E663756D22CC4E964C752EFDC05B4FC09E8B	Windows 11 26H2 Arm64	Chinese Simplified 64-bit	2026-10-31
C0486202732B8D91918FF83E014D52D936A37CAC65B80F5B34023AA188F25C6E	Windows 11 26H2 Arm64	Chinese Traditional 64-bit	2026-10-31
78B7388EA549C3440CC48C7C427CB1C118EC40408A914B6A98D4684C6DEE138E	Windows 11 26H2 Arm64	Croatian 64-bit	2026-10-31
A299C5B56A5FE93996F4C4EBD390338E00C1208E94F04F14085DC05FEC262F06	Windows 11 26H2 Arm64	Czech 64-bit	2026-10-31
0DF64FA738E25BEACDF844D9B74DAC7F67345F5003B23787F6AE87E3451BFBF1	Windows 11 26H2 Arm64	Danish 64-bit	2026-10-31
554267A82102284894E874625C6E8C5FDE0850C9A998D16DC25DB968B9B2D575	Windows 11 26H2 Arm64	Dutch 64-bit	2026-10-31
8992F2D2CFD2FA647E579E9EB31FC21F34DA8333C29B6170FDE17D2ED6623E9C	Windows 11 26H2 Arm64	English 64-bit	2026-10-31
500BCB6F272B7C455156470EA06816F558F13B885723F84EE9EAB7534C7DEE61	Windows 11 26H2 Arm64	English International 64-bit	2026-10-31
F2B835D2894AFE3160B53F2CFC58DAED95DAB80D677596F0A69544FBAE17DD05	Windows 11 26H2 Arm64	Estonian 64-bit	2026-10-31
0BF586CF3DE2D8ABDFC998B5A5270F3F5BC9586F7342AAB7B0E3D1C212AE730B	Windows 11 26H2 Arm64	Finnish 64-bit	2026-10-31
D086FB0BC1574188E8533A7422B55A3FE3BC39D0E48DA0E895DEC3F370E472DF	Windows 11 26H2 Arm64	French 64-bit	2026-10-31
595A083F8B63EFEC1FC2CD5E7875D88C1C7E71D7B34369C3BC359E8A7CE666BF	Windows 11 26H2 Arm64	French Canadian 64-bit	2026-10-31
10CB224A54AEE8022ED250DA75B00CC8E614B0336D975100A0F80DBBC38ECDC2	Windows 11 26H2 Arm64	German 64-bit	2026-10-31
390042887EE2FBE34AC831C64E71D9057EB82CD98F989AC585ECF719E7F27F1B	Windows 11 26H2 Arm64	Greek 64-bit	2026-10-31
BBF9F2284FE7559EA8BDF960851A80231EADA3AA7E740958948B79AB01D23478	Windows 11 26H2 Arm64	Hebrew 64-bit	2026-10-31
C511B047920A571E5D58D983E5EA3CC6811E20BB9CD6D255B73E85DA88FD5BAB	Windows 11 26H2 Arm64	Hungarian 64-bit	2026-10-31
DE651996AF788D7F55B8D11BFA45D5B20E22013687EA2C37F3325A8CD4D7C5E5	Windows 11 26H2 Arm64	Italian 64-bit	2026-10-31
8618E995C48FB6BB4D32C8CDF0E4B280473640736071C53943789F93A03BDD51	Windows 11 26H2 Arm64	Japanese 64-bit	2026-10-31
833E132E94335A7EECC2B3BB6BA9E16B199413504049CC19743752F402FB9CF7	Windows 11 26H2 Arm64	Korean 64-bit	2026-10-31
94ABA682D5D3A1CBA7F7A096A0E2A2B7A203513E75DD184AC4DAF3A36B36F273	Windows 11 26H2 Arm64	Latvian 64-bit	2026-10-31
635899EA6901E7C9CE1C42E629D2E6DAAFF71128ED9D03C63B7DC0999805D613	Windows 11 26H2 Arm64	Lithuanian 64-bit	2026-10-31
2C85AD913811599893B510A8278BD64CD6A0C1E1238582A57CC81FB28F7A76A3	Windows 11 26H2 Arm64	Norwegian 64-bit	2026-10-31
6D9B301E9009FE9191A75DC537CE7D648649C3F991511105A89822BC19AED933	Windows 11 26H2 Arm64	Polish 64-bit	2026-10-31
8F9E526B24BDB89C4EE6BB550D8E42FEE08FD9F657E4941A8F89FEA77CA9BE17	Windows 11 26H2 Arm64	Portuguese 64-bit	2026-10-31
DEBA3AA801C8EB6C6D354D124A62A4CE8F7C1E52D0C081FD132D0FA5E9017A0E	Windows 11 26H2 Arm64	Romanian 64-bit	2026-10-31
311879B09B0A990082BF4E47A1533BF994BC5379D9A41E4D386E5202DF2719A1	Windows 11 26H2 Arm64	Russian 64-bit	2026-10-31
E9994BBD05440CD2FA2DB846710119CF33A5AA2AFD4FF71834D22A52CAB5FFA6	Windows 11 26H2 Arm64	Serbian Latin 64-bit	2026-10-31
7FE3233A5162BD73F38FF378B824CA466A949354002D09FE47AA9AEE2AB67D10	Windows 11 26H2 Arm64	Slovak 64-bit	2026-10-31
2178F38D5571B706770C932399F8A6139B58EDB537872A0D9973CE7297A9EB6D	Windows 11 26H2 Arm64	Slovenian 64-bit	2026-10-31
23D5D42E8CD37FE1BACC37920EAA1AB0BB044AAE0D41EEEB6A77E82A8CA9A483	Windows 11 26H2 Arm64	Spanish (Mexico) 64-bit	2026-10-31
DBF606CEB4CE1390F9F21AD1D96331848BC6B701CBAB0012785881A1A1C0EC63	Windows 11 26H2 Arm64	Spanish 64-bit	2026-10-31
0D706BC138C9CD287C30D316FE9E623C5F700D085C430CB5329C8C4A1745E9BF	Windows 11 26H2 Arm64	Swedish 64-bit	2026-10-31
768E8CE3BC0A5FE1D8102063791F056D52D073D2C3F1A6D47C40C5DC9F5F6560	Windows 11 26H2 Arm64	Thai 64-bit	2026-10-31
13EEAB6C3DF650A8A219C2266F0768BA8583F8EEDE5D62EEBF2CAEE641CE747E	Windows 11 26H2 Arm64	Turkish 64-bit	2026-10-31
99B00684F0FFF80C64E305A5559D6BF30356B17303BD8E7FFB379CDE9E7D23E7	Windows 11 26H2 Arm64	Ukrainian 64-bit	2026-10-31
'@
}


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
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Dest -Recurse -Force
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
        $idx = 0
        if ($key -match '/IMAGE/INDEX' -and -not [int]::TryParse($val.Trim(), [ref]$idx)) {
            Write-Warn "autounattend.xml has an image INDEX that is not a number ('$val')."
        } elseif ($key -match '/IMAGE/INDEX' -and $idx -gt $img.Count) {
            Write-Warn "autounattend.xml installs image INDEX $val but the new install.wim has $($img.Count) edition(s)."
        } elseif ($key -match '/IMAGE/INDEX') {
            Write-Info "autounattend.xml picks index $val = $(($img | Where-Object { $_.ImageIndex -eq $idx }).ImageName)"
        } elseif ($key -match '/IMAGE/NAME' -and -not ($img | Where-Object { $_.ImageName -eq $val })) {
            Write-Warn "autounattend.xml installs '$val' but that edition is not in the new install.wim."
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

# ---- storage / network drivers for WinRE and boot.wim: one DISM call instead of one per driver
# Each driver folder is copied into one set (only its own INF kept), so /Recurse adds exactly
# those drivers. Very big folders (vendor packs) are added one INF at a time instead.
function New-BootDriverSet([string[]]$Infs, [string]$Dest) {
    $Infs = @($Infs | Where-Object { $_ })
    $set = [pscustomobject]@{ Folder = $null; Singles = @(); Count = $Infs.Count }
    if ($set.Count -eq 0) { return $set }
    Reset-Dir $Dest
    $n = 0
    foreach ($inf in $Infs) {
        $dir = Split-Path $inf -Parent
        $size = [double](Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($size -gt 300MB) { $set.Singles += $inf; continue }
        $n++
        $to = Join-Path $Dest ('{0:D3}' -f $n)
        New-Item -ItemType Directory -Force -Path $to | Out-Null
        Get-ChildItem -LiteralPath $dir -Force | Copy-Item -Destination $to -Recurse -Force
        $keep = Split-Path $inf -Leaf
        Get-ChildItem -LiteralPath $to -Recurse -File -Force | Where-Object { $_.Extension -ieq '.inf' -and -not ($_.DirectoryName -eq $to -and $_.Name -ieq $keep) } | Remove-Item -Force
    }
    if ($n -gt 0) { $set.Folder = $Dest }
    return $set
}
function Add-BootDrivers([string]$MountDir, $Set, [string]$Fu, [string]$Label) {
    if (-not $Set -or $Set.Count -eq 0) { return }
    Write-Sub "Storage/network drivers ($($Set.Count))"
    if ($Set.Folder) { Invoke-Dism "/Image:$(Q $MountDir) /Add-Driver /Driver:$(Q $Set.Folder) /Recurse$Fu" "$Label drivers" -Soft }
    foreach ($inf in @($Set.Singles)) { Invoke-Dism "/Image:$(Q $MountDir) /Add-Driver /Driver:$(Q $inf)$Fu" "$Label driver" -Soft }
}

function Set-SideLabel([string]$Text) { if ($Script:Sync) { $Script:Sync.Label = $Text } }
# ---- time per step: every job of the slipstream (also the background ones) adds its steps to one queue,
# shown as a table at the end, so it is plain where the time goes on this PC.
function Add-Timing($Times, [string]$Part, [string]$Step, [datetime]$Start) {
    if ($null -eq $Times) { return }
    $Times.Enqueue([pscustomobject]@{ Part = $Part; Step = $Step; Secs = ((Get-Date) - $Start).TotalSeconds })
}
function Write-TimingTable($Times, [TimeSpan]$Total) {
    $rows = @($Times.ToArray())
    if (-not $rows.Count) { return }
    $rank = {
        param($p)
        if ($p -match '^Staging') { return 0 }
        if ($p -match '^Edition (\d+)') { return [int]$Matches[1] }
        switch -regex ($p) { '^Other' { return 900 } '^WinRE' { return 1000 } '^boot' { return 1001 } }
        return 1002
    }
    $parts = @($rows | ForEach-Object { $_.Part } | Select-Object -Unique | Sort-Object { & $rank $_ })
    Write-Step 'Time per step'
    foreach ($p in $parts) {
        $mine = @($rows | Where-Object { $_.Part -eq $p })
        $sum = 0.0; foreach ($r in $mine) { $sum += $r.Secs }
        Write-Info ('{0,-46} {1}' -f (Limit-Text $p 46), (Format-Span ([timespan]::FromSeconds([math]::Round($sum)))))
        foreach ($r in $mine) { Write-Info ('   {0,-43} {1}' -f (Limit-Text $r.Step 43), (Format-Span ([timespan]::FromSeconds([math]::Round($r.Secs))))) }
    }
    Write-Info ('{0,-46} {1}' -f 'Total', (Format-Span ([timespan]::FromSeconds([math]::Round($Total.TotalSeconds)))))
    if (@($parts | Where-Object { $_ -match '^(boot|WinRE|Edition)' }).Count -gt 1) { Write-Info '(parts that run at the same time add up to more than the total)' }
}
function Get-FreeGB([string]$Path) {
    try { return (New-Object IO.DriveInfo -ArgumentList ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)))).AvailableFreeSpace / 1GB } catch { return 0.0 }
}
# Editions updated at the same time: the setting (1-4), or automatic - 2 on 4+ processor cores, 3 on 8+ -
# never more than the editions ticked, and about 25 GB free on the work drive for each.
function Get-EditionJobs([int]$Count, [double]$FreeGB) {
    $n = 0
    if ($Script:Cfg) { $n = [int]$Script:Cfg.ParallelEditions }
    if ($n -lt 1) { $c = [Environment]::ProcessorCount; $n = if ($c -ge 8) { 3 } elseif ($c -ge 4) { 2 } else { 1 } }
    $n = [int][math]::Max(1, [math]::Min([math]::Min(4, $n), $Count))
    $space = [int][math]::Max(1, [math]::Floor($FreeGB / 25))
    return [pscustomobject]@{ Jobs = [int][math]::Min($n, $space); Wanted = $n; Space = $space }
}
# ---- updates the image already has. An ISO that Microsoft refreshed ("updated Oct 2025") already carries
# the cumulative update, and DISM unpacks the whole .msu (3-4 minutes per image) only to report "already in
# the correct state". The build an update brings is in the XML inside the .msu (Package_for_RollupFix
# version), the build of an image in its WIM metadata - an update the image is already at is skipped.
function Read-MsuXml([string]$Text) {
    $out = @()
    foreach ($m in [regex]::Matches($Text, '<assemblyIdentity\b[^>]*>')) {
        $n = [regex]::Match($m.Value, '\bname="([^"]+)"').Groups[1].Value
        $v = [regex]::Match($m.Value, '\bversion="([^"]+)"').Groups[1].Value
        if ($n -and $v) { $out += [pscustomobject]@{ Name = $n; Version = $v } }
    }
    return $out
}
# Build and revision of the cumulative update in a .msu (19041.6456), or $null when it cannot be read.
function Get-UpdateBuild([string]$Msu) {
    if ($Msu -notmatch '(?i)\.msu$') { return $null }
    $dir = Join-Path $Script:P.Temp ('msuxml_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $exe = if ($Script:ExpandExe) { $Script:ExpandExe } else { Join-Path $env:SystemRoot 'System32\expand.exe' }
        $r = Invoke-Native $exe @($Msu, '-F:*.xml', $dir)
        Add-Log $r.Text
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter *.xml -File -Recurse -ErrorAction SilentlyContinue)) {
            foreach ($x in @(Read-MsuXml ([IO.File]::ReadAllText($f.FullName)))) {
                if ($x.Name -like 'Package_for_RollupFix*') { $v = [version]$x.Version; return [pscustomobject]@{ Build = $v.Major; Rev = $v.Minor } }
            }
        }
    } catch { Add-Log "Build of $Msu not read: $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    return $null
}
# "19041.6456" for one image of a WIM file, '' when it cannot be read.
function Get-ImageVersion([string]$ImageFile, [int]$Index) {
    try {
        $d = Get-WindowsImage -ImagePath $ImageFile -Index $Index -ErrorAction Stop
        if ($d.Version -and $null -ne $d.SPBuild) { return ('{0}.{1}' -f ([version]$d.Version).Build, [int]$d.SPBuild) }
    } catch { }
    return ''
}
# $true when the image ("19045.6456") is already at the build the update brings (same servicing base).
function Test-UpdateInImage($Update, [string]$ImgVersion) {
    if (-not $Update -or $ImgVersion -notmatch '^(\d+)\.(\d+)$') { return $false }
    return ((Get-BaseBuild ([int]$Matches[1])) -eq (Get-BaseBuild ([int]$Update.Build)) -and [int]$Matches[2] -ge [int]$Update.Rev)
}
# ---- the updates of one mounted edition (the same in the main job and in an edition job)
function Add-EditionUpdates([string]$MountDir, $Upd, [string]$Fu, [string]$LcuTip, [bool]$HasDrv, $Times, [string]$Part, [string]$ImgVersion = '', $LcuBuild = @{}) {
    $Cfg = $Script:Cfg
    Write-Step 'Updating Windows'
    if ($HasDrv) {
        $t = Get-Date
        Write-Sub "Drivers ($(@($Script:S.Drivers).Count) packages)"
        Invoke-Dism "/Image:$(Q $MountDir) /Add-Driver /Driver:$(Q $Script:P.DrvSel) /Recurse$Fu" 'Add drivers' -Soft
        Add-Timing $Times $Part 'drivers' $t
    }
    $t = Get-Date
    foreach ($x in @($Upd.SSU)) { Set-SideLabel "$Part servicing stack"; Add-Pkg $MountDir $x 'Servicing stack' -Soft }
    if (@($Upd.SSU).Count) { Add-Timing $Times $Part 'servicing stack' $t }
    $t = Get-Date; $done = 0
    foreach ($x in @($Upd.LCU)) {
        if ($LcuBuild -and (Test-UpdateInImage $LcuBuild[$x] $ImgVersion)) { Write-Sub "Cumulative update : $(Split-Path $x -Leaf) - this edition is already at build $ImgVersion, skipped"; continue }
        Set-SideLabel "$Part cumulative update"
        try { Add-Pkg $MountDir $x 'Cumulative update' -IgnoreHex @('800F081E') }
        catch { Write-Err $LcuTip; throw }
        $done++
    }
    if ($done) { Add-Timing $Times $Part 'cumulative update' $t }
    $t = Get-Date
    foreach ($x in @($Upd.EKB)) { Set-SideLabel "$Part enablement package"; Add-Pkg $MountDir $x 'Enablement package' -IgnoreHex @('800F081E') -Soft }
    if (@($Upd.EKB).Count) { Add-Timing $Times $Part 'enablement package' $t }
    if ($Cfg.ResetBase) { $t = Get-Date; Set-SideLabel "$Part component cleanup"; Invoke-ImageCleanup $MountDir 'Windows'; Add-Timing $Times $Part 'component cleanup (/ResetBase)' $t }
    if ($Cfg.NetFx3) {
        $sxs = Join-Path $Script:P.Media 'sources\sxs'
        if (Test-Path -LiteralPath $sxs) {
            $t = Get-Date
            Set-SideLabel "$Part .NET 3.5"
            Write-Sub '.NET Framework 3.5 (from sources\sxs)'
            Invoke-Dism "/Image:$(Q $MountDir) /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$(Q $sxs)" 'Enable .NET 3.5' -Soft
            Add-Timing $Times $Part '.NET Framework 3.5' $t
        } else { Write-Warn 'sources\sxs not found - .NET 3.5 skipped.' }
    }
    $t = Get-Date
    foreach ($x in @($Upd.NET481)) { Set-SideLabel "$Part .NET 4.8.1"; Add-Pkg $MountDir $x '.NET Framework 4.8.1' -IgnoreHex @('800F081E') -Soft }
    foreach ($x in @($Upd.NET)) { Set-SideLabel "$Part .NET update"; Add-Pkg $MountDir $x '.NET cumulative update' -IgnoreHex @('800F081E') -Soft }
    if (@($Upd.NET481).Count + @($Upd.NET).Count) { Add-Timing $Times $Part '.NET updates' $t }
}
# ---- boot.wim (WinPE + Setup). Runs in its own runspace while install.wim is serviced
# (Options: "Update boot.wim and WinRE at the same time"), or inline. Returns what the media step needs.
function Invoke-BootWimService($Ctx) {
    $res = [pscustomobject]@{ ExSaved = $false; Count = 0 }
    Write-Title 'Updating boot.wim (WinPE / Setup)'
    Copy-Item -LiteralPath (Join-Path $Ctx.Media 'sources\boot.wim') -Destination $Ctx.BootSt -Force
    (Get-Item -LiteralPath $Ctx.BootSt -Force).Attributes = 'Normal'
    $bootCount = @(Get-WindowsImage -ImagePath $Ctx.BootSt).Count
    $res.Count = $bootCount
    $upd = $Ctx.Upd
    $tq = $Ctx.Times
    for ($b = 1; $b -le $bootCount; $b++) {
        Set-SideLabel "boot.wim $b/$bootCount"
        $t = Get-Date
        if ($Ctx.SkipPE -and $b -eq 1 -and $bootCount -ge 2) {
            Write-Step "boot.wim index 1 of $bootCount (Windows PE) - kept as it is (option)"
            Export-Img $Ctx.BootSt $b $Ctx.BootFin
            Add-Timing $tq 'boot.wim' 'index 1: kept as it is, export' $t
            continue
        }
        Write-Step "boot.wim index $b of $bootCount"
        $iv = Get-ImageVersion $Ctx.BootSt $b
        Mount-Img $Ctx.BootSt $b $Ctx.MountPE
        Add-Timing $tq 'boot.wim' "index ${b}: mount" $t
        $t = Get-Date
        foreach ($x in @($upd.SSU)) { Set-SideLabel "boot.wim $b/$bootCount servicing stack"; Add-Pkg $Ctx.MountPE $x 'Servicing stack' -Soft }
        foreach ($x in @($upd.LCU)) {
            if ($Ctx.LcuBuild -and (Test-UpdateInImage $Ctx.LcuBuild[$x] $iv)) { Write-Sub "Cumulative update : $(Split-Path $x -Leaf) - boot.wim index $b is already at build $iv, skipped"; continue }
            Set-SideLabel "boot.wim $b/$bootCount cumulative update"
            # Microsoft's way for WinPE: the first pass installs the servicing stack in the update and may stop
            # with 0x8007007E; the second one installs the rest. When the first pass installed it all, or the
            # update does not apply, a second pass only unpacks the whole update again.
            Add-Pkg $Ctx.MountPE $x 'Servicing stack via LCU' -IgnoreHex @('8007007E', '800F081E') -Soft
            if (@(0, 3010, [Convert]::ToInt32('800F081E', 16)) -contains $Script:LastDism) { Write-Sub 'Cumulative update installed (or not needed) in that pass - no second pass'; continue }
            Add-Pkg $Ctx.MountPE $x 'Cumulative update' -IgnoreHex @('800F081E') -Soft
        }
        Add-Timing $tq 'boot.wim' "index ${b}: updates" $t
        Set-SideLabel "boot.wim $b/$bootCount drivers"
        $t = Get-Date
        Add-BootDrivers $Ctx.MountPE $Ctx.BootSet $Ctx.Fu 'WinPE'
        if ($Ctx.BootSet -and ($Ctx.BootSet.Folder -or @($Ctx.BootSet.Singles).Count)) { Add-Timing $tq 'boot.wim' "index ${b}: drivers" $t }
        Set-SideLabel "boot.wim $b/$bootCount cleanup"
        $t = Get-Date
        Invoke-ImageCleanup $Ctx.MountPE 'WinPE'
        Add-Timing $tq 'boot.wim' "index ${b}: cleanup" $t
        if (Test-Path -LiteralPath (Join-Path $Ctx.MountPE 'sources\setup.exe')) {
            Copy-Item -LiteralPath (Join-Path $Ctx.MountPE 'sources\setup.exe') -Destination (Join-Path $Ctx.BfDir 'setup.exe') -Force
            foreach ($n in 'bootmgfw.efi', 'bootmgr.efi', 'boot.stl') {
                $f = Join-Path $Ctx.MountPE "Windows\Boot\EFI\$n"
                if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $Ctx.BfDir $n) -Force }
            }
        }
        if ($Ctx.Boot2023 -and -not $res.ExSaved) { $res.ExSaved = [bool](Save-BootFiles2023 $Ctx.MountPE $Ctx.ExDir) }
        Set-SideLabel "boot.wim $b/$bootCount saving"
        $t = Get-Date
        Dismount-Img $Ctx.MountPE -Commit
        Export-Img $Ctx.BootSt $b $Ctx.BootFin
        Add-Timing $tq 'boot.wim' "index ${b}: save and export" $t
    }
    Set-SideLabel ''
    return $res
}
# ---- WinRE (recovery environment, taken from the first edition). Runs in its own runspace while that
# edition is serviced (same option as boot.wim), or inline. $true = $Ctx.ReNew is ready for every edition.
function Invoke-WinReService($Ctx) {
    Write-Step 'Updating WinRE (recovery environment)'
    $ok = $false
    $tq = $Ctx.Times
    try {
        Set-SideLabel 'WinRE mounting'
        $t = Get-Date
        $iv = Get-ImageVersion $Ctx.ReWim 1
        Mount-Img $Ctx.ReWim 1 $Ctx.MountRE
        Add-Timing $tq 'WinRE' 'mount' $t
        $t = Get-Date
        foreach ($x in @($Ctx.Upd.SSU)) { Set-SideLabel 'WinRE servicing stack'; Add-Pkg $Ctx.MountRE $x 'Servicing stack' -Soft }
        foreach ($x in @($Ctx.Upd.LCU)) {
            if ($Ctx.LcuBuild -and (Test-UpdateInImage $Ctx.LcuBuild[$x] $iv)) { Write-Sub "Cumulative update : $(Split-Path $x -Leaf) - WinRE is already at build $iv, skipped"; continue }
            Set-SideLabel 'WinRE servicing stack'; Add-Pkg $Ctx.MountRE $x 'Servicing stack via LCU' -IgnoreHex @('8007007E', '800F081E') -Soft
        }
        foreach ($x in @($Ctx.Upd.SAFEOS)) { Set-SideLabel 'WinRE Safe OS update'; Add-Pkg $Ctx.MountRE $x 'Safe OS Dynamic Update' -Soft }
        Add-Timing $tq 'WinRE' 'updates' $t
        Set-SideLabel 'WinRE drivers'
        $t = Get-Date
        Add-BootDrivers $Ctx.MountRE $Ctx.BootSet $Ctx.Fu 'WinRE'
        if ($Ctx.BootSet -and ($Ctx.BootSet.Folder -or @($Ctx.BootSet.Singles).Count)) { Add-Timing $tq 'WinRE' 'drivers' $t }
        Set-SideLabel 'WinRE cleanup'
        $t = Get-Date
        Invoke-ImageCleanup $Ctx.MountRE 'WinRE'
        Add-Timing $tq 'WinRE' 'cleanup' $t
        Set-SideLabel 'WinRE saving'
        $t = Get-Date
        Dismount-Img $Ctx.MountRE -Commit
        Export-Img $Ctx.ReWim 1 $Ctx.ReNew
        Add-Timing $tq 'WinRE' 'save and export' $t
        $ok = $true
    } catch {
        Write-Warn "WinRE update skipped: $($_.Exception.Message)"
        try { Dismount-Img $Ctx.MountRE } catch { }
    }
    Set-SideLabel ''
    # editions updated at the same time wait for this before they are saved
    if ($Ctx.Shared) { $Ctx.Shared.Re = $(if ($ok) { 'ready' } else { 'failed' }) }
    return $ok
}
# The engine text (to load it into another runspace): this file, between the engine markers.
function Get-EngineText {
    if ($Script:EngineText) { return $Script:EngineText }
    try {
        $all = [IO.File]::ReadAllText($env:W10U_SELF)
        $b = $all.IndexOf('#ENGINE-' + 'BEGIN'); $e = $all.IndexOf('#ENGINE-' + 'END')
        if ($b -ge 0 -and $e -gt $b) { return $all.Substring($b, $e - $b) }
    } catch { }
    return $null
}
# ---- side jobs: boot.wim, WinRE and the servicing stack lookup run in a runspace of their own (with the
# engine loaded) while the main job goes on. Each has its own engine log, DISM log and scratch folder;
# its Activity lines follow when it is joined, and the window shows its status next to the main one.
# $Spec: Name (shown), Command (takes -Ctx), Tag (log names), Scratch (folder name), DismMatch (to end its dism.exe).
function Start-SideJob($Spec, $Ctx) {
    $engine = Get-EngineText
    if (-not $engine) { return $null }
    $sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = ''; Label = "$($Spec.Name) starting" })
    $p = @{}; foreach ($k in $Script:P.Keys) { $p[$k] = $Script:P[$k] }
    $p.Scratch = Join-Path $Script:P.Temp $Spec.Scratch
    $rs = [runspacefactory]::CreateRunspace([Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $sync)
    $rs.SessionStateProxy.SetVariable('IsWorker', $false)       # no Yes/No questions from here
    $init = [PowerShell]::Create(); $init.Runspace = $rs
    $why = $null
    try { [void]$init.AddScript($engine).Invoke(); if ($init.HadErrors) { $why = [string]$init.Streams.Error[0] } }
    catch { $why = $_.Exception.Message }
    $init.Dispose()
    if ($why) { Add-Log "$($Spec.Name) background worker: $why"; $rs.Dispose(); return $null }
    $log = Join-Path $Script:P.Logs "engine-$($Spec.Tag).log"
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    foreach ($kv in @{ P = $p; Cfg = $Script:Cfg; S = $Script:S; Dism = $Script:Dism; LogFile = $log; DismLog = (Join-Path $Script:P.Logs "dism-$($Spec.Tag).log") }.GetEnumerator()) {
        $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
    }
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddCommand($Spec.Command).AddParameter('Ctx', $Ctx)
    $job = [pscustomobject]@{ Name = $Spec.Name; DismMatch = $Spec.DismMatch; Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke(); Sync = $sync; Log = $log; Start = (Get-Date) }
    if ($Script:Sync) { $Script:Sync.SideSync = @(@($Script:Sync.SideSync) | Where-Object { $_ }) + @($sync) }
    return $job
}
function Start-BootWimJob($Ctx) {
    $job = Start-SideJob @{ Name = 'boot.wim'; Command = 'Invoke-BootWimService'; Tag = 'boot'; Scratch = 'scratch-pe'; DismMatch = '(boot_stage|boot_final|mnt\\pe|scratch-pe)' } $Ctx
    if ($job) { Write-Info 'boot.wim is updated at the same time in the background - its log follows after install.wim.' }
    return $job
}
function Receive-SideLines($Job) {
    $it = $null
    while ($Job.Sync.Queue.TryDequeue([ref]$it)) {
        if ($Script:Sync) { $Script:Sync.Queue.Enqueue($it) } else { Microsoft.PowerShell.Utility\Write-Host $it[1] }
    }
}
function Close-SideJob($Job) {
    if ($Script:Sync) {
        $left = @(@($Script:Sync.SideSync) | Where-Object { $_ -and -not [object]::ReferenceEquals($_, $Job.Sync) })
        $Script:Sync.SideSync = if ($left.Count) { $left } else { $null }
    }
    if ($Job.Log -and (Test-Path -LiteralPath $Job.Log) -and $Script:LogFile) {
        try {
            Add-Content -LiteralPath $Script:LogFile -Value ("---- $($Job.Name) (background) log`r`n" + [IO.File]::ReadAllText($Job.Log) + "---- end of $($Job.Name) log") -Encoding UTF8
            Remove-Item -LiteralPath $Job.Log -Force
        } catch { }
    }
    try { $Job.Ps.Dispose() } catch { }
    try { $Job.Rs.Dispose() } catch { }
}
# Waits for a side job, shows its log, returns its result (or throws its error).
function Wait-SideJob($Job) {
    while (-not $Job.Handle.IsCompleted) {
        Receive-SideLines $Job
        $pct = [double]$Job.Sync.Pct
        $st = "waiting for $($Job.Sync.Label)"
        if ($pct -ge 0) { $st += (' {0:N0}%' -f $pct) }
        Write-Host $st -NoNewline
        Start-Sleep -Milliseconds 300
    }
    Receive-SideLines $Job
    if ($Script:Sync) { $Script:Sync.Status = '' }
    $err = $null; $out = $null
    try { $out = @($Job.Ps.EndInvoke($Job.Handle)) } catch { $err = $_.Exception }
    if (-not $err -and $Job.Ps.HadErrors -and $Job.Ps.Streams.Error.Count) { $err = $Job.Ps.Streams.Error[0].Exception }
    Receive-SideLines $Job
    Close-SideJob $Job
    if ($err) {
        $m = $err.Message
        if ($err.InnerException) { $m = $err.InnerException.Message }
        throw "$($Job.Name): $m"
    }
    Write-Info ('{0}: background job finished after {1:mm\:ss}' -f $Job.Name, ((Get-Date) - $Job.Start))
    return (@($out | Where-Object { $null -ne $_ }) | Select-Object -Last 1)
}
# Stops a side job after an error (its dism.exe is ended too, so the mounts can be discarded).
function Stop-SideJob($Job) {
    if (-not $Job) { return }
    try { [void]$Job.Ps.BeginStop($null, $null) } catch { }
    if ($Job.DismMatch) {
        try {
            $rx = [regex]::Escape((Split-Path $Job.Log -Parent | Split-Path -Parent)) + '.*' + $Job.DismMatch
            Get-CimInstance Win32_Process -Filter "Name='dism.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -match $rx } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    $t = Get-Date
    while (-not $Job.Handle.IsCompleted -and ((Get-Date) - $t).TotalSeconds -lt 60) { Start-Sleep -Milliseconds 300 }
    Receive-SideLines $Job
    Close-SideJob $Job
}

# ---- one edition in a runspace of its own (Options: editions at the same time): its own WIM file
# (install_stageN.wim), mount folder, scratch folder and logs. The first one hands its winre.wim to the main
# job (Shared.ReSrc); every one waits for the updated WinRE (Shared.Re) just before it is saved.
function Invoke-EditionJob($Ctx) {
    $res = [pscustomobject]@{ ExSaved = $false }
    Write-Title $Ctx.Title
    Set-SideLabel "$($Ctx.Part) mounting"
    $t = Get-Date
    Mount-Img $Ctx.Wim 1 $Ctx.Mount
    Add-Timing $Ctx.Times $Ctx.Part 'mount' $t
    if ($Ctx.TakeRe) {
        $reSrc = Join-Path $Ctx.Mount 'Windows\System32\Recovery\winre.wim'
        if (Test-Path -LiteralPath $reSrc) {
            Copy-Item -LiteralPath $reSrc -Destination $Ctx.ReWim -Force
            (Get-Item -LiteralPath $Ctx.ReWim -Force).Attributes = 'Normal'
            $Ctx.Shared.ReSrc = 'copied'
        } else {
            Write-Warn 'No winre.wim in this edition - WinRE skipped.'
            $Ctx.Shared.Re = 'none'; $Ctx.Shared.ReSrc = 'none'
        }
    }
    Add-EditionUpdates $Ctx.Mount $Ctx.Upd $Ctx.Fu $Ctx.LcuTip ([bool]$Ctx.HasDrv) $Ctx.Times $Ctx.Part ([string]$Ctx.ImgVersion) $Ctx.LcuBuild
    if ($Ctx.Shared.Re -eq 'pending') {
        $t = Get-Date
        Set-SideLabel "$($Ctx.Part) waiting for WinRE"
        while ($Ctx.Shared.Re -eq 'pending') { Start-Sleep -Milliseconds 300 }
        Add-Timing $Ctx.Times $Ctx.Part 'waiting for WinRE' $t
    }
    if ($Ctx.Shared.Re -eq 'ready') {
        Copy-Item -LiteralPath $Ctx.ReNew -Destination (Join-Path $Ctx.Mount 'Windows\System32\Recovery\winre.wim') -Force
        Write-Sub 'Updated WinRE copied into the image'
    }
    if ($Ctx.Boot2023) { $res.ExSaved = [bool](Save-BootFiles2023 $Ctx.Mount $Ctx.ExDir) }
    Set-SideLabel "$($Ctx.Part) saving"
    $t = Get-Date
    Dismount-Img $Ctx.Mount -Commit
    Add-Timing $Ctx.Times $Ctx.Part 'save' $t
    Set-SideLabel ''
    return $res
}
# Several editions at the same time. The main job stages each ticked edition into a WIM file of its own and
# starts an edition job for it (up to $Ctx.Jobs at once); it starts WinRE as soon as the first edition handed
# over its winre.wim, and writes the new install.wim in the original edition order as editions finish.
# Returns $null when no background worker could start (then the editions are updated one after the other).
function Invoke-EditionsParallel($Ctx) {
    $idx = @($Ctx.ExportIdx)
    $n = $idx.Count
    $shared = [hashtable]::Synchronized(@{ ReSrc = 'pending'; Re = 'pending' })
    $Ctx.ReCtx.Shared = $shared
    $toStart = New-Object 'System.Collections.Generic.Queue[int]'
    for ($k = 1; $k -le $n; $k++) { if (@($Ctx.Selected) -contains [int]$idx[$k - 1]) { $toStart.Enqueue($k) } }
    $first = $toStart.Peek()
    $running = New-Object System.Collections.Generic.List[object]
    $done = @{}
    $res = [pscustomobject]@{ ExDir = $null }
    $reJob = $null; $reState = 'wait'
    $next = 1
    try {
        while ($next -le $n) {
            # WinRE: updated once, as soon as the first edition handed over its winre.wim
            if ($reState -eq 'wait' -and $shared.ReSrc -ne 'pending') {
                $reState = 'done'
                if ($shared.ReSrc -eq 'copied') {
                    if ($Ctx.ParallelRe) { $reJob = Start-SideJob $Ctx.ReSpec $Ctx.ReCtx }
                    if ($reJob) { $reState = 'running'; Write-Info 'WinRE is updated at the same time in the background - its log follows when it is done.' }
                    else { [void](Invoke-WinReService $Ctx.ReCtx) }
                }
            }
            if ($reState -eq 'running' -and $reJob.Handle.IsCompleted) {
                $j = $reJob; $reJob = $null; $reState = 'done'
                try { [void](Wait-SideJob $j) } catch { Write-Warn "WinRE update skipped: $($_.Exception.Message)" }
                if ($shared.Re -eq 'pending') { $shared.Re = 'failed' }
            }
            # start the next edition when a slot is free
            if ($running.Count -lt $Ctx.Jobs -and $toStart.Count) {
                $k = $toStart.Dequeue()
                $orig = [int]$idx[$k - 1]
                $info = @($Ctx.Images | Where-Object { $_.Index -eq $orig })[0]
                $part = "Edition ${k}: $($info.Name)"
                $wim = Join-Path $Ctx.Temp "install_stage$k.wim"
                Write-Step "Staging edition $k of $n ($($info.Name)) from $(Split-Path $Ctx.Src -Leaf)"
                $t = Get-Date
                Export-Img $Ctx.Src $orig $wim -Max
                Add-Timing $Ctx.Times $part 'stage (export into its own WIM)' $t
                $ec = @{
                    Title = "Edition $k/${n}: $($info.Name) (in the background)"; Part = $part; Wim = $wim; Mount = (Join-Path $Ctx.MountBase "os$k")
                    Upd = $Ctx.Upd; Fu = $Ctx.Fu; LcuTip = $Ctx.LcuTip; HasDrv = $Ctx.HasDrv; Times = $Ctx.Times; Shared = $shared
                    ImgVersion = [string]$info.Version; LcuBuild = $Ctx.LcuBuild
                    TakeRe = ($k -eq $first); ReWim = $Ctx.ReCtx.ReWim; ReNew = $Ctx.ReCtx.ReNew; Boot2023 = ($Ctx.Boot2023 -and $k -eq $first); ExDir = $Ctx.ExDir
                }
                $job = Start-SideJob @{ Name = "Edition $k"; Command = 'Invoke-EditionJob'; Tag = "ed$k"; Scratch = "scratch-ed$k"; DismMatch = "(install_stage$k\.wim|mnt\\os$k\b|scratch-ed$k\b)" } $ec
                if (-not $job) {
                    if ($k -eq $first) { Remove-Item -LiteralPath $wim -Force -ErrorAction SilentlyContinue; $Ctx.ReCtx.Shared = $null; return $null }
                    throw "The background worker for edition $k could not start."
                }
                Write-Info "Edition $k ($($info.Name)) is updated in the background - its log follows when it is done."
                $running.Add([pscustomobject]@{ K = $k; Job = $job })
                continue
            }
            # the new install.wim, in the original edition order
            $orig = [int]$idx[$next - 1]
            $info = @($Ctx.Images | Where-Object { $_.Index -eq $orig })[0]
            if (@($Ctx.Selected) -notcontains $orig) {
                Write-Step "Exporting edition $next ($($info.Name), not updated) to the new install.wim"
                $t = Get-Date
                Export-Img $Ctx.Src $orig $Ctx.Final -Max
                Add-Timing $Ctx.Times 'Other editions (not updated)' "export $($info.Name)" $t
                $next++; continue
            }
            if ($done[$next]) {
                Write-Step "Exporting edition $next to the new install.wim"
                $wim = Join-Path $Ctx.Temp "install_stage$next.wim"
                $t = Get-Date
                Export-Img $wim 1 $Ctx.Final -Max
                Add-Timing $Ctx.Times "Edition ${next}: $($info.Name)" 'export into install.wim' $t
                Remove-Item -LiteralPath $wim -Force -ErrorAction SilentlyContinue
                $next++; continue
            }
            # wait until an edition (or WinRE) is done
            $fin = @($running | Where-Object { $_.Job.Handle.IsCompleted }) | Select-Object -First 1
            if (-not $fin) {
                Write-Host ('{0} edition(s) being updated, {1} still to start - waiting' -f $running.Count, $toStart.Count) -NoNewline
                Start-Sleep -Milliseconds 300
                continue
            }
            [void]$running.Remove($fin)
            $r = Wait-SideJob $fin.Job
            $done[$fin.K] = $true
            if ($r -and $r.ExSaved) { $res.ExDir = $Ctx.ExDir }
        }
        if ($reJob) { $j = $reJob; $reJob = $null; try { [void](Wait-SideJob $j) } catch { Write-Warn "WinRE update skipped: $($_.Exception.Message)" } }
        if ($Script:Sync) { $Script:Sync.Status = '' }
        return $res
    } catch {
        foreach ($x in $running) { Write-Warn "Stopping edition $($x.K) in the background..."; Stop-SideJob $x.Job }
        if ($reJob) { Write-Warn 'Stopping the WinRE background job...'; Stop-SideJob $reJob }
        throw
    }
}

function Invoke-Service([switch]$Auto) {
    Assert-Analyzed
    $S = $Script:S; $P = $Script:P; $Cfg = $Script:Cfg
    Write-Title 'Slipstream updates, drivers and options'
    if (@($S.Selected).Count -eq 0) { throw 'No edition selected - tick at least one on the Editions page.' }
    if ($S.Serviced -and -not $Auto) {
        Write-Warn "This media was already serviced on $($S.Serviced.When). For a clean result unpack the ISO again (step 1)."
        if (-not (Read-YesNo 'Service it again anyway?' $false)) { return }
    }
    $upd = Get-UpdateFiles
    $Script:Dism = Get-ServicingDism ([int]$S.Family.Build) -Install       # a newer DISM for Windows 11 on a Windows 10 PC
    if ($Script:Dism -match '(?i)Assessment and Deployment Kit') { Write-Info "DISM of the Windows ADK: $($Script:Dism)" }
    $updCount = 0; foreach ($k in $upd.Keys) { $updCount += @($upd[$k]).Count }
    if ($updCount -eq 0) {
        Write-Warn 'No updates downloaded - only drivers and options will be applied.'
        if (-not $Auto -and -not (Read-YesNo 'Continue?' $true)) { return }
    }
    Test-WorkDir 25
    Clear-Mounts
    Reset-Dir $P.Temp

    $t0 = Get-Date
    $times    = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $src      = Get-SourceImage
    $stage    = Join-Path $P.Temp 'install_stage.wim'
    $final    = Join-Path $P.Temp 'install_final.wim'
    $reWim    = Join-Path $P.Temp 'winre.wim'
    $reNew    = Join-Path $P.Temp 'winre_new.wim'
    $bfDir    = Join-Path $P.Temp 'bootfiles'
    $exDir    = Join-Path $P.Temp 'boot2023'
    $hasDrv   = @($S.Drivers).Count -gt 0 -and (Test-Path -LiteralPath $P.DrvSel)
    $bootInfs = if ($Cfg.BootDrivers -and $hasDrv) { Get-BootDriverInfs } else { @() }
    $fu       = if ($Cfg.ForceUnsigned) { ' /ForceUnsigned' } else { '' }
    $lcuTip   = if ((Get-FamilyOs $S.Family) -eq '10') { 'If this is a Windows 10 update newer than 2025-10, Microsoft blocks offline ESU integration - set the month back on the Windows updates page.' }
                else { 'See logs\dism.log. A Windows 11 image needs a DISM of the same or a newer Windows (the Windows ADK Deployment Tools have one).' }
    New-Item -ItemType Directory -Force -Path $bfDir | Out-Null
    $lcuBuild = @{}
    foreach ($x in @($upd.LCU)) {
        $ub = Get-UpdateBuild $x
        if ($ub) { $lcuBuild[$x] = $ub; Write-Info ('{0} brings build {1}.{2} - an image already at that build skips it' -f (Split-Path $x -Leaf), $ub.Build, $ub.Rev) }
    }
    $bootSet  = New-BootDriverSet $bootInfs (Join-Path $P.Temp 'bootdrivers')
    $bootCtx  = @{
        Upd = $upd; Media = $P.Media; MountPE = $P.MountPE; BfDir = $bfDir; ExDir = (Join-Path $P.Temp 'boot2023_pe')
        BootSt = (Join-Path $P.Temp 'boot_stage.wim'); BootFin = (Join-Path $P.Temp 'boot_final.wim')
        BootSet = $bootSet; Fu = $fu; Boot2023 = [bool]$Cfg.Boot2023; SkipPE = [bool]$Cfg.BootSkipPE; Times = $times; LcuBuild = $lcuBuild
    }
    $reCtx    = @{ Upd = $upd; ReWim = $reWim; ReNew = $reNew; MountRE = $P.MountRE; BootSet = $bootSet; Fu = $fu; Times = $times; LcuBuild = $lcuBuild }
    $reSpec   = @{ Name = 'WinRE'; Command = 'Invoke-WinReService'; Tag = 're'; Scratch = 'scratch-re'; DismMatch = '(winre|mnt\\re|scratch-re)' }

    $all = @($S.Images | ForEach-Object { [int]$_.Index })
    $exportIdx = @(if ($Cfg.KeepOnlySelected) { $S.Selected } else { $all })
    $selCount = @($exportIdx | Where-Object { @($S.Selected) -contains $_ }).Count
    $edJobs = 1
    if ($selCount -gt 1) {
        $free = Get-FreeGB $P.Work
        $ej = Get-EditionJobs $selCount $free
        $edJobs = $ej.Jobs
        if ($edJobs -gt 1) { Write-Info ('{0} of the {1} editions are updated at the same time (Options: editions at the same time).' -f $edJobs, $selCount) }
        elseif ($ej.Wanted -gt 1) { Write-Warn ('The editions are updated one after the other: {0:N0} GB free on the work drive, and each edition updated at the same time needs about 25 GB.' -f $free) }
    }
    $reReady = $false; $reTried = $false; $exSaved = $false
    $bootJob = $null; $bootRes = $null; $reJob = $null

    try {
        # ---- boot.wim in the background (it does not depend on install.wim)
        if ($Cfg.ParallelBoot) {
            $bootJob = Start-BootWimJob $bootCtx
            if (-not $bootJob) { Write-Warn 'The background worker for boot.wim could not start - boot.wim is updated after install.wim.' }
        }

        # ---- several editions at the same time, each in a background job
        $parDone = $false
        if ($edJobs -gt 1) {
            $pr = @(Invoke-EditionsParallel @{
                Src = $src; ExportIdx = $exportIdx; Selected = @($S.Selected); Images = @($S.Images); Jobs = $edJobs; Final = $final; Temp = $P.Temp
                MountBase = (Split-Path $P.Mount -Parent); Upd = $upd; Fu = $fu; LcuTip = $lcuTip; HasDrv = $hasDrv; Times = $times; LcuBuild = $lcuBuild
                ReCtx = $reCtx; ReSpec = $reSpec; ParallelRe = [bool]$Cfg.ParallelBoot; Boot2023 = [bool]$Cfg.Boot2023; ExDir = $exDir
            }) | Select-Object -Last 1
            if ($pr) { $parDone = $true; if ($pr.ExDir) { $exSaved = $true } }
            else { Write-Warn 'The background workers for the editions could not start - they are updated one after the other.' }
        }

        if (-not $parDone) {
            # ---- stage editions (also converts install.esd -> wim)
            Write-Step "Staging $($exportIdx.Count) edition(s) from $(Split-Path $src -Leaf)"
            $t = Get-Date
            foreach ($i in $exportIdx) { Export-Img $src $i $stage -Max }
            Add-Timing $times 'Staging' "export $($exportIdx.Count) edition(s) from $(Split-Path $src -Leaf)" $t

            # ---- WinRE + every selected edition
            for ($k = 1; $k -le $exportIdx.Count; $k++) {
                $orig = [int]$exportIdx[$k - 1]
                $info = $S.Images | Where-Object { $_.Index -eq $orig }
                $part = "Edition ${k}: $($info.Name)"
                if ($S.Selected -contains $orig) {
                    Write-Title "Edition $k/$($exportIdx.Count): $($info.Name)"
                    $t = Get-Date
                    Mount-Img $stage $k $P.Mount
                    Add-Timing $times $part 'mount' $t

                    # WinRE comes from the first edition that has one and is updated once, in the background
                    # while this edition is serviced (same option as boot.wim); it goes into every edition before saving.
                    if (-not $reTried) {
                        $reSrc = Join-Path $P.Mount 'Windows\System32\Recovery\winre.wim'
                        if (Test-Path -LiteralPath $reSrc) {
                            $reTried = $true
                            Copy-Item -LiteralPath $reSrc -Destination $reWim -Force
                            (Get-Item -LiteralPath $reWim -Force).Attributes = 'Normal'
                            if ($Cfg.ParallelBoot) {
                                $reJob = Start-SideJob $reSpec $reCtx
                                if ($reJob) { Write-Info 'WinRE is updated at the same time in the background - its log follows before this edition is saved.' }
                            }
                            if (-not $reJob) { $reReady = (@(Invoke-WinReService $reCtx) | Select-Object -Last 1) -eq $true }
                        } else { Write-Warn 'No winre.wim in this edition - WinRE skipped.' }
                    }

                    Add-EditionUpdates $P.Mount $upd $fu $lcuTip $hasDrv $times $part ([string]$info.Version) $lcuBuild
                    if ($reJob) {
                        $j = $reJob; $reJob = $null
                        $t = Get-Date
                        try { $reReady = (Wait-SideJob $j) -eq $true } catch { Write-Warn "WinRE update skipped: $($_.Exception.Message)"; $reReady = $false }
                        Add-Timing $times $part 'waiting for WinRE' $t
                    }
                    if ($reReady) {
                        Copy-Item -LiteralPath $reNew -Destination (Join-Path $P.Mount 'Windows\System32\Recovery\winre.wim') -Force
                        Write-Sub 'Updated WinRE copied into the image'
                    }
                    if ($Cfg.Boot2023 -and -not $exSaved) { $exSaved = Save-BootFiles2023 $P.Mount $exDir }
                    $t = Get-Date
                    Dismount-Img $P.Mount -Commit
                    Add-Timing $times $part 'save' $t
                }
                Write-Step "Exporting edition $k to the new install.wim"
                $t = Get-Date
                Export-Img $stage $k $final -Max
                if ($S.Selected -contains $orig) { Add-Timing $times $part 'export into install.wim' $t }
                else { Add-Timing $times 'Other editions (not updated)' "export $($info.Name)" $t }
            }
        }

        # ---- boot.wim: join the background job, or run it now
        if ($bootJob) { $j = $bootJob; $bootJob = $null; $bootRes = Wait-SideJob $j }
        else { $bootRes = Invoke-BootWimService $bootCtx }
        if ($bootRes -and $bootRes.ExSaved) { $exDir = $bootCtx.ExDir; $exSaved = $true }   # WinPE's 2023 boot files are preferred, as before
    } catch {
        Write-Err $_.Exception.Message
        if ($reJob) { Write-Warn 'Stopping the WinRE background job...'; Stop-SideJob $reJob }
        if ($bootJob) { Write-Warn 'Stopping the boot.wim background job...'; Stop-SideJob $bootJob }
        Write-Warn 'Discarding mounted images - your unpacked media was not changed.'
        Clear-Mounts
        throw
    }
    $bootFin = $bootCtx.BootFin


    # ---- write results into the media folder
    Write-Title 'Updating the media folder'
    $t = Get-Date
    $srcDir = Join-Path $P.Media 'sources'
    foreach ($n in @('install.wim', 'install.esd')) { Remove-Item -LiteralPath (Join-Path $srcDir $n) -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $srcDir -Filter 'install*.swm' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Move-Item -LiteralPath $final -Destination (Join-Path $srcDir 'install.wim') -Force
    Move-Item -LiteralPath $bootFin -Destination (Join-Path $srcDir 'boot.wim') -Force
    Write-Ok 'install.wim and boot.wim replaced'

    foreach ($cab in $upd.SETUP) {
        Write-Sub "Setup Dynamic Update -> sources ($(Split-Path $cab -Leaf))"
        $r = Invoke-Native (Join-Path $env:SystemRoot 'System32\expand.exe') @($cab, '-F:*', $srcDir)
        Add-Log $r.Text
        $n = [regex]::Match($r.Text, '(\d+) files? total').Groups[1].Value
        if ($r.Code -ne 0) { Write-Warn "expand.exe exit $($r.Code)" } elseif ($n) { Write-Sub "$n setup files updated" }
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
    Add-Timing $times 'Media folder' 'new install.wim / boot.wim, setup files' $t

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
        $t = Get-Date
        Invoke-Dism "/Split-Image /ImageFile:$(Q (Join-Path $srcDir 'install.wim')) /SWMFile:$(Q (Join-Path $srcDir 'install.swm')) /FileSize:3800" 'Split image'
        Remove-Item -LiteralPath (Join-Path $srcDir 'install.wim') -Force
        Add-Timing $times 'Media folder' 'split install.wim (FAT32)' $t
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
    Get-ChildItem -LiteralPath (Split-Path $P.Mount -Parent) -Directory -Filter 'os*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^os\d+$' -and @(Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0 } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Title 'Slipstream finished'
    foreach ($n in $newList) { Write-Ok ('{0,-44} {1}' -f (Limit-Text $n.Name 44), $n.Version) }
    Write-Info ('install.wim: {0}   time: {1:hh\:mm\:ss}' -f (Format-Size $wimSize), ((Get-Date) - $t0))
    Write-TimingTable $times ((Get-Date) - $t0)
}
#endregion

#region ---------------------------------------------------------------- [7] Build ISO
# Free bytes on the drive that holds $Path, or -1 when that can't be told (network share).
function Get-FreeBytes([string]$Path) {
    try { return [double](New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)))).AvailableFreeSpace }
    catch { return -1 }
}
# An ISO that is mounted in Explorer or open in a virtual machine can't be replaced - better to
# say so before oscdimg writes 5 GB than after.
function Test-FileInUse([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None').Dispose(); return $false }
    catch [IO.IOException] { return $true }
    catch { return $false }
}
function Invoke-Build([switch]$Auto, [string]$OutIso) {
    Assert-Unpacked
    $S = $Script:S; $P = $Script:P; $Cfg = $Script:Cfg
    Write-Title 'Build ISO'
    $osc = Find-Oscdimg
    if (-not $osc) { $osc = Get-Oscdimg }
    Write-Info "oscdimg: $osc"
    if (-not $S.Serviced -and -not $Auto) {
        Write-Warn 'The media has not been slipstreamed yet (step 6).'
        if (-not (Read-YesNo 'Build the ISO anyway?' $false)) { return }
    }
    Sync-Oem
    Sync-Unattend
    Test-UnattendSelection
    Write-Step 'Install check (answer file, $OEM$, drivers)'
    $chk = @(Invoke-InstallCheck -NoDownload -Quiet)
    $bad = @($chk | Where-Object { $_.Level -eq 'Error' })
    if ($bad.Count -and -not (Read-YesNo "The install check found $($bad.Count) problem(s) that can break Windows setup (details in the log and on the Install check page). Build the ISO anyway?" $false)) {
        throw 'Build stopped - open the Install check page to see and fix the problems.'
    }

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
    $label = if ($S.Family -and $S.Family.Label) { $S.Family.Label } else { 'WINDOWS_CUSTOM' }
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
    New-Item -ItemType Directory -Force -Path $P.Output | Out-Null
    $iso = Join-Path $P.Output ('Win{0}_{1}_{2}_{3}_{4:yyyyMMdd}.iso' -f (Get-FamilyOs $S.Family), $tag, $build, $arch, (Get-Date))
    if ($OutIso) { $iso = Resolve-OutIso $OutIso $iso }
    Write-Info "Output: $iso"
    New-Item -ItemType Directory -Force -Path (Split-Path $iso -Parent) | Out-Null
    if (Test-FileInUse $iso) {
        throw "$iso is in use - it is probably mounted in Explorer (right-click its drive, Eject) or open in a virtual machine. Close it, or choose another name under Output ISO."
    }

    # oscdimg writes into a .part file: an ISO of the same name is only replaced once the new one is complete
    $part = "$iso.part"
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    $need = [double](Get-ChildItem -LiteralPath $m -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum + 100MB
    $free = Get-FreeBytes $iso
    $old = if (Test-Path -LiteralPath $iso -PathType Leaf) { [double](Get-Item -LiteralPath $iso).Length } else { 0 }
    if ($free -ge 0 -and $free -lt $need -and $old -gt 0 -and $free + $old -ge $need) {
        Write-Info 'Not enough room for the new ISO next to the old one of the same name - the old one is deleted first.'
        Remove-Item -LiteralPath $iso, "$iso.sha256" -Force -ErrorAction SilentlyContinue
        $free += $old
    }
    if ($free -ge 0 -and $free -lt $need) {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($iso))
        $short = 'Only {0} free on {1} - the ISO needs about {2}.' -f (Format-Size $free), $root, (Format-Size $need)
        Write-Warn $short
        if (-not (Read-YesNo "$short Build it anyway?" $false)) {
            throw "Not enough free space for the ISO on $root - free some space, or choose a folder on another drive under Output ISO."
        }
    }

    if (Test-Path -LiteralPath $etfs) { $bootdata = "-bootdata:2#p0,e,b$(Q $etfs)#pEF,e,b$(Q $efi)" }
    else { $bootdata = "-bootdata:1#pEF,e,b$(Q $efi)"; Write-Info 'No etfsboot.com - building a UEFI-only ISO.' }
    Write-Step 'Writing ISO (BIOS + UEFI, UDF)'
    $code = Invoke-Exe $osc ("-m -o -u2 -udfver102 -l$label $bootdata $(Q $m) $(Q $part)") -MergeErr
    if ($code -ne 0 -or -not (Test-Path -LiteralPath $part)) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $kept = if (Test-Path -LiteralPath $iso) { ' The previous ISO of that name is unchanged.' } else { '' }
        throw "oscdimg failed (exit $code).$kept"
    }
    try { Move-Item -LiteralPath $part -Destination $iso -Force }
    catch { throw "The new ISO could not replace $iso ($($_.Exception.Message)). It is saved as $part - rename it once the old file is free." }

    $size = (Get-Item -LiteralPath $iso).Length
    Write-Ok "ISO ready: $iso ($(Format-Size $size))"
    Write-Info 'Calculating SHA-256...'
    $hash = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
    # UTF-8 without BOM (sha256sum -c cannot read a BOM) so a file name with accents stays intact
    [IO.File]::WriteAllText("$iso.sha256", "$hash *$(Split-Path $iso -Leaf)`n", (New-Object Text.UTF8Encoding $false))
    Write-Info "SHA-256: $hash"
    $S.Iso = $iso
    Save-State
    if (-not $Auto -and (Read-YesNo 'Open the output folder?' $true)) { Start-Process explorer.exe "/select,`"$iso`"" }
}
#endregion


#region ---------------------------------------------------------------- processes with live output
function Push-ExeLine([string]$Line) {
    $t = $Line.Trim()
    if (-not $t -or $t -match '^[#=O\-\s]+$') { return }
    # progress bars (DISM "[====  45.0%  ]", curl "####  45.0%") drive the GUI progress bar
    $m = [regex]::Match($t, '(\d{1,3}(?:[\.,]\d+)?)\s*%')
    if ($m.Success -and (($t -replace '[\d\.,%\[\]=#\-\sO>]', '').Length -lt 3 -or $t -match '^\d{1,3}(\.\d+)?% complete$')) {
        $v = 0.0
        if ($Script:Sync -and [double]::TryParse(($m.Groups[1].Value -replace ',', '.'), [Globalization.NumberStyles]::Float, $Script:Inv, [ref]$v)) {
            $Script:Sync.Pct = [math]::Min(100.0, $v)
        }
        return
    }
    $col = if ($t -match '^(Error|ERROR)') { 'Red' } elseif ($t -match '^(Warning|WARNING)') { 'Yellow' } else { 'DarkGray' }
    Write-Host "       $t" -ForegroundColor $col
}
function Invoke-Exe([string]$File, [string]$Arguments, [switch]$MergeErr) {
    Add-Log "EXEC $File $Arguments"
    $psi = New-Object Diagnostics.ProcessStartInfo
    if ($MergeErr) {
        $psi.FileName  = Join-Path $env:SystemRoot 'System32\cmd.exe'
        $psi.Arguments = '/d /s /c "' + (Q $File) + ' ' + $Arguments + ' 2>&1"'
    } else {
        $psi.FileName  = $File
        $psi.Arguments = $Arguments
        $psi.RedirectStandardError = $true
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $null
    if (-not $MergeErr) { $errTask = $p.StandardError.ReadToEndAsync() }
    $sr = $p.StandardOutput
    $sb = New-Object Text.StringBuilder
    $buf = New-Object char[] 2048
    while (($n = $sr.Read($buf, 0, $buf.Length)) -gt 0) {
        for ($i = 0; $i -lt $n; $i++) {
            $ch = $buf[$i]
            if ($ch -eq [char]13 -or $ch -eq [char]10) {
                if ($sb.Length -gt 0) { Push-ExeLine $sb.ToString(); [void]$sb.Clear() }
            } else { [void]$sb.Append($ch) }
        }
    }
    if ($sb.Length -gt 0) { Push-ExeLine $sb.ToString() }
    $p.WaitForExit()
    if ($errTask) {
        foreach ($l in ($errTask.Result -split "`r?`n")) { if ($l.Trim()) { Write-Host "       $($l.Trim())" -ForegroundColor DarkYellow } }
    }
    if ($Script:Sync) { $Script:Sync.Pct = -1 }
    return [int]$p.ExitCode
}
#endregion

# Runs a console tool and returns exit code + output. Windows PowerShell 5.1 turns redirected
# stderr lines into errors, and with ErrorActionPreference = Stop one line on stderr would end
# the whole job - so it is relaxed for this call only.
function Invoke-Native([string]$File, [string[]]$ArgList) {
    $ErrorActionPreference = 'Continue'
    $out = @(& $File @ArgList 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out; Text = ($out -join "`r`n") }
}
# Quotes one argument the way .NET / CommandLineToArgvW read it back.
function ConvertTo-ArgText([string]$A) {
    if ($A -and $A -notmatch '[\s"]') { return $A }
    $s = $A -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}
function Format-Span([TimeSpan]$T) { return ('{0}:{1:mm\:ss}' -f [int][math]::Floor($T.TotalHours), $T) }
# Inf2Cat can run for a long time on big packages (NVIDIA Display.Driver has dozens of INF files
# that all point at the same ~1 GB of files). One run uses one processor core, so several folders
# are catalogued at the same time (up to $Jobs runs). The output of every run is read live: the
# status line shows what is running and for how long, even while the tool prints nothing. With an
# estimate for every item (Est, seconds) it also shows the time left and drives the progress bar.
# Items: Dir, Label, Est, Args (the tool's arguments), WorkDir (optional). $Tool names it in the status
# line. Returns one result per item, in the same order.
function Invoke-Inf2CatQueue([string]$Exe, $Items, [string]$Os, [int]$Jobs = 1) {
    $runs = @(foreach ($it in @($Items)) { [pscustomobject]@{ Dir = $it.Dir; Label = $it.Label; Est = $it.Est; Args = @("/driver:$($it.Dir)", "/os:$Os", '/uselocaltime', '/verbose') } })
    return (Invoke-ToolQueue $Exe $runs $Jobs 'Inf2Cat')
}
function Invoke-ToolQueue([string]$Exe, $Items, [int]$Jobs = 1, [string]$Tool = 'Inf2Cat') {
    $Items = @($Items)
    $Jobs = [math]::Max(1, $Jobs)
    $res = New-Object 'object[]' $Items.Count
    $run = New-Object System.Collections.Generic.List[object]
    $useEst = $Items.Count -gt 0 -and @($Items | Where-Object { [double]$_.Est -gt 0 }).Count -eq $Items.Count
    $allW = 0.0; foreach ($it in $Items) { $allW += [double]$it.Est }
    $doneW = 0.0
    $next = 0; $done = 0
    $t0 = Get-Date
    $shown = [datetime]::MinValue
    $last = $null
    while ($next -lt $Items.Count -or $run.Count -gt 0) {
        while ($next -lt $Items.Count -and $run.Count -lt $Jobs) {
            $it = $Items[$next]
            $argText = (@($it.Args) | ForEach-Object { ConvertTo-ArgText $_ }) -join ' '
            Add-Log "EXEC $Exe $argText"
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $Exe
            $psi.Arguments = $argText
            if ($it.WorkDir) { $psi.WorkingDirectory = [string]$it.WorkDir }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $p = [Diagnostics.Process]::Start($psi)
            $last = [pscustomobject]@{ I = $next; It = $it; P = $p; Err = $p.StandardError.ReadToEndAsync(); Read = $p.StandardOutput.ReadLineAsync()
                                       Out = (New-Object System.Collections.Generic.List[string]); What = 'starting'; Start = (Get-Date); Beat = 5; Est = [double]$it.Est }
            $run.Add($last)
            $next++
        }
        [void][Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($run | ForEach-Object { $_.Read }), 400)
        $now = Get-Date
        foreach ($j in $run.ToArray()) {
            $eof = $false
            while ($j.Read.IsCompleted) {
                $line = $j.Read.Result
                if ($null -eq $line) { $eof = $true; break }
                $j.Out.Add($line)
                $t = $line.Trim()
                if ($t -and $t -notmatch '^[\.\s]+$') {
                    # full paths -> file names, so the line fits the status bar
                    $t = $t -replace '(?i)\b[A-Z]:\\(?:[^\\\r\n]*\\)+', '' -replace '(?<![\w:])(?:/[^/\s]+)+/', ''
                    if ($t.Length -gt 90) { $t = $t.Substring(0, 87) + '...' }
                    $j.What = $t; $last = $j
                }
                $j.Read = $j.P.StandardOutput.ReadLineAsync()
            }
            if ($eof) {
                $j.P.WaitForExit()
                foreach ($l in ($j.Err.Result -split "`r?`n")) { if ($l.Trim()) { $j.Out.Add($l) } }
                $lines = @($j.Out)
                $res[$j.I] = [pscustomobject]@{ Code = [int]$j.P.ExitCode; Output = $lines; Text = ($lines -join "`r`n"); Time = ((Get-Date) - $j.Start); Dir = [string]$j.It.Dir }
                [void]$run.Remove($j)
                $done++; $doneW += [double]$j.It.Est
                if ($last -eq $j) { $last = $null }
                continue
            }
            # engine.log gets a "still running" line every 5 minutes
            if (($now - $j.Start).TotalMinutes -ge $j.Beat) { Add-Log ('{0} {1} still running ({2}) - {3}' -f $Tool, $j.It.Label, (Format-Span ($now - $j.Start)), $j.What); $j.Beat += 5 }
        }
        if ($Script:Sync -and $run.Count -gt 0 -and ($now - $shown).TotalMilliseconds -ge 400) {
            $eta = ''
            if ($useEst) {
                $w = $doneW
                $remain = @()
                foreach ($j in $run) {
                    $e = ($now - $j.Start).TotalSeconds
                    if ($e -gt 0.9 * $j.Est) { $j.Est = $e / 0.9 }      # slower than expected: stretch the estimate
                    $remain += $j.Est - $e
                    $w += [double]$j.It.Est * [math]::Min(0.95, $e / $j.Est)
                }
                $left = Get-LaneTime $remain @(for ($k = $next; $k -lt $Items.Count; $k++) { [double]$Items[$k].Est }) $Jobs
                $Script:Sync.Pct = [math]::Min(99.0, 100.0 * $w / $allW)
                $eta = '  (about {0} left)' -f (Format-Span ([timespan]::FromSeconds([math]::Ceiling($left))))
            }
            $j = if ($last) { $last } else { $run[0] }
            if ($run.Count -eq 1) {
                $Script:Sync.Status = ('{0} {1}  {2}{3}  - {4}' -f $Tool, $j.It.Label, (Format-Span ($now - $j.Start)), $eta, $j.What)
            } else {
                $Script:Sync.Status = ('{0} {1} runs at the same time, {2} of {3} done  {4}{5}  - {6}: {7}' -f $Tool, $run.Count, $done, $Items.Count, (Format-Span ($now - $t0)), $eta, $j.It.Label, $j.What)
            }
            $shown = $now
        }
    }
    if ($Script:Sync) { $Script:Sync.Status = ''; if ($useEst) { $Script:Sync.Pct = -1 } }
    return $res
}
# Time until a queue is through: the seconds the running items still need, then every waiting
# item goes to the slot that is free first.
function Get-LaneTime([double[]]$Running, [double[]]$Waiting, [int]$Jobs) {
    $lanes = New-Object System.Collections.Generic.List[double]
    foreach ($v in @($Running)) { $lanes.Add([math]::Max(0.0, $v)) }
    while ($lanes.Count -lt [math]::Max(1, $Jobs)) { $lanes.Add(0.0) }
    foreach ($v in @($Waiting)) {
        $m = 0; for ($x = 1; $x -lt $lanes.Count; $x++) { if ($lanes[$x] -lt $lanes[$m]) { $m = $x } }
        $lanes[$m] += $v
    }
    $max = 0.0; foreach ($v in $lanes) { if ($v -gt $max) { $max = $v } }
    return $max
}
function Invoke-Inf2Cat([string]$Exe, [string]$Dir, [string]$Os, [string]$Label) {
    return @(Invoke-Inf2CatQueue $Exe @([pscustomobject]@{ Dir = $Dir; Label = $Label; Est = 0 }) $Os 1)[0]
}
# ok | untrusted (signed, but by a certificate Windows does not trust) | mismatch (edited / not in the catalog)
function Get-VerifyState([string]$Cat, [string]$Inf) {
    $r = Invoke-Native $Script:SignTool @('verify', '/pa', '/c', $Cat, $Inf)
    if ($r.Code -eq 0) { return 'ok' }
    if ($r.Text -match '(?i)terminated in a root|not trusted|untrusted') { return 'untrusted' }
    return 'mismatch'
}
#endregion

#region ---------------------------------------------------------------- tools (oscdimg, Inf2Cat, signtool)
function Test-MicrosoftSigned([string]$Path) {
    $s = Get-AuthenticodeSignature -LiteralPath $Path
    return ($s.Status -eq 'Valid' -and $s.SignerCertificate.Subject -match 'O=Microsoft Corporation')
}
function Get-Oscdimg {
    $osc = Find-Oscdimg
    if ($osc) { return $osc }
    # Same source and hashes as Microsoft's Make2023BootableMedia.ps1
    $arch = Get-HostArch
    $src = @{
        x64   = @('https://msdl.microsoft.com/download/symbols/oscdimg.exe/9F01AFB765000/oscdimg.exe', 'ABCD07318EBD8CDBE274B46C9DE78820DCA9709D558CDBC1F5D1730924264D07')
        arm64 = @('https://msdl.microsoft.com/download/symbols/oscdimg.exe/2267BF2C66000/oscdimg.exe', 'CDAE3649F6A6DE45F50A0B5FB5E2BBC098503B9EEFB1AE6A398FC955B434F579')
        x86   = @('https://msdl.microsoft.com/download/symbols/oscdimg.exe/CFBCC93A60000/oscdimg.exe', '85AC2DDD96239D037560E5336727F9A8BE2B902734B9DD88264DD7DB5612EFB9')
    }[$arch]
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    $part = Join-Path $ToolsDir 'oscdimg.exe.part'
    Write-Step "Downloading oscdimg.exe ($arch) from the Microsoft symbol server"
    try { Invoke-WebRequest -Uri $src[0] -OutFile $part -UseBasicParsing } catch { Write-Warn "Download failed: $($_.Exception.Message)" }
    if (Test-Path -LiteralPath $part) {
        if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -eq $src[1]) {
            Move-Item -LiteralPath $part -Destination (Join-Path $ToolsDir 'oscdimg.exe') -Force
            Write-Ok 'oscdimg.exe saved to the tools folder (SHA-256 verified)'
            return (Find-Oscdimg)
        }
        Remove-Item -LiteralPath $part -Force
        Write-Warn 'SHA-256 mismatch - file deleted.'
    }
    $code = Install-AdkDeploymentTools
    $osc = Find-Oscdimg
    if (-not $osc) { throw "oscdimg.exe could not be installed (ADK setup exit $code)." }
    Write-Ok "oscdimg.exe installed: $osc"
    return $osc
}
# Windows ADK Deployment Tools (oscdimg, and a DISM that can service Windows 11), from Microsoft. Returns the setup exit code.
function Install-AdkDeploymentTools {
    Write-Step 'Installing the Windows ADK Deployment Tools from Microsoft (a few minutes)'
    $adk = Join-Path $env:TEMP 'adksetup.exe'
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2289980' -OutFile $adk -UseBasicParsing
    if (-not (Test-MicrosoftSigned $adk)) { Remove-Item -LiteralPath $adk -Force; throw 'The ADK installer failed the Microsoft signature check.' }
    $code = Invoke-Exe $adk '/quiet /norestart /ceip off /features OptionId.DeploymentTools'
    Remove-Item -LiteralPath $adk -Force -ErrorAction SilentlyContinue
    return $code
}
function Find-Tool([string]$Name) {
    if (Test-Path -LiteralPath $ToolsDir) {
        $f = Get-ChildItem -LiteralPath $ToolsDir -Recurse -Filter $Name -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (Test-Path -LiteralPath $kits) {
        $dirs = @(Get-ChildItem -LiteralPath $kits -Directory | Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
        foreach ($d in $dirs) {
            foreach ($a in 'x64', 'x86') {
                $p = Join-Path (Join-Path $d.FullName $a) $Name
                if (Test-Path -LiteralPath $p) { return $p }
            }
        }
    }
    return $null
}
function Save-NuPkg([string]$Id) {
    $lid = $Id.ToLowerInvariant()
    $idx = Invoke-RestMethod -Uri "https://api.nuget.org/v3-flatcontainer/$lid/index.json"
    $stable = @($idx.versions | Where-Object { $_ -notmatch '-' })
    $ver = @($stable | Sort-Object { try { [version]($_ -replace '^(\d+(\.\d+){1,3}).*', '$1') } catch { [version]'0.0' } } -Descending)[0]
    if (-not $ver) { throw "No stable version of $Id on nuget.org" }
    $dl = Join-Path $ToolsDir 'download'
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $file = Join-Path $dl "$lid.$ver.nupkg"
    if (-not (Test-Path -LiteralPath $file) -or (Get-Item -LiteralPath $file).Length -eq 0) {
        Write-Sub "downloading $Id $ver from nuget.org"
        Invoke-WebRequest -Uri "https://api.nuget.org/v3-flatcontainer/$lid/$ver/$lid.$ver.nupkg" -OutFile $file -UseBasicParsing
    }
    return $file
}
# Extracts the folder that holds $Exe (that folder's files only) from a .nupkg into $Dest.
function Expand-Tool([string]$Nupkg, [string]$Exe, [string]$Dest, [string]$Prefer) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Nupkg)
    try {
        $hits = @($zip.Entries | Where-Object { $_.Name -ieq $Exe })
        if ($hits.Count -eq 0) { return $false }
        $hit = @($hits | Sort-Object @{ Expression = { if ($_.FullName -match $Prefer) { 0 } else { 1 } } }, @{ Expression = { $_.FullName }; Descending = $true })[0]
        $prefix = $hit.FullName.Substring(0, $hit.FullName.Length - $hit.Name.Length)
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        foreach ($e in $zip.Entries) {
            if ($e.Name -and $e.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $e.FullName.IndexOf('/', $prefix.Length) -lt 0) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $Dest $e.Name), $true)
            }
        }
        return $true
    } finally { $zip.Dispose() }
}
function Get-FromNuGet([string]$Exe, [string[]]$Packages, [string]$Prefer) {
    foreach ($pkg in $Packages) {
        try {
            $nupkg = Save-NuPkg $pkg
            $dest = Join-Path $ToolsDir ([IO.Path]::GetFileNameWithoutExtension($Exe))
            if (Expand-Tool $nupkg $Exe $dest $Prefer) {
                $exePath = Join-Path $dest $Exe
                $sig = Get-AuthenticodeSignature -LiteralPath $exePath
                if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation') { Write-Ok "$Exe extracted from $pkg (Microsoft signature valid)"; return $exePath }
                if ($sig.Status -eq 'NotSigned') {
                    # Some kit tools (Inf2Cat is .NET) carry no Authenticode signature of their own; the package
                    # itself comes from nuget.org over HTTPS under Microsoft's reserved Microsoft.* prefix.
                    Write-Ok "$Exe extracted from $pkg (not signed itself - comes from Microsoft's NuGet package)"
                    return $exePath
                }
                Write-Warn "$Exe from $pkg failed the signature check (status: $($sig.Status)) - removed."
                Remove-Item -LiteralPath $dest -Recurse -Force
            } else { Write-Info "$Exe is not inside $pkg" }
        } catch { Write-Warn "$pkg : $($_.Exception.Message)" }
    }
    return $null
}
# signtool always; Inf2Cat when it builds the catalogs (for the other engines it is the fallback,
# fetched with Get-Inf2CatTool when first needed).
function Get-SignTools([string]$Engine = 'inf2cat') {
    $t = @{ Inf2Cat = (Find-Tool 'Inf2Cat.exe'); SignTool = (Find-Tool 'signtool.exe') }
    if (-not $t.SignTool) {
        Write-Step 'Getting signtool.exe (Windows SDK build tools)'
        $t.SignTool = Get-FromNuGet 'signtool.exe' @('Microsoft.Windows.SDK.BuildTools', 'Microsoft.Windows.WDK.x64') '(?i)/x64/'
    }
    if ($Engine -eq 'inf2cat') { $t.Inf2Cat = Get-Inf2CatTool }
    elseif ($t.Inf2Cat) { Write-Info "Inf2Cat : $($t.Inf2Cat) (fallback)" }
    if ($t.SignTool) { Write-Info "signtool: $($t.SignTool)" } else { Write-Warn 'signtool.exe not available - PowerShell signing is used and every package is re-signed.' }
    return $t
}
function Get-Inf2CatTool {
    $i = Find-Tool 'Inf2Cat.exe'
    if (-not $i) {
        Write-Step 'Getting Inf2Cat.exe (Windows Driver Kit, about 110 MB)'
        $i = Get-FromNuGet 'Inf2Cat.exe' @('Microsoft.Windows.WDK.x64') '(?i)/x86/'
    }
    if (-not $i) { throw 'Inf2Cat.exe could not be downloaded from nuget.org (see the lines above). Check the internet connection and try again - only the Inf2Cat folder of the package is kept, nothing is installed.' }
    Write-Info "Inf2Cat : $i"
    return $i
}
function Get-AllTools {
    Write-Title 'Tools'
    $o = Get-Oscdimg
    Write-Ok "oscdimg.exe : $o"
    [void](Get-SignTools)
    if ((Get-SignEngine) -eq 'makecat') { $m = Get-MakeCat; if ($m) { Write-Info "MakeCat : $m" } else { Write-Warn 'makecat.exe could not be downloaded - Inf2Cat signs instead.' } }
    Write-Ok 'All tools are ready.'
}
#endregion


#region ---------------------------------------------------------------- re-signing modded drivers (NVCleanstall / edited INF)
function Get-StoreCert {
    $now = Get-Date
    return (Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $Script:CertSubject -and $_.HasPrivateKey -and $_.NotAfter -gt $now.AddDays(30) } |
            Sort-Object NotAfter -Descending | Select-Object -First 1)
}
function Find-Pfx {
    # signing\ is where this tool keeps it; Signing-Output\ is where Sign-Drivers.cmd kept it
    foreach ($p in @((Join-Path $Script:SignDir 'DriverSigning.pfx'), (Join-Path $Script:Root 'Signing-Output\DriverSigning.pfx'))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
# ready = in the store and backed up | export = in the store, no .pfx yet
# import = .pfx found, password needed | create = nothing yet
function Get-CertStatus {
    $c = Get-StoreCert
    $pfx = Find-Pfx
    if ($c -and $pfx) { return 'ready' }
    if ($c) { return 'export' }
    if ($pfx) { return 'import' }
    return 'create'
}
function Get-SigningCert($Password) {
    New-Item -ItemType Directory -Force -Path $Script:SignDir | Out-Null
    $pfx = Join-Path $Script:SignDir 'DriverSigning.pfx'
    $cer = Join-Path $Script:SignDir 'DriverSigning.cer'
    $cert = Get-StoreCert
    if (-not $cert) {
        $have = Find-Pfx
        if ($have) {
            if (-not $Password) { throw 'The password of DriverSigning.pfx is needed.' }
            Write-Sub "Loading $have"
            try { $cert = Import-PfxCertificate -FilePath $have -CertStoreLocation Cert:\CurrentUser\My -Password $Password | Select-Object -First 1 }
            catch { throw 'Could not open DriverSigning.pfx - wrong password?' }
            if ($have -ne $pfx) { Copy-Item -LiteralPath $have -Destination $pfx -Force }
        } else {
            if (-not $Password) { throw 'A password for the new DriverSigning.pfx is needed.' }
            Write-Sub 'Creating a self-signed code-signing certificate (10 years)'
            $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $Script:CertSubject -KeyAlgorithm RSA -KeyLength 3072 `
                    -HashAlgorithm SHA256 -KeyExportPolicy Exportable -KeyUsage DigitalSignature `
                    -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10) -FriendlyName 'Custom Driver Signing'
        }
    }
    if (-not (Test-Path -LiteralPath $pfx)) {
        if (-not $Password) { throw 'A password is needed to back up the certificate as DriverSigning.pfx.' }
        Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $Password | Out-Null
        Write-Ok "Certificate backed up to $pfx - keep it private."
    }
    Export-Certificate -Cert $cert -FilePath $cer -Type CERT | Out-Null
    return $cert
}
# Trusts the certificate on this PC for a moment (to verify catalogs) and returns the
# stores it was added to - stores that already trusted it are left alone afterwards.
function Add-TempTrust([string]$Cer) {
    $pub = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Cer
    $added = @()
    foreach ($name in 'Root', 'TrustedPublisher') {
        $st = New-Object Security.Cryptography.X509Certificates.X509Store -ArgumentList $name, 'LocalMachine'
        $st.Open('ReadWrite')
        if (-not @($st.Certificates | Where-Object { $_.Thumbprint -eq $pub.Thumbprint }).Count) { $st.Add($pub); $added += $name }
        $st.Close()
    }
    return $added
}
function Remove-TempTrust([string]$Cer, [string[]]$Stores) {
    $pub = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $Cer
    foreach ($name in @($Stores)) {
        $st = New-Object Security.Cryptography.X509Certificates.X509Store -ArgumentList $name, 'LocalMachine'
        $st.Open('ReadWrite'); $st.Remove($pub); $st.Close()
    }
}
function Get-InfCatalogs([string]$Inf) {
    $names = @()
    foreach ($line in @(Get-Content -LiteralPath $Inf -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*CatalogFile(\.\w+)?\s*=\s*"?([^";\s]+)"?') { $names += $Matches[2] }
    }
    return @($names | Sort-Object -Unique)
}
function Get-InfFolders([string]$Root) {
    $list = @()
    $infs = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.inf' })
    foreach ($g in ($infs | Group-Object DirectoryName)) {
        $list += [pscustomobject]@{ Dir = $g.Name; Infs = @($g.Group | ForEach-Object { $_.FullName }) }
    }
    return $list
}
# Hardware + compatible IDs of every device present in this PC.
function Get-HostHardwareIds {
    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($d in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop)) {
            foreach ($h in @($d.HardwareID) + @($d.CompatibleID)) { if ($h) { [void]$ids.Add(([string]$h).Trim()) } }
        }
    } catch { Add-Log "Hardware IDs of this PC could not be read: $($_.Exception.Message)" }
    return , $ids
}
# Device IDs an INF installs on (PCI\VEN_10DE&DEV_2206&SUBSYS_..., HDAUDIO\FUNC_01&VEN_10DE...).
function Get-InfDeviceIds([string]$Inf) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $text = ''
    try { $text = [IO.File]::ReadAllText($Inf) } catch { }
    foreach ($line in ($text -split "`r?`n")) {
        $l = $line -replace ';.*$', ''
        if ($l -notmatch '=') { continue }
        foreach ($m in [regex]::Matches($l, '(?i)(?<![\w\\])(?:PCI|HDAUDIO|USB|HID|ACPI|SWC|INTELAUDIO|BTHENUM)\\[^\s,;"]+')) { [void]$set.Add($m.Value) }
    }
    return , $set
}
function Get-InfIncludes([string]$Inf) {
    $names = @()
    foreach ($line in @(Get-Content -LiteralPath $Inf -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*Include\s*=\s*(.+)$') {
            $names += @(($Matches[1] -replace ';.*$', '') -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
        }
    }
    return @($names | Sort-Object -Unique)
}
# "Only this PC's hardware": in a folder with several INF files (NVIDIA Display.Driver has one per
# laptop / desktop maker), keeps the INF files that list a hardware ID of this PC and removes the
# others from the work copy, so Inf2Cat has a fraction of the work. INF files without device IDs
# (components, software) and INF files that a kept one includes stay. A folder where nothing
# matches this PC is left whole.
function Limit-InfsToHost([string]$Root, $Pkgs) {
    $res = [pscustomobject]@{ Removed = 0; Kept = @() }
    $hw = Get-HostHardwareIds
    if ($hw.Count -eq 0) { Write-Warn 'The hardware IDs of this PC could not be read - every INF file is kept.'; return $res }
    foreach ($p in @($Pkgs)) {
        if (@($p.Infs).Count -lt 2) { continue }
        $rel = $p.Dir.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/'); if (-not $rel) { $rel = '.' }
        $keep = New-Object System.Collections.Generic.List[string]
        $other = New-Object System.Collections.Generic.List[string]
        $hits = @()
        foreach ($inf in $p.Infs) {
            $ids = Get-InfDeviceIds $inf
            if ($ids.Count -eq 0) { $keep.Add($inf); continue }
            $hit = $null
            foreach ($id in $ids) { if ($hw.Contains($id)) { $hit = $id; break } }
            if ($hit) { $keep.Add($inf); $hits += ('{0} ({1})' -f (Split-Path $inf -Leaf), $hit) } else { $other.Add($inf) }
        }
        if ($hits.Count -eq 0) { Write-Info "$rel : no INF file lists this PC's hardware - all $(@($p.Infs).Count) are kept"; continue }
        if ($other.Count -eq 0) { continue }
        $more = $true
        while ($more) {
            $more = $false
            foreach ($k in @($keep)) {
                foreach ($inc in (Get-InfIncludes $k)) {
                    $o = @($other | Where-Object { (Split-Path $_ -Leaf) -ieq $inc }) | Select-Object -First 1
                    if ($o) { [void]$other.Remove($o); $keep.Add($o); $more = $true }
                }
            }
        }
        foreach ($o in $other) { Remove-Item -LiteralPath $o -Force }
        $p.Infs = @($keep)
        $res.Removed += $other.Count
        $res.Kept += @($keep | ForEach-Object { Split-Path $_ -Leaf })
        Write-Info ("{0} : kept {1} for this PC, removed {2} INF file(s) for other hardware from the work copy" -f $rel, (($hits | Select-Object -First 3) -join ', '), $other.Count)
    }
    return $res
}
# ok | mismatch | untrusted | catalog-missing | no-catalog-directive | unknown (no signtool to check)
function Get-InfState([string]$Inf) {
    $cats = @(Get-InfCatalogs $Inf)
    if ($cats.Count -eq 0) { return 'no-catalog-directive' }
    $dir = Split-Path -Parent $Inf
    foreach ($c in $cats) {
        $cp = Join-Path $dir $c
        if (-not (Test-Path -LiteralPath $cp)) { return 'catalog-missing' }
        if ($Script:SignTool) {
            $v = Get-VerifyState $cp $Inf
            if ($v -ne 'ok') { return $v }
        }
    }
    if ($Script:SignTool) { return 'ok' }
    return 'unknown'
}
function Invoke-SignCatalog([string]$CatFile, $Cert) {
    if ($Script:SignTool) {
        $r = Invoke-Native $Script:SignTool @('sign', '/fd', 'SHA256', '/sha1', $Cert.Thumbprint, '/s', 'My', $CatFile)
        Add-Log $r.Text
        if ($r.Code -ne 0) { @($r.Output | Where-Object { $_.Trim() } | Select-Object -Last 3) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow } }
        return ($r.Code -eq 0)
    }
    $r = Set-AuthenticodeSignature -FilePath $CatFile -Certificate $Cert -HashAlgorithm SHA256
    return ($null -ne $r.SignerCertificate)
}
# Signs up to 16 catalogs per signtool call instead of one call each. Returns the files that
# could not be signed (a batch that fails is signed again one file at a time to find them).
function Invoke-SignCatalogs([string[]]$Files, $Cert) {
    $Files = @($Files | Where-Object { $_ })
    $failed = @()
    if (-not $Files.Count) { return $failed }
    if (-not $Script:SignTool) {
        foreach ($s in @(Set-AuthenticodeSignature -FilePath $Files -Certificate $Cert -HashAlgorithm SHA256)) { if (-not $s.SignerCertificate) { $failed += $s.Path } }
        return $failed
    }
    for ($i = 0; $i -lt $Files.Count; $i += 16) {
        $chunk = @($Files[$i..([math]::Min($i + 15, $Files.Count - 1))])
        $r = Invoke-Native $Script:SignTool (@('sign', '/fd', 'SHA256', '/sha1', $Cert.Thumbprint, '/s', 'My') + $chunk)
        Add-Log $r.Text
        if ($r.Code -eq 0) { continue }
        foreach ($f in $chunk) { if (-not (Invoke-SignCatalog $f $Cert)) { $failed += $f } }
    }
    return $failed
}
function Test-SignedCatalog([string]$CatFile, [string]$Inf) {
    if ($Script:SignTool) {
        return ((Get-VerifyState $CatFile $Inf) -eq 'ok')
    }
    return ((Get-AuthenticodeSignature -FilePath $CatFile).Status -eq 'Valid')
}
# Inf2Cat runs at the same time: the setting, or the processor cores up to 8 (0 = automatic).
function Get-SignJobs {
    $n = 0
    if ($Script:Cfg) { $n = [int]$Script:Cfg.SignJobs }
    if ($n -lt 1) { $n = [math]::Min(8, [Environment]::ProcessorCount) }
    return [int][math]::Max(1, [math]::Min(8, $n))
}
# How fast Inf2Cat was in earlier runs, for the time estimate: MB of driver files x INF files per
# second (one INF checked against 1 GB at 12 per second takes about 85 s). Kept with the tools.
function Get-Inf2CatRate {
    try {
        $v = [double](Get-Content -LiteralPath (Join-Path $ToolsDir 'inf2cat-speed.json') -Raw | ConvertFrom-Json).Rate
        if ($v -gt 0) { return $v }
    } catch { }
    return 12.0
}
function Save-Inf2CatRate([double]$Rate) {
    $f = Join-Path $ToolsDir 'inf2cat-speed.json'
    $v = $Rate
    if (Test-Path -LiteralPath $f) { $v = 0.5 * (Get-Inf2CatRate) + 0.5 * $Rate }
    $v = [math]::Round([math]::Max(0.5, [math]::Min(2000.0, $v)), 2)
    try {
        New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
        ConvertTo-Json @{ Rate = $v } | Set-Content -LiteralPath $f -Encoding ASCII
    } catch { }
}
# Spreads INF files over at most $Parts Inf2Cat runs (each run gets its own copy of the folder).
function Split-InfRuns([string[]]$Infs, [int]$Parts) {
    $Infs = @($Infs)
    $n = [math]::Max(1, [math]::Min($Parts, $Infs.Count))
    $bins = @(1..$n | ForEach-Object { [pscustomobject]@{ Infs = @() } })
    for ($k = 0; $k -lt $Infs.Count; $k++) { $bins[$k % $n].Infs += $Infs[$k] }
    return @($bins | Where-Object { @($_.Infs).Count })
}
# The catalog an INF gets when its own one is shared with other INF files (NVIDIA's nv_dispi.cat):
# a new catalog for one INF would leave the others without theirs, so it gets a file of its own.
function Get-OwnCatalogName([string]$Inf) {
    return ([IO.Path]::GetFileNameWithoutExtension($Inf).ToLowerInvariant() + '_w10u.cat')
}
# Copies an INF with every CatalogFile= line pointing at $Cat. The encoding is kept: UTF-16 and
# UTF-8 by their byte order mark, anything else byte for byte (Latin-1 maps every byte to itself).
function Set-InfCatalog([string]$Src, [string]$Dst, [string]$Cat) {
    $bytes = [IO.File]::ReadAllBytes($Src)
    $enc, $off = Get-InfEncoding $bytes
    $text = $enc.GetString($bytes, $off, $bytes.Length - $off)
    $text = [regex]::Replace($text, '(?im)^(\s*CatalogFile(?:\.\w+)?\s*=\s*)"?[^";\s]+"?', ('${1}' + $Cat))
    [IO.File]::WriteAllBytes($Dst, [byte[]](@($enc.GetPreamble()) + @($enc.GetBytes($text))))
}
function New-HardLink([string]$Link, [string]$Target) {
    try {
        if (-not ('W10U.Fs' -as [type])) {
            Add-Type -Namespace W10U -Name Fs -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CreateHardLink(string lpFileName, string lpExistingFileName, IntPtr lpSecurityAttributes);'
        }
        return [W10U.Fs]::CreateHardLink($Link, $Target, [IntPtr]::Zero)
    } catch { return $false }
}
# A copy of a package folder for Inf2Cat with only some of its INF files: the driver files are hard
# links (instant, no extra space; copied where the drive has no hard links), no catalogs, and only
# the INF files given. Inf2Cat then checks those INF files instead of every INF in the folder.
function New-InfStage([string]$Dir, [string]$Stage, [string[]]$Infs) {
    New-Item -ItemType Directory -Force -Path $Stage | Out-Null
    $base = $Dir.TrimEnd('\', '/').Length
    $res = [pscustomobject]@{ Links = 0; Copies = 0 }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Extension -ieq '.inf' -or $f.Extension -ieq '.cat') { continue }
        $dst = Join-Path $Stage $f.FullName.Substring($base).TrimStart('\', '/')
        $pd = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Force -Path $pd | Out-Null }
        if (New-HardLink $dst $f.FullName) { $res.Links++ } else { Copy-Item -LiteralPath $f.FullName -Destination $dst -Force; $res.Copies++ }
    }
    foreach ($i in $Infs) { Copy-Item -LiteralPath $i -Destination $Stage -Force }
    return $res
}
# $Isolate: only the INF files that need a new signature are catalogued, in copies of the folder -
# every other INF keeps its catalog and signature. One whose catalog is shared with other INF files
# gets a catalog of its own (Get-OwnCatalogName), so the shared one stays valid for the others.
# $Jobs: Inf2Cat runs at the same time. A folder whose isolated run fails is catalogued whole, as before.
# $Engine: makecat / libwdi / gencat build one catalog per folder (Invoke-CatalogEngine, $EngineTool is
# what Initialize-SignEngine returned); a folder they cannot do goes to Inf2Cat ($Inf2Cat, or fetched then).
function Invoke-SignFolder([string]$Root, $Cert, [string]$Inf2Cat, [bool]$All, [bool]$OnlyThisPc = $false, [bool]$Isolate = $true, [int]$Jobs = 1, [string]$Engine = 'inf2cat', [string]$EngineTool = '') {
    $arch = if ($Script:S.Family -and $Script:S.Family.Arch) { [string]$Script:S.Family.Arch } else { 'x64' }
    $os = if ($arch -eq 'x86') { '10_X86' } else { '10_X64' }
    $Jobs = [math]::Max(1, [math]::Min(8, $Jobs))
    $pkgs = @(Get-InfFolders $Root)
    $trim = [pscustomobject]@{ Removed = 0; Kept = @() }
    if ($OnlyThisPc) { $trim = Limit-InfsToHost $Root $pkgs }
    $states = @{}
    $total = 0; foreach ($p in $pkgs) { $total += @($p.Infs).Count }
    $n = 0
    foreach ($p in $pkgs) { foreach ($inf in $p.Infs) { $n++; Write-Host "checking the signature of INF $n of $total" -NoNewline; $states[$inf] = Get-InfState $inf } }
    if ($Script:Sync) { $Script:Sync.Status = '' }
    $bad = @($states.Keys | Where-Object { $states[$_] -in 'mismatch', 'untrusted', 'catalog-missing', 'unknown' })
    $untrusted = @($states.Keys | Where-Object { $states[$_] -eq 'untrusted' }).Count
    Write-Info ("{0} INF file(s) in {1} folder(s) - {2} need a new signature ({3} signed with a certificate Windows does not trust)" -f @($states.Keys).Count, $pkgs.Count, $bad.Count, $untrusted)
    $res = [ordered]@{ Signed = 0; Failed = 0; Untouched = 0; Skipped = 0; Removed = [int]$trim.Removed; Kept = @($trim.Kept); Engine = '' }
    $todo = @()
    foreach ($p in $pkgs) {
        $rel = $p.Dir.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/'); if (-not $rel) { $rel = '.' }
        $withCat = @($p.Infs | Where-Object { $states[$_] -ne 'no-catalog-directive' })
        $need = @($p.Infs | Where-Object { $states[$_] -in 'mismatch', 'untrusted', 'catalog-missing', 'unknown' })
        if ($withCat.Count -eq 0) { Write-Info "$rel : no CatalogFile= line in the INF - left as is"; $res.Skipped++; continue }
        if (-not $All -and $need.Count -eq 0) { $res.Untouched++; continue }
        $todo += [pscustomobject]@{ Pkg = $p; Rel = $rel; WithCat = $withCat; Need = $(if ($All) { $withCat } else { $need }); Staged = $false; Runs = @(); Check = $withCat; Cats = @(); Ok = $true; Start = $null; Mb = 1.0; Own = @{}; Engine = 'inf2cat' }
    }
    $stageBase = $Root.TrimEnd('\', '/') + '~stage'
    if (Test-Path -LiteralPath $stageBase) { Remove-Item -LiteralPath $stageBase -Recurse -Force -ErrorAction SilentlyContinue }
    $rate = Get-Inf2CatRate
    try {
        # ---- MakeCat / libwdi-style / generate-cat-file; what they cannot do goes to Inf2Cat
        $i2c = @($todo)
        if ($Engine -ne 'inf2cat' -and $todo.Count) { $i2c = @(Invoke-CatalogEngine $Engine $EngineTool $todo $Isolate $Jobs $stageBase $arch) }
        if ($i2c.Count -and -not $Inf2Cat) {
            try { $Inf2Cat = Get-Inf2CatTool }
            catch { Write-Err $_.Exception.Message; foreach ($t in $i2c) { $t.Ok = $false }; $i2c = @() }
        }
        # ---- what every Inf2Cat run gets
        $i = 0; $ns = 0
        foreach ($t in $i2c) {
            $i++
            $p = $t.Pkg
            $cnt = @($p.Infs).Count
            Write-Sub ('{0}  ({1} INF file(s), folder {2} of {3})' -f $t.Rel, $cnt, $i, $i2c.Count)
            $mb = [math]::Max(1.0, [double](@(Get-ChildItem -LiteralPath $p.Dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum)[0].Sum) / 1MB)
            $t.Mb = $mb
            $parts = @()
            if ($Isolate) { $parts = @(Split-InfRuns $t.Need $Jobs) }
            $picked = 0; foreach ($x in $parts) { $picked += @($x.Infs).Count }
            if ($parts.Count -gt 1 -or ($parts.Count -eq 1 -and $picked -lt $t.WithCat.Count)) {
                try {
                    # catalogs named by more than one INF of the folder
                    $uses = @{}
                    foreach ($inf in $p.Infs) { foreach ($c in @(Get-InfCatalogs $inf)) { $k = $c.ToLowerInvariant(); $uses[$k] = 1 + [int]$uses[$k] } }
                    $own = @{}; $sharedNames = @()
                    foreach ($inf in $t.Need) {
                        $sc = @(Get-InfCatalogs $inf | Where-Object { [int]$uses[$_.ToLowerInvariant()] -gt 1 })
                        if ($sc.Count) { $own[$inf] = Get-OwnCatalogName $inf; $sharedNames += $sc }
                    }
                    $t.Own = $own
                    $runs = @()
                    foreach ($x in $parts) {
                        $ns++
                        $sd = Join-Path $stageBase $ns
                        $m = New-InfStage $p.Dir $sd @($x.Infs)
                        foreach ($inf in @($x.Infs)) { if ($own.ContainsKey($inf)) { Set-InfCatalog $inf (Join-Path $sd (Split-Path $inf -Leaf)) $own[$inf] } }
                        if ($m.Copies -gt 0) { Add-Log "$($t.Rel): $($m.Copies) file(s) copied for Inf2Cat (no hard links on this drive)" }
                        $lbl = if ($parts.Count -gt 1) { '{0} part {1}/{2}' -f $t.Rel, ($runs.Count + 1), $parts.Count } else { $t.Rel }
                        $runs += [pscustomobject]@{ Dir = $sd; Label = $lbl; Infs = @($x.Infs).Count; Est = (3 + @($x.Infs).Count * $mb / $rate); R = $null }
                    }
                    $t.Runs = $runs; $t.Staged = $true
                    $t.Check = @($parts | ForEach-Object { $_.Infs })
                    $msg = '{0} of {1} INF file(s) get a new catalog - the others keep their signature' -f $picked, $t.WithCat.Count
                    if ($parts.Count -gt 1) { $msg += " (in $($parts.Count) Inf2Cat runs at the same time)" }
                    Write-Info $msg
                    if ($own.Count) {
                        $names = @($sharedNames | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
                        Write-Info ('{0} of them get a catalog file of their own (<name>_w10u.cat), because {1} is named by several INF files - it is left as it is' -f $own.Count, (($names | Select-Object -First 3) -join ', '))
                    }
                } catch {
                    Add-Log "$($t.Rel): isolated copy not possible ($($_.Exception.Message)) - the whole folder is catalogued"
                    $t.Staged = $false; $t.Check = $t.WithCat; $t.Own = @{}
                }
            }
            if (-not $t.Staged) { $t.Runs = @([pscustomobject]@{ Dir = $p.Dir; Label = $t.Rel; Infs = $cnt; Est = (3 + $cnt * $mb / $rate); R = $null }) }
            if (@($t.Runs | Where-Object { $_.Infs -ge 10 }).Count) {
                Write-Info "Inf2Cat checks each of these INF files against every file of the package - this can take a long time (up to an hour for a full NVIDIA package). It is still working while the time in the status line keeps counting."
                if (-not $OnlyThisPc) { Write-Info 'Faster next time: "Only keep the INF files for this PC''s hardware" on this page.' }
            }
        }
        # ---- Inf2Cat, up to $Jobs runs at the same time; then the folders whose isolated run failed, whole
        $pending = @($i2c | ForEach-Object { $_.Runs })
        while ($pending.Count) {
            $start = Get-Date
            foreach ($t in $i2c) { if (@($t.Runs | Where-Object { $pending -contains $_ }).Count) { $t.Start = $start } }
            $est = Get-LaneTime @() @($pending | ForEach-Object { [double]$_.Est }) $Jobs
            $how = if ($pending.Count -eq 1) { '1 run' } else { '{0} runs, up to {1} at the same time' -f $pending.Count, [math]::Min($Jobs, $pending.Count) }
            Write-Info ('Inf2Cat: {0} - estimated time {1}' -f $how, (Format-Span ([timespan]::FromSeconds([math]::Ceiling($est)))))
            $out = @(Invoke-Inf2CatQueue $Inf2Cat $pending $os $Jobs)
            for ($k = 0; $k -lt $pending.Count; $k++) { $pending[$k].R = $out[$k] }
            $retry = @()
            foreach ($t in $i2c) {
                $mine = @($t.Runs | Where-Object { $pending -contains $_ })
                foreach ($r in $mine) { Add-Log ("[$($r.Label)] Inf2Cat exit $($r.R.Code) after $(Format-Span $r.R.Time)`r`n" + ($r.R.Output | Out-String)) }
                if ($t.Staged -and @($mine | Where-Object { $_.R.Code -ne 0 }).Count) {
                    $f = @($mine | Where-Object { $_.R.Code -ne 0 })[0]
                    Write-Warn "$($t.Rel): Inf2Cat failed on the isolated INF file(s) - the whole folder is catalogued instead (slower)"
                    @($f.R.Output | Out-String -Stream | Where-Object { $_.Trim() } | Select-Object -Last 3) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
                    $cnt = @($t.Pkg.Infs).Count
                    $t.Staged = $false; $t.Check = $t.WithCat; $t.Own = @{}
                    $t.Runs = @([pscustomobject]@{ Dir = $t.Pkg.Dir; Label = $t.Rel; Infs = $cnt; Est = (3 + $cnt * $t.Mb / $rate); R = $null })
                    $retry += $t.Runs
                }
            }
            $pending = $retry
        }
        # learned speed for the next estimate (runs shorter than a few seconds say little)
        $work = 0.0; $secs = 0.0
        foreach ($t in $i2c) { foreach ($r in $t.Runs) { if ($r.R -and $r.R.Code -eq 0 -and $r.R.Time.TotalSeconds -gt 8) { $work += $r.Infs * $t.Mb; $secs += $r.R.Time.TotalSeconds - 3 } } }
        if ($secs -gt 0) { Save-Inf2CatRate ($work / $secs) }

        # ---- the new catalogs, signed together
        $newCats = @()
        foreach ($t in $todo) {
            if (-not $t.Ok) { continue }
            if ($t.Engine -ne 'inf2cat') { $newCats += $t.Cats; continue }
            if (@($t.Runs | Where-Object { $_.R.Code -ne 0 }).Count) {
                $f = @($t.Runs | Where-Object { $_.R.Code -ne 0 })[0]
                Write-Err "Inf2Cat failed for $($t.Rel)"
                @($f.R.Output | Out-String -Stream | Where-Object { $_.Trim() } | Select-Object -Last 4) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
                if (($f.R.Output | Out-String) -match 'Signability test failed') { Write-Info 'Hint: delete inf2cat.exe.manifest next to Inf2Cat.exe and try again.' }
                $t.Ok = $false; continue
            }
            if ($t.Staged) {
                foreach ($r in $t.Runs) {
                    foreach ($c in @(Get-ChildItem -LiteralPath $r.Dir -Filter *.cat -File)) {
                        $dst = Join-Path $t.Pkg.Dir $c.Name
                        Copy-Item -LiteralPath $c.FullName -Destination $dst -Force
                        $t.Cats += $dst
                    }
                    foreach ($inf in @($t.Own.Keys)) {
                        $staged = Join-Path $r.Dir (Split-Path $inf -Leaf)
                        if (Test-Path -LiteralPath $staged) { Copy-Item -LiteralPath $staged -Destination $inf -Force }
                    }
                }
            } else {
                $t.Cats = @(Get-ChildItem -LiteralPath $t.Pkg.Dir -Filter *.cat -File | Where-Object { $_.LastWriteTime -ge $t.Start.AddSeconds(-2) } | ForEach-Object { $_.FullName })
            }
            if (-not $t.Cats.Count) { Write-Err "Inf2Cat wrote no catalog for $($t.Rel)"; $t.Ok = $false; continue }
            $newCats += $t.Cats
        }
        if ($newCats.Count) { Write-Host "signing $($newCats.Count) catalog(s)" -NoNewline }
        $failed = @(Invoke-SignCatalogs $newCats $Cert)
        if ($Script:Sync) { $Script:Sync.Status = '' }
        foreach ($t in $todo) {
            if (-not $t.Ok) { $res.Failed++; continue }
            $ok = $true
            foreach ($c in $t.Cats) { if ($failed -contains $c) { $ok = $false; Write-Err "Signing failed: $(Split-Path $c -Leaf)" } }
            if ($ok) {
                foreach ($inf in $t.Check) { foreach ($c in (Get-InfCatalogs $inf)) { if (-not (Test-SignedCatalog (Join-Path $t.Pkg.Dir $c) $inf)) { $ok = $false; Write-Err "Verification failed: $c" } } }
            }
            $runs = @($t.Runs)
            $longest = ($runs | ForEach-Object { $_.R.Time } | Sort-Object -Descending | Select-Object -First 1)
            $took = if ($runs.Count -eq 1) { "$(Get-SignEngineName $t.Engine) took $(Format-Span $longest)" } else { "$($runs.Count) Inf2Cat runs, the longest took $(Format-Span $longest)" }
            if ($ok) { $res.Signed++; Write-Ok "$($t.Rel) signed and verified ($took)" }
            else {
                $res.Failed++
                if ($t.Engine -ne 'inf2cat') { Write-Info "Hint: choose the Inf2Cat engine on this page and sign again - $(Get-SignEngineName $t.Engine) does not parse the INF." }
            }
        }
        $res.Engine = (@($todo | Where-Object { $_.Ok } | ForEach-Object { Get-SignEngineName $_.Engine } | Sort-Object -Unique) -join ' + ')
    } finally {
        if (Test-Path -LiteralPath $stageBase) { Remove-Item -LiteralPath $stageBase -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($Script:Sync) { $Script:Sync.Status = '' }
    return $res
}
# Folder / file name of a driver package. ASCII only: it ends up in SetupComplete-drivers.cmd, which is
# written as ASCII, so "Treiber fuer Mueller" typed with accents must not turn into question marks there.
function ConvertTo-PackageName([string]$Text) {
    if ($null -eq $Text) { $Text = '' }
    $d = $Text.Normalize([Text.NormalizationForm]::FormD)
    $d = [regex]::Replace($d, '\p{Mn}', '')
    $n = ([regex]::Replace($d, '[^A-Za-z0-9_\.-]', '_')).Trim('_')
    if (-not $n) { $n = 'Driver' }
    return $n
}
function Invoke-SignPackage([string]$Source, [string]$Name, $Password, [bool]$All, [bool]$OnlyThisPc = $false, [bool]$Isolate = $true, [int]$Jobs = 1, [string]$Engine = 'inf2cat') {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Folder not found: $Source" }
    $Name = ConvertTo-PackageName $Name
    Write-Title "Re-sign modded drivers - $Name"
    $tools = Get-SignTools $Engine
    $Script:SignTool = $tools.SignTool
    $engTool = ''
    if ($Engine -ne 'inf2cat') {
        try { $engTool = Initialize-SignEngine $Engine }
        catch {
            Write-Warn "$(Get-SignEngineName $Engine) is not available: $($_.Exception.Message)"
            Write-Info 'Inf2Cat builds the catalogs instead.'
            $Engine = 'inf2cat'
        }
    }
    $cert = Get-SigningCert $Password
    Write-Info ("Certificate: {0}  {1}  valid until {2:yyyy-MM-dd}" -f $cert.Subject, $cert.Thumbprint, $cert.NotAfter)
    $dest = Join-Path $Script:P.Signed $Name
    Write-Step "Copying $Source into the work folder (the original is not touched)"
    Reset-Dir $dest
    Copy-Tree $Source $dest
    $cer = Join-Path $Script:SignDir 'DriverSigning.cer'
    Write-Step 'Building new catalogs and signing them'
    $added = @(Add-TempTrust $cer)   # only while verifying - the ISO trusts it during setup
    if ($OnlyThisPc) { Write-Info 'Only the INF files for this PC''s hardware are kept - the ISO installs this driver on this PC only.' }
    $scope = if ($Isolate) { 'only the INF files that need a new catalog get one' } else { 'every INF file of a folder that needs a new catalog gets one' }
    if ($Engine -eq 'inf2cat') { Write-Info ('Engine: Inf2Cat, up to {0} run(s) at the same time - {1}' -f $Jobs, $scope) }
    else { Write-Info ('Engine: {0} - one catalog per driver folder with the hash of every file in it, {1}; Inf2Cat for a folder it cannot do' -f (Get-SignEngineName $Engine), $scope) }
    try { $res = Invoke-SignFolder $dest $cert $tools.Inf2Cat $All $OnlyThisPc $Isolate $Jobs $Engine $engTool }
    finally { if ($added.Count) { Remove-TempTrust $cer $added } }
    $rec = [ordered]@{
        Name = $Name; Source = $Source; Path = $dest; InstallDir = "C:\Drivers\$Name"; When = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Signed = [int]$res.Signed; Failed = [int]$res.Failed; Untouched = [int]$res.Untouched; Thumbprint = $cert.Thumbprint
        OnlyThisPc = [bool]($OnlyThisPc -and $res.Removed -gt 0); Removed = [int]$res.Removed; Kept = @($res.Kept); Engine = [string]$res.Engine
    }
    $Script:S.Signed = @(@($Script:S.Signed | Where-Object { $_ -and $_.Name -ne $Name }) + @($rec))
    Save-State
    if ($res.Failed -gt 0) { Write-Warn "$($res.Failed) package folder(s) failed - details in logs\engine.log. The rest is ready." }
    if ($res.Signed -eq 0 -and $res.Failed -eq 0) { Write-Warn 'Nothing needed a new signature (all catalogs were valid). Turn on "Re-sign every package" to sign anyway.' }
    Write-Ok "$Name is added to the ISO through `$OEM`$ and installs from $($rec.InstallDir) at the end of Windows setup."
}
function Remove-SignedPackage([string]$Name) {
    $x = @($Script:S.Signed | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
    if ($x -and $x.Path) { Remove-Item -LiteralPath $x.Path -Recurse -Force -ErrorAction SilentlyContinue }
    $Script:S.Signed = @($Script:S.Signed | Where-Object { $_ -and $_.Name -ne $Name })
    Save-State
}
function New-SetupCompleteDrivers($Packages, [bool]$Cleanup, $ExtraRoots = @()) {
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add('@echo off')
    $l.Add('rem Generated by Windows-ISO-Updater: trusts the driver-signing certificate and installs the driver packages.')
    $l.Add('rem Called from SetupComplete.cmd and (optionally) from the specialize pass - it runs only once.')
    $l.Add('set "LOG=%windir%\Temp\SetupComplete-drivers.log"')
    $l.Add('set "DONE=%windir%\Setup\Scripts\drivers.done"')
    $l.Add('if exist "%DONE%" exit /b 0')
    $l.Add('set "CER=%SystemDrive%\Drivers\DriverSigning.cer"')
    $l.Add('echo %date% %time% trusting the driver-signing certificate>>"%LOG%"')
    $l.Add('if exist "%CER%" certutil -addstore -f Root "%CER%">>"%LOG%" 2>&1')
    $l.Add('if exist "%CER%" certutil -addstore -f TrustedPublisher "%CER%">>"%LOG%" 2>&1')
    foreach ($r in @($ExtraRoots)) {
        $l.Add("echo %date% %time% installing $r>>`"%LOG%`"")
        $l.Add("pnputil /add-driver `"%SystemDrive%\$r\*.inf`" /subdirs /install>>`"%LOG%`" 2>&1")
    }
    foreach ($x in @($Packages)) {
        $rel = ([string]$x.InstallDir) -replace '^[A-Za-z]:\\?', ''
        $l.Add("echo %date% %time% installing $($x.Name)>>`"%LOG%`"")
        $l.Add("pnputil /add-driver `"%SystemDrive%\$rel\*.inf`" /subdirs /install>>`"%LOG%`" 2>&1")
        if ($Cleanup) { $l.Add("rd /s /q `"%SystemDrive%\$rel`"") }
    }
    if ($Cleanup -and @($Packages).Count) { $l.Add('del /f /q "%CER%" >nul 2>&1') }
    $l.Add('echo %date% %time% done>"%DONE%"')
    $l.Add('echo %date% %time% done>>"%LOG%"')
    $l.Add('exit /b 0')
    return (($l -join "`r`n") + "`r`n")
}
# Rebuilds sources\$OEM$ on the media: your $OEM$ folder + the re-signed packages +
# SetupComplete-drivers.cmd (called from SetupComplete.cmd).
function Sync-Oem {
    $srcDir = Join-Path $Script:P.Media 'sources'
    if (-not (Test-Path -LiteralPath $srcDir)) { return }
    $oem = Join-Path $srcDir '$OEM$'
    $S = $Script:S
    $signed = @($S.Signed | Where-Object { $_ -and $_.Path -and (Test-Path -LiteralPath $_.Path) })
    $user = $null
    if ($S.Oem -and $S.Oem.Source -and (Test-Path -LiteralPath $S.Oem.Source)) { $user = [string]$S.Oem.Source }
    elseif ($S.Oem -and $S.Oem.Source) { Write-Warn "Your `$OEM`$ folder is gone: $($S.Oem.Source)" }
    $roots = @()
    if ($user -and $Script:Cfg.InstallOemDrivers) { $roots = @(Get-OemDriverRoots $user $signed) }
    if (-not $user -and $signed.Count -eq 0) {
        if ($S.OemSynced) {
            Remove-Item -LiteralPath $oem -Recurse -Force -ErrorAction SilentlyContinue
            $S.OemSynced = $false; Save-State
            Write-Info "`$OEM`$ removed from the media."
        }
        return
    }
    Write-Step "Updating sources\`$OEM`$ on the media"
    if (Test-Path -LiteralPath $oem) { Remove-Item -LiteralPath $oem -Recurse -Force }
    if ($user) { Copy-Tree $user $oem; Write-Sub "your `$OEM`$ folder ($user)" }
    else { New-Item -ItemType Directory -Force -Path $oem | Out-Null }
    if ($signed.Count -gt 0 -or $roots.Count -gt 0) {
        $cer = Join-Path $Script:SignDir 'DriverSigning.cer'
        if ($signed.Count -gt 0 -and -not (Test-Path -LiteralPath $cer)) { throw "DriverSigning.cer is missing from $($Script:SignDir) - sign the package again." }
        $one = Join-Path $oem '$1'
        foreach ($x in $signed) {
            $rel = ([string]$x.InstallDir) -replace '^[A-Za-z]:\\?', ''
            Copy-Tree $x.Path (Join-Path $one $rel)
            Write-Sub "$($x.Name) -> $($x.InstallDir)"
        }
        if (Test-Path -LiteralPath $cer) {
            New-Item -ItemType Directory -Force -Path (Join-Path $one 'Drivers') | Out-Null
            Copy-Item -LiteralPath $cer -Destination (Join-Path $one 'Drivers\DriverSigning.cer') -Force
        }
        foreach ($r in $roots) { Write-Sub "your drivers in C:\$r are installed with pnputil" }
        $scDir = Join-Path $oem '$$\Setup\Scripts'
        New-Item -ItemType Directory -Force -Path $scDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $scDir 'SetupComplete-drivers.cmd'), (New-SetupCompleteDrivers $signed ([bool]$Script:Cfg.SignCleanup) $roots), [Text.Encoding]::ASCII)
        $main = Join-Path $scDir 'SetupComplete.cmd'
        $call = 'call "%~dp0SetupComplete-drivers.cmd"'
        if (Test-Path -LiteralPath $main) {
            # Byte-preserving: the file is read and written as Latin-1 (1 byte = 1 char), so accents in the
            # user's own script survive (writing it back as ASCII would turn them into "?"). A UTF-8 BOM is kept.
            $bytes = [IO.File]::ReadAllBytes($main)
            $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $latin = [Text.Encoding]::GetEncoding(28591)
            $text = if ($bom) { $latin.GetString($bytes, 3, $bytes.Length - 3) } else { $latin.GetString($bytes) }
            if ($text -notmatch 'SetupComplete-drivers\.cmd') {
                $lines = New-Object System.Collections.Generic.List[string]
                $lines.AddRange([string[]]@($text -split "`r?`n"))
                if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
                $at = if ($lines.Count -gt 0 -and $lines[0] -match '^\s*@?echo\s+off') { 1 } else { 0 }
                $lines.Insert($at, $call)
                $out = $latin.GetBytes(($lines -join "`r`n") + "`r`n")
                if ($bom) { $out = [byte[]](@(0xEF, 0xBB, 0xBF) + $out) }
                [IO.File]::WriteAllBytes($main, $out)
                Write-Sub 'your SetupComplete.cmd now calls SetupComplete-drivers.cmd first'
            }
        } else {
            [IO.File]::WriteAllText($main, "@echo off`r`n$call`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
        }
        Write-Sub 'SetupComplete-drivers.cmd: trust certificate + pnputil /add-driver /install'
    }
    $S.OemSynced = $true
    Save-State
}
function Set-OemFolder([string]$Dir) {
    if ($Dir) {
        $d = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\')
        if ((Split-Path $d -Leaf) -ne '$OEM$' -and (Test-Path -LiteralPath (Join-Path $d '$OEM$'))) { $d = Join-Path $d '$OEM$' }
        if ((Split-Path $d -Leaf) -ne '$OEM$') { Write-Warn "This folder is not named `$OEM`$ - its contents are copied to sources\`$OEM`$ anyway." }
        $Script:S.Oem = [ordered]@{ Source = $d; Added = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
        Write-Ok "`$OEM`$ folder set: $d (copied into the media when the ISO is built)"
    } else {
        $Script:S.Oem = $null
        Write-Ok "`$OEM`$ folder removed (taken out of the media at the next build)."
    }
    Save-State
}
#endregion

#region ---------------------------------------------------------------- catalog engines (NVIDIA Modded Drivers Signer 2.3.0)
# Inf2Cat parses every INF and checks it against every file of the package, once per INF. The other
# engines do not parse the INF: they build ONE catalog per driver folder (<folder>_w10u.cat) that every
# INF needing a new signature in that folder points at. It holds the hash of those INF files and of every
# file of the folder, so the driver files are hashed once - about 20 s for NVIDIA's 3 GB Display.Driver
# instead of minutes. Windows checks every file it copies against the catalog, also the ones an INF
# copies as whole directories (ngx-builtins, NvCamera, ...), so all files of the folder go in.
#   makecat - makecat.exe from the Windows SDK / WDK and a generated .cdf (the default)
#   libwdi  - the CryptCAT API of wintrust.dll, the way libwdi (Zadig) builds its catalogs
#   gencat  - LINBIT generate-cat-file, built and run inside WSL
#   inf2cat - Microsoft's Inf2Cat, the standard tool, and the fallback for the others
function Get-SignEngine {
    $e = ''
    if ($Script:Cfg) { $e = ([string]$Script:Cfg.SignEngine).ToLowerInvariant() }
    if ($e -in 'makecat', 'libwdi', 'gencat', 'inf2cat') { return $e }
    return 'makecat'
}
function Get-SignEngineName([string]$Engine) {
    switch ($Engine) { 'makecat' { return 'MakeCat' } 'libwdi' { return 'libwdi-style' } 'gencat' { return 'generate-cat-file' } }
    return 'Inf2Cat'
}
# Encoding of an INF file: UTF-16 and UTF-8 by their byte order mark, anything else byte for byte
# (Latin-1 maps every byte to itself). Returns the encoding and the length of the byte order mark.
function Get-InfEncoding([byte[]]$Bytes) {
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return @((New-Object Text.UnicodeEncoding -ArgumentList $false, $true), 2) }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return @((New-Object Text.UnicodeEncoding -ArgumentList $true, $true), 2) }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return @((New-Object Text.UTF8Encoding -ArgumentList $true), 3) }
    return @([Text.Encoding]::GetEncoding(28591), 0)
}
function Read-InfText([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $enc, $off = Get-InfEncoding $bytes
    return $enc.GetString($bytes, $off, $bytes.Length - $off)
}
# Name Windows looks for when a file is stored compressed: the last character of the extension becomes
# "_" (nvngx_dlssd.dll -> nvngx_dlssd.dl_), a shorter extension gets "_" appended, no extension -> "._".
function Get-PackedName([string]$Leaf) {
    if (-not $Leaf) { return '' }
    $dot = $Leaf.LastIndexOf('.')
    if ($dot -lt 0) { return ($Leaf + '._') }
    if (($Leaf.Length - $dot - 1) -ge 3) { return ($Leaf.Substring(0, $Leaf.Length - 1) + '_') }
    return ($Leaf + '_')
}
# Files an INF names in [SourceDisksFiles] (plain, .nt and the image's architecture) that are in its folder.
# A file that is only there compressed (name.dl_) counts: Packed, Path is the compressed file and Name the
# name the INF uses (the one Windows checks against the catalog). Missing: named but not there; MissingUsed:
# of those, the ones a copy section names too - no catalog can hold the hash of a file that is not there.
function Get-InfSourceFiles([string]$Inf, [string]$Arch = 'amd64') {
    $dir = Split-Path -Parent $Inf
    $self = Split-Path -Leaf $Inf
    $text = Read-InfText $Inf
    $secs = [regex]::Matches($text, '(?m)^[ \t]*\[([^\]\r\n]+)\]')
    $split = New-Object Text.RegularExpressions.Regex -ArgumentList ',(?=(?:[^"]*"[^"]*")*[^"]*$)'
    $want = '^SourceDisks(Names|Files)(\.nt|\.(nt)?' + [regex]::Escape($Arch) + ')?$'
    $disks = @{}
    $entries = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $secs.Count; $i++) {
        $sname = $secs[$i].Groups[1].Value.Trim()
        if ($sname -notmatch $want) { continue }
        $isNames = $sname -match '^SourceDisksNames'
        $start = $secs[$i].Index + $secs[$i].Length
        $end = if (($i + 1) -lt $secs.Count) { $secs[$i + 1].Index } else { $text.Length }
        foreach ($line in ($text.Substring($start, $end - $start) -split "`r?`n")) {
            $l = $line.Trim()
            if ($l.Length -eq 0 -or $l[0] -eq ';') { continue }
            $eq = $l.IndexOf('=')
            if ($eq -lt 1) { continue }
            $key = $l.Substring(0, $eq).Trim().Trim('"')
            $parts = @($split.Split($l.Substring($eq + 1)) | ForEach-Object { $p = $_.Trim(); if ($p -notmatch '"') { $p = ($p -replace '\s*;.*$', '').Trim() }; $p })
            if ($isNames) { if ($parts.Count -ge 4) { $disks[$key] = $parts[3].Trim('"').Trim('\') } }
            else { $entries.Add([pscustomobject]@{ File = $key; Disk = $(if ($parts.Count -ge 1) { $parts[0] } else { '' }); Sub = $(if ($parts.Count -ge 2) { $parts[1].Trim('"').Trim('\') } else { '' }) }) }
        }
    }
    $seen = @{}
    $files = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($e in $entries) {
        if ($e.File -match '[%"*?<>|]') { continue }
        $pre = @()
        if ($disks.ContainsKey($e.Disk) -and $disks[$e.Disk]) { $pre += $disks[$e.Disk] }
        if ($e.Sub) { $pre += $e.Sub }
        $rel = ((@($pre) + $e.File) -join '\').TrimStart('\')
        if ($rel -match '\.\.') { continue }
        $leaf = Split-Path -Leaf $rel
        if ($leaf -ieq $self -or $leaf -match '(?i)\.cat$') { continue }
        $full = Join-Path $dir $rel
        $packed = $false
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $pfull = Join-Path (Split-Path -Parent $full) (Get-PackedName $leaf)
            if (Test-Path -LiteralPath $pfull -PathType Leaf) { $packed = $true; $full = $pfull }
            else { if (-not $missing.Contains($rel)) { $missing.Add($rel) }; continue }
        }
        $full = (Get-Item -LiteralPath $full -Force).FullName
        $lk = $leaf.ToLowerInvariant()
        if ($seen.ContainsKey($lk)) { continue }
        $seen[$lk] = $true
        $files.Add([pscustomobject]@{ Name = $leaf; Path = $full; Packed = $packed })
    }
    # a file only named in [SourceDisksFiles] is harmless when absent; one a copy section names is not
    $used = @()
    if ($missing.Count) {
        $other = New-Object Text.StringBuilder
        for ($i = 0; $i -lt $secs.Count; $i++) {
            if ($secs[$i].Groups[1].Value.Trim() -match '^SourceDisks(Names|Files)') { continue }
            $bs = $secs[$i].Index + $secs[$i].Length
            $be = if (($i + 1) -lt $secs.Count) { $secs[$i + 1].Index } else { $text.Length }
            [void]$other.Append($text.Substring($bs, $be - $bs)).Append("`n")
        }
        $ot = $other.ToString()
        foreach ($m in $missing) {
            $ml = $m.Substring($m.LastIndexOfAny([char[]]@([char]92, [char]47)) + 1)
            if ([regex]::IsMatch($ot, '(?im)^[^;\r\n]*(?<![A-Za-z0-9_.\-])' + [regex]::Escape($ml) + '(?![A-Za-z0-9_.\-])')) { $used += $m }
        }
    }
    return [pscustomobject]@{ Files = $files.ToArray(); Missing = $missing.ToArray(); MissingUsed = @($used) }
}
# Every file under the driver folder except .inf / .cat, sorted.
function Get-FolderFiles([string]$Dir) {
    return @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -ine '.inf' -and $_.Extension -ine '.cat' } | Sort-Object FullName |
             ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName } })
}
# Windows checks a compressed file (name.dl_) as the expanded file, so that is what goes into the catalog:
# expand.exe writes it to <stage>\_expanded\<name the INF uses>. Returns '' when that fails.
function Expand-PackedFile([string]$Src, [string]$Name, [string]$Stage) {
    $exe = if ($Script:ExpandExe) { $Script:ExpandExe } else { Join-Path $env:SystemRoot 'System32\expand.exe' }
    try {
        $xd = Join-Path $Stage '_expanded'
        New-Item -ItemType Directory -Force -Path $xd | Out-Null
        $dst = Join-Path $xd $Name
        if ((Test-Path -LiteralPath $dst -PathType Leaf) -and (Get-Item -LiteralPath $dst).Length -gt 0) { return $dst }
        $r = Invoke-Native $exe @($Src, $dst)
        Add-Log $r.Text
        if ((Test-Path -LiteralPath $dst -PathType Leaf) -and (Get-Item -LiteralPath $dst).Length -gt 0) { return $dst }
        # a cabinet with one file under another name: expand all of it, take that file
        $td = Join-Path $xd ('x_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $td | Out-Null
        $r = Invoke-Native $exe @($Src, '-F:*', $td)
        Add-Log $r.Text
        $one = Get-ChildItem -LiteralPath $td -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($one -and $one.Length -gt 0) { Move-Item -LiteralPath $one.FullName -Destination $dst -Force; return $dst }
    } catch { Add-Log "expand $Src : $($_.Exception.Message)" }
    return ''
}
# What goes into one folder's catalog: the staged INF files, the files they list (compressed ones expanded,
# under the name the INF uses) and every other file of the folder, each name once.
# $NameRx: file names the engine cannot take are skipped; $Lower: member names in lower case.
function Get-CatMembers([string]$Stage, [string]$Dir, [string[]]$Infs, [string[]]$Staged, [string]$NameRx, [bool]$Lower, [string]$Arch = 'amd64') {
    $mem = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $r = [pscustomobject]@{ Members = @(); InfCount = 0; FileCount = 0; ExtraCount = 0; PackedCount = 0; ExpandFailed = 0; Skipped = 0; Clashes = 0; Missing = 0; MissingUsed = @(); MB = 0.0 }
    $add = {
        param($Name, $Path, $Kind)
        $nm = if ($Lower) { $Name.ToLowerInvariant() } else { $Name }
        if ($NameRx -and $nm -notmatch $NameRx) { $r.Skipped++; return $false }
        $lk = $nm.ToLowerInvariant()
        if ($seen.ContainsKey($lk)) { if ($seen[$lk] -ne $Path) { $r.Clashes++ }; return $false }
        $seen[$lk] = $Path
        $mem.Add([pscustomobject]@{ Name = $nm; Path = $Path; Kind = $Kind })
        return $true
    }
    foreach ($s in @($Staged)) { if (& $add (Split-Path $s -Leaf) $s 'inf') { $r.InfCount++ } }
    $miss = @{}
    foreach ($inf in @($Infs)) {
        $l = Get-InfSourceFiles $inf $Arch
        foreach ($m in $l.Missing) { $miss[$m] = $true }
        $r.MissingUsed += @($l.MissingUsed)
        foreach ($f in $l.Files) {
            $p = $f.Path
            if ($f.Packed) {
                $nm = if ($Lower) { $f.Name.ToLowerInvariant() } else { $f.Name }
                if ($seen.ContainsKey($nm.ToLowerInvariant()) -or ($NameRx -and $nm -notmatch $NameRx)) { [void](& $add $f.Name $p 'file'); continue }
                $r.PackedCount++
                $x = Expand-PackedFile $p $f.Name $Stage
                if ($x) { $p = $x } else { $r.ExpandFailed++ }
            }
            [void](& $add $f.Name $p 'file')
        }
    }
    $listed = $mem.Count - $r.InfCount
    foreach ($f in (Get-FolderFiles $Dir)) { if (& $add $f.Name $f.Path 'file') { $r.ExtraCount++ } }
    $r.Members = $mem.ToArray()
    $r.FileCount = $listed + $r.ExtraCount
    $r.Missing = $miss.Count
    $r.MissingUsed = @($r.MissingUsed | Sort-Object -Unique)
    $sum = 0.0; foreach ($m in $r.Members) { try { $sum += (Get-Item -LiteralPath $m.Path).Length } catch { } }
    $r.MB = $sum / 1MB
    return $r
}
function Get-MemberNote($Info) {
    $s = '{0} member(s), {1:N0} MB: {2} INF + {3} file(s) the INF files list + {4} other file(s) of the folder' -f $Info.Members.Count, $Info.MB, $Info.InfCount, ($Info.FileCount - $Info.ExtraCount), $Info.ExtraCount
    if ($Info.PackedCount) {
        $s += '; {0} stored compressed (name.dl_): the expanded file is hashed under the name the INF uses' -f $Info.PackedCount
        if ($Info.ExpandFailed) { $s += ' ({0} could not be expanded - the compressed file is hashed instead)' -f $Info.ExpandFailed }
    }
    if ($Info.Skipped) { $s += '; {0} skipped (file name the engine cannot take)' -f $Info.Skipped }
    if ($Info.Clashes) { $s += '; {0} name clash(es), the first file kept' -f $Info.Clashes }
    if ($Info.Missing) { $s += '; {0} file(s) named in [SourceDisksFiles] are not in the folder' -f $Info.Missing }
    return $s
}
# One catalog per driver folder, named after it.
function Get-SharedCatName([string]$Dir) {
    $leaf = ((Split-Path -Leaf $Dir).ToLowerInvariant()) -replace '[^a-z0-9._\-]', '_'
    if (-not $leaf) { $leaf = 'driver' }
    return ($leaf + '_w10u.cat')
}
# The .cdf that makecat.exe reads: SHA-256, every member with its name and the Windows versions.
# INF files are named relative to the stage folder, where makecat runs and writes the catalog.
function New-MakeCatCdf([string]$Cat, $Members) {
    $os = @('6.0', '6.1', '6.2', '6.3', '6.4', '10.0')
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($x in @('[CatalogHeader]', "Name=$Cat", 'ResultDir=.', 'CatalogVersion=2', 'HashAlgorithms=SHA256', 'PageHashes=false', 'EncodingType=0x00010001')) { $l.Add($x) }
    for ($i = 0; $i -lt $os.Count; $i++) { $l.Add(('CATATTR{0}=0x10010001:OSAttr:2:{1}' -f ($i + 1), $os[$i])) }
    $l.Add('[CatalogFiles]')
    foreach ($m in @($Members)) {
        $tag = '<HASH>' + $m.Name
        $l.Add($tag + '=' + $(if ($m.Kind -eq 'inf') { $m.Name } else { $m.Path }))
        $l.Add($tag + 'ATTR1=0x10010001:File:' + $m.Name)
        for ($i = 0; $i -lt $os.Count; $i++) { $l.Add(('{0}ATTR{1}=0x10010001:OSAttr:2:{2}' -f $tag, ($i + 2), $os[$i])) }
    }
    return (($l -join "`r`n") + "`r`n")
}
# makecat.exe: installed Windows Kit or tools folder, else from Microsoft's NuGet packages.
function Get-MakeCat {
    $m = Find-Tool 'makecat.exe'
    if (-not $m) {
        Write-Step 'Getting makecat.exe (Windows SDK build tools / Windows Driver Kit)'
        $m = Get-FromNuGet 'makecat.exe' @('Microsoft.Windows.SDK.BuildTools', 'Microsoft.Windows.WDK.x64') '(?i)/x64/'
    }
    return $m
}
function Invoke-MakeCatGroups([string]$MakeCat, $Groups, [int]$Jobs) {
    $items = @()
    foreach ($g in @($Groups)) {
        $cdf = [IO.Path]::GetFileNameWithoutExtension($g.Cat) + '.cdf'
        # Windows PowerShell's default encoding is the ANSI code page, the one makecat reads a .cdf in
        [IO.File]::WriteAllText((Join-Path $g.Dir $cdf), (New-MakeCatCdf $g.Cat $g.Info.Members), [Text.Encoding]::Default)
        $items += [pscustomobject]@{ Dir = $g.Dir; WorkDir = $g.Dir; Label = $g.Label; Est = (2 + $g.Info.MB / 120.0); Args = @('-v', $cdf) }
    }
    $out = @(Invoke-ToolQueue $MakeCat $items ([math]::Max(1, [math]::Min(4, $Jobs))) 'MakeCat')
    for ($k = 0; $k -lt $items.Count; $k++) {
        $r = $out[$k]
        # makecat's exit code is not reliable: the catalog file tells (as in the signer)
        if (Test-Path -LiteralPath (Join-Path $Groups[$k].Dir $Groups[$k].Cat)) { $r.Code = 0 } elseif ($r.Code -eq 0) { $r.Code = 1 }
        # success: drop the line per member ("processing", "attribute", "opened")
        if ($r.Code -eq 0) { $r.Output = @($r.Output | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(attribute|processing|opened):' }); $r.Text = $r.Output -join "`r`n" }
        $Groups[$k].R = $r
    }
}
# ---- libwdi-style: the catalog is built with the CryptCAT API of wintrust.dll, following libwdi (pki.c):
# SHA-1 member hashes, PE files with SPC_PE_IMAGE_DATA, INF and other files with SPC_LINK.
function Get-NativeCatSource {
    return @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace W10U
{
    public static class NativeCat
    {
        [StructLayout(LayoutKind.Sequential)]
        struct BLOB { public uint cbData; public IntPtr pbData; }

        [StructLayout(LayoutKind.Sequential)]
        struct SIP_INDIRECT_DATA
        {
            public IntPtr DataObjId;
            public BLOB DataValue;
            public IntPtr AlgObjId;
            public BLOB AlgParams;
            public BLOB Digest;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PE_IMAGE_DATA
        {
            public uint FlagsCb;
            public IntPtr FlagsPb;
            public uint FlagsUnused;
            public IntPtr pFile;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CryptAcquireContextW(out IntPtr phProv, string pszContainer, string pszProvider, uint dwProvType, uint dwFlags);
        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool CryptReleaseContext(IntPtr hProv, uint dwFlags);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATOpen(string pwszFileName, uint fdwOpenFlags, IntPtr hProv, uint dwPublicVersion, uint dwEncodingType);
        [DllImport("wintrust.dll", SetLastError = true)]
        static extern bool CryptCATClose(IntPtr hCatalog);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATPutCatAttrInfo(IntPtr hCatalog, string pwszReferenceTag, uint dwAttrTypeAndAction, uint cbData, byte[] pbData);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATPutMemberInfo(IntPtr hCatalog, string pwszFileName, string pwszReferenceTag, ref Guid pgSubjectType, uint dwCertVersion, uint cbSIPIndirectData, IntPtr pbSIPIndirectData);
        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATPutAttrInfo(IntPtr hCatalog, IntPtr pCatMember, string pwszReferenceTag, uint dwAttrTypeAndAction, uint cbData, byte[] pbData);
        [DllImport("wintrust.dll", SetLastError = true)]
        static extern bool CryptCATPersistStore(IntPtr hCatalog);
        [DllImport("wintrust.dll", SetLastError = true)]
        static extern bool CryptCATAdminCalcHashFromFileHandle(IntPtr hFile, ref uint pcbHash, byte[] pbHash, uint dwFlags);
        [DllImport("crypt32.dll", SetLastError = true)]
        static extern bool CryptEncodeObject(uint dwCertEncodingType, [MarshalAs(UnmanagedType.LPStr)] string lpszStructType, IntPtr pvStructInfo, byte[] pbEncoded, ref uint pcbEncoded);

        const uint X509_ASN_ENCODING = 1;
        const uint CRYPTCAT_OPEN_CREATENEW = 1;
        const uint CATATTR = 0x10000000 | 0x1 | 0x10000;   // AUTHENTICATED | NAMEASCII | DATAASCII
        const uint PROV_RSA_FULL = 1;
        const uint CRYPT_VERIFYCONTEXT = 0xF0000000;
        const string OID_PE = "1.3.6.1.4.1.311.2.1.15";
        const string OID_CAB = "1.3.6.1.4.1.311.2.1.25";
        const string OID_SHA1 = "1.3.14.3.2.26";
        static readonly Guid FLAT_GUID = new Guid("DE351A42-8E59-11D0-8C47-00C04FC295EE");
        static readonly Guid PE_GUID = new Guid("C689AAB8-8E78-11D0-8C47-00C04FC295EE");

        public static bool IsPE(string path)
        {
            try
            {
                using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    byte[] b = new byte[64];
                    if (f.Read(b, 0, 64) < 64) return false;
                    if (b[0] != 0x4D || b[1] != 0x5A) return false;
                    int off = BitConverter.ToInt32(b, 60);
                    if (off < 0 || off > f.Length - 4) return false;
                    f.Seek(off, SeekOrigin.Begin);
                    byte[] s = new byte[4];
                    if (f.Read(s, 0, 4) < 4) return false;
                    return s[0] == 0x50 && s[1] == 0x45 && s[2] == 0 && s[3] == 0;
                }
            }
            catch (Exception) { return false; }
        }

        static byte[] UniZ(string s) { return Encoding.Unicode.GetBytes(s + "\0"); }

        public static string Create(string catPath, string hwid, string osString, string osAttr, string[] names, string[] paths, CatJob job)
        {
            IntPtr hProv = IntPtr.Zero;
            IntPtr hCat = IntPtr.Zero;
            try
            {
                if (File.Exists(catPath)) File.Delete(catPath);
                if (!CryptAcquireContextW(out hProv, null, null, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT))
                    return "CryptAcquireContext failed, Win32 error " + Marshal.GetLastWin32Error();
                hCat = CryptCATOpen(catPath, CRYPTCAT_OPEN_CREATENEW, hProv, 0, 0);
                if (hCat == IntPtr.Zero || hCat == new IntPtr(-1))
                {
                    int e = Marshal.GetLastWin32Error();
                    hCat = IntPtr.Zero;
                    return "CryptCATOpen failed, Win32 error " + e;
                }
                byte[] b;
                if (!String.IsNullOrEmpty(hwid))
                {
                    b = UniZ(hwid);
                    if (CryptCATPutCatAttrInfo(hCat, "HWID1", CATATTR, (uint)b.Length, b) == IntPtr.Zero)
                        return "Setting HWID1 failed, Win32 error " + Marshal.GetLastWin32Error();
                }
                if (!String.IsNullOrEmpty(osString))
                {
                    b = UniZ(osString);
                    if (CryptCATPutCatAttrInfo(hCat, "OS", CATATTR, (uint)b.Length, b) == IntPtr.Zero)
                        return "Setting OS failed, Win32 error " + Marshal.GetLastWin32Error();
                }
                for (int i = 0; i < names.Length; i++)
                {
                    string err = AddMember(hCat, names[i], paths[i], osAttr);
                    if (err != null) return names[i] + ": " + err;
                    if (job != null) job.Processed = i + 1;
                }
                if (!CryptCATPersistStore(hCat))
                    return "CryptCATPersistStore failed, Win32 error " + Marshal.GetLastWin32Error();
                return "";
            }
            finally
            {
                if (hCat != IntPtr.Zero) CryptCATClose(hCat);
                if (hProv != IntPtr.Zero) CryptReleaseContext(hProv, 0);
            }
        }

        static string AddMember(IntPtr hCat, string name, string path, string osAttr)
        {
            byte[] hash = new byte[20];
            uint cb = 20;
            bool pe = IsPE(path);
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                if (!CryptCATAdminCalcHashFromFileHandle(fs.SafeFileHandle.DangerousGetHandle(), ref cb, hash, 0))
                    return "hashing failed, Win32 error " + Marshal.GetLastWin32Error();
            }
            string hex = BitConverter.ToString(hash).Replace("-", "");

            IntPtr pLinkStr = IntPtr.Zero, pLink = IntPtr.Zero, pFlags = IntPtr.Zero, pImg = IntPtr.Zero;
            IntPtr pEnc = IntPtr.Zero, pOidData = IntPtr.Zero, pOidAlg = IntPtr.Zero, pDigest = IntPtr.Zero, pSip = IntPtr.Zero;
            try
            {
                // SPC_LINK { DWORD dwLinkChoice; union { LPWSTR pwszFile; ... } } - the union starts at pointer alignment
                pLinkStr = Marshal.StringToHGlobalUni("<<<Obsolete>>>");
                pLink = Marshal.AllocHGlobal(64);
                for (int i = 0; i < 64; i += 4) Marshal.WriteInt32(pLink, i, 0);
                Marshal.WriteInt32(pLink, 0, 3);                    // SPC_FILE_LINK_CHOICE
                Marshal.WriteIntPtr(pLink, IntPtr.Size, pLinkStr);  // pwszFile

                byte[] enc = new byte[256];
                uint cbEnc = (uint)enc.Length;
                if (pe)
                {
                    pFlags = Marshal.AllocHGlobal(1);
                    Marshal.WriteByte(pFlags, 0xA0);
                    PE_IMAGE_DATA img = new PE_IMAGE_DATA();
                    img.FlagsCb = 1;
                    img.FlagsPb = pFlags;
                    img.FlagsUnused = 0;
                    img.pFile = pLink;
                    pImg = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(PE_IMAGE_DATA)));
                    Marshal.StructureToPtr(img, pImg, false);
                    if (!CryptEncodeObject(X509_ASN_ENCODING, OID_PE, pImg, enc, ref cbEnc))
                        return "encoding SPC_PE_IMAGE_DATA failed, Win32 error " + Marshal.GetLastWin32Error();
                }
                else
                {
                    if (!CryptEncodeObject(X509_ASN_ENCODING, OID_CAB, pLink, enc, ref cbEnc))
                        return "encoding SPC_LINK failed, Win32 error " + Marshal.GetLastWin32Error();
                }

                pEnc = Marshal.AllocHGlobal((int)cbEnc);
                Marshal.Copy(enc, 0, pEnc, (int)cbEnc);
                pOidData = Marshal.StringToHGlobalAnsi(pe ? OID_PE : OID_CAB);
                pOidAlg = Marshal.StringToHGlobalAnsi(OID_SHA1);
                pDigest = Marshal.AllocHGlobal(20);
                Marshal.Copy(hash, 0, pDigest, 20);

                SIP_INDIRECT_DATA sip = new SIP_INDIRECT_DATA();
                sip.DataObjId = pOidData;
                sip.DataValue.cbData = cbEnc;
                sip.DataValue.pbData = pEnc;
                sip.AlgObjId = pOidAlg;
                sip.AlgParams.cbData = 0;
                sip.AlgParams.pbData = IntPtr.Zero;
                sip.Digest.cbData = 20;
                sip.Digest.pbData = pDigest;
                int sipSize = Marshal.SizeOf(typeof(SIP_INDIRECT_DATA));
                pSip = Marshal.AllocHGlobal(sipSize);
                Marshal.StructureToPtr(sip, pSip, false);

                Guid g = pe ? PE_GUID : FLAT_GUID;
                IntPtr member = CryptCATPutMemberInfo(hCat, null, hex, ref g, 0x200, (uint)sipSize, pSip);
                if (member == IntPtr.Zero)
                    return "CryptCATPutMemberInfo failed, Win32 error " + Marshal.GetLastWin32Error();

                byte[] b1 = UniZ(name.ToLowerInvariant());
                if (CryptCATPutAttrInfo(hCat, member, "File", CATATTR, (uint)b1.Length, b1) == IntPtr.Zero)
                    return "Setting File attribute failed, Win32 error " + Marshal.GetLastWin32Error();
                byte[] b2 = UniZ(osAttr);
                if (CryptCATPutAttrInfo(hCat, member, "OSAttr", CATATTR, (uint)b2.Length, b2) == IntPtr.Zero)
                    return "Setting OSAttr attribute failed, Win32 error " + Marshal.GetLastWin32Error();
                return null;
            }
            finally
            {
                if (pSip != IntPtr.Zero) Marshal.FreeHGlobal(pSip);
                if (pDigest != IntPtr.Zero) Marshal.FreeHGlobal(pDigest);
                if (pOidAlg != IntPtr.Zero) Marshal.FreeHGlobal(pOidAlg);
                if (pOidData != IntPtr.Zero) Marshal.FreeHGlobal(pOidData);
                if (pEnc != IntPtr.Zero) Marshal.FreeHGlobal(pEnc);
                if (pImg != IntPtr.Zero) Marshal.FreeHGlobal(pImg);
                if (pFlags != IntPtr.Zero) Marshal.FreeHGlobal(pFlags);
                if (pLink != IntPtr.Zero) Marshal.FreeHGlobal(pLink);
                if (pLinkStr != IntPtr.Zero) Marshal.FreeHGlobal(pLinkStr);
            }
        }
    }

    // NativeCat.Create on a thread of its own, so the job can show how many files are hashed.
    public class CatJob
    {
        public volatile bool Done;
        public string Error = "";
        public volatile int Processed;
        public int Total;
        string cat, hwid, os, osAttr;
        string[] names, paths;

        public CatJob(string cat, string hwid, string os, string osAttr, string[] names, string[] paths)
        {
            this.cat = cat; this.hwid = hwid; this.os = os; this.osAttr = osAttr;
            this.names = names; this.paths = paths; this.Total = names.Length;
        }

        public void Start()
        {
            Thread th = new Thread(new ThreadStart(Run));
            th.IsBackground = true;
            th.Start();
        }

        void Run()
        {
            try { Error = NativeCat.Create(cat, hwid, os, osAttr, names, paths, this); }
            catch (Exception ex) { Error = ex.GetType().Name + ": " + ex.Message; }
            Done = true;
        }
    }
}
'@
}
function Initialize-NativeCat {
    if (-not ('W10U.CatJob' -as [type])) { Add-Type -TypeDefinition (Get-NativeCatSource) -Language CSharp }
}
# Catalog attributes the native and WSL engines write (Windows 7 to 11, the image's architecture).
function Get-CatOs([string]$Engine, [string]$Arch) {
    $tok = switch ($Arch) { 'x86' { 'X86' } 'arm64' { 'ARM64' } default { 'X64' } }
    if ($Engine -eq 'gencat') {
        return [pscustomobject]@{ Os = ('7X64,8X64,_v100_X64,_v100_X64_RS5,_v100_X64_19H1,_v100_X64_Vb,_v100_X64_21H2,_v100_X64_22H2,_v100_X64_24H2' -replace 'X64', $tok); Attr = '2:6.1,2:6.2,2:6.3,2:6.4,2:10.0' }
    }
    return [pscustomobject]@{ Os = ('7_X64,8_X64,10_X64,10_RS5_X64,10_19H1_X64,10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64' -replace 'X64', $tok); Attr = '2:6.0,2:6.1,2:6.2,2:6.3,2:6.4,2:10.0' }
}
function Invoke-NativeCatGroups($Groups, [string]$Arch) {
    Initialize-NativeCat
    $os = Get-CatOs 'libwdi' $Arch
    foreach ($g in @($Groups)) {
        $t0 = Get-Date
        $catPath = Join-Path $g.Dir $g.Cat
        $job = [W10U.CatJob]::new($catPath, $g.Hwid, $os.Os, $os.Attr, [string[]]@($g.Info.Members | ForEach-Object { $_.Name }), [string[]]@($g.Info.Members | ForEach-Object { $_.Path }))
        $job.Start()
        $beat = 5
        while (-not $job.Done) {
            Start-Sleep -Milliseconds 200
            $e = (Get-Date) - $t0
            if ($Script:Sync) {
                $Script:Sync.Status = 'libwdi-style {0}  {1}  - {2} of {3} file(s) hashed' -f $g.Label, (Format-Span $e), $job.Processed, $job.Total
                if ($job.Total) { $Script:Sync.Pct = [math]::Min(99.0, 100.0 * $job.Processed / $job.Total) }
            }
            if ($e.TotalMinutes -ge $beat) { Add-Log ('libwdi-style {0} still running ({1}) - {2} of {3} file(s)' -f $g.Label, (Format-Span $e), $job.Processed, $job.Total); $beat += 5 }
        }
        $err = [string]$job.Error
        if (-not $err -and -not (Test-Path -LiteralPath $catPath)) { $err = 'the catalog file was not created' }
        if ($err) { Remove-Item -LiteralPath $catPath -Force -ErrorAction SilentlyContinue }
        $out = @($(if ($err) { $err } else { 'catalog written: {0} member(s)' -f $job.Total }))
        $g.R = [pscustomobject]@{ Code = $(if ($err) { 1 } else { 0 }); Output = $out; Text = ($out -join "`r`n"); Time = ((Get-Date) - $t0); Dir = $g.Dir }
    }
    if ($Script:Sync) { $Script:Sync.Status = ''; $Script:Sync.Pct = -1 }
}
# ---- generate-cat-file (LINBIT, GPL-2.0): its source, pinned to one commit and checked by SHA-256, is
# downloaded into the tools folder and built inside WSL (needs a Linux distribution with gcc and make).
function Get-GenCatPin {
    return [pscustomobject]@{
        Commit = '65ebf4de79a42b0a1104fbef37b1c207ff13e1e9'
        Sha256 = @{
            'generate-cat-file.c' = '45afc2c933849e5cb4dfd7eadd2300bac993e721dc8f4ac902eed5808845d607'
            'strip-pe-image.c'    = 'b5fe83eecea5d6ef4b6fb185a79069db9a468bda7e92d34f09e70df9ffccb8da'
            'gencat.sh'           = 'b922bd15f7be71ab07e9329ac593176cb37ee2dddefd0e0050e6eae2296882d1'
            'Makefile'            = '198357b8b2c4ecfd5b463fc2266621a9036c8663071c15819903425f182d7ae3'
        }
    }
}
function ConvertTo-ShQuoted([string]$S) { return ("'" + $S.Replace("'", "'\''") + "'") }
# Runs a shell script in WSL (stdin, UTF-8). Returns Code, Output, Text.
function Invoke-WslScript([string]$Text, [int]$TimeoutSec = 600) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = if ($Script:WslExe) { $Script:WslExe } else { 'wsl.exe' }
    $psi.Arguments = '-e sh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    Add-Log "EXEC $($psi.FileName) -e sh"
    $p = [Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $b = (New-Object Text.UTF8Encoding -ArgumentList $false).GetBytes(($Text -replace "`r`n", "`n"))
    $p.StandardInput.BaseStream.Write($b, 0, $b.Length); $p.StandardInput.Close()
    $late = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $late = $true; try { $p.Kill() } catch { }; [void]$p.WaitForExit(5000) }
    $lines = @((($o.Result + "`n" + $e.Result) -replace "`0", '') -split "`r?`n" | Where-Object { $_.Trim() })
    if ($late) { $lines += "(stopped after $TimeoutSec s)" }
    $code = if ($late) { -1 } else { [int]$p.ExitCode }
    return [pscustomobject]@{ Code = $code; Output = $lines; Text = ($lines -join "`r`n") }
}
function Initialize-GenCat {
    $pin = Get-GenCatPin
    try { $chk = Invoke-WslScript "echo W10U_WSL_OK`nuname -sr`n" 120 } catch { $chk = [pscustomobject]@{ Text = $_.Exception.Message; Output = @() } }
    if ($chk.Text -notmatch 'W10U_WSL_OK') { throw ('WSL is not available or has no Linux distribution (run "wsl --install" as administrator). ' + $chk.Text).Trim() }
    Write-Info ('WSL: ' + @($chk.Output | Where-Object { $_ -notmatch 'W10U_WSL_OK' })[0])
    $src = Join-Path $ToolsDir 'gencat\src'
    $ok = { foreach ($k in $pin.Sha256.Keys) { $f = Join-Path $src $k; if (-not (Test-Path -LiteralPath $f) -or (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pin.Sha256[$k]) { return $false } }; return $true }
    if (-not (& $ok)) {
        Write-Step 'Getting generate-cat-file (LINBIT, GPL-2.0) - source, pinned commit'
        New-Item -ItemType Directory -Force -Path $src, (Join-Path $ToolsDir 'download') | Out-Null
        $zip = Join-Path $ToolsDir 'download\generate-cat-file.zip'
        Invoke-WebRequest -Uri "https://github.com/LINBIT/generate-cat-file/archive/$($pin.Commit).zip" -OutFile $zip -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($x in $z.Entries) {
                if (@($x.FullName.Split('/')).Count -eq 2 -and ($pin.Sha256.ContainsKey($x.Name) -or $x.Name -eq 'COPYING')) {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($x, (Join-Path $src $x.Name), $true)
                }
            }
        } finally { $z.Dispose() }
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if (-not (& $ok)) { throw 'The generate-cat-file source failed the SHA-256 check (not the pinned commit) - nothing was built.' }
        Write-Ok 'generate-cat-file source verified (SHA-256)'
    }
    $build = @'
set -e
SRC="$(wslpath -a @SRC@)"
DST="$HOME/.w10u-gencat"
if [ -x "$DST/generate-cat-file" ] && [ -x "$DST/strip-pe-image" ] && [ -f "$DST/gencat.sh" ] && [ "$(cat "$DST/COMMIT" 2>/dev/null)" = "@COMMIT@" ]; then echo W10U_BUILD_OK; exit 0; fi
for t in gcc make sha1sum getopt bash sort cut tr basename dirname sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing inside WSL: $t (sudo apt install build-essential)"; exit 90; }
done
rm -rf "$DST"; mkdir -p "$DST"
cp "$SRC/generate-cat-file.c" "$SRC/strip-pe-image.c" "$SRC/gencat.sh" "$SRC/Makefile" "$DST/"
cd "$DST"
sed -i 's/\r$//' gencat.sh Makefile generate-cat-file.c strip-pe-image.c
make >build.log 2>&1 || { echo "build failed"; tail -n 20 build.log; exit 94; }
chmod +x gencat.sh generate-cat-file strip-pe-image
echo "@COMMIT@" > COMMIT
echo W10U_BUILD_OK
'@
    $r = Invoke-WslScript ($build.Replace('@SRC@', (ConvertTo-ShQuoted $src)).Replace('@COMMIT@', $pin.Commit)) 900
    Add-Log $r.Text
    if ($r.Text -notmatch 'W10U_BUILD_OK') { throw ('Building generate-cat-file inside WSL failed: ' + $r.Text).Trim() }
    Write-Info 'generate-cat-file: built inside WSL'
}
function Invoke-GenCatGroups($Groups, [string]$Arch) {
    $os = Get-CatOs 'gencat' $Arch
    $tpl = @'
set -e
D="$HOME/.w10u-gencat"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
@LINKS@cd "$W"
bash "$D/gencat.sh" -o "$W/out.cat" -h @HWID@ -O @OS@ -A @OSATTR@ @NAMES@ </dev/null
cp "$W/out.cat" "$(wslpath -a @OUTCAT@)"
echo W10U_RUN_OK
'@
    foreach ($g in @($Groups)) {
        $t0 = Get-Date
        $links = New-Object Text.StringBuilder
        foreach ($m in $g.Info.Members) { [void]$links.Append(('ln -s "$(wslpath -a {0})" "$W/{1}"' -f (ConvertTo-ShQuoted $m.Path), $m.Name)).Append("`n") }
        $sh = $tpl.Replace('@LINKS@', $links.ToString()).Replace('@HWID@', (ConvertTo-ShQuoted $(if ($g.Hwid) { $g.Hwid } else { 'w10u' }))).Replace('@OS@', (ConvertTo-ShQuoted $os.Os)).Replace('@OSATTR@', (ConvertTo-ShQuoted $os.Attr))
        $sh = $sh.Replace('@NAMES@', (@($g.Info.Members | ForEach-Object { $_.Name }) -join ' ')).Replace('@OUTCAT@', (ConvertTo-ShQuoted (Join-Path $g.Dir $g.Cat)))
        if ($Script:Sync) { $Script:Sync.Status = 'generate-cat-file (WSL) {0} - {1} member(s), {2:N0} MB' -f $g.Label, $g.Info.Members.Count, $g.Info.MB }
        $r = Invoke-WslScript $sh 1800
        if ($r.Text -match 'W10U_RUN_OK' -and (Test-Path -LiteralPath (Join-Path $g.Dir $g.Cat))) { $r.Code = 0 } elseif ($r.Code -eq 0) { $r.Code = 1 }
        $g.R = [pscustomobject]@{ Code = $r.Code; Output = $r.Output; Text = $r.Text; Time = ((Get-Date) - $t0); Dir = $g.Dir }
    }
    if ($Script:Sync) { $Script:Sync.Status = '' }
}
# Finds / downloads / builds what an engine needs: the makecat.exe path, or a marker.
function Initialize-SignEngine([string]$Engine) {
    switch ($Engine) {
        'makecat' { $m = Get-MakeCat; if (-not $m) { throw 'makecat.exe could not be found or downloaded (see the lines above).' }; Write-Info "MakeCat : $m"; return $m }
        'libwdi'  { Initialize-NativeCat; return 'native' }
        'gencat'  { Initialize-GenCat; return 'wsl' }
    }
    return ''
}
# MakeCat / libwdi-style / generate-cat-file for the folders in $Todo (the work items of Invoke-SignFolder).
# Each folder is prepared in <Root>~stage\gN: its INF files pointing at <folder>_w10u.cat (+ expanded
# copies of compressed files). The package changes only once its catalog is built: then the INF files and
# the catalog are copied in, and the item gets Cats / Check / Runs / Engine. Returns the items it could
# not build a catalog for - Inf2Cat builds theirs.
function Invoke-CatalogEngine([string]$Engine, [string]$Tool, $Todo, [bool]$Isolate, [int]$Jobs, [string]$StageBase, [string]$Arch) {
    $name = Get-SignEngineName $Engine
    $infArch = switch ($Arch) { 'x86' { 'x86' } 'arm64' { 'arm64' } default { 'amd64' } }
    $rx = switch ($Engine) { 'makecat' { '^[A-Za-z0-9._\-]+$' } 'gencat' { '^[a-z0-9._\-]+$' } default { '' } }
    $groups = @(); $back = @()
    $n = 0
    foreach ($t in @($Todo)) {
        $n++
        Write-Sub ('{0}  ({1}, folder {2} of {3})' -f $t.Rel, $name, $n, @($Todo).Count)
        $cat = Get-SharedCatName $t.Pkg.Dir
        $infs = @(if ($Isolate) { $t.Need } else { $t.WithCat })
        # an INF already pointing at that catalog name (signed by this tool before) has to stay in it
        $infs = @($infs + @($t.WithCat | Where-Object { $infs -notcontains $_ -and @(Get-InfCatalogs $_) -contains $cat }))
        try {
            $sd = Join-Path $StageBase ('g{0}' -f $n)
            New-Item -ItemType Directory -Force -Path $sd | Out-Null
            $staged = @()
            foreach ($inf in $infs) { $s = Join-Path $sd (Split-Path $inf -Leaf); Set-InfCatalog $inf $s $cat; $staged += $s }
            $info = Get-CatMembers $sd $t.Pkg.Dir $infs $staged $rx ($Engine -eq 'gencat') $infArch
            $hw = ''
            foreach ($inf in $infs) { foreach ($id in (Get-InfDeviceIds $inf)) { $hw = $id.ToLowerInvariant(); break }; if ($hw) { break } }
            $groups += [pscustomobject]@{ T = $t; Dir = $sd; Cat = $cat; Infs = $infs; Staged = $staged; Info = $info; Label = $t.Rel; Hwid = $hw; R = $null }
            $what = if ($infs.Count -lt $t.WithCat.Count) { '{0} of {1} INF file(s) point at it - the others keep their signature' -f $infs.Count, $t.WithCat.Count } else { 'all {0} INF file(s) point at it' -f $infs.Count }
            Write-Info ('one catalog for the folder, {0}: {1}' -f $cat, $what)
            Write-Info (Get-MemberNote $info)
            if (@($info.MissingUsed).Count) { Write-Warn ('{0} file(s) the INF files copy are not in the folder ({1}) - no catalog can hold their hash, Windows will refuse the driver' -f @($info.MissingUsed).Count, ((@($info.MissingUsed) | Select-Object -First 3) -join ', ')) }
        } catch {
            Write-Warn "$($t.Rel): $name could not be prepared ($($_.Exception.Message)) - Inf2Cat builds its catalog"
            $back += $t
        }
    }
    if ($groups.Count) {
        $mb = 0.0; foreach ($g in $groups) { $mb += $g.Info.MB }
        Write-Info ('{0}: {1} catalog(s), {2:N0} MB to hash' -f $name, $groups.Count, $mb)
        switch ($Engine) {
            'makecat' { Invoke-MakeCatGroups $Tool $groups $Jobs }
            'libwdi'  { Invoke-NativeCatGroups $groups $Arch }
            'gencat'  { Invoke-GenCatGroups $groups $Arch }
        }
    }
    foreach ($g in $groups) {
        $t = $g.T
        $built = Join-Path $g.Dir $g.Cat
        Add-Log ("[$($g.Label)] $name exit $($g.R.Code) after $(Format-Span $g.R.Time)`r`n" + $g.R.Text)
        if ($g.R.Code -ne 0 -or -not (Test-Path -LiteralPath $built)) {
            Write-Warn "$($t.Rel): $name could not build the catalog - Inf2Cat builds it instead"
            @($g.R.Output | Where-Object { $_.Trim() } | Select-Object -Last 3) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
            $back += $t; continue
        }
        for ($k = 0; $k -lt $g.Infs.Count; $k++) { Copy-Item -LiteralPath $g.Staged[$k] -Destination $g.Infs[$k] -Force }
        $dst = Join-Path $t.Pkg.Dir $g.Cat
        Copy-Item -LiteralPath $built -Destination $dst -Force
        $t.Cats = @($dst); $t.Check = $g.Infs; $t.Engine = $Engine; $t.Staged = $true
        $t.Runs = @([pscustomobject]@{ Dir = $g.Dir; Label = $g.Label; Infs = $g.Infs.Count; Est = 0; R = $g.R })
    }
    return $back
}
#endregion


#region ---------------------------------------------------------------- install check: helpers
$Script:UnattendNs = 'urn:schemas-microsoft-com:unattend'
$Script:WcmNs      = 'http://schemas.microsoft.com/WMIConfig/2002/State'
# Generic install keys (they pick an edition, they don't activate)
$Script:GenericKeys = @{
    'YTMG3-N6DKC-DKB77-7M9GQ-8MKC8' = 'Core'; '4CPRK-NM3K3-X6XXQ-RXX86-WXCHW' = 'CoreN'; 'BT79Q-G7N6G-PGBYW-4YWX6-6F4BT' = 'CoreSingleLanguage'
    'VK7JG-NPHTM-C97JM-9MPGT-3V66T' = 'Professional'; '2B87N-8KFHP-DKV6R-Y2C8J-PKCKT' = 'ProfessionalN'
    'DXG7C-N36C4-C4HTG-X4T3X-2YV77' = 'ProfessionalWorkstation'; 'YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY' = 'Education'
    'NPPR9-FWDCX-D2C8J-H872K-2YT43' = 'Enterprise'
}
$Script:InstallerRx = '(?i)\b(pnputil|drvload|dpinst|devcon)\b|/add-driver'

function Add-Finding([string]$Level, [string]$Area, [string]$Text, [string]$Fix = '', [string]$FixText = '') {
    $Script:Findings.Add([pscustomobject]@{ Level = $Level; Area = $Area; Finding = $Text; Fix = $Fix; FixText = $FixText })
}
function Get-UnattendDoc([string]$File) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($File)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('u', $Script:UnattendNs)
    $ns.AddNamespace('wcm', $Script:WcmNs)
    return @{ Doc = $doc; Ns = $ns }
}
function Get-XNodes($X, [string]$XPath) { return @($X.Doc.SelectNodes($XPath, $X.Ns)) }
function Get-XText($X, $Node, [string]$Child) {
    $n = $Node.SelectSingleNode($Child, $X.Ns)
    if ($n) { return $n.InnerText.Trim() }
    return ''
}
function Get-XPass($Node) {
    $p = $Node
    while ($p -and $p.LocalName -ne 'settings') { $p = $p.ParentNode }
    if ($p) { return [string]$p.GetAttribute('pass') }
    return ''
}
# Editions in the ISO that will be built (index = position in the new install.wim)
function Get-FinalEditions {
    $wim = Join-Path $Script:P.Media 'sources\install.wim'
    if ($Script:S.Serviced -and (Test-Path -LiteralPath $wim)) {
        try { return @(Get-ImageList $wim) } catch { }
    }
    $imgs = @($Script:S.Images)
    $sel = @($Script:S.Selected)
    $keep = if ($Script:Cfg.KeepOnlySelected -and $sel.Count -gt 0) { @($imgs | Where-Object { $sel -contains [int]$_.Index }) } else { $imgs }
    $n = 0
    return @(foreach ($i in $keep) { $n++; [ordered]@{ Index = $n; Name = $i.Name; Edition = $i.Edition; Arch = $i.Arch; Langs = $i.Langs; Size = $i.Size } })
}
function Test-FirmwareOemKey {
    if ($null -eq $Script:OemKeyHere) {
        $Script:OemKeyHere = $false
        try { $Script:OemKeyHere = [bool]((Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop).OA3xOriginalProductKey) } catch { }
    }
    return $Script:OemKeyHere
}
# What will be inside sources\$OEM$ once the ISO is built (your folder + generated files)
function Get-OemDriverRoots([string]$OemDir, $Signed) {
    $one = Join-Path $OemDir '$1'
    if (-not (Test-Path -LiteralPath $one)) { return @() }
    $skip = @(foreach ($x in @($Signed)) { (([string]$x.InstallDir) -replace '^[A-Za-z]:\\?', '').ToLower() })
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $one -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue)) {
        $rel = $f.DirectoryName.Substring($one.Length).TrimStart('\', '/')
        $seg = @($rel -split '[\\/]' | Where-Object { $_ })
        $root = if ($seg.Count -ge 2) { $seg[0] + '\' + $seg[1] } elseif ($seg.Count -eq 1) { $seg[0] } else { '' }
        if ($root -cmatch '[^\x20-\x7E]') { Add-Log "OEM driver folder skipped (non-ASCII name cannot go into the .cmd script): $root"; continue }
        if ($root -and $skip -notcontains $root.ToLower() -and -not $roots.Contains($root)) { $roots.Add($root) }
    }
    return @($roots)
}
function Get-OemContext {
    $S = $Script:S
    $user = $null
    if ($S.Oem -and $S.Oem.Source -and (Test-Path -LiteralPath $S.Oem.Source)) { $user = [string]$S.Oem.Source }
    $signed = @($S.Signed | Where-Object { $_ -and $_.Path -and (Test-Path -LiteralPath $_.Path) })
    $roots = @()
    if ($user -and $Script:Cfg.InstallOemDrivers) { $roots = @(Get-OemDriverRoots $user $signed) }
    $script = ($signed.Count -gt 0 -or $roots.Count -gt 0)
    $gen = @{}
    if ($script) {
        $gen['$$\setup\scripts\setupcomplete-drivers.cmd'] = $true
        $gen['$$\setup\scripts\setupcomplete.cmd'] = $true
        $gen['$1\drivers\driversigning.cer'] = $true
    }
    return @{
        User = $user; Signed = $signed; Roots = $roots; Generated = $gen; DriverScript = $script; Fallback = $false
        PkgDirs = @(foreach ($x in $signed) { '$1\' + (([string]$x.InstallDir) -replace '^[A-Za-z]:\\?', '') })
        Installers = New-Object System.Collections.Generic.List[object]; OemInfDirs = @()
        PkgRefs = New-Object System.Collections.Generic.List[string]
    }
}
function Test-OemRel($Ctx, [string]$Rel) {
    $r = $Rel.TrimStart('\')
    if ($Ctx.Generated.ContainsKey($r.ToLower())) { return $true }
    foreach ($d in $Ctx.PkgDirs) { if ($r -ieq $d -or $r.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    if ($Ctx.User) { return (Test-Path -LiteralPath (Join-Path $Ctx.User $r)) }
    return $false
}
# File paths used in a command / script line, mapped into $OEM$ ($1 = C:\, $$ = C:\Windows)
function Get-CommandRefs([string]$Text, [string]$ScriptDirRel, [switch]$Dirs) {
    $t = $Text
    if ($ScriptDirRel) { $t = [regex]::Replace($t, '(?i)%~dp0\\?', '%OEMDIR%\') }
    $head = '(%SystemDrive%|%WINDIR%|%SystemRoot%|%OEMDIR%|(?<![\w%])[A-Za-z]:)'
    $ext = if ($Dirs) { '' } else { '\.(?:cmd|bat|ps1|exe|reg|vbs|msi|inf|xml|cer|ini|json|txt|zip)' }
    $rxQ = '"' + $head + '\\([^"]*?' + $ext + ')"'
    $rxU = '(?<!")' + $head + '\\([^\s"<>|&%:]*' + $(if ($Dirs) { '' } else { '?' }) + $ext + ')' + $(if ($Dirs) { '' } else { '(?=$|[\s"''),;])' })
    $out = @()
    $seen = @{}
    foreach ($rx in @($rxQ, $rxU)) {
        foreach ($m in [regex]::Matches($t, $rx)) {
            $h = $m.Groups[1].Value; $rest = $m.Groups[2].Value.TrimEnd('\')
            $raw = $h + '\' + $rest
            if ($seen.ContainsKey($raw.ToLower())) { continue }
            $seen[$raw.ToLower()] = $true
            $rel = $null; $kind = 'oem'
            if ($h -ieq '%OEMDIR%') { $rel = $ScriptDirRel + '\' + $rest; $raw = '%~dp0' + $rest }
            elseif ($h -ieq '%SystemDrive%' -or $h -ieq 'C:') { if ($rest -match '(?i)^Windows\\(.+)$') { $rel = '$$\' + $Matches[1] } elseif ($rest -ieq 'Windows') { $rel = '$$' } else { $rel = '$1\' + $rest } }
            elseif ($h -ieq '%WINDIR%' -or $h -ieq '%SystemRoot%') { $rel = '$$\' + $rest }
            elseif ($h -ieq 'X:') { $kind = 'winpe' }
            else { $kind = 'drive' }
            $out += [pscustomobject]@{ Raw = $raw; Rel = $rel; Kind = $kind }
        }
    }
    return $out
}
# Catalog state of one INF: ok | own | unchecked | mismatch | untrusted | catalog-missing | no-catalog | unsigned | other-cert
function Get-DriverSignState([string]$Inf, [string]$OwnThumb) {
    $cats = @(Get-InfCatalogs $Inf)
    if ($cats.Count -eq 0) { return 'no-catalog' }
    $dir = Split-Path -Parent $Inf
    $own = $false
    foreach ($c in $cats) {
        $cp = Join-Path $dir $c
        if (-not (Test-Path -LiteralPath $cp)) { return 'catalog-missing' }
        $sig = $null
        try { $sig = Get-AuthenticodeSignature -LiteralPath $cp } catch { }
        if ($sig -and $sig.SignerCertificate -and $sig.SignerCertificate.Subject -eq $Script:CertSubject) {
            if (-not $OwnThumb -or $sig.SignerCertificate.Thumbprint -ne $OwnThumb) { return 'other-cert' }
            $own = $true
        }
        if ($Script:SignTool) {
            $v = Get-VerifyState $cp $Inf
            if ($v -ne 'ok') { return $v }
        } elseif (-not $own -and (-not $sig -or $sig.Status -ne 'Valid')) { return 'unsigned' }
    }
    if ($own) { return 'own' }
    if ($Script:SignTool) { return 'ok' }
    return 'unchecked'
}
$Script:BadSign = @('mismatch', 'untrusted', 'catalog-missing', 'no-catalog', 'unsigned', 'other-cert')
function Get-SignText([string]$State) {
    switch ($State) {
        'mismatch'        { 'the INF was edited after signing, so its catalog no longer matches' }
        'untrusted'       { 'its catalog is signed with a certificate Windows does not trust (NVCleanstall''s own, for example)' }
        'catalog-missing' { 'its .cat catalog file is missing' }
        'no-catalog'      { 'the INF names no catalog file, so it is unsigned' }
        'unsigned'        { 'its catalog is not validly signed' }
        'other-cert'      { 'signed with a different "Custom Driver Signing" certificate than yours' }
        default           { $State }
    }
}
#endregion

#region ---------------------------------------------------------------- install check: scripts in $OEM$
function Test-SetupScript($Ctx, [string]$Rel, [string]$Why, [hashtable]$Seen, [bool]$Hidden, [int]$Depth = 0, [bool]$WithArgs = $false) {
    $key = $Rel.ToLower()
    if ($Seen.ContainsKey($key)) { return }
    $Seen[$key] = $true
    if (-not $Ctx.User) { return }
    $full = Join-Path $Ctx.User $Rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
    $bytes = [IO.File]::ReadAllBytes($full)
    $name = '{0} ({1})' -f $Rel, $Why
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        Add-Finding 'Error' 'Scripts' ('{0} is saved as UTF-16 - cmd.exe cannot run it. Save it as ANSI or UTF-8 without BOM.' -f $name) '' 'Re-save the file (Notepad: Save as > Encoding ANSI)'
        return
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Add-Finding 'Warning' 'Scripts' ('{0} starts with a UTF-8 BOM - cmd.exe misreads its first line (for example @echo off).' -f $name) '' 'Re-save it as ANSI / UTF-8 without BOM'
    }
    $text = [Text.Encoding]::Default.GetString($bytes)
    if ($text.Contains("`n") -and -not $text.Contains("`r`n")) {
        Add-Finding 'Warning' 'Scripts' ('{0} has Unix (LF) line endings - labels and goto can break in cmd.exe.' -f $name) '' 'Re-save it with Windows (CRLF) line endings'
    }
    Test-ScriptText $Ctx $Rel $name $text $Hidden $WithArgs $Seen $Depth $false
}
# Checks the lines of a cmd / PowerShell script that runs during setup.
#   $Hidden   - runs without a visible window (SetupComplete, specialize, SYSTEM task): prompts hang setup
#   $WithArgs - called with parameters: menu scripts normally skip their prompts then
function Test-ScriptText($Ctx, [string]$Rel, [string]$Name, [string]$Text, [bool]$Hidden, [bool]$WithArgs, [hashtable]$Seen, [int]$Depth, [bool]$IsPs) {
    $dir = if ($Rel) { Split-Path $Rel -Parent } else { '' }
    $waitRx = if ($IsPs) { '(?i)\bRead-Host\b|\[Console\]::ReadKey|^\s*pause\b' } else { '(?i)(^|[&|(]\s*)@?(pause\b|set\s+/p\b|choice\b(?!.*\s/t))' }
    $bootRx = if ($IsPs) { '(?i)\b(Restart|Stop)-Computer\b|\bshutdown(\.exe)?\s+[/-][rsg]\b' } else { '(?i)\bshutdown(\.exe)?\s+[/-][rsg]\b' }
    $no = 0
    $waits = @(); $restarts = @(); $drives = @(); $missing = @(); $calls = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $no++
        $l = $line.Trim()
        if (-not $l -or $l -match '^(?i)(@?rem\b|::|#)') { continue }
        if ($Hidden -and $l -match $waitRx) { $waits += $no }
        if ($Hidden -and $l -match $bootRx) { $restarts += $no }
        if ($l -match $Script:InstallerRx) { $Ctx.Installers.Add([pscustomobject]@{ Text = $l; Dir = $dir }) }
        foreach ($r in @(Get-CommandRefs $l $dir)) {
            if ($r.Kind -eq 'drive') { if ($drives -notcontains $r.Raw) { $drives += $r.Raw }; continue }
            Add-PkgRef $Ctx $r $Name
            if (-not (Test-RefWorthChecking $Ctx $r.Rel)) { continue }
            if (-not (Test-OemRel $Ctx $r.Rel)) { if ($missing -notcontains $r.Raw) { $missing += $r.Raw } }
            elseif ($Depth -lt 2 -and $r.Rel -match '(?i)\.(cmd|bat)$' -and -not @($calls | Where-Object { $_.Rel -eq $r.Rel }).Count) {
                $calls += [pscustomobject]@{ Rel = $r.Rel; Args = (Test-CalledWithArgs $l $r.Rel) }
            }
        }
    }
    # one finding per script and problem, not one per line
    $lines = { param($l) $t = (@($l | Select-Object -First 8) -join ', '); if (@($l).Count -gt 8) { $t += ', ...' }; $t }
    if ($waits.Count -and $WithArgs) {
        Add-Finding 'Info' 'Scripts' ('{0} has {1} prompt line(s), but it is called with parameters - menu scripts normally skip their prompts then. Make sure those parameters run it without questions.' -f $Name, $waits.Count)
    } elseif ($waits.Count) {
        Add-Finding 'Warning' 'Scripts' ('{0} waits for input on {1} line(s) (line {2}). It runs hidden during setup, so setup hangs there.' -f $Name, $waits.Count, (& $lines $waits)) '' 'Remove the prompts, call it with its unattended parameters, or run it from FirstLogonCommands (visible) instead'
    }
    if ($restarts.Count -and -not $WithArgs) {
        Add-Finding 'Warning' 'Scripts' ('{0} restarts the PC (line {1}) - that can cut setup short.' -f $Name, (& $lines $restarts)) '' 'Restart from FirstLogonCommands instead'
    }
    if ($drives.Count) {
        Add-Finding 'Warning' 'Scripts' ('{0} uses fixed drive letters ({1}) - USB stick and disk letters differ between PCs.' -f $Name, (& $lines $drives)) '' 'Use %SystemDrive%, %~dp0 or search for the drive'
    }
    if ($missing.Count) {
        Add-Finding 'Warning' 'Scripts' ('{0} uses files that will not exist: {1}' -f $Name, (& $lines $missing)) '' 'Add the files to $OEM$ or fix the paths'
    }
    foreach ($c in $calls) { Test-SetupScript $Ctx $c.Rel ('called by ' + (Split-Path $Rel -Leaf)) $Seen $Hidden ($Depth + 1) $c.Args }
}
# "call script.cmd /switch" -> $true
function Test-CalledWithArgs([string]$Line, [string]$Rel) {
    $leaf = Split-Path $Rel -Leaf
    $i = $Line.IndexOf($leaf, [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { return $false }
    $after = $Line.Substring($i + $leaf.Length).TrimStart('"', "'").Trim()
    return ($after -match '^[/-]?\w' -and $after -notmatch '^(>|2>|&|\|)')
}
# Only paths that a person would put into $OEM$ are checked; Windows' own folders
# (System32, Sysnative, Panther, Temp, Program Files, ...) and paths built from variables are not.
function Test-RefWorthChecking($Ctx, [string]$Rel) {
    if (-not $Rel -or $Rel -match '[\*%]|\$env') { return $false }
    if ($Rel -match '(?i)^\$\$\\([^\\]+)\\') {
        $top = $Matches[1]
        if ($top -ieq 'Setup') { return $true }
        if ($Ctx.User -and (Test-Path -LiteralPath (Join-Path (Join-Path $Ctx.User '$$') $top))) { return $true }
        return $false
    }
    if ($Rel -match '(?i)^\$\$(\\[^\\]*)?$') { return $false }
    if ($Rel -match '(?i)^\$1\\(Program Files|ProgramData|Users|PerfLogs|Recovery|\$Recycle\.Bin)\b') { return $false }
    return $true
}
# Remember when something uses a file inside a signed package (e.g. C:\Drivers\NVIDIA\setup.exe)
function Add-PkgRef($Ctx, $Ref, [string]$Where) {
    if (-not $Ref.Rel) { return }
    foreach ($d in $Ctx.PkgDirs) {
        if ($Ref.Rel.StartsWith($d + '\', [StringComparison]::OrdinalIgnoreCase)) { $Ctx.PkgRefs.Add(('{0} uses {1}' -f $Where, $Ref.Raw)); return }
    }
}
# Files the answer file writes itself (<Extensions><File path="...">, used by the autounattend generator)
function Get-EmbeddedFiles {
    if (-not $Script:S.Unattend -or -not (Test-Path -LiteralPath $Script:P.Unattend)) { return @() }
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($Script:P.Unattend)
        return @(foreach ($n in $doc.SelectNodes("//*[local-name()='File' and @path]")) { [pscustomobject]@{ Path = $n.GetAttribute('path'); Text = $n.InnerText } })
    } catch { return @() }
}
function ConvertTo-OemRel([string]$Path) {
    $r = @(Get-CommandRefs ('"' + $Path + '"') '') | Select-Object -First 1
    if ($r) { return $r.Rel }
    return $null
}
function Test-EmbeddedScripts($Ctx, $X, $Emb, [hashtable]$Seen) {
    if (-not $X -or @($Emb).Count -eq 0) { return }
    $visible = (@(Get-XNodes $X '//u:SynchronousCommand/u:CommandLine | //u:AsynchronousCommand/u:CommandLine') | ForEach-Object { $_.InnerText }) -join "`n"
    $n = 0
    foreach ($f in $Emb) {
        $isPs = $f.Path -match '(?i)\.ps1$'
        if (-not $isPs -and $f.Path -notmatch '(?i)\.(cmd|bat)$') { continue }
        $n++
        $hidden = $visible -notmatch [regex]::Escape($f.Path)
        Test-ScriptText $Ctx (ConvertTo-OemRel $f.Path) ('{0} (written by the answer file)' -f $f.Path) $f.Text $hidden $false $Seen 0 $isPs
    }
    if ($n) { Add-Finding 'OK' 'Answer file' ('{0} script(s) embedded in the answer file were checked too.' -f $n) }
}
#endregion

#region ---------------------------------------------------------------- install check: $OEM$, drivers, signed packages
function Test-OemFolder($Ctx, [string]$OwnThumb, [string]$Arch) {
    $u = $Ctx.User
    $S = $Script:S
    if ($S.Oem -and $S.Oem.Source -and -not $u) { Add-Finding 'Error' '$OEM$' ('Your $OEM$ folder is gone: {0}' -f $S.Oem.Source) '' 'Choose it again on page 6' }
    if (-not $u) {
        if ($Ctx.DriverScript) { Add-Finding 'OK' '$OEM$' 'The ISO gets a $OEM$ folder with your signed driver package(s) and SetupComplete-drivers.cmd.' }
        else { Add-Finding 'Info' '$OEM$' 'No $OEM$ folder - nothing extra is copied to C:\.' }
        return
    }
    foreach ($i in @(Get-ChildItem -LiteralPath $u -Force -ErrorAction SilentlyContinue)) {
        if ($i.PSIsContainer -and @('$$', '$1') -notcontains $i.Name) {
            Add-Finding 'Warning' '$OEM$' ('Folder "{0}" at the top of $OEM$ is ignored by Windows Setup - only $$ (C:\Windows) and $1 (C:\) are copied.' -f $i.Name) '' 'Move its contents into $1 or $$'
        } elseif (-not $i.PSIsContainer) {
            Add-Finding 'Warning' '$OEM$' ('File "{0}" at the top of $OEM$ is ignored - put it in $1 or $$.' -f $i.Name)
        }
    }
    $files = @(Get-ChildItem -LiteralPath $u -Recurse -File -Force -ErrorAction SilentlyContinue)
    $rels = @{}
    foreach ($f in $files) { $rels[$f.FullName.Substring($u.TrimEnd('\', '/').Length).TrimStart('\', '/').Replace('/', '\')] = $f }
    $total = ($files | Measure-Object -Property Length -Sum).Sum
    Add-Finding 'Info' '$OEM$' ('{0}: {1} files, {2}' -f $u, $files.Count, (Format-Size ([double]$total)))

    foreach ($r in @($rels.Keys)) {
        $leaf = Split-Path $r -Leaf
        if ($r -match '(?i)^\$1\\(auto)?unattend\.xml$') {
            $fix = ''; $ft = ''
            if (-not $S.Unattend -or [string]$S.Unattend.Source -ne $rels[$r].FullName) { $fix = 'use-oem-unattend=' + $rels[$r].FullName; $ft = 'Use it as the ISO''s answer file' }
            Add-Finding 'Warning' '$OEM$' ('{0} is only copied to C:\ - Setup never reads it from there. The answer file must be in the ISO root (page 6).' -f $r) $fix $ft
        }
        if ($r -match '(?i)^\$\$\\Panther\\(auto)?unattend\.xml$') {
            Add-Finding 'Warning' '$OEM$' ('{0} lands in C:\Windows\Panther, where Setup looks for its answer file in later passes - it can override your autounattend.xml.' -f $r) '' 'Remove it from $OEM$'
        }
        if ($leaf -ieq 'SetupComplete.cmd' -and $r -notmatch '(?i)^\$\$\\Setup\\Scripts\\SetupComplete\.cmd$') {
            Add-Finding 'Error' '$OEM$' ('{0} is in the wrong place - Windows only runs $$\Setup\Scripts\SetupComplete.cmd.' -f $r) '' 'Move it to $OEM$\$$\Setup\Scripts'
        }
        if ($Script:Cfg.SplitFat32 -and $rels[$r].Length -ge 4GB) {
            Add-Finding 'Warning' '$OEM$' ('{0} is larger than 4 GB - it does not fit on a FAT32 USB stick.' -f $r)
        }
        if (('C:\' + ($r -replace '^\$1\\', '')).Length -gt 240) {
            Add-Finding 'Warning' '$OEM$' ('Path too long for Setup to copy reliably (over 240 characters): {0}' -f (Limit-Text $r 90))
        }
    }

    # scripts that run during setup
    $seen = @{}
    $sc = '$$\Setup\Scripts\SetupComplete.cmd'
    if ($rels.ContainsKey($sc)) { Test-SetupScript $Ctx $sc 'runs at the end of setup' $seen $true }
    foreach ($r in @($rels.Keys | Where-Object { $_ -match '(?i)\.(cmd|bat)$' -and -not $seen.ContainsKey($_.ToLower()) })) {
        # other scripts: only collect driver-install lines for the coverage check
        try {
            foreach ($l in [IO.File]::ReadAllLines($rels[$r].FullName)) { if ($l -match $Script:InstallerRx) { $Ctx.Installers.Add([pscustomobject]@{ Text = $l.Trim(); Dir = (Split-Path $r -Parent) }) } }
        } catch { }
    }

    # drivers inside $OEM$\$1
    $one = Join-Path $u '$1'
    if (-not (Test-Path -LiteralPath $one)) { return }
    $infs = @(Get-ChildItem -LiteralPath $one -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | Select-Object -First 400)
    if ($infs.Count -eq 0) { return }
    $byDir = @{}
    $n = 0
    foreach ($f in $infs) {
        $n++
        Write-Host ('checking $OEM$ drivers {0}/{1}' -f $n, $infs.Count) -NoNewline
        $rel = '$1\' + $f.DirectoryName.Substring($one.Length).TrimStart('\', '/').Replace('/', '\')
        if (-not $byDir.ContainsKey($rel)) { $byDir[$rel] = @{ Full = $f.DirectoryName; Bad = @(); Arch = @(); N = 0 } }
        $e = $byDir[$rel]
        $e.N++
        $info = Get-InfInfo $f.FullName
        if ($Arch -and -not (Test-DriverArch $info.Arch $Arch)) { $e.Arch += $f.Name }
        $st = Get-DriverSignState $f.FullName $OwnThumb
        if ($Script:BadSign -contains $st) { $e.Bad += ('{0} ({1})' -f $f.Name, (Get-SignText $st)) }
    }
    $Ctx.OemInfDirs = @($byDir.Keys)
    $okDirs = 0
    foreach ($rel in @($byDir.Keys | Sort-Object)) {
        $e = $byDir[$rel]
        if ($e.Arch.Count) { Add-Finding 'Warning' 'Drivers in $OEM$' ('{0}: {1} not built for {2} - Windows skips it.' -f $rel, ($e.Arch -join ', '), $Arch) }
        if ($e.Bad.Count -eq 0) { $okDirs++; continue }
        $overlay = @($Ctx.PkgDirs | Where-Object { $rel -ieq $_ -or $rel.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($overlay.Count) {
            Add-Finding 'OK' 'Drivers in $OEM$' ('{0}: the unsigned files are replaced by your signed copy at build time.' -f $rel)
            continue
        }
        $from = @($Ctx.Signed | Where-Object { $e.Full -ieq [string]$_.Source -or $e.Full.StartsWith(([string]$_.Source).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($from.Count) {
            Add-Finding 'Warning' 'Drivers in $OEM$' ('{0}: the unsigned original stays in the ISO - your signed copy installs from {1}. Installing the original fails.' -f $rel, $from[0].InstallDir) '' ('Remove it from $OEM$ or name the signed package "{0}"' -f (Split-Path $rel -Leaf))
            continue
        }
        Add-Finding 'Error' 'Drivers in $OEM$' ('{0}: Windows will refuse it - {1}.' -f $rel, (($e.Bad | Select-Object -First 3) -join '; ')) '' 'Sign this folder on page 5 (it is then copied and installed automatically)'
    }
    if ($okDirs) { Add-Finding 'OK' 'Drivers in $OEM$' ('{0} driver folder(s) in $OEM$ have valid signatures.' -f $okDirs) }
    if ($Script:Sync) { $Script:Sync.Status = '' }
}
function Test-SlipstreamDrivers([string]$OwnThumb) {
    $d = @($Script:S.Drivers)
    if ($d.Count -eq 0) { return }
    $bad = @(); $nums = @()
    for ($i = 0; $i -lt $d.Count; $i++) {
        Write-Host ('checking slipstreamed drivers {0}/{1}' -f ($i + 1), $d.Count) -NoNewline
        $inf = Join-Path (Join-Path $Script:P.DrvSel $d[$i].Folder) $d[$i].Inf
        if (-not (Test-Path -LiteralPath $inf)) { $bad += ('{0} (file missing)' -f $d[$i].Inf); $nums += ($i + 1); continue }
        $st = Get-DriverSignState $inf $OwnThumb
        if ($Script:BadSign -contains $st -or $st -eq 'own') {
            $why = if ($st -eq 'own') { 'signed with your certificate - only trusted after SetupComplete runs' } else { Get-SignText $st }
            $bad += ('{0} {1} {2} ({3})' -f $d[$i].Class, $d[$i].Provider, $d[$i].Inf, $why); $nums += ($i + 1)
        }
    }
    if ($Script:Sync) { $Script:Sync.Status = '' }
    if ($bad.Count -eq 0) { Add-Finding 'OK' 'Drivers' ('{0} slipstreamed driver package(s) have valid catalogs.' -f $d.Count); return }
    $lvl = if ($Script:Cfg.ForceUnsigned) { 'Warning' } else { 'Error' }
    $what = if ($Script:Cfg.ForceUnsigned) { 'DISM adds them with /ForceUnsigned, but 64-bit Windows will not load them' } else { 'DISM refuses them, so these devices stay without a driver' }
    Add-Finding $lvl 'Drivers' ('{0} slipstreamed driver(s) are not validly signed - {1}: {2}' -f $bad.Count, $what, (($bad | Select-Object -First 5) -join '; ')) ('drop-bad-drivers=' + ($nums -join ',')) 'Remove them from the slipstream list (sign modded ones on page 5)'
}
function Test-SignedPackages([string]$OwnThumb) {
    $all = @($Script:S.Signed | Where-Object { $_ })
    if ($all.Count -eq 0) { return }
    $cer = Join-Path $Script:SignDir 'DriverSigning.cer'
    if (-not (Test-Path -LiteralPath $cer)) { Add-Finding 'Error' 'Signed drivers' 'DriverSigning.cer is missing from the signing folder - the ISO cannot trust your packages.' '' 'Sign the package(s) again on page 5'; return }
    try {
        $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $cer
        if ($c.NotAfter -lt (Get-Date).AddDays(30)) { Add-Finding 'Warning' 'Signed drivers' ('Your signing certificate expires on {0:yyyy-MM-dd}.' -f $c.NotAfter) }
    } catch { }
    foreach ($x in $all) {
        if (-not $x.Path -or -not (Test-Path -LiteralPath $x.Path)) { Add-Finding 'Error' 'Signed drivers' ('{0}: the signed copy is gone from the work folder.' -f $x.Name) '' 'Sign it again on page 5'; continue }
        if ($OwnThumb -and $x.Thumbprint -and $x.Thumbprint -ne $OwnThumb) { Add-Finding 'Error' 'Signed drivers' ('{0} was signed with another certificate than the one in the signing folder.' -f $x.Name) '' 'Sign it again on page 5'; continue }
        if ([int]$x.Failed -gt 0) { Add-Finding 'Warning' 'Signed drivers' ('{0}: {1} folder(s) failed to sign - those parts will not install.' -f $x.Name, $x.Failed) '' 'See logs\engine.log, then sign again' }
        else { Add-Finding 'OK' 'Signed drivers' ('{0}: {1} package folder(s) signed with your certificate, installs from {2}.' -f $x.Name, $x.Signed, $x.InstallDir) }
        if ($x.OnlyThisPc) {
            Add-Finding 'Info' 'Signed drivers' ('{0}: only the INF files for the PC it was signed on were kept ({1}; {2} removed) - it installs on that hardware only.' -f $x.Name, ((@($x.Kept) | Select-Object -First 4) -join ', '), [int]$x.Removed)
        }
    }
}
function Test-DriverCoverage($Ctx) {
    if (-not $Ctx.User -or -not $Ctx.OemInfDirs) { return }
    $cover = @()
    foreach ($i in $Ctx.Installers) {
        foreach ($r in @(Get-CommandRefs $i.Text $i.Dir -Dirs)) {
            if (-not $r.Rel) { continue }
            $p = ($r.Rel -replace '\\\*(\.inf)?$', '' -replace '\\[^\\]*\.inf$', '').TrimEnd('\')
            $cover += [pscustomobject]@{ Path = $p; Sub = ($i.Text -match '(?i)/subdirs|/recurse') }
        }
    }
    foreach ($r in $Ctx.Roots) { $cover += [pscustomobject]@{ Path = '$1\' + $r; Sub = $true } }
    foreach ($d in $Ctx.PkgDirs) { $cover += [pscustomobject]@{ Path = $d; Sub = $true } }
    $loose = @()
    foreach ($dir in $Ctx.OemInfDirs) {
        $hit = @($cover | Where-Object { $dir -ieq $_.Path -or ($_.Sub -and $dir.StartsWith($_.Path + '\', [StringComparison]::OrdinalIgnoreCase)) })
        if ($hit.Count -eq 0) { $loose += $dir }
    }
    if ($loose.Count -eq 0) { Add-Finding 'OK' 'Drivers in $OEM$' 'Every driver folder in $OEM$ is installed by a command (pnputil / dism / your signed package).'; return }
    $show = @($loose | ForEach-Object { 'C:\' + ($_ -replace '^\$1\\', '') } | Select-Object -First 6)
    Add-Finding 'Warning' 'Drivers in $OEM$' ('{0} driver folder(s) are only copied to C:\ - nothing installs them: {1}' -f $loose.Count, ($show -join ', ')) 'oem-drivers' 'Install them with pnputil from SetupComplete-drivers.cmd'
}
#endregion


#region ---------------------------------------------------------------- install check: answer file
function Test-AnswerFileFull($Ctx, $Final, [string]$Arch, [string]$UArch) {
    $S = $Script:S
    $file = $Script:P.Unattend
    if (-not $S.Unattend -or -not (Test-Path -LiteralPath $file)) {
        Add-Finding 'Info' 'Answer file' 'No autounattend.xml - Setup asks every question itself.'
        return $null
    }
    try { $X = Get-UnattendDoc $file } catch { Add-Finding 'Error' 'Answer file' ('autounattend.xml is not valid XML: {0}' -f $_.Exception.Message) '' 'Fix it in the generator and choose it again'; return $null }
    $root = $X.Doc.DocumentElement
    if ($root.LocalName -ne 'unattend' -or $root.NamespaceURI -ne $Script:UnattendNs) {
        Add-Finding 'Error' 'Answer file' 'The root element is not <unattend xmlns="urn:schemas-microsoft-com:unattend"> - Setup ignores the whole file.' '' 'Regenerate the answer file'
        return $null
    }
    $src = if ($S.Unattend.Fixed) { 'fixed copy of ' + $S.Unattend.Source } else { [string]$S.Unattend.Source }
    Add-Finding 'OK' 'Answer file' ('autounattend.xml is valid XML ({0})' -f $src)

    # passes
    $passes = @('windowsPE', 'offlineServicing', 'generalize', 'specialize', 'auditSystem', 'auditUser', 'oobeSystem')
    foreach ($st in (Get-XNodes $X '/u:unattend/u:settings')) {
        $p = $st.GetAttribute('pass')
        if ($passes -cnotcontains $p) { Add-Finding 'Error' 'Answer file' ('Unknown pass "{0}" - Setup stops with "could not parse the answer file".' -f $p) '' 'Fix the pass name (case matters)' }
    }

    # architecture of every component
    if ($UArch) {
        $bad = @(Get-XNodes $X '//u:component' | Where-Object { $_.GetAttribute('processorArchitecture') -ne $UArch })
        if ($bad.Count) {
            $seenA = @($bad | ForEach-Object { $_.GetAttribute('processorArchitecture') } | Sort-Object -Unique) -join ', '
            Add-Finding 'Error' 'Answer file' ('{0} component(s) are for {1}, but the ISO is {2} ({3}) - Setup silently ignores them, so the install is not automated.' -f $bad.Count, $seenA, $Arch, $UArch) ('arch=' + $UArch) ('Set processorArchitecture="{0}" everywhere' -f $UArch)
        } else { Add-Finding 'OK' 'Answer file' ('All components are for {0}.' -f $UArch) }
    }

    # edition selection
    $setupC = "//u:settings[@pass='windowsPE']/u:component[@name='Microsoft-Windows-Setup']"
    $md = Get-XNodes $X "$setupC/u:ImageInstall/u:OSImage/u:InstallFrom/u:MetaData"
    $keyNode = Get-XNodes $X "$setupC/u:UserData/u:ProductKey/u:Key" | Select-Object -First 1
    $key = if ($keyNode) { $keyNode.InnerText.Trim().ToUpper() } else { '' }
    $orig = @($S.Images)
    $target = $null
    if ($Final.Count -gt 0) {
        if ($md.Count -eq 0) {
            if ($Final.Count -eq 1) { Add-Finding 'OK' 'Answer file' ('The ISO has one edition: {0}.' -f $Final[0].Name); $target = $Final[0] }
            elseif (-not $key) { Add-Finding 'Info' 'Answer file' ('No edition is preselected and the ISO has {0} editions - Setup will ask which one to install.' -f $Final.Count) }
        }
        foreach ($m in $md) {
            $k = Get-XText $X $m 'u:Key'; $v = Get-XText $X $m 'u:Value'
            if ($k -match '(?i)/IMAGE/INDEX') {
                $iv = 0; [void][int]::TryParse($v, [ref]$iv)
                $o = @($orig | Where-Object { [int]$_.Index -eq $iv }) | Select-Object -First 1
                $mapped = if ($o) { @($Final | Where-Object { $_.Name -eq $o.Name }) | Select-Object -First 1 } else { $null }
                if ($iv -ge 1 -and $iv -le $Final.Count) {
                    $now = $Final[$iv - 1]
                    if ($o -and $o.Name -ne $now.Name -and $mapped) {
                        Add-Finding 'Warning' 'Answer file' ('The answer file installs index {0}. In the new ISO that is "{1}", but in the original ISO it was "{2}" - if the file was made for the original ISO, Setup installs the wrong edition.' -f $iv, $now.Name, $o.Name) ('index=' + $mapped.Index) ('Point it to "{0}" (index {1} in the new ISO)' -f $mapped.Name, $mapped.Index)
                        $target = $now
                    } else { Add-Finding 'OK' 'Answer file' ('Installs index {0}: {1}.' -f $iv, $now.Name); $target = $now }
                } elseif ($mapped) {
                    Add-Finding 'Error' 'Answer file' ('The answer file installs index {0} ("{1}" in the original ISO), but the new install.wim has only {2} edition(s) - Setup stops with "No images are available".' -f $iv, $o.Name, $Final.Count) ('index=' + $mapped.Index) ('Point it to "{0}" (index {1})' -f $mapped.Name, $mapped.Index)
                } elseif ($Final.Count -eq 1) {
                    Add-Finding 'Error' 'Answer file' ('The answer file installs index {0}, but the new install.wim has only one edition.' -f $iv) 'index=1' ('Point it to index 1 ({0})' -f $Final[0].Name)
                } else {
                    Add-Finding 'Error' 'Answer file' ('The answer file installs index {0}, but the new install.wim has {1} edition(s).' -f $iv, $Final.Count) '' 'Tick that edition on page 2 or regenerate the answer file'
                }
            } elseif ($k -match '(?i)/IMAGE/NAME') {
                $now = @($Final | Where-Object { $_.Name -eq $v }) | Select-Object -First 1
                if ($now) { Add-Finding 'OK' 'Answer file' ('Installs "{0}".' -f $v); $target = $now }
                elseif ($Final.Count -eq 1) { Add-Finding 'Error' 'Answer file' ('The answer file installs "{0}", which is not in the new ISO - Setup stops with "No images are available".' -f $v) ('name=' + $Final[0].Name) ('Install "{0}" instead' -f $Final[0].Name) }
                else { Add-Finding 'Error' 'Answer file' ('The answer file installs "{0}", which is not in the new ISO (it has: {1}).' -f $v, ((@($Final | ForEach-Object { $_.Name })) -join ', ')) '' 'Tick that edition on page 2 or regenerate the answer file' }
            }
        }
        if ($key -and $Script:GenericKeys.ContainsKey($key)) {
            $ed = $Script:GenericKeys[$key]
            $has = @($Final | Where-Object { $_.Edition -eq $ed })
            if ($has.Count -eq 0) { Add-Finding 'Error' 'Answer file' ('The product key is the generic key for {0}, which is not in the new ISO - Setup stops with "No images are available".' -f $ed) '' 'Tick that edition on page 2 or change the key' }
            elseif ($target -and $target.Edition -and $target.Edition -ne $ed) { Add-Finding 'Warning' 'Answer file' ('The product key is for {0}, but the answer file selects {1}.' -f $ed, $target.Name) '' 'Use the matching generic key or edition' }
            else { Add-Finding 'OK' 'Answer file' ('Generic product key for {0} - that edition is in the ISO.' -f $ed); if (-not $target) { $target = $has[0] } }
        }
    } else { Add-Finding 'Info' 'Answer file' 'Unpack the ISO (page 1) to check edition, language and architecture against it.' }

    # languages
    $langs = @()
    if ($Final.Count) { $langs = @(([string]$Final[0].Langs) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($langs.Count) {
        $pe = "//u:component[@name='Microsoft-Windows-International-Core-WinPE']"
        $peBad = @(Get-XNodes $X "$pe/u:UILanguage | $pe/u:SetupUILanguage/u:UILanguage" | Where-Object { $langs -notcontains $_.InnerText.Trim() })
        $osBad = @(Get-XNodes $X "//u:component[@name='Microsoft-Windows-International-Core']/u:UILanguage" | Where-Object { $langs -notcontains $_.InnerText.Trim() })
        if ($peBad.Count) { Add-Finding 'Error' 'Answer file' ('Setup language {0} is not in this ISO (it has {1}) - Setup stops right at the start.' -f $peBad[0].InnerText.Trim(), ($langs -join ', ')) ('lang=' + $langs[0]) ('Use {0}' -f $langs[0]) }
        elseif ($osBad.Count) { Add-Finding 'Warning' 'Answer file' ('Windows display language {0} is not in this ISO (it has {1}).' -f $osBad[0].InnerText.Trim(), ($langs -join ', ')) ('lang=' + $langs[0]) ('Use {0}' -f $langs[0]) }
        else { Add-Finding 'OK' 'Answer file' ('Language settings match the ISO ({0}).' -f ($langs -join ', ')) }
    }
    foreach ($loc in (Get-XNodes $X "//u:component[starts-with(@name,'Microsoft-Windows-International-Core')]/u:SystemLocale | //u:component[starts-with(@name,'Microsoft-Windows-International-Core')]/u:UserLocale")) {
        $v = $loc.InnerText.Trim()
        try { [void][Globalization.CultureInfo]::GetCultureInfo($v) } catch { Add-Finding 'Warning' 'Answer file' ('{0} "{1}" is not a known locale.' -f $loc.LocalName, $v) }
    }

    # computer name / time zone
    $names = @()
    foreach ($cn in (Get-XNodes $X "//u:component[@name='Microsoft-Windows-Shell-Setup']/u:ComputerName")) {
        $v = $cn.InnerText.Trim()
        if ($v -eq '*' -or -not $v) { continue }
        $names += $v
        if ($v.Length -gt 15 -or $v -notmatch '^[A-Za-z0-9-]+$' -or $v -match '^\d+$') {
            Add-Finding 'Error' 'Answer file' ('Computer name "{0}" is invalid (max 15 letters, digits or hyphens, not only digits) - the specialize pass fails.' -f $v) 'computername' 'Use * (random name, rename later)'
        } else { Add-Finding 'OK' 'Answer file' ('Computer name {0} is valid.' -f $v) }
    }
    foreach ($tz in (Get-XNodes $X "//u:component[@name='Microsoft-Windows-Shell-Setup']/u:TimeZone")) {
        $v = $tz.InnerText.Trim()
        try { [void][TimeZoneInfo]::FindSystemTimeZoneById($v); Add-Finding 'OK' 'Answer file' ('Time zone "{0}" exists.' -f $v) }
        catch {
            $here = [TimeZoneInfo]::Local.Id
            Add-Finding 'Error' 'Answer file' ('Time zone "{0}" does not exist - Windows setup fails with "could not parse or process the answer file".' -f $v) ('timezone=' + $here) ('Use this PC''s time zone ({0})' -f $here)
        }
    }

    # accounts
    $accts = @(Get-XNodes $X '//u:UserAccounts/u:LocalAccounts/u:LocalAccount')
    $reserved = @('administrator', 'guest', 'defaultaccount', 'wdagutilityaccount', 'system', 'none')
    foreach ($a in $accts) {
        $n = Get-XText $X $a 'u:Name'
        if (-not $n) { Add-Finding 'Error' 'Answer file' 'A local account has no name.'; continue }
        if ($n.Length -gt 20 -or $n -match '["/\\\[\]:;|=,+*?<>@]' -or $n.EndsWith('.')) { Add-Finding 'Error' 'Answer file' ('Account name "{0}" is invalid (max 20 characters, none of " / \ [ ] : ; | = , + * ? < > @).' -f $n) '' 'Change it in the generator' }
        elseif ($reserved -contains $n.ToLower()) { Add-Finding 'Error' 'Answer file' ('Account name "{0}" is reserved by Windows - creating it fails.' -f $n) '' 'Use another name' }
        elseif (@($names | Where-Object { $_ -ieq $n }).Count) { Add-Finding 'Error' 'Answer file' ('Account "{0}" has the same name as the computer - Windows does not allow that.' -f $n) '' 'Change the account or the computer name' }
        else {
            $g = Get-XText $X $a 'u:Group'
            if ($g -notmatch '(?i)administrators') { Add-Finding 'Info' 'Answer file' ('Account "{0}" is a standard user (group "{1}").' -f $n, $g) }
            else { Add-Finding 'OK' 'Answer file' ('Creates administrator account "{0}".' -f $n) }
        }
    }
    $hideLocal = @(Get-XNodes $X '//u:OOBE/u:HideLocalAccountScreen' | Where-Object { $_.InnerText.Trim() -eq 'true' }).Count -gt 0
    $autoUser = (@(Get-XNodes $X '//u:AutoLogon/u:Username') | Select-Object -First 1)
    if ($hideLocal -and $accts.Count -eq 0 -and -not $autoUser) {
        Add-Finding 'Warning' 'Answer file' 'The local account screen is hidden but no account is created - setup can end at "Something went wrong" or with no way to sign in.' '' 'Add a local account in the generator'
    }
    if ($autoUser) {
        $au = $autoUser.InnerText.Trim()
        if ($au -and $au -ine 'Administrator' -and -not @($accts | Where-Object { (Get-XText $X $_ 'u:Name') -ieq $au }).Count) {
            Add-Finding 'Warning' 'Answer file' ('AutoLogon signs in as "{0}", but the answer file does not create that account.' -f $au)
        }
    }

    # command lists: Order values must be unique
    $dupe = $false
    foreach ($list in (Get-XNodes $X '//u:RunSynchronous | //u:FirstLogonCommands | //u:LogonCommands')) {
        $orders = @($list.SelectNodes('*/u:Order', $X.Ns) | ForEach-Object { $_.InnerText.Trim() })
        $items = @($list.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
        if ($orders.Count -ne $items.Count -or @($orders | Where-Object { $_ -notmatch '^\d+$' }).Count -or @($orders | Sort-Object -Unique).Count -ne $orders.Count) { $dupe = $true }
    }
    if ($dupe) { Add-Finding 'Error' 'Answer file' 'A command list has missing or duplicate <Order> numbers - Setup stops with "could not parse the answer file".' 'order' 'Renumber the commands 1, 2, 3...' }

    # commands: referenced files, drive letters, installers, the driver fallback
    $seen = @{}
    foreach ($c in (Get-XNodes $X '//u:RunSynchronousCommand/u:Path | //u:SynchronousCommand/u:CommandLine | //u:AsynchronousCommand/u:CommandLine')) {
        $text = $c.InnerText.Trim()
        $pass = Get-XPass $c
        $hidden = ($c.LocalName -eq 'Path')
        if ($text -match '(?i)SetupComplete-drivers\.cmd' -and $pass -eq 'specialize') { $Ctx.Fallback = $true }
        if ($text -match $Script:InstallerRx) { $Ctx.Installers.Add([pscustomobject]@{ Text = $text; Dir = '' }) }
        foreach ($r in @(Get-CommandRefs $text '')) {
            if ($r.Kind -eq 'drive') { Add-Finding 'Warning' 'Answer file' ('A command in the {0} pass uses a fixed drive letter ({1}) - USB stick and disk letters differ between PCs.' -f $pass, $r.Raw) '' 'Use %SystemDrive% / %WINDIR% or search for the drive'; continue }
            Add-PkgRef $Ctx $r ('A command in the {0} pass' -f $pass)
            if (-not (Test-RefWorthChecking $Ctx $r.Rel)) { continue }
            if ($pass -eq 'windowsPE') { Add-Finding 'Warning' 'Answer file' ('A command in the windowsPE pass uses {0} - in that pass C: is not the new Windows yet.' -f $r.Raw); continue }
            if ($r.Rel -match '(?i)SetupComplete-drivers\.cmd$') { continue }
            if (-not (Test-OemRel $Ctx $r.Rel)) { Add-Finding 'Warning' 'Answer file' ('A command in the {0} pass uses {1}, which will not exist (it is not in your $OEM$ and the answer file does not create it).' -f $pass, $r.Raw) '' 'Add the file to $OEM$ or fix the path' }
            elseif ($r.Rel -match '(?i)\.(cmd|bat)$') { Test-SetupScript $Ctx $r.Rel ('run by the answer file, ' + $pass) $seen $hidden 0 (Test-CalledWithArgs $text $r.Rel) }
        }
    }
    foreach ($p in (Get-XNodes $X "//u:component[@name='Microsoft-Windows-PnpCustomizationsNonWinPE']//u:PathAndCredentials/u:Path")) {
        $Ctx.Installers.Add([pscustomobject]@{ Text = 'pnputil /subdirs "' + $p.InnerText.Trim() + '"'; Dir = '' })
    }

    # disk layout
    $disks = @(Get-XNodes $X "$setupC/u:DiskConfiguration/u:Disk")
    $inst = @(Get-XNodes $X "$setupC/u:ImageInstall/u:OSImage/u:InstallTo") | Select-Object -First 1
    $avail = @(Get-XNodes $X "$setupC/u:ImageInstall/u:OSImage/u:InstallToAvailablePartition" | Where-Object { $_.InnerText.Trim() -eq 'true' })
    if ($disks.Count -eq 0 -and -not $inst -and -not $avail.Count) { Add-Finding 'OK' 'Answer file' 'Setup asks which disk / partition to use (no automatic partitioning).' }
    if ($inst -and $avail.Count) { Add-Finding 'Error' 'Answer file' 'Both InstallTo and InstallToAvailablePartition are set - Setup refuses that combination.' 'installto-avail' 'Remove InstallToAvailablePartition' }
    foreach ($d in $disks) {
        $id = Get-XText $X $d 'u:DiskID'
        if ((Get-XText $X $d 'u:WillWipeDisk') -eq 'true') {
            Add-Finding 'Warning' 'Answer file' ('Disk {0} is erased completely. On PCs with two or more drives the numbering can change - make sure disk {0} is the drive you want.' -f $id) '' 'Unplug other drives, or let Setup ask'
        }
        $parts = @($d.SelectNodes('u:CreatePartitions/u:CreatePartition', $X.Ns))
        if ($parts.Count -eq 0) { continue }
        $ord = @($parts | ForEach-Object { Get-XText $X $_ 'u:Order' })
        if (@($ord | Sort-Object -Unique).Count -ne $ord.Count) { Add-Finding 'Error' 'Answer file' ('Disk {0}: two partitions have the same Order.' -f $id) }
        $ext = @($parts | Where-Object { (Get-XText $X $_ 'u:Extend') -eq 'true' })
        if ($ext.Count -gt 1) { Add-Finding 'Error' 'Answer file' ('Disk {0}: more than one partition is set to Extend (fill the disk).' -f $id) }
        if (@($ext | Where-Object { $_.SelectSingleNode('u:Size', $X.Ns) }).Count) { Add-Finding 'Error' 'Answer file' ('Disk {0}: a partition has both Extend=true and a Size - Setup rejects that.' -f $id) 'extendsize' 'Remove the Size from the extended partition' }
        $efi = @($parts | Where-Object { (Get-XText $X $_ 'u:Type') -eq 'EFI' })
        if ($efi.Count) {
            $sz = 0; [void][int]::TryParse((Get-XText $X $efi[0] 'u:Size'), [ref]$sz)
            if ($sz -gt 0 -and $sz -lt 100) { Add-Finding 'Error' 'Answer file' ('Disk {0}: the EFI partition is {1} MB - it must be at least 100 MB.' -f $id, $sz) }
            elseif ($sz -gt 0 -and $sz -lt 260) { Add-Finding 'Info' 'Answer file' ('Disk {0}: EFI partition {1} MB - drives with 4K sectors need 260 MB.' -f $id, $sz) }
            Add-Finding 'Info' 'Answer file' ('Disk {0} gets a GPT (UEFI) layout - boot the USB stick in UEFI mode; legacy/CSM boot fails with this layout.' -f $id)
        } else { Add-Finding 'Info' 'Answer file' ('Disk {0} gets an MBR (legacy BIOS) layout - boot the USB stick in legacy/CSM mode; UEFI boot fails with this layout.' -f $id) }
        if ($inst -and (Get-XText $X $inst 'u:DiskID') -eq $id) {
            $partId = 0; [void][int]::TryParse((Get-XText $X $inst 'u:PartitionID'), [ref]$partId)
            if ($partId -gt $parts.Count) { Add-Finding 'Error' 'Answer file' ('Windows is installed to partition {0} of disk {1}, but only {2} partition(s) are created there.' -f $partId, $id, $parts.Count) }
        }
    }
    if ($inst -and $disks.Count -eq 0) {
        Add-Finding 'Warning' 'Answer file' ('Windows goes to disk {0} partition {1} as it exists now - if that partition is missing or too small, setup stops.' -f (Get-XText $X $inst 'u:DiskID'), (Get-XText $X $inst 'u:PartitionID'))
    }
    $plain = @(Get-XNodes $X '//u:PlainText' | Where-Object { $_.InnerText.Trim() -eq 'true' }).Count
    if ($plain) { Add-Finding 'Info' 'Answer file' ('{0} password(s) are stored as plain text - keep the ISO / USB stick private.' -f $plain) }
    return $X
}
function Test-SetupCompleteRuns($Ctx, $X, $Final) {
    $userSc = $Ctx.User -and (Test-Path -LiteralPath (Join-Path $Ctx.User '$$\Setup\Scripts\SetupComplete.cmd'))
    if (-not $Ctx.DriverScript -and -not $userSc) { return }
    $ent = $Final.Count -gt 0 -and -not @($Final | Where-Object { $_.Edition -notmatch '^Enterprise' }).Count
    if ($ent) { Add-Finding 'OK' 'Setup scripts' 'Enterprise editions always run SetupComplete.cmd.'; return }
    $here = Test-FirmwareOemKey
    $pc = if ($here) { ' - THIS PC has one' } else { '' }
    if ($Ctx.DriverScript) {
        if ($Ctx.Fallback) { Add-Finding 'OK' 'Setup scripts' 'SetupComplete-drivers.cmd also runs from the specialize pass, so drivers install even on PCs with an OEM key.' }
        else {
            $lvl = if ($here) { 'Error' } else { 'Warning' }
            $fix = if ($X) { 'specialize-drivers' } else { '' }
            $ft = if ($X) { 'Also run SetupComplete-drivers.cmd from the specialize pass (runs once)' } else { 'Add an autounattend.xml (page 6), then apply this fix' }
            Add-Finding $lvl 'Setup scripts' ('Windows skips SetupComplete.cmd on Home/Pro when it is activated with an OEM key (PCs sold with Windows keep it in the firmware{0}) - your signed drivers would not be installed.' -f $pc) $fix $ft
        }
    }
    if ($userSc) {
        $lvl = if ($here) { 'Warning' } else { 'Info' }
        Add-Finding $lvl 'Setup scripts' ('Your own SetupComplete.cmd commands are skipped on PCs activated with an OEM key{0}. Move anything essential to FirstLogonCommands in the answer file.' -f $pc)
    }
}
#endregion

#region ---------------------------------------------------------------- install check: run + fixes
function Invoke-InstallCheck([switch]$NoDownload, [switch]$Quiet) {
    $Script:Findings = New-Object System.Collections.Generic.List[object]
    if (-not $Quiet) { Write-Title 'Install check - answer file, $OEM$ and drivers' }
    $S = $Script:S
    $arch = if ($S.Family) { [string]$S.Family.Arch } else { '' }
    $uArch = if ($arch) { @{ x64 = 'amd64'; x86 = 'x86'; arm64 = 'arm64' }[$arch] } else { '' }
    $final = @(Get-FinalEditions)
    $Script:SignTool = Find-Tool 'signtool.exe'
    if (-not $Script:SignTool -and -not $NoDownload) {
        Write-Step 'Getting signtool.exe to check driver signatures'
        $Script:SignTool = Get-FromNuGet 'signtool.exe' @('Microsoft.Windows.SDK.BuildTools') '(?i)/x64/'
    }
    $cer = Join-Path $Script:SignDir 'DriverSigning.cer'
    $own = $null
    if (Test-Path -LiteralPath $cer) { try { $own = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $cer).Thumbprint } catch { } }
    $added = @()
    if ($own -and $Script:IsWorker) { try { $added = @(Add-TempTrust $cer) } catch { } }
    try {
        $ctx = Get-OemContext
        $emb = @(Get-EmbeddedFiles)
        foreach ($f in $emb) { $rel = ConvertTo-OemRel $f.Path; if ($rel) { $ctx.Generated[$rel.ToLower()] = $true } }
        if ($final.Count -gt 0 -and $S.Serviced) {
            $wim = Join-Path $Script:P.Media 'sources\install.wim'
            if ((Test-Path -LiteralPath $wim) -and (Get-Item -LiteralPath $wim).Length -gt 4GB -and -not $Script:Cfg.SplitFat32) {
                Add-Finding 'Info' 'Media' ('install.wim is {0} - too big for a FAT32 USB stick. Use Rufus (it handles this) or turn on "Split install.wim" on page 7.' -f (Format-Size (Get-Item -LiteralPath $wim).Length))
            }
        }
        if (-not $Script:SignTool) { Add-Finding 'Info' 'Drivers' 'signtool.exe is not available, so driver catalogs were only partly checked.' }
        Test-OemFolder $ctx $own $arch
        Test-SlipstreamDrivers $own
        Test-SignedPackages $own
        $X = Test-AnswerFileFull $ctx $final $arch $uArch
        Test-EmbeddedScripts $ctx $X $emb @{}
        Test-SetupCompleteRuns $ctx $X $final
        Test-DriverCoverage $ctx
        $refs = @($ctx.PkgRefs | Select-Object -Unique)
        if ($refs.Count -and $Script:Cfg.SignCleanup) {
            Add-Finding 'Warning' 'Signed drivers' ('{0} - but SetupComplete-drivers.cmd deletes that folder right after pnputil has installed the driver, so the file is gone when this runs.' -f (($refs | Select-Object -First 3) -join '; ')) 'keep-driver-copy' 'Keep the driver copy in C:\Drivers (turns off "Delete the driver copy")'
        } elseif ($refs.Count) {
            Add-Finding 'OK' 'Signed drivers' ('{0} - the signed copy stays in place for it.' -f (($refs | Select-Object -First 3) -join '; '))
        }
        foreach ($sp in @($Script:S.Signed | Where-Object { $_ -and $_.OnlyThisPc })) {
            $rel = ([string]$sp.InstallDir) -replace '^[A-Za-z]:\\?', ''
            $exe = @($refs | Where-Object { $_ -match ('(?i)' + [regex]::Escape($rel) + '\\[^\s"]*\.exe') })
            if ($exe.Count) {
                Add-Finding 'Warning' 'Signed drivers' ('{0} - but {1} only keeps the INF files for this PC, and NVIDIA''s installer may stop when the others are missing. pnputil installs the driver anyway.' -f $exe[0], $sp.Name) '' 'If the installer fails, turn off "Only keep the INF files for this PC" on page 5 and sign again'
            }
        }
    } finally {
        if ($added.Count) { try { Remove-TempTrust $cer $added } catch { } }
        if ($Script:Sync) { $Script:Sync.Status = '' }
    }
    $list = @($Script:Findings | Sort-Object @{ Expression = { @{ Error = 0; Warning = 1; Info = 2; OK = 3 }[$_.Level] } }, @{ Expression = { $_.Area } })
    $e = @($list | Where-Object { $_.Level -eq 'Error' }).Count
    $w = @($list | Where-Object { $_.Level -eq 'Warning' }).Count
    $o = @($list | Where-Object { $_.Level -eq 'OK' }).Count
    foreach ($f in $list) {
        $t = '{0}: {1}' -f $f.Area, $f.Finding
        switch ($f.Level) {
            'Error'   { Write-Err $t }
            'Warning' { Write-Warn $t }
            'Info'    { if (-not $Quiet) { Write-Info $t } }
            'OK'      { if (-not $Quiet) { Write-Ok $t } }
        }
    }
    $sum = '{0} error(s), {1} warning(s), {2} check(s) passed' -f $e, $w, $o
    if ($e) { Write-Err "Install check: $sum" } elseif ($w) { Write-Warn "Install check: $sum" } else { Write-Ok "Install check: $sum" }
    $Script:S.Check = [ordered]@{ When = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Errors = $e; Warnings = $w; Passed = $o }
    Save-State
    try { ConvertTo-Json -InputObject @($list) -Depth 3 | Set-Content -LiteralPath (Join-Path $Script:P.Work 'install-check.json') -Encoding UTF8 } catch { }
    return $list
}
function Add-SpecializeDriverCommand($X, [string]$UArch) {
    $doc = $X.Doc; $ns = $Script:UnattendNs
    $set = $doc.SelectSingleNode("/u:unattend/u:settings[@pass='specialize']", $X.Ns)
    if (-not $set) { $set = $doc.CreateElement('settings', $ns); $set.SetAttribute('pass', 'specialize'); [void]$doc.DocumentElement.AppendChild($set) }
    $comp = $set.SelectSingleNode("u:component[@name='Microsoft-Windows-Deployment']", $X.Ns)
    if (-not $comp) {
        $comp = $doc.CreateElement('component', $ns)
        foreach ($kv in @(@('name', 'Microsoft-Windows-Deployment'), @('processorArchitecture', $UArch), @('publicKeyToken', '31bf3856ad364e35'), @('language', 'neutral'), @('versionScope', 'nonSxS'))) { $comp.SetAttribute($kv[0], $kv[1]) }
        [void]$set.AppendChild($comp)
    }
    $rs = $comp.SelectSingleNode('u:RunSynchronous', $X.Ns)
    if (-not $rs) { $rs = $doc.CreateElement('RunSynchronous', $ns); [void]$comp.AppendChild($rs) }
    if ($rs.InnerXml -match 'SetupComplete-drivers\.cmd') { return }
    $max = 0
    foreach ($o in @($rs.SelectNodes('u:RunSynchronousCommand/u:Order', $X.Ns))) { $v = 0; if ([int]::TryParse($o.InnerText.Trim(), [ref]$v) -and $v -gt $max) { $max = $v } }
    $cmd = $doc.CreateElement('RunSynchronousCommand', $ns)
    $a = $doc.CreateAttribute('wcm', 'action', $Script:WcmNs); $a.Value = 'add'; [void]$cmd.Attributes.Append($a)
    $vals = @(@('Order', [string]($max + 1)),
              @('Path', 'cmd.exe /c if exist "%WINDIR%\Setup\Scripts\SetupComplete-drivers.cmd" call "%WINDIR%\Setup\Scripts\SetupComplete-drivers.cmd"'),
              @('Description', 'Install signed drivers (runs even when SetupComplete.cmd is skipped)'))
    foreach ($kv in $vals) { $el = $doc.CreateElement($kv[0], $ns); $el.InnerText = $kv[1]; [void]$cmd.AppendChild($el) }
    [void]$rs.AppendChild($cmd)
}
function Set-AnswerFix($X, [string]$Fix) {
    $n = $X.Ns
    switch -Regex ($Fix) {
        '^arch=(\w+)$' {
            $a = $Matches[1]
            foreach ($c in (Get-XNodes $X '//u:component')) { $c.SetAttribute('processorArchitecture', $a) }
            Write-Ok "processorArchitecture set to $a on every component"
        }
        '^index=(\d+)$' {
            $v = $Matches[1]
            foreach ($m in (Get-XNodes $X '//u:InstallFrom/u:MetaData')) { if ((Get-XText $X $m 'u:Key') -match '(?i)/IMAGE/INDEX') { $m.SelectSingleNode('u:Value', $n).InnerText = $v } }
            Write-Ok "Edition index set to $v"
        }
        '^name=(.+)$' {
            $v = $Matches[1]
            foreach ($m in (Get-XNodes $X '//u:InstallFrom/u:MetaData')) { if ((Get-XText $X $m 'u:Key') -match '(?i)/IMAGE/NAME') { $m.SelectSingleNode('u:Value', $n).InnerText = $v } }
            Write-Ok "Edition set to $v"
        }
        '^lang=(.+)$' {
            $v = $Matches[1]; $pe = "//u:component[@name='Microsoft-Windows-International-Core-WinPE']"
            foreach ($u in (Get-XNodes $X "$pe/u:UILanguage | $pe/u:SetupUILanguage/u:UILanguage | //u:component[@name='Microsoft-Windows-International-Core']/u:UILanguage")) { $u.InnerText = $v }
            Write-Ok "Setup and display language set to $v"
        }
        '^computername$' {
            foreach ($c in (Get-XNodes $X "//u:component[@name='Microsoft-Windows-Shell-Setup']/u:ComputerName")) { $c.InnerText = '*' }
            Write-Ok 'Computer name set to * (random)'
        }
        '^timezone=(.+)$' {
            $v = $Matches[1]
            foreach ($t in (Get-XNodes $X "//u:component[@name='Microsoft-Windows-Shell-Setup']/u:TimeZone")) { $t.InnerText = $v }
            Write-Ok "Time zone set to $v"
        }
        '^order$' {
            foreach ($list in (Get-XNodes $X '//u:RunSynchronous | //u:FirstLogonCommands | //u:LogonCommands')) {
                $items = @($list.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })
                $sorted = @($items | Sort-Object { $o = $_.SelectSingleNode('u:Order', $n); $v = 9999; if ($o) { [void][int]::TryParse($o.InnerText.Trim(), [ref]$v) }; $v })
                $i = 0
                foreach ($it in $sorted) {
                    $i++
                    $o = $it.SelectSingleNode('u:Order', $n)
                    if (-not $o) { $o = $X.Doc.CreateElement('Order', $Script:UnattendNs); [void]$it.PrependChild($o) }
                    $o.InnerText = [string]$i
                }
            }
            Write-Ok 'Command Order numbers renumbered'
        }
        '^extendsize$' {
            foreach ($p in (Get-XNodes $X '//u:CreatePartition')) {
                $sz = $p.SelectSingleNode('u:Size', $n)
                if ((Get-XText $X $p 'u:Extend') -eq 'true' -and $sz) { [void]$p.RemoveChild($sz) }
            }
            Write-Ok 'Size removed from the extended partition'
        }
        '^installto-avail$' {
            foreach ($a in (Get-XNodes $X '//u:OSImage/u:InstallToAvailablePartition')) { [void]$a.ParentNode.RemoveChild($a) }
            Write-Ok 'InstallToAvailablePartition removed'
        }
        '^specialize-drivers$' {
            $ua = if ($Script:S.Family) { @{ x64 = 'amd64'; x86 = 'x86'; arm64 = 'arm64' }[[string]$Script:S.Family.Arch] } else { 'amd64' }
            Add-SpecializeDriverCommand $X $ua
            Write-Ok 'specialize pass now also runs SetupComplete-drivers.cmd'
        }
        default { Write-Warn "Unknown fix: $Fix" }
    }
}
function Invoke-InstallFixes([string[]]$Fixes) {
    Write-Title 'Applying fixes'
    $xml = @()
    $newFile = $false
    foreach ($f in @($Fixes | Where-Object { $_ } | Sort-Object -Unique)) {
        if ($f -eq 'keep-driver-copy') { $Script:Cfg.SignCleanup = $false; Save-Settings; Write-Ok 'The signed driver copy now stays in C:\Drivers after installation.' }
        elseif ($f -eq 'oem-drivers') { $Script:Cfg.InstallOemDrivers = $true; Save-Settings; Write-Ok 'The driver folders in your $OEM$ are now installed by SetupComplete-drivers.cmd.' }
        elseif ($f -match '^drop-bad-drivers=(.+)$') { Remove-DriverEntries @($Matches[1] -split ',' | ForEach-Object { [int]$_ }) }
        elseif ($f -match '^use-oem-unattend=(.+)$') { Set-UnattendFile $Matches[1]; $newFile = $true }
        else { $xml += $f }
    }
    if ($xml.Count -and $newFile) { Write-Info 'A different answer file was chosen - run the check again to see its fixes.'; return }
    if ($xml.Count) {
        if (-not (Test-Path -LiteralPath $Script:P.Unattend)) { Write-Warn 'There is no answer file to fix.'; return }
        $bak = Join-Path $Script:P.Work 'autounattend.original.xml'
        if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $Script:P.Unattend -Destination $bak }
        $X = Get-UnattendDoc $Script:P.Unattend
        foreach ($f in $xml) { Set-AnswerFix $X $f }
        $X.Doc.Save($Script:P.Unattend)
        $Script:S.Unattend.Fixed = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Save-State
        Sync-Unattend
        Write-Ok "Fixed answer file saved for the ISO (your original is untouched; backup: $bak)"
    }
}
#endregion


#region ---------------------------------------------------------------- drivers: scan (worker) / commit (worker) / remove (GUI)
# Windows keeps the old versions of a driver in its driver store, and Export-WindowsDriver exports them all
# (one PC had 3 NVIDIA display drivers of about 1.5 GB each and 12 Intel Bluetooth versions). Every package
# gets Older = $true except the newest of its kind (same INF name, provider and class): the picker leaves
# those unticked - they only make the ISO bigger and the slipstream slower.
function Set-OlderDrivers($Items) {
    $groups = @{}
    foreach ($x in @($Items)) {
        $k = '{0}|{1}|{2}' -f ([string]$x.Inf).ToLowerInvariant(), $x.Provider, $x.Class
        if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.Generic.List[object] }
        $groups[$k].Add($x)
    }
    foreach ($g in $groups.Values) {
        $best = @($g | Sort-Object @{ Expression = { [string]$_.Date }; Descending = $true },
                                   @{ Expression = { $v = [version]'0.0'; [void][version]::TryParse(([string]$_.Version), [ref]$v); $v }; Descending = $true })[0]
        foreach ($x in $g) { $x | Add-Member -NotePropertyName Older -NotePropertyValue ([string]$x.Folder -ne [string]$best.Folder) -Force }
    }
    return @($Items)
}
function Get-HostDriverScan {
    $hostArch = Get-HostArch
    if ($Script:S.Family -and $Script:S.Family.Arch -ne $hostArch) {
        throw "This PC is $hostArch but the ISO is $($Script:S.Family.Arch) - its drivers would not work in that image."
    }
    $exp = Join-Path $Script:P.Drivers 'host_export'
    Reset-Dir $exp
    Write-Step 'Exporting third-party drivers from this PC (1-3 minutes)'
    $drv = @(Export-WindowsDriver -Online -Destination $exp)
    if ($drv.Count -eq 0) { Write-Warn 'No third-party drivers found on this PC.'; return @() }
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
            Class = [string]$d.ClassName; Provider = [string]$d.ProviderName; Version = [string]$d.Version; Date = $date; Arch = $hostArch
            'Size (MB)' = [math]::Round($size / 1MB, 1); Inf = $inf; Folder = $folder; FullDir = $path
        }
    }
    $items = @(Set-OlderDrivers @($items | Sort-Object Class, Provider))
    Write-Ok "$($items.Count) driver packages found on this PC."
    $old = @($items | Where-Object { $_.Older }).Count
    if ($old) { Write-Info "$old of them are older versions of a driver that is there in a newer version too - they are unticked in the list." }
    return $items
}
function Save-HostDrivers($Pick) {
    $pick = @($Pick)
    $exp = Join-Path $Script:P.Drivers 'host_export'
    if ($pick.Count -eq 0) { Remove-Item -LiteralPath $exp -Recurse -Force -ErrorAction SilentlyContinue; return }
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
function Save-ImportDrivers([string]$Dir, $Pick) {
    $pick = @($Pick)
    $target = ''
    if ($Script:S.Family) { $target = [string]$Script:S.Family.Arch }
    $wrong = @($pick | Where-Object { -not (Test-DriverArch $_.Arch $target) })
    if ($wrong.Count -gt 0) {
        Write-Warn "$($wrong.Count) picked driver(s) are not built for $target and were left out."
        $pick = @($pick | Where-Object { Test-DriverArch $_.Arch $target })
    }
    if ($pick.Count -eq 0) { Write-Warn 'No drivers imported.'; return }
    $name = (Split-Path $Dir -Leaf) -replace '[^\w\.-]', '_'
    if (-not $name) { $name = 'drivers' }
    $base = Join-Path (Join-Path $Script:P.DrvSel 'import') $name
    Reset-Dir $base
    Write-Step "Copying $($pick.Count) driver(s) into the work folder"
    $rootTrim = $Dir.TrimEnd('\', '/')
    $dirs = @($pick | ForEach-Object { $_.FullDir } | Sort-Object -Unique | Sort-Object Length)
    $done = New-Object System.Collections.Generic.List[string]
    foreach ($d in $dirs) {
        $inside = $false
        foreach ($c in $done) { if ($d -eq $c -or $d.StartsWith($c.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break } }
        if ($inside) { continue }
        $rel = ''
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
    $Script:Cfg.LastDriverFolder = $Dir
    Save-Settings
    $boot = @($pick | Where-Object { $Script:BootClasses -contains $_.Class }).Count
    Write-Ok "$($pick.Count) driver(s) imported from $Dir ($boot storage/network also go into boot.wim and WinRE)."
}
function Remove-DriverEntries([int[]]$Numbers) {
    $d = @($Script:S.Drivers)
    $keep = @()
    for ($i = 0; $i -lt $d.Count; $i++) {
        if ($Numbers -contains ($i + 1)) {
            $folder = Join-Path $Script:P.DrvSel $d[$i].Folder
            if ($d[$i].Source -eq 'host') { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
            else { Remove-Item -LiteralPath (Join-Path $folder $d[$i].Inf) -Force -ErrorAction SilentlyContinue }
        } else { $keep += $d[$i] }
    }
    $Script:S.Drivers = $keep
    Save-State
    Write-Ok "$($d.Count - $keep.Count) driver(s) removed."
}
#endregion

#region ---------------------------------------------------------------- answer file
function Set-UnattendFile([string]$File) {
    [void](Test-UnattendFile $File)
    New-Item -ItemType Directory -Force -Path $Script:P.Work | Out-Null
    Copy-Item -LiteralPath $File -Destination $Script:P.Unattend -Force
    Remove-Item -LiteralPath (Join-Path $Script:P.Work 'autounattend.original.xml') -Force -ErrorAction SilentlyContinue
    $Script:S.Unattend = [ordered]@{ Source = $File; Added = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    Save-State
    Sync-Unattend
    Write-Ok "autounattend.xml added (from $File)"
}
function Clear-UnattendFile {
    if ($Script:S.Unattend) { Remove-Item -LiteralPath (Join-Path $Script:P.Media 'autounattend.xml') -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $Script:P.Unattend -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Script:P.Work 'autounattend.original.xml') -Force -ErrorAction SilentlyContinue
    $Script:S.Unattend = $null
    Save-State
    Write-Ok 'autounattend.xml removed.'
}
#endregion

#region ---------------------------------------------------------------- run everything / clean / job entry point
function Invoke-RunAll($A) {
    Write-Title "Run everything - $Script:AppName $Script:AppVersion"
    $iso = if ($A.Iso) { [string]$A.Iso } else { [string]$Script:S.SourceIso }
    $fresh = (-not $Script:S.Unpacked) -or $Script:S.Serviced -or ($iso -and $iso -ne $Script:S.SourceIso)
    if ($fresh) {
        if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { throw 'Choose the source ISO first (page 1).' }
        if ($Script:S.Serviced) { Write-Info 'The unpacked media was already serviced - unpacking a fresh copy.' }
        $Script:IsoPath = $iso
        $Script:NoAsk = $true
        Invoke-Unpack
        $Script:NoAsk = $false
    } else { Invoke-Analyze }
    $n = @($Script:S.Images).Count
    if (@($Script:S.Selected).Count -eq 0) {
        if ($n -gt 1 -and -not (Read-YesNo "No edition is ticked. Update and keep all $n editions? They are updated one after the other, so this takes about $n times as long as one edition - No stops here, so you can tick only the ones you need on page 2." $true)) { throw 'Tick the editions on page 2, then run again.' }
        $Script:S.Selected = @($Script:S.Images | ForEach-Object { [int]$_.Index })
        Save-State
    }
    if ($Script:S.Family.Supported) { Invoke-Download -Auto } else { Write-Warn 'Updates skipped (unsupported build).' }
    Invoke-Service -Auto
    Invoke-Build -Auto -OutIso $A.Out
    Write-Title 'Everything done'
    Write-Ok $Script:S.Iso
}
# Turns what is typed in "Output ISO" into a full file path: a folder gets the default file name,
# a bare name goes into the output folder, ".iso" is added. Bad input gets a clear message
# instead of .NET's "The path is not of a legal form".
function Resolve-OutIso([string]$Want, [string]$Default) {
    $w = ([string]$Want).Trim().Trim('"').Trim()
    if (-not $w) { return $Default }
    $hint = ' - clear the "Output ISO" box on the Build page to use the default name, or pick a file with "Save as...".'
    if ($w.IndexOfAny([char[]]'*?<>|"') -ge 0 -or $w.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { throw "The output ISO path has characters Windows does not allow: $w$hint" }
    $outDir = Split-Path $Default -Parent
    $isDir = $w -match '[\\/]$' -or (Test-Path -LiteralPath $w -PathType Container)
    if ($isDir) { $w = Join-Path $w (Split-Path $Default -Leaf) }
    elseif ($w -match '^[A-Za-z]:[^\\/]' -or -not [IO.Path]::IsPathRooted($w)) {
        # "Win10.iso" or "E:Win10.iso" - no folder given
        $w = Join-Path $outDir ($w -replace '^[A-Za-z]:', '')
    }
    if ($w -notmatch '(?i)\.iso$') { $w += '.iso' }
    try { $full = [IO.Path]::GetFullPath($w) } catch { throw "The output ISO path is not valid: $w$hint" }
    if ($full.Substring(2) -match ':') { throw "The output ISO path is not valid (':' inside the name): $w$hint" }
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -and -not (Test-Path -LiteralPath $root)) { throw "Drive $root does not exist (output ISO: $full)$hint" }
    return $full
}
function Invoke-CleanJob($A) {
    Write-Title 'Clean up'
    Clear-Mounts
    Remove-Item -LiteralPath $Script:P.Temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Script:P.Work 'mnt') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok 'Leftover mounts and temporary files removed.'
    if ($A.Updates -and (Test-Path -LiteralPath $Script:P.Updates)) {
        Remove-Item -LiteralPath $Script:P.Updates -Recurse -Force; $Script:S.Updates = @(); Write-Ok 'Downloaded updates deleted.'
    }
    if ($A.Media -and (Test-Path -LiteralPath $Script:P.Media)) {
        Remove-Item -LiteralPath $Script:P.Media -Recurse -Force
        $Script:S.Unpacked = $false; $Script:S.Serviced = $null; $Script:S.Images = @(); $Script:S.Family = $null; $Script:S.Selected = @(); $Script:S.OemSynced = $false
        Write-Ok 'Unpacked media deleted.'
    }
    if ($A.Output -and (Test-Path -LiteralPath $Script:P.Output)) {
        Remove-Item -LiteralPath $Script:P.Output -Recurse -Force; $Script:S.Iso = $null; Write-Ok 'Built ISOs deleted.'
    }
    if ($A.Signed -and (Test-Path -LiteralPath $Script:P.Signed)) {
        Remove-Item -LiteralPath $Script:P.Signed -Recurse -Force; $Script:S.Signed = @(); Write-Ok 'Re-signed driver copies deleted.'
    }
    if ($A.Drivers -and (Test-Path -LiteralPath $Script:P.Drivers)) {
        Remove-Item -LiteralPath $Script:P.Drivers -Recurse -Force; $Script:S.Drivers = @(); Write-Ok 'Copied drivers deleted (this PC / imported folder).'
    }
    if ($A.Extra) {
        $n = 0
        foreach ($f in @($Script:P.Unattend, (Join-Path $Script:P.Work 'autounattend.original.xml'), (Join-Path $Script:P.Work 'install-check.json'))) {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; $n++ }
        }
        if ($Script:S.Unattend) { $Script:S.Unattend = $null; Write-Info 'The answer file is no longer added - choose it again on page 6 (your own file is not touched).' }
        $Script:S.Check = $null
        if ($n) { Write-Ok 'Answer file copy and install check results deleted.' }
    }
    if ($A.All) {
        # start from scratch: everything this tool keeps in the work folder goes, the state starts empty.
        # Only its own names are deleted - anything else in that folder is left alone.
        $own = @('media', 'updates', 'drivers', 'signed', 'output', 'temp', 'mnt', 'logs', 'state.json', 'autounattend.xml',
                 'autounattend.original.xml', 'install-check.json', 'defender-exclusion.txt')
        $Script:LogFile = $null
        foreach ($n in $own) {
            $f = Join-Path $Script:P.Work $n
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $Script:S = New-State
        $left = @($own | Where-Object { Test-Path -LiteralPath (Join-Path $Script:P.Work $_) })
        $other = @(Get-ChildItem -LiteralPath $Script:P.Work -Force -ErrorAction SilentlyContinue | Where-Object { $own -notcontains $_.Name.ToLower() })
        if ($left.Count) { Write-Warn "Could not delete: $($left -join ', ') (in use?)" }
        else { Write-Ok "Work folder $($Script:P.Work) is clean - settings and your signing certificate (next to the .cmd) are kept." }
        if ($other.Count) { Write-Info "Not made by this tool, left alone: $((@($other | ForEach-Object Name) | Select-Object -First 5) -join ', ')" }
        return
    }
    Save-State
    if ($A.Logs -and (Test-Path -LiteralPath $Script:P.Logs)) {
        Get-ChildItem -LiteralPath $Script:P.Logs -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $Script:LogFile = $null
        Write-Ok 'Logs deleted.'
    }
}
# Option "Let Windows Defender skip the work folder while a job runs": real-time scanning of
# every file DISM, robocopy and oscdimg touch slows servicing a lot. The exclusion is added for
# the job only and removed afterwards; a marker file makes sure a crash cannot leave it behind.
function Enable-DefenderSkip {
    if (-not $Script:Cfg.DefenderExclude) { return }
    $w = [IO.Path]::GetFullPath($Script:P.Work).TrimEnd('\')
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        if (@($pref.ExclusionPath) -contains $w) { Add-Log "Defender already excludes $w (left as it is)"; return }
        New-Item -ItemType Directory -Force -Path $w | Out-Null
        Add-MpPreference -ExclusionPath $w -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path $w 'defender-exclusion.txt') -Value $w -Encoding UTF8
        $Script:DefenderAdded = $w
        Write-Info "Windows Defender skips $w during this job (removed again at the end)."
    } catch {
        # 0x800106ba: the Defender service is not running (turned off, or another antivirus) - nothing scans the folder
        if ($_.Exception.Message -match '800106ba') { Write-Info 'Windows Defender is not running on this PC - there is no scan to skip.' }
        else { Write-Warn "Could not add the Defender exclusion ($($_.Exception.Message)) - normal scanning stays on." }
    }
}
function Disable-DefenderSkip {
    $w = $Script:DefenderAdded
    $marker = $null
    if ($Script:P -and $Script:P.Work) { $marker = Join-Path $Script:P.Work 'defender-exclusion.txt' }
    if (-not $w -and $marker -and (Test-Path -LiteralPath $marker)) { $w = [string](Get-Content -LiteralPath $marker -TotalCount 1) }
    if (-not $w) { return }
    try { Remove-MpPreference -ExclusionPath $w -ErrorAction Stop; Add-Log "Defender exclusion removed: $w" }
    catch { Add-Log "Defender exclusion not removed: $($_.Exception.Message)" }
    if ($marker) { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue }
    $Script:DefenderAdded = $null
}
# Entry point of the background worker. State is re-read from disk for every job.
function Invoke-Job([string]$Job, $A) {
    if ($null -eq $A) { $A = @{} }
    $Script:Cfg = Import-Settings
    Initialize-Paths
    $Script:S = Import-State
    $Script:Dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    if ($Script:S.Family -and $Script:S.Family.Build) { $Script:Dism = Get-ServicingDism ([int]$Script:S.Family.Build) }   # the ADK's DISM for Windows 11 on a Windows 10 PC
    $Script:NoAsk = [bool]$A.NoAsk
    $Script:Sync.Result = $null
    New-Item -ItemType Directory -Force -Path $Script:P.Logs | Out-Null
    $Script:LogFile = Join-Path $Script:P.Logs 'engine.log'
    $Script:DismLog = Join-Path $Script:P.Logs 'dism.log'
    Add-Log "---- $Script:AppName $Script:AppVersion  job=$Job"
    try {
        Disable-DefenderSkip       # leftover from a run that was killed
        if ($Job -in 'Unpack', 'Download', 'Sign', 'Service', 'Build', 'All') { Enable-DefenderSkip }
        switch ($Job) {
            'CheckIso'     { $Script:Sync.Result = Test-IsoOriginal ([string]$A.Iso) }
            'Unpack'       { $Script:IsoPath = [string]$A.Iso; Invoke-Unpack }
            'Analyze'      { Invoke-Analyze }
            'Download'     { Invoke-Download -Auto }
            'ScanHost'     { $Script:Sync.Result = @(Get-HostDriverScan) }
            'CommitHost'   { Save-HostDrivers $A.Pick }
            'ScanFolder'   {
                Write-Step "Scanning $($A.Dir)"
                $Script:Sync.Result = @(Set-OlderDrivers @(Get-DriverPackages $A.Dir | Sort-Object Class, Provider, Inf))
                Write-Ok "$(@($Script:Sync.Result).Count) driver(s) found."
            }
            'CommitImport' { Save-ImportDrivers $A.Dir $A.Pick }
            'Sign'         { Invoke-SignPackage $A.Source $A.Name $A.Password ([bool]$A.All) ([bool]$Script:Cfg.SignOnlyThisPc) ([bool]$Script:Cfg.SignIsolate) (Get-SignJobs) (Get-SignEngine) }
            'Service'      { Invoke-Service -Auto }
            'Build'        { Invoke-Build -Auto -OutIso ([string]$A.Out) }
            'All'          { Invoke-RunAll $A }
            'Tools'        { Get-AllTools }
            'Check'        { $Script:Sync.Result = @(Invoke-InstallCheck) }
            'Fix'          { Invoke-InstallFixes @($A.Fixes); $Script:Sync.Result = @(Invoke-InstallCheck) }
            'Clean'        { Invoke-CleanJob $A }
            default        { throw "Unknown job: $Job" }
        }
    } catch {
        Write-Err $_.Exception.Message
        Add-Log ($_ | Out-String)
        throw
    } finally {
        try { Disable-DefenderSkip } catch { }
        if ($Script:Sync) { $Script:Sync.Pct = -1; $Script:Sync.Status = ''; $Script:Sync.SideSync = $null }
    }
}
#endregion
#ENGINE-END
# ============================================================================
#  GUI - WPF, dark theme. Long work runs in a background runspace (the engine
#  above) so the window stays responsive; its log lines stream into the
#  Activity panel and DISM / curl percentages drive the progress bar.
# ============================================================================
$Script:XRes = @'
    <LinearGradientBrush x:Key="Grad" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#2F9BFF" Offset="0"/>
      <GradientStop Color="#8B5CF6" Offset="1"/>
    </LinearGradientBrush>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#141A27"/>
      <Setter Property="BorderBrush" Value="#232B3D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="18,16"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#F4F6FB"/>
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#DCE3F0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#A3ADC2"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="Background" Value="#222B3F"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.65"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Grad}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Padding" Value="22,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="#222B3F" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Grad}"/>
                <Setter Property="Foreground" Value="White"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="Margin" Value="0,5,0,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Border x:Name="track" Width="38" Height="20" CornerRadius="10" Background="#2A3348" VerticalAlignment="Top" Margin="0,1,0,0">
                <Ellipse x:Name="knob" Width="14" Height="14" Fill="#AEB7C8" HorizontalAlignment="Left" Margin="3,0,3,0"/>
              </Border>
              <ContentPresenter Grid.Column="1" Margin="10,2,0,0" VerticalAlignment="Top"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{StaticResource Grad}"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="knob" Property="Fill" Value="White"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0E131E"/>
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="BorderBrush" Value="#2A3348"/>
      <Setter Property="CaretBrush" Value="#F4F6FB"/>
      <Setter Property="SelectionBrush" Value="#2F9BFF"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="#0E131E"/>
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="BorderBrush" Value="#2A3348"/>
      <Setter Property="CaretBrush" Value="#F4F6FB"/>
      <Setter Property="Padding" Value="8,6"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#0E131E"/>
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="BorderBrush" Value="#232B3D"/>
      <Setter Property="RowBackground" Value="#111726"/>
      <Setter Property="AlternatingRowBackground" Value="#141B2B"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionMode" Value="Extended"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
      <Setter Property="AutoGenerateColumns" Value="True"/>
      <Setter Property="ColumnHeaderStyle">
        <Setter.Value>
          <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#1A2133"/>
            <Setter Property="Foreground" Value="#8A94A8"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="BorderThickness" Value="0,0,1,0"/>
            <Setter Property="BorderBrush" Value="#232B3D"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
          </Style>
        </Setter.Value>
      </Setter>
      <Setter Property="CellStyle">
        <Setter.Value>
          <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="DataGridCell">
                  <Border Background="{TemplateBinding Background}" Padding="9,5">
                    <ContentPresenter VerticalAlignment="Center"/>
                  </Border>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
            <Style.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter Property="Background" Value="#24406E"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </Style.Triggers>
          </Style>
        </Setter.Value>
      </Setter>
    </Style>
'@

$Script:XMain = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows ISO Updater" Width="1220" Height="800" MinWidth="1040" MinHeight="680"
        WindowStartupLocation="CenterScreen" Background="#0B0E14" Foreground="#E6EAF2"
        FontFamily="Segoe UI" FontSize="13" WindowStyle="None" ResizeMode="CanResize" BorderBrush="#232B3D" BorderThickness="1">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="54" ResizeBorderThickness="6" CornerRadius="0" GlassFrameThickness="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
__RES__
    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Foreground" Value="#AEB7C8"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#2A3142"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="Margin" Value="12,2,12,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="nav"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="bd" Background="Transparent" CornerRadius="10" Padding="12,8">
              <Grid>
                <Border x:Name="bar" Width="3" HorizontalAlignment="Left" Margin="-12,3,0,3" CornerRadius="2" Background="{StaticResource Grad}" Visibility="Hidden"/>
                <ContentPresenter/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#161D2C"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#1C2538"/>
                <Setter TargetName="bar" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Num" TargetType="Border">
      <Setter Property="Width" Value="24"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Background" Value="#1A2133"/>
      <Setter Property="BorderThickness" Value="2"/>
      <Setter Property="BorderBrush" Value="#5B6478"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="Margin" Value="0,1,0,0"/>
    </Style>
  </Window.Resources>

  <Grid x:Name="Root">
    <Grid.RowDefinitions>
      <RowDefinition Height="54"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="5"/>
      <RowDefinition Height="200" MinHeight="90"/>
    </Grid.RowDefinitions>

    <!-- title bar -->
    <Grid Grid.Row="0" Background="#0E121B">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="18,0,0,0">
        <Border Width="32" Height="32" CornerRadius="9" Background="{StaticResource Grad}">
          <TextBlock Text="W10" Foreground="White" FontWeight="Bold" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
          <TextBlock FontSize="15" FontWeight="SemiBold"><Run Text="Windows ISO Updater"/><Run x:Name="VerRun" Text="  v4.4.0" Foreground="#5B6478" FontWeight="Normal" FontSize="12"/></TextBlock>
          <TextBlock Text="updates + drivers + signed NVIDIA mods + autounattend + $OEM$  ->  bootable ISO" Foreground="#8A94A8" FontSize="11"/>
        </StackPanel>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,10,0">
        <Button x:Name="ThemeBtn" Style="{StaticResource Chrome}" FontSize="14" Content="&#xE706;" ToolTip="Light theme" AutomationProperties.Name="Switch to the light theme"/>
        <Button x:Name="A11yBtn" Style="{StaticResource Chrome}" FontSize="14" Content="&#xE776;" ToolTip="Display and accessibility: theme, text size, font" AutomationProperties.Name="Display and accessibility settings"/>
        <Border Width="1" Height="18" Background="#232B3D" Margin="6,0,6,0" VerticalAlignment="Center"/>
        <Button x:Name="MinBtn" Style="{StaticResource Chrome}" Content="&#xE921;" ToolTip="Minimize" AutomationProperties.Name="Minimize"/>
        <Button x:Name="MaxBtn" Style="{StaticResource Chrome}" Content="&#xE922;" ToolTip="Maximize" AutomationProperties.Name="Maximize"/>
        <Button x:Name="CloseBtn" Style="{StaticResource Chrome}" Content="&#xE8BB;" ToolTip="Close" AutomationProperties.Name="Close"/>
      </StackPanel>
      <Popup x:Name="A11yPop" PlacementTarget="{Binding ElementName=A11yBtn}" Placement="Bottom" HorizontalOffset="-300" VerticalOffset="6" StaysOpen="False" AllowsTransparency="True">
        <Border x:Name="A11yPanel" Background="#141A27" BorderBrush="#232B3D" BorderThickness="1" CornerRadius="12" Padding="18,16" Width="346">
          <StackPanel>
            <TextBlock Style="{StaticResource H2}" Text="Display and accessibility"/>
            <TextBlock Text="Theme" FontWeight="SemiBold" Margin="0,0,0,6"/>
            <WrapPanel>
              <RadioButton x:Name="ThemeDark" Style="{StaticResource Seg}" Padding="12,7" GroupName="theme" Content="Dark" Margin="0,0,6,6"/>
              <RadioButton x:Name="ThemeLight" Style="{StaticResource Seg}" Padding="12,7" GroupName="theme" Content="Light" Margin="0,0,6,6"/>
              <RadioButton x:Name="ThemeSystem" Style="{StaticResource Seg}" Padding="12,7" GroupName="theme" Content="Like Windows" Margin="0,0,0,6"/>
            </WrapPanel>
            <TextBlock Text="Text size" FontWeight="SemiBold" Margin="0,8,0,6"/>
            <WrapPanel>
              <RadioButton x:Name="Zoom100" Style="{StaticResource Seg}" Padding="12,7" GroupName="zoom" Content="100%" Margin="0,0,6,6"/>
              <RadioButton x:Name="Zoom115" Style="{StaticResource Seg}" Padding="12,7" GroupName="zoom" Content="115%" Margin="0,0,6,6"/>
              <RadioButton x:Name="Zoom130" Style="{StaticResource Seg}" Padding="12,7" GroupName="zoom" Content="130%" Margin="0,0,6,6"/>
              <RadioButton x:Name="Zoom150" Style="{StaticResource Seg}" Padding="12,7" GroupName="zoom" Content="150%" Margin="0,0,0,6"/>
            </WrapPanel>
            <TextBlock Text="Font" FontWeight="SemiBold" Margin="0,8,0,6"/>
            <WrapPanel>
              <RadioButton x:Name="FontSegoe" Style="{StaticResource Seg}" Padding="12,7" GroupName="font" Content="Segoe UI" FontFamily="Segoe UI" Margin="0,0,6,6"/>
              <RadioButton x:Name="FontVerdana" Style="{StaticResource Seg}" Padding="12,7" GroupName="font" Content="Verdana" FontFamily="Verdana" Margin="0,0,6,6"/>
              <RadioButton x:Name="FontTahoma" Style="{StaticResource Seg}" Padding="12,7" GroupName="font" Content="Tahoma" FontFamily="Tahoma" Margin="0,0,6,6"/>
              <RadioButton x:Name="FontArial" Style="{StaticResource Seg}" Padding="12,7" GroupName="font" Content="Arial" FontFamily="Arial" Margin="0,0,0,6"/>
            </WrapPanel>
            <TextBlock Text="Language" FontWeight="SemiBold" Margin="0,8,0,6"/>
            <WrapPanel>
              <RadioButton x:Name="LangAuto" Style="{StaticResource Seg}" Padding="12,7" GroupName="lang" Content="Like Windows" Margin="0,0,6,6"/>
              <RadioButton x:Name="LangEn" Style="{StaticResource Seg}" Padding="12,7" GroupName="lang" Content="English" Margin="0,0,6,6"/>
              <RadioButton x:Name="LangPt" Style="{StaticResource Seg}" Padding="12,7" GroupName="lang" Content="Portugu&#xEA;s" Margin="0,0,6,6"/>
              <RadioButton x:Name="LangEs" Style="{StaticResource Seg}" Padding="12,7" GroupName="lang" Content="Espa&#xF1;ol" Margin="0,0,6,6"/>
              <RadioButton x:Name="LangFr" Style="{StaticResource Seg}" Padding="12,7" GroupName="lang" Content="Fran&#xE7;ais" Margin="0,0,6,6"/>
              <RadioButton x:Name="LangDe" Style="{StaticResource Seg}" Padding="12,7" GroupName="lang" Content="Deutsch" Margin="0,0,6,6"/>
              <RadioButton x:Name="LangIt" Style="{StaticResource Seg}" Padding="12,7" GroupName="lang" Content="Italiano" Margin="0,0,0,6"/>
            </WrapPanel>
            <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,8,0,0" Text="Ctrl + plus / Ctrl + minus / Ctrl + 0 change the text size anywhere in the window. Verdana and Tahoma have wider, more distinct letters. Saved for the next start."/>
            <TextBlock Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" Text="The Activity log and the Install check findings stay in English - that is what a bug report or a search needs."/>
          </StackPanel>
        </Border>
      </Popup>
    </Grid>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="262"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- sidebar -->
      <Border Grid.Column="0" Background="#0E121B" BorderBrush="#1A2133" BorderThickness="0,1,1,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><DockPanel LastChildFill="False">
          <StackPanel DockPanel.Dock="Top" Margin="0,14,0,0">
            <TextBlock Text="STEPS" Foreground="#5B6478" FontSize="11" FontWeight="SemiBold" Margin="26,0,0,6"/>
            <RadioButton x:Name="Nav1" Style="{StaticResource Nav}" IsChecked="True">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Border x:Name="D1" Style="{StaticResource Num}"><TextBlock Text="1" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Source ISO" FontWeight="SemiBold"/><TextBlock x:Name="S1" Text="to do" FontSize="11" Foreground="#8A94A8" TextTrimming="CharacterEllipsis"/></StackPanel></Grid>
            </RadioButton>
            <RadioButton x:Name="Nav2" Style="{StaticResource Nav}">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Border x:Name="D2" Style="{StaticResource Num}"><TextBlock Text="2" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Editions" FontWeight="SemiBold"/><TextBlock x:Name="S2" Text="to do" FontSize="11" Foreground="#8A94A8" TextTrimming="CharacterEllipsis"/></StackPanel></Grid>
            </RadioButton>
            <RadioButton x:Name="Nav3" Style="{StaticResource Nav}">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Border x:Name="D3" Style="{StaticResource Num}"><TextBlock Text="3" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Windows updates" FontWeight="SemiBold"/><TextBlock x:Name="S3" Text="to do" FontSize="11" Foreground="#8A94A8" TextTrimming="CharacterEllipsis"/></StackPanel></Grid>
            </RadioButton>
            <RadioButton x:Name="Nav4" Style="{StaticResource Nav}">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Border x:Name="D4" Style="{StaticResource Num}"><TextBlock Text="4" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Drivers" FontWeight="SemiBold"/><TextBlock x:Name="S4" Text="optional" FontSize="11" Foreground="#8A94A8" TextTrimming="CharacterEllipsis"/></StackPanel></Grid>
            </RadioButton>
            <RadioButton x:Name="Nav5" Style="{StaticResource Nav}">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Border x:Name="D5" Style="{StaticResource Num}"><TextBlock Text="5" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Signed NVIDIA / modded" FontWeight="SemiBold"/><TextBlock x:Name="S5" Text="optional" FontSize="11" Foreground="#8A94A8" TextTrimming="CharacterEllipsis"/></StackPanel></Grid>
            </RadioButton>
            <RadioButton x:Name="Nav6" Style="{StaticResource Nav}">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Border x:Name="D6" Style="{StaticResource Num}"><TextBlock Text="6" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Answer file + $OEM$" FontWeight="SemiBold"/><TextBlock x:Name="S6" Text="optional" FontSize="11" Foreground="#8A94A8" TextTrimming="CharacterEllipsis"/></StackPanel></Grid>
            </RadioButton>
            <RadioButton x:Name="Nav10" Style="{StaticResource Nav}">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Border x:Name="D8" Style="{StaticResource Num}"><TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Install check" FontWeight="SemiBold"/><TextBlock x:Name="S8" Text="not run yet" FontSize="11" Foreground="#8A94A8" TextTrimming="CharacterEllipsis"/></StackPanel></Grid>
            </RadioButton>
            <RadioButton x:Name="Nav7" Style="{StaticResource Nav}">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Border x:Name="D7" Style="{StaticResource Num}"><TextBlock Text="7" FontSize="11" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                <StackPanel Grid.Column="1"><TextBlock Text="Slipstream + build ISO" FontWeight="SemiBold"/><TextBlock x:Name="S7" Text="to do" FontSize="11" Foreground="#8A94A8" TextTrimming="CharacterEllipsis"/></StackPanel></Grid>
            </RadioButton>
            <TextBlock Text="MORE" Foreground="#5B6478" FontSize="11" FontWeight="SemiBold" Margin="26,14,0,6"/>
            <RadioButton x:Name="Nav8" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE713;" FontFamily="Segoe MDL2 Assets" Width="34" VerticalAlignment="Center" Foreground="#8A94A8"/><TextBlock Text="Options and clean up" FontWeight="SemiBold"/></StackPanel>
            </RadioButton>
            <RadioButton x:Name="Nav9" Style="{StaticResource Nav}">
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE90F;" FontFamily="Segoe MDL2 Assets" Width="34" VerticalAlignment="Center" Foreground="#8A94A8"/><TextBlock Text="Tools" FontWeight="SemiBold"/><TextBlock x:Name="ToolsDot" Text="" Foreground="#FFC857" Margin="8,0,0,0"/></StackPanel>
            </RadioButton>
          </StackPanel>
          <StackPanel DockPanel.Dock="Bottom" Margin="16,0,16,16">
            <Button x:Name="RunAll" Style="{StaticResource Primary}" Padding="14,13" Margin="0" FontSize="14">
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE768;" FontFamily="Segoe MDL2 Assets" VerticalAlignment="Center" Margin="0,0,10,0"/><TextBlock Text="Run everything"/></StackPanel>
            </Button>
            <TextBlock Text="unpack - updates - slipstream - ISO, using what you set on each page" Style="{StaticResource Sub}" FontSize="11" Margin="2,8,0,0"/>
          </StackPanel>
        </DockPanel></ScrollViewer>
      </Border>

      <!-- main -->
      <Grid Grid.Column="1">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Margin="24,16,24,0" Padding="18,12" CornerRadius="12" BorderBrush="#232B3D" BorderThickness="1" Background="{DynamicResource HeaderBg}">
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="1.1*"/><ColumnDefinition Width="1.6*"/><ColumnDefinition Width="1.2*"/></Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Margin="0,0,14,0"><TextBlock Text="SOURCE" Foreground="#6F7A90" FontSize="10" FontWeight="SemiBold"/><TextBlock x:Name="HdrIso" Text="-" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/></StackPanel>
            <StackPanel Grid.Column="1" Margin="0,0,14,0"><TextBlock Text="IMAGE" Foreground="#6F7A90" FontSize="10" FontWeight="SemiBold"/><TextBlock x:Name="HdrImg" Text="-" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/></StackPanel>
            <StackPanel Grid.Column="2"><TextBlock Text="WORK FOLDER" Foreground="#6F7A90" FontSize="10" FontWeight="SemiBold"/><TextBlock x:Name="HdrWork" Text="-" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/></StackPanel>
          </Grid>
        </Border>

        <TabControl x:Name="Pages" Grid.Row="1" Background="Transparent" Foreground="#E6EAF2" BorderThickness="0" Padding="0">
__PAGES__
        </TabControl>
      </Grid>
    </Grid>

    <GridSplitter Grid.Row="2" HorizontalAlignment="Stretch" Background="#141A27" ResizeDirection="Rows" ResizeBehavior="PreviousAndNext"/>

    <!-- activity -->
    <Border Grid.Row="3" Background="#0A0D13">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Grid Margin="18,8,14,6">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse x:Name="BusyDot" Width="8" Height="8" Fill="#3DDC97" Margin="0,0,8,0"/>
            <TextBlock Text="ACTIVITY" Foreground="#6F7A90" FontSize="11" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <TextBlock x:Name="BusyText" Text="Ready" Margin="14,0,0,0" VerticalAlignment="Center" FontWeight="SemiBold"/>
          </StackPanel>
          <Grid Grid.Column="1" Margin="18,0,18,0" VerticalAlignment="Center">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <ProgressBar x:Name="Prog" Height="6" Minimum="0" Maximum="100" Background="#1A2133" BorderThickness="0" Foreground="#2F9BFF" Visibility="Hidden"/>
            <TextBlock x:Name="StatusText" Grid.Column="1" Foreground="#8A94A8" Margin="12,0,0,0" FontSize="11" MaxWidth="680" TextTrimming="CharacterEllipsis"/>
          </Grid>
          <StackPanel Grid.Column="2" Orientation="Horizontal">
            <Button x:Name="LogOpen" Style="{StaticResource Btn}" Content="Logs folder" Padding="10,4" FontSize="12"/>
            <Button x:Name="LogClear" Style="{StaticResource Btn}" Content="Clear" Padding="10,4" FontSize="12" Margin="0"/>
          </StackPanel>
        </Grid>
        <RichTextBox x:Name="LogBox" Grid.Row="1" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#AEB7C8"
                     FontFamily="Consolas" FontSize="12" Padding="14,0,14,8" VerticalScrollBarVisibility="Auto" IsDocumentEnabled="False">
          <RichTextBox.Resources><Style TargetType="Paragraph"><Setter Property="Margin" Value="0"/></Style></RichTextBox.Resources>
          <FlowDocument/>
        </RichTextBox>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
$Script:XPages = @'
          <!-- 1 source -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Source ISO"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Choose Windows 10 or Windows 11 and pick its ISO. It is copied into the work folder and its build and editions are detected - the version follows the ISO you unpack."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Windows version"/>
              <StackPanel Orientation="Horizontal">
                <RadioButton x:Name="WinVer10" Style="{StaticResource Seg}" GroupName="winver" Content="Windows 10"/>
                <RadioButton x:Name="WinVer11" Style="{StaticResource Seg}" GroupName="winver" Content="Windows 11"/>
              </StackPanel>
              <TextBlock x:Name="WinVerNote" Style="{StaticResource Sub}" Margin="0,10,0,0"/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="ISO file"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,10" Text="Use an original ISO from Microsoft. Before it is unpacked, its SHA-256 is compared with the ones Microsoft publishes for its Windows 10 and 11 ISOs - the list in this program and, when online, the download pages on microsoft.com. When it is not there (an ISO made with the Media Creation Tool never is), the Microsoft signatures of its setup and boot files are checked."/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="IsoBox" Margin="0,0,8,0"/>
                <Button x:Name="IsoBrowse" Grid.Column="1" Style="{StaticResource Btn}" Content="Browse..." Margin="0"/>
              </Grid>
              <WrapPanel Margin="0,14,0,0">
                <Button x:Name="UnpackBtn" Style="{StaticResource Primary}" Content="Unpack and analyze"/>
                <Button x:Name="IsoCheckBtn" Style="{StaticResource Btn}" Content="Check the ISO"/>
                <Button x:Name="AnalyzeBtn" Style="{StaticResource Btn}" Content="Re-read image info"/>
                <Button x:Name="GetIsoBtn" Style="{StaticResource Btn}" Content="Download Windows 10 from Microsoft"/>
              </WrapPanel>
              <StackPanel x:Name="IsoCheckPanel" Margin="0,12,0,0" Visibility="Collapsed">
                <TextBlock x:Name="IsoCheckText" FontWeight="SemiBold" TextWrapping="Wrap"/>
                <TextBlock x:Name="IsoCheckNote" Style="{StaticResource Sub}" Margin="0,4,0,0"/>
                <TextBox x:Name="IsoHashBox" IsReadOnly="True" FontFamily="Consolas" Margin="0,8,0,0" Visibility="Collapsed" ToolTip="SHA-256 of the ISO - select it to copy"/>
              </StackPanel>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Detected image"/>
              <TextBlock x:Name="ImgInfo" FontSize="14" FontWeight="SemiBold" TextWrapping="Wrap" Text="Nothing unpacked yet."/>
              <TextBlock x:Name="ImgNote" Style="{StaticResource Sub}" Margin="0,4,0,12"/>
              <DataGrid x:Name="ImgGrid" Height="210"/>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 2 editions -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Editions"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Tick the editions to update. With the option below on, unticked editions are left out of the new ISO (smaller and faster)."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <WrapPanel Margin="0,0,0,12">
                <Button x:Name="EdAll" Style="{StaticResource Btn}" Content="Tick all"/>
                <Button x:Name="EdNone" Style="{StaticResource Btn}" Content="Tick none"/>
              </WrapPanel>
              <DataGrid x:Name="EdGrid" Height="300" IsReadOnly="False">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Header="Use" Width="54">
                    <DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Use, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" Cursor="Hand"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
              <CheckBox x:Name="cfg_KeepOnlySelected" Style="{StaticResource Toggle}" Margin="0,14,0,0" Content="Keep only the ticked editions in the new ISO"/>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 3 updates -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Windows updates"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Finds the newest cumulative update, servicing stack, Safe OS and Setup Dynamic Updates and .NET updates for this build in the Microsoft Update Catalog and downloads them (SHA-1 checked)."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="What to integrate"/>
              <CheckBox x:Name="cfg_NetFx481" Style="{StaticResource Toggle}" Content="Add .NET Framework 4.8.1 (Windows 10 2004-22H2 - Windows 11 has it built in)"/>
              <CheckBox x:Name="cfg_NetFx3" Style="{StaticResource Toggle}" Content="Enable .NET Framework 3.5 (from the ISO's sources\sxs)"/>
              <CheckBox x:Name="cfg_ResetBase" Style="{StaticResource Toggle}" Content="Component cleanup /ResetBase (smaller image - updates can't be uninstalled)"/>
              <StackPanel x:Name="CutoffRow" Orientation="Horizontal" Margin="0,12,0,0">
                <TextBlock Text="Newest month to integrate" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBox x:Name="CutoffBox" Width="90"/>
                <TextBlock Style="{StaticResource Sub}" VerticalAlignment="Center" Margin="12,0,0,0" Text="YYYY-MM, for Windows 10 2004-22H2 / LTSC 2021"/>
              </StackPanel>
              <TextBlock x:Name="CutoffNote" Style="{StaticResource Sub}" Margin="0,6,0,0" Text="2025-10 is the last Windows 10 update Microsoft allows offline. ESU updates (Nov 2025+) come from Windows Update after setup on enrolled PCs."/>
              <WrapPanel Margin="0,14,0,0"><Button x:Name="UpdBtn" Style="{StaticResource Primary}" Content="Find and download updates"/></WrapPanel>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Downloaded"/>
              <DataGrid x:Name="UpdGrid" Height="210"/>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 4 drivers -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Drivers"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Signed drivers are slipstreamed into install.wim with DISM, so Windows installs them on first boot. Storage and network drivers also go into boot.wim and WinRE, so Setup sees RAID / VMD disks. Modded drivers (edited INF) belong on the next page."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <WrapPanel Margin="0,0,0,12">
                <Button x:Name="DrvHost" Style="{StaticResource Primary}" Content="Add drivers from this PC"/>
                <Button x:Name="DrvImport" Style="{StaticResource Btn}" Content="Import a drivers folder"/>
                <Button x:Name="DrvRemove" Style="{StaticResource Btn}" Content="Remove selected"/>
                <Button x:Name="DrvClear" Style="{StaticResource Btn}" Content="Clear all"/>
              </WrapPanel>
              <TextBlock x:Name="DrvSum" Style="{StaticResource Sub}" Margin="0,0,0,8"/>
              <DataGrid x:Name="DrvGrid" Height="290"/>
              <CheckBox x:Name="cfg_BootDrivers" Style="{StaticResource Toggle}" Margin="0,14,0,0" Content="Also put storage and network drivers into boot.wim and WinRE"/>
              <CheckBox x:Name="cfg_ForceUnsigned" Style="{StaticResource Toggle}" Content="Allow unsigned drivers in DISM (/ForceUnsigned)"/>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 5 signed / modded -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Signed NVIDIA / modded drivers"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="For driver packages whose INF was edited - NVCleanstall hardware-ID mods for an unsupported GPU, custom INF files. The edit breaks the catalog signature, so Windows refuses them. Every subfolder is scanned; each modified package gets a new catalog (MakeCat by default, or the engine you pick below) signed with your own certificate. The package is added to the ISO through $OEM$ and installed by SetupComplete.cmd at the end of Windows setup, right after the certificate is trusted."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Driver package"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="Folder" VerticalAlignment="Center"/>
                <TextBox x:Name="SignSrc" Grid.Column="1" Margin="0,0,8,0"/>
                <Button x:Name="SignBrowse" Grid.Column="2" Style="{StaticResource Btn}" Content="Browse..." Margin="0"/>
              </Grid>
              <Grid Margin="0,10,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="220"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <TextBlock Text="Name" VerticalAlignment="Center"/>
                <TextBox x:Name="SignName" Grid.Column="1" Text="NVIDIA"/>
                <TextBlock x:Name="SignDest" Grid.Column="2" Style="{StaticResource Sub}" VerticalAlignment="Center" Margin="12,0,0,0" Text="installs from C:\Drivers\NVIDIA during setup"/>
              </Grid>
              <Grid Margin="0,12,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <TextBlock Text="Engine" VerticalAlignment="Top" Margin="0,7,0,0"/>
                <WrapPanel Grid.Column="1">
                  <RadioButton x:Name="SignEngMakeCat" Style="{StaticResource Seg}" Padding="14,7" Margin="0,0,6,6" GroupName="signeng" Content="MakeCat" AutomationProperties.Name="Signing engine: MakeCat"/>
                  <RadioButton x:Name="SignEngLibwdi" Style="{StaticResource Seg}" Padding="14,7" Margin="0,0,6,6" GroupName="signeng" Content="libwdi-style" AutomationProperties.Name="Signing engine: libwdi-style"/>
                  <RadioButton x:Name="SignEngGenCat" Style="{StaticResource Seg}" Padding="14,7" Margin="0,0,6,6" GroupName="signeng" Content="generate-cat-file (WSL)" AutomationProperties.Name="Signing engine: generate-cat-file in WSL"/>
                  <RadioButton x:Name="SignEngInf2Cat" Style="{StaticResource Seg}" Padding="14,7" Margin="0,0,0,6" GroupName="signeng" Content="Inf2Cat" AutomationProperties.Name="Signing engine: Inf2Cat"/>
                </WrapPanel>
              </Grid>
              <TextBlock x:Name="SignEngNote" Style="{StaticResource Sub}" Margin="110,2,0,0"/>
              <CheckBox x:Name="SignAll" Style="{StaticResource Toggle}" Margin="0,12,0,0" Content="Re-sign every package, not only the modified ones"/>
              <CheckBox x:Name="cfg_SignCleanup" Style="{StaticResource Toggle}" Content="Delete the driver copy from C:\Drivers once it is installed"/>
              <CheckBox x:Name="cfg_SignIsolate" Style="{StaticResource Toggle}" Content="Faster: new catalogs only for the INF files that need one"/>
              <TextBlock Style="{StaticResource Sub}" Margin="48,-2,0,4" Text="Every INF stays in the package, and the ones you did not edit keep their NVIDIA / Microsoft signature. MakeCat and the other folder engines point only the edited INF files at the folder's new catalog (off: every INF of the folder). Inf2Cat gets a copy of the folder with only the edited INF files (the driver files are hard links - no extra space), several at the same time; an edited INF whose catalog is shared with the others (nv_dispi.cat) gets a catalog file of its own. If Inf2Cat fails on that copy, the whole folder is catalogued as before."/>
              <CheckBox x:Name="cfg_SignOnlyThisPc" Style="{StaticResource Toggle}" Content="Faster: only keep the INF files for this PC's hardware (when the ISO is for this PC)"/>
              <TextBlock Style="{StaticResource Sub}" Margin="48,-2,0,4" Text="Mostly for Inf2Cat: NVIDIA's Display.Driver has one INF file per laptop and desktop maker, and Inf2Cat checks every one of them against the whole package - that can take up to an hour. With this on, only the INF files that list a device of this PC are signed (minutes instead), the others are removed from the copy. The original folder is not touched."/>
              <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                <TextBlock Text="Catalog runs at the same time" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBox x:Name="SignJobsBox" Width="50"/>
                <TextBlock Style="{StaticResource Sub}" VerticalAlignment="Center" Margin="12,0,0,0" Text="1-8, empty = processor cores up to 8. Each Inf2Cat run uses one core; MakeCat does up to 4 folders at once."/>
              </StackPanel>
              <WrapPanel Margin="0,14,0,0">
                <Button x:Name="SignBtn" Style="{StaticResource Primary}" Content="Sign and add to the ISO"/>
                <Button x:Name="SignOpen" Style="{StaticResource Btn}" Content="Open signing folder"/>
              </WrapPanel>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Signing certificate"/>
              <TextBlock x:Name="CertInfo" TextWrapping="Wrap" FontWeight="SemiBold"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,6,0,0" Text="DriverSigning.pfx (private key) stays in the signing folder next to this tool - back it up and never share or upload it. Only the public DriverSigning.cer goes into the ISO. Tools (makecat, Inf2Cat, signtool) are downloaded automatically."/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Packages added to the ISO"/>
              <DataGrid x:Name="SignGrid" Height="150"/>
              <WrapPanel Margin="0,12,0,0"><Button x:Name="SignRemove" Style="{StaticResource Btn}" Content="Remove selected"/></WrapPanel>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 6 answer file + oem -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Answer file and $OEM$"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Both are optional and copied into the media when the ISO is built."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="autounattend.xml"/>
              <TextBlock x:Name="UnaCur" FontWeight="SemiBold" TextWrapping="Wrap" Text="none"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,12" Text="Placed in the ISO root so Setup runs unattended. Create one with the autounattend generator."/>
              <WrapPanel>
                <Button x:Name="UnaPick" Style="{StaticResource Primary}" Content="Choose autounattend.xml"/>
                <Button x:Name="UnaGen" Style="{StaticResource Btn}" Content="Open the generator"/>
                <Button x:Name="UnaRemove" Style="{StaticResource Btn}" Content="Remove"/>
              </WrapPanel>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="$OEM$ folder"/>
              <TextBlock x:Name="OemCur" FontWeight="SemiBold" TextWrapping="Wrap" Text="none"/>
              <TextBlock x:Name="OemInfo" Style="{StaticResource Sub}" Margin="0,2,0,0"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,6,0,12" Text="Copied to sources\$OEM$: $OEM$\$1 lands in C:\ and $OEM$\$$ in C:\Windows (e.g. $$\Setup\Scripts\SetupComplete.cmd). Packages from the signed-drivers page are merged in, and your SetupComplete.cmd gets a call to SetupComplete-drivers.cmd as its first command."/>
              <WrapPanel>
                <Button x:Name="OemPick" Style="{StaticResource Primary}" Content="Choose $OEM$ folder"/>
                <Button x:Name="OemOpen" Style="{StaticResource Btn}" Content="Open"/>
                <Button x:Name="OemRemove" Style="{StaticResource Btn}" Content="Remove"/>
              </WrapPanel>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 7 build -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Slipstream and build"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Slipstream applies updates, drivers and options to WinRE, install.wim and boot.wim (30-90 minutes). Build writes the bootable BIOS + UEFI ISO with your answer file, $OEM$ and signed drivers."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Boot options"/>
              <CheckBox x:Name="cfg_NoPrompt" Style="{StaticResource Toggle}" Content="UEFI boot without 'Press any key to boot from CD or DVD'"/>
              <CheckBox x:Name="cfg_Boot2023" Style="{StaticResource Toggle}" Content="Boot manager signed by Windows UEFI CA 2023 (needs firmware that trusts it)"/>
              <CheckBox x:Name="cfg_SplitFat32" Style="{StaticResource Toggle}" Content="Split install.wim into 3.8 GB parts (FAT32 USB sticks)"/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Speed"/>
              <CheckBox x:Name="cfg_ParallelBoot" Style="{StaticResource Toggle}" Content="Update boot.wim and WinRE at the same time as install.wim (faster, uses more CPU and disk)"/>
              <StackPanel Orientation="Horizontal" Margin="0,6,0,6">
                <TextBlock Text="Editions at the same time" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBox x:Name="EdJobsBox" Width="50" AutomationProperties.Name="Editions updated at the same time"/>
                <TextBlock Style="{StaticResource Sub}" VerticalAlignment="Center" Margin="12,0,0,0" TextWrapping="Wrap" MaxWidth="560" Text="1-4, empty = automatic (2 on 4+ processor cores, 3 on 8+). Each one needs about 25 GB free on the work drive; fewer run at once when there is less. 1 = one after the other."/>
              </StackPanel>
              <CheckBox x:Name="cfg_DefenderExclude" Style="{StaticResource Toggle}" Content="Let Windows Defender skip the work folder while a job runs (removed again afterwards)"/>
              <CheckBox x:Name="cfg_BootSkipPE" Style="{StaticResource Toggle}" Content="Leave boot.wim index 1 (Windows PE for WDS servers) as it is - USB / DVD setup uses index 2"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="DISM applies each update with one process, so servicing one image cannot use more cores - updating boot.wim, WinRE and several editions side by side can. Defender scanning every file DISM writes is often the biggest slowdown. Storage / network drivers go into WinRE and boot.wim with one DISM call. The log ends with the time of every step."/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Output ISO"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="OutBox" Margin="0,0,8,0"/>
                <Button x:Name="OutBrowse" Grid.Column="1" Style="{StaticResource Btn}" Content="Save as..." Margin="0"/>
              </Grid>
              <TextBlock Style="{StaticResource Sub}" Margin="0,6,0,14" Text="Empty = work folder\output\Win10_ or Win11_version_build_arch_date.iso"/>
              <WrapPanel>
                <Button x:Name="SvcBtn" Style="{StaticResource Primary}" Content="1 - Slipstream into the image"/>
                <Button x:Name="BuildBtn" Style="{StaticResource Primary}" Content="2 - Build the ISO"/>
                <Button x:Name="OpenOut" Style="{StaticResource Btn}" Content="Open output folder"/>
              </WrapPanel>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Result"/>
              <TextBlock x:Name="IsoInfo" FontWeight="SemiBold" TextWrapping="Wrap" Text="No ISO built yet."/>
              <TextBox x:Name="IsoHash" IsReadOnly="True" Margin="0,8,0,0" BorderThickness="0" Background="Transparent" Foreground="#8A94A8" FontFamily="Consolas"/>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 8 options -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Options and clean up"/>
            <Border Style="{StaticResource Card}" Margin="0,14,0,14"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Work folder"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="WorkBox" Margin="0,0,8,0"/>
                <Button x:Name="WorkBrowse" Grid.Column="1" Style="{StaticResource Btn}" Content="Browse..."/>
                <Button x:Name="WorkApply" Grid.Column="2" Style="{StaticResource Primary}" Content="Apply" Margin="0"/>
              </Grid>
              <TextBlock Style="{StaticResource Sub}" Margin="0,6,0,0" Text="Short NTFS path without spaces with about 30 GB free (e.g. D:\W10U). A new folder starts empty."/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Clean up"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,8" Text="Leftover mounted images and temporary files are always removed. Also delete:"/>
              <CheckBox x:Name="ClnUpd" Style="{StaticResource Toggle}" Content="Downloaded updates"/>
              <CheckBox x:Name="ClnMedia" Style="{StaticResource Toggle}" Content="Unpacked media"/>
              <CheckBox x:Name="ClnOut" Style="{StaticResource Toggle}" Content="Built ISOs"/>
              <CheckBox x:Name="ClnSigned" Style="{StaticResource Toggle}" Content="Re-signed driver copies"/>
              <CheckBox x:Name="ClnDrivers" Style="{StaticResource Toggle}" Content="Copied drivers (this PC / imported folder)"/>
              <CheckBox x:Name="ClnExtra" Style="{StaticResource Toggle}" Content="Answer file copy and install check results (the answer file must be chosen again)"/>
              <CheckBox x:Name="ClnLogs" Style="{StaticResource Toggle}" Content="Logs"/>
              <CheckBox x:Name="ClnAll" Style="{StaticResource Toggle}" Margin="0,10,0,5" Content="Everything - empty the work folder and start from scratch"/>
              <WrapPanel Margin="0,12,0,0"><Button x:Name="ClnBtn" Style="{StaticResource Btn}" Content="Clean up now"/></WrapPanel>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Defaults"/>
              <WrapPanel><Button x:Name="DefBtn" Style="{StaticResource Btn}" Content="Restore default options"/><Button x:Name="WorkOpen" Style="{StaticResource Btn}" Content="Open work folder"/></WrapPanel>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 9 tools -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Tools"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Everything missing is downloaded automatically when a step needs it, into the tools folder next to this file. oscdimg.exe comes from the Microsoft symbol server (SHA-256 checked) or the Windows ADK; makecat, Inf2Cat and signtool are extracted from Microsoft's NuGet packages (Windows SDK build tools / Windows Driver Kit) - only those tools are kept, nothing is installed."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Text="DISM" Margin="0,4"/><TextBlock x:Name="T_Dism" Grid.Row="0" Grid.Column="1" Margin="0,4" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="1" Text="oscdimg.exe" Margin="0,4"/><TextBlock x:Name="T_Osc" Grid.Row="1" Grid.Column="1" Margin="0,4" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="2" Text="Inf2Cat.exe" Margin="0,4"/><TextBlock x:Name="T_Inf" Grid.Row="2" Grid.Column="1" Margin="0,4" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="3" Text="signtool.exe" Margin="0,4"/><TextBlock x:Name="T_Sign" Grid.Row="3" Grid.Column="1" Margin="0,4" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="4" Text="makecat.exe" Margin="0,4"/><TextBlock x:Name="T_Mkc" Grid.Row="4" Grid.Column="1" Margin="0,4" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="5" Text="curl.exe" Margin="0,4"/><TextBlock x:Name="T_Curl" Grid.Row="5" Grid.Column="1" Margin="0,4"/>
              </Grid>
              <WrapPanel Margin="0,14,0,0"><Button x:Name="ToolsBtn" Style="{StaticResource Primary}" Content="Download missing tools now"/><Button x:Name="ToolsOpen" Style="{StaticResource Btn}" Content="Open tools folder"/></WrapPanel>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 10 install check -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Install check"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Checks your autounattend.xml, $OEM$ folder and drivers against the ISO you are building and points out what would break or stall a clean install: wrong edition index or language, invalid computer / account names or time zone, duplicate command numbers, scripts that wait for a key, missing files, drivers that nothing installs or that Windows will refuse, and SetupComplete.cmd being skipped on PCs with an OEM key. Fixes change only the copies that go into the ISO - your own files stay as they are. The check also runs before every ISO build."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <WrapPanel Margin="0,0,0,12">
                <Button x:Name="ChkBtn" Style="{StaticResource Primary}" Content="Run the check"/>
                <Button x:Name="ChkFix" Style="{StaticResource Btn}" Content="Apply all fixes"/>
                <Button x:Name="ChkSave" Style="{StaticResource Btn}" Content="Save fixed answer file as..."/>
                <Button x:Name="ChkUndo" Style="{StaticResource Btn}" Content="Undo answer file fixes"/>
              </WrapPanel>
              <TextBlock x:Name="ChkSum" FontSize="14" FontWeight="SemiBold" TextWrapping="Wrap" Text="Not run yet."/>
              <TextBlock x:Name="ChkNote" Style="{StaticResource Sub}" Margin="0,2,0,10"/>
              <DataGrid x:Name="ChkGrid" Height="400" AutoGenerateColumns="False">
                <DataGrid.RowStyle>
                  <Style TargetType="DataGridRow">
                    <Style.Triggers>
                      <DataTrigger Binding="{Binding Level}" Value="Error"><Setter Property="Foreground" Value="#FF5C7A"/></DataTrigger>
                      <DataTrigger Binding="{Binding Level}" Value="Warning"><Setter Property="Foreground" Value="#FFC857"/></DataTrigger>
                      <DataTrigger Binding="{Binding Level}" Value="Info"><Setter Property="Foreground" Value="#AEB7C8"/></DataTrigger>
                      <DataTrigger Binding="{Binding Level}" Value="OK"><Setter Property="Foreground" Value="#3DDC97"/></DataTrigger>
                    </Style.Triggers>
                  </Style>
                </DataGrid.RowStyle>
                <DataGrid.Columns>
                  <DataGridTextColumn Header="Level" Binding="{Binding Level}" Width="74"/>
                  <DataGridTextColumn Header="Area" Binding="{Binding Area}" Width="120"/>
                  <DataGridTextColumn Header="Finding" Binding="{Binding Finding}" Width="3*">
                    <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style></DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="Fix" Binding="{Binding FixText}" Width="1.6*">
                    <DataGridTextColumn.ElementStyle><Style TargetType="TextBlock"><Setter Property="TextWrapping" Value="Wrap"/></Style></DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                </DataGrid.Columns>
              </DataGrid>
              <CheckBox x:Name="cfg_InstallOemDrivers" Style="{StaticResource Toggle}" Margin="0,14,0,0" Content="Also install the driver folders in my $OEM$\$1 with pnputil (from SetupComplete-drivers.cmd)"/>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>
'@

$Script:XPicker = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Choose drivers" Width="1060" Height="660" WindowStartupLocation="CenterOwner"
        Background="#0B0E14" Foreground="#E6EAF2" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
__RES__
  </Window.Resources>
  <Grid Margin="20">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel>
      <TextBlock x:Name="PTitle" Style="{StaticResource H2}" TextWrapping="Wrap" Margin="0,0,0,2"/>
      <TextBlock x:Name="PSub" Style="{StaticResource Sub}" Margin="0,0,0,12"/>
    </StackPanel>
    <Grid Grid.Row="1" Margin="0,0,0,10">
      <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Text="Filter" VerticalAlignment="Center" Margin="0,0,10,0"/>
      <TextBox x:Name="PFilter" Grid.Column="1" ToolTip="Class, provider, INF or folder name"/>
      <StackPanel Grid.Column="2" Orientation="Horizontal" Margin="10,0,0,0">
        <Button x:Name="PFit" Style="{StaticResource Btn}" Content="All that fit"/>
        <Button x:Name="PShown" Style="{StaticResource Btn}" Content="Tick shown"/>
        <Button x:Name="PNone" Style="{StaticResource Btn}" Content="None" Margin="0"/>
      </StackPanel>
    </Grid>
    <DataGrid x:Name="PGrid" Grid.Row="2" IsReadOnly="False">
      <DataGrid.Columns>
        <DataGridTemplateColumn Header="Use" Width="54">
          <DataGridTemplateColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Use, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" Cursor="Hand"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
        </DataGridTemplateColumn>
      </DataGrid.Columns>
    </DataGrid>
    <Grid Grid.Row="3" Margin="0,14,0,0">
      <TextBlock x:Name="PCount" Style="{StaticResource Sub}" VerticalAlignment="Center"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="POk" Style="{StaticResource Primary}" Content="Add ticked drivers"/>
        <Button x:Name="PCancel" Style="{StaticResource Btn}" Content="Cancel" Margin="0" IsCancel="True"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

$Script:XPass = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Driver signing certificate" Width="480" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        Background="#0B0E14" Foreground="#E6EAF2" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
__RES__
  </Window.Resources>
  <StackPanel Margin="22">
    <TextBlock Style="{StaticResource H2}" Text="Driver signing certificate"/>
    <TextBlock x:Name="PwText" TextWrapping="Wrap" Foreground="#AEB7C8" Margin="0,0,0,14"/>
    <TextBlock Text="Password" Style="{StaticResource Sub}"/>
    <PasswordBox x:Name="Pw1" Margin="0,4,0,10"/>
    <StackPanel x:Name="Pw2Panel">
      <TextBlock Text="Repeat the password" Style="{StaticResource Sub}"/>
      <PasswordBox x:Name="Pw2" Margin="0,4,0,10"/>
    </StackPanel>
    <TextBlock x:Name="PwErr" Foreground="#FF5C7A" Margin="0,0,0,8"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="PwOk" Style="{StaticResource Primary}" Content="OK" IsDefault="True"/>
      <Button x:Name="PwCancel" Style="{StaticResource Btn}" Content="Cancel" IsCancel="True" Margin="0"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
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
    $list = [System.Collections.Generic.List[object]]::new()     # not New-Object: @() over that list fails ("Argument types do not match")
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
    foreach ($x in $Texts) {
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
function Get-LangData([string]$Code) {
    switch ($Code) {
        'pt' { return @'
updates + drivers + signed NVIDIA mods + autounattend + $OEM$  ->  bootable ISO	atualiza&#xE7;&#xF5;es + controladores + mods NVIDIA assinados + autounattend + $OEM$  ->  ISO de arranque
Light theme	Tema claro
Switch to the light theme	Mudar para o tema claro
Display and accessibility: theme, text size, font	Visualiza&#xE7;&#xE3;o e acessibilidade: tema, tamanho do texto, tipo de letra
Display and accessibility settings	Defini&#xE7;&#xF5;es de visualiza&#xE7;&#xE3;o e acessibilidade
Minimize	Minimizar
Maximize	Maximizar
Close	Fechar
Display and accessibility	Visualiza&#xE7;&#xE3;o e acessibilidade
Theme	Tema
Dark	Escuro
Light	Claro
Like Windows	Como o Windows
Text size	Tamanho do texto
Font	Tipo de letra
Language	Idioma
Ctrl + plus / Ctrl + minus / Ctrl + 0 change the text size anywhere in the window. Verdana and Tahoma have wider, more distinct letters. Saved for the next start.	Ctrl + mais / Ctrl + menos / Ctrl + 0 alteram o tamanho do texto em qualquer parte da janela. Verdana e Tahoma t&#xEA;m letras mais largas e mais distintas. Fica guardado para o pr&#xF3;ximo arranque.
The Activity log and the Install check findings stay in English - that is what a bug report or a search needs.	O registo de Atividade e os resultados da Verifica&#xE7;&#xE3;o da instala&#xE7;&#xE3;o ficam em ingl&#xEA;s - &#xE9; o que um relat&#xF3;rio de erro ou uma pesquisa precisam.
STEPS	PASSOS
Source ISO	ISO de origem
to do	por fazer
Editions	Edi&#xE7;&#xF5;es
Windows updates	Atualiza&#xE7;&#xF5;es do Windows
Drivers	Controladores
optional	opcional
Signed NVIDIA / modded	NVIDIA assinados / modificados
Answer file + $OEM$	Ficheiro de respostas + $OEM$
Install check	Verifica&#xE7;&#xE3;o da instala&#xE7;&#xE3;o
not run yet	ainda n&#xE3;o executada
Slipstream + build ISO	Integrar + criar ISO
MORE	MAIS
Options and clean up	Op&#xE7;&#xF5;es e limpeza
Tools	Ferramentas
Run everything	Executar tudo
unpack - updates - slipstream - ISO, using what you set on each page	extrair - atualiza&#xE7;&#xF5;es - integrar - ISO, com o que definiu em cada p&#xE1;gina
SOURCE	ORIGEM
IMAGE	IMAGEM
WORK FOLDER	PASTA DE TRABALHO
ACTIVITY	ATIVIDADE
Ready	Pronto
Logs folder	Pasta de registos
Clear	Limpar
Choose Windows 10 or Windows 11 and pick its ISO. It is copied into the work folder and its build and editions are detected - the version follows the ISO you unpack.	Escolha o Windows 10 ou o Windows 11 e selecione a respetiva ISO. &#xC9; copiada para a pasta de trabalho e a compila&#xE7;&#xE3;o e as edi&#xE7;&#xF5;es s&#xE3;o detetadas - a vers&#xE3;o segue a ISO que extrair.
Windows version	Vers&#xE3;o do Windows
ISO file	Ficheiro ISO
Use an original ISO from Microsoft. Before it is unpacked, its SHA-256 is compared with the ones Microsoft publishes for its Windows 10 and 11 ISOs - the list in this program and, when online, the download pages on microsoft.com. When it is not there (an ISO made with the Media Creation Tool never is), the Microsoft signatures of its setup and boot files are checked.	Use uma ISO original da Microsoft. Antes de ser extra&#xED;da, o seu SHA-256 &#xE9; comparado com os que a Microsoft publica para as ISOs do Windows 10 e 11 - a lista deste programa e, com liga&#xE7;&#xE3;o &#xE0; Internet, as p&#xE1;ginas de transfer&#xEA;ncia em microsoft.com. Quando n&#xE3;o est&#xE1; l&#xE1; (uma ISO criada com a Ferramenta de Cria&#xE7;&#xE3;o de Multim&#xE9;dia nunca est&#xE1;), s&#xE3;o verificadas as assinaturas da Microsoft dos ficheiros de instala&#xE7;&#xE3;o e de arranque.
Browse...	Procurar...
Unpack and analyze	Extrair e analisar
Check the ISO	Verificar a ISO
Re-read image info	Voltar a ler a imagem
Download Windows 10 from Microsoft	Transferir o Windows 10 da Microsoft
SHA-256 of the ISO - select it to copy	SHA-256 da ISO - selecione-o para copiar
Detected image	Imagem detetada
Nothing unpacked yet.	Ainda nada foi extra&#xED;do.
Tick the editions to update. With the option below on, unticked editions are left out of the new ISO (smaller and faster).	Marque as edi&#xE7;&#xF5;es a atualizar. Com a op&#xE7;&#xE3;o abaixo ativa, as edi&#xE7;&#xF5;es n&#xE3;o marcadas ficam de fora da nova ISO (mais pequena e mais r&#xE1;pida).
Tick all	Marcar todas
Tick none	Desmarcar todas
Use	Usar
Keep only the ticked editions in the new ISO	Manter apenas as edi&#xE7;&#xF5;es marcadas na nova ISO
Finds the newest cumulative update, servicing stack, Safe OS and Setup Dynamic Updates and .NET updates for this build in the Microsoft Update Catalog and downloads them (SHA-1 checked).	Procura no Cat&#xE1;logo do Microsoft Update a atualiza&#xE7;&#xE3;o cumulativa mais recente, a pilha de manuten&#xE7;&#xE3;o, as Atualiza&#xE7;&#xF5;es Din&#xE2;micas Safe OS e de Configura&#xE7;&#xE3;o e as atualiza&#xE7;&#xF5;es do .NET para esta compila&#xE7;&#xE3;o e transfere-as (verificadas com SHA-1).
What to integrate	O que integrar
Add .NET Framework 4.8.1 (Windows 10 2004-22H2 - Windows 11 has it built in)	Adicionar o .NET Framework 4.8.1 (Windows 10 2004-22H2 - o Windows 11 j&#xE1; o inclui)
Enable .NET Framework 3.5 (from the ISO's sources\sxs)	Ativar o .NET Framework 3.5 (a partir de sources\sxs da ISO)
Component cleanup /ResetBase (smaller image - updates can't be uninstalled)	Limpeza de componentes /ResetBase (imagem mais pequena - as atualiza&#xE7;&#xF5;es deixam de poder ser desinstaladas)
Newest month to integrate	M&#xEA;s mais recente a integrar
YYYY-MM, for Windows 10 2004-22H2 / LTSC 2021	AAAA-MM, para o Windows 10 2004-22H2 / LTSC 2021
2025-10 is the last Windows 10 update Microsoft allows offline. ESU updates (Nov 2025+) come from Windows Update after setup on enrolled PCs.	2025-10 &#xE9; a &#xFA;ltima atualiza&#xE7;&#xE3;o do Windows 10 que a Microsoft permite integrar offline. As atualiza&#xE7;&#xF5;es ESU (nov. 2025+) chegam pelo Windows Update depois da instala&#xE7;&#xE3;o, nos PCs inscritos.
Find and download updates	Procurar e transferir atualiza&#xE7;&#xF5;es
Downloaded	Transferidas
Signed drivers are slipstreamed into install.wim with DISM, so Windows installs them on first boot. Storage and network drivers also go into boot.wim and WinRE, so Setup sees RAID / VMD disks. Modded drivers (edited INF) belong on the next page.	Os controladores assinados s&#xE3;o integrados no install.wim com o DISM, para o Windows os instalar no primeiro arranque. Os controladores de armazenamento e de rede v&#xE3;o tamb&#xE9;m para o boot.wim e o WinRE, para a Configura&#xE7;&#xE3;o ver discos RAID / VMD. Os controladores modificados (INF editado) ficam na p&#xE1;gina seguinte.
Add drivers from this PC	Adicionar controladores deste PC
Import a drivers folder	Importar uma pasta de controladores
Remove selected	Remover selecionados
Clear all	Remover todos
Also put storage and network drivers into boot.wim and WinRE	Colocar tamb&#xE9;m os controladores de armazenamento e de rede no boot.wim e no WinRE
Allow unsigned drivers in DISM (/ForceUnsigned)	Permitir controladores n&#xE3;o assinados no DISM (/ForceUnsigned)
Signed NVIDIA / modded drivers	Controladores NVIDIA assinados / modificados
For driver packages whose INF was edited - NVCleanstall hardware-ID mods for an unsupported GPU, custom INF files. The edit breaks the catalog signature, so Windows refuses them. Every subfolder is scanned; each modified package gets a new catalog (MakeCat by default, or the engine you pick below) signed with your own certificate. The package is added to the ISO through $OEM$ and installed by SetupComplete.cmd at the end of Windows setup, right after the certificate is trusted.	Para pacotes de controladores cujo INF foi editado - mods de ID de hardware do NVCleanstall para uma GPU n&#xE3;o suportada, ficheiros INF personalizados. A edi&#xE7;&#xE3;o quebra a assinatura do cat&#xE1;logo e o Windows recusa-os. Todas as subpastas s&#xE3;o analisadas; cada pacote modificado recebe um novo cat&#xE1;logo (MakeCat por predefini&#xE7;&#xE3;o, ou o motor que escolher abaixo) assinado com o seu pr&#xF3;prio certificado. O pacote &#xE9; adicionado &#xE0; ISO atrav&#xE9;s de $OEM$ e instalado pelo SetupComplete.cmd no fim da instala&#xE7;&#xE3;o do Windows, logo depois de o certificado ser considerado fidedigno.
Driver package	Pacote de controladores
Folder	Pasta
Name	Nome
installs from C:\Drivers\NVIDIA during setup	instala a partir de C:\Drivers\NVIDIA durante a instala&#xE7;&#xE3;o
Engine	Motor
Signing engine: MakeCat	Motor de assinatura: MakeCat
Signing engine: libwdi-style	Motor de assinatura: libwdi-style
Signing engine: generate-cat-file in WSL	Motor de assinatura: generate-cat-file no WSL
Signing engine: Inf2Cat	Motor de assinatura: Inf2Cat
Re-sign every package, not only the modified ones	Voltar a assinar todos os pacotes, n&#xE3;o s&#xF3; os modificados
Delete the driver copy from C:\Drivers once it is installed	Apagar a c&#xF3;pia dos controladores de C:\Drivers depois de instalada
Faster: new catalogs only for the INF files that need one	Mais r&#xE1;pido: novos cat&#xE1;logos s&#xF3; para os ficheiros INF que precisam de um
Every INF stays in the package, and the ones you did not edit keep their NVIDIA / Microsoft signature. MakeCat and the other folder engines point only the edited INF files at the folder's new catalog (off: every INF of the folder). Inf2Cat gets a copy of the folder with only the edited INF files (the driver files are hard links - no extra space), several at the same time; an edited INF whose catalog is shared with the others (nv_dispi.cat) gets a catalog file of its own. If Inf2Cat fails on that copy, the whole folder is catalogued as before.	Todos os INF ficam no pacote, e os que n&#xE3;o editou mant&#xEA;m a assinatura da NVIDIA / Microsoft. O MakeCat e os outros motores por pasta apontam apenas os INF editados para o novo cat&#xE1;logo da pasta (desativado: todos os INF da pasta). O Inf2Cat recebe uma c&#xF3;pia da pasta s&#xF3; com os INF editados (os ficheiros dos controladores s&#xE3;o liga&#xE7;&#xF5;es f&#xED;sicas - sem espa&#xE7;o extra), v&#xE1;rias ao mesmo tempo; um INF editado cujo cat&#xE1;logo &#xE9; partilhado com os outros (nv_dispi.cat) recebe um ficheiro de cat&#xE1;logo pr&#xF3;prio. Se o Inf2Cat falhar nessa c&#xF3;pia, a pasta inteira &#xE9; catalogada como antes.
Faster: only keep the INF files for this PC's hardware (when the ISO is for this PC)	Mais r&#xE1;pido: manter s&#xF3; os ficheiros INF do hardware deste PC (quando a ISO &#xE9; para este PC)
Mostly for Inf2Cat: NVIDIA's Display.Driver has one INF file per laptop and desktop maker, and Inf2Cat checks every one of them against the whole package - that can take up to an hour. With this on, only the INF files that list a device of this PC are signed (minutes instead), the others are removed from the copy. The original folder is not touched.	Sobretudo para o Inf2Cat: o Display.Driver da NVIDIA tem um ficheiro INF por fabricante de port&#xE1;teis e de computadores de secret&#xE1;ria, e o Inf2Cat verifica cada um contra o pacote inteiro - pode demorar at&#xE9; uma hora. Com isto ativo, s&#xF3; s&#xE3;o assinados os INF que indicam um dispositivo deste PC (minutos em vez disso); os outros s&#xE3;o removidos da c&#xF3;pia. A pasta original n&#xE3;o &#xE9; alterada.
Catalog runs at the same time	Cataloga&#xE7;&#xF5;es em simult&#xE2;neo
1-8, empty = processor cores up to 8. Each Inf2Cat run uses one core; MakeCat does up to 4 folders at once.	1-8, vazio = n&#xFA;cleos do processador at&#xE9; 8. Cada execu&#xE7;&#xE3;o do Inf2Cat usa um n&#xFA;cleo; o MakeCat trata at&#xE9; 4 pastas de uma vez.
Sign and add to the ISO	Assinar e adicionar &#xE0; ISO
Open signing folder	Abrir a pasta de assinatura
Signing certificate	Certificado de assinatura
DriverSigning.pfx (private key) stays in the signing folder next to this tool - back it up and never share or upload it. Only the public DriverSigning.cer goes into the ISO. Tools (makecat, Inf2Cat, signtool) are downloaded automatically.	O DriverSigning.pfx (chave privada) fica na pasta de assinatura ao lado desta ferramenta - fa&#xE7;a uma c&#xF3;pia de seguran&#xE7;a e nunca o partilhe nem o carregue em lado nenhum. S&#xF3; o DriverSigning.cer p&#xFA;blico vai para a ISO. As ferramentas (makecat, Inf2Cat, signtool) s&#xE3;o transferidas automaticamente.
Packages added to the ISO	Pacotes adicionados &#xE0; ISO
Answer file and $OEM$	Ficheiro de respostas e $OEM$
Both are optional and copied into the media when the ISO is built.	Ambos s&#xE3;o opcionais e s&#xE3;o copiados para o suporte quando a ISO &#xE9; criada.
none	nenhum
Placed in the ISO root so Setup runs unattended. Create one with the autounattend generator.	Colocado na raiz da ISO para a Configura&#xE7;&#xE3;o correr sem interven&#xE7;&#xE3;o. Crie um com o gerador de autounattend.
Choose autounattend.xml	Escolher autounattend.xml
Open the generator	Abrir o gerador
Remove	Remover
$OEM$ folder	Pasta $OEM$
Copied to sources\$OEM$: $OEM$\$1 lands in C:\ and $OEM$\$$ in C:\Windows (e.g. $$\Setup\Scripts\SetupComplete.cmd). Packages from the signed-drivers page are merged in, and your SetupComplete.cmd gets a call to SetupComplete-drivers.cmd as its first command.	Copiada para sources\$OEM$: $OEM$\$1 vai para C:\ e $OEM$\$$ para C:\Windows (p. ex. $$\Setup\Scripts\SetupComplete.cmd). Os pacotes da p&#xE1;gina de controladores assinados s&#xE3;o juntados, e o seu SetupComplete.cmd recebe uma chamada a SetupComplete-drivers.cmd como primeiro comando.
Choose $OEM$ folder	Escolher a pasta $OEM$
Open	Abrir
Slipstream and build	Integrar e criar
Slipstream applies updates, drivers and options to WinRE, install.wim and boot.wim (30-90 minutes). Build writes the bootable BIOS + UEFI ISO with your answer file, $OEM$ and signed drivers.	A integra&#xE7;&#xE3;o aplica atualiza&#xE7;&#xF5;es, controladores e op&#xE7;&#xF5;es ao WinRE, install.wim e boot.wim (30-90 minutos). A cria&#xE7;&#xE3;o escreve a ISO de arranque BIOS + UEFI com o seu ficheiro de respostas, $OEM$ e controladores assinados.
Boot options	Op&#xE7;&#xF5;es de arranque
UEFI boot without 'Press any key to boot from CD or DVD'	Arranque UEFI sem 'Prima qualquer tecla para arrancar a partir do CD ou DVD'
Boot manager signed by Windows UEFI CA 2023 (needs firmware that trusts it)	Gestor de arranque assinado pela Windows UEFI CA 2023 (precisa de firmware que confie nela)
Split install.wim into 3.8 GB parts (FAT32 USB sticks)	Dividir o install.wim em partes de 3,8 GB (pens USB FAT32)
Speed	Velocidade
Update boot.wim and WinRE at the same time as install.wim (faster, uses more CPU and disk)	Atualizar o boot.wim e o WinRE ao mesmo tempo que o install.wim (mais r&#xE1;pido, usa mais CPU e disco)
Editions at the same time	Edi&#xE7;&#xF5;es em simult&#xE2;neo
Editions updated at the same time	Edi&#xE7;&#xF5;es atualizadas em simult&#xE2;neo
1-4, empty = automatic (2 on 4+ processor cores, 3 on 8+). Each one needs about 25 GB free on the work drive; fewer run at once when there is less. 1 = one after the other.	1-4, vazio = autom&#xE1;tico (2 com 4+ n&#xFA;cleos, 3 com 8+). Cada uma precisa de cerca de 25 GB livres na unidade de trabalho; com menos espa&#xE7;o correm menos de cada vez. 1 = uma depois da outra.
Let Windows Defender skip the work folder while a job runs (removed again afterwards)	Deixar o Windows Defender ignorar a pasta de trabalho durante uma tarefa (removido depois)
Leave boot.wim index 1 (Windows PE for WDS servers) as it is - USB / DVD setup uses index 2	Deixar o &#xED;ndice 1 do boot.wim (Windows PE para servidores WDS) como est&#xE1; - a instala&#xE7;&#xE3;o por USB / DVD usa o &#xED;ndice 2
DISM applies each update with one process, so servicing one image cannot use more cores - updating boot.wim, WinRE and several editions side by side can. Defender scanning every file DISM writes is often the biggest slowdown. Storage / network drivers go into WinRE and boot.wim with one DISM call. The log ends with the time of every step.	O DISM aplica cada atualiza&#xE7;&#xE3;o com um s&#xF3; processo, por isso a manuten&#xE7;&#xE3;o de uma imagem n&#xE3;o aproveita mais n&#xFA;cleos - atualizar o boot.wim, o WinRE e v&#xE1;rias edi&#xE7;&#xF5;es lado a lado sim. A an&#xE1;lise do Defender a cada ficheiro que o DISM escreve &#xE9; muitas vezes o maior atraso. Os controladores de armazenamento / rede v&#xE3;o para o WinRE e o boot.wim numa s&#xF3; chamada ao DISM. O registo termina com o tempo de cada passo.
Output ISO	ISO de sa&#xED;da
Save as...	Guardar como...
Empty = work folder\output\Win10_ or Win11_version_build_arch_date.iso	Vazio = pasta de trabalho\output\Win10_ ou Win11_vers&#xE3;o_compila&#xE7;&#xE3;o_arquitetura_data.iso
1 - Slipstream into the image	1 - Integrar na imagem
2 - Build the ISO	2 - Criar a ISO
Open output folder	Abrir a pasta de sa&#xED;da
Result	Resultado
No ISO built yet.	Ainda nenhuma ISO criada.
Work folder	Pasta de trabalho
Apply	Aplicar
Short NTFS path without spaces with about 30 GB free (e.g. D:\W10U). A new folder starts empty.	Caminho NTFS curto, sem espa&#xE7;os, com cerca de 30 GB livres (p. ex. D:\W10U). Uma pasta nova come&#xE7;a vazia.
Clean up	Limpeza
Leftover mounted images and temporary files are always removed. Also delete:	As imagens montadas que sobraram e os ficheiros tempor&#xE1;rios s&#xE3;o sempre removidos. Apagar tamb&#xE9;m:
Downloaded updates	Atualiza&#xE7;&#xF5;es transferidas
Unpacked media	Suporte extra&#xED;do
Built ISOs	ISOs criadas
Re-signed driver copies	C&#xF3;pias de controladores assinados de novo
Copied drivers (this PC / imported folder)	Controladores copiados (deste PC / pasta importada)
Answer file copy and install check results (the answer file must be chosen again)	C&#xF3;pia do ficheiro de respostas e resultados da verifica&#xE7;&#xE3;o (o ficheiro de respostas tem de ser escolhido de novo)
Logs	Registos
Everything - empty the work folder and start from scratch	Tudo - esvaziar a pasta de trabalho e come&#xE7;ar do zero
Clean up now	Limpar agora
Defaults	Predefini&#xE7;&#xF5;es
Restore default options	Repor as op&#xE7;&#xF5;es predefinidas
Open work folder	Abrir a pasta de trabalho
Everything missing is downloaded automatically when a step needs it, into the tools folder next to this file. oscdimg.exe comes from the Microsoft symbol server (SHA-256 checked) or the Windows ADK; makecat, Inf2Cat and signtool are extracted from Microsoft's NuGet packages (Windows SDK build tools / Windows Driver Kit) - only those tools are kept, nothing is installed.	Tudo o que faltar &#xE9; transferido automaticamente quando um passo precisa, para a pasta tools ao lado deste ficheiro. O oscdimg.exe vem do servidor de s&#xED;mbolos da Microsoft (verificado com SHA-256) ou do Windows ADK; makecat, Inf2Cat e signtool s&#xE3;o extra&#xED;dos dos pacotes NuGet da Microsoft (Windows SDK build tools / Windows Driver Kit) - s&#xF3; essas ferramentas s&#xE3;o guardadas, nada &#xE9; instalado.
Download missing tools now	Transferir agora as ferramentas em falta
Open tools folder	Abrir a pasta de ferramentas
Checks your autounattend.xml, $OEM$ folder and drivers against the ISO you are building and points out what would break or stall a clean install: wrong edition index or language, invalid computer / account names or time zone, duplicate command numbers, scripts that wait for a key, missing files, drivers that nothing installs or that Windows will refuse, and SetupComplete.cmd being skipped on PCs with an OEM key. Fixes change only the copies that go into the ISO - your own files stay as they are. The check also runs before every ISO build.	Verifica o seu autounattend.xml, a pasta $OEM$ e os controladores em rela&#xE7;&#xE3;o &#xE0; ISO que est&#xE1; a criar e indica o que estragaria ou pararia uma instala&#xE7;&#xE3;o limpa: &#xED;ndice de edi&#xE7;&#xE3;o ou idioma errados, nomes de computador / conta ou fuso hor&#xE1;rio inv&#xE1;lidos, n&#xFA;meros de comando repetidos, scripts que esperam por uma tecla, ficheiros em falta, controladores que nada instala ou que o Windows vai recusar, e o SetupComplete.cmd a ser ignorado em PCs com chave OEM. As corre&#xE7;&#xF5;es s&#xF3; alteram as c&#xF3;pias que v&#xE3;o para a ISO - os seus ficheiros ficam como est&#xE3;o. A verifica&#xE7;&#xE3;o tamb&#xE9;m corre antes de cada cria&#xE7;&#xE3;o da ISO.
Run the check	Executar a verifica&#xE7;&#xE3;o
Apply all fixes	Aplicar todas as corre&#xE7;&#xF5;es
Save fixed answer file as...	Guardar o ficheiro de respostas corrigido como...
Undo answer file fixes	Anular as corre&#xE7;&#xF5;es do ficheiro de respostas
Not run yet.	Ainda n&#xE3;o executada.
Level	N&#xED;vel
Area	&#xC1;rea
Finding	Resultado
Fix	Corre&#xE7;&#xE3;o
Also install the driver folders in my $OEM$\$1 with pnputil (from SetupComplete-drivers.cmd)	Instalar tamb&#xE9;m as pastas de controladores do meu $OEM$\$1 com o pnputil (a partir do SetupComplete-drivers.cmd)
Filter	Filtrar
Class, provider, INF or folder name	Classe, fornecedor, INF ou nome da pasta
All that fit	Todos os compat&#xED;veis
Tick shown	Marcar os vis&#xED;veis
None	Nenhum
Add ticked drivers	Adicionar os controladores marcados
Cancel	Cancelar
Driver signing certificate	Certificado de assinatura de controladores
Password	Palavra-passe
Repeat the password	Repetir a palavra-passe
Not there yet: {0}	Ainda n&#xE3;o existe: {0}
Dark theme	Tema escuro
Switch to the dark theme	Mudar para o tema escuro
Another job is still running.	Outra tarefa ainda est&#xE1; a decorrer.
{0} finished in {1:mm\:ss}	{0} conclu&#xED;do em {1:mm\:ss}
{0} stopped with an error - see the log	{0} parou com um erro - veja o registo
Unpack	Extrair
Analyze	Analisar
Download updates	Transferir atualiza&#xE7;&#xF5;es
Driver scan	An&#xE1;lise de controladores
Copy drivers	Copiar controladores
Folder scan	An&#xE1;lise de pasta
Import drivers	Importar controladores
Re-sign drivers	Voltar a assinar controladores
Slipstream	Integra&#xE7;&#xE3;o
Build ISO	Criar ISO
Apply fixes	Aplicar corre&#xE7;&#xF5;es
ISO check	Verifica&#xE7;&#xE3;o da ISO
no ISO yet	ainda sem ISO
{0}  |  {1}  |  {2}  |  {3} edition(s)	{0}  |  {1}  |  {2}  |  {3} edi&#xE7;&#xE3;o(&#xF5;es)
{0} free	{0} livres
unpacked	extra&#xED;da
{0} of {1} ticked	{0} de {1} marcadas
tick at least one	marque pelo menos uma
not available for this build	indispon&#xED;vel para esta compila&#xE7;&#xE3;o
{0} ({1}) + {2} more	{0} ({1}) + mais {2}
{0} packages ({1} for boot)	{0} pacotes ({1} para o arranque)
none (optional)	nenhum (opcional)
{0} error(s), {1} warning(s)	{0} erro(s), {1} aviso(s)
{0} warning(s)	{0} aviso(s)
all good	tudo bem
ISO ready	ISO pronta
slipstreamed ({0}) - build the ISO	integrada ({0}) - crie a ISO
Updates for Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 and 25H2 (x64, ARM64). On a Windows 10 PC the slipstream uses the DISM of the Windows ADK Deployment Tools, installed from Microsoft when needed.	Atualiza&#xE7;&#xF5;es para o Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 e 25H2 (x64, ARM64). Num PC com Windows 10, a integra&#xE7;&#xE3;o usa o DISM das Ferramentas de Implementa&#xE7;&#xE3;o do Windows ADK, instaladas a partir da Microsoft quando necess&#xE1;rio.
Updates for Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 and LTSC 2021 (x64, x86, ARM64).	Atualiza&#xE7;&#xF5;es para o Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 e LTSC 2021 (x64, x86, ARM64).
The unpacked ISO is Windows {0} - pick a Windows {1} ISO and unpack it to switch.	A ISO extra&#xED;da &#xE9; Windows {0} - escolha uma ISO do Windows {1} e extraia-a para mudar.
Download Windows {0} from Microsoft	Transferir o Windows {0} da Microsoft
Windows 11: the newest updates in the Microsoft Update Catalog are used (21H2, which is out of servicing: its last ones, 2024-10).	Windows 11: s&#xE3;o usadas as atualiza&#xE7;&#xF5;es mais recentes do Cat&#xE1;logo do Microsoft Update (21H2, j&#xE1; fora de suporte: as suas &#xFA;ltimas, 2024-10).
microsoft.com could not be reached, so only the list in this program was used - check again when online, the newest ISOs may be on the page.	N&#xE3;o foi poss&#xED;vel contactar microsoft.com, por isso s&#xF3; foi usada a lista deste programa - verifique de novo com liga&#xE7;&#xE3;o &#xE0; Internet, as ISOs mais recentes podem estar na p&#xE1;gina.
Its name is the one of a Visual Studio subscription or Volume Licensing download, which are original too but not on the public pages: compare the SHA-256 with the one shown on that portal.	O nome &#xE9; o de uma transfer&#xEA;ncia de uma subscri&#xE7;&#xE3;o do Visual Studio ou do Licenciamento por Volume, que tamb&#xE9;m s&#xE3;o originais mas n&#xE3;o est&#xE3;o nas p&#xE1;ginas p&#xFA;blicas: compare o SHA-256 com o indicado nesse portal.
An ISO made with the Media Creation Tool is built on the PC and is never listed, and an older ISO Microsoft no longer offers may be missing too. Otherwise it may have been modified: download an original Windows {0} ISO from Microsoft (button above) and use that one.	Uma ISO criada com a Ferramenta de Cria&#xE7;&#xE3;o de Multim&#xE9;dia &#xE9; gerada no PC e nunca est&#xE1; na lista, e uma ISO mais antiga que a Microsoft j&#xE1; n&#xE3;o disponibiliza tamb&#xE9;m pode faltar. Caso contr&#xE1;rio, pode ter sido modificada: transfira uma ISO original do Windows {0} da Microsoft (bot&#xE3;o acima) e use essa.
Its SHA-256 is one Microsoft published on its download page (seen there on {0}).	O seu SHA-256 &#xE9; um dos que a Microsoft publicou na p&#xE1;gina de transfer&#xEA;ncia (visto l&#xE1; em {0}).
Its SHA-256 is on Microsoft's download page (checked {0}).	O seu SHA-256 est&#xE1; na p&#xE1;gina de transfer&#xEA;ncia da Microsoft (verificado em {0}).
Original Microsoft ISO: {0} - {1}	ISO original da Microsoft: {0} - {1}
Made with the Media Creation Tool - setup and boot files signed by Microsoft	Criada com a Ferramenta de Cria&#xE7;&#xE3;o de Multim&#xE9;dia - ficheiros de instala&#xE7;&#xE3;o e de arranque assinados pela Microsoft
The Media Creation Tool builds the ISO on the PC from Microsoft's download, so its SHA-256 is never in Microsoft's list - that is normal. Its setup and boot files ({0} checked) carry Microsoft's signature; the Windows image in it (install.esd) isn't signed as a whole, so it isn't covered.	A Ferramenta de Cria&#xE7;&#xE3;o de Multim&#xE9;dia cria a ISO no PC a partir da transfer&#xEA;ncia da Microsoft, por isso o seu SHA-256 nunca est&#xE1; na lista da Microsoft - &#xE9; normal. Os ficheiros de instala&#xE7;&#xE3;o e de arranque ({0} verificados) t&#xEA;m a assinatura da Microsoft; a imagem do Windows (install.esd) n&#xE3;o &#xE9; assinada como um todo, por isso n&#xE3;o fica coberta.
Modified: files in this ISO are not signed by Microsoft	Modificada: h&#xE1; ficheiros nesta ISO que n&#xE3;o est&#xE3;o assinados pela Microsoft
Not signed by Microsoft: {0}. Download an original Windows {1} ISO from Microsoft (button above) and use that one.	Sem assinatura da Microsoft: {0}. Transfira uma ISO original do Windows {1} da Microsoft (bot&#xE3;o acima) e use essa.
Its setup and boot files are signed by Microsoft ({0} checked), but the Windows image in it can't be checked this way.	Os ficheiros de instala&#xE7;&#xE3;o e de arranque est&#xE3;o assinados pela Microsoft ({0} verificados), mas a imagem do Windows n&#xE3;o pode ser verificada desta forma.
Not verified: the SHA-256 is not one Microsoft lists for its Windows 10 and 11 ISOs.	N&#xE3;o verificada: o SHA-256 n&#xE3;o &#xE9; nenhum dos que a Microsoft indica para as ISOs do Windows 10 e 11.
Not checked yet - the ISO is checked when you unpack it, or now with Check the ISO.	Ainda n&#xE3;o verificada - a ISO &#xE9; verificada quando a extrair, ou j&#xE1; com Verificar a ISO.
{0}  -  build {1}  -  {2}  -  {3} edition(s)	{0}  -  compila&#xE7;&#xE3;o {1}  -  {2}  -  {3} edi&#xE7;&#xE3;o(&#xF5;es)
No automatic updates for this build - drivers, signed packages, answer file and $OEM$ still work.	Sem atualiza&#xE7;&#xF5;es autom&#xE1;ticas para esta compila&#xE7;&#xE3;o - controladores, pacotes assinados, ficheiro de respostas e $OEM$ continuam a funcionar.
Updates up to {0} (the last month Microsoft allows offline for Windows 10).	Atualiza&#xE7;&#xF5;es at&#xE9; {0} (o &#xFA;ltimo m&#xEA;s que a Microsoft permite integrar offline no Windows 10).
Its last updates ({0}) - this version is out of servicing.	As suas &#xFA;ltimas atualiza&#xE7;&#xF5;es ({0}) - esta vers&#xE3;o est&#xE1; fora de suporte.
Newest updates available in the Microsoft Update Catalog.	Atualiza&#xE7;&#xF5;es mais recentes dispon&#xED;veis no Cat&#xE1;logo do Microsoft Update.
The {0} enablement package is added too.	O pacote de ativa&#xE7;&#xE3;o {0} tamb&#xE9;m &#xE9; adicionado.
{0} driver package(s), {1} storage/network for boot.wim and WinRE, about {2:N0} MB	{0} pacote(s) de controladores, {1} de armazenamento/rede para o boot.wim e o WinRE, cerca de {2:N0} MB
No drivers selected.	Nenhum controlador selecionado.
this PC only ({0} kept)	s&#xF3; este PC ({0} mantidos)
all	todos
Ready - {0}, valid until {1:yyyy-MM-dd} (backed up as DriverSigning.pfx)	Pronto - {0}, v&#xE1;lido at&#xE9; {1:yyyy-MM-dd} (c&#xF3;pia de seguran&#xE7;a em DriverSigning.pfx)
In this PC's certificate store, not backed up yet - you will be asked for a password to save DriverSigning.pfx.	No arquivo de certificados deste PC, ainda sem c&#xF3;pia de seguran&#xE7;a - vai ser pedida uma palavra-passe para guardar o DriverSigning.pfx.
DriverSigning.pfx found - its password is asked when you sign.	DriverSigning.pfx encontrado - a palavra-passe &#xE9; pedida quando assinar.
None yet - one is created the first time you sign (you choose its password).	Ainda nenhum - &#xE9; criado na primeira vez que assinar (escolhe a palavra-passe).
{0}   (added {1})	{0}   (adicionado {1})
Slipstreamed on {0} - build {1}. Build the ISO next.	Integrada em {0} - compila&#xE7;&#xE3;o {1}. A seguir, crie a ISO.
{0} error(s), {1} warning(s), {2} check(s) passed   -   {3}	{0} erro(s), {1} aviso(s), {2} verifica&#xE7;&#xE3;o(&#xF5;es) aprovada(s)   -   {3}
Apply {0} fix(es)	Aplicar {0} corre&#xE7;&#xE3;o(&#xF5;es)
The ISO uses a fixed copy of your answer file (fixed {0}). Save it to update your own file too.	A ISO usa uma c&#xF3;pia corrigida do seu ficheiro de respostas (corrigida em {0}). Guarde-a para atualizar tamb&#xE9;m o seu ficheiro.
folder not found	pasta n&#xE3;o encontrada
{0} files, {1}   ({2})	{0} ficheiros, {1}   ({2})
has SetupComplete.cmd	tem SetupComplete.cmd
missing - downloaded automatically when you build the ISO	em falta - transferido automaticamente quando criar a ISO
missing - downloaded automatically when you sign drivers	em falta - transferido automaticamente quando assinar controladores
missing - downloaded only if the signing engine needs Inf2Cat as fallback	em falta - s&#xF3; &#xE9; transferido se o motor de assinatura precisar do Inf2Cat como alternativa
missing - only needed for the MakeCat signing engine	em falta - s&#xF3; &#xE9; preciso para o motor de assinatura MakeCat
missing - PowerShell / BITS downloads are used	em falta - s&#xE3;o usadas transfer&#xEA;ncias do PowerShell / BITS
Default. makecat.exe (Windows SDK) builds one catalog per driver folder with the hash of every file in it, so each file is hashed once - about 20 s for NVIDIA's 3 GB Display.Driver instead of minutes. Compressed files (name.dl_) are hashed expanded, the way Windows checks them. MakeCat does not parse the INF: every catalog is checked with signtool afterwards, and a folder MakeCat cannot do goes to Inf2Cat.	Predefinido. O makecat.exe (Windows SDK) cria um cat&#xE1;logo por pasta de controladores com o hash de todos os ficheiros nela, por isso cada ficheiro &#xE9; calculado uma s&#xF3; vez - cerca de 20 s para os 3 GB do Display.Driver da NVIDIA em vez de minutos. Os ficheiros comprimidos (nome.dl_) s&#xE3;o calculados expandidos, como o Windows os verifica. O MakeCat n&#xE3;o analisa o INF: cada cat&#xE1;logo &#xE9; verificado com o signtool depois, e uma pasta que o MakeCat n&#xE3;o consiga tratar passa para o Inf2Cat.
Experimental. The catalog is built with the CryptCAT API of Windows itself, the way libwdi (Zadig) does it - nothing to download. One catalog per driver folder with the hash of every file in it (SHA-1). Checked with signtool afterwards; a folder it cannot do goes to Inf2Cat.	Experimental. O cat&#xE1;logo &#xE9; criado com a API CryptCAT do pr&#xF3;prio Windows, como faz o libwdi (Zadig) - nada a transferir. Um cat&#xE1;logo por pasta de controladores com o hash de todos os ficheiros nela (SHA-1). Verificado com o signtool depois; uma pasta que n&#xE3;o consiga tratar passa para o Inf2Cat.
Experimental. LINBIT generate-cat-file (GPL-2.0): its source is downloaded from GitHub (one pinned commit, SHA-256 checked) and built inside WSL - needs WSL with a Linux distribution that has gcc and make. One catalog per driver folder; Inf2Cat signs when WSL or the build is missing.	Experimental. LINBIT generate-cat-file (GPL-2.0): o c&#xF3;digo-fonte &#xE9; transferido do GitHub (um commit fixo, verificado com SHA-256) e compilado dentro do WSL - precisa do WSL com uma distribui&#xE7;&#xE3;o Linux que tenha gcc e make. Um cat&#xE1;logo por pasta de controladores; o Inf2Cat assina quando falta o WSL ou a compila&#xE7;&#xE3;o.
Microsoft's standard tool from the Windows Driver Kit: it parses every INF and checks it against every file of the package. The proven choice, but slow on big packages - the options below make it faster.	A ferramenta padr&#xE3;o da Microsoft, do Windows Driver Kit: analisa cada INF e verifica-o contra todos os ficheiros do pacote. A escolha comprovada, mas lenta em pacotes grandes - as op&#xE7;&#xF5;es abaixo tornam-na mais r&#xE1;pida.
installs from {0} during Windows setup	instala a partir de {0} durante a instala&#xE7;&#xE3;o do Windows
{0} older version(s) of drivers that are here in a newer version too are unticked (column Older) - Windows uses the newest one.	{0} vers&#xE3;o(&#xF5;es) antiga(s) de controladores que tamb&#xE9;m est&#xE3;o aqui numa vers&#xE3;o mais recente ficam desmarcadas (coluna Antiga) - o Windows usa a mais recente.
DriverSigning.pfx was found next to this tool. Enter its password to load your signing certificate.	O DriverSigning.pfx foi encontrado ao lado desta ferramenta. Introduza a palavra-passe para carregar o seu certificado de assinatura.
Your signing certificate is in this PC's store but has no backup yet. Choose a password to save it as DriverSigning.pfx - you need it to sign again after reinstalling Windows.	O seu certificado de assinatura est&#xE1; no arquivo deste PC mas ainda n&#xE3;o tem c&#xF3;pia de seguran&#xE7;a. Escolha uma palavra-passe para o guardar como DriverSigning.pfx - precisa dele para voltar a assinar depois de reinstalar o Windows.
A new self-signed code-signing certificate will be created. Choose a password for its backup file DriverSigning.pfx - you need it to sign again after reinstalling Windows.	Vai ser criado um novo certificado de assinatura de c&#xF3;digo autoassinado. Escolha uma palavra-passe para o ficheiro de c&#xF3;pia de seguran&#xE7;a DriverSigning.pfx - precisa dele para voltar a assinar depois de reinstalar o Windows.
Enter a password.	Introduza uma palavra-passe.
The passwords do not match.	As palavras-passe n&#xE3;o coincidem.
Index	&#xCD;ndice
Edition	Edi&#xE7;&#xE3;o
Build	Compila&#xE7;&#xE3;o
Size	Tamanho
SizeGB	Tamanho (GB)
Kind	Tipo
Date	Data
Title	T&#xED;tulo
No	N.&#xBA;
Source	Origem
Class	Classe
Provider	Fornecedor
Version	Vers&#xE3;o
SizeMB	Tamanho (MB)
InstallsFrom	Instala de
Signed	Assinados
Failed	Falhados
When	Quando
FixText	Corre&#xE7;&#xE3;o
Arch	Arquitetura
Older	Antiga
Unpack an ISO first (page 1).	Extraia primeiro uma ISO (p&#xE1;gina 1).
Choose an existing .iso file first.	Escolha primeiro um ficheiro .iso existente.
The work folder already has unpacked media ({0}). Replace it with a fresh copy of this ISO?	A pasta de trabalho j&#xE1; tem um suporte extra&#xED;do ({0}). Substitu&#xED;-lo por uma c&#xF3;pia nova desta ISO?
Unpack this ISO anyway?	Extrair esta ISO mesmo assim?
Drivers installed on this PC	Controladores instalados neste PC
Third-party drivers exported from this PC. Ticked ones are slipstreamed into the ISO.	Controladores de terceiros exportados deste PC. Os marcados s&#xE3;o integrados na ISO.
Pick the drivers folder - Drivers-Backup made by Drivers.cmd, a folder from another PC or a vendor pack. All subfolders are scanned.	Escolha a pasta de controladores - Drivers-Backup criada pelo Drivers.cmd, uma pasta de outro PC ou um pacote do fabricante. Todas as subpastas s&#xE3;o analisadas.
No .inf drivers in that folder.	N&#xE3;o h&#xE1; controladores .inf nessa pasta.
Drivers in {0}	Controladores em {0}
Drivers built for another architecture than the ISO are unticked and left out.	Os controladores feitos para outra arquitetura que n&#xE3;o a da ISO ficam desmarcados e de fora.
Choose the driver folder first (for example the folder NVCleanstall extracted).	Escolha primeiro a pasta dos controladores (por exemplo a pasta que o NVCleanstall extraiu).
There are no .inf files in that folder or its subfolders.	N&#xE3;o h&#xE1; ficheiros .inf nessa pasta nem nas subpastas.
Tick at least one edition first.	Marque primeiro pelo menos uma edi&#xE7;&#xE3;o.
This media was already slipstreamed on {0}. For a clean result unpack the ISO again (page 1). Slipstream again anyway?	Este suporte j&#xE1; foi integrado em {0}. Para um resultado limpo, extraia de novo a ISO (p&#xE1;gina 1). Integrar de novo mesmo assim?
No updates are downloaded (page 3). Continue with drivers and options only?	N&#xE3;o h&#xE1; atualiza&#xE7;&#xF5;es transferidas (p&#xE1;gina 3). Continuar s&#xF3; com controladores e op&#xE7;&#xF5;es?
The media has not been slipstreamed yet. Build the ISO anyway (drivers, updates and options are then missing)?	O suporte ainda n&#xE3;o foi integrado. Criar a ISO mesmo assim (faltam ent&#xE3;o os controladores, as atualiza&#xE7;&#xF5;es e as op&#xE7;&#xF5;es)?
Nothing to fix automatically - run the check first. Findings without a fix need a change on the page they mention.	Nada para corrigir automaticamente - execute primeiro a verifica&#xE7;&#xE3;o. Os resultados sem corre&#xE7;&#xE3;o precisam de uma altera&#xE7;&#xE3;o na p&#xE1;gina que indicam.
Apply these fixes? They change the copies that go into the ISO, not your own files.	Aplicar estas corre&#xE7;&#xF5;es? Alteram as c&#xF3;pias que v&#xE3;o para a ISO, n&#xE3;o os seus ficheiros.
Choose the source ISO on page 1 first.	Escolha primeiro a ISO de origem na p&#xE1;gina 1.
yes	sim
no	n&#xE3;o
Source: {0}	Origem: {0}
Editions: {0}	Edi&#xE7;&#xF5;es: {0}
{0} ticked	{0} marcadas
asked after unpacking	perguntado depois de extrair
Drivers: {0}   Signed packages: {1}	Controladores: {0}   Pacotes assinados: {1}
Answer file: {0}   $OEM$: {1}	Ficheiro de respostas: {0}   $OEM$: {1}
Run everything now? It takes 30-90 minutes - the PC is kept awake until it is done.	Executar tudo agora? Demora 30-90 minutos - o PC fica acordado at&#xE9; terminar.
Run everything with this ISO anyway?	Executar tudo com esta ISO mesmo assim?
While a job runs (unpack, download, sign, slipstream, build), Windows Defender does not scan the work folder ({0}). The exclusion is removed when the job ends, and at the next start if the program was closed during a job. Everything in there comes from Microsoft, your drivers and this tool - do not put other downloads in that folder.	Durante uma tarefa (extrair, transferir, assinar, integrar, criar), o Windows Defender n&#xE3;o analisa a pasta de trabalho ({0}). A exclus&#xE3;o &#xE9; removida quando a tarefa termina, e no pr&#xF3;ximo arranque se o programa tiver sido fechado durante uma tarefa. Tudo o que l&#xE1; est&#xE1; vem da Microsoft, dos seus controladores e desta ferramenta - n&#xE3;o coloque l&#xE1; outras transfer&#xEA;ncias.
Use this only when the ISO is for this PC. INF files for other hardware are removed from the signed copy, so the driver installs only on hardware that matches this PC. NVIDIA's own setup.exe may refuse to run from that copy - pnputil installs the driver anyway. Sign the package again for it to take effect.	Use isto s&#xF3; quando a ISO &#xE9; para este PC. Os ficheiros INF de outro hardware s&#xE3;o removidos da c&#xF3;pia assinada, por isso o controlador s&#xF3; se instala em hardware igual ao deste PC. O pr&#xF3;prio setup.exe da NVIDIA pode recusar-se a correr a partir dessa c&#xF3;pia - o pnputil instala o controlador na mesma. Assine o pacote de novo para ter efeito.
With Secure Boot on, this ISO only boots on PCs whose UEFI already trusts 'Windows UEFI CA 2023'. Older firmware needs that Secure Boot update first (or Secure Boot off). The image also needs a 2024-04 or newer update.	Com o Arranque Seguro ativo, esta ISO s&#xF3; arranca em PCs cujo UEFI j&#xE1; confia na 'Windows UEFI CA 2023'. Firmware mais antigo precisa primeiro dessa atualiza&#xE7;&#xE3;o do Arranque Seguro (ou do Arranque Seguro desligado). A imagem tamb&#xE9;m precisa de uma atualiza&#xE7;&#xE3;o de 2024-04 ou mais recente.
Use the YYYY-MM format, e.g. 2025-10.	Use o formato AAAA-MM, p. ex. 2025-10.
Use a number from 1 to 8 (or leave it empty for the number of processor cores, up to 8).	Use um n&#xFA;mero de 1 a 8 (ou deixe vazio para o n&#xFA;mero de n&#xFA;cleos do processador, at&#xE9; 8).
Use a number from 1 to 4 (or leave it empty: 2 on 4+ processor cores, 3 on 8+).	Use um n&#xFA;mero de 1 a 4 (ou deixe vazio: 2 com 4+ n&#xFA;cleos, 3 com 8+).
Select a Windows {0} ISO	Selecione uma ISO do Windows {0}
ISO images	Imagens ISO
Select the drivers to remove in the list first (Ctrl+click for several).	Selecione primeiro na lista os controladores a remover (Ctrl+clique para v&#xE1;rios).
Remove every selected driver?	Remover todos os controladores selecionados?
Pick the modded driver folder (e.g. the folder NVCleanstall extracted). All subfolders are scanned.	Escolha a pasta dos controladores modificados (p. ex. a pasta que o NVCleanstall extraiu). Todas as subpastas s&#xE3;o analisadas.
Select a package in the list first.	Selecione primeiro um pacote na lista.
Select your autounattend.xml	Selecione o seu autounattend.xml
Answer files	Ficheiros de respostas
Pick your $OEM$ folder (the one that contains $1 and/or $$)	Escolha a sua pasta $OEM$ (a que cont&#xE9;m $1 e/ou $$)
ISO image	Imagem ISO
Pick or create the work folder (NTFS, no spaces, ~30 GB free)	Escolha ou crie a pasta de trabalho (NTFS, sem espa&#xE7;os, ~30 GB livres)
The path has spaces - a short path like D:\W10U is safer for DISM. Use it anyway?	O caminho tem espa&#xE7;os - um caminho curto como D:\W10U &#xE9; mais seguro para o DISM. Us&#xE1;-lo mesmo assim?
downloaded updates	atualiza&#xE7;&#xF5;es transferidas
unpacked media	suporte extra&#xED;do
built ISOs	ISOs criadas
re-signed driver copies	c&#xF3;pias de controladores assinados de novo
copied drivers	controladores copiados
answer file copy and check results	c&#xF3;pia do ficheiro de respostas e resultados da verifica&#xE7;&#xE3;o
logs	registos
EVERYTHING in the work folder	TUDO o que est&#xE1; na pasta de trabalho
mounted images and temp files	imagens montadas e ficheiros tempor&#xE1;rios
Delete: {0}?	Apagar: {0}?
Restore the default options? The work folder is kept.	Repor as op&#xE7;&#xF5;es predefinidas? A pasta de trabalho &#xE9; mantida.
There is no answer file yet (page 6).	Ainda n&#xE3;o h&#xE1; ficheiro de respostas (p&#xE1;gina 6).
Answer file	Ficheiro de respostas
No answer file fixes to undo.	N&#xE3;o h&#xE1; corre&#xE7;&#xF5;es do ficheiro de respostas para anular.
Put the answer file back the way it was before the fixes?	Repor o ficheiro de respostas como estava antes das corre&#xE7;&#xF5;es?
'{0}' is still running. Closing now can leave a mounted image behind (run Clean up next time). Close anyway?	'{0}' ainda est&#xE1; a decorrer. Fechar agora pode deixar uma imagem montada (execute a Limpeza da pr&#xF3;xima vez). Fechar mesmo assim?
'@ }
        'es' { return @'
updates + drivers + signed NVIDIA mods + autounattend + $OEM$  ->  bootable ISO	actualizaciones + controladores + mods NVIDIA firmados + autounattend + $OEM$  ->  ISO de arranque
Light theme	Tema claro
Switch to the light theme	Cambiar al tema claro
Display and accessibility: theme, text size, font	Pantalla y accesibilidad: tema, tama&#xF1;o del texto, fuente
Display and accessibility settings	Configuraci&#xF3;n de pantalla y accesibilidad
Minimize	Minimizar
Maximize	Maximizar
Close	Cerrar
Display and accessibility	Pantalla y accesibilidad
Theme	Tema
Dark	Oscuro
Light	Claro
Like Windows	Como Windows
Text size	Tama&#xF1;o del texto
Font	Fuente
Language	Idioma
Ctrl + plus / Ctrl + minus / Ctrl + 0 change the text size anywhere in the window. Verdana and Tahoma have wider, more distinct letters. Saved for the next start.	Ctrl + m&#xE1;s / Ctrl + menos / Ctrl + 0 cambian el tama&#xF1;o del texto en cualquier parte de la ventana. Verdana y Tahoma tienen letras m&#xE1;s anchas y m&#xE1;s claras. Se guarda para el pr&#xF3;ximo inicio.
The Activity log and the Install check findings stay in English - that is what a bug report or a search needs.	El registro de Actividad y los resultados de la Comprobaci&#xF3;n de la instalaci&#xF3;n se quedan en ingl&#xE9;s: es lo que necesita un informe de error o una b&#xFA;squeda.
STEPS	PASOS
Source ISO	ISO de origen
to do	pendiente
Editions	Ediciones
Windows updates	Actualizaciones de Windows
Drivers	Controladores
optional	opcional
Signed NVIDIA / modded	NVIDIA firmados / modificados
Answer file + $OEM$	Archivo de respuesta + $OEM$
Install check	Comprobaci&#xF3;n de la instalaci&#xF3;n
not run yet	a&#xFA;n no ejecutada
Slipstream + build ISO	Integrar + crear ISO
MORE	M&#xC1;S
Options and clean up	Opciones y limpieza
Tools	Herramientas
Run everything	Ejecutar todo
unpack - updates - slipstream - ISO, using what you set on each page	extraer - actualizaciones - integrar - ISO, con lo que configure en cada p&#xE1;gina
SOURCE	ORIGEN
IMAGE	IMAGEN
WORK FOLDER	CARPETA DE TRABAJO
ACTIVITY	ACTIVIDAD
Ready	Listo
Logs folder	Carpeta de registros
Clear	Borrar
Choose Windows 10 or Windows 11 and pick its ISO. It is copied into the work folder and its build and editions are detected - the version follows the ISO you unpack.	Elija Windows 10 o Windows 11 y seleccione su ISO. Se copia en la carpeta de trabajo y se detectan su compilaci&#xF3;n y sus ediciones; la versi&#xF3;n sigue a la ISO que extraiga.
Windows version	Versi&#xF3;n de Windows
ISO file	Archivo ISO
Use an original ISO from Microsoft. Before it is unpacked, its SHA-256 is compared with the ones Microsoft publishes for its Windows 10 and 11 ISOs - the list in this program and, when online, the download pages on microsoft.com. When it is not there (an ISO made with the Media Creation Tool never is), the Microsoft signatures of its setup and boot files are checked.	Use una ISO original de Microsoft. Antes de extraerla, su SHA-256 se compara con los que Microsoft publica para sus ISO de Windows 10 y 11: la lista de este programa y, con conexi&#xF3;n a Internet, las p&#xE1;ginas de descarga de microsoft.com. Si no est&#xE1; ah&#xED; (una ISO creada con la Herramienta de creaci&#xF3;n de medios nunca lo est&#xE1;), se comprueban las firmas de Microsoft de sus archivos de instalaci&#xF3;n y de arranque.
Browse...	Examinar...
Unpack and analyze	Extraer y analizar
Check the ISO	Comprobar la ISO
Re-read image info	Volver a leer la imagen
Download Windows 10 from Microsoft	Descargar Windows 10 de Microsoft
SHA-256 of the ISO - select it to copy	SHA-256 de la ISO: selecci&#xF3;nelo para copiarlo
Detected image	Imagen detectada
Nothing unpacked yet.	Todav&#xED;a no se ha extra&#xED;do nada.
Tick the editions to update. With the option below on, unticked editions are left out of the new ISO (smaller and faster).	Marque las ediciones que quiere actualizar. Con la opci&#xF3;n de abajo activada, las ediciones sin marcar se quedan fuera de la nueva ISO (m&#xE1;s peque&#xF1;a y m&#xE1;s r&#xE1;pida).
Tick all	Marcar todas
Tick none	Desmarcar todas
Use	Usar
Keep only the ticked editions in the new ISO	Conservar solo las ediciones marcadas en la nueva ISO
Finds the newest cumulative update, servicing stack, Safe OS and Setup Dynamic Updates and .NET updates for this build in the Microsoft Update Catalog and downloads them (SHA-1 checked).	Busca en el Cat&#xE1;logo de Microsoft Update la actualizaci&#xF3;n acumulativa m&#xE1;s reciente, la pila de servicio, las Actualizaciones din&#xE1;micas de Safe OS y de instalaci&#xF3;n y las actualizaciones de .NET para esta compilaci&#xF3;n, y las descarga (comprobadas con SHA-1).
What to integrate	Qu&#xE9; integrar
Add .NET Framework 4.8.1 (Windows 10 2004-22H2 - Windows 11 has it built in)	A&#xF1;adir .NET Framework 4.8.1 (Windows 10 2004-22H2; Windows 11 ya lo incluye)
Enable .NET Framework 3.5 (from the ISO's sources\sxs)	Activar .NET Framework 3.5 (desde sources\sxs de la ISO)
Component cleanup /ResetBase (smaller image - updates can't be uninstalled)	Limpieza de componentes /ResetBase (imagen m&#xE1;s peque&#xF1;a; las actualizaciones ya no se pueden desinstalar)
Newest month to integrate	Mes m&#xE1;s reciente que integrar
YYYY-MM, for Windows 10 2004-22H2 / LTSC 2021	AAAA-MM, para Windows 10 2004-22H2 / LTSC 2021
2025-10 is the last Windows 10 update Microsoft allows offline. ESU updates (Nov 2025+) come from Windows Update after setup on enrolled PCs.	2025-10 es la &#xFA;ltima actualizaci&#xF3;n de Windows 10 que Microsoft permite integrar sin conexi&#xF3;n. Las actualizaciones ESU (nov. 2025+) llegan por Windows Update despu&#xE9;s de la instalaci&#xF3;n, en los PC inscritos.
Find and download updates	Buscar y descargar actualizaciones
Downloaded	Descargadas
Signed drivers are slipstreamed into install.wim with DISM, so Windows installs them on first boot. Storage and network drivers also go into boot.wim and WinRE, so Setup sees RAID / VMD disks. Modded drivers (edited INF) belong on the next page.	Los controladores firmados se integran en install.wim con DISM, para que Windows los instale en el primer arranque. Los controladores de almacenamiento y de red van tambi&#xE9;n a boot.wim y WinRE, para que el programa de instalaci&#xF3;n vea discos RAID / VMD. Los controladores modificados (INF editado) van en la p&#xE1;gina siguiente.
Add drivers from this PC	A&#xF1;adir controladores de este PC
Import a drivers folder	Importar una carpeta de controladores
Remove selected	Quitar los seleccionados
Clear all	Quitar todos
Also put storage and network drivers into boot.wim and WinRE	Poner tambi&#xE9;n los controladores de almacenamiento y de red en boot.wim y WinRE
Allow unsigned drivers in DISM (/ForceUnsigned)	Permitir controladores sin firmar en DISM (/ForceUnsigned)
Signed NVIDIA / modded drivers	Controladores NVIDIA firmados / modificados
For driver packages whose INF was edited - NVCleanstall hardware-ID mods for an unsupported GPU, custom INF files. The edit breaks the catalog signature, so Windows refuses them. Every subfolder is scanned; each modified package gets a new catalog (MakeCat by default, or the engine you pick below) signed with your own certificate. The package is added to the ISO through $OEM$ and installed by SetupComplete.cmd at the end of Windows setup, right after the certificate is trusted.	Para paquetes de controladores cuyo INF se ha editado: mods de ID de hardware de NVCleanstall para una GPU no compatible, archivos INF personalizados. La edici&#xF3;n rompe la firma del cat&#xE1;logo y Windows los rechaza. Se analizan todas las subcarpetas; cada paquete modificado recibe un cat&#xE1;logo nuevo (MakeCat de forma predeterminada, o el motor que elija abajo) firmado con su propio certificado. El paquete se a&#xF1;ade a la ISO mediante $OEM$ y lo instala SetupComplete.cmd al final de la instalaci&#xF3;n de Windows, justo despu&#xE9;s de que el certificado pase a ser de confianza.
Driver package	Paquete de controladores
Folder	Carpeta
Name	Nombre
installs from C:\Drivers\NVIDIA during setup	se instala desde C:\Drivers\NVIDIA durante la instalaci&#xF3;n
Engine	Motor
Signing engine: MakeCat	Motor de firma: MakeCat
Signing engine: libwdi-style	Motor de firma: libwdi-style
Signing engine: generate-cat-file in WSL	Motor de firma: generate-cat-file en WSL
Signing engine: Inf2Cat	Motor de firma: Inf2Cat
Re-sign every package, not only the modified ones	Volver a firmar todos los paquetes, no solo los modificados
Delete the driver copy from C:\Drivers once it is installed	Eliminar la copia de los controladores de C:\Drivers una vez instalada
Faster: new catalogs only for the INF files that need one	M&#xE1;s r&#xE1;pido: cat&#xE1;logos nuevos solo para los archivos INF que lo necesitan
Every INF stays in the package, and the ones you did not edit keep their NVIDIA / Microsoft signature. MakeCat and the other folder engines point only the edited INF files at the folder's new catalog (off: every INF of the folder). Inf2Cat gets a copy of the folder with only the edited INF files (the driver files are hard links - no extra space), several at the same time; an edited INF whose catalog is shared with the others (nv_dispi.cat) gets a catalog file of its own. If Inf2Cat fails on that copy, the whole folder is catalogued as before.	Todos los INF se quedan en el paquete, y los que no ha editado conservan su firma de NVIDIA / Microsoft. MakeCat y los dem&#xE1;s motores por carpeta apuntan solo los INF editados al nuevo cat&#xE1;logo de la carpeta (desactivado: todos los INF de la carpeta). Inf2Cat recibe una copia de la carpeta solo con los INF editados (los archivos de los controladores son v&#xED;nculos f&#xED;sicos: sin espacio extra), varias a la vez; un INF editado cuyo cat&#xE1;logo se comparte con los dem&#xE1;s (nv_dispi.cat) recibe un archivo de cat&#xE1;logo propio. Si Inf2Cat falla con esa copia, la carpeta entera se cataloga como antes.
Faster: only keep the INF files for this PC's hardware (when the ISO is for this PC)	M&#xE1;s r&#xE1;pido: conservar solo los archivos INF del hardware de este PC (cuando la ISO es para este PC)
Mostly for Inf2Cat: NVIDIA's Display.Driver has one INF file per laptop and desktop maker, and Inf2Cat checks every one of them against the whole package - that can take up to an hour. With this on, only the INF files that list a device of this PC are signed (minutes instead), the others are removed from the copy. The original folder is not touched.	Sobre todo para Inf2Cat: el Display.Driver de NVIDIA tiene un archivo INF por cada fabricante de port&#xE1;tiles y de sobremesa, e Inf2Cat comprueba cada uno contra el paquete entero; puede tardar hasta una hora. Con esto activado, solo se firman los INF que indican un dispositivo de este PC (minutos en su lugar); los dem&#xE1;s se quitan de la copia. La carpeta original no se toca.
Catalog runs at the same time	Catalogaciones a la vez
1-8, empty = processor cores up to 8. Each Inf2Cat run uses one core; MakeCat does up to 4 folders at once.	1-8, vac&#xED;o = n&#xFA;cleos del procesador hasta 8. Cada ejecuci&#xF3;n de Inf2Cat usa un n&#xFA;cleo; MakeCat procesa hasta 4 carpetas a la vez.
Sign and add to the ISO	Firmar y a&#xF1;adir a la ISO
Open signing folder	Abrir la carpeta de firma
Signing certificate	Certificado de firma
DriverSigning.pfx (private key) stays in the signing folder next to this tool - back it up and never share or upload it. Only the public DriverSigning.cer goes into the ISO. Tools (makecat, Inf2Cat, signtool) are downloaded automatically.	DriverSigning.pfx (clave privada) se queda en la carpeta de firma junto a esta herramienta: haga una copia de seguridad y no lo comparta ni lo suba nunca. Solo el DriverSigning.cer p&#xFA;blico va a la ISO. Las herramientas (makecat, Inf2Cat, signtool) se descargan autom&#xE1;ticamente.
Packages added to the ISO	Paquetes a&#xF1;adidos a la ISO
Answer file and $OEM$	Archivo de respuesta y $OEM$
Both are optional and copied into the media when the ISO is built.	Ambos son opcionales y se copian en el medio cuando se crea la ISO.
none	ninguno
Placed in the ISO root so Setup runs unattended. Create one with the autounattend generator.	Se coloca en la ra&#xED;z de la ISO para que la instalaci&#xF3;n sea desatendida. Cree uno con el generador de autounattend.
Choose autounattend.xml	Elegir autounattend.xml
Open the generator	Abrir el generador
Remove	Quitar
$OEM$ folder	Carpeta $OEM$
Copied to sources\$OEM$: $OEM$\$1 lands in C:\ and $OEM$\$$ in C:\Windows (e.g. $$\Setup\Scripts\SetupComplete.cmd). Packages from the signed-drivers page are merged in, and your SetupComplete.cmd gets a call to SetupComplete-drivers.cmd as its first command.	Se copia en sources\$OEM$: $OEM$\$1 va a C:\ y $OEM$\$$ a C:\Windows (p. ej. $$\Setup\Scripts\SetupComplete.cmd). Los paquetes de la p&#xE1;gina de controladores firmados se a&#xF1;aden, y su SetupComplete.cmd recibe una llamada a SetupComplete-drivers.cmd como primer comando.
Choose $OEM$ folder	Elegir la carpeta $OEM$
Open	Abrir
Slipstream and build	Integrar y crear
Slipstream applies updates, drivers and options to WinRE, install.wim and boot.wim (30-90 minutes). Build writes the bootable BIOS + UEFI ISO with your answer file, $OEM$ and signed drivers.	La integraci&#xF3;n aplica actualizaciones, controladores y opciones a WinRE, install.wim y boot.wim (30-90 minutos). La creaci&#xF3;n escribe la ISO de arranque BIOS + UEFI con su archivo de respuesta, $OEM$ y controladores firmados.
Boot options	Opciones de arranque
UEFI boot without 'Press any key to boot from CD or DVD'	Arranque UEFI sin 'Presione cualquier tecla para arrancar desde el CD o DVD'
Boot manager signed by Windows UEFI CA 2023 (needs firmware that trusts it)	Administrador de arranque firmado por Windows UEFI CA 2023 (necesita un firmware que conf&#xED;e en ella)
Split install.wim into 3.8 GB parts (FAT32 USB sticks)	Dividir install.wim en partes de 3,8 GB (memorias USB FAT32)
Speed	Velocidad
Update boot.wim and WinRE at the same time as install.wim (faster, uses more CPU and disk)	Actualizar boot.wim y WinRE al mismo tiempo que install.wim (m&#xE1;s r&#xE1;pido, usa m&#xE1;s CPU y disco)
Editions at the same time	Ediciones a la vez
Editions updated at the same time	Ediciones actualizadas a la vez
1-4, empty = automatic (2 on 4+ processor cores, 3 on 8+). Each one needs about 25 GB free on the work drive; fewer run at once when there is less. 1 = one after the other.	1-4, vac&#xED;o = autom&#xE1;tico (2 con 4+ n&#xFA;cleos, 3 con 8+). Cada una necesita unos 25 GB libres en la unidad de trabajo; con menos espacio se ejecutan menos a la vez. 1 = una tras otra.
Let Windows Defender skip the work folder while a job runs (removed again afterwards)	Dejar que Windows Defender omita la carpeta de trabajo mientras se ejecuta una tarea (se quita despu&#xE9;s)
Leave boot.wim index 1 (Windows PE for WDS servers) as it is - USB / DVD setup uses index 2	Dejar el &#xED;ndice 1 de boot.wim (Windows PE para servidores WDS) como est&#xE1;; la instalaci&#xF3;n desde USB / DVD usa el &#xED;ndice 2
DISM applies each update with one process, so servicing one image cannot use more cores - updating boot.wim, WinRE and several editions side by side can. Defender scanning every file DISM writes is often the biggest slowdown. Storage / network drivers go into WinRE and boot.wim with one DISM call. The log ends with the time of every step.	DISM aplica cada actualizaci&#xF3;n con un solo proceso, as&#xED; que el mantenimiento de una imagen no aprovecha m&#xE1;s n&#xFA;cleos; actualizar boot.wim, WinRE y varias ediciones en paralelo s&#xED;. El an&#xE1;lisis de Defender de cada archivo que escribe DISM suele ser la mayor causa de lentitud. Los controladores de almacenamiento / red van a WinRE y boot.wim en una sola llamada a DISM. El registro termina con el tiempo de cada paso.
Output ISO	ISO de salida
Save as...	Guardar como...
Empty = work folder\output\Win10_ or Win11_version_build_arch_date.iso	Vac&#xED;o = carpeta de trabajo\output\Win10_ o Win11_versi&#xF3;n_compilaci&#xF3;n_arquitectura_fecha.iso
1 - Slipstream into the image	1 - Integrar en la imagen
2 - Build the ISO	2 - Crear la ISO
Open output folder	Abrir la carpeta de salida
Result	Resultado
No ISO built yet.	Todav&#xED;a no se ha creado ninguna ISO.
Work folder	Carpeta de trabajo
Apply	Aplicar
Short NTFS path without spaces with about 30 GB free (e.g. D:\W10U). A new folder starts empty.	Ruta NTFS corta, sin espacios, con unos 30 GB libres (p. ej. D:\W10U). Una carpeta nueva empieza vac&#xED;a.
Clean up	Limpieza
Leftover mounted images and temporary files are always removed. Also delete:	Las im&#xE1;genes montadas que quedaron y los archivos temporales se eliminan siempre. Eliminar tambi&#xE9;n:
Downloaded updates	Actualizaciones descargadas
Unpacked media	Medio extra&#xED;do
Built ISOs	ISO creadas
Re-signed driver copies	Copias de controladores firmados de nuevo
Copied drivers (this PC / imported folder)	Controladores copiados (este PC / carpeta importada)
Answer file copy and install check results (the answer file must be chosen again)	Copia del archivo de respuesta y resultados de la comprobaci&#xF3;n (habr&#xE1; que elegir de nuevo el archivo de respuesta)
Logs	Registros
Everything - empty the work folder and start from scratch	Todo: vaciar la carpeta de trabajo y empezar de cero
Clean up now	Limpiar ahora
Defaults	Valores predeterminados
Restore default options	Restaurar las opciones predeterminadas
Open work folder	Abrir la carpeta de trabajo
Everything missing is downloaded automatically when a step needs it, into the tools folder next to this file. oscdimg.exe comes from the Microsoft symbol server (SHA-256 checked) or the Windows ADK; makecat, Inf2Cat and signtool are extracted from Microsoft's NuGet packages (Windows SDK build tools / Windows Driver Kit) - only those tools are kept, nothing is installed.	Todo lo que falte se descarga autom&#xE1;ticamente cuando un paso lo necesita, en la carpeta tools junto a este archivo. oscdimg.exe viene del servidor de s&#xED;mbolos de Microsoft (comprobado con SHA-256) o del Windows ADK; makecat, Inf2Cat y signtool se extraen de los paquetes NuGet de Microsoft (Windows SDK build tools / Windows Driver Kit). Solo se guardan esas herramientas; no se instala nada.
Download missing tools now	Descargar ahora las herramientas que faltan
Open tools folder	Abrir la carpeta de herramientas
Checks your autounattend.xml, $OEM$ folder and drivers against the ISO you are building and points out what would break or stall a clean install: wrong edition index or language, invalid computer / account names or time zone, duplicate command numbers, scripts that wait for a key, missing files, drivers that nothing installs or that Windows will refuse, and SetupComplete.cmd being skipped on PCs with an OEM key. Fixes change only the copies that go into the ISO - your own files stay as they are. The check also runs before every ISO build.	Comprueba su autounattend.xml, la carpeta $OEM$ y los controladores con la ISO que est&#xE1; creando e indica lo que estropear&#xED;a o detendr&#xED;a una instalaci&#xF3;n limpia: &#xED;ndice de edici&#xF3;n o idioma incorrectos, nombres de equipo / cuenta o zona horaria no v&#xE1;lidos, n&#xFA;meros de comando duplicados, scripts que esperan una tecla, archivos que faltan, controladores que nada instala o que Windows rechazar&#xE1;, y SetupComplete.cmd omitido en PC con clave OEM. Las correcciones solo cambian las copias que van a la ISO; sus propios archivos quedan como est&#xE1;n. La comprobaci&#xF3;n tambi&#xE9;n se ejecuta antes de cada creaci&#xF3;n de la ISO.
Run the check	Ejecutar la comprobaci&#xF3;n
Apply all fixes	Aplicar todas las correcciones
Save fixed answer file as...	Guardar el archivo de respuesta corregido como...
Undo answer file fixes	Deshacer las correcciones del archivo de respuesta
Not run yet.	A&#xFA;n no ejecutada.
Level	Nivel
Area	&#xC1;rea
Finding	Hallazgo
Fix	Correcci&#xF3;n
Also install the driver folders in my $OEM$\$1 with pnputil (from SetupComplete-drivers.cmd)	Instalar tambi&#xE9;n las carpetas de controladores de mi $OEM$\$1 con pnputil (desde SetupComplete-drivers.cmd)
Filter	Filtrar
Class, provider, INF or folder name	Clase, proveedor, INF o nombre de carpeta
All that fit	Todos los compatibles
Tick shown	Marcar los visibles
None	Ninguno
Add ticked drivers	A&#xF1;adir los controladores marcados
Cancel	Cancelar
Driver signing certificate	Certificado de firma de controladores
Password	Contrase&#xF1;a
Repeat the password	Repetir la contrase&#xF1;a
Not there yet: {0}	Todav&#xED;a no existe: {0}
Dark theme	Tema oscuro
Switch to the dark theme	Cambiar al tema oscuro
Another job is still running.	Todav&#xED;a se est&#xE1; ejecutando otra tarea.
{0} finished in {1:mm\:ss}	{0} terminado en {1:mm\:ss}
{0} stopped with an error - see the log	{0} se detuvo con un error; consulte el registro
Unpack	Extraer
Analyze	Analizar
Download updates	Descargar actualizaciones
Driver scan	B&#xFA;squeda de controladores
Copy drivers	Copiar controladores
Folder scan	An&#xE1;lisis de carpeta
Import drivers	Importar controladores
Re-sign drivers	Volver a firmar controladores
Slipstream	Integraci&#xF3;n
Build ISO	Crear ISO
Apply fixes	Aplicar correcciones
ISO check	Comprobaci&#xF3;n de la ISO
no ISO yet	a&#xFA;n sin ISO
{0}  |  {1}  |  {2}  |  {3} edition(s)	{0}  |  {1}  |  {2}  |  {3} edici&#xF3;n(es)
{0} free	{0} libres
unpacked	extra&#xED;da
{0} of {1} ticked	{0} de {1} marcadas
tick at least one	marque al menos una
not available for this build	no disponible para esta compilaci&#xF3;n
{0} ({1}) + {2} more	{0} ({1}) + {2} m&#xE1;s
{0} packages ({1} for boot)	{0} paquetes ({1} para el arranque)
none (optional)	ninguno (opcional)
{0} error(s), {1} warning(s)	{0} error(es), {1} advertencia(s)
{0} warning(s)	{0} advertencia(s)
all good	todo correcto
ISO ready	ISO lista
slipstreamed ({0}) - build the ISO	integrada ({0}); cree la ISO
Updates for Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 and 25H2 (x64, ARM64). On a Windows 10 PC the slipstream uses the DISM of the Windows ADK Deployment Tools, installed from Microsoft when needed.	Actualizaciones para Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 y 25H2 (x64, ARM64). En un PC con Windows 10, la integraci&#xF3;n usa el DISM de las Herramientas de implementaci&#xF3;n del Windows ADK, que se instalan desde Microsoft cuando hace falta.
Updates for Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 and LTSC 2021 (x64, x86, ARM64).	Actualizaciones para Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 y LTSC 2021 (x64, x86, ARM64).
The unpacked ISO is Windows {0} - pick a Windows {1} ISO and unpack it to switch.	La ISO extra&#xED;da es Windows {0}; elija una ISO de Windows {1} y extr&#xE1;igala para cambiar.
Download Windows {0} from Microsoft	Descargar Windows {0} de Microsoft
Windows 11: the newest updates in the Microsoft Update Catalog are used (21H2, which is out of servicing: its last ones, 2024-10).	Windows 11: se usan las actualizaciones m&#xE1;s recientes del Cat&#xE1;logo de Microsoft Update (21H2, ya sin soporte: sus &#xFA;ltimas, 2024-10).
microsoft.com could not be reached, so only the list in this program was used - check again when online, the newest ISOs may be on the page.	No se pudo acceder a microsoft.com, as&#xED; que solo se us&#xF3; la lista de este programa; vuelva a comprobarlo con conexi&#xF3;n, las ISO m&#xE1;s recientes pueden estar en la p&#xE1;gina.
Its name is the one of a Visual Studio subscription or Volume Licensing download, which are original too but not on the public pages: compare the SHA-256 with the one shown on that portal.	Su nombre es el de una descarga de una suscripci&#xF3;n de Visual Studio o de Licencias por Volumen, que tambi&#xE9;n son originales pero no est&#xE1;n en las p&#xE1;ginas p&#xFA;blicas: compare el SHA-256 con el que se muestra en ese portal.
An ISO made with the Media Creation Tool is built on the PC and is never listed, and an older ISO Microsoft no longer offers may be missing too. Otherwise it may have been modified: download an original Windows {0} ISO from Microsoft (button above) and use that one.	Una ISO creada con la Herramienta de creaci&#xF3;n de medios se genera en el PC y nunca est&#xE1; en la lista, y una ISO m&#xE1;s antigua que Microsoft ya no ofrece tambi&#xE9;n puede faltar. Si no, puede haber sido modificada: descargue una ISO original de Windows {0} de Microsoft (bot&#xF3;n de arriba) y use esa.
Its SHA-256 is one Microsoft published on its download page (seen there on {0}).	Su SHA-256 es uno de los que Microsoft public&#xF3; en su p&#xE1;gina de descarga (visto all&#xED; el {0}).
Its SHA-256 is on Microsoft's download page (checked {0}).	Su SHA-256 est&#xE1; en la p&#xE1;gina de descarga de Microsoft (comprobado el {0}).
Original Microsoft ISO: {0} - {1}	ISO original de Microsoft: {0} - {1}
Made with the Media Creation Tool - setup and boot files signed by Microsoft	Creada con la Herramienta de creaci&#xF3;n de medios: archivos de instalaci&#xF3;n y de arranque firmados por Microsoft
The Media Creation Tool builds the ISO on the PC from Microsoft's download, so its SHA-256 is never in Microsoft's list - that is normal. Its setup and boot files ({0} checked) carry Microsoft's signature; the Windows image in it (install.esd) isn't signed as a whole, so it isn't covered.	La Herramienta de creaci&#xF3;n de medios crea la ISO en el PC a partir de la descarga de Microsoft, as&#xED; que su SHA-256 nunca est&#xE1; en la lista de Microsoft; es normal. Sus archivos de instalaci&#xF3;n y de arranque ({0} comprobados) llevan la firma de Microsoft; la imagen de Windows (install.esd) no est&#xE1; firmada en conjunto, as&#xED; que no queda cubierta.
Modified: files in this ISO are not signed by Microsoft	Modificada: hay archivos en esta ISO que no est&#xE1;n firmados por Microsoft
Not signed by Microsoft: {0}. Download an original Windows {1} ISO from Microsoft (button above) and use that one.	Sin firma de Microsoft: {0}. Descargue una ISO original de Windows {1} de Microsoft (bot&#xF3;n de arriba) y use esa.
Its setup and boot files are signed by Microsoft ({0} checked), but the Windows image in it can't be checked this way.	Sus archivos de instalaci&#xF3;n y de arranque est&#xE1;n firmados por Microsoft ({0} comprobados), pero la imagen de Windows no se puede comprobar de esta forma.
Not verified: the SHA-256 is not one Microsoft lists for its Windows 10 and 11 ISOs.	No verificada: el SHA-256 no es ninguno de los que Microsoft indica para sus ISO de Windows 10 y 11.
Not checked yet - the ISO is checked when you unpack it, or now with Check the ISO.	A&#xFA;n sin comprobar: la ISO se comprueba al extraerla, o ahora con Comprobar la ISO.
{0}  -  build {1}  -  {2}  -  {3} edition(s)	{0}  -  compilaci&#xF3;n {1}  -  {2}  -  {3} edici&#xF3;n(es)
No automatic updates for this build - drivers, signed packages, answer file and $OEM$ still work.	No hay actualizaciones autom&#xE1;ticas para esta compilaci&#xF3;n; los controladores, los paquetes firmados, el archivo de respuesta y $OEM$ siguen funcionando.
Updates up to {0} (the last month Microsoft allows offline for Windows 10).	Actualizaciones hasta {0} (el &#xFA;ltimo mes que Microsoft permite integrar sin conexi&#xF3;n en Windows 10).
Its last updates ({0}) - this version is out of servicing.	Sus &#xFA;ltimas actualizaciones ({0}); esta versi&#xF3;n ya no tiene soporte.
Newest updates available in the Microsoft Update Catalog.	Actualizaciones m&#xE1;s recientes disponibles en el Cat&#xE1;logo de Microsoft Update.
The {0} enablement package is added too.	Tambi&#xE9;n se a&#xF1;ade el paquete de habilitaci&#xF3;n {0}.
{0} driver package(s), {1} storage/network for boot.wim and WinRE, about {2:N0} MB	{0} paquete(s) de controladores, {1} de almacenamiento/red para boot.wim y WinRE, unos {2:N0} MB
No drivers selected.	No hay controladores seleccionados.
this PC only ({0} kept)	solo este PC ({0} conservados)
all	todos
Ready - {0}, valid until {1:yyyy-MM-dd} (backed up as DriverSigning.pfx)	Listo: {0}, v&#xE1;lido hasta {1:yyyy-MM-dd} (copia de seguridad en DriverSigning.pfx)
In this PC's certificate store, not backed up yet - you will be asked for a password to save DriverSigning.pfx.	En el almac&#xE9;n de certificados de este PC, todav&#xED;a sin copia de seguridad; se le pedir&#xE1; una contrase&#xF1;a para guardar DriverSigning.pfx.
DriverSigning.pfx found - its password is asked when you sign.	DriverSigning.pfx encontrado; la contrase&#xF1;a se pide al firmar.
None yet - one is created the first time you sign (you choose its password).	Todav&#xED;a ninguno; se crea la primera vez que firme (usted elige la contrase&#xF1;a).
{0}   (added {1})	{0}   (a&#xF1;adido {1})
Slipstreamed on {0} - build {1}. Build the ISO next.	Integrada el {0}, compilaci&#xF3;n {1}. Ahora cree la ISO.
{0} error(s), {1} warning(s), {2} check(s) passed   -   {3}	{0} error(es), {1} advertencia(s), {2} comprobaci&#xF3;n(es) superada(s)   -   {3}
Apply {0} fix(es)	Aplicar {0} correcci&#xF3;n(es)
The ISO uses a fixed copy of your answer file (fixed {0}). Save it to update your own file too.	La ISO usa una copia corregida de su archivo de respuesta (corregida el {0}). Gu&#xE1;rdela para actualizar tambi&#xE9;n su propio archivo.
folder not found	carpeta no encontrada
{0} files, {1}   ({2})	{0} archivos, {1}   ({2})
has SetupComplete.cmd	tiene SetupComplete.cmd
missing - downloaded automatically when you build the ISO	falta: se descarga autom&#xE1;ticamente al crear la ISO
missing - downloaded automatically when you sign drivers	falta: se descarga autom&#xE1;ticamente al firmar controladores
missing - downloaded only if the signing engine needs Inf2Cat as fallback	falta: solo se descarga si el motor de firma necesita Inf2Cat como alternativa
missing - only needed for the MakeCat signing engine	falta: solo se necesita para el motor de firma MakeCat
missing - PowerShell / BITS downloads are used	falta: se usan descargas de PowerShell / BITS
Default. makecat.exe (Windows SDK) builds one catalog per driver folder with the hash of every file in it, so each file is hashed once - about 20 s for NVIDIA's 3 GB Display.Driver instead of minutes. Compressed files (name.dl_) are hashed expanded, the way Windows checks them. MakeCat does not parse the INF: every catalog is checked with signtool afterwards, and a folder MakeCat cannot do goes to Inf2Cat.	Predeterminado. makecat.exe (Windows SDK) crea un cat&#xE1;logo por carpeta de controladores con el hash de todos sus archivos, as&#xED; que cada archivo se calcula una sola vez: unos 20 s para los 3 GB del Display.Driver de NVIDIA en lugar de minutos. Los archivos comprimidos (nombre.dl_) se calculan expandidos, como los comprueba Windows. MakeCat no analiza el INF: cada cat&#xE1;logo se comprueba despu&#xE9;s con signtool, y una carpeta que MakeCat no pueda procesar pasa a Inf2Cat.
Experimental. The catalog is built with the CryptCAT API of Windows itself, the way libwdi (Zadig) does it - nothing to download. One catalog per driver folder with the hash of every file in it (SHA-1). Checked with signtool afterwards; a folder it cannot do goes to Inf2Cat.	Experimental. El cat&#xE1;logo se crea con la API CryptCAT del propio Windows, como hace libwdi (Zadig); no hay nada que descargar. Un cat&#xE1;logo por carpeta de controladores con el hash de todos sus archivos (SHA-1). Se comprueba despu&#xE9;s con signtool; una carpeta que no pueda procesar pasa a Inf2Cat.
Experimental. LINBIT generate-cat-file (GPL-2.0): its source is downloaded from GitHub (one pinned commit, SHA-256 checked) and built inside WSL - needs WSL with a Linux distribution that has gcc and make. One catalog per driver folder; Inf2Cat signs when WSL or the build is missing.	Experimental. LINBIT generate-cat-file (GPL-2.0): su c&#xF3;digo fuente se descarga de GitHub (un commit fijo, comprobado con SHA-256) y se compila dentro de WSL; necesita WSL con una distribuci&#xF3;n Linux que tenga gcc y make. Un cat&#xE1;logo por carpeta de controladores; Inf2Cat firma cuando falta WSL o la compilaci&#xF3;n.
Microsoft's standard tool from the Windows Driver Kit: it parses every INF and checks it against every file of the package. The proven choice, but slow on big packages - the options below make it faster.	La herramienta est&#xE1;ndar de Microsoft, del Windows Driver Kit: analiza cada INF y lo comprueba contra todos los archivos del paquete. La opci&#xF3;n probada, pero lenta con paquetes grandes; las opciones de abajo la aceleran.
installs from {0} during Windows setup	se instala desde {0} durante la instalaci&#xF3;n de Windows
{0} older version(s) of drivers that are here in a newer version too are unticked (column Older) - Windows uses the newest one.	{0} versi&#xF3;n(es) antigua(s) de controladores que tambi&#xE9;n est&#xE1;n aqu&#xED; en una versi&#xF3;n m&#xE1;s nueva quedan desmarcadas (columna Antigua); Windows usa la m&#xE1;s reciente.
DriverSigning.pfx was found next to this tool. Enter its password to load your signing certificate.	Se encontr&#xF3; DriverSigning.pfx junto a esta herramienta. Escriba su contrase&#xF1;a para cargar su certificado de firma.
Your signing certificate is in this PC's store but has no backup yet. Choose a password to save it as DriverSigning.pfx - you need it to sign again after reinstalling Windows.	Su certificado de firma est&#xE1; en el almac&#xE9;n de este PC pero todav&#xED;a no tiene copia de seguridad. Elija una contrase&#xF1;a para guardarlo como DriverSigning.pfx; lo necesitar&#xE1; para volver a firmar despu&#xE9;s de reinstalar Windows.
A new self-signed code-signing certificate will be created. Choose a password for its backup file DriverSigning.pfx - you need it to sign again after reinstalling Windows.	Se crear&#xE1; un nuevo certificado de firma de c&#xF3;digo autofirmado. Elija una contrase&#xF1;a para su archivo de copia de seguridad DriverSigning.pfx; lo necesitar&#xE1; para volver a firmar despu&#xE9;s de reinstalar Windows.
Enter a password.	Escriba una contrase&#xF1;a.
The passwords do not match.	Las contrase&#xF1;as no coinciden.
Index	&#xCD;ndice
Edition	Edici&#xF3;n
Build	Compilaci&#xF3;n
Size	Tama&#xF1;o
SizeGB	Tama&#xF1;o (GB)
Kind	Tipo
Date	Fecha
Title	T&#xED;tulo
No	N.&#xBA;
Source	Origen
Class	Clase
Provider	Proveedor
Version	Versi&#xF3;n
SizeMB	Tama&#xF1;o (MB)
InstallsFrom	Se instala desde
Signed	Firmados
Failed	Fallidos
When	Cu&#xE1;ndo
FixText	Correcci&#xF3;n
Arch	Arquitectura
Older	Antigua
Unpack an ISO first (page 1).	Extraiga primero una ISO (p&#xE1;gina 1).
Choose an existing .iso file first.	Elija primero un archivo .iso existente.
The work folder already has unpacked media ({0}). Replace it with a fresh copy of this ISO?	La carpeta de trabajo ya tiene un medio extra&#xED;do ({0}). &#xBF;Reemplazarlo por una copia nueva de esta ISO?
Unpack this ISO anyway?	&#xBF;Extraer esta ISO de todos modos?
Drivers installed on this PC	Controladores instalados en este PC
Third-party drivers exported from this PC. Ticked ones are slipstreamed into the ISO.	Controladores de terceros exportados de este PC. Los marcados se integran en la ISO.
Pick the drivers folder - Drivers-Backup made by Drivers.cmd, a folder from another PC or a vendor pack. All subfolders are scanned.	Elija la carpeta de controladores: Drivers-Backup creada por Drivers.cmd, una carpeta de otro PC o un paquete del fabricante. Se analizan todas las subcarpetas.
No .inf drivers in that folder.	No hay controladores .inf en esa carpeta.
Drivers in {0}	Controladores en {0}
Drivers built for another architecture than the ISO are unticked and left out.	Los controladores hechos para otra arquitectura distinta de la de la ISO quedan desmarcados y fuera.
Choose the driver folder first (for example the folder NVCleanstall extracted).	Elija primero la carpeta de los controladores (por ejemplo, la carpeta que extrajo NVCleanstall).
There are no .inf files in that folder or its subfolders.	No hay archivos .inf en esa carpeta ni en sus subcarpetas.
Tick at least one edition first.	Marque primero al menos una edici&#xF3;n.
This media was already slipstreamed on {0}. For a clean result unpack the ISO again (page 1). Slipstream again anyway?	Este medio ya se integr&#xF3; el {0}. Para un resultado limpio, vuelva a extraer la ISO (p&#xE1;gina 1). &#xBF;Integrar de nuevo de todos modos?
No updates are downloaded (page 3). Continue with drivers and options only?	No hay actualizaciones descargadas (p&#xE1;gina 3). &#xBF;Continuar solo con controladores y opciones?
The media has not been slipstreamed yet. Build the ISO anyway (drivers, updates and options are then missing)?	El medio todav&#xED;a no se ha integrado. &#xBF;Crear la ISO de todos modos (faltar&#xE1;n entonces los controladores, las actualizaciones y las opciones)?
Nothing to fix automatically - run the check first. Findings without a fix need a change on the page they mention.	No hay nada que corregir autom&#xE1;ticamente: ejecute primero la comprobaci&#xF3;n. Los hallazgos sin correcci&#xF3;n necesitan un cambio en la p&#xE1;gina que mencionan.
Apply these fixes? They change the copies that go into the ISO, not your own files.	&#xBF;Aplicar estas correcciones? Cambian las copias que van a la ISO, no sus propios archivos.
Choose the source ISO on page 1 first.	Elija primero la ISO de origen en la p&#xE1;gina 1.
yes	s&#xED;
no	no
Source: {0}	Origen: {0}
Editions: {0}	Ediciones: {0}
{0} ticked	{0} marcadas
asked after unpacking	se pregunta despu&#xE9;s de extraer
Drivers: {0}   Signed packages: {1}	Controladores: {0}   Paquetes firmados: {1}
Answer file: {0}   $OEM$: {1}	Archivo de respuesta: {0}   $OEM$: {1}
Run everything now? It takes 30-90 minutes - the PC is kept awake until it is done.	&#xBF;Ejecutar todo ahora? Tarda 30-90 minutos; el PC se mantiene despierto hasta que termine.
Run everything with this ISO anyway?	&#xBF;Ejecutar todo con esta ISO de todos modos?
While a job runs (unpack, download, sign, slipstream, build), Windows Defender does not scan the work folder ({0}). The exclusion is removed when the job ends, and at the next start if the program was closed during a job. Everything in there comes from Microsoft, your drivers and this tool - do not put other downloads in that folder.	Mientras se ejecuta una tarea (extraer, descargar, firmar, integrar, crear), Windows Defender no analiza la carpeta de trabajo ({0}). La exclusi&#xF3;n se quita cuando termina la tarea, y en el siguiente inicio si el programa se cerr&#xF3; durante una tarea. Todo lo que hay ah&#xED; viene de Microsoft, de sus controladores y de esta herramienta; no ponga otras descargas en esa carpeta.
Use this only when the ISO is for this PC. INF files for other hardware are removed from the signed copy, so the driver installs only on hardware that matches this PC. NVIDIA's own setup.exe may refuse to run from that copy - pnputil installs the driver anyway. Sign the package again for it to take effect.	Use esto solo cuando la ISO sea para este PC. Los archivos INF de otro hardware se quitan de la copia firmada, as&#xED; que el controlador solo se instala en hardware igual al de este PC. El propio setup.exe de NVIDIA puede negarse a ejecutarse desde esa copia; pnputil instala el controlador de todos modos. Vuelva a firmar el paquete para que tenga efecto.
With Secure Boot on, this ISO only boots on PCs whose UEFI already trusts 'Windows UEFI CA 2023'. Older firmware needs that Secure Boot update first (or Secure Boot off). The image also needs a 2024-04 or newer update.	Con el Arranque seguro activado, esta ISO solo arranca en PC cuyo UEFI ya conf&#xED;a en 'Windows UEFI CA 2023'. Los firmwares m&#xE1;s antiguos necesitan antes esa actualizaci&#xF3;n del Arranque seguro (o el Arranque seguro desactivado). La imagen tambi&#xE9;n necesita una actualizaci&#xF3;n de 2024-04 o m&#xE1;s reciente.
Use the YYYY-MM format, e.g. 2025-10.	Use el formato AAAA-MM, p. ej. 2025-10.
Use a number from 1 to 8 (or leave it empty for the number of processor cores, up to 8).	Use un n&#xFA;mero del 1 al 8 (o d&#xE9;jelo vac&#xED;o para usar el n&#xFA;mero de n&#xFA;cleos del procesador, hasta 8).
Use a number from 1 to 4 (or leave it empty: 2 on 4+ processor cores, 3 on 8+).	Use un n&#xFA;mero del 1 al 4 (o d&#xE9;jelo vac&#xED;o: 2 con 4+ n&#xFA;cleos, 3 con 8+).
Select a Windows {0} ISO	Seleccione una ISO de Windows {0}
ISO images	Im&#xE1;genes ISO
Select the drivers to remove in the list first (Ctrl+click for several).	Seleccione primero en la lista los controladores que quiere quitar (Ctrl+clic para varios).
Remove every selected driver?	&#xBF;Quitar todos los controladores seleccionados?
Pick the modded driver folder (e.g. the folder NVCleanstall extracted). All subfolders are scanned.	Elija la carpeta de los controladores modificados (p. ej. la carpeta que extrajo NVCleanstall). Se analizan todas las subcarpetas.
Select a package in the list first.	Seleccione primero un paquete en la lista.
Select your autounattend.xml	Seleccione su autounattend.xml
Answer files	Archivos de respuesta
Pick your $OEM$ folder (the one that contains $1 and/or $$)	Elija su carpeta $OEM$ (la que contiene $1 y/o $$)
ISO image	Imagen ISO
Pick or create the work folder (NTFS, no spaces, ~30 GB free)	Elija o cree la carpeta de trabajo (NTFS, sin espacios, ~30 GB libres)
The path has spaces - a short path like D:\W10U is safer for DISM. Use it anyway?	La ruta tiene espacios; una ruta corta como D:\W10U es m&#xE1;s segura para DISM. &#xBF;Usarla de todos modos?
downloaded updates	actualizaciones descargadas
unpacked media	medio extra&#xED;do
built ISOs	ISO creadas
re-signed driver copies	copias de controladores firmados de nuevo
copied drivers	controladores copiados
answer file copy and check results	copia del archivo de respuesta y resultados de la comprobaci&#xF3;n
logs	registros
EVERYTHING in the work folder	TODO lo que hay en la carpeta de trabajo
mounted images and temp files	im&#xE1;genes montadas y archivos temporales
Delete: {0}?	&#xBF;Eliminar: {0}?
Restore the default options? The work folder is kept.	&#xBF;Restaurar las opciones predeterminadas? La carpeta de trabajo se conserva.
There is no answer file yet (page 6).	Todav&#xED;a no hay archivo de respuesta (p&#xE1;gina 6).
Answer file	Archivo de respuesta
No answer file fixes to undo.	No hay correcciones del archivo de respuesta que deshacer.
Put the answer file back the way it was before the fixes?	&#xBF;Devolver el archivo de respuesta a como estaba antes de las correcciones?
'{0}' is still running. Closing now can leave a mounted image behind (run Clean up next time). Close anyway?	'{0}' todav&#xED;a se est&#xE1; ejecutando. Cerrar ahora puede dejar una imagen montada (ejecute la Limpieza la pr&#xF3;xima vez). &#xBF;Cerrar de todos modos?
'@ }
        'fr' { return @'
updates + drivers + signed NVIDIA mods + autounattend + $OEM$  ->  bootable ISO	mises &#xE0; jour + pilotes + mods NVIDIA sign&#xE9;s + autounattend + $OEM$  ->  ISO amor&#xE7;able
Light theme	Th&#xE8;me clair
Switch to the light theme	Passer au th&#xE8;me clair
Display and accessibility: theme, text size, font	Affichage et accessibilit&#xE9; : th&#xE8;me, taille du texte, police
Display and accessibility settings	Param&#xE8;tres d'affichage et d'accessibilit&#xE9;
Minimize	R&#xE9;duire
Maximize	Agrandir
Close	Fermer
Display and accessibility	Affichage et accessibilit&#xE9;
Theme	Th&#xE8;me
Dark	Sombre
Light	Clair
Like Windows	Comme Windows
Text size	Taille du texte
Font	Police
Language	Langue
Ctrl + plus / Ctrl + minus / Ctrl + 0 change the text size anywhere in the window. Verdana and Tahoma have wider, more distinct letters. Saved for the next start.	Ctrl + plus / Ctrl + moins / Ctrl + 0 changent la taille du texte partout dans la fen&#xEA;tre. Verdana et Tahoma ont des lettres plus larges et plus lisibles. Enregistr&#xE9; pour le prochain d&#xE9;marrage.
The Activity log and the Install check findings stay in English - that is what a bug report or a search needs.	Le journal d'Activit&#xE9; et les r&#xE9;sultats de la V&#xE9;rification de l'installation restent en anglais : c'est ce dont un rapport de bug ou une recherche a besoin.
STEPS	&#xC9;TAPES
Source ISO	ISO source
to do	&#xE0; faire
Editions	&#xC9;ditions
Windows updates	Mises &#xE0; jour Windows
Drivers	Pilotes
optional	facultatif
Signed NVIDIA / modded	NVIDIA sign&#xE9;s / modifi&#xE9;s
Answer file + $OEM$	Fichier de r&#xE9;ponses + $OEM$
Install check	V&#xE9;rification de l'installation
not run yet	pas encore lanc&#xE9;e
Slipstream + build ISO	Int&#xE9;grer + cr&#xE9;er l'ISO
MORE	PLUS
Options and clean up	Options et nettoyage
Tools	Outils
Run everything	Tout ex&#xE9;cuter
unpack - updates - slipstream - ISO, using what you set on each page	extraire - mises &#xE0; jour - int&#xE9;grer - ISO, avec ce que vous avez r&#xE9;gl&#xE9; sur chaque page
SOURCE	SOURCE
IMAGE	IMAGE
WORK FOLDER	DOSSIER DE TRAVAIL
ACTIVITY	ACTIVIT&#xC9;
Ready	Pr&#xEA;t
Logs folder	Dossier des journaux
Clear	Effacer
Choose Windows 10 or Windows 11 and pick its ISO. It is copied into the work folder and its build and editions are detected - the version follows the ISO you unpack.	Choisissez Windows 10 ou Windows 11 et s&#xE9;lectionnez son ISO. Elle est copi&#xE9;e dans le dossier de travail et sa build et ses &#xE9;ditions sont d&#xE9;tect&#xE9;es - la version suit l'ISO que vous extrayez.
Windows version	Version de Windows
ISO file	Fichier ISO
Use an original ISO from Microsoft. Before it is unpacked, its SHA-256 is compared with the ones Microsoft publishes for its Windows 10 and 11 ISOs - the list in this program and, when online, the download pages on microsoft.com. When it is not there (an ISO made with the Media Creation Tool never is), the Microsoft signatures of its setup and boot files are checked.	Utilisez une ISO originale de Microsoft. Avant son extraction, son SHA-256 est compar&#xE9; &#xE0; ceux que Microsoft publie pour ses ISO de Windows 10 et 11 - la liste de ce programme et, en ligne, les pages de t&#xE9;l&#xE9;chargement de microsoft.com. S'il n'y figure pas (une ISO cr&#xE9;&#xE9;e avec l'outil de cr&#xE9;ation de m&#xE9;dia n'y figure jamais), les signatures Microsoft de ses fichiers d'installation et de d&#xE9;marrage sont v&#xE9;rifi&#xE9;es.
Browse...	Parcourir...
Unpack and analyze	Extraire et analyser
Check the ISO	V&#xE9;rifier l'ISO
Re-read image info	Relire l'image
Download Windows 10 from Microsoft	T&#xE9;l&#xE9;charger Windows 10 chez Microsoft
SHA-256 of the ISO - select it to copy	SHA-256 de l'ISO - s&#xE9;lectionnez-le pour le copier
Detected image	Image d&#xE9;tect&#xE9;e
Nothing unpacked yet.	Rien n'a encore &#xE9;t&#xE9; extrait.
Tick the editions to update. With the option below on, unticked editions are left out of the new ISO (smaller and faster).	Cochez les &#xE9;ditions &#xE0; mettre &#xE0; jour. Avec l'option ci-dessous activ&#xE9;e, les &#xE9;ditions non coch&#xE9;es sont exclues de la nouvelle ISO (plus petite et plus rapide).
Tick all	Tout cocher
Tick none	Tout d&#xE9;cocher
Use	Utiliser
Keep only the ticked editions in the new ISO	Ne garder que les &#xE9;ditions coch&#xE9;es dans la nouvelle ISO
Finds the newest cumulative update, servicing stack, Safe OS and Setup Dynamic Updates and .NET updates for this build in the Microsoft Update Catalog and downloads them (SHA-1 checked).	Cherche dans le Catalogue Microsoft Update la mise &#xE0; jour cumulative la plus r&#xE9;cente, la pile de maintenance, les mises &#xE0; jour dynamiques Safe OS et d'installation et les mises &#xE0; jour .NET pour cette build, et les t&#xE9;l&#xE9;charge (v&#xE9;rifi&#xE9;es par SHA-1).
What to integrate	Quoi int&#xE9;grer
Add .NET Framework 4.8.1 (Windows 10 2004-22H2 - Windows 11 has it built in)	Ajouter .NET Framework 4.8.1 (Windows 10 2004-22H2 - Windows 11 l'inclut d&#xE9;j&#xE0;)
Enable .NET Framework 3.5 (from the ISO's sources\sxs)	Activer .NET Framework 3.5 (depuis sources\sxs de l'ISO)
Component cleanup /ResetBase (smaller image - updates can't be uninstalled)	Nettoyage des composants /ResetBase (image plus petite - les mises &#xE0; jour ne peuvent plus &#xEA;tre d&#xE9;sinstall&#xE9;es)
Newest month to integrate	Mois le plus r&#xE9;cent &#xE0; int&#xE9;grer
YYYY-MM, for Windows 10 2004-22H2 / LTSC 2021	AAAA-MM, pour Windows 10 2004-22H2 / LTSC 2021
2025-10 is the last Windows 10 update Microsoft allows offline. ESU updates (Nov 2025+) come from Windows Update after setup on enrolled PCs.	2025-10 est la derni&#xE8;re mise &#xE0; jour de Windows 10 que Microsoft permet d'int&#xE9;grer hors ligne. Les mises &#xE0; jour ESU (nov. 2025+) arrivent par Windows Update apr&#xE8;s l'installation, sur les PC inscrits.
Find and download updates	Rechercher et t&#xE9;l&#xE9;charger les mises &#xE0; jour
Downloaded	T&#xE9;l&#xE9;charg&#xE9;es
Signed drivers are slipstreamed into install.wim with DISM, so Windows installs them on first boot. Storage and network drivers also go into boot.wim and WinRE, so Setup sees RAID / VMD disks. Modded drivers (edited INF) belong on the next page.	Les pilotes sign&#xE9;s sont int&#xE9;gr&#xE9;s dans install.wim avec DISM, pour que Windows les installe au premier d&#xE9;marrage. Les pilotes de stockage et r&#xE9;seau vont aussi dans boot.wim et WinRE, pour que l'installation voie les disques RAID / VMD. Les pilotes modifi&#xE9;s (INF &#xE9;dit&#xE9;) vont sur la page suivante.
Add drivers from this PC	Ajouter les pilotes de ce PC
Import a drivers folder	Importer un dossier de pilotes
Remove selected	Retirer la s&#xE9;lection
Clear all	Tout retirer
Also put storage and network drivers into boot.wim and WinRE	Mettre aussi les pilotes de stockage et r&#xE9;seau dans boot.wim et WinRE
Allow unsigned drivers in DISM (/ForceUnsigned)	Autoriser les pilotes non sign&#xE9;s dans DISM (/ForceUnsigned)
Signed NVIDIA / modded drivers	Pilotes NVIDIA sign&#xE9;s / modifi&#xE9;s
For driver packages whose INF was edited - NVCleanstall hardware-ID mods for an unsupported GPU, custom INF files. The edit breaks the catalog signature, so Windows refuses them. Every subfolder is scanned; each modified package gets a new catalog (MakeCat by default, or the engine you pick below) signed with your own certificate. The package is added to the ISO through $OEM$ and installed by SetupComplete.cmd at the end of Windows setup, right after the certificate is trusted.	Pour les paquets de pilotes dont l'INF a &#xE9;t&#xE9; modifi&#xE9; - mods d'ID mat&#xE9;riel de NVCleanstall pour un GPU non pris en charge, fichiers INF personnalis&#xE9;s. La modification casse la signature du catalogue et Windows les refuse. Tous les sous-dossiers sont analys&#xE9;s ; chaque paquet modifi&#xE9; re&#xE7;oit un nouveau catalogue (MakeCat par d&#xE9;faut, ou le moteur choisi ci-dessous) sign&#xE9; avec votre propre certificat. Le paquet est ajout&#xE9; &#xE0; l'ISO via $OEM$ et install&#xE9; par SetupComplete.cmd &#xE0; la fin de l'installation de Windows, juste apr&#xE8;s que le certificat a &#xE9;t&#xE9; approuv&#xE9;.
Driver package	Paquet de pilotes
Folder	Dossier
Name	Nom
installs from C:\Drivers\NVIDIA during setup	s'installe depuis C:\Drivers\NVIDIA pendant l'installation
Engine	Moteur
Signing engine: MakeCat	Moteur de signature : MakeCat
Signing engine: libwdi-style	Moteur de signature : libwdi-style
Signing engine: generate-cat-file in WSL	Moteur de signature : generate-cat-file dans WSL
Signing engine: Inf2Cat	Moteur de signature : Inf2Cat
Re-sign every package, not only the modified ones	Signer &#xE0; nouveau tous les paquets, pas seulement les modifi&#xE9;s
Delete the driver copy from C:\Drivers once it is installed	Supprimer la copie des pilotes de C:\Drivers une fois install&#xE9;e
Faster: new catalogs only for the INF files that need one	Plus rapide : nouveaux catalogues seulement pour les fichiers INF qui en ont besoin
Every INF stays in the package, and the ones you did not edit keep their NVIDIA / Microsoft signature. MakeCat and the other folder engines point only the edited INF files at the folder's new catalog (off: every INF of the folder). Inf2Cat gets a copy of the folder with only the edited INF files (the driver files are hard links - no extra space), several at the same time; an edited INF whose catalog is shared with the others (nv_dispi.cat) gets a catalog file of its own. If Inf2Cat fails on that copy, the whole folder is catalogued as before.	Chaque INF reste dans le paquet, et ceux que vous n'avez pas modifi&#xE9;s gardent leur signature NVIDIA / Microsoft. MakeCat et les autres moteurs par dossier ne pointent que les INF modifi&#xE9;s vers le nouveau catalogue du dossier (d&#xE9;sactiv&#xE9; : tous les INF du dossier). Inf2Cat re&#xE7;oit une copie du dossier avec seulement les INF modifi&#xE9;s (les fichiers des pilotes sont des liens physiques - pas d'espace en plus), plusieurs &#xE0; la fois ; un INF modifi&#xE9; dont le catalogue est partag&#xE9; avec les autres (nv_dispi.cat) re&#xE7;oit son propre fichier catalogue. Si Inf2Cat &#xE9;choue sur cette copie, tout le dossier est catalogu&#xE9; comme avant.
Faster: only keep the INF files for this PC's hardware (when the ISO is for this PC)	Plus rapide : ne garder que les fichiers INF du mat&#xE9;riel de ce PC (quand l'ISO est pour ce PC)
Mostly for Inf2Cat: NVIDIA's Display.Driver has one INF file per laptop and desktop maker, and Inf2Cat checks every one of them against the whole package - that can take up to an hour. With this on, only the INF files that list a device of this PC are signed (minutes instead), the others are removed from the copy. The original folder is not touched.	Surtout pour Inf2Cat : le Display.Driver de NVIDIA a un fichier INF par fabricant de portables et de PC de bureau, et Inf2Cat v&#xE9;rifie chacun contre tout le paquet - cela peut prendre jusqu'&#xE0; une heure. Avec cette option, seuls les INF qui citent un p&#xE9;riph&#xE9;rique de ce PC sont sign&#xE9;s (quelques minutes &#xE0; la place), les autres sont retir&#xE9;s de la copie. Le dossier d'origine n'est pas modifi&#xE9;.
Catalog runs at the same time	Catalogages simultan&#xE9;s
1-8, empty = processor cores up to 8. Each Inf2Cat run uses one core; MakeCat does up to 4 folders at once.	1-8, vide = c&#x153;urs du processeur jusqu'&#xE0; 8. Chaque ex&#xE9;cution d'Inf2Cat utilise un c&#x153;ur ; MakeCat traite jusqu'&#xE0; 4 dossiers &#xE0; la fois.
Sign and add to the ISO	Signer et ajouter &#xE0; l'ISO
Open signing folder	Ouvrir le dossier de signature
Signing certificate	Certificat de signature
DriverSigning.pfx (private key) stays in the signing folder next to this tool - back it up and never share or upload it. Only the public DriverSigning.cer goes into the ISO. Tools (makecat, Inf2Cat, signtool) are downloaded automatically.	DriverSigning.pfx (cl&#xE9; priv&#xE9;e) reste dans le dossier de signature &#xE0; c&#xF4;t&#xE9; de cet outil - sauvegardez-le et ne le partagez ni ne l'envoyez jamais. Seul le DriverSigning.cer public va dans l'ISO. Les outils (makecat, Inf2Cat, signtool) sont t&#xE9;l&#xE9;charg&#xE9;s automatiquement.
Packages added to the ISO	Paquets ajout&#xE9;s &#xE0; l'ISO
Answer file and $OEM$	Fichier de r&#xE9;ponses et $OEM$
Both are optional and copied into the media when the ISO is built.	Les deux sont facultatifs et copi&#xE9;s sur le support quand l'ISO est cr&#xE9;&#xE9;e.
none	aucun
Placed in the ISO root so Setup runs unattended. Create one with the autounattend generator.	Plac&#xE9; &#xE0; la racine de l'ISO pour une installation sans assistance. Cr&#xE9;ez-en un avec le g&#xE9;n&#xE9;rateur autounattend.
Choose autounattend.xml	Choisir autounattend.xml
Open the generator	Ouvrir le g&#xE9;n&#xE9;rateur
Remove	Retirer
$OEM$ folder	Dossier $OEM$
Copied to sources\$OEM$: $OEM$\$1 lands in C:\ and $OEM$\$$ in C:\Windows (e.g. $$\Setup\Scripts\SetupComplete.cmd). Packages from the signed-drivers page are merged in, and your SetupComplete.cmd gets a call to SetupComplete-drivers.cmd as its first command.	Copi&#xE9; dans sources\$OEM$ : $OEM$\$1 arrive dans C:\ et $OEM$\$$ dans C:\Windows (p. ex. $$\Setup\Scripts\SetupComplete.cmd). Les paquets de la page des pilotes sign&#xE9;s y sont ajout&#xE9;s, et votre SetupComplete.cmd re&#xE7;oit un appel &#xE0; SetupComplete-drivers.cmd comme premi&#xE8;re commande.
Choose $OEM$ folder	Choisir le dossier $OEM$
Open	Ouvrir
Slipstream and build	Int&#xE9;grer et cr&#xE9;er
Slipstream applies updates, drivers and options to WinRE, install.wim and boot.wim (30-90 minutes). Build writes the bootable BIOS + UEFI ISO with your answer file, $OEM$ and signed drivers.	L'int&#xE9;gration applique les mises &#xE0; jour, pilotes et options &#xE0; WinRE, install.wim et boot.wim (30-90 minutes). La cr&#xE9;ation &#xE9;crit l'ISO amor&#xE7;able BIOS + UEFI avec votre fichier de r&#xE9;ponses, $OEM$ et les pilotes sign&#xE9;s.
Boot options	Options de d&#xE9;marrage
UEFI boot without 'Press any key to boot from CD or DVD'	D&#xE9;marrage UEFI sans 'Appuyez sur une touche pour d&#xE9;marrer &#xE0; partir du CD ou du DVD'
Boot manager signed by Windows UEFI CA 2023 (needs firmware that trusts it)	Gestionnaire de d&#xE9;marrage sign&#xE9; par Windows UEFI CA 2023 (n&#xE9;cessite un firmware qui lui fait confiance)
Split install.wim into 3.8 GB parts (FAT32 USB sticks)	Diviser install.wim en parties de 3,8 Go (cl&#xE9;s USB FAT32)
Speed	Vitesse
Update boot.wim and WinRE at the same time as install.wim (faster, uses more CPU and disk)	Mettre &#xE0; jour boot.wim et WinRE en m&#xEA;me temps qu'install.wim (plus rapide, utilise plus de processeur et de disque)
Editions at the same time	&#xC9;ditions simultan&#xE9;es
Editions updated at the same time	&#xC9;ditions mises &#xE0; jour simultan&#xE9;ment
1-4, empty = automatic (2 on 4+ processor cores, 3 on 8+). Each one needs about 25 GB free on the work drive; fewer run at once when there is less. 1 = one after the other.	1-4, vide = automatique (2 avec 4+ c&#x153;urs, 3 avec 8+). Chacune a besoin d'environ 25 Go libres sur le lecteur de travail ; avec moins d'espace, moins tournent &#xE0; la fois. 1 = l'une apr&#xE8;s l'autre.
Let Windows Defender skip the work folder while a job runs (removed again afterwards)	Laisser Windows Defender ignorer le dossier de travail pendant une t&#xE2;che (retir&#xE9; ensuite)
Leave boot.wim index 1 (Windows PE for WDS servers) as it is - USB / DVD setup uses index 2	Laisser l'index 1 de boot.wim (Windows PE pour serveurs WDS) tel quel - l'installation par USB / DVD utilise l'index 2
DISM applies each update with one process, so servicing one image cannot use more cores - updating boot.wim, WinRE and several editions side by side can. Defender scanning every file DISM writes is often the biggest slowdown. Storage / network drivers go into WinRE and boot.wim with one DISM call. The log ends with the time of every step.	DISM applique chaque mise &#xE0; jour avec un seul processus, donc la maintenance d'une image ne peut pas utiliser plus de c&#x153;urs - mettre &#xE0; jour boot.wim, WinRE et plusieurs &#xE9;ditions en parall&#xE8;le, si. L'analyse par Defender de chaque fichier &#xE9;crit par DISM est souvent le plus gros ralentissement. Les pilotes de stockage / r&#xE9;seau vont dans WinRE et boot.wim en un seul appel DISM. Le journal se termine par la dur&#xE9;e de chaque &#xE9;tape.
Output ISO	ISO de sortie
Save as...	Enregistrer sous...
Empty = work folder\output\Win10_ or Win11_version_build_arch_date.iso	Vide = dossier de travail\output\Win10_ ou Win11_version_build_architecture_date.iso
1 - Slipstream into the image	1 - Int&#xE9;grer dans l'image
2 - Build the ISO	2 - Cr&#xE9;er l'ISO
Open output folder	Ouvrir le dossier de sortie
Result	R&#xE9;sultat
No ISO built yet.	Aucune ISO cr&#xE9;&#xE9;e pour l'instant.
Work folder	Dossier de travail
Apply	Appliquer
Short NTFS path without spaces with about 30 GB free (e.g. D:\W10U). A new folder starts empty.	Chemin NTFS court, sans espaces, avec environ 30 Go libres (p. ex. D:\W10U). Un nouveau dossier d&#xE9;marre vide.
Clean up	Nettoyage
Leftover mounted images and temporary files are always removed. Also delete:	Les images mont&#xE9;es restantes et les fichiers temporaires sont toujours supprim&#xE9;s. Supprimer aussi :
Downloaded updates	Mises &#xE0; jour t&#xE9;l&#xE9;charg&#xE9;es
Unpacked media	Support extrait
Built ISOs	ISO cr&#xE9;&#xE9;es
Re-signed driver copies	Copies des pilotes sign&#xE9;s &#xE0; nouveau
Copied drivers (this PC / imported folder)	Pilotes copi&#xE9;s (ce PC / dossier import&#xE9;)
Answer file copy and install check results (the answer file must be chosen again)	Copie du fichier de r&#xE9;ponses et r&#xE9;sultats de la v&#xE9;rification (il faudra choisir &#xE0; nouveau le fichier de r&#xE9;ponses)
Logs	Journaux
Everything - empty the work folder and start from scratch	Tout - vider le dossier de travail et repartir de z&#xE9;ro
Clean up now	Nettoyer maintenant
Defaults	Valeurs par d&#xE9;faut
Restore default options	Restaurer les options par d&#xE9;faut
Open work folder	Ouvrir le dossier de travail
Everything missing is downloaded automatically when a step needs it, into the tools folder next to this file. oscdimg.exe comes from the Microsoft symbol server (SHA-256 checked) or the Windows ADK; makecat, Inf2Cat and signtool are extracted from Microsoft's NuGet packages (Windows SDK build tools / Windows Driver Kit) - only those tools are kept, nothing is installed.	Tout ce qui manque est t&#xE9;l&#xE9;charg&#xE9; automatiquement quand une &#xE9;tape en a besoin, dans le dossier tools &#xE0; c&#xF4;t&#xE9; de ce fichier. oscdimg.exe vient du serveur de symboles de Microsoft (v&#xE9;rifi&#xE9; par SHA-256) ou du Windows ADK ; makecat, Inf2Cat et signtool sont extraits des paquets NuGet de Microsoft (Windows SDK build tools / Windows Driver Kit) - seuls ces outils sont gard&#xE9;s, rien n'est install&#xE9;.
Download missing tools now	T&#xE9;l&#xE9;charger maintenant les outils manquants
Open tools folder	Ouvrir le dossier des outils
Checks your autounattend.xml, $OEM$ folder and drivers against the ISO you are building and points out what would break or stall a clean install: wrong edition index or language, invalid computer / account names or time zone, duplicate command numbers, scripts that wait for a key, missing files, drivers that nothing installs or that Windows will refuse, and SetupComplete.cmd being skipped on PCs with an OEM key. Fixes change only the copies that go into the ISO - your own files stay as they are. The check also runs before every ISO build.	V&#xE9;rifie votre autounattend.xml, le dossier $OEM$ et les pilotes par rapport &#xE0; l'ISO que vous cr&#xE9;ez et signale ce qui ferait &#xE9;chouer ou bloquerait une installation propre : index d'&#xE9;dition ou langue erron&#xE9;s, noms d'ordinateur / de compte ou fuseau horaire non valides, num&#xE9;ros de commande en double, scripts qui attendent une touche, fichiers manquants, pilotes que rien n'installe ou que Windows refusera, et SetupComplete.cmd ignor&#xE9; sur les PC avec une cl&#xE9; OEM. Les corrections ne modifient que les copies qui vont dans l'ISO - vos propres fichiers restent tels quels. La v&#xE9;rification est aussi lanc&#xE9;e avant chaque cr&#xE9;ation d'ISO.
Run the check	Lancer la v&#xE9;rification
Apply all fixes	Appliquer toutes les corrections
Save fixed answer file as...	Enregistrer le fichier de r&#xE9;ponses corrig&#xE9; sous...
Undo answer file fixes	Annuler les corrections du fichier de r&#xE9;ponses
Not run yet.	Pas encore lanc&#xE9;e.
Level	Niveau
Area	Domaine
Finding	Constat
Fix	Correction
Also install the driver folders in my $OEM$\$1 with pnputil (from SetupComplete-drivers.cmd)	Installer aussi les dossiers de pilotes de mon $OEM$\$1 avec pnputil (depuis SetupComplete-drivers.cmd)
Filter	Filtrer
Class, provider, INF or folder name	Classe, fournisseur, INF ou nom de dossier
All that fit	Tous ceux qui conviennent
Tick shown	Cocher ceux affich&#xE9;s
None	Aucun
Add ticked drivers	Ajouter les pilotes coch&#xE9;s
Cancel	Annuler
Driver signing certificate	Certificat de signature des pilotes
Password	Mot de passe
Repeat the password	R&#xE9;p&#xE9;ter le mot de passe
Not there yet: {0}	Pas encore l&#xE0; : {0}
Dark theme	Th&#xE8;me sombre
Switch to the dark theme	Passer au th&#xE8;me sombre
Another job is still running.	Une autre t&#xE2;che est encore en cours.
{0} finished in {1:mm\:ss}	{0} termin&#xE9; en {1:mm\:ss}
{0} stopped with an error - see the log	{0} s'est arr&#xEA;t&#xE9; avec une erreur - voir le journal
Unpack	Extraire
Analyze	Analyser
Download updates	T&#xE9;l&#xE9;charger les mises &#xE0; jour
Driver scan	Recherche de pilotes
Copy drivers	Copier les pilotes
Folder scan	Analyse du dossier
Import drivers	Importer les pilotes
Re-sign drivers	Signer &#xE0; nouveau les pilotes
Slipstream	Int&#xE9;gration
Build ISO	Cr&#xE9;er l'ISO
Apply fixes	Appliquer les corrections
ISO check	V&#xE9;rification de l'ISO
no ISO yet	pas encore d'ISO
{0}  |  {1}  |  {2}  |  {3} edition(s)	{0}  |  {1}  |  {2}  |  {3} &#xE9;dition(s)
{0} free	{0} libres
unpacked	extraite
{0} of {1} ticked	{0} sur {1} coch&#xE9;es
tick at least one	cochez-en au moins une
not available for this build	non disponible pour cette build
{0} ({1}) + {2} more	{0} ({1}) + {2} autres
{0} packages ({1} for boot)	{0} paquets ({1} pour le d&#xE9;marrage)
none (optional)	aucun (facultatif)
{0} error(s), {1} warning(s)	{0} erreur(s), {1} avertissement(s)
{0} warning(s)	{0} avertissement(s)
all good	tout est bon
ISO ready	ISO pr&#xEA;te
slipstreamed ({0}) - build the ISO	int&#xE9;gr&#xE9;e ({0}) - cr&#xE9;ez l'ISO
Updates for Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 and 25H2 (x64, ARM64). On a Windows 10 PC the slipstream uses the DISM of the Windows ADK Deployment Tools, installed from Microsoft when needed.	Mises &#xE0; jour pour Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 et 25H2 (x64, ARM64). Sur un PC sous Windows 10, l'int&#xE9;gration utilise le DISM des outils de d&#xE9;ploiement du Windows ADK, install&#xE9;s depuis Microsoft si besoin.
Updates for Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 and LTSC 2021 (x64, x86, ARM64).	Mises &#xE0; jour pour Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 et LTSC 2021 (x64, x86, ARM64).
The unpacked ISO is Windows {0} - pick a Windows {1} ISO and unpack it to switch.	L'ISO extraite est Windows {0} - choisissez une ISO de Windows {1} et extrayez-la pour changer.
Download Windows {0} from Microsoft	T&#xE9;l&#xE9;charger Windows {0} chez Microsoft
Windows 11: the newest updates in the Microsoft Update Catalog are used (21H2, which is out of servicing: its last ones, 2024-10).	Windows 11 : les mises &#xE0; jour les plus r&#xE9;centes du Catalogue Microsoft Update sont utilis&#xE9;es (21H2, qui n'est plus pris en charge : ses derni&#xE8;res, 2024-10).
microsoft.com could not be reached, so only the list in this program was used - check again when online, the newest ISOs may be on the page.	microsoft.com est inaccessible, seule la liste de ce programme a donc &#xE9;t&#xE9; utilis&#xE9;e - v&#xE9;rifiez &#xE0; nouveau en ligne, les ISO les plus r&#xE9;centes peuvent figurer sur la page.
Its name is the one of a Visual Studio subscription or Volume Licensing download, which are original too but not on the public pages: compare the SHA-256 with the one shown on that portal.	Son nom est celui d'un t&#xE9;l&#xE9;chargement d'abonnement Visual Studio ou de licences en volume, qui sont aussi originales mais absentes des pages publiques : comparez le SHA-256 avec celui indiqu&#xE9; sur ce portail.
An ISO made with the Media Creation Tool is built on the PC and is never listed, and an older ISO Microsoft no longer offers may be missing too. Otherwise it may have been modified: download an original Windows {0} ISO from Microsoft (button above) and use that one.	Une ISO cr&#xE9;&#xE9;e avec l'outil de cr&#xE9;ation de m&#xE9;dia est g&#xE9;n&#xE9;r&#xE9;e sur le PC et n'est jamais dans la liste, et une ISO plus ancienne que Microsoft ne propose plus peut aussi manquer. Sinon, elle a peut-&#xEA;tre &#xE9;t&#xE9; modifi&#xE9;e : t&#xE9;l&#xE9;chargez une ISO originale de Windows {0} chez Microsoft (bouton ci-dessus) et utilisez-la.
Its SHA-256 is one Microsoft published on its download page (seen there on {0}).	Son SHA-256 fait partie de ceux que Microsoft a publi&#xE9;s sur sa page de t&#xE9;l&#xE9;chargement (vu le {0}).
Its SHA-256 is on Microsoft's download page (checked {0}).	Son SHA-256 figure sur la page de t&#xE9;l&#xE9;chargement de Microsoft (v&#xE9;rifi&#xE9; le {0}).
Original Microsoft ISO: {0} - {1}	ISO originale de Microsoft : {0} - {1}
Made with the Media Creation Tool - setup and boot files signed by Microsoft	Cr&#xE9;&#xE9;e avec l'outil de cr&#xE9;ation de m&#xE9;dia - fichiers d'installation et de d&#xE9;marrage sign&#xE9;s par Microsoft
The Media Creation Tool builds the ISO on the PC from Microsoft's download, so its SHA-256 is never in Microsoft's list - that is normal. Its setup and boot files ({0} checked) carry Microsoft's signature; the Windows image in it (install.esd) isn't signed as a whole, so it isn't covered.	L'outil de cr&#xE9;ation de m&#xE9;dia cr&#xE9;e l'ISO sur le PC &#xE0; partir du t&#xE9;l&#xE9;chargement de Microsoft, son SHA-256 n'est donc jamais dans la liste de Microsoft - c'est normal. Ses fichiers d'installation et de d&#xE9;marrage ({0} v&#xE9;rifi&#xE9;s) portent la signature de Microsoft ; l'image Windows (install.esd) n'est pas sign&#xE9;e dans son ensemble, elle n'est donc pas couverte.
Modified: files in this ISO are not signed by Microsoft	Modifi&#xE9;e : des fichiers de cette ISO ne sont pas sign&#xE9;s par Microsoft
Not signed by Microsoft: {0}. Download an original Windows {1} ISO from Microsoft (button above) and use that one.	Sans signature Microsoft : {0}. T&#xE9;l&#xE9;chargez une ISO originale de Windows {1} chez Microsoft (bouton ci-dessus) et utilisez-la.
Its setup and boot files are signed by Microsoft ({0} checked), but the Windows image in it can't be checked this way.	Ses fichiers d'installation et de d&#xE9;marrage sont sign&#xE9;s par Microsoft ({0} v&#xE9;rifi&#xE9;s), mais l'image Windows ne peut pas &#xEA;tre v&#xE9;rifi&#xE9;e de cette fa&#xE7;on.
Not verified: the SHA-256 is not one Microsoft lists for its Windows 10 and 11 ISOs.	Non v&#xE9;rifi&#xE9;e : le SHA-256 ne fait partie d'aucun de ceux que Microsoft indique pour ses ISO de Windows 10 et 11.
Not checked yet - the ISO is checked when you unpack it, or now with Check the ISO.	Pas encore v&#xE9;rifi&#xE9;e - l'ISO est v&#xE9;rifi&#xE9;e &#xE0; son extraction, ou maintenant avec V&#xE9;rifier l'ISO.
{0}  -  build {1}  -  {2}  -  {3} edition(s)	{0}  -  build {1}  -  {2}  -  {3} &#xE9;dition(s)
No automatic updates for this build - drivers, signed packages, answer file and $OEM$ still work.	Pas de mises &#xE0; jour automatiques pour cette build - les pilotes, les paquets sign&#xE9;s, le fichier de r&#xE9;ponses et $OEM$ fonctionnent quand m&#xEA;me.
Updates up to {0} (the last month Microsoft allows offline for Windows 10).	Mises &#xE0; jour jusqu'&#xE0; {0} (le dernier mois que Microsoft permet d'int&#xE9;grer hors ligne pour Windows 10).
Its last updates ({0}) - this version is out of servicing.	Ses derni&#xE8;res mises &#xE0; jour ({0}) - cette version n'est plus prise en charge.
Newest updates available in the Microsoft Update Catalog.	Mises &#xE0; jour les plus r&#xE9;centes du Catalogue Microsoft Update.
The {0} enablement package is added too.	Le paquet d'activation {0} est aussi ajout&#xE9;.
{0} driver package(s), {1} storage/network for boot.wim and WinRE, about {2:N0} MB	{0} paquet(s) de pilotes, {1} de stockage/r&#xE9;seau pour boot.wim et WinRE, environ {2:N0} Mo
No drivers selected.	Aucun pilote s&#xE9;lectionn&#xE9;.
this PC only ({0} kept)	ce PC seulement ({0} gard&#xE9;s)
all	tous
Ready - {0}, valid until {1:yyyy-MM-dd} (backed up as DriverSigning.pfx)	Pr&#xEA;t - {0}, valide jusqu'au {1:yyyy-MM-dd} (sauvegard&#xE9; dans DriverSigning.pfx)
In this PC's certificate store, not backed up yet - you will be asked for a password to save DriverSigning.pfx.	Dans le magasin de certificats de ce PC, pas encore sauvegard&#xE9; - un mot de passe vous sera demand&#xE9; pour enregistrer DriverSigning.pfx.
DriverSigning.pfx found - its password is asked when you sign.	DriverSigning.pfx trouv&#xE9; - son mot de passe est demand&#xE9; quand vous signez.
None yet - one is created the first time you sign (you choose its password).	Aucun pour l'instant - il est cr&#xE9;&#xE9; la premi&#xE8;re fois que vous signez (vous choisissez son mot de passe).
{0}   (added {1})	{0}   (ajout&#xE9; le {1})
Slipstreamed on {0} - build {1}. Build the ISO next.	Int&#xE9;gr&#xE9;e le {0} - build {1}. Cr&#xE9;ez ensuite l'ISO.
{0} error(s), {1} warning(s), {2} check(s) passed   -   {3}	{0} erreur(s), {1} avertissement(s), {2} v&#xE9;rification(s) r&#xE9;ussie(s)   -   {3}
Apply {0} fix(es)	Appliquer {0} correction(s)
The ISO uses a fixed copy of your answer file (fixed {0}). Save it to update your own file too.	L'ISO utilise une copie corrig&#xE9;e de votre fichier de r&#xE9;ponses (corrig&#xE9;e le {0}). Enregistrez-la pour mettre aussi &#xE0; jour votre propre fichier.
folder not found	dossier introuvable
{0} files, {1}   ({2})	{0} fichiers, {1}   ({2})
has SetupComplete.cmd	contient SetupComplete.cmd
missing - downloaded automatically when you build the ISO	manquant - t&#xE9;l&#xE9;charg&#xE9; automatiquement quand vous cr&#xE9;ez l'ISO
missing - downloaded automatically when you sign drivers	manquant - t&#xE9;l&#xE9;charg&#xE9; automatiquement quand vous signez des pilotes
missing - downloaded only if the signing engine needs Inf2Cat as fallback	manquant - t&#xE9;l&#xE9;charg&#xE9; seulement si le moteur de signature a besoin d'Inf2Cat en secours
missing - only needed for the MakeCat signing engine	manquant - n&#xE9;cessaire seulement pour le moteur de signature MakeCat
missing - PowerShell / BITS downloads are used	manquant - les t&#xE9;l&#xE9;chargements PowerShell / BITS sont utilis&#xE9;s
Default. makecat.exe (Windows SDK) builds one catalog per driver folder with the hash of every file in it, so each file is hashed once - about 20 s for NVIDIA's 3 GB Display.Driver instead of minutes. Compressed files (name.dl_) are hashed expanded, the way Windows checks them. MakeCat does not parse the INF: every catalog is checked with signtool afterwards, and a folder MakeCat cannot do goes to Inf2Cat.	Par d&#xE9;faut. makecat.exe (Windows SDK) cr&#xE9;e un catalogue par dossier de pilotes avec le hachage de chaque fichier qu'il contient, donc chaque fichier n'est hach&#xE9; qu'une fois - environ 20 s pour les 3 Go du Display.Driver de NVIDIA au lieu de plusieurs minutes. Les fichiers compress&#xE9;s (nom.dl_) sont hach&#xE9;s d&#xE9;compress&#xE9;s, comme Windows les v&#xE9;rifie. MakeCat n'analyse pas l'INF : chaque catalogue est v&#xE9;rifi&#xE9; ensuite avec signtool, et un dossier que MakeCat ne peut pas traiter passe &#xE0; Inf2Cat.
Experimental. The catalog is built with the CryptCAT API of Windows itself, the way libwdi (Zadig) does it - nothing to download. One catalog per driver folder with the hash of every file in it (SHA-1). Checked with signtool afterwards; a folder it cannot do goes to Inf2Cat.	Exp&#xE9;rimental. Le catalogue est cr&#xE9;&#xE9; avec l'API CryptCAT de Windows lui-m&#xEA;me, comme le fait libwdi (Zadig) - rien &#xE0; t&#xE9;l&#xE9;charger. Un catalogue par dossier de pilotes avec le hachage de chaque fichier qu'il contient (SHA-1). V&#xE9;rifi&#xE9; ensuite avec signtool ; un dossier qu'il ne peut pas traiter passe &#xE0; Inf2Cat.
Experimental. LINBIT generate-cat-file (GPL-2.0): its source is downloaded from GitHub (one pinned commit, SHA-256 checked) and built inside WSL - needs WSL with a Linux distribution that has gcc and make. One catalog per driver folder; Inf2Cat signs when WSL or the build is missing.	Exp&#xE9;rimental. LINBIT generate-cat-file (GPL-2.0) : son code source est t&#xE9;l&#xE9;charg&#xE9; depuis GitHub (un commit fix&#xE9;, v&#xE9;rifi&#xE9; par SHA-256) et compil&#xE9; dans WSL - n&#xE9;cessite WSL avec une distribution Linux qui a gcc et make. Un catalogue par dossier de pilotes ; Inf2Cat signe quand WSL ou la compilation manque.
Microsoft's standard tool from the Windows Driver Kit: it parses every INF and checks it against every file of the package. The proven choice, but slow on big packages - the options below make it faster.	L'outil standard de Microsoft, du Windows Driver Kit : il analyse chaque INF et le v&#xE9;rifie contre tous les fichiers du paquet. Le choix &#xE9;prouv&#xE9;, mais lent sur les gros paquets - les options ci-dessous l'acc&#xE9;l&#xE8;rent.
installs from {0} during Windows setup	s'installe depuis {0} pendant l'installation de Windows
{0} older version(s) of drivers that are here in a newer version too are unticked (column Older) - Windows uses the newest one.	{0} ancienne(s) version(s) de pilotes qui sont aussi ici dans une version plus r&#xE9;cente sont d&#xE9;coch&#xE9;es (colonne Ancienne) - Windows utilise la plus r&#xE9;cente.
DriverSigning.pfx was found next to this tool. Enter its password to load your signing certificate.	DriverSigning.pfx a &#xE9;t&#xE9; trouv&#xE9; &#xE0; c&#xF4;t&#xE9; de cet outil. Entrez son mot de passe pour charger votre certificat de signature.
Your signing certificate is in this PC's store but has no backup yet. Choose a password to save it as DriverSigning.pfx - you need it to sign again after reinstalling Windows.	Votre certificat de signature est dans le magasin de ce PC mais n'a pas encore de sauvegarde. Choisissez un mot de passe pour l'enregistrer sous DriverSigning.pfx - il vous faudra pour signer &#xE0; nouveau apr&#xE8;s avoir r&#xE9;install&#xE9; Windows.
A new self-signed code-signing certificate will be created. Choose a password for its backup file DriverSigning.pfx - you need it to sign again after reinstalling Windows.	Un nouveau certificat de signature de code auto-sign&#xE9; va &#xEA;tre cr&#xE9;&#xE9;. Choisissez un mot de passe pour son fichier de sauvegarde DriverSigning.pfx - il vous faudra pour signer &#xE0; nouveau apr&#xE8;s avoir r&#xE9;install&#xE9; Windows.
Enter a password.	Entrez un mot de passe.
The passwords do not match.	Les mots de passe ne correspondent pas.
Index	Index
Edition	&#xC9;dition
Build	Build
Size	Taille
SizeGB	Taille (Go)
Kind	Type
Date	Date
Title	Titre
No	N&#xB0;
Source	Source
Class	Classe
Provider	Fournisseur
Version	Version
SizeMB	Taille (Mo)
InstallsFrom	S'installe depuis
Signed	Sign&#xE9;s
Failed	&#xC9;chou&#xE9;s
When	Quand
FixText	Correction
Arch	Architecture
Older	Ancienne
Unpack an ISO first (page 1).	Extrayez d'abord une ISO (page 1).
Choose an existing .iso file first.	Choisissez d'abord un fichier .iso existant.
The work folder already has unpacked media ({0}). Replace it with a fresh copy of this ISO?	Le dossier de travail contient d&#xE9;j&#xE0; un support extrait ({0}). Le remplacer par une nouvelle copie de cette ISO ?
Unpack this ISO anyway?	Extraire quand m&#xEA;me cette ISO ?
Drivers installed on this PC	Pilotes install&#xE9;s sur ce PC
Third-party drivers exported from this PC. Ticked ones are slipstreamed into the ISO.	Pilotes tiers export&#xE9;s de ce PC. Ceux qui sont coch&#xE9;s sont int&#xE9;gr&#xE9;s &#xE0; l'ISO.
Pick the drivers folder - Drivers-Backup made by Drivers.cmd, a folder from another PC or a vendor pack. All subfolders are scanned.	Choisissez le dossier de pilotes - Drivers-Backup cr&#xE9;&#xE9; par Drivers.cmd, un dossier d'un autre PC ou un pack du fabricant. Tous les sous-dossiers sont analys&#xE9;s.
No .inf drivers in that folder.	Aucun pilote .inf dans ce dossier.
Drivers in {0}	Pilotes dans {0}
Drivers built for another architecture than the ISO are unticked and left out.	Les pilotes con&#xE7;us pour une autre architecture que celle de l'ISO sont d&#xE9;coch&#xE9;s et laiss&#xE9;s de c&#xF4;t&#xE9;.
Choose the driver folder first (for example the folder NVCleanstall extracted).	Choisissez d'abord le dossier des pilotes (par exemple le dossier extrait par NVCleanstall).
There are no .inf files in that folder or its subfolders.	Il n'y a pas de fichiers .inf dans ce dossier ni dans ses sous-dossiers.
Tick at least one edition first.	Cochez d'abord au moins une &#xE9;dition.
This media was already slipstreamed on {0}. For a clean result unpack the ISO again (page 1). Slipstream again anyway?	Ce support a d&#xE9;j&#xE0; &#xE9;t&#xE9; int&#xE9;gr&#xE9; le {0}. Pour un r&#xE9;sultat propre, extrayez &#xE0; nouveau l'ISO (page 1). Int&#xE9;grer &#xE0; nouveau quand m&#xEA;me ?
No updates are downloaded (page 3). Continue with drivers and options only?	Aucune mise &#xE0; jour t&#xE9;l&#xE9;charg&#xE9;e (page 3). Continuer seulement avec les pilotes et les options ?
The media has not been slipstreamed yet. Build the ISO anyway (drivers, updates and options are then missing)?	Le support n'a pas encore &#xE9;t&#xE9; int&#xE9;gr&#xE9;. Cr&#xE9;er l'ISO quand m&#xEA;me (les pilotes, mises &#xE0; jour et options manqueront alors) ?
Nothing to fix automatically - run the check first. Findings without a fix need a change on the page they mention.	Rien &#xE0; corriger automatiquement - lancez d'abord la v&#xE9;rification. Les constats sans correction demandent une modification sur la page qu'ils mentionnent.
Apply these fixes? They change the copies that go into the ISO, not your own files.	Appliquer ces corrections ? Elles modifient les copies qui vont dans l'ISO, pas vos propres fichiers.
Choose the source ISO on page 1 first.	Choisissez d'abord l'ISO source &#xE0; la page 1.
yes	oui
no	non
Source: {0}	Source : {0}
Editions: {0}	&#xC9;ditions : {0}
{0} ticked	{0} coch&#xE9;es
asked after unpacking	demand&#xE9; apr&#xE8;s l'extraction
Drivers: {0}   Signed packages: {1}	Pilotes : {0}   Paquets sign&#xE9;s : {1}
Answer file: {0}   $OEM$: {1}	Fichier de r&#xE9;ponses : {0}   $OEM$ : {1}
Run everything now? It takes 30-90 minutes - the PC is kept awake until it is done.	Tout ex&#xE9;cuter maintenant ? Cela prend 30-90 minutes - le PC reste &#xE9;veill&#xE9; jusqu'&#xE0; la fin.
Run everything with this ISO anyway?	Tout ex&#xE9;cuter quand m&#xEA;me avec cette ISO ?
While a job runs (unpack, download, sign, slipstream, build), Windows Defender does not scan the work folder ({0}). The exclusion is removed when the job ends, and at the next start if the program was closed during a job. Everything in there comes from Microsoft, your drivers and this tool - do not put other downloads in that folder.	Pendant une t&#xE2;che (extraire, t&#xE9;l&#xE9;charger, signer, int&#xE9;grer, cr&#xE9;er), Windows Defender n'analyse pas le dossier de travail ({0}). L'exclusion est retir&#xE9;e &#xE0; la fin de la t&#xE2;che, et au prochain d&#xE9;marrage si le programme a &#xE9;t&#xE9; ferm&#xE9; pendant une t&#xE2;che. Tout ce qu'il contient vient de Microsoft, de vos pilotes et de cet outil - n'y mettez pas d'autres t&#xE9;l&#xE9;chargements.
Use this only when the ISO is for this PC. INF files for other hardware are removed from the signed copy, so the driver installs only on hardware that matches this PC. NVIDIA's own setup.exe may refuse to run from that copy - pnputil installs the driver anyway. Sign the package again for it to take effect.	N'utilisez cette option que si l'ISO est pour ce PC. Les fichiers INF d'autres mat&#xE9;riels sont retir&#xE9;s de la copie sign&#xE9;e, donc le pilote ne s'installe que sur du mat&#xE9;riel identique &#xE0; ce PC. Le setup.exe de NVIDIA peut refuser de s'ex&#xE9;cuter depuis cette copie - pnputil installe le pilote quand m&#xEA;me. Signez &#xE0; nouveau le paquet pour que cela prenne effet.
With Secure Boot on, this ISO only boots on PCs whose UEFI already trusts 'Windows UEFI CA 2023'. Older firmware needs that Secure Boot update first (or Secure Boot off). The image also needs a 2024-04 or newer update.	Avec le D&#xE9;marrage s&#xE9;curis&#xE9; activ&#xE9;, cette ISO ne d&#xE9;marre que sur les PC dont l'UEFI fait d&#xE9;j&#xE0; confiance &#xE0; 'Windows UEFI CA 2023'. Les firmwares plus anciens ont d'abord besoin de cette mise &#xE0; jour du D&#xE9;marrage s&#xE9;curis&#xE9; (ou du D&#xE9;marrage s&#xE9;curis&#xE9; d&#xE9;sactiv&#xE9;). L'image a aussi besoin d'une mise &#xE0; jour de 2024-04 ou plus r&#xE9;cente.
Use the YYYY-MM format, e.g. 2025-10.	Utilisez le format AAAA-MM, p. ex. 2025-10.
Use a number from 1 to 8 (or leave it empty for the number of processor cores, up to 8).	Utilisez un nombre de 1 &#xE0; 8 (ou laissez vide pour le nombre de c&#x153;urs du processeur, jusqu'&#xE0; 8).
Use a number from 1 to 4 (or leave it empty: 2 on 4+ processor cores, 3 on 8+).	Utilisez un nombre de 1 &#xE0; 4 (ou laissez vide : 2 avec 4+ c&#x153;urs, 3 avec 8+).
Select a Windows {0} ISO	S&#xE9;lectionnez une ISO de Windows {0}
ISO images	Images ISO
Select the drivers to remove in the list first (Ctrl+click for several).	S&#xE9;lectionnez d'abord dans la liste les pilotes &#xE0; retirer (Ctrl+clic pour plusieurs).
Remove every selected driver?	Retirer tous les pilotes s&#xE9;lectionn&#xE9;s ?
Pick the modded driver folder (e.g. the folder NVCleanstall extracted). All subfolders are scanned.	Choisissez le dossier des pilotes modifi&#xE9;s (p. ex. le dossier extrait par NVCleanstall). Tous les sous-dossiers sont analys&#xE9;s.
Select a package in the list first.	S&#xE9;lectionnez d'abord un paquet dans la liste.
Select your autounattend.xml	S&#xE9;lectionnez votre autounattend.xml
Answer files	Fichiers de r&#xE9;ponses
Pick your $OEM$ folder (the one that contains $1 and/or $$)	Choisissez votre dossier $OEM$ (celui qui contient $1 et/ou $$)
ISO image	Image ISO
Pick or create the work folder (NTFS, no spaces, ~30 GB free)	Choisissez ou cr&#xE9;ez le dossier de travail (NTFS, sans espaces, ~30 Go libres)
The path has spaces - a short path like D:\W10U is safer for DISM. Use it anyway?	Le chemin contient des espaces - un chemin court comme D:\W10U est plus s&#xFB;r pour DISM. L'utiliser quand m&#xEA;me ?
downloaded updates	mises &#xE0; jour t&#xE9;l&#xE9;charg&#xE9;es
unpacked media	support extrait
built ISOs	ISO cr&#xE9;&#xE9;es
re-signed driver copies	copies des pilotes sign&#xE9;s &#xE0; nouveau
copied drivers	pilotes copi&#xE9;s
answer file copy and check results	copie du fichier de r&#xE9;ponses et r&#xE9;sultats de la v&#xE9;rification
logs	journaux
EVERYTHING in the work folder	TOUT le contenu du dossier de travail
mounted images and temp files	images mont&#xE9;es et fichiers temporaires
Delete: {0}?	Supprimer : {0} ?
Restore the default options? The work folder is kept.	Restaurer les options par d&#xE9;faut ? Le dossier de travail est conserv&#xE9;.
There is no answer file yet (page 6).	Il n'y a pas encore de fichier de r&#xE9;ponses (page 6).
Answer file	Fichier de r&#xE9;ponses
No answer file fixes to undo.	Aucune correction du fichier de r&#xE9;ponses &#xE0; annuler.
Put the answer file back the way it was before the fixes?	Remettre le fichier de r&#xE9;ponses tel qu'il &#xE9;tait avant les corrections ?
'{0}' is still running. Closing now can leave a mounted image behind (run Clean up next time). Close anyway?	'{0}' est encore en cours. Fermer maintenant peut laisser une image mont&#xE9;e (lancez le Nettoyage la prochaine fois). Fermer quand m&#xEA;me ?
'@ }
        'de' { return @'
updates + drivers + signed NVIDIA mods + autounattend + $OEM$  ->  bootable ISO	Updates + Treiber + signierte NVIDIA-Mods + autounattend + $OEM$  ->  bootf&#xE4;hige ISO
Light theme	Helles Design
Switch to the light theme	Zum hellen Design wechseln
Display and accessibility: theme, text size, font	Anzeige und Barrierefreiheit: Design, Textgr&#xF6;&#xDF;e, Schriftart
Display and accessibility settings	Einstellungen f&#xFC;r Anzeige und Barrierefreiheit
Minimize	Minimieren
Maximize	Maximieren
Close	Schlie&#xDF;en
Display and accessibility	Anzeige und Barrierefreiheit
Theme	Design
Dark	Dunkel
Light	Hell
Like Windows	Wie Windows
Text size	Textgr&#xF6;&#xDF;e
Font	Schriftart
Language	Sprache
Ctrl + plus / Ctrl + minus / Ctrl + 0 change the text size anywhere in the window. Verdana and Tahoma have wider, more distinct letters. Saved for the next start.	Strg + Plus / Strg + Minus / Strg + 0 &#xE4;ndern die Textgr&#xF6;&#xDF;e &#xFC;berall im Fenster. Verdana und Tahoma haben breitere, besser unterscheidbare Buchstaben. Wird f&#xFC;r den n&#xE4;chsten Start gespeichert.
The Activity log and the Install check findings stay in English - that is what a bug report or a search needs.	Das Aktivit&#xE4;tsprotokoll und die Ergebnisse der Installationspr&#xFC;fung bleiben auf Englisch - das braucht ein Fehlerbericht oder eine Suche.
STEPS	SCHRITTE
Source ISO	Quell-ISO
to do	offen
Editions	Editionen
Windows updates	Windows-Updates
Drivers	Treiber
optional	optional
Signed NVIDIA / modded	Signierte NVIDIA- / Mod-Treiber
Answer file + $OEM$	Antwortdatei + $OEM$
Install check	Installationspr&#xFC;fung
not run yet	noch nicht ausgef&#xFC;hrt
Slipstream + build ISO	Integrieren + ISO erstellen
MORE	MEHR
Options and clean up	Optionen und Bereinigen
Tools	Werkzeuge
Run everything	Alles ausf&#xFC;hren
unpack - updates - slipstream - ISO, using what you set on each page	entpacken - Updates - integrieren - ISO, mit dem, was Sie auf jeder Seite eingestellt haben
SOURCE	QUELLE
IMAGE	ABBILD
WORK FOLDER	ARBEITSORDNER
ACTIVITY	AKTIVIT&#xC4;T
Ready	Bereit
Logs folder	Protokollordner
Clear	Leeren
Choose Windows 10 or Windows 11 and pick its ISO. It is copied into the work folder and its build and editions are detected - the version follows the ISO you unpack.	W&#xE4;hlen Sie Windows 10 oder Windows 11 und dessen ISO. Sie wird in den Arbeitsordner kopiert, Build und Editionen werden erkannt - die Version richtet sich nach der ISO, die Sie entpacken.
Windows version	Windows-Version
ISO file	ISO-Datei
Use an original ISO from Microsoft. Before it is unpacked, its SHA-256 is compared with the ones Microsoft publishes for its Windows 10 and 11 ISOs - the list in this program and, when online, the download pages on microsoft.com. When it is not there (an ISO made with the Media Creation Tool never is), the Microsoft signatures of its setup and boot files are checked.	Verwenden Sie eine Original-ISO von Microsoft. Vor dem Entpacken wird ihr SHA-256 mit den Werten verglichen, die Microsoft f&#xFC;r seine Windows 10- und 11-ISOs ver&#xF6;ffentlicht - die Liste in diesem Programm und, wenn online, die Downloadseiten auf microsoft.com. Steht er dort nicht (eine mit dem Media Creation Tool erstellte ISO steht nie dort), werden die Microsoft-Signaturen ihrer Setup- und Startdateien gepr&#xFC;ft.
Browse...	Durchsuchen...
Unpack and analyze	Entpacken und analysieren
Check the ISO	ISO pr&#xFC;fen
Re-read image info	Abbild neu einlesen
Download Windows 10 from Microsoft	Windows 10 bei Microsoft herunterladen
SHA-256 of the ISO - select it to copy	SHA-256 der ISO - zum Kopieren markieren
Detected image	Erkanntes Abbild
Nothing unpacked yet.	Noch nichts entpackt.
Tick the editions to update. With the option below on, unticked editions are left out of the new ISO (smaller and faster).	Haken Sie die Editionen an, die aktualisiert werden sollen. Mit der Option unten bleiben nicht angehakte Editionen aus der neuen ISO drau&#xDF;en (kleiner und schneller).
Tick all	Alle anhaken
Tick none	Keine anhaken
Use	Verwenden
Keep only the ticked editions in the new ISO	Nur die angehakten Editionen in der neuen ISO behalten
Finds the newest cumulative update, servicing stack, Safe OS and Setup Dynamic Updates and .NET updates for this build in the Microsoft Update Catalog and downloads them (SHA-1 checked).	Sucht im Microsoft Update-Katalog das neueste kumulative Update, den Servicing Stack, die dynamischen Safe-OS- und Setup-Updates und die .NET-Updates f&#xFC;r diesen Build und l&#xE4;dt sie herunter (per SHA-1 gepr&#xFC;ft).
What to integrate	Was integriert wird
Add .NET Framework 4.8.1 (Windows 10 2004-22H2 - Windows 11 has it built in)	.NET Framework 4.8.1 hinzuf&#xFC;gen (Windows 10 2004-22H2 - Windows 11 hat es bereits)
Enable .NET Framework 3.5 (from the ISO's sources\sxs)	.NET Framework 3.5 aktivieren (aus sources\sxs der ISO)
Component cleanup /ResetBase (smaller image - updates can't be uninstalled)	Komponentenbereinigung /ResetBase (kleineres Abbild - Updates lassen sich nicht mehr deinstallieren)
Newest month to integrate	Neuester zu integrierender Monat
YYYY-MM, for Windows 10 2004-22H2 / LTSC 2021	JJJJ-MM, f&#xFC;r Windows 10 2004-22H2 / LTSC 2021
2025-10 is the last Windows 10 update Microsoft allows offline. ESU updates (Nov 2025+) come from Windows Update after setup on enrolled PCs.	2025-10 ist das letzte Windows 10-Update, das Microsoft offline integrieren l&#xE4;sst. ESU-Updates (ab Nov. 2025) kommen nach der Installation &#xFC;ber Windows Update auf angemeldete PCs.
Find and download updates	Updates suchen und herunterladen
Downloaded	Heruntergeladen
Signed drivers are slipstreamed into install.wim with DISM, so Windows installs them on first boot. Storage and network drivers also go into boot.wim and WinRE, so Setup sees RAID / VMD disks. Modded drivers (edited INF) belong on the next page.	Signierte Treiber werden mit DISM in install.wim integriert, damit Windows sie beim ersten Start installiert. Speicher- und Netzwerktreiber kommen auch in boot.wim und WinRE, damit das Setup RAID-/VMD-Datentr&#xE4;ger sieht. Modifizierte Treiber (bearbeitete INF) geh&#xF6;ren auf die n&#xE4;chste Seite.
Add drivers from this PC	Treiber dieses PCs hinzuf&#xFC;gen
Import a drivers folder	Treiberordner importieren
Remove selected	Auswahl entfernen
Clear all	Alle entfernen
Also put storage and network drivers into boot.wim and WinRE	Speicher- und Netzwerktreiber auch in boot.wim und WinRE aufnehmen
Allow unsigned drivers in DISM (/ForceUnsigned)	Unsignierte Treiber in DISM erlauben (/ForceUnsigned)
Signed NVIDIA / modded drivers	Signierte NVIDIA- / Mod-Treiber
For driver packages whose INF was edited - NVCleanstall hardware-ID mods for an unsupported GPU, custom INF files. The edit breaks the catalog signature, so Windows refuses them. Every subfolder is scanned; each modified package gets a new catalog (MakeCat by default, or the engine you pick below) signed with your own certificate. The package is added to the ISO through $OEM$ and installed by SetupComplete.cmd at the end of Windows setup, right after the certificate is trusted.	F&#xFC;r Treiberpakete, deren INF bearbeitet wurde - Hardware-ID-Mods von NVCleanstall f&#xFC;r eine nicht unterst&#xFC;tzte GPU, eigene INF-Dateien. Die Bearbeitung bricht die Katalogsignatur, deshalb lehnt Windows sie ab. Alle Unterordner werden durchsucht; jedes ge&#xE4;nderte Paket erh&#xE4;lt einen neuen Katalog (standardm&#xE4;&#xDF;ig MakeCat oder das unten gew&#xE4;hlte Modul), signiert mit Ihrem eigenen Zertifikat. Das Paket kommt &#xFC;ber $OEM$ in die ISO und wird am Ende der Windows-Installation von SetupComplete.cmd installiert, direkt nachdem dem Zertifikat vertraut wurde.
Driver package	Treiberpaket
Folder	Ordner
Name	Name
installs from C:\Drivers\NVIDIA during setup	wird w&#xE4;hrend des Setups aus C:\Drivers\NVIDIA installiert
Engine	Modul
Signing engine: MakeCat	Signaturmodul: MakeCat
Signing engine: libwdi-style	Signaturmodul: libwdi-style
Signing engine: generate-cat-file in WSL	Signaturmodul: generate-cat-file in WSL
Signing engine: Inf2Cat	Signaturmodul: Inf2Cat
Re-sign every package, not only the modified ones	Alle Pakete neu signieren, nicht nur die ge&#xE4;nderten
Delete the driver copy from C:\Drivers once it is installed	Treiberkopie aus C:\Drivers l&#xF6;schen, sobald sie installiert ist
Faster: new catalogs only for the INF files that need one	Schneller: neue Kataloge nur f&#xFC;r die INF-Dateien, die einen brauchen
Every INF stays in the package, and the ones you did not edit keep their NVIDIA / Microsoft signature. MakeCat and the other folder engines point only the edited INF files at the folder's new catalog (off: every INF of the folder). Inf2Cat gets a copy of the folder with only the edited INF files (the driver files are hard links - no extra space), several at the same time; an edited INF whose catalog is shared with the others (nv_dispi.cat) gets a catalog file of its own. If Inf2Cat fails on that copy, the whole folder is catalogued as before.	Jede INF bleibt im Paket, und die nicht bearbeiteten behalten ihre NVIDIA-/Microsoft-Signatur. MakeCat und die anderen Ordner-Module verweisen nur die bearbeiteten INF-Dateien auf den neuen Katalog des Ordners (aus: jede INF des Ordners). Inf2Cat erh&#xE4;lt eine Kopie des Ordners mit nur den bearbeiteten INF-Dateien (die Treiberdateien sind feste Links - kein zus&#xE4;tzlicher Platz), mehrere gleichzeitig; eine bearbeitete INF, deren Katalog mit den anderen geteilt wird (nv_dispi.cat), erh&#xE4;lt eine eigene Katalogdatei. Scheitert Inf2Cat an dieser Kopie, wird der ganze Ordner wie bisher katalogisiert.
Faster: only keep the INF files for this PC's hardware (when the ISO is for this PC)	Schneller: nur die INF-Dateien f&#xFC;r die Hardware dieses PCs behalten (wenn die ISO f&#xFC;r diesen PC ist)
Mostly for Inf2Cat: NVIDIA's Display.Driver has one INF file per laptop and desktop maker, and Inf2Cat checks every one of them against the whole package - that can take up to an hour. With this on, only the INF files that list a device of this PC are signed (minutes instead), the others are removed from the copy. The original folder is not touched.	Vor allem f&#xFC;r Inf2Cat: NVIDIAs Display.Driver hat eine INF-Datei pro Laptop- und Desktop-Hersteller, und Inf2Cat pr&#xFC;ft jede gegen das ganze Paket - das kann bis zu einer Stunde dauern. Damit werden nur die INF-Dateien signiert, die ein Ger&#xE4;t dieses PCs nennen (stattdessen Minuten), die anderen werden aus der Kopie entfernt. Der Originalordner bleibt unver&#xE4;ndert.
Catalog runs at the same time	Gleichzeitige Katalogl&#xE4;ufe
1-8, empty = processor cores up to 8. Each Inf2Cat run uses one core; MakeCat does up to 4 folders at once.	1-8, leer = Prozessorkerne bis 8. Jeder Inf2Cat-Lauf nutzt einen Kern; MakeCat verarbeitet bis zu 4 Ordner gleichzeitig.
Sign and add to the ISO	Signieren und zur ISO hinzuf&#xFC;gen
Open signing folder	Signaturordner &#xF6;ffnen
Signing certificate	Signaturzertifikat
DriverSigning.pfx (private key) stays in the signing folder next to this tool - back it up and never share or upload it. Only the public DriverSigning.cer goes into the ISO. Tools (makecat, Inf2Cat, signtool) are downloaded automatically.	DriverSigning.pfx (privater Schl&#xFC;ssel) bleibt im Signaturordner neben diesem Werkzeug - sichern Sie es und geben Sie es nie weiter oder laden es hoch. Nur das &#xF6;ffentliche DriverSigning.cer kommt in die ISO. Die Werkzeuge (makecat, Inf2Cat, signtool) werden automatisch heruntergeladen.
Packages added to the ISO	Zur ISO hinzugef&#xFC;gte Pakete
Answer file and $OEM$	Antwortdatei und $OEM$
Both are optional and copied into the media when the ISO is built.	Beide sind optional und werden beim Erstellen der ISO auf das Medium kopiert.
none	keine
Placed in the ISO root so Setup runs unattended. Create one with the autounattend generator.	Liegt im Stammverzeichnis der ISO, damit das Setup unbeaufsichtigt l&#xE4;uft. Erstellen Sie eine mit dem autounattend-Generator.
Choose autounattend.xml	autounattend.xml ausw&#xE4;hlen
Open the generator	Generator &#xF6;ffnen
Remove	Entfernen
$OEM$ folder	$OEM$-Ordner
Copied to sources\$OEM$: $OEM$\$1 lands in C:\ and $OEM$\$$ in C:\Windows (e.g. $$\Setup\Scripts\SetupComplete.cmd). Packages from the signed-drivers page are merged in, and your SetupComplete.cmd gets a call to SetupComplete-drivers.cmd as its first command.	Wird nach sources\$OEM$ kopiert: $OEM$\$1 landet in C:\ und $OEM$\$$ in C:\Windows (z. B. $$\Setup\Scripts\SetupComplete.cmd). Die Pakete der Seite mit signierten Treibern werden hinzugef&#xFC;gt, und Ihre SetupComplete.cmd erh&#xE4;lt als ersten Befehl einen Aufruf von SetupComplete-drivers.cmd.
Choose $OEM$ folder	$OEM$-Ordner ausw&#xE4;hlen
Open	&#xD6;ffnen
Slipstream and build	Integrieren und erstellen
Slipstream applies updates, drivers and options to WinRE, install.wim and boot.wim (30-90 minutes). Build writes the bootable BIOS + UEFI ISO with your answer file, $OEM$ and signed drivers.	Integrieren wendet Updates, Treiber und Optionen auf WinRE, install.wim und boot.wim an (30-90 Minuten). Erstellen schreibt die bootf&#xE4;hige BIOS- + UEFI-ISO mit Ihrer Antwortdatei, $OEM$ und den signierten Treibern.
Boot options	Startoptionen
UEFI boot without 'Press any key to boot from CD or DVD'	UEFI-Start ohne 'Dr&#xFC;cken Sie eine beliebige Taste, um von CD oder DVD zu starten'
Boot manager signed by Windows UEFI CA 2023 (needs firmware that trusts it)	Start-Manager signiert von Windows UEFI CA 2023 (braucht Firmware, die ihr vertraut)
Split install.wim into 3.8 GB parts (FAT32 USB sticks)	install.wim in Teile zu 3,8 GB aufteilen (FAT32-USB-Sticks)
Speed	Geschwindigkeit
Update boot.wim and WinRE at the same time as install.wim (faster, uses more CPU and disk)	boot.wim und WinRE gleichzeitig mit install.wim aktualisieren (schneller, braucht mehr CPU und Datentr&#xE4;ger)
Editions at the same time	Gleichzeitige Editionen
Editions updated at the same time	Gleichzeitig aktualisierte Editionen
1-4, empty = automatic (2 on 4+ processor cores, 3 on 8+). Each one needs about 25 GB free on the work drive; fewer run at once when there is less. 1 = one after the other.	1-4, leer = automatisch (2 bei 4+ Kernen, 3 bei 8+). Jede braucht etwa 25 GB frei auf dem Arbeitslaufwerk; mit weniger Platz laufen weniger gleichzeitig. 1 = eine nach der anderen.
Let Windows Defender skip the work folder while a job runs (removed again afterwards)	Windows Defender den Arbeitsordner w&#xE4;hrend eines Auftrags &#xFC;berspringen lassen (danach wieder entfernt)
Leave boot.wim index 1 (Windows PE for WDS servers) as it is - USB / DVD setup uses index 2	boot.wim-Index 1 (Windows PE f&#xFC;r WDS-Server) unver&#xE4;ndert lassen - Setup von USB / DVD nutzt Index 2
DISM applies each update with one process, so servicing one image cannot use more cores - updating boot.wim, WinRE and several editions side by side can. Defender scanning every file DISM writes is often the biggest slowdown. Storage / network drivers go into WinRE and boot.wim with one DISM call. The log ends with the time of every step.	DISM wendet jedes Update mit einem einzigen Prozess an, die Wartung eines Abbilds kann also nicht mehr Kerne nutzen - boot.wim, WinRE und mehrere Editionen nebeneinander zu aktualisieren schon. Der Defender-Scan jeder Datei, die DISM schreibt, ist oft die gr&#xF6;&#xDF;te Bremse. Speicher-/Netzwerktreiber kommen mit einem DISM-Aufruf in WinRE und boot.wim. Das Protokoll endet mit der Dauer jedes Schritts.
Output ISO	Ausgabe-ISO
Save as...	Speichern unter...
Empty = work folder\output\Win10_ or Win11_version_build_arch_date.iso	Leer = Arbeitsordner\output\Win10_ oder Win11_Version_Build_Architektur_Datum.iso
1 - Slipstream into the image	1 - In das Abbild integrieren
2 - Build the ISO	2 - ISO erstellen
Open output folder	Ausgabeordner &#xF6;ffnen
Result	Ergebnis
No ISO built yet.	Noch keine ISO erstellt.
Work folder	Arbeitsordner
Apply	&#xDC;bernehmen
Short NTFS path without spaces with about 30 GB free (e.g. D:\W10U). A new folder starts empty.	Kurzer NTFS-Pfad ohne Leerzeichen mit etwa 30 GB frei (z. B. D:\W10U). Ein neuer Ordner beginnt leer.
Clean up	Bereinigen
Leftover mounted images and temporary files are always removed. Also delete:	&#xDC;brig gebliebene eingebundene Abbilder und tempor&#xE4;re Dateien werden immer entfernt. Au&#xDF;erdem l&#xF6;schen:
Downloaded updates	Heruntergeladene Updates
Unpacked media	Entpacktes Medium
Built ISOs	Erstellte ISOs
Re-signed driver copies	Kopien neu signierter Treiber
Copied drivers (this PC / imported folder)	Kopierte Treiber (dieser PC / importierter Ordner)
Answer file copy and install check results (the answer file must be chosen again)	Kopie der Antwortdatei und Pr&#xFC;fergebnisse (die Antwortdatei muss neu ausgew&#xE4;hlt werden)
Logs	Protokolle
Everything - empty the work folder and start from scratch	Alles - den Arbeitsordner leeren und von vorn beginnen
Clean up now	Jetzt bereinigen
Defaults	Standardwerte
Restore default options	Standardoptionen wiederherstellen
Open work folder	Arbeitsordner &#xF6;ffnen
Everything missing is downloaded automatically when a step needs it, into the tools folder next to this file. oscdimg.exe comes from the Microsoft symbol server (SHA-256 checked) or the Windows ADK; makecat, Inf2Cat and signtool are extracted from Microsoft's NuGet packages (Windows SDK build tools / Windows Driver Kit) - only those tools are kept, nothing is installed.	Alles Fehlende wird automatisch heruntergeladen, wenn ein Schritt es braucht, in den Ordner tools neben dieser Datei. oscdimg.exe kommt vom Symbolserver von Microsoft (per SHA-256 gepr&#xFC;ft) oder aus dem Windows ADK; makecat, Inf2Cat und signtool werden aus den NuGet-Paketen von Microsoft entnommen (Windows SDK build tools / Windows Driver Kit) - nur diese Werkzeuge werden behalten, nichts wird installiert.
Download missing tools now	Fehlende Werkzeuge jetzt herunterladen
Open tools folder	Werkzeugordner &#xF6;ffnen
Checks your autounattend.xml, $OEM$ folder and drivers against the ISO you are building and points out what would break or stall a clean install: wrong edition index or language, invalid computer / account names or time zone, duplicate command numbers, scripts that wait for a key, missing files, drivers that nothing installs or that Windows will refuse, and SetupComplete.cmd being skipped on PCs with an OEM key. Fixes change only the copies that go into the ISO - your own files stay as they are. The check also runs before every ISO build.	Pr&#xFC;ft Ihre autounattend.xml, den $OEM$-Ordner und die Treiber gegen die ISO, die Sie erstellen, und zeigt, was eine saubere Installation st&#xF6;ren oder anhalten w&#xFC;rde: falscher Editionsindex oder falsche Sprache, ung&#xFC;ltige Computer-/Kontonamen oder Zeitzone, doppelte Befehlsnummern, Skripte, die auf eine Taste warten, fehlende Dateien, Treiber, die nichts installiert oder die Windows ablehnt, und SetupComplete.cmd, das auf PCs mit OEM-Schl&#xFC;ssel &#xFC;bersprungen wird. Korrekturen &#xE4;ndern nur die Kopien, die in die ISO kommen - Ihre eigenen Dateien bleiben, wie sie sind. Die Pr&#xFC;fung l&#xE4;uft auch vor jedem ISO-Build.
Run the check	Pr&#xFC;fung ausf&#xFC;hren
Apply all fixes	Alle Korrekturen anwenden
Save fixed answer file as...	Korrigierte Antwortdatei speichern unter...
Undo answer file fixes	Korrekturen der Antwortdatei r&#xFC;ckg&#xE4;ngig machen
Not run yet.	Noch nicht ausgef&#xFC;hrt.
Level	Stufe
Area	Bereich
Finding	Befund
Fix	Korrektur
Also install the driver folders in my $OEM$\$1 with pnputil (from SetupComplete-drivers.cmd)	Auch die Treiberordner in meinem $OEM$\$1 mit pnputil installieren (aus SetupComplete-drivers.cmd)
Filter	Filter
Class, provider, INF or folder name	Klasse, Anbieter, INF oder Ordnername
All that fit	Alle passenden
Tick shown	Angezeigte anhaken
None	Keine
Add ticked drivers	Angehakte Treiber hinzuf&#xFC;gen
Cancel	Abbrechen
Driver signing certificate	Treibersignatur-Zertifikat
Password	Kennwort
Repeat the password	Kennwort wiederholen
Not there yet: {0}	Noch nicht vorhanden: {0}
Dark theme	Dunkles Design
Switch to the dark theme	Zum dunklen Design wechseln
Another job is still running.	Ein anderer Auftrag l&#xE4;uft noch.
{0} finished in {1:mm\:ss}	{0} fertig in {1:mm\:ss}
{0} stopped with an error - see the log	{0} mit einem Fehler beendet - siehe Protokoll
Unpack	Entpacken
Analyze	Analysieren
Download updates	Updates herunterladen
Driver scan	Treibersuche
Copy drivers	Treiber kopieren
Folder scan	Ordnersuche
Import drivers	Treiber importieren
Re-sign drivers	Treiber neu signieren
Slipstream	Integrieren
Build ISO	ISO erstellen
Apply fixes	Korrekturen anwenden
ISO check	ISO-Pr&#xFC;fung
no ISO yet	noch keine ISO
{0}  |  {1}  |  {2}  |  {3} edition(s)	{0}  |  {1}  |  {2}  |  {3} Edition(en)
{0} free	{0} frei
unpacked	entpackt
{0} of {1} ticked	{0} von {1} angehakt
tick at least one	mindestens eine anhaken
not available for this build	f&#xFC;r diesen Build nicht verf&#xFC;gbar
{0} ({1}) + {2} more	{0} ({1}) + {2} weitere
{0} packages ({1} for boot)	{0} Pakete ({1} f&#xFC;r den Start)
none (optional)	keine (optional)
{0} error(s), {1} warning(s)	{0} Fehler, {1} Warnung(en)
{0} warning(s)	{0} Warnung(en)
all good	alles in Ordnung
ISO ready	ISO fertig
slipstreamed ({0}) - build the ISO	integriert ({0}) - ISO erstellen
Updates for Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 and 25H2 (x64, ARM64). On a Windows 10 PC the slipstream uses the DISM of the Windows ADK Deployment Tools, installed from Microsoft when needed.	Updates f&#xFC;r Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 und 25H2 (x64, ARM64). Auf einem Windows 10-PC nutzt das Integrieren das DISM der Bereitstellungstools des Windows ADK, die bei Bedarf von Microsoft installiert werden.
Updates for Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 and LTSC 2021 (x64, x86, ARM64).	Updates f&#xFC;r Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 und LTSC 2021 (x64, x86, ARM64).
The unpacked ISO is Windows {0} - pick a Windows {1} ISO and unpack it to switch.	Die entpackte ISO ist Windows {0} - w&#xE4;hlen Sie eine Windows {1}-ISO und entpacken Sie sie, um zu wechseln.
Download Windows {0} from Microsoft	Windows {0} bei Microsoft herunterladen
Windows 11: the newest updates in the Microsoft Update Catalog are used (21H2, which is out of servicing: its last ones, 2024-10).	Windows 11: die neuesten Updates aus dem Microsoft Update-Katalog werden verwendet (21H2, das keinen Support mehr hat: seine letzten, 2024-10).
microsoft.com could not be reached, so only the list in this program was used - check again when online, the newest ISOs may be on the page.	microsoft.com war nicht erreichbar, daher wurde nur die Liste in diesem Programm verwendet - pr&#xFC;fen Sie erneut, wenn Sie online sind, die neuesten ISOs stehen eventuell auf der Seite.
Its name is the one of a Visual Studio subscription or Volume Licensing download, which are original too but not on the public pages: compare the SHA-256 with the one shown on that portal.	Der Name entspricht einem Download aus einem Visual Studio-Abonnement oder dem Volumenlizenz-Portal - auch diese sind original, stehen aber nicht auf den &#xF6;ffentlichen Seiten: Vergleichen Sie den SHA-256 mit dem dort angezeigten.
An ISO made with the Media Creation Tool is built on the PC and is never listed, and an older ISO Microsoft no longer offers may be missing too. Otherwise it may have been modified: download an original Windows {0} ISO from Microsoft (button above) and use that one.	Eine mit dem Media Creation Tool erstellte ISO wird auf dem PC erzeugt und steht nie in der Liste, und auch eine &#xE4;ltere ISO, die Microsoft nicht mehr anbietet, kann fehlen. Andernfalls wurde sie m&#xF6;glicherweise ver&#xE4;ndert: Laden Sie eine Original-ISO von Windows {0} bei Microsoft herunter (Schaltfl&#xE4;che oben) und verwenden Sie diese.
Its SHA-256 is one Microsoft published on its download page (seen there on {0}).	Ihr SHA-256 ist einer der Werte, die Microsoft auf seiner Downloadseite ver&#xF6;ffentlicht hat (dort gesehen am {0}).
Its SHA-256 is on Microsoft's download page (checked {0}).	Ihr SHA-256 steht auf der Downloadseite von Microsoft (gepr&#xFC;ft am {0}).
Original Microsoft ISO: {0} - {1}	Original-ISO von Microsoft: {0} - {1}
Made with the Media Creation Tool - setup and boot files signed by Microsoft	Mit dem Media Creation Tool erstellt - Setup- und Startdateien von Microsoft signiert
The Media Creation Tool builds the ISO on the PC from Microsoft's download, so its SHA-256 is never in Microsoft's list - that is normal. Its setup and boot files ({0} checked) carry Microsoft's signature; the Windows image in it (install.esd) isn't signed as a whole, so it isn't covered.	Das Media Creation Tool erstellt die ISO auf dem PC aus dem Download von Microsoft, daher steht ihr SHA-256 nie in der Liste von Microsoft - das ist normal. Ihre Setup- und Startdateien ({0} gepr&#xFC;ft) tragen die Signatur von Microsoft; das Windows-Abbild darin (install.esd) ist nicht als Ganzes signiert und wird daher nicht erfasst.
Modified: files in this ISO are not signed by Microsoft	Ver&#xE4;ndert: Dateien in dieser ISO sind nicht von Microsoft signiert
Not signed by Microsoft: {0}. Download an original Windows {1} ISO from Microsoft (button above) and use that one.	Nicht von Microsoft signiert: {0}. Laden Sie eine Original-ISO von Windows {1} bei Microsoft herunter (Schaltfl&#xE4;che oben) und verwenden Sie diese.
Its setup and boot files are signed by Microsoft ({0} checked), but the Windows image in it can't be checked this way.	Ihre Setup- und Startdateien sind von Microsoft signiert ({0} gepr&#xFC;ft), das Windows-Abbild darin l&#xE4;sst sich so aber nicht pr&#xFC;fen.
Not verified: the SHA-256 is not one Microsoft lists for its Windows 10 and 11 ISOs.	Nicht best&#xE4;tigt: Der SHA-256 ist keiner der Werte, die Microsoft f&#xFC;r seine Windows 10- und 11-ISOs angibt.
Not checked yet - the ISO is checked when you unpack it, or now with Check the ISO.	Noch nicht gepr&#xFC;ft - die ISO wird beim Entpacken gepr&#xFC;ft oder jetzt mit ISO pr&#xFC;fen.
{0}  -  build {1}  -  {2}  -  {3} edition(s)	{0}  -  Build {1}  -  {2}  -  {3} Edition(en)
No automatic updates for this build - drivers, signed packages, answer file and $OEM$ still work.	Keine automatischen Updates f&#xFC;r diesen Build - Treiber, signierte Pakete, Antwortdatei und $OEM$ funktionieren weiterhin.
Updates up to {0} (the last month Microsoft allows offline for Windows 10).	Updates bis {0} (der letzte Monat, den Microsoft f&#xFC;r Windows 10 offline zul&#xE4;sst).
Its last updates ({0}) - this version is out of servicing.	Seine letzten Updates ({0}) - diese Version hat keinen Support mehr.
Newest updates available in the Microsoft Update Catalog.	Neueste Updates aus dem Microsoft Update-Katalog.
The {0} enablement package is added too.	Das Aktivierungspaket {0} wird ebenfalls hinzugef&#xFC;gt.
{0} driver package(s), {1} storage/network for boot.wim and WinRE, about {2:N0} MB	{0} Treiberpaket(e), {1} Speicher/Netzwerk f&#xFC;r boot.wim und WinRE, etwa {2:N0} MB
No drivers selected.	Keine Treiber ausgew&#xE4;hlt.
this PC only ({0} kept)	nur dieser PC ({0} behalten)
all	alle
Ready - {0}, valid until {1:yyyy-MM-dd} (backed up as DriverSigning.pfx)	Bereit - {0}, g&#xFC;ltig bis {1:yyyy-MM-dd} (gesichert als DriverSigning.pfx)
In this PC's certificate store, not backed up yet - you will be asked for a password to save DriverSigning.pfx.	Im Zertifikatspeicher dieses PCs, noch nicht gesichert - Sie werden nach einem Kennwort gefragt, um DriverSigning.pfx zu speichern.
DriverSigning.pfx found - its password is asked when you sign.	DriverSigning.pfx gefunden - das Kennwort wird beim Signieren abgefragt.
None yet - one is created the first time you sign (you choose its password).	Noch keins - es wird beim ersten Signieren erstellt (Sie w&#xE4;hlen das Kennwort).
{0}   (added {1})	{0}   (hinzugef&#xFC;gt {1})
Slipstreamed on {0} - build {1}. Build the ISO next.	Integriert am {0} - Build {1}. Als N&#xE4;chstes die ISO erstellen.
{0} error(s), {1} warning(s), {2} check(s) passed   -   {3}	{0} Fehler, {1} Warnung(en), {2} Pr&#xFC;fung(en) bestanden   -   {3}
Apply {0} fix(es)	{0} Korrektur(en) anwenden
The ISO uses a fixed copy of your answer file (fixed {0}). Save it to update your own file too.	Die ISO nutzt eine korrigierte Kopie Ihrer Antwortdatei (korrigiert {0}). Speichern Sie sie, um auch Ihre eigene Datei zu aktualisieren.
folder not found	Ordner nicht gefunden
{0} files, {1}   ({2})	{0} Dateien, {1}   ({2})
has SetupComplete.cmd	enth&#xE4;lt SetupComplete.cmd
missing - downloaded automatically when you build the ISO	fehlt - wird beim Erstellen der ISO automatisch heruntergeladen
missing - downloaded automatically when you sign drivers	fehlt - wird beim Signieren von Treibern automatisch heruntergeladen
missing - downloaded only if the signing engine needs Inf2Cat as fallback	fehlt - wird nur heruntergeladen, wenn das Signaturmodul Inf2Cat als Ausweichl&#xF6;sung braucht
missing - only needed for the MakeCat signing engine	fehlt - nur f&#xFC;r das Signaturmodul MakeCat n&#xF6;tig
missing - PowerShell / BITS downloads are used	fehlt - Downloads &#xFC;ber PowerShell / BITS werden verwendet
Default. makecat.exe (Windows SDK) builds one catalog per driver folder with the hash of every file in it, so each file is hashed once - about 20 s for NVIDIA's 3 GB Display.Driver instead of minutes. Compressed files (name.dl_) are hashed expanded, the way Windows checks them. MakeCat does not parse the INF: every catalog is checked with signtool afterwards, and a folder MakeCat cannot do goes to Inf2Cat.	Standard. makecat.exe (Windows SDK) erstellt einen Katalog pro Treiberordner mit dem Hash jeder Datei darin, jede Datei wird also nur einmal gehasht - etwa 20 s f&#xFC;r NVIDIAs 3 GB Display.Driver statt Minuten. Komprimierte Dateien (name.dl_) werden entpackt gehasht, so wie Windows sie pr&#xFC;ft. MakeCat liest die INF nicht: jeder Katalog wird danach mit signtool gepr&#xFC;ft, und ein Ordner, den MakeCat nicht schafft, geht an Inf2Cat.
Experimental. The catalog is built with the CryptCAT API of Windows itself, the way libwdi (Zadig) does it - nothing to download. One catalog per driver folder with the hash of every file in it (SHA-1). Checked with signtool afterwards; a folder it cannot do goes to Inf2Cat.	Experimentell. Der Katalog wird mit der CryptCAT-API von Windows selbst erstellt, so wie libwdi (Zadig) es macht - nichts herunterzuladen. Ein Katalog pro Treiberordner mit dem Hash jeder Datei darin (SHA-1). Danach mit signtool gepr&#xFC;ft; ein Ordner, den es nicht schafft, geht an Inf2Cat.
Experimental. LINBIT generate-cat-file (GPL-2.0): its source is downloaded from GitHub (one pinned commit, SHA-256 checked) and built inside WSL - needs WSL with a Linux distribution that has gcc and make. One catalog per driver folder; Inf2Cat signs when WSL or the build is missing.	Experimentell. LINBIT generate-cat-file (GPL-2.0): der Quellcode wird von GitHub geladen (ein fester Commit, per SHA-256 gepr&#xFC;ft) und in WSL gebaut - braucht WSL mit einer Linux-Distribution, die gcc und make hat. Ein Katalog pro Treiberordner; Inf2Cat signiert, wenn WSL oder der Build fehlt.
Microsoft's standard tool from the Windows Driver Kit: it parses every INF and checks it against every file of the package. The proven choice, but slow on big packages - the options below make it faster.	Das Standardwerkzeug von Microsoft aus dem Windows Driver Kit: es liest jede INF und pr&#xFC;ft sie gegen jede Datei des Pakets. Die bew&#xE4;hrte Wahl, aber langsam bei gro&#xDF;en Paketen - die Optionen unten machen es schneller.
installs from {0} during Windows setup	wird w&#xE4;hrend der Windows-Installation aus {0} installiert
{0} older version(s) of drivers that are here in a newer version too are unticked (column Older) - Windows uses the newest one.	{0} &#xE4;ltere Version(en) von Treibern, die hier auch in einer neueren Version vorliegen, sind nicht angehakt (Spalte &#xC4;lter) - Windows nutzt die neueste.
DriverSigning.pfx was found next to this tool. Enter its password to load your signing certificate.	DriverSigning.pfx wurde neben diesem Werkzeug gefunden. Geben Sie das Kennwort ein, um Ihr Signaturzertifikat zu laden.
Your signing certificate is in this PC's store but has no backup yet. Choose a password to save it as DriverSigning.pfx - you need it to sign again after reinstalling Windows.	Ihr Signaturzertifikat ist im Speicher dieses PCs, hat aber noch keine Sicherung. W&#xE4;hlen Sie ein Kennwort, um es als DriverSigning.pfx zu speichern - Sie brauchen es, um nach einer Neuinstallation von Windows erneut zu signieren.
A new self-signed code-signing certificate will be created. Choose a password for its backup file DriverSigning.pfx - you need it to sign again after reinstalling Windows.	Ein neues selbstsigniertes Codesignaturzertifikat wird erstellt. W&#xE4;hlen Sie ein Kennwort f&#xFC;r die Sicherungsdatei DriverSigning.pfx - Sie brauchen sie, um nach einer Neuinstallation von Windows erneut zu signieren.
Enter a password.	Geben Sie ein Kennwort ein.
The passwords do not match.	Die Kennw&#xF6;rter stimmen nicht &#xFC;berein.
Index	Index
Edition	Edition
Build	Build
Size	Gr&#xF6;&#xDF;e
SizeGB	Gr&#xF6;&#xDF;e (GB)
Kind	Art
Date	Datum
Title	Titel
No	Nr.
Source	Quelle
Class	Klasse
Provider	Anbieter
Version	Version
SizeMB	Gr&#xF6;&#xDF;e (MB)
InstallsFrom	Installiert aus
Signed	Signiert
Failed	Fehlgeschlagen
When	Wann
FixText	Korrektur
Arch	Architektur
Older	&#xC4;lter
Unpack an ISO first (page 1).	Entpacken Sie zuerst eine ISO (Seite 1).
Choose an existing .iso file first.	W&#xE4;hlen Sie zuerst eine vorhandene .iso-Datei.
The work folder already has unpacked media ({0}). Replace it with a fresh copy of this ISO?	Der Arbeitsordner enth&#xE4;lt bereits ein entpacktes Medium ({0}). Durch eine frische Kopie dieser ISO ersetzen?
Unpack this ISO anyway?	Diese ISO trotzdem entpacken?
Drivers installed on this PC	Auf diesem PC installierte Treiber
Third-party drivers exported from this PC. Ticked ones are slipstreamed into the ISO.	Von diesem PC exportierte Treiber von Drittanbietern. Die angehakten werden in die ISO integriert.
Pick the drivers folder - Drivers-Backup made by Drivers.cmd, a folder from another PC or a vendor pack. All subfolders are scanned.	W&#xE4;hlen Sie den Treiberordner - Drivers-Backup von Drivers.cmd, ein Ordner von einem anderen PC oder ein Herstellerpaket. Alle Unterordner werden durchsucht.
No .inf drivers in that folder.	Keine .inf-Treiber in diesem Ordner.
Drivers in {0}	Treiber in {0}
Drivers built for another architecture than the ISO are unticked and left out.	Treiber f&#xFC;r eine andere Architektur als die der ISO sind nicht angehakt und bleiben drau&#xDF;en.
Choose the driver folder first (for example the folder NVCleanstall extracted).	W&#xE4;hlen Sie zuerst den Treiberordner (zum Beispiel den Ordner, den NVCleanstall entpackt hat).
There are no .inf files in that folder or its subfolders.	In diesem Ordner und seinen Unterordnern gibt es keine .inf-Dateien.
Tick at least one edition first.	Haken Sie zuerst mindestens eine Edition an.
This media was already slipstreamed on {0}. For a clean result unpack the ISO again (page 1). Slipstream again anyway?	Dieses Medium wurde bereits am {0} integriert. F&#xFC;r ein sauberes Ergebnis entpacken Sie die ISO erneut (Seite 1). Trotzdem erneut integrieren?
No updates are downloaded (page 3). Continue with drivers and options only?	Keine Updates heruntergeladen (Seite 3). Nur mit Treibern und Optionen fortfahren?
The media has not been slipstreamed yet. Build the ISO anyway (drivers, updates and options are then missing)?	Das Medium wurde noch nicht integriert. Die ISO trotzdem erstellen (dann fehlen Treiber, Updates und Optionen)?
Nothing to fix automatically - run the check first. Findings without a fix need a change on the page they mention.	Nichts automatisch zu korrigieren - f&#xFC;hren Sie zuerst die Pr&#xFC;fung aus. Befunde ohne Korrektur brauchen eine &#xC4;nderung auf der genannten Seite.
Apply these fixes? They change the copies that go into the ISO, not your own files.	Diese Korrekturen anwenden? Sie &#xE4;ndern die Kopien, die in die ISO kommen, nicht Ihre eigenen Dateien.
Choose the source ISO on page 1 first.	W&#xE4;hlen Sie zuerst die Quell-ISO auf Seite 1.
yes	ja
no	nein
Source: {0}	Quelle: {0}
Editions: {0}	Editionen: {0}
{0} ticked	{0} angehakt
asked after unpacking	wird nach dem Entpacken gefragt
Drivers: {0}   Signed packages: {1}	Treiber: {0}   Signierte Pakete: {1}
Answer file: {0}   $OEM$: {1}	Antwortdatei: {0}   $OEM$: {1}
Run everything now? It takes 30-90 minutes - the PC is kept awake until it is done.	Jetzt alles ausf&#xFC;hren? Es dauert 30-90 Minuten - der PC bleibt wach, bis es fertig ist.
Run everything with this ISO anyway?	Trotzdem alles mit dieser ISO ausf&#xFC;hren?
While a job runs (unpack, download, sign, slipstream, build), Windows Defender does not scan the work folder ({0}). The exclusion is removed when the job ends, and at the next start if the program was closed during a job. Everything in there comes from Microsoft, your drivers and this tool - do not put other downloads in that folder.	W&#xE4;hrend ein Auftrag l&#xE4;uft (entpacken, herunterladen, signieren, integrieren, erstellen), scannt Windows Defender den Arbeitsordner ({0}) nicht. Die Ausnahme wird entfernt, wenn der Auftrag endet, und beim n&#xE4;chsten Start, falls das Programm w&#xE4;hrend eines Auftrags geschlossen wurde. Alles darin stammt von Microsoft, Ihren Treibern und diesem Werkzeug - legen Sie keine anderen Downloads in diesen Ordner.
Use this only when the ISO is for this PC. INF files for other hardware are removed from the signed copy, so the driver installs only on hardware that matches this PC. NVIDIA's own setup.exe may refuse to run from that copy - pnputil installs the driver anyway. Sign the package again for it to take effect.	Nutzen Sie das nur, wenn die ISO f&#xFC;r diesen PC ist. INF-Dateien f&#xFC;r andere Hardware werden aus der signierten Kopie entfernt, der Treiber installiert sich also nur auf Hardware wie in diesem PC. NVIDIAs eigenes setup.exe startet aus dieser Kopie eventuell nicht - pnputil installiert den Treiber trotzdem. Signieren Sie das Paket erneut, damit es wirkt.
With Secure Boot on, this ISO only boots on PCs whose UEFI already trusts 'Windows UEFI CA 2023'. Older firmware needs that Secure Boot update first (or Secure Boot off). The image also needs a 2024-04 or newer update.	Mit aktiviertem Secure Boot startet diese ISO nur auf PCs, deren UEFI 'Windows UEFI CA 2023' bereits vertraut. &#xC4;ltere Firmware braucht zuerst dieses Secure-Boot-Update (oder Secure Boot aus). Das Abbild braucht au&#xDF;erdem ein Update von 2024-04 oder neuer.
Use the YYYY-MM format, e.g. 2025-10.	Verwenden Sie das Format JJJJ-MM, z. B. 2025-10.
Use a number from 1 to 8 (or leave it empty for the number of processor cores, up to 8).	Verwenden Sie eine Zahl von 1 bis 8 (oder lassen Sie das Feld leer f&#xFC;r die Zahl der Prozessorkerne, bis 8).
Use a number from 1 to 4 (or leave it empty: 2 on 4+ processor cores, 3 on 8+).	Verwenden Sie eine Zahl von 1 bis 4 (oder lassen Sie das Feld leer: 2 bei 4+ Kernen, 3 bei 8+).
Select a Windows {0} ISO	Eine Windows {0}-ISO ausw&#xE4;hlen
ISO images	ISO-Abbilder
Select the drivers to remove in the list first (Ctrl+click for several).	W&#xE4;hlen Sie zuerst in der Liste die zu entfernenden Treiber (Strg+Klick f&#xFC;r mehrere).
Remove every selected driver?	Alle ausgew&#xE4;hlten Treiber entfernen?
Pick the modded driver folder (e.g. the folder NVCleanstall extracted). All subfolders are scanned.	W&#xE4;hlen Sie den Ordner mit den modifizierten Treibern (z. B. den Ordner, den NVCleanstall entpackt hat). Alle Unterordner werden durchsucht.
Select a package in the list first.	W&#xE4;hlen Sie zuerst ein Paket in der Liste.
Select your autounattend.xml	Ihre autounattend.xml ausw&#xE4;hlen
Answer files	Antwortdateien
Pick your $OEM$ folder (the one that contains $1 and/or $$)	W&#xE4;hlen Sie Ihren $OEM$-Ordner (den, der $1 und/oder $$ enth&#xE4;lt)
ISO image	ISO-Abbild
Pick or create the work folder (NTFS, no spaces, ~30 GB free)	Arbeitsordner w&#xE4;hlen oder anlegen (NTFS, ohne Leerzeichen, ~30 GB frei)
The path has spaces - a short path like D:\W10U is safer for DISM. Use it anyway?	Der Pfad enth&#xE4;lt Leerzeichen - ein kurzer Pfad wie D:\W10U ist f&#xFC;r DISM sicherer. Trotzdem verwenden?
downloaded updates	heruntergeladene Updates
unpacked media	entpacktes Medium
built ISOs	erstellte ISOs
re-signed driver copies	Kopien neu signierter Treiber
copied drivers	kopierte Treiber
answer file copy and check results	Kopie der Antwortdatei und Pr&#xFC;fergebnisse
logs	Protokolle
EVERYTHING in the work folder	ALLES im Arbeitsordner
mounted images and temp files	eingebundene Abbilder und tempor&#xE4;re Dateien
Delete: {0}?	L&#xF6;schen: {0}?
Restore the default options? The work folder is kept.	Standardoptionen wiederherstellen? Der Arbeitsordner bleibt.
There is no answer file yet (page 6).	Es gibt noch keine Antwortdatei (Seite 6).
Answer file	Antwortdatei
No answer file fixes to undo.	Keine Korrekturen der Antwortdatei zum R&#xFC;ckg&#xE4;ngigmachen.
Put the answer file back the way it was before the fixes?	Die Antwortdatei wieder so herstellen, wie sie vor den Korrekturen war?
'{0}' is still running. Closing now can leave a mounted image behind (run Clean up next time). Close anyway?	'{0}' l&#xE4;uft noch. Wenn Sie jetzt schlie&#xDF;en, kann ein eingebundenes Abbild zur&#xFC;ckbleiben (beim n&#xE4;chsten Mal Bereinigen ausf&#xFC;hren). Trotzdem schlie&#xDF;en?
'@ }
        'it' { return @'
updates + drivers + signed NVIDIA mods + autounattend + $OEM$  ->  bootable ISO	aggiornamenti + driver + mod NVIDIA firmati + autounattend + $OEM$  ->  ISO avviabile
Light theme	Tema chiaro
Switch to the light theme	Passa al tema chiaro
Display and accessibility: theme, text size, font	Schermo e accessibilit&#xE0;: tema, dimensione del testo, carattere
Display and accessibility settings	Impostazioni di schermo e accessibilit&#xE0;
Minimize	Riduci a icona
Maximize	Ingrandisci
Close	Chiudi
Display and accessibility	Schermo e accessibilit&#xE0;
Theme	Tema
Dark	Scuro
Light	Chiaro
Like Windows	Come Windows
Text size	Dimensione del testo
Font	Carattere
Language	Lingua
Ctrl + plus / Ctrl + minus / Ctrl + 0 change the text size anywhere in the window. Verdana and Tahoma have wider, more distinct letters. Saved for the next start.	Ctrl + pi&#xF9; / Ctrl + meno / Ctrl + 0 cambiano la dimensione del testo in qualsiasi punto della finestra. Verdana e Tahoma hanno lettere pi&#xF9; larghe e pi&#xF9; distinte. Salvato per il prossimo avvio.
The Activity log and the Install check findings stay in English - that is what a bug report or a search needs.	Il registro Attivit&#xE0; e i risultati del Controllo dell'installazione restano in inglese: &#xE8; ci&#xF2; che serve a una segnalazione di bug o a una ricerca.
STEPS	PASSAGGI
Source ISO	ISO di origine
to do	da fare
Editions	Edizioni
Windows updates	Aggiornamenti di Windows
Drivers	Driver
optional	facoltativo
Signed NVIDIA / modded	NVIDIA firmati / modificati
Answer file + $OEM$	File di risposta + $OEM$
Install check	Controllo dell'installazione
not run yet	non ancora eseguito
Slipstream + build ISO	Integra + crea ISO
MORE	ALTRO
Options and clean up	Opzioni e pulizia
Tools	Strumenti
Run everything	Esegui tutto
unpack - updates - slipstream - ISO, using what you set on each page	estrai - aggiornamenti - integra - ISO, con ci&#xF2; che hai impostato in ogni pagina
SOURCE	ORIGINE
IMAGE	IMMAGINE
WORK FOLDER	CARTELLA DI LAVORO
ACTIVITY	ATTIVIT&#xC0;
Ready	Pronto
Logs folder	Cartella dei registri
Clear	Cancella
Choose Windows 10 or Windows 11 and pick its ISO. It is copied into the work folder and its build and editions are detected - the version follows the ISO you unpack.	Scegli Windows 10 o Windows 11 e seleziona la sua ISO. Viene copiata nella cartella di lavoro e ne vengono rilevate build ed edizioni - la versione segue la ISO che estrai.
Windows version	Versione di Windows
ISO file	File ISO
Use an original ISO from Microsoft. Before it is unpacked, its SHA-256 is compared with the ones Microsoft publishes for its Windows 10 and 11 ISOs - the list in this program and, when online, the download pages on microsoft.com. When it is not there (an ISO made with the Media Creation Tool never is), the Microsoft signatures of its setup and boot files are checked.	Usa una ISO originale di Microsoft. Prima dell'estrazione, il suo SHA-256 viene confrontato con quelli che Microsoft pubblica per le ISO di Windows 10 e 11 - l'elenco di questo programma e, se sei online, le pagine di download su microsoft.com. Se non &#xE8; l&#xEC; (una ISO creata con lo Strumento di creazione supporti non lo &#xE8; mai), vengono verificate le firme Microsoft dei suoi file di installazione e di avvio.
Browse...	Sfoglia...
Unpack and analyze	Estrai e analizza
Check the ISO	Verifica la ISO
Re-read image info	Rileggi l'immagine
Download Windows 10 from Microsoft	Scarica Windows 10 da Microsoft
SHA-256 of the ISO - select it to copy	SHA-256 della ISO - selezionalo per copiarlo
Detected image	Immagine rilevata
Nothing unpacked yet.	Ancora niente estratto.
Tick the editions to update. With the option below on, unticked editions are left out of the new ISO (smaller and faster).	Spunta le edizioni da aggiornare. Con l'opzione qui sotto attiva, le edizioni non spuntate restano fuori dalla nuova ISO (pi&#xF9; piccola e pi&#xF9; veloce).
Tick all	Spunta tutte
Tick none	Togli tutte
Use	Usa
Keep only the ticked editions in the new ISO	Tieni solo le edizioni spuntate nella nuova ISO
Finds the newest cumulative update, servicing stack, Safe OS and Setup Dynamic Updates and .NET updates for this build in the Microsoft Update Catalog and downloads them (SHA-1 checked).	Cerca nel Catalogo di Microsoft Update l'aggiornamento cumulativo pi&#xF9; recente, lo stack di manutenzione, gli aggiornamenti dinamici Safe OS e di installazione e gli aggiornamenti .NET per questa build e li scarica (controllati con SHA-1).
What to integrate	Cosa integrare
Add .NET Framework 4.8.1 (Windows 10 2004-22H2 - Windows 11 has it built in)	Aggiungi .NET Framework 4.8.1 (Windows 10 2004-22H2 - Windows 11 lo include gi&#xE0;)
Enable .NET Framework 3.5 (from the ISO's sources\sxs)	Attiva .NET Framework 3.5 (da sources\sxs della ISO)
Component cleanup /ResetBase (smaller image - updates can't be uninstalled)	Pulizia dei componenti /ResetBase (immagine pi&#xF9; piccola - gli aggiornamenti non si possono pi&#xF9; disinstallare)
Newest month to integrate	Mese pi&#xF9; recente da integrare
YYYY-MM, for Windows 10 2004-22H2 / LTSC 2021	AAAA-MM, per Windows 10 2004-22H2 / LTSC 2021
2025-10 is the last Windows 10 update Microsoft allows offline. ESU updates (Nov 2025+) come from Windows Update after setup on enrolled PCs.	2025-10 &#xE8; l'ultimo aggiornamento di Windows 10 che Microsoft consente di integrare offline. Gli aggiornamenti ESU (nov. 2025+) arrivano da Windows Update dopo l'installazione, sui PC iscritti.
Find and download updates	Cerca e scarica gli aggiornamenti
Downloaded	Scaricati
Signed drivers are slipstreamed into install.wim with DISM, so Windows installs them on first boot. Storage and network drivers also go into boot.wim and WinRE, so Setup sees RAID / VMD disks. Modded drivers (edited INF) belong on the next page.	I driver firmati vengono integrati in install.wim con DISM, cos&#xEC; Windows li installa al primo avvio. I driver di archiviazione e di rete vanno anche in boot.wim e WinRE, cos&#xEC; il programma di installazione vede i dischi RAID / VMD. I driver modificati (INF modificato) vanno nella pagina successiva.
Add drivers from this PC	Aggiungi i driver di questo PC
Import a drivers folder	Importa una cartella di driver
Remove selected	Rimuovi selezionati
Clear all	Rimuovi tutti
Also put storage and network drivers into boot.wim and WinRE	Metti anche i driver di archiviazione e di rete in boot.wim e WinRE
Allow unsigned drivers in DISM (/ForceUnsigned)	Consenti driver non firmati in DISM (/ForceUnsigned)
Signed NVIDIA / modded drivers	Driver NVIDIA firmati / modificati
For driver packages whose INF was edited - NVCleanstall hardware-ID mods for an unsupported GPU, custom INF files. The edit breaks the catalog signature, so Windows refuses them. Every subfolder is scanned; each modified package gets a new catalog (MakeCat by default, or the engine you pick below) signed with your own certificate. The package is added to the ISO through $OEM$ and installed by SetupComplete.cmd at the end of Windows setup, right after the certificate is trusted.	Per pacchetti di driver il cui INF &#xE8; stato modificato - mod di ID hardware di NVCleanstall per una GPU non supportata, file INF personalizzati. La modifica rompe la firma del catalogo e Windows li rifiuta. Tutte le sottocartelle vengono analizzate; ogni pacchetto modificato riceve un nuovo catalogo (MakeCat come impostazione predefinita, o il motore che scegli qui sotto) firmato con il tuo certificato. Il pacchetto viene aggiunto alla ISO tramite $OEM$ e installato da SetupComplete.cmd alla fine dell'installazione di Windows, subito dopo che il certificato &#xE8; diventato attendibile.
Driver package	Pacchetto di driver
Folder	Cartella
Name	Nome
installs from C:\Drivers\NVIDIA during setup	si installa da C:\Drivers\NVIDIA durante l'installazione
Engine	Motore
Signing engine: MakeCat	Motore di firma: MakeCat
Signing engine: libwdi-style	Motore di firma: libwdi-style
Signing engine: generate-cat-file in WSL	Motore di firma: generate-cat-file in WSL
Signing engine: Inf2Cat	Motore di firma: Inf2Cat
Re-sign every package, not only the modified ones	Firma di nuovo tutti i pacchetti, non solo quelli modificati
Delete the driver copy from C:\Drivers once it is installed	Elimina la copia dei driver da C:\Drivers dopo l'installazione
Faster: new catalogs only for the INF files that need one	Pi&#xF9; veloce: nuovi cataloghi solo per i file INF che ne hanno bisogno
Every INF stays in the package, and the ones you did not edit keep their NVIDIA / Microsoft signature. MakeCat and the other folder engines point only the edited INF files at the folder's new catalog (off: every INF of the folder). Inf2Cat gets a copy of the folder with only the edited INF files (the driver files are hard links - no extra space), several at the same time; an edited INF whose catalog is shared with the others (nv_dispi.cat) gets a catalog file of its own. If Inf2Cat fails on that copy, the whole folder is catalogued as before.	Ogni INF resta nel pacchetto, e quelli che non hai modificato mantengono la firma NVIDIA / Microsoft. MakeCat e gli altri motori per cartella collegano solo gli INF modificati al nuovo catalogo della cartella (disattivato: tutti gli INF della cartella). Inf2Cat riceve una copia della cartella con solo gli INF modificati (i file dei driver sono collegamenti fisici - nessuno spazio in pi&#xF9;), pi&#xF9; copie insieme; un INF modificato il cui catalogo &#xE8; condiviso con gli altri (nv_dispi.cat) riceve un file di catalogo proprio. Se Inf2Cat non riesce su quella copia, l'intera cartella viene catalogata come prima.
Faster: only keep the INF files for this PC's hardware (when the ISO is for this PC)	Pi&#xF9; veloce: tieni solo i file INF per l'hardware di questo PC (quando la ISO &#xE8; per questo PC)
Mostly for Inf2Cat: NVIDIA's Display.Driver has one INF file per laptop and desktop maker, and Inf2Cat checks every one of them against the whole package - that can take up to an hour. With this on, only the INF files that list a device of this PC are signed (minutes instead), the others are removed from the copy. The original folder is not touched.	Soprattutto per Inf2Cat: il Display.Driver di NVIDIA ha un file INF per ogni produttore di portatili e desktop, e Inf2Cat controlla ciascuno sull'intero pacchetto - pu&#xF2; richiedere fino a un'ora. Con questa opzione vengono firmati solo gli INF che indicano un dispositivo di questo PC (minuti invece), gli altri vengono rimossi dalla copia. La cartella originale non viene toccata.
Catalog runs at the same time	Catalogazioni contemporanee
1-8, empty = processor cores up to 8. Each Inf2Cat run uses one core; MakeCat does up to 4 folders at once.	1-8, vuoto = core del processore fino a 8. Ogni esecuzione di Inf2Cat usa un core; MakeCat elabora fino a 4 cartelle insieme.
Sign and add to the ISO	Firma e aggiungi alla ISO
Open signing folder	Apri la cartella di firma
Signing certificate	Certificato di firma
DriverSigning.pfx (private key) stays in the signing folder next to this tool - back it up and never share or upload it. Only the public DriverSigning.cer goes into the ISO. Tools (makecat, Inf2Cat, signtool) are downloaded automatically.	DriverSigning.pfx (chiave privata) resta nella cartella di firma accanto a questo strumento - fanne un backup e non condividerlo n&#xE9; caricarlo mai. Solo il DriverSigning.cer pubblico va nella ISO. Gli strumenti (makecat, Inf2Cat, signtool) vengono scaricati automaticamente.
Packages added to the ISO	Pacchetti aggiunti alla ISO
Answer file and $OEM$	File di risposta e $OEM$
Both are optional and copied into the media when the ISO is built.	Entrambi sono facoltativi e vengono copiati nel supporto quando si crea la ISO.
none	nessuno
Placed in the ISO root so Setup runs unattended. Create one with the autounattend generator.	Messo nella radice della ISO perch&#xE9; l'installazione sia automatica. Creane uno con il generatore autounattend.
Choose autounattend.xml	Scegli autounattend.xml
Open the generator	Apri il generatore
Remove	Rimuovi
$OEM$ folder	Cartella $OEM$
Copied to sources\$OEM$: $OEM$\$1 lands in C:\ and $OEM$\$$ in C:\Windows (e.g. $$\Setup\Scripts\SetupComplete.cmd). Packages from the signed-drivers page are merged in, and your SetupComplete.cmd gets a call to SetupComplete-drivers.cmd as its first command.	Copiata in sources\$OEM$: $OEM$\$1 finisce in C:\ e $OEM$\$$ in C:\Windows (es. $$\Setup\Scripts\SetupComplete.cmd). I pacchetti della pagina dei driver firmati vengono aggiunti, e il tuo SetupComplete.cmd riceve una chiamata a SetupComplete-drivers.cmd come primo comando.
Choose $OEM$ folder	Scegli la cartella $OEM$
Open	Apri
Slipstream and build	Integra e crea
Slipstream applies updates, drivers and options to WinRE, install.wim and boot.wim (30-90 minutes). Build writes the bootable BIOS + UEFI ISO with your answer file, $OEM$ and signed drivers.	L'integrazione applica aggiornamenti, driver e opzioni a WinRE, install.wim e boot.wim (30-90 minuti). La creazione scrive la ISO avviabile BIOS + UEFI con il tuo file di risposta, $OEM$ e i driver firmati.
Boot options	Opzioni di avvio
UEFI boot without 'Press any key to boot from CD or DVD'	Avvio UEFI senza 'Premere un tasto per avviare da CD o DVD'
Boot manager signed by Windows UEFI CA 2023 (needs firmware that trusts it)	Boot manager firmato da Windows UEFI CA 2023 (serve un firmware che lo consideri attendibile)
Split install.wim into 3.8 GB parts (FAT32 USB sticks)	Dividi install.wim in parti da 3,8 GB (chiavette USB FAT32)
Speed	Velocit&#xE0;
Update boot.wim and WinRE at the same time as install.wim (faster, uses more CPU and disk)	Aggiorna boot.wim e WinRE insieme a install.wim (pi&#xF9; veloce, usa pi&#xF9; CPU e disco)
Editions at the same time	Edizioni contemporanee
Editions updated at the same time	Edizioni aggiornate contemporaneamente
1-4, empty = automatic (2 on 4+ processor cores, 3 on 8+). Each one needs about 25 GB free on the work drive; fewer run at once when there is less. 1 = one after the other.	1-4, vuoto = automatico (2 con 4+ core, 3 con 8+). Ognuna richiede circa 25 GB liberi sull'unit&#xE0; di lavoro; con meno spazio ne girano meno insieme. 1 = una dopo l'altra.
Let Windows Defender skip the work folder while a job runs (removed again afterwards)	Lascia che Windows Defender salti la cartella di lavoro mentre un'operazione &#xE8; in corso (rimosso dopo)
Leave boot.wim index 1 (Windows PE for WDS servers) as it is - USB / DVD setup uses index 2	Lascia l'indice 1 di boot.wim (Windows PE per server WDS) com'&#xE8; - l'installazione da USB / DVD usa l'indice 2
DISM applies each update with one process, so servicing one image cannot use more cores - updating boot.wim, WinRE and several editions side by side can. Defender scanning every file DISM writes is often the biggest slowdown. Storage / network drivers go into WinRE and boot.wim with one DISM call. The log ends with the time of every step.	DISM applica ogni aggiornamento con un solo processo, quindi la manutenzione di un'immagine non pu&#xF2; usare pi&#xF9; core - aggiornare boot.wim, WinRE e pi&#xF9; edizioni affiancate s&#xEC;. La scansione di Defender di ogni file scritto da DISM &#xE8; spesso il rallentamento maggiore. I driver di archiviazione / rete vanno in WinRE e boot.wim con una sola chiamata DISM. Il registro termina con la durata di ogni passaggio.
Output ISO	ISO di output
Save as...	Salva con nome...
Empty = work folder\output\Win10_ or Win11_version_build_arch_date.iso	Vuoto = cartella di lavoro\output\Win10_ o Win11_versione_build_architettura_data.iso
1 - Slipstream into the image	1 - Integra nell'immagine
2 - Build the ISO	2 - Crea la ISO
Open output folder	Apri la cartella di output
Result	Risultato
No ISO built yet.	Nessuna ISO ancora creata.
Work folder	Cartella di lavoro
Apply	Applica
Short NTFS path without spaces with about 30 GB free (e.g. D:\W10U). A new folder starts empty.	Percorso NTFS corto, senza spazi, con circa 30 GB liberi (es. D:\W10U). Una nuova cartella parte vuota.
Clean up	Pulizia
Leftover mounted images and temporary files are always removed. Also delete:	Le immagini montate rimaste e i file temporanei vengono sempre rimossi. Elimina anche:
Downloaded updates	Aggiornamenti scaricati
Unpacked media	Supporto estratto
Built ISOs	ISO create
Re-signed driver copies	Copie dei driver firmati di nuovo
Copied drivers (this PC / imported folder)	Driver copiati (questo PC / cartella importata)
Answer file copy and install check results (the answer file must be chosen again)	Copia del file di risposta e risultati del controllo (il file di risposta va scelto di nuovo)
Logs	Registri
Everything - empty the work folder and start from scratch	Tutto - svuota la cartella di lavoro e ricomincia da zero
Clean up now	Pulisci ora
Defaults	Impostazioni predefinite
Restore default options	Ripristina le opzioni predefinite
Open work folder	Apri la cartella di lavoro
Everything missing is downloaded automatically when a step needs it, into the tools folder next to this file. oscdimg.exe comes from the Microsoft symbol server (SHA-256 checked) or the Windows ADK; makecat, Inf2Cat and signtool are extracted from Microsoft's NuGet packages (Windows SDK build tools / Windows Driver Kit) - only those tools are kept, nothing is installed.	Tutto ci&#xF2; che manca viene scaricato automaticamente quando un passaggio ne ha bisogno, nella cartella tools accanto a questo file. oscdimg.exe viene dal server dei simboli di Microsoft (controllato con SHA-256) o dal Windows ADK; makecat, Inf2Cat e signtool vengono estratti dai pacchetti NuGet di Microsoft (Windows SDK build tools / Windows Driver Kit) - vengono tenuti solo questi strumenti, non viene installato nulla.
Download missing tools now	Scarica ora gli strumenti mancanti
Open tools folder	Apri la cartella degli strumenti
Checks your autounattend.xml, $OEM$ folder and drivers against the ISO you are building and points out what would break or stall a clean install: wrong edition index or language, invalid computer / account names or time zone, duplicate command numbers, scripts that wait for a key, missing files, drivers that nothing installs or that Windows will refuse, and SetupComplete.cmd being skipped on PCs with an OEM key. Fixes change only the copies that go into the ISO - your own files stay as they are. The check also runs before every ISO build.	Controlla il tuo autounattend.xml, la cartella $OEM$ e i driver rispetto alla ISO che stai creando e indica cosa romperebbe o bloccherebbe un'installazione pulita: indice di edizione o lingua errati, nomi di computer / account o fuso orario non validi, numeri di comando duplicati, script che aspettano un tasto, file mancanti, driver che nulla installa o che Windows rifiuter&#xE0;, e SetupComplete.cmd saltato sui PC con chiave OEM. Le correzioni cambiano solo le copie che vanno nella ISO - i tuoi file restano come sono. Il controllo viene eseguito anche prima di ogni creazione della ISO.
Run the check	Esegui il controllo
Apply all fixes	Applica tutte le correzioni
Save fixed answer file as...	Salva il file di risposta corretto con nome...
Undo answer file fixes	Annulla le correzioni del file di risposta
Not run yet.	Non ancora eseguito.
Level	Livello
Area	Area
Finding	Rilievo
Fix	Correzione
Also install the driver folders in my $OEM$\$1 with pnputil (from SetupComplete-drivers.cmd)	Installa anche le cartelle di driver nel mio $OEM$\$1 con pnputil (da SetupComplete-drivers.cmd)
Filter	Filtro
Class, provider, INF or folder name	Classe, fornitore, INF o nome della cartella
All that fit	Tutti quelli adatti
Tick shown	Spunta quelli visibili
None	Nessuno
Add ticked drivers	Aggiungi i driver spuntati
Cancel	Annulla
Driver signing certificate	Certificato di firma dei driver
Password	Password
Repeat the password	Ripeti la password
Not there yet: {0}	Non c'&#xE8; ancora: {0}
Dark theme	Tema scuro
Switch to the dark theme	Passa al tema scuro
Another job is still running.	Un'altra operazione &#xE8; ancora in corso.
{0} finished in {1:mm\:ss}	{0} terminato in {1:mm\:ss}
{0} stopped with an error - see the log	{0} si &#xE8; fermato con un errore - vedi il registro
Unpack	Estrai
Analyze	Analizza
Download updates	Scarica aggiornamenti
Driver scan	Ricerca driver
Copy drivers	Copia driver
Folder scan	Analisi cartella
Import drivers	Importa driver
Re-sign drivers	Firma di nuovo i driver
Slipstream	Integrazione
Build ISO	Crea ISO
Apply fixes	Applica correzioni
ISO check	Verifica della ISO
no ISO yet	ancora nessuna ISO
{0}  |  {1}  |  {2}  |  {3} edition(s)	{0}  |  {1}  |  {2}  |  {3} edizione/i
{0} free	{0} liberi
unpacked	estratta
{0} of {1} ticked	{0} di {1} spuntate
tick at least one	spuntane almeno una
not available for this build	non disponibile per questa build
{0} ({1}) + {2} more	{0} ({1}) + altri {2}
{0} packages ({1} for boot)	{0} pacchetti ({1} per l'avvio)
none (optional)	nessuno (facoltativo)
{0} error(s), {1} warning(s)	{0} errore/i, {1} avviso/i
{0} warning(s)	{0} avviso/i
all good	tutto a posto
ISO ready	ISO pronta
slipstreamed ({0}) - build the ISO	integrata ({0}) - crea la ISO
Updates for Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 and 25H2 (x64, ARM64). On a Windows 10 PC the slipstream uses the DISM of the Windows ADK Deployment Tools, installed from Microsoft when needed.	Aggiornamenti per Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 e 25H2 (x64, ARM64). Su un PC con Windows 10 l'integrazione usa il DISM degli Strumenti di distribuzione del Windows ADK, installati da Microsoft quando serve.
Updates for Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 and LTSC 2021 (x64, x86, ARM64).	Aggiornamenti per Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 e LTSC 2021 (x64, x86, ARM64).
The unpacked ISO is Windows {0} - pick a Windows {1} ISO and unpack it to switch.	La ISO estratta &#xE8; Windows {0} - scegli una ISO di Windows {1} ed estraila per cambiare.
Download Windows {0} from Microsoft	Scarica Windows {0} da Microsoft
Windows 11: the newest updates in the Microsoft Update Catalog are used (21H2, which is out of servicing: its last ones, 2024-10).	Windows 11: vengono usati gli aggiornamenti pi&#xF9; recenti del Catalogo di Microsoft Update (21H2, non pi&#xF9; supportato: i suoi ultimi, 2024-10).
microsoft.com could not be reached, so only the list in this program was used - check again when online, the newest ISOs may be on the page.	Impossibile raggiungere microsoft.com, quindi &#xE8; stato usato solo l'elenco di questo programma - verifica di nuovo quando sei online, le ISO pi&#xF9; recenti potrebbero essere sulla pagina.
Its name is the one of a Visual Studio subscription or Volume Licensing download, which are original too but not on the public pages: compare the SHA-256 with the one shown on that portal.	Il nome &#xE8; quello di un download di un abbonamento Visual Studio o del Volume Licensing, che sono anch'esse originali ma non compaiono nelle pagine pubbliche: confronta lo SHA-256 con quello indicato su quel portale.
An ISO made with the Media Creation Tool is built on the PC and is never listed, and an older ISO Microsoft no longer offers may be missing too. Otherwise it may have been modified: download an original Windows {0} ISO from Microsoft (button above) and use that one.	Una ISO creata con lo Strumento di creazione supporti viene generata sul PC e non &#xE8; mai nell'elenco, e anche una ISO pi&#xF9; vecchia che Microsoft non offre pi&#xF9; pu&#xF2; mancare. Altrimenti potrebbe essere stata modificata: scarica una ISO originale di Windows {0} da Microsoft (pulsante qui sopra) e usa quella.
Its SHA-256 is one Microsoft published on its download page (seen there on {0}).	Il suo SHA-256 &#xE8; uno di quelli che Microsoft ha pubblicato sulla sua pagina di download (visto l&#xEC; il {0}).
Its SHA-256 is on Microsoft's download page (checked {0}).	Il suo SHA-256 &#xE8; sulla pagina di download di Microsoft (verificato il {0}).
Original Microsoft ISO: {0} - {1}	ISO originale di Microsoft: {0} - {1}
Made with the Media Creation Tool - setup and boot files signed by Microsoft	Creata con lo Strumento di creazione supporti - file di installazione e di avvio firmati da Microsoft
The Media Creation Tool builds the ISO on the PC from Microsoft's download, so its SHA-256 is never in Microsoft's list - that is normal. Its setup and boot files ({0} checked) carry Microsoft's signature; the Windows image in it (install.esd) isn't signed as a whole, so it isn't covered.	Lo Strumento di creazione supporti crea la ISO sul PC dal download di Microsoft, quindi il suo SHA-256 non &#xE8; mai nell'elenco di Microsoft - &#xE8; normale. I suoi file di installazione e di avvio ({0} verificati) hanno la firma di Microsoft; l'immagine di Windows (install.esd) non &#xE8; firmata nel suo insieme, quindi non &#xE8; coperta.
Modified: files in this ISO are not signed by Microsoft	Modificata: alcuni file di questa ISO non sono firmati da Microsoft
Not signed by Microsoft: {0}. Download an original Windows {1} ISO from Microsoft (button above) and use that one.	Senza firma Microsoft: {0}. Scarica una ISO originale di Windows {1} da Microsoft (pulsante qui sopra) e usa quella.
Its setup and boot files are signed by Microsoft ({0} checked), but the Windows image in it can't be checked this way.	I suoi file di installazione e di avvio sono firmati da Microsoft ({0} verificati), ma l'immagine di Windows non si pu&#xF2; verificare in questo modo.
Not verified: the SHA-256 is not one Microsoft lists for its Windows 10 and 11 ISOs.	Non verificata: lo SHA-256 non &#xE8; nessuno di quelli che Microsoft indica per le ISO di Windows 10 e 11.
Not checked yet - the ISO is checked when you unpack it, or now with Check the ISO.	Non ancora verificata - la ISO viene verificata quando la estrai, o subito con Verifica la ISO.
{0}  -  build {1}  -  {2}  -  {3} edition(s)	{0}  -  build {1}  -  {2}  -  {3} edizione/i
No automatic updates for this build - drivers, signed packages, answer file and $OEM$ still work.	Nessun aggiornamento automatico per questa build - driver, pacchetti firmati, file di risposta e $OEM$ funzionano comunque.
Updates up to {0} (the last month Microsoft allows offline for Windows 10).	Aggiornamenti fino a {0} (l'ultimo mese che Microsoft consente offline per Windows 10).
Its last updates ({0}) - this version is out of servicing.	I suoi ultimi aggiornamenti ({0}) - questa versione non &#xE8; pi&#xF9; supportata.
Newest updates available in the Microsoft Update Catalog.	Aggiornamenti pi&#xF9; recenti disponibili nel Catalogo di Microsoft Update.
The {0} enablement package is added too.	Viene aggiunto anche il pacchetto di abilitazione {0}.
{0} driver package(s), {1} storage/network for boot.wim and WinRE, about {2:N0} MB	{0} pacchetto/i di driver, {1} di archiviazione/rete per boot.wim e WinRE, circa {2:N0} MB
No drivers selected.	Nessun driver selezionato.
this PC only ({0} kept)	solo questo PC ({0} tenuti)
all	tutti
Ready - {0}, valid until {1:yyyy-MM-dd} (backed up as DriverSigning.pfx)	Pronto - {0}, valido fino al {1:yyyy-MM-dd} (backup in DriverSigning.pfx)
In this PC's certificate store, not backed up yet - you will be asked for a password to save DriverSigning.pfx.	Nell'archivio certificati di questo PC, ancora senza backup - ti verr&#xE0; chiesta una password per salvare DriverSigning.pfx.
DriverSigning.pfx found - its password is asked when you sign.	DriverSigning.pfx trovato - la password viene chiesta quando firmi.
None yet - one is created the first time you sign (you choose its password).	Ancora nessuno - viene creato la prima volta che firmi (scegli tu la password).
{0}   (added {1})	{0}   (aggiunto il {1})
Slipstreamed on {0} - build {1}. Build the ISO next.	Integrata il {0} - build {1}. Ora crea la ISO.
{0} error(s), {1} warning(s), {2} check(s) passed   -   {3}	{0} errore/i, {1} avviso/i, {2} controllo/i superato/i   -   {3}
Apply {0} fix(es)	Applica {0} correzione/i
The ISO uses a fixed copy of your answer file (fixed {0}). Save it to update your own file too.	La ISO usa una copia corretta del tuo file di risposta (corretta il {0}). Salvala per aggiornare anche il tuo file.
folder not found	cartella non trovata
{0} files, {1}   ({2})	{0} file, {1}   ({2})
has SetupComplete.cmd	contiene SetupComplete.cmd
missing - downloaded automatically when you build the ISO	manca - viene scaricato automaticamente quando crei la ISO
missing - downloaded automatically when you sign drivers	manca - viene scaricato automaticamente quando firmi i driver
missing - downloaded only if the signing engine needs Inf2Cat as fallback	manca - viene scaricato solo se il motore di firma ha bisogno di Inf2Cat come riserva
missing - only needed for the MakeCat signing engine	manca - serve solo per il motore di firma MakeCat
missing - PowerShell / BITS downloads are used	manca - vengono usati i download di PowerShell / BITS
Default. makecat.exe (Windows SDK) builds one catalog per driver folder with the hash of every file in it, so each file is hashed once - about 20 s for NVIDIA's 3 GB Display.Driver instead of minutes. Compressed files (name.dl_) are hashed expanded, the way Windows checks them. MakeCat does not parse the INF: every catalog is checked with signtool afterwards, and a folder MakeCat cannot do goes to Inf2Cat.	Predefinito. makecat.exe (Windows SDK) crea un catalogo per cartella di driver con l'hash di ogni file al suo interno, cos&#xEC; ogni file viene calcolato una sola volta - circa 20 s per i 3 GB del Display.Driver di NVIDIA invece di minuti. I file compressi (nome.dl_) vengono calcolati espansi, come li controlla Windows. MakeCat non analizza l'INF: ogni catalogo viene poi controllato con signtool, e una cartella che MakeCat non riesce a gestire passa a Inf2Cat.
Experimental. The catalog is built with the CryptCAT API of Windows itself, the way libwdi (Zadig) does it - nothing to download. One catalog per driver folder with the hash of every file in it (SHA-1). Checked with signtool afterwards; a folder it cannot do goes to Inf2Cat.	Sperimentale. Il catalogo viene creato con l'API CryptCAT di Windows stesso, come fa libwdi (Zadig) - niente da scaricare. Un catalogo per cartella di driver con l'hash di ogni file al suo interno (SHA-1). Controllato poi con signtool; una cartella che non riesce a gestire passa a Inf2Cat.
Experimental. LINBIT generate-cat-file (GPL-2.0): its source is downloaded from GitHub (one pinned commit, SHA-256 checked) and built inside WSL - needs WSL with a Linux distribution that has gcc and make. One catalog per driver folder; Inf2Cat signs when WSL or the build is missing.	Sperimentale. LINBIT generate-cat-file (GPL-2.0): il codice sorgente viene scaricato da GitHub (un commit fisso, controllato con SHA-256) e compilato dentro WSL - serve WSL con una distribuzione Linux che abbia gcc e make. Un catalogo per cartella di driver; Inf2Cat firma quando mancano WSL o la compilazione.
Microsoft's standard tool from the Windows Driver Kit: it parses every INF and checks it against every file of the package. The proven choice, but slow on big packages - the options below make it faster.	Lo strumento standard di Microsoft, dal Windows Driver Kit: analizza ogni INF e lo controlla su ogni file del pacchetto. La scelta collaudata, ma lenta con pacchetti grandi - le opzioni qui sotto la rendono pi&#xF9; veloce.
installs from {0} during Windows setup	si installa da {0} durante l'installazione di Windows
{0} older version(s) of drivers that are here in a newer version too are unticked (column Older) - Windows uses the newest one.	{0} versione/i pi&#xF9; vecchia/e di driver presenti qui anche in una versione pi&#xF9; nuova non sono spuntate (colonna Pi&#xF9; vecchio) - Windows usa la pi&#xF9; recente.
DriverSigning.pfx was found next to this tool. Enter its password to load your signing certificate.	DriverSigning.pfx &#xE8; stato trovato accanto a questo strumento. Inserisci la sua password per caricare il tuo certificato di firma.
Your signing certificate is in this PC's store but has no backup yet. Choose a password to save it as DriverSigning.pfx - you need it to sign again after reinstalling Windows.	Il tuo certificato di firma &#xE8; nell'archivio di questo PC ma non ha ancora un backup. Scegli una password per salvarlo come DriverSigning.pfx - ti serve per firmare di nuovo dopo aver reinstallato Windows.
A new self-signed code-signing certificate will be created. Choose a password for its backup file DriverSigning.pfx - you need it to sign again after reinstalling Windows.	Verr&#xE0; creato un nuovo certificato di firma del codice autofirmato. Scegli una password per il suo file di backup DriverSigning.pfx - ti serve per firmare di nuovo dopo aver reinstallato Windows.
Enter a password.	Inserisci una password.
The passwords do not match.	Le password non coincidono.
Index	Indice
Edition	Edizione
Build	Build
Size	Dimensione
SizeGB	Dimensione (GB)
Kind	Tipo
Date	Data
Title	Titolo
No	N.
Source	Origine
Class	Classe
Provider	Fornitore
Version	Versione
SizeMB	Dimensione (MB)
InstallsFrom	Si installa da
Signed	Firmati
Failed	Non riusciti
When	Quando
FixText	Correzione
Arch	Architettura
Older	Pi&#xF9; vecchio
Unpack an ISO first (page 1).	Estrai prima una ISO (pagina 1).
Choose an existing .iso file first.	Scegli prima un file .iso esistente.
The work folder already has unpacked media ({0}). Replace it with a fresh copy of this ISO?	La cartella di lavoro contiene gi&#xE0; un supporto estratto ({0}). Sostituirlo con una nuova copia di questa ISO?
Unpack this ISO anyway?	Estrarre comunque questa ISO?
Drivers installed on this PC	Driver installati su questo PC
Third-party drivers exported from this PC. Ticked ones are slipstreamed into the ISO.	Driver di terze parti esportati da questo PC. Quelli spuntati vengono integrati nella ISO.
Pick the drivers folder - Drivers-Backup made by Drivers.cmd, a folder from another PC or a vendor pack. All subfolders are scanned.	Scegli la cartella dei driver - Drivers-Backup creata da Drivers.cmd, una cartella di un altro PC o un pacchetto del produttore. Tutte le sottocartelle vengono analizzate.
No .inf drivers in that folder.	Nessun driver .inf in quella cartella.
Drivers in {0}	Driver in {0}
Drivers built for another architecture than the ISO are unticked and left out.	I driver fatti per un'architettura diversa da quella della ISO non sono spuntati e restano fuori.
Choose the driver folder first (for example the folder NVCleanstall extracted).	Scegli prima la cartella dei driver (per esempio la cartella estratta da NVCleanstall).
There are no .inf files in that folder or its subfolders.	Non ci sono file .inf in quella cartella n&#xE9; nelle sue sottocartelle.
Tick at least one edition first.	Spunta prima almeno un'edizione.
This media was already slipstreamed on {0}. For a clean result unpack the ISO again (page 1). Slipstream again anyway?	Questo supporto &#xE8; gi&#xE0; stato integrato il {0}. Per un risultato pulito estrai di nuovo la ISO (pagina 1). Integrare di nuovo comunque?
No updates are downloaded (page 3). Continue with drivers and options only?	Nessun aggiornamento scaricato (pagina 3). Continuare solo con driver e opzioni?
The media has not been slipstreamed yet. Build the ISO anyway (drivers, updates and options are then missing)?	Il supporto non &#xE8; ancora stato integrato. Creare comunque la ISO (mancheranno driver, aggiornamenti e opzioni)?
Nothing to fix automatically - run the check first. Findings without a fix need a change on the page they mention.	Niente da correggere automaticamente - esegui prima il controllo. I rilievi senza correzione richiedono una modifica nella pagina che indicano.
Apply these fixes? They change the copies that go into the ISO, not your own files.	Applicare queste correzioni? Cambiano le copie che vanno nella ISO, non i tuoi file.
Choose the source ISO on page 1 first.	Scegli prima la ISO di origine nella pagina 1.
yes	s&#xEC;
no	no
Source: {0}	Origine: {0}
Editions: {0}	Edizioni: {0}
{0} ticked	{0} spuntate
asked after unpacking	chiesto dopo l'estrazione
Drivers: {0}   Signed packages: {1}	Driver: {0}   Pacchetti firmati: {1}
Answer file: {0}   $OEM$: {1}	File di risposta: {0}   $OEM$: {1}
Run everything now? It takes 30-90 minutes - the PC is kept awake until it is done.	Eseguire tutto ora? Richiede 30-90 minuti - il PC resta acceso finch&#xE9; non ha finito.
Run everything with this ISO anyway?	Eseguire comunque tutto con questa ISO?
While a job runs (unpack, download, sign, slipstream, build), Windows Defender does not scan the work folder ({0}). The exclusion is removed when the job ends, and at the next start if the program was closed during a job. Everything in there comes from Microsoft, your drivers and this tool - do not put other downloads in that folder.	Mentre un'operazione &#xE8; in corso (estrai, scarica, firma, integra, crea), Windows Defender non analizza la cartella di lavoro ({0}). L'esclusione viene rimossa al termine dell'operazione, e al prossimo avvio se il programma &#xE8; stato chiuso durante un'operazione. Tutto ci&#xF2; che contiene viene da Microsoft, dai tuoi driver e da questo strumento - non metterci altri download.
Use this only when the ISO is for this PC. INF files for other hardware are removed from the signed copy, so the driver installs only on hardware that matches this PC. NVIDIA's own setup.exe may refuse to run from that copy - pnputil installs the driver anyway. Sign the package again for it to take effect.	Usalo solo quando la ISO &#xE8; per questo PC. I file INF per altro hardware vengono rimossi dalla copia firmata, quindi il driver si installa solo su hardware uguale a quello di questo PC. Il setup.exe di NVIDIA potrebbe rifiutarsi di partire da quella copia - pnputil installa comunque il driver. Firma di nuovo il pacchetto perch&#xE9; abbia effetto.
With Secure Boot on, this ISO only boots on PCs whose UEFI already trusts 'Windows UEFI CA 2023'. Older firmware needs that Secure Boot update first (or Secure Boot off). The image also needs a 2024-04 or newer update.	Con l'Avvio protetto attivo, questa ISO si avvia solo sui PC il cui UEFI considera gi&#xE0; attendibile 'Windows UEFI CA 2023'. I firmware pi&#xF9; vecchi hanno bisogno prima di quell'aggiornamento dell'Avvio protetto (o dell'Avvio protetto disattivato). L'immagine ha bisogno anche di un aggiornamento del 2024-04 o pi&#xF9; recente.
Use the YYYY-MM format, e.g. 2025-10.	Usa il formato AAAA-MM, es. 2025-10.
Use a number from 1 to 8 (or leave it empty for the number of processor cores, up to 8).	Usa un numero da 1 a 8 (o lascia vuoto per il numero di core del processore, fino a 8).
Use a number from 1 to 4 (or leave it empty: 2 on 4+ processor cores, 3 on 8+).	Usa un numero da 1 a 4 (o lascia vuoto: 2 con 4+ core, 3 con 8+).
Select a Windows {0} ISO	Seleziona una ISO di Windows {0}
ISO images	Immagini ISO
Select the drivers to remove in the list first (Ctrl+click for several).	Seleziona prima nell'elenco i driver da rimuovere (Ctrl+clic per pi&#xF9; di uno).
Remove every selected driver?	Rimuovere tutti i driver selezionati?
Pick the modded driver folder (e.g. the folder NVCleanstall extracted). All subfolders are scanned.	Scegli la cartella dei driver modificati (es. la cartella estratta da NVCleanstall). Tutte le sottocartelle vengono analizzate.
Select a package in the list first.	Seleziona prima un pacchetto nell'elenco.
Select your autounattend.xml	Seleziona il tuo autounattend.xml
Answer files	File di risposta
Pick your $OEM$ folder (the one that contains $1 and/or $$)	Scegli la tua cartella $OEM$ (quella che contiene $1 e/o $$)
ISO image	Immagine ISO
Pick or create the work folder (NTFS, no spaces, ~30 GB free)	Scegli o crea la cartella di lavoro (NTFS, senza spazi, ~30 GB liberi)
The path has spaces - a short path like D:\W10U is safer for DISM. Use it anyway?	Il percorso contiene spazi - un percorso corto come D:\W10U &#xE8; pi&#xF9; sicuro per DISM. Usarlo comunque?
downloaded updates	aggiornamenti scaricati
unpacked media	supporto estratto
built ISOs	ISO create
re-signed driver copies	copie dei driver firmati di nuovo
copied drivers	driver copiati
answer file copy and check results	copia del file di risposta e risultati del controllo
logs	registri
EVERYTHING in the work folder	TUTTO il contenuto della cartella di lavoro
mounted images and temp files	immagini montate e file temporanei
Delete: {0}?	Eliminare: {0}?
Restore the default options? The work folder is kept.	Ripristinare le opzioni predefinite? La cartella di lavoro viene mantenuta.
There is no answer file yet (page 6).	Non c'&#xE8; ancora un file di risposta (pagina 6).
Answer file	File di risposta
No answer file fixes to undo.	Nessuna correzione del file di risposta da annullare.
Put the answer file back the way it was before the fixes?	Riportare il file di risposta com'era prima delle correzioni?
'{0}' is still running. Closing now can leave a mounted image behind (run Clean up next time). Close anyway?	'{0}' &#xE8; ancora in corso. Chiudere ora pu&#xF2; lasciare un'immagine montata (esegui la Pulizia la prossima volta). Chiudere comunque?
'@ }
    }
    return ''
}

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
    # the texts in the language in use (English in the XAML); list columns get theirs when they are made
    $texts = Get-UiTexts $win
    Set-UiTexts $texts
    Add-GridHeaderTranslation $texts
    return @{ W = $win; U = $names; Texts = $texts }
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
    if ($Path -and (Test-Path -LiteralPath $Path)) { Start-Process explorer.exe "`"$Path`"" } else { Show-Msg ((T 'Not there yet: {0}') -f $Path) }
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
    $lc = ([string]$Script:Cfg.UiLanguage).ToLowerInvariant()
    if (-not $lc) { $lc = 'auto' }
    $U.LangAuto.IsChecked = ($lc -eq 'auto')
    foreach ($l in (Get-LanguageList)) { $U[$l.Button].IsChecked = ($lc -eq $l.Code) }
    $light = $Script:ThemeNow -eq 'Light'
    $U.ThemeBtn.Content = if ($light) { [string][char]0xE708 } else { [string][char]0xE706 }      # moon / sun
    $U.ThemeBtn.ToolTip = if ($light) { T 'Dark theme' } else { T 'Light theme' }
    try { [Windows.Automation.AutomationProperties]::SetName($U.ThemeBtn, $(if ($light) { T 'Switch to the dark theme' } else { T 'Switch to the light theme' })) } catch { }
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
    if ($Script:Busy) { Show-Msg (T 'Another job is still running.'); return }
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
        $Script:U.BusyText.Text = ((T '{0} finished in {1:mm\:ss}') -f $Script:JobLabel, $took)
        Set-BusyDot '#3DDC97'
        Set-TaskbarState 'None'
    } else {
        $Script:U.BusyText.Text = (T '{0} stopped with an error - see the log') -f $Script:JobLabel
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
    $labels = @{ Unpack = (T 'Unpack'); Analyze = (T 'Analyze'); Download = (T 'Download updates'); ScanHost = (T 'Driver scan'); CommitHost = (T 'Copy drivers')
                 ScanFolder = (T 'Folder scan'); CommitImport = (T 'Import drivers'); Sign = (T 'Re-sign drivers'); Service = (T 'Slipstream'); Build = (T 'Build ISO')
                 All = (T 'Run everything'); Tools = (T 'Tools'); Clean = (T 'Clean up'); Check = (T 'Install check'); Fix = (T 'Apply fixes'); CheckIso = (T 'ISO check') }
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
    $U.HdrIso.Text = if ($S.SourceIso) { Split-Path $S.SourceIso -Leaf } else { T 'no ISO yet' }
    $U.HdrImg.Text = if ($S.Family -and @($S.Images).Count -gt 0) { (T '{0}  |  {1}  |  {2}  |  {3} edition(s)') -f $S.Family.Name, $S.Images[0].Version, $S.Family.Arch, @($S.Images).Count } else { '-' }
    $free = ''
    try { $free = '  (' + ((T '{0} free') -f (Format-Size (New-Object IO.DriveInfo([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Script:P.Work)))).AvailableFreeSpace)) + ')' } catch { }
    $U.HdrWork.Text = $Script:P.Work + $free

    if ($S.Unpacked) { Set-Step 1 (T 'unpacked') 'ok' } else { Set-Step 1 (T 'to do') 'todo' }
    $ns = @($S.Selected).Count
    if ($ns -gt 0) { Set-Step 2 ((T '{0} of {1} ticked') -f $ns, @($S.Images).Count) 'ok' } elseif ($S.Unpacked) { Set-Step 2 (T 'tick at least one') 'todo' } else { Set-Step 2 (T 'to do') 'todo' }
    $lcu = @($S.Updates | Where-Object { $_.Kind -eq 'LCU' }) | Select-Object -First 1
    if ($S.Family -and -not $S.Family.Supported) { Set-Step 3 (T 'not available for this build') 'warn' }
    elseif ($lcu) { Set-Step 3 ((T '{0} ({1}) + {2} more') -f $lcu.KB, $lcu.Date.Substring(0, 7), (@($S.Updates).Count - 1)) 'ok' }
    else { Set-Step 3 (T 'to do') 'todo' }
    $nd = @($S.Drivers).Count
    if ($nd -gt 0) { Set-Step 4 ((T '{0} packages ({1} for boot)') -f $nd, @($S.Drivers | Where-Object { $Script:BootClasses -contains $_.Class }).Count) 'ok' } else { Set-Step 4 (T 'none (optional)') 'opt' }
    $sg = @($S.Signed | Where-Object { $_ })
    if ($sg.Count -gt 0) {
        $kind = if (@($sg | Where-Object { [int]$_.Failed -gt 0 }).Count) { 'warn' } else { 'ok' }
        Set-Step 5 (($sg | ForEach-Object { $_.Name }) -join ', ') $kind
    } else { Set-Step 5 (T 'none (optional)') 'opt' }
    $p6 = @()
    if ($S.Unattend) { $p6 += 'autounattend' }
    if ($S.Oem) { $p6 += '$OEM$' }
    if ($p6.Count) { Set-Step 6 ($p6 -join ' + ') 'ok' } else { Set-Step 6 (T 'none (optional)') 'opt' }
    if ($S.Check) {
        if ([int]$S.Check.Errors -gt 0) { Set-Step 8 ((T '{0} error(s), {1} warning(s)') -f $S.Check.Errors, $S.Check.Warnings) 'warn' }
        elseif ([int]$S.Check.Warnings -gt 0) { Set-Step 8 ((T '{0} warning(s)') -f $S.Check.Warnings) 'todo' }
        else { Set-Step 8 (T 'all good') 'ok' }
    } else { Set-Step 8 (T 'not run yet') 'opt' }
    if ($S.Iso -and (Test-Path -LiteralPath $S.Iso)) { Set-Step 7 (T 'ISO ready') 'ok' }
    elseif ($S.Serviced) { Set-Step 7 ((T 'slipstreamed ({0}) - build the ISO') -f $S.Serviced.Build) 'todo' }
    else { Set-Step 7 (T 'to do') 'todo' }
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
    $note = if ($os -eq '11') { T 'Updates for Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 and 25H2 (x64, ARM64). On a Windows 10 PC the slipstream uses the DISM of the Windows ADK Deployment Tools, installed from Microsoft when needed.' }
            else { T 'Updates for Windows 10 1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 and LTSC 2021 (x64, x86, ARM64).' }
    if ($isoOs -and $isoOs -ne $os) { $note += ' ' + ((T 'The unpacked ISO is Windows {0} - pick a Windows {1} ISO and unpack it to switch.') -f $isoOs, $os) }
    $U.WinVerNote.Text = $note
    $U.GetIsoBtn.Content = (T 'Download Windows {0} from Microsoft') -f $os
    $U.CutoffRow.Visibility = if ($os -eq '10') { 'Visible' } else { 'Collapsed' }
    $U.CutoffNote.Text = if ($os -eq '10') { T '2025-10 is the last Windows 10 update Microsoft allows offline. ESU updates (Nov 2025+) come from Windows Update after setup on enrolled PCs.' }
                         else { T 'Windows 11: the newest updates in the Microsoft Update Catalog are used (21H2, which is out of servicing: its last ones, 2024-10).' }
}
# SHA-256 check on page 1: the last result (IsoCheck in the state) when it is for the file in the box.
function Get-IsoCheckFor([string]$Iso) {
    $c = $Script:S.IsoCheck
    if (-not $c -or -not $Iso) { return $null }
    try { $f = Get-Item -LiteralPath $Iso -ErrorAction Stop } catch { return $null }
    if ($f.PSIsContainer -or [string]$c.Key -ne (Get-IsoFileKey $f)) { return $null }
    return $c
}
# What to do about an ISO whose SHA-256 Microsoft does not list.
function Get-IsoAdvice($C) {
    $os = if ([string]$Script:Cfg.WinVersion -eq '11') { '11' } else { '10' }
    $t = @()
    if ($C -and $C.Online -eq $false) { $t += T 'microsoft.com could not be reached, so only the list in this program was used - check again when online, the newest ISOs may be on the page.' }
    if ($C -and $C.Subscription) { $t += T 'Its name is the one of a Visual Studio subscription or Volume Licensing download, which are original too but not on the public pages: compare the SHA-256 with the one shown on that portal.' }
    $t += (T 'An ISO made with the Media Creation Tool is built on the PC and is never listed, and an older ISO Microsoft no longer offers may be missing too. Otherwise it may have been modified: download an original Windows {0} ISO from Microsoft (button above) and use that one.') -f $os
    return ($t -join ' ')
}
# What page 1 and the question before unpacking say about a checked ISO: Text, its color, Note.
function Get-IsoCheckView($C) {
    $os = if ([string]$Script:Cfg.WinVersion -eq '11') { '11' } else { '10' }
    $n = @($C.SigChecked | Where-Object { $_ }).Count      # a list read back from state.json may be $null
    switch ([string]$C.Status) {
        'original' {
            $note = if ($C.Source -eq 'list') { (T 'Its SHA-256 is one Microsoft published on its download page (seen there on {0}).') -f $C.Listed }
                    else { (T 'Its SHA-256 is on Microsoft''s download page (checked {0}).') -f $C.When }
            return @{ Text = (T 'Original Microsoft ISO: {0} - {1}') -f $C.Product, $C.Label; Color = '#3DDC97'; Note = $note }
        }
        'mct' {
            return @{ Text = T 'Made with the Media Creation Tool - setup and boot files signed by Microsoft'; Color = '#5CC8FF'
                      Note = (T 'The Media Creation Tool builds the ISO on the PC from Microsoft''s download, so its SHA-256 is never in Microsoft''s list - that is normal. Its setup and boot files ({0} checked) carry Microsoft''s signature; the Windows image in it (install.esd) isn''t signed as a whole, so it isn''t covered.') -f $n }
        }
        'badsig' {
            return @{ Text = T 'Modified: files in this ISO are not signed by Microsoft'; Color = '#FF5C7A'
                      Note = (T 'Not signed by Microsoft: {0}. Download an original Windows {1} ISO from Microsoft (button above) and use that one.') -f (@($C.SigBad | Where-Object { $_ }) -join ', '), $os }
        }
        default {
            $note = @()
            if ($n) { $note += (T 'Its setup and boot files are signed by Microsoft ({0} checked), but the Windows image in it can''t be checked this way.') -f $n }
            $note += Get-IsoAdvice $C
            return @{ Text = T 'Not verified: the SHA-256 is not one Microsoft lists for its Windows 10 and 11 ISOs.'; Color = '#FFC857'; Note = ($note -join ' ') }
        }
    }
}
function Update-IsoCheck {
    $U = $Script:U
    $iso = ([string]$U.IsoBox.Text).Trim().Trim('"')
    if (-not $iso -or -not (Test-Path -LiteralPath $iso -PathType Leaf)) { $U.IsoCheckPanel.Visibility = 'Collapsed'; return }
    $U.IsoCheckPanel.Visibility = 'Visible'
    $c = Get-IsoCheckFor $iso
    $U.IsoHashBox.Visibility = if ($c) { 'Visible' } else { 'Collapsed' }
    if (-not $c) {
        $U.IsoCheckText.Text = T 'Not checked yet - the ISO is checked when you unpack it, or now with Check the ISO.'
        $U.IsoCheckText.Foreground = New-Brush '#E6EAF2'
        $U.IsoCheckNote.Text = ''
        return
    }
    $U.IsoHashBox.Text = [string]$c.Sha256
    $v = Get-IsoCheckView $c
    $U.IsoCheckText.Text = $v.Text
    $U.IsoCheckText.Foreground = New-Brush $v.Color
    $U.IsoCheckNote.Text = $v.Note
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
        Update-IsoCheck

        # 1 source
        $imgs = @($S.Images)
        if ($S.Family -and $imgs.Count) {
            $U.ImgInfo.Text = (T '{0}  -  build {1}  -  {2}  -  {3} edition(s)') -f $S.Family.Name, $imgs[0].Version, $S.Family.Arch, $imgs.Count
            $U.ImgNote.Text = if (-not $S.Family.Supported) { T 'No automatic updates for this build - drivers, signed packages, answer file and $OEM$ still work.' }
                              elseif ($S.Family.Cap -and (Get-FamilyOs $S.Family) -eq '10') { (T 'Updates up to {0} (the last month Microsoft allows offline for Windows 10).') -f $Cfg.Win10Cutoff }
                              elseif ($S.Family.Cap) { (T 'Its last updates ({0}) - this version is out of servicing.') -f $S.Family.Cap }
                              else { T 'Newest updates available in the Microsoft Update Catalog.' }
            if ($S.Family.Supported -and $S.Family.NeedsEkb) { $U.ImgNote.Text += ' ' + ((T 'The {0} enablement package is added too.') -f $(if ($S.Family.EkbFor) { $S.Family.EkbFor } else { '22H2' })) }
        } else { $U.ImgInfo.Text = T 'Nothing unpacked yet.'; $U.ImgNote.Text = '' }
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
            $U.DrvSum.Text = (T '{0} driver package(s), {1} storage/network for boot.wim and WinRE, about {2:N0} MB') -f $d.Count, $boot, $mb
        } else { $U.DrvSum.Text = T 'No drivers selected.' }

        # 5 signed
        $U.SignGrid.ItemsSource = (New-Table @('Name', 'InstallsFrom', 'Signed:int', 'Failed:int', 'INFs', 'Engine', 'When', 'Source') @(foreach ($x in @($S.Signed | Where-Object { $_ })) { , @($x.Name, $x.InstallDir, [int]$x.Signed, [int]$x.Failed, $(if ($x.OnlyThisPc) { (T 'this PC only ({0} kept)') -f @($x.Kept).Count } else { T 'all' }), $(if ($x.Engine) { [string]$x.Engine } else { 'Inf2Cat' }), $x.When, $x.Source) })).DefaultView
        Update-SignDest
        Update-SignEngine
        $cs = 'create'; $c = $null
        try { $cs = Get-CertStatus; $c = Get-StoreCert } catch { }
        $U.CertInfo.Text = switch ($cs) {
            'ready'  { (T 'Ready - {0}, valid until {1:yyyy-MM-dd} (backed up as DriverSigning.pfx)') -f $c.Subject, $c.NotAfter }
            'export' { T 'In this PC''s certificate store, not backed up yet - you will be asked for a password to save DriverSigning.pfx.' }
            'import' { T 'DriverSigning.pfx found - its password is asked when you sign.' }
            default  { T 'None yet - one is created the first time you sign (you choose its password).' }
        }

        # 6 answer file + oem
        $U.UnaCur.Text = if ($S.Unattend) { (T '{0}   (added {1})') -f $S.Unattend.Source, $S.Unattend.Added } else { T 'none' }
        if ($S.Oem -and $S.Oem.Source) {
            $U.OemCur.Text = [string]$S.Oem.Source
            $U.OemInfo.Text = Get-OemSummary ([string]$S.Oem.Source)
        } else { $U.OemCur.Text = T 'none'; $U.OemInfo.Text = '' }

        # 7 build
        if ($S.Iso -and (Test-Path -LiteralPath $S.Iso)) {
            $U.IsoInfo.Text = '{0}   ({1})' -f $S.Iso, (Format-Size (Get-Item -LiteralPath $S.Iso).Length)
            $h = "$($S.Iso).sha256"
            $U.IsoHash.Text = if (Test-Path -LiteralPath $h) { 'SHA-256  ' + ((Get-Content -LiteralPath $h -Raw) -split '\s')[0] } else { '' }
        } elseif ($S.Serviced) {
            $U.IsoInfo.Text = (T 'Slipstreamed on {0} - build {1}. Build the ISO next.') -f $S.Serviced.When, $S.Serviced.Build
            $U.IsoHash.Text = ''
        } else { $U.IsoInfo.Text = T 'No ISO built yet.'; $U.IsoHash.Text = '' }

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
        $U.ChkSum.Text = (T '{0} error(s), {1} warning(s), {2} check(s) passed   -   {3}') -f $c.Errors, $c.Warnings, $c.Passed, $c.When
        $U.ChkSum.Foreground = New-Brush $(if ([int]$c.Errors) { '#FF5C7A' } elseif ([int]$c.Warnings) { '#FFC857' } else { '#3DDC97' })
    } else { $U.ChkSum.Text = T 'Not run yet.'; $U.ChkSum.Foreground = New-Brush '#E6EAF2' }
    $nf = @($rows | Where-Object { $_.Fix }).Count
    $U.ChkFix.IsEnabled = $nf -gt 0
    $U.ChkFix.Content = if ($nf) { (T 'Apply {0} fix(es)') -f $nf } else { T 'Apply all fixes' }
    $fixed = $Script:S.Unattend -and $Script:S.Unattend.Fixed
    $U.ChkUndo.IsEnabled = [bool]$fixed
    $U.ChkSave.IsEnabled = [bool]$fixed
    $U.ChkNote.Text = if ($fixed) { (T 'The ISO uses a fixed copy of your answer file (fixed {0}). Save it to update your own file too.') -f $Script:S.Unattend.Fixed } else { '' }
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
    if (-not (Test-Path -LiteralPath $Dir)) { return (T 'folder not found') }
    if ($Script:OemCache -and $Script:OemCache[0] -eq "$Dir|$Script:LangNow") { return $Script:OemCache[1] }
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)
    $mb = ($files | Measure-Object -Property Length -Sum).Sum
    $parts = @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $txt = (T '{0} files, {1}   ({2})') -f $files.Count, (Format-Size ([double]$mb)), ($parts -join ', ')
    if (Test-Path -LiteralPath (Join-Path $Dir '$$\Setup\Scripts\SetupComplete.cmd')) { $txt += '   - ' + (T 'has SetupComplete.cmd') }
    $Script:OemCache = @("$Dir|$Script:LangNow", $txt)
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
    & $set $U.T_Osc $osc (T 'missing - downloaded automatically when you build the ISO')
    & $set $U.T_Inf $inf $(if ($eng -eq 'inf2cat') { T 'missing - downloaded automatically when you sign drivers' } else { T 'missing - downloaded only if the signing engine needs Inf2Cat as fallback' })
    & $set $U.T_Sign $sig (T 'missing - downloaded automatically when you sign drivers')
    & $set $U.T_Mkc $mkc $(if ($eng -eq 'makecat') { T 'missing - downloaded automatically when you sign drivers' } else { T 'missing - only needed for the MakeCat signing engine' })
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    & $set $U.T_Curl $(if (Test-Path -LiteralPath $curl) { $curl }) (T 'missing - PowerShell / BITS downloads are used')
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
        'makecat' { T 'Default. makecat.exe (Windows SDK) builds one catalog per driver folder with the hash of every file in it, so each file is hashed once - about 20 s for NVIDIA''s 3 GB Display.Driver instead of minutes. Compressed files (name.dl_) are hashed expanded, the way Windows checks them. MakeCat does not parse the INF: every catalog is checked with signtool afterwards, and a folder MakeCat cannot do goes to Inf2Cat.' }
        'libwdi'  { T 'Experimental. The catalog is built with the CryptCAT API of Windows itself, the way libwdi (Zadig) does it - nothing to download. One catalog per driver folder with the hash of every file in it (SHA-1). Checked with signtool afterwards; a folder it cannot do goes to Inf2Cat.' }
        'gencat'  { T 'Experimental. LINBIT generate-cat-file (GPL-2.0): its source is downloaded from GitHub (one pinned commit, SHA-256 checked) and built inside WSL - needs WSL with a Linux distribution that has gcc and make. One catalog per driver folder; Inf2Cat signs when WSL or the build is missing.' }
        default   { T 'Microsoft''s standard tool from the Windows Driver Kit: it parses every INF and checks it against every file of the package. The proven choice, but slow on big packages - the options below make it faster.' }
    }
}
function Update-SignDest {
    $n = ConvertTo-PackageName $Script:U.SignName.Text
    $Script:U.SignDest.Text = (T 'installs from {0} during Windows setup') -f "C:\Drivers\$n"
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
    if ($old) { $SubText += ' ' + ((T '{0} older version(s) of drivers that are here in a newer version too are unticked (column Older) - Windows uses the newest one.') -f $old) }
    $Script:PickArch = $arch
    $D.U.PTitle.Text = $Title
    $D.U.PSub.Text = $SubText
    $D.U.PGrid.Add_AutoGeneratingColumn({ param($s, $e) if ($e.PropertyName -eq 'Use') { $e.Cancel = $true } else { $e.Column.IsReadOnly = $true } })
    $D.U.PGrid.ItemsSource = $Script:PickTable.DefaultView
    $count = { $c = @($Script:PickTable.Select('Use = true')).Count; $Script:PickD.U.PCount.Text = (T '{0} of {1} ticked') -f $c, $Script:PickTable.Rows.Count }
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
        'import' { T 'DriverSigning.pfx was found next to this tool. Enter its password to load your signing certificate.' }
        'export' { T 'Your signing certificate is in this PC''s store but has no backup yet. Choose a password to save it as DriverSigning.pfx - you need it to sign again after reinstalling Windows.' }
        default  { T 'A new self-signed code-signing certificate will be created. Choose a password for its backup file DriverSigning.pfx - you need it to sign again after reinstalling Windows.' }
    }
    if ($Mode -eq 'import') { $D.U.Pw2Panel.Visibility = 'Collapsed' }
    $D.U.PwOk.Add_Click({
        $a = $Script:PwD.U.Pw1.Password
        if (-not $a) { $Script:PwD.U.PwErr.Text = T 'Enter a password.'; return }
        if ($Script:PwMode -ne 'import' -and $a -cne $Script:PwD.U.Pw2.Password) { $Script:PwD.U.PwErr.Text = T 'The passwords do not match.'; return }
        $Script:PwD.W.DialogResult = $true
    })
    $D.W.Add_ContentRendered({ [void]$Script:PwD.U.Pw1.Focus() })
    if ($D.W.ShowDialog()) { return $D.U.Pw1.SecurePassword }
    return $null
}
#endregion

#region ---------------------------------------------------------------- page actions
function Test-Unpacked {
    if ($Script:S.Unpacked) { return $true }
    Show-Msg (T 'Unpack an ISO first (page 1).')
    $Script:U.Nav1.IsChecked = $true
    return $false
}
# The check of $Iso first (skipped for a file found original, or made with the Media Creation Tool, before), then
# $Then - for any other ISO only when the user goes on anyway ($Ask), once per ISO while the program is open.
function Invoke-IsoCheckThen([string]$Iso, [string]$Ask, [scriptblock]$Then) {
    $Script:IsoCheckPath = $Iso; $Script:IsoAsk = $Ask; $Script:IsoThen = $Then
    if (-not $Script:IsoAccepted) { $Script:IsoAccepted = @{} }
    $c = Get-IsoCheckFor $Iso
    if ($c -and ([string]$c.Status -in 'original', 'mct' -or $Script:IsoAccepted[[string]$c.Key])) { $Script:IsoThen = $null; & $Then; return }
    Start-Work 'CheckIso' @{ Iso = $Iso } { Complete-IsoCheck }
}
function Complete-IsoCheck {
    $then = $Script:IsoThen; $Script:IsoThen = $null
    if (-not $then) { return }
    $c = Get-IsoCheckFor $Script:IsoCheckPath
    if (-not $c) { return }
    if ([string]$c.Status -notin 'original', 'mct') {
        $v = Get-IsoCheckView $c
        $msg = $v.Text + "`n`n" + $v.Note + "`n`n" + $Script:IsoAsk
        if (-not (Confirm-Ui $msg 'Warning')) { return }
        $Script:IsoAccepted[[string]$c.Key] = $true
    }
    & $then
}
function Invoke-IsoCheckClick {
    $iso = $Script:U.IsoBox.Text.Trim().Trim('"')
    if (-not $iso -or -not (Test-Path -LiteralPath $iso -PathType Leaf)) { Show-Msg (T 'Choose an existing .iso file first.') 'Warning'; return }
    $Script:IsoThen = $null
    Start-Work 'CheckIso' @{ Iso = $iso }
}
function Invoke-UnpackClick {
    $iso = $Script:U.IsoBox.Text.Trim().Trim('"')
    if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { Show-Msg (T 'Choose an existing .iso file first.') 'Warning'; return }
    if ($Script:S.Unpacked -and (Test-Path -LiteralPath (Join-Path $Script:P.Media 'sources'))) {
        if (-not (Confirm-Ui ((T 'The work folder already has unpacked media ({0}). Replace it with a fresh copy of this ISO?') -f (Split-Path ([string]$Script:S.SourceIso) -Leaf)))) { return }
    }
    $Script:UnpackIso = $iso
    Invoke-IsoCheckThen $iso (T 'Unpack this ISO anyway?') {
        Start-Work 'Unpack' @{ Iso = $Script:UnpackIso; NoAsk = $true } { if (@($Script:S.Images).Count -gt 1) { $Script:U.Nav2.IsChecked = $true } }
    }
}
function Invoke-HostDriversClick {
    Start-Work 'ScanHost' @{} {
        $items = @($Script:Sync.Result)
        if ($items.Count -eq 0) { return }
        $pick = @(Show-DriverPicker $items (T 'Drivers installed on this PC') (T 'Third-party drivers exported from this PC. Ticked ones are slipstreamed into the ISO.'))
        Start-Work 'CommitHost' @{ Pick = $pick }
    }
}
function Invoke-ImportDriversClick {
    $start = @(Find-DriverBackupFolders) | Select-Object -First 1
    $dir = Select-Folder (T 'Pick the drivers folder - Drivers-Backup made by Drivers.cmd, a folder from another PC or a vendor pack. All subfolders are scanned.') $start
    if (-not $dir) { return }
    $Script:ImportDir = $dir
    Start-Work 'ScanFolder' @{ Dir = $dir } {
        $items = @($Script:Sync.Result)
        if ($items.Count -eq 0) { Show-Msg (T 'No .inf drivers in that folder.') 'Warning'; return }
        $pick = @(Show-DriverPicker $items ((T 'Drivers in {0}') -f $Script:ImportDir) (T 'Drivers built for another architecture than the ISO are unticked and left out.'))
        if ($pick.Count -gt 0) { Start-Work 'CommitImport' @{ Dir = $Script:ImportDir; Pick = $pick } }
    }
}
function Invoke-SignClick {
    $src = $Script:U.SignSrc.Text.Trim().Trim('"')
    if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Container)) { Show-Msg (T 'Choose the driver folder first (for example the folder NVCleanstall extracted).') 'Warning'; return }
    $hasInf = Get-ChildItem -LiteralPath $src -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hasInf) { Show-Msg (T 'There are no .inf files in that folder or its subfolders.') 'Warning'; return }
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
    if (@($Script:S.Selected).Count -eq 0) { Show-Msg (T 'Tick at least one edition first.'); $Script:U.Nav2.IsChecked = $true; return }
    if ($Script:S.Serviced -and -not (Confirm-Ui ((T 'This media was already slipstreamed on {0}. For a clean result unpack the ISO again (page 1). Slipstream again anyway?') -f $Script:S.Serviced.When) 'Warning')) { return }
    if (@($Script:S.Updates).Count -eq 0 -and $Script:S.Family.Supported -and
        -not (Confirm-Ui (T 'No updates are downloaded (page 3). Continue with drivers and options only?'))) { return }
    Start-Work 'Service' @{} { $Script:U.Nav7.IsChecked = $true }
}
function Invoke-BuildClick {
    if (-not (Test-Unpacked)) { return }
    if (-not $Script:S.Serviced -and -not (Confirm-Ui (T 'The media has not been slipstreamed yet. Build the ISO anyway (drivers, updates and options are then missing)?') 'Warning')) { return }
    Start-Work 'Build' @{ Out = $Script:U.OutBox.Text.Trim().Trim('"') }
}
function Invoke-FixClick {
    $fixes = @($Script:CheckRows | Where-Object { $_.Fix } )
    if ($fixes.Count -eq 0) { Show-Msg (T 'Nothing to fix automatically - run the check first. Findings without a fix need a change on the page they mention.'); return }
    $txt = ($fixes | ForEach-Object { '- ' + $_.FixText } | Sort-Object -Unique) -join "`n"
    if (-not (Confirm-Ui ((T 'Apply these fixes? They change the copies that go into the ISO, not your own files.') + "`n`n" + $txt))) { return }
    Start-Work 'Fix' @{ Fixes = @($fixes | ForEach-Object { [string]$_.Fix } | Sort-Object -Unique) } { Show-CheckResults }
}
function Invoke-RunAllClick {
    $iso = $Script:U.IsoBox.Text.Trim().Trim('"')
    if (-not $iso) { $iso = [string]$Script:S.SourceIso }
    if (-not $iso -or -not (Test-Path -LiteralPath $iso)) { Show-Msg (T 'Choose the source ISO on page 1 first.') 'Warning'; $Script:U.Nav1.IsChecked = $true; return }
    $yes = T 'yes'; $no = T 'no'
    $lines = @((T 'Source: {0}') -f (Split-Path $iso -Leaf))
    $lines += (T 'Editions: {0}') -f $(if (@($Script:S.Selected).Count) { (T '{0} ticked') -f @($Script:S.Selected).Count } else { T 'asked after unpacking' })
    $lines += (T 'Drivers: {0}   Signed packages: {1}') -f @($Script:S.Drivers).Count, @($Script:S.Signed | Where-Object { $_ }).Count
    $lines += (T 'Answer file: {0}   $OEM$: {1}') -f $(if ($Script:S.Unattend) { $yes } else { $no }), $(if ($Script:S.Oem) { $yes } else { $no })
    if (-not (Confirm-Ui ((T 'Run everything now? It takes 30-90 minutes - the PC is kept awake until it is done.') + "`n`n" + ($lines -join "`n")))) { return }
    $Script:RunAllArgs = @{ Iso = $iso; Out = $Script:U.OutBox.Text.Trim().Trim('"') }
    $unpacks = (-not $Script:S.Unpacked) -or $Script:S.Serviced -or ($iso -ne [string]$Script:S.SourceIso)   # as Invoke-RunAll decides
    if (-not $unpacks) { Start-Work 'All' $Script:RunAllArgs; return }
    Invoke-IsoCheckThen $iso (T 'Run everything with this ISO anyway?') { Start-Work 'All' $Script:RunAllArgs }
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
    $Script:IsoAccepted = @{}
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

    $Script:ThemeNow = Get-ThemeName          # the window is built in the saved theme, font, text size and language
    $Script:LangNow = Get-UiLanguage
    $M = New-Xaml $Script:XMain
    $Script:W = $M.W; $Script:U = $M.U; $Script:UiTexts = $M.Texts
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
    $U.LangAuto.Tag = 'auto'
    foreach ($l in (Get-LanguageList)) { $U[$l.Button].Tag = $l.Code }
    foreach ($n in @('LangAuto') + @(Get-LanguageList | ForEach-Object { $_.Button })) {
        $U[$n].Add_Click({ $Script:Cfg.UiLanguage = [string]$this.Tag; Save-Settings; Set-UiLanguage })
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
                Show-Msg ((T 'While a job runs (unpack, download, sign, slipstream, build), Windows Defender does not scan the work folder ({0}). The exclusion is removed when the job ends, and at the next start if the program was closed during a job. Everything in there comes from Microsoft, your drivers and this tool - do not put other downloads in that folder.') -f $Script:P.Work) 'Information'
            }
            if ($this.Tag -eq 'SignOnlyThisPc' -and $this.IsChecked) {
                Show-Msg (T 'Use this only when the ISO is for this PC. INF files for other hardware are removed from the signed copy, so the driver installs only on hardware that matches this PC. NVIDIA''s own setup.exe may refuse to run from that copy - pnputil installs the driver anyway. Sign the package again for it to take effect.') 'Information'
            }
            if ($this.Tag -eq 'Boot2023' -and $this.IsChecked) {
                Show-Msg (T 'With Secure Boot on, this ISO only boots on PCs whose UEFI already trusts ''Windows UEFI CA 2023''. Older firmware needs that Secure Boot update first (or Secure Boot off). The image also needs a 2024-04 or newer update.') 'Warning'
            }
        })
    }
    $U.CutoffBox.Add_LostFocus({
        $v = $Script:U.CutoffBox.Text.Trim()
        if ($v -match '^\d{4}-\d{2}$') { $Script:Cfg.Win10Cutoff = $v; Save-Settings }
        else { $Script:U.CutoffBox.Text = [string]$Script:Cfg.Win10Cutoff; if ($v) { Show-Msg (T 'Use the YYYY-MM format, e.g. 2025-10.') } }
    })
    $U.SignJobsBox.Add_LostFocus({
        $v = $Script:U.SignJobsBox.Text.Trim()
        if (-not $v) { $Script:Cfg.SignJobs = 0; Save-Settings }
        elseif ($v -match '^[1-8]$') { if ([int]$v -ne (Get-SignJobs)) { $Script:Cfg.SignJobs = [int]$v; Save-Settings } }
        else { Show-Msg (T 'Use a number from 1 to 8 (or leave it empty for the number of processor cores, up to 8).') }
        $Script:U.SignJobsBox.Text = [string](Get-SignJobs)
    })
    $U.EdJobsBox.Add_LostFocus({
        $v = $Script:U.EdJobsBox.Text.Trim()
        $now = (Get-EditionJobs 4 1e6).Wanted
        if (-not $v) { $Script:Cfg.ParallelEditions = 0; Save-Settings }
        elseif ($v -match '^[1-4]$') { if ([int]$v -ne $now) { $Script:Cfg.ParallelEditions = [int]$v; Save-Settings } }
        else { Show-Msg (T 'Use a number from 1 to 4 (or leave it empty: 2 on 4+ processor cores, 3 on 8+).') }
        $Script:U.EdJobsBox.Text = [string](Get-EditionJobs 4 1e6).Wanted
    })

    # 1 source
    $U.IsoBrowse.Add_Click({
        $start = if ($Script:S.SourceIso) { Split-Path ([string]$Script:S.SourceIso) -Parent } else { Join-Path $env:USERPROFILE 'Downloads' }
        $f = Select-File ((T 'Select a Windows {0} ISO') -f $(if ($Script:Cfg.WinVersion -eq '11') { '11' } else { '10' })) ((T 'ISO images') + ' (*.iso)|*.iso') $start
        if ($f) { $Script:U.IsoBox.Text = $f }
    })
    $U.UnpackBtn.Add_Click({ Invoke-UnpackClick })
    $U.IsoCheckBtn.Add_Click({ Invoke-IsoCheckClick })
    $U.IsoBox.Add_TextChanged({ if (-not $Script:Loading) { Update-IsoCheck } })
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
        if ($nums.Count -eq 0) { Show-Msg (T 'Select the drivers to remove in the list first (Ctrl+click for several).'); return }
        Remove-DriverEntries $nums; Update-Ui
    })
    $U.DrvClear.Add_Click({
        if (@($Script:S.Drivers).Count -and (Confirm-Ui (T 'Remove every selected driver?'))) {
            Remove-Item -LiteralPath $Script:P.DrvSel -Recurse -Force -ErrorAction SilentlyContinue
            $Script:S.Drivers = @(); Save-State; Update-Ui
        }
    })
    # 5 signed drivers
    $U.SignBrowse.Add_Click({
        $d = Select-Folder (T 'Pick the modded driver folder (e.g. the folder NVCleanstall extracted). All subfolders are scanned.') $Script:U.SignSrc.Text
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
        if ($names.Count -eq 0) { Show-Msg (T 'Select a package in the list first.'); return }
        foreach ($n in $names) { Remove-SignedPackage $n }
        Write-Ok "Removed: $($names -join ', ') (taken out of the media at the next build)"
        Update-Ui
    })
    # 6 answer file + oem
    $U.UnaPick.Add_Click({
        $f = Select-File (T 'Select your autounattend.xml') ((T 'Answer files') + ' (*.xml)|*.xml') (Join-Path $env:USERPROFILE 'Downloads')
        if ($f) { try { Set-UnattendFile $f } catch { Show-Msg $_.Exception.Message 'Error' }; Update-Ui }
    })
    $U.UnaGen.Add_Click({ Start-Process $Script:GeneratorUrl })
    $U.UnaRemove.Add_Click({ Clear-UnattendFile; Update-Ui })
    $U.OemPick.Add_Click({
        $start = if ($Script:S.Oem) { [string]$Script:S.Oem.Source } else { $null }
        $d = Select-Folder (T 'Pick your $OEM$ folder (the one that contains $1 and/or $$)') $start
        if ($d) { $Script:OemCache = $null; Set-OemFolder $d; Update-Ui }
    })
    $U.OemOpen.Add_Click({ if ($Script:S.Oem) { Open-Path ([string]$Script:S.Oem.Source) } })
    $U.OemRemove.Add_Click({ Set-OemFolder $null; Update-Ui })
    # 7 build
    $U.OutBrowse.Add_Click({
        $d = New-Object Microsoft.Win32.SaveFileDialog
        $d.Filter = (T 'ISO image') + ' (*.iso)|*.iso'; $d.FileName = if ($Script:S -and $Script:S.Family) { 'Win' + (Get-FamilyOs $Script:S.Family) + '_custom.iso' } else { 'Windows_custom.iso' }
        if ($d.ShowDialog($Script:W)) { $Script:U.OutBox.Text = $d.FileName }
    })
    $U.SvcBtn.Add_Click({ Invoke-ServiceClick })
    $U.BuildBtn.Add_Click({ Invoke-BuildClick })
    $U.OpenOut.Add_Click({
        if ($Script:S.Iso -and (Test-Path -LiteralPath $Script:S.Iso)) { Start-Process explorer.exe "/select,`"$($Script:S.Iso)`"" } else { Open-Path $Script:P.Output }
    })
    # 8 options
    $U.WorkBrowse.Add_Click({ $d = Select-Folder (T 'Pick or create the work folder (NTFS, no spaces, ~30 GB free)') $Script:Cfg.WorkDir; if ($d) { $Script:U.WorkBox.Text = $d } })
    $U.WorkApply.Add_Click({
        $w = $Script:U.WorkBox.Text.Trim().Trim('"').TrimEnd('\')
        if (-not $w) { return }
        if ($w -match '\s' -and -not (Confirm-Ui (T 'The path has spaces - a short path like D:\W10U is safer for DISM. Use it anyway?') 'Warning')) { return }
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
        $names = @{ Updates = (T 'downloaded updates'); Media = (T 'unpacked media'); Output = (T 'built ISOs'); Signed = (T 're-signed driver copies'); Drivers = (T 'copied drivers')
                    Extra = (T 'answer file copy and check results'); Logs = (T 'logs'); All = (T 'EVERYTHING in the work folder') }
        $what = @(T 'mounted images and temp files') + @($a.Keys | Where-Object { $a[$_] } | ForEach-Object { $names[$_] })
        if (Confirm-Ui ((T 'Delete: {0}?') -f ($what -join ', ')) 'Warning') { Start-Work 'Clean' $a }
    })
    $U.DefBtn.Add_Click({
        if (-not (Confirm-Ui (T 'Restore the default options? The work folder is kept.'))) { return }
        $keep = $Script:Cfg.WorkDir; $last = $Script:Cfg.LastDriverFolder; $lang = $Script:Cfg.UiLanguage
        $Script:Cfg = Get-DefaultSettings; $Script:Cfg.WorkDir = $keep; $Script:Cfg.LastDriverFolder = $last; $Script:Cfg.UiLanguage = $lang
        Save-Settings; Update-Ui; Write-Ok 'Default options restored.'
    })
    # install check
    $U.ChkBtn.Add_Click({ Start-Work 'Check' @{} { Show-CheckResults } })
    $U.ChkFix.Add_Click({ Invoke-FixClick })
    $U.ChkSave.Add_Click({
        if (-not (Test-Path -LiteralPath $Script:P.Unattend)) { Show-Msg (T 'There is no answer file yet (page 6).'); return }
        $d = New-Object Microsoft.Win32.SaveFileDialog
        $d.Filter = (T 'Answer file') + ' (*.xml)|*.xml'; $d.FileName = 'autounattend.xml'
        if ($Script:S.Unattend -and $Script:S.Unattend.Source) { $d.InitialDirectory = Split-Path ([string]$Script:S.Unattend.Source) -Parent }
        if ($d.ShowDialog($Script:W)) { Copy-Item -LiteralPath $Script:P.Unattend -Destination $d.FileName -Force; Write-Ok "Saved: $($d.FileName)" }
    })
    $U.ChkUndo.Add_Click({
        $bak = Join-Path $Script:P.Work 'autounattend.original.xml'
        if (-not (Test-Path -LiteralPath $bak)) { Show-Msg (T 'No answer file fixes to undo.'); return }
        if (-not (Confirm-Ui (T 'Put the answer file back the way it was before the fixes?'))) { return }
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
            $r = [Windows.MessageBox]::Show($Script:W, ((T '''{0}'' is still running. Closing now can leave a mounted image behind (run Clean up next time). Close anyway?') -f $Script:JobLabel), $Script:AppTitle, 'YesNo', 'Warning')
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
