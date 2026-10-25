
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
