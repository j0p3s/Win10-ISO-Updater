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
          <TextBlock FontSize="15" FontWeight="SemiBold"><Run Text="Win10 ISO Updater"/><Run x:Name="VerRun" Text="  v3.2.0" Foreground="#5B6478" FontWeight="Normal" FontSize="12"/></TextBlock>
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
