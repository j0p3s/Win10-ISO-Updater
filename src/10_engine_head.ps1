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
$Script:AppVersion   = '4.3.1'
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

