@echo off
:: ===========================================================================
::  Win10-ISO-Updater.cmd  (v2.1.1)  -  one file, graphical interface
::  - unpacks a Windows 10 ISO and detects its build
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
title Win10 ISO Updater
fltmc >nul 2>&1 && goto :admin_ok
echo Requesting administrator rights...
set "W10U_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:W10U_SELF -Verb RunAs"
exit /b

:admin_ok
set "W10U_SELF=%~f0"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
echo Starting Win10 ISO Updater v2.1.1 ...  (this window hides when the program opens)
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

$Script:AppName      = 'Win10-ISO-Updater'
$Script:AppVersion   = '2.1.1'
$Script:Root         = Split-Path -Parent $env:W10U_SELF
$ToolsDir            = Join-Path $Script:Root 'tools'
$IsoPath             = $null
$Script:NoAsk        = $false
$Script:SettingsFile = Join-Path $Script:Root 'Win10-ISO-Updater.settings.json'
$Script:SignDir      = Join-Path $Script:Root 'signing'
$Script:CertSubject  = 'CN=Custom Driver Signing'
$Script:GeneratorUrl = 'https://github.com/j0p3s/autounattended-generator'
$Script:IsoPageUrl   = 'https://www.microsoft.com/software-download/windows10ISO'
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
        ParallelBoot     = $true
        BootSkipPE       = $false
        DefenderExclude  = $false
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
function Get-UpdateFiles {
    $h = @{ SSU = @(); LCU = @(); EKB = @(); SAFEOS = @(); SETUP = @(); NET = @(); NET481 = @() }
    $seenLeaf = @{}
    foreach ($u in @($Script:S.Updates)) {
        foreach ($f in @($u.Files)) {
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
    $Script:SavedFiles = @{}
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
        if ($key -match '/IMAGE/INDEX' -and [int]$val -gt $img.Count) {
            Write-Warn "autounattend.xml installs image INDEX $val but the new install.wim has $($img.Count) edition(s)."
        } elseif ($key -match '/IMAGE/INDEX') {
            Write-Info "autounattend.xml picks index $val = $(($img | Where-Object { $_.ImageIndex -eq [int]$val }).ImageName)"
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
    $set = [pscustomobject]@{ Folder = $null; Singles = @(); Count = @($Infs).Count }
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

function Set-BootLabel([string]$Text) { if ($Script:Sync) { $Script:Sync.Label = $Text } }
# ---- boot.wim (WinPE + Setup). Runs in its own runspace while install.wim is serviced
# (Options: "Update boot.wim at the same time"), or inline. Returns what the media step needs.
function Invoke-BootWimService($Ctx) {
    $res = [pscustomobject]@{ ExSaved = $false; Count = 0 }
    Write-Title 'Updating boot.wim (WinPE / Setup)'
    Copy-Item -LiteralPath (Join-Path $Ctx.Media 'sources\boot.wim') -Destination $Ctx.BootSt -Force
    (Get-Item -LiteralPath $Ctx.BootSt -Force).Attributes = 'Normal'
    $bootCount = @(Get-WindowsImage -ImagePath $Ctx.BootSt).Count
    $res.Count = $bootCount
    $upd = $Ctx.Upd
    for ($b = 1; $b -le $bootCount; $b++) {
        Set-BootLabel "boot.wim $b/$bootCount"
        if ($Ctx.SkipPE -and $b -eq 1 -and $bootCount -ge 2) {
            Write-Step "boot.wim index 1 of $bootCount (Windows PE) - kept as it is (option)"
            Export-Img $Ctx.BootSt $b $Ctx.BootFin
            continue
        }
        Write-Step "boot.wim index $b of $bootCount"
        Mount-Img $Ctx.BootSt $b $Ctx.MountPE
        foreach ($x in @($upd.SSU)) { Set-BootLabel "boot.wim $b/$bootCount servicing stack"; Add-Pkg $Ctx.MountPE $x 'Servicing stack' -Soft }
        foreach ($x in @($upd.LCU)) {
            Set-BootLabel "boot.wim $b/$bootCount cumulative update"
            Add-Pkg $Ctx.MountPE $x 'Servicing stack via LCU' -IgnoreHex @('8007007E', '800F081E') -Soft
            Add-Pkg $Ctx.MountPE $x 'Cumulative update' -IgnoreHex @('800F081E') -Soft
        }
        Set-BootLabel "boot.wim $b/$bootCount drivers"
        Add-BootDrivers $Ctx.MountPE $Ctx.BootSet $Ctx.Fu 'WinPE'
        Set-BootLabel "boot.wim $b/$bootCount cleanup"
        Invoke-ImageCleanup $Ctx.MountPE 'WinPE'
        if (Test-Path -LiteralPath (Join-Path $Ctx.MountPE 'sources\setup.exe')) {
            Copy-Item -LiteralPath (Join-Path $Ctx.MountPE 'sources\setup.exe') -Destination (Join-Path $Ctx.BfDir 'setup.exe') -Force
            foreach ($n in 'bootmgfw.efi', 'bootmgr.efi', 'boot.stl') {
                $f = Join-Path $Ctx.MountPE "Windows\Boot\EFI\$n"
                if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $Ctx.BfDir $n) -Force }
            }
        }
        if ($Ctx.Boot2023 -and -not $res.ExSaved) { $res.ExSaved = [bool](Save-BootFiles2023 $Ctx.MountPE $Ctx.ExDir) }
        Set-BootLabel "boot.wim $b/$bootCount saving"
        Dismount-Img $Ctx.MountPE -Commit
        Export-Img $Ctx.BootSt $b $Ctx.BootFin
    }
    Set-BootLabel ''
    return $res
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
function Start-BootWimJob($Ctx) {
    $engine = Get-EngineText
    if (-not $engine) { return $null }
    $sync = [hashtable]::Synchronized(@{ Queue = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Pct = -1; Status = ''; Label = 'boot.wim starting' })
    $p = @{}; foreach ($k in $Script:P.Keys) { $p[$k] = $Script:P[$k] }
    $p.Scratch = Join-Path $Script:P.Temp 'scratch-pe'
    $rs = [runspacefactory]::CreateRunspace([Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $sync)
    $rs.SessionStateProxy.SetVariable('IsWorker', $false)       # no Yes/No questions from here
    $init = [PowerShell]::Create(); $init.Runspace = $rs
    $why = $null
    try { [void]$init.AddScript($engine).Invoke(); if ($init.HadErrors) { $why = [string]$init.Streams.Error[0] } }
    catch { $why = $_.Exception.Message }
    $init.Dispose()
    if ($why) { Add-Log "boot.wim background worker: $why"; $rs.Dispose(); return $null }
    $log = Join-Path $Script:P.Logs 'engine-boot.log'
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    foreach ($kv in @{ P = $p; Cfg = $Script:Cfg; S = $Script:S; Dism = $Script:Dism; LogFile = $log; DismLog = (Join-Path $Script:P.Logs 'dism-boot.log') }.GetEnumerator()) {
        $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
    }
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddCommand('Invoke-BootWimService').AddParameter('Ctx', $Ctx)
    $job = [pscustomobject]@{ Ps = $ps; Rs = $rs; Handle = $ps.BeginInvoke(); Sync = $sync; Log = $log; Start = (Get-Date) }
    if ($Script:Sync) { $Script:Sync.SideSync = $sync }
    Write-Info 'boot.wim is updated at the same time in the background - its log follows after install.wim.'
    return $job
}
function Receive-BootWimLines($Job) {
    $it = $null
    while ($Job.Sync.Queue.TryDequeue([ref]$it)) {
        if ($Script:Sync) { $Script:Sync.Queue.Enqueue($it) } else { Microsoft.PowerShell.Utility\Write-Host $it[1] }
    }
}
function Close-BootWimJob($Job) {
    if ($Script:Sync) { $Script:Sync.SideSync = $null }
    if ($Job.Log -and (Test-Path -LiteralPath $Job.Log) -and $Script:LogFile) {
        try {
            Add-Content -LiteralPath $Script:LogFile -Value ("---- boot.wim (background) log`r`n" + [IO.File]::ReadAllText($Job.Log) + "---- end of boot.wim log") -Encoding UTF8
            Remove-Item -LiteralPath $Job.Log -Force
        } catch { }
    }
    try { $Job.Ps.Dispose() } catch { }
    try { $Job.Rs.Dispose() } catch { }
}
# Waits for the background boot.wim job, shows its log, returns its result (or throws its error).
function Wait-BootWimJob($Job) {
    while (-not $Job.Handle.IsCompleted) {
        Receive-BootWimLines $Job
        $pct = [double]$Job.Sync.Pct
        $st = "waiting for $($Job.Sync.Label)"
        if ($pct -ge 0) { $st += (' {0:N0}%' -f $pct) }
        Write-Host $st -NoNewline
        Start-Sleep -Milliseconds 300
    }
    Receive-BootWimLines $Job
    if ($Script:Sync) { $Script:Sync.Status = '' }
    $err = $null; $out = $null
    try { $out = @($Job.Ps.EndInvoke($Job.Handle)) } catch { $err = $_.Exception }
    if (-not $err -and $Job.Ps.HadErrors -and $Job.Ps.Streams.Error.Count) { $err = $Job.Ps.Streams.Error[0].Exception }
    Receive-BootWimLines $Job
    Close-BootWimJob $Job
    if ($err) {
        $m = $err.Message
        if ($err.InnerException) { $m = $err.InnerException.Message }
        throw "boot.wim: $m"
    }
    Write-Ok ('boot.wim done (ran alongside install.wim, {0:mm\:ss} in total)' -f ((Get-Date) - $Job.Start))
    return @($out | Where-Object { $_ -and $_.PSObject.Properties['ExSaved'] })[0]
}
# Stops the background job after an error (its dism.exe is ended too, so the mounts can be discarded).
function Stop-BootWimJob($Job) {
    if (-not $Job) { return }
    try { [void]$Job.Ps.BeginStop($null, $null) } catch { }
    try {
        $rx = [regex]::Escape((Split-Path $Job.Log -Parent | Split-Path -Parent)) + '.*(boot_stage|boot_final|mnt\\pe|scratch-pe)'
        Get-CimInstance Win32_Process -Filter "Name='dism.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -match $rx } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
    $t = Get-Date
    while (-not $Job.Handle.IsCompleted -and ((Get-Date) - $t).TotalSeconds -lt 60) { Start-Sleep -Milliseconds 300 }
    Receive-BootWimLines $Job
    Close-BootWimJob $Job
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
    $bfDir    = Join-Path $P.Temp 'bootfiles'
    $exDir    = Join-Path $P.Temp 'boot2023'
    $hasDrv   = @($S.Drivers).Count -gt 0 -and (Test-Path -LiteralPath $P.DrvSel)
    $bootInfs = if ($Cfg.BootDrivers -and $hasDrv) { Get-BootDriverInfs } else { @() }
    $fu       = if ($Cfg.ForceUnsigned) { ' /ForceUnsigned' } else { '' }
    $lcuTip   = 'If this is a Windows 10 update newer than 2025-10, Microsoft blocks offline ESU integration - set the month back in Options.'
    New-Item -ItemType Directory -Force -Path $bfDir | Out-Null
    $bootSet  = New-BootDriverSet $bootInfs (Join-Path $P.Temp 'bootdrivers')
    $bootCtx  = @{
        Upd = $upd; Media = $P.Media; MountPE = $P.MountPE; BfDir = $bfDir; ExDir = (Join-Path $P.Temp 'boot2023_pe')
        BootSt = (Join-Path $P.Temp 'boot_stage.wim'); BootFin = (Join-Path $P.Temp 'boot_final.wim')
        BootSet = $bootSet; Fu = $fu; Boot2023 = [bool]$Cfg.Boot2023; SkipPE = [bool]$Cfg.BootSkipPE
    }

    $all = @($S.Images | ForEach-Object { [int]$_.Index })
    $exportIdx = @(if ($Cfg.KeepOnlySelected) { $S.Selected } else { $all })
    $reReady = $false; $exSaved = $false
    $bootJob = $null; $bootRes = $null

    try {
        # ---- boot.wim in the background (it does not depend on install.wim)
        if ($Cfg.ParallelBoot) {
            $bootJob = Start-BootWimJob $bootCtx
            if (-not $bootJob) { Write-Warn 'The background worker for boot.wim could not start - boot.wim is updated after install.wim.' }
        }

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
                            Add-BootDrivers $P.MountRE $bootSet $fu 'WinRE'
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

        # ---- boot.wim: join the background job, or run it now
        if ($bootJob) { $j = $bootJob; $bootJob = $null; $bootRes = Wait-BootWimJob $j }
        else { $bootRes = Invoke-BootWimService $bootCtx }
        if ($bootRes -and $bootRes.ExSaved) { $exDir = $bootCtx.ExDir; $exSaved = $true }   # WinPE's 2023 boot files are preferred, as before
    } catch {
        Write-Err $_.Exception.Message
        if ($bootJob) { Write-Warn 'Stopping the boot.wim background job...'; Stop-BootWimJob $bootJob }
        Write-Warn 'Discarding mounted images - your unpacked media was not changed.'
        Clear-Mounts
        throw
    }
    $bootFin = $bootCtx.BootFin


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
    $label = if ($S.Family -and $S.Family.Label) { $S.Family.Label } else { 'WIN10_CUSTOM' }
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
    New-Item -ItemType Directory -Force -Path $P.Output | Out-Null
    $iso = Join-Path $P.Output ('Win10_{0}_{1}_{2}_{3:yyyyMMdd}.iso' -f $tag, $build, $arch, (Get-Date))
    if ($OutIso) { $iso = Resolve-OutIso $OutIso $iso }
    Write-Info "Output: $iso"
    New-Item -ItemType Directory -Force -Path (Split-Path $iso -Parent) | Out-Null
    if (Test-Path -LiteralPath $iso) { Remove-Item -LiteralPath $iso -Force }

    if (Test-Path -LiteralPath $etfs) { $bootdata = "-bootdata:2#p0,e,b$(Q $etfs)#pEF,e,b$(Q $efi)" }
    else { $bootdata = "-bootdata:1#pEF,e,b$(Q $efi)"; Write-Info 'No etfsboot.com - building a UEFI-only ISO.' }
    Write-Step 'Writing ISO (BIOS + UEFI, UDF)'
    $code = Invoke-Exe $osc ("-m -o -u2 -udfver102 -l$label $bootdata $(Q $m) $(Q $iso)") -MergeErr
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
# that all point at the same ~1 GB of files). Its output is read live, so the status line shows
# what it is doing and for how long, even while it prints nothing.
function Invoke-Inf2Cat([string]$Exe, [string]$Dir, [string]$Os, [string]$Label) {
    $argText = (@("/driver:$Dir", "/os:$Os", '/uselocaltime', '/verbose') | ForEach-Object { ConvertTo-ArgText $_ }) -join ' '
    Add-Log "EXEC $Exe $argText"
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $start = Get-Date
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = New-Object System.Collections.Generic.List[string]
    $what = 'starting'
    $shown = [datetime]::MinValue
    $beat = 5                      # engine.log gets a "still running" line every 5 minutes
    $read =$p.StandardOutput.ReadLineAsync()
    while ($true) {
        if ($read.Wait(500)) {
            $line = $read.Result
            if ($null -eq $line) { break }
            $out.Add($line)
            $t = $line.Trim()
            if ($t -and $t -notmatch '^[\.\s]+$') {
                # full paths -> file names, so the line fits the status bar
                $t = $t -replace '(?i)\b[A-Z]:\\(?:[^\\\r\n]*\\)+', '' -replace '(?<![\w:])(?:/[^/\s]+)+/', ''
                if ($t.Length -gt 90) { $t = $t.Substring(0, 87) + '...' }
                $what = $t
            }
            $read = $p.StandardOutput.ReadLineAsync()
        }
        $now = Get-Date
        if (($now - $start).TotalMinutes -ge $beat) { Add-Log ('Inf2Cat {0} still running ({1}) - {2}' -f $Label, (Format-Span ($now - $start)), $what); $beat += 5 }
        if ($Script:Sync -and ($now - $shown).TotalMilliseconds -ge 400) {
            $Script:Sync.Status = ('Inf2Cat {0}  {1}  - {2}' -f $Label, (Format-Span ($now - $start)), $what)
            $shown = $now
        }
    }
    $p.WaitForExit()
    foreach ($l in ($errTask.Result -split "`r?`n")) { if ($l.Trim()) { $out.Add($l) } }
    if ($Script:Sync) { $Script:Sync.Status = '' }
    $lines = @($out)
    return [pscustomobject]@{ Code = [int]$p.ExitCode; Output = $lines; Text = ($lines -join "`r`n"); Time = ((Get-Date) - $start) }
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
    Write-Step 'Installing the Windows ADK Deployment Tools instead (a few minutes)'
    $adk = Join-Path $env:TEMP 'adksetup.exe'
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2289980' -OutFile $adk -UseBasicParsing
    if (-not (Test-MicrosoftSigned $adk)) { Remove-Item -LiteralPath $adk -Force; throw 'The ADK installer failed the Microsoft signature check.' }
    $code = Invoke-Exe $adk '/quiet /norestart /ceip off /features OptionId.DeploymentTools'
    $osc = Find-Oscdimg
    if (-not $osc) { throw "oscdimg.exe could not be installed (ADK setup exit $code)." }
    Write-Ok "oscdimg.exe installed: $osc"
    return $osc
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
function Get-SignTools {
    $t = @{ Inf2Cat = (Find-Tool 'Inf2Cat.exe'); SignTool = (Find-Tool 'signtool.exe') }
    if (-not $t.SignTool) {
        Write-Step 'Getting signtool.exe (Windows SDK build tools)'
        $t.SignTool = Get-FromNuGet 'signtool.exe' @('Microsoft.Windows.SDK.BuildTools', 'Microsoft.Windows.WDK.x64') '(?i)/x64/'
    }
    if (-not $t.Inf2Cat) {
        Write-Step 'Getting Inf2Cat.exe (Windows Driver Kit, about 110 MB)'
        $t.Inf2Cat = Get-FromNuGet 'Inf2Cat.exe' @('Microsoft.Windows.WDK.x64') '(?i)/x86/'
    }
    if (-not $t.Inf2Cat) { throw 'Inf2Cat.exe could not be downloaded from nuget.org (see the lines above). Check the internet connection and try again - only the Inf2Cat folder of the package is kept, nothing is installed.' }
    Write-Info "Inf2Cat : $($t.Inf2Cat)"
    if ($t.SignTool) { Write-Info "signtool: $($t.SignTool)" } else { Write-Warn 'signtool.exe not available - PowerShell signing is used and every package is re-signed.' }
    return $t
}
function Get-AllTools {
    Write-Title 'Tools'
    $o = Get-Oscdimg
    Write-Ok "oscdimg.exe : $o"
    [void](Get-SignTools)
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
function Test-SignedCatalog([string]$CatFile, [string]$Inf) {
    if ($Script:SignTool) {
        return ((Get-VerifyState $CatFile $Inf) -eq 'ok')
    }
    return ((Get-AuthenticodeSignature -FilePath $CatFile).Status -eq 'Valid')
}
function Invoke-SignFolder([string]$Root, $Cert, [string]$Inf2Cat, [bool]$All, [bool]$OnlyThisPc = $false) {
    $os = if ($Script:S.Family -and $Script:S.Family.Arch -eq 'x86') { '10_X86' } else { '10_X64' }
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
    $res = [ordered]@{ Signed = 0; Failed = 0; Untouched = 0; Skipped = 0; Removed = [int]$trim.Removed; Kept = @($trim.Kept) }
    $todo = @()
    foreach ($p in $pkgs) {
        $rel = $p.Dir.Substring($Root.TrimEnd('\', '/').Length).TrimStart('\', '/'); if (-not $rel) { $rel = '.' }
        $withCat = @($p.Infs | Where-Object { $states[$_] -ne 'no-catalog-directive' })
        $need = @($p.Infs | Where-Object { $states[$_] -in 'mismatch', 'untrusted', 'catalog-missing', 'unknown' })
        if ($withCat.Count -eq 0) { Write-Info "$rel : no CatalogFile= line in the INF - left as is"; $res.Skipped++; continue }
        if (-not $All -and $need.Count -eq 0) { $res.Untouched++; continue }
        $todo += [pscustomobject]@{ Pkg = $p; Rel = $rel; WithCat = $withCat }
    }
    $i = 0
    foreach ($t in $todo) {
        $i++
        $p = $t.Pkg; $rel = $t.Rel; $withCat = $t.WithCat
        $cnt = @($p.Infs).Count
        Write-Sub ('{0}  ({1} INF file(s), folder {2} of {3})' -f $rel, $cnt, $i, $todo.Count)
        if ($cnt -ge 10) {
            Write-Info "Inf2Cat checks each of these INF files against every file of the package - this can take a long time (up to an hour for a full NVIDIA package). It is still working while the time in the status line keeps counting."
            if (-not $OnlyThisPc) { Write-Info 'Faster next time: "Only keep the INF files for this PC''s hardware" on this page.' }
        }
        $start = Get-Date
        $r = Invoke-Inf2Cat $Inf2Cat $p.Dir $os ('{0} ({1} of {2})' -f $rel, $i, $todo.Count)
        $o = $r.Output
        $code = $r.Code
        Add-Log ("[$rel] Inf2Cat exit $code after $(Format-Span $r.Time)`r`n" + ($o | Out-String))
        if ($code -ne 0) {
            Write-Err "Inf2Cat failed for $rel"
            @($o | Out-String -Stream | Where-Object { $_.Trim() } | Select-Object -Last 4) | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkYellow }
            if (($o | Out-String) -match 'Signability test failed') { Write-Info 'Hint: delete inf2cat.exe.manifest next to Inf2Cat.exe and try again.' }
            $res.Failed++
            continue
        }
        $cats = @(Get-ChildItem -LiteralPath $p.Dir -Filter *.cat -File | Where-Object { $_.LastWriteTime -ge $start.AddSeconds(-2) })
        $ok = $cats.Count -gt 0
        foreach ($c in $cats) { if (-not (Invoke-SignCatalog $c.FullName $Cert)) { $ok = $false; Write-Err "Signing failed: $($c.Name)" } }
        if ($ok) {
            foreach ($inf in $withCat) { foreach ($c in (Get-InfCatalogs $inf)) { if (-not (Test-SignedCatalog (Join-Path $p.Dir $c) $inf)) { $ok = $false; Write-Err "Verification failed: $c" } } }
        }
        if ($ok) { $res.Signed++; Write-Ok "$rel signed and verified (Inf2Cat took $(Format-Span $r.Time))" } else { $res.Failed++ }
    }
    if ($Script:Sync) { $Script:Sync.Status = '' }
    return $res
}
function Invoke-SignPackage([string]$Source, [string]$Name, $Password, [bool]$All, [bool]$OnlyThisPc = $false) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Folder not found: $Source" }
    $Name = ($Name -replace '[^\w\.-]', '_').Trim('_')
    if (-not $Name) { $Name = 'Driver' }
    Write-Title "Re-sign modded drivers - $Name"
    $tools = Get-SignTools
    $Script:SignTool = $tools.SignTool
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
    try { $res = Invoke-SignFolder $dest $cert $tools.Inf2Cat $All $OnlyThisPc }
    finally { if ($added.Count) { Remove-TempTrust $cer $added } }
    $rec = [ordered]@{
        Name = $Name; Source = $Source; Path = $dest; InstallDir = "C:\Drivers\$Name"; When = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        Signed = [int]$res.Signed; Failed = [int]$res.Failed; Untouched = [int]$res.Untouched; Thumbprint = $cert.Thumbprint
        OnlyThisPc = [bool]($OnlyThisPc -and $res.Removed -gt 0); Removed = [int]$res.Removed; Kept = @($res.Kept)
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
    $l.Add('rem Generated by Win10-ISO-Updater: trusts the driver-signing certificate and installs the driver packages.')
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
            $lines = @([IO.File]::ReadAllLines($main))
            if (-not (($lines -join "`n") -match 'SetupComplete-drivers\.cmd')) {
                $at = if ($lines.Count -gt 0 -and $lines[0] -match '^\s*@?echo\s+off') { 1 } else { 0 }
                $new = New-Object System.Collections.Generic.List[string]
                for ($i = 0; $i -lt $lines.Count; $i++) { if ($i -eq $at) { $new.Add($call) }; $new.Add($lines[$i]) }
                if ($at -ge $lines.Count) { $new.Add($call) }
                [IO.File]::WriteAllText($main, (($new -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
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
            Add-Finding 'Warning' '$OEM$' ('Folder "{0}" at the top of $OEM$ is ignored by Windows 10 Setup - only $$ (C:\Windows) and $1 (C:\) are copied.' -f $i.Name) '' 'Move its contents into $1 or $$'
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
    $items = @($items | Sort-Object Class, Provider)
    Write-Ok "$($items.Count) driver packages found on this PC."
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
        if ($n -gt 1 -and -not (Read-YesNo "No edition is ticked. Update and keep all $n editions?" $true)) { throw 'Tick the editions on page 2, then run again.' }
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
        Set-Content -LiteralPath (Join-Path $w 'defender-exclusion.txt') -Value $w -Encoding ASCII
        $Script:DefenderAdded = $w
        Write-Info "Windows Defender skips $w during this job (removed again at the end)."
    } catch { Write-Warn "Could not add the Defender exclusion ($($_.Exception.Message)) - normal scanning stays on." }
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
            'Unpack'       { $Script:IsoPath = [string]$A.Iso; Invoke-Unpack }
            'Analyze'      { Invoke-Analyze }
            'Download'     { Invoke-Download -Auto }
            'ScanHost'     { $Script:Sync.Result = @(Get-HostDriverScan) }
            'CommitHost'   { Save-HostDrivers $A.Pick }
            'ScanFolder'   {
                Write-Step "Scanning $($A.Dir)"
                $Script:Sync.Result = @(Get-DriverPackages $A.Dir | Sort-Object Class, Provider, Inf)
                Write-Ok "$(@($Script:Sync.Result).Count) driver(s) found."
            }
            'CommitImport' { Save-ImportDrivers $A.Dir $A.Pick }
            'Sign'         { Invoke-SignPackage $A.Source $A.Name $A.Password ([bool]$A.All) ([bool]$Script:Cfg.SignOnlyThisPc) }
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
      <Setter Property="FontSize" Value="24"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Sub" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#8A94A8"/>
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
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="SelectionBrush" Value="#2F9BFF"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="#0E131E"/>
      <Setter Property="Foreground" Value="#E6EAF2"/>
      <Setter Property="BorderBrush" Value="#2A3348"/>
      <Setter Property="CaretBrush" Value="White"/>
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
        Title="Win10 ISO Updater" Width="1220" Height="800" MinWidth="1040" MinHeight="680"
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

  <Grid>
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
          <TextBlock FontSize="15" FontWeight="SemiBold"><Run Text="Win10 ISO Updater"/><Run x:Name="VerRun" Text="  v2.0.0" Foreground="#5B6478" FontWeight="Normal" FontSize="12"/></TextBlock>
          <TextBlock Text="updates + drivers + signed NVIDIA mods + autounattend + $OEM$  ->  bootable ISO" Foreground="#8A94A8" FontSize="11"/>
        </StackPanel>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,8,10,0">
        <Button x:Name="MinBtn" Style="{StaticResource Chrome}" Content="&#xE921;" ToolTip="Minimize"/>
        <Button x:Name="MaxBtn" Style="{StaticResource Chrome}" Content="&#xE922;" ToolTip="Maximize"/>
        <Button x:Name="CloseBtn" Style="{StaticResource Chrome}" Content="&#xE8BB;" ToolTip="Close"/>
      </StackPanel>
    </Grid>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="262"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- sidebar -->
      <Border Grid.Column="0" Background="#0E121B" BorderBrush="#1A2133" BorderThickness="0,1,1,0">
        <DockPanel LastChildFill="False">
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
        </DockPanel>
      </Border>

      <!-- main -->
      <Grid Grid.Column="1">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Margin="24,16,24,0" Padding="18,12" CornerRadius="12" BorderBrush="#232B3D" BorderThickness="1">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#16213A" Offset="0"/><GradientStop Color="#1B1733" Offset="1"/></LinearGradientBrush>
          </Border.Background>
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
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Source ISO"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Pick a Windows 10 ISO (1607 / LTSB 2016, 1809 / LTSC 2019, 2004-22H2 or LTSC 2021). It is copied into the work folder and its build and editions are detected."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="ISO file"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="IsoBox" Margin="0,0,8,0"/>
                <Button x:Name="IsoBrowse" Grid.Column="1" Style="{StaticResource Btn}" Content="Browse..." Margin="0"/>
              </Grid>
              <WrapPanel Margin="0,14,0,0">
                <Button x:Name="UnpackBtn" Style="{StaticResource Primary}" Content="Unpack and analyze"/>
                <Button x:Name="AnalyzeBtn" Style="{StaticResource Btn}" Content="Re-read image info"/>
                <Button x:Name="GetIsoBtn" Style="{StaticResource Btn}" Content="Download Windows 10 from Microsoft"/>
              </WrapPanel>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Detected image"/>
              <TextBlock x:Name="ImgInfo" FontSize="14" FontWeight="SemiBold" TextWrapping="Wrap" Text="Nothing unpacked yet."/>
              <TextBlock x:Name="ImgNote" Style="{StaticResource Sub}" Margin="0,4,0,12"/>
              <DataGrid x:Name="ImgGrid" Height="210"/>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 2 editions -->
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
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
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Windows updates"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Finds the newest cumulative update, servicing stack, Safe OS and Setup Dynamic Updates and .NET updates for this build in the Microsoft Update Catalog and downloads them (SHA-1 checked)."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="What to integrate"/>
              <CheckBox x:Name="cfg_NetFx481" Style="{StaticResource Toggle}" Content="Add .NET Framework 4.8.1 (Windows 10 2004-22H2)"/>
              <CheckBox x:Name="cfg_NetFx3" Style="{StaticResource Toggle}" Content="Enable .NET Framework 3.5 (from the ISO's sources\sxs)"/>
              <CheckBox x:Name="cfg_ResetBase" Style="{StaticResource Toggle}" Content="Component cleanup /ResetBase (smaller image - updates can't be uninstalled)"/>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <TextBlock Text="Newest month to integrate" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBox x:Name="CutoffBox" Width="90"/>
                <TextBlock Style="{StaticResource Sub}" VerticalAlignment="Center" Margin="12,0,0,0" Text="YYYY-MM, for 2004-22H2 / LTSC 2021"/>
              </StackPanel>
              <TextBlock Style="{StaticResource Sub}" Margin="0,6,0,0" Text="2025-10 is the last Windows 10 update Microsoft allows offline. ESU updates (Nov 2025+) come from Windows Update after setup on enrolled PCs."/>
              <WrapPanel Margin="0,14,0,0"><Button x:Name="UpdBtn" Style="{StaticResource Primary}" Content="Find and download updates"/></WrapPanel>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Downloaded"/>
              <DataGrid x:Name="UpdGrid" Height="210"/>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 4 drivers -->
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
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
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Signed NVIDIA / modded drivers"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="For driver packages whose INF was edited - NVCleanstall hardware-ID mods for an unsupported GPU, custom INF files. The edit breaks the catalog signature, so Windows refuses them. Every subfolder is scanned; each modified package gets a new catalog (Inf2Cat) signed with your own certificate. The package is added to the ISO through $OEM$ and installed by SetupComplete.cmd at the end of Windows setup, right after the certificate is trusted."/>
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
              <CheckBox x:Name="SignAll" Style="{StaticResource Toggle}" Margin="0,12,0,0" Content="Re-sign every package, not only the modified ones"/>
              <CheckBox x:Name="cfg_SignCleanup" Style="{StaticResource Toggle}" Content="Delete the driver copy from C:\Drivers once it is installed"/>
              <CheckBox x:Name="cfg_SignOnlyThisPc" Style="{StaticResource Toggle}" Content="Faster: only keep the INF files for this PC's hardware (when the ISO is for this PC)"/>
              <TextBlock Style="{StaticResource Sub}" Margin="48,-2,0,4" Text="NVIDIA's Display.Driver has one INF file per laptop and desktop maker, and Inf2Cat checks every one of them against the whole package - that can take up to an hour. With this on, only the INF files that list a device of this PC are signed (minutes instead), the others are removed from the copy. The original folder is not touched."/>
              <WrapPanel Margin="0,14,0,0">
                <Button x:Name="SignBtn" Style="{StaticResource Primary}" Content="Sign and add to the ISO"/>
                <Button x:Name="SignOpen" Style="{StaticResource Btn}" Content="Open signing folder"/>
              </WrapPanel>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Signing certificate"/>
              <TextBlock x:Name="CertInfo" TextWrapping="Wrap" FontWeight="SemiBold"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,6,0,0" Text="DriverSigning.pfx (private key) stays in the signing folder next to this tool - back it up and never share or upload it. Only the public DriverSigning.cer goes into the ISO. Tools (Inf2Cat, signtool) are downloaded automatically."/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Packages added to the ISO"/>
              <DataGrid x:Name="SignGrid" Height="150"/>
              <WrapPanel Margin="0,12,0,0"><Button x:Name="SignRemove" Style="{StaticResource Btn}" Content="Remove selected"/></WrapPanel>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 6 answer file + oem -->
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
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
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
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
              <CheckBox x:Name="cfg_ParallelBoot" Style="{StaticResource Toggle}" Content="Update boot.wim at the same time as install.wim (faster, uses more CPU and disk)"/>
              <CheckBox x:Name="cfg_DefenderExclude" Style="{StaticResource Toggle}" Content="Let Windows Defender skip the work folder while a job runs (removed again afterwards)"/>
              <CheckBox x:Name="cfg_BootSkipPE" Style="{StaticResource Toggle}" Content="Leave boot.wim index 1 (Windows PE for WDS servers) as it is - USB / DVD setup uses index 2"/>
              <TextBlock Style="{StaticResource Sub}" Margin="0,4,0,0" Text="DISM applies each update with one process, so servicing one image cannot use more cores - updating boot.wim alongside install.wim can. Defender scanning every file DISM writes is often the biggest slowdown. Storage / network drivers go into WinRE and boot.wim with one DISM call."/>
            </StackPanel></Border>
            <Border Style="{StaticResource Card}"><StackPanel>
              <TextBlock Style="{StaticResource H2}" Text="Output ISO"/>
              <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBox x:Name="OutBox" Margin="0,0,8,0"/>
                <Button x:Name="OutBrowse" Grid.Column="1" Style="{StaticResource Btn}" Content="Save as..." Margin="0"/>
              </Grid>
              <TextBlock Style="{StaticResource Sub}" Margin="0,6,0,14" Text="Empty = work folder\output\Win10_version_build_arch_date.iso"/>
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
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
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
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
            <TextBlock Style="{StaticResource H1}" Text="Tools"/>
            <TextBlock Style="{StaticResource Sub}" Margin="0,0,0,14" Text="Everything missing is downloaded automatically when a step needs it, into the tools folder next to this file. oscdimg.exe comes from the Microsoft symbol server (SHA-256 checked) or the Windows ADK; Inf2Cat and signtool are extracted from Microsoft's NuGet packages (Windows SDK build tools / Windows Driver Kit) - only those tools are kept, nothing is installed."/>
            <Border Style="{StaticResource Card}"><StackPanel>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition/></Grid.ColumnDefinitions>
                <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Text="DISM" Margin="0,4"/><TextBlock x:Name="T_Dism" Grid.Row="0" Grid.Column="1" Margin="0,4" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="1" Text="oscdimg.exe" Margin="0,4"/><TextBlock x:Name="T_Osc" Grid.Row="1" Grid.Column="1" Margin="0,4" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="2" Text="Inf2Cat.exe" Margin="0,4"/><TextBlock x:Name="T_Inf" Grid.Row="2" Grid.Column="1" Margin="0,4" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="3" Text="signtool.exe" Margin="0,4"/><TextBlock x:Name="T_Sign" Grid.Row="3" Grid.Column="1" Margin="0,4" TextTrimming="CharacterEllipsis"/>
                <TextBlock Grid.Row="4" Text="curl.exe" Margin="0,4"/><TextBlock x:Name="T_Curl" Grid.Row="4" Grid.Column="1" Margin="0,4"/>
              </Grid>
              <WrapPanel Margin="0,14,0,0"><Button x:Name="ToolsBtn" Style="{StaticResource Primary}" Content="Download missing tools now"/><Button x:Name="ToolsOpen" Style="{StaticResource Btn}" Content="Open tools folder"/></WrapPanel>
            </StackPanel></Border>
          </StackPanel></ScrollViewer></TabItem>

          <!-- 10 install check -->
          <TabItem Visibility="Collapsed"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
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

#region ---------------------------------------------------------------- GUI helpers
function New-Xaml([string]$Text) {
    $x = $Text.Replace('__PAGES__', $Script:XPages).Replace('__RES__', $Script:XRes)
    $win = [Windows.Markup.XamlReader]::Parse($x)
    $names = @{}
    foreach ($m in [regex]::Matches($x, 'x:Name="([^"]+)"')) {
        $o = $win.FindName($m.Groups[1].Value)
        if ($o) { $names[$m.Groups[1].Value] = $o }
    }
    return @{ W = $win; U = $names }
}
function New-Brush([string]$Hex) {
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
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
    [void][Windows.MessageBox]::Show($Script:W, $Text, 'Win10 ISO Updater', 'OK', $Icon)
}
function Confirm-Ui([string]$Text, [string]$Icon = 'Question') {
    return ([Windows.MessageBox]::Show($Script:W, $Text, 'Win10 ISO Updater', 'YesNo', $Icon) -eq 'Yes')
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

#region ---------------------------------------------------------------- background worker
function Start-Work([string]$Job, $A = @{}, [scriptblock]$Then) {
    if ($Script:Busy) { Show-Msg 'Another job is still running.'; return }
    try { Save-Settings } catch { }
    $Script:Busy = $true
    $Script:JobName = $Job
    $Script:JobStart = Get-Date
    $Script:Then = $Then
    $Script:Sync.Pct = -1; $Script:Sync.Status = ''; $Script:Sync.Result = $null
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
    $took = (Get-Date) - $Script:JobStart
    Flush-Log
    $Script:Cfg = Import-Settings; Initialize-Paths; $Script:S = Import-State
    Set-Busy $false
    if ($ok) {
        $Script:U.BusyText.Text = ('{0} finished in {1:mm\:ss}' -f $Script:JobLabel, $took)
        $Script:U.BusyDot.Fill = New-Brush '#3DDC97'
    } else {
        $Script:U.BusyText.Text = "$($Script:JobLabel) stopped with an error - see the log"
        $Script:U.BusyDot.Fill = New-Brush '#FF5C7A'
    }
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
        $Script:U.BusyDot.Fill = New-Brush '#FFC857'
        $Script:U.BusyText.Text = "$($Script:JobLabel)..."
    }
}
function Invoke-Tick {
    Flush-Log
    $q = $Script:Sync.Question
    if ($q) {
        $Script:Sync.Question = $null
        $Script:Timer.Stop()
        $def = if ($q.Default) { 'Yes' } else { 'No' }
        $r = [Windows.MessageBox]::Show($Script:W, [string]$q.Text, 'Win10 ISO Updater', 'YesNo', 'Question', $def)
        $Script:Sync.Answer = ($r -eq 'Yes')
        $Script:Timer.Start()
    }
    if ($Script:Busy) {
        $pct = [double]$Script:Sync.Pct
        if ($pct -ge 0) { $Script:U.Prog.IsIndeterminate = $false; $Script:U.Prog.Value = $pct } else { $Script:U.Prog.IsIndeterminate = $true }
        $el = (Get-Date) - $Script:JobStart
        $Script:U.BusyText.Text = ('{0}  {1:hh\:mm\:ss}' -f $Script:JobLabel, $el)
        $st = [string]$Script:Sync.Status
        if ($pct -ge 0) { $st = ('{0:N1}%  {1}' -f $pct, $st) }
        $side = $Script:Sync.SideSync
        if ($side -and $side.Label) {
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
function Update-Ui {
    $Script:Loading = $true
    try {
        $S = $Script:S; $U = $Script:U; $Cfg = $Script:Cfg
        Update-Status
        foreach ($k in $Script:CfgToggles) { $U["cfg_$k"].IsChecked = [bool]$Cfg[$k] }
        $U.CutoffBox.Text = [string]$Cfg.Win10Cutoff
        $U.WorkBox.Text = [string]$Cfg.WorkDir
        if (-not $U.IsoBox.Text -and $S.SourceIso) { $U.IsoBox.Text = $S.SourceIso }

        # 1 source
        $imgs = @($S.Images)
        if ($S.Family -and $imgs.Count) {
            $U.ImgInfo.Text = '{0}  -  build {1}  -  {2}  -  {3} edition(s)' -f $S.Family.Name, $imgs[0].Version, $S.Family.Arch, $imgs.Count
            $U.ImgNote.Text = if (-not $S.Family.Supported) { 'No automatic updates for this build - drivers, signed packages, answer file and $OEM$ still work.' }
                              elseif ($S.Family.Cap) { "Updates up to $($Cfg.Win10Cutoff) (the last month Microsoft allows offline for Windows 10)." + $(if ($S.Family.NeedsEkb) { ' The 22H2 enablement package is added too.' } else { '' }) }
                              else { 'Newest updates available in the Microsoft Update Catalog.' }
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
        $U.SignGrid.ItemsSource = (New-Table @('Name', 'InstallsFrom', 'Signed:int', 'Failed:int', 'INFs', 'When', 'Source') @(foreach ($x in @($S.Signed | Where-Object { $_ })) { , @($x.Name, $x.InstallDir, [int]$x.Signed, [int]$x.Failed, $(if ($x.OnlyThisPc) { "this PC only ($(@($x.Kept).Count) kept)" } else { 'all' }), $x.When, $x.Source) })).DefaultView
        Update-SignDest
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
    $osc = Find-Oscdimg; $inf = Find-Tool 'Inf2Cat.exe'; $sig = Find-Tool 'signtool.exe'
    & $set $U.T_Osc $osc 'missing - downloaded automatically when you build the ISO'
    & $set $U.T_Inf $inf 'missing - downloaded automatically when you sign drivers'
    & $set $U.T_Sign $sig 'missing - downloaded automatically when you sign drivers'
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    & $set $U.T_Curl $(if (Test-Path -LiteralPath $curl) { $curl }) 'missing - PowerShell / BITS downloads are used'
    $U.ToolsDot.Text = if ($osc -and $inf -and $sig) { '' } else { [string][char]0x25CF }
}
function Save-EditionPick {
    $sel = @(foreach ($r in $Script:EdTable.Rows) { if ($r['Use'] -eq $true) { [int]$r['Index'] } })
    $Script:S.Selected = $sel
    Save-State
    Update-Status
}
function Update-SignDest {
    $n = ($Script:U.SignName.Text -replace '[^\w\.-]', '_').Trim('_')
    if (-not $n) { $n = 'Driver' }
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
    $Script:PickTable = New-Table @('Use:bool', 'No:int', 'Class', 'Provider', 'Version', 'Date', 'Arch', 'SizeMB:dbl', 'Inf', 'Folder') @(foreach ($x in @($Items)) {
        $n++; , @((Test-DriverArch ([string]$x.Arch) $arch), $n, $x.Class, $x.Provider, $x.Version, $x.Date, [string]$x.Arch, [double]$x.'Size (MB)', $x.Inf, $x.Folder) })
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
    $D.U.PFit.Add_Click({ foreach ($r in $Script:PickTable.Rows) { $r['Use'] = (Test-DriverArch ([string]$r['Arch']) $Script:PickArch) } })
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
        if ($pick.Count -gt 0) { Start-Work 'CommitHost' @{ Pick = $pick } } else { Start-Work 'CommitHost' @{ Pick = @() } }
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
    $name = ($Script:U.SignName.Text -replace '[^\w\.-]', '_').Trim('_')
    if (-not $name) { $name = 'Driver' }
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
    if (-not (Confirm-Ui ("Run everything now? It takes 30-90 minutes.`n`n" + ($lines -join "`n")))) { return }
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
    $Script:CfgToggles = @('KeepOnlySelected', 'NetFx3', 'NetFx481', 'ResetBase', 'BootDrivers', 'ForceUnsigned', 'NoPrompt', 'Boot2023', 'SplitFat32', 'SignCleanup', 'InstallOemDrivers', 'SignOnlyThisPc', 'ParallelBoot', 'DefenderExclude', 'BootSkipPE')
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

    $M = New-Xaml $Script:XMain
    $Script:W = $M.W; $Script:U = $M.U
    $W = $Script:W; $U = $Script:U
    $U.VerRun.Text = "  v$Script:AppVersion"

    # title bar
    $U.MinBtn.Add_Click({ $Script:W.WindowState = 'Minimized' })
    $U.MaxBtn.Add_Click({ Set-WorkAreaMax (-not $Script:FakeMax) })
    $U.CloseBtn.Add_Click({ $Script:W.Close() })
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

    # 1 source
    $U.IsoBrowse.Add_Click({
        $start = if ($Script:S.SourceIso) { Split-Path ([string]$Script:S.SourceIso) -Parent } else { Join-Path $env:USERPROFILE 'Downloads' }
        $f = Select-File 'Select a Windows 10 ISO' 'ISO images (*.iso)|*.iso' $start
        if ($f) { $Script:U.IsoBox.Text = $f }
    })
    $U.UnpackBtn.Add_Click({ Invoke-UnpackClick })
    $U.AnalyzeBtn.Add_Click({ if (Test-Unpacked) { Start-Work 'Analyze' } })
    $U.GetIsoBtn.Add_Click({ Start-Process $Script:IsoPageUrl })
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
            $Script:U.SignName.Text = if ($leaf -match '(?i)nvidia|nvcleanstall|geforce|^\d{3}\.\d{2}') { 'NVIDIA' } else { ($leaf -replace '[^\w\.-]', '_') }
        }
    })
    $U.SignName.Add_TextChanged({ Update-SignDest })
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
        $d.Filter = 'ISO image (*.iso)|*.iso'; $d.FileName = 'Win10_custom.iso'
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
            $r = [Windows.MessageBox]::Show($Script:W, "'$($Script:JobLabel)' is still running. Closing now can leave a mounted image behind (run Clean up next time). Close anyway?", 'Win10 ISO Updater', 'YesNo', 'Warning')
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
    Write-Title "Win10 ISO Updater $Script:AppVersion"
    Write-Info "Work folder: $($Script:P.Work)"
    if ($Script:S.Unpacked) { Write-Info "Unpacked media: $(Split-Path ([string]$Script:S.SourceIso) -Leaf) - pick up where you left off." }
    else { Write-Info 'Start on page 1: choose a Windows 10 ISO and unpack it - or set everything up and press Run everything.' }

    try {
        Add-Type -Namespace W10U -Name Con -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
        [void][W10U.Con]::ShowWindow([W10U.Con]::GetConsoleWindow(), 0)
    } catch { }
    [void]$W.ShowDialog()
    if ($Script:Busy) { [Environment]::Exit(0) }
    try { $Script:RS.Close() } catch { }
    exit 0
} catch {
    try { [void][W10U.Con]::ShowWindow([W10U.Con]::GetConsoleWindow(), 5) } catch { }
    Microsoft.PowerShell.Utility\Write-Host ''
    Microsoft.PowerShell.Utility\Write-Host "  Win10 ISO Updater could not start: $($_.Exception.Message)" -ForegroundColor Red
    Microsoft.PowerShell.Utility\Write-Host "  $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    exit 1
}
#endregion
