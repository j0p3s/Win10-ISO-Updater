$Script:XPages = @'
          <!-- 1 source -->
          <TabItem Visibility="Collapsed" Foreground="#E6EAF2"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24,18,24,18">
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
