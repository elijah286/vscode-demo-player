Add-Type -AssemblyName System.Windows.Forms

[xml]$overlayLayout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Playback overlay" Width="820" Height="180" MinWidth="360" MinHeight="132" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" ResizeMode="CanResize"
        ShowInTaskbar="False" ShowActivated="False" Topmost="True"
        WindowStartupLocation="Manual" FontFamily="Segoe UI"
        AutomationProperties.AutomationId="PlaybackOverlay">
  <Grid>
  <Border x:Name="OverlayFrame" Background="#FFFFFF" BorderBrush="#F5B82E"
          BorderThickness="4" CornerRadius="8" Padding="16,12" Cursor="SizeAll">
    <Grid x:Name="OverlayContent">
      <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="0"/></Grid.RowDefinitions>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <Grid x:Name="PromptPanel">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Prompt summary" Foreground="#555555" FontSize="12"/>
          <TextBlock x:Name="PromptProgress" Margin="12,0,0,0" Foreground="#555555" FontSize="12"/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,8,0,0">
        <TextBlock x:Name="PromptText" FontSize="18" FontWeight="SemiBold"
                   Foreground="#202020" TextWrapping="Wrap"/>
        </ScrollViewer>
      </Grid>
      <StackPanel x:Name="TimerPanel" Grid.Column="1" VerticalAlignment="Center" Margin="24,0,0,0"
                  ToolTip="Recorded response time, interpolated during playback. Excludes idle gaps between turns; not model compute time.">
        <TextBlock Text="Working time (HH:MM:SS)" Foreground="#555555" FontSize="11"/>
        <TextBlock x:Name="ElapsedText" Text="00:00:00" MinWidth="164" FontFamily="Consolas"
                   FontSize="30" Foreground="#202020" Margin="0,6,0,0"/>
      </StackPanel>
    </Grid>
  </Border>
  <Thumb x:Name="OverlayResize" Width="20" Height="20" HorizontalAlignment="Right" VerticalAlignment="Bottom"
         Cursor="SizeNWSE" ToolTip="Drag to resize the overlay" AutomationProperties.AutomationId="OverlayResize">
    <Thumb.Template><ControlTemplate><Grid Background="Transparent"><Path Data="M 6,16 L 16,6 M 11,16 L 16,11" Stroke="#777777" StrokeThickness="2"/></Grid></ControlTemplate></Thumb.Template>
  </Thumb>
  </Grid>
</Window>
'@
$overlayReader = [System.Xml.XmlNodeReader]::new($overlayLayout)
try { $script:overlayWindow = [System.Windows.Markup.XamlReader]::Load($overlayReader) } finally { $overlayReader.Dispose() }
$script:overlayWindow.Width = [Math]::Min(820, $area.Width - 32)
$script:overlayWindow.Left = $area.Left + ($area.Width - $script:overlayWindow.Width) / 2
$script:overlayWindow.Top = $area.Top + 16
$overlayFrame = $script:overlayWindow.FindName('OverlayFrame')
$promptPanel = $script:overlayWindow.FindName('PromptPanel')
$timerPanel = $script:overlayWindow.FindName('TimerPanel')
$promptText = $script:overlayWindow.FindName('PromptText')
$promptProgress = $script:overlayWindow.FindName('PromptProgress')
$elapsedText = $script:overlayWindow.FindName('ElapsedText')
$overlayContent = $script:overlayWindow.FindName('OverlayContent')

function Update-OverlayLayout {
    $combined = $promptPanel.Visibility -eq 'Visible' -and $timerPanel.Visibility -eq 'Visible'
    $width = if ($script:overlayWindow.ActualWidth -gt 0) { $script:overlayWindow.ActualWidth } else { $script:overlayWindow.Width }
    $stacked = $combined -and $width -lt 640
    $overlayContent.RowDefinitions[0].Height = if ($stacked) { [System.Windows.GridLength]::Auto } else { [System.Windows.GridLength]::new(1, 'Star') }
    $overlayContent.RowDefinitions[1].Height = if ($stacked) { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::new(0) }
    $overlayContent.ColumnDefinitions[1].Width = if ($stacked) { [System.Windows.GridLength]::new(0) } else { [System.Windows.GridLength]::Auto }
    [System.Windows.Controls.Grid]::SetRow($promptPanel, $(if ($stacked) { 1 } else { 0 }))
    [System.Windows.Controls.Grid]::SetColumn($timerPanel, $(if ($stacked) { 0 } else { 1 }))
    $timerPanel.VerticalAlignment = if ($stacked) { 'Top' } else { 'Center' }
    $timerPanel.HorizontalAlignment = if ($stacked) { 'Left' } else { 'Stretch' }
    $timerPanel.Margin = if ($stacked) { [System.Windows.Thickness]::new(0,0,0,12) } elseif ($combined) { [System.Windows.Thickness]::new(24,0,0,0) } else { [System.Windows.Thickness]::new(0) }
}

$script:overlayWindow.Add_SizeChanged({ Update-OverlayLayout })
$script:overlayResized = $false
$script:overlayWindow.FindName('OverlayResize').Add_DragDelta({
    param($sender, $eventArgs)
    $script:overlayResized = $true
    $script:overlayWindow.Width = [Math]::Max($script:overlayWindow.MinWidth, $script:overlayWindow.ActualWidth + $eventArgs.HorizontalChange)
    $script:overlayWindow.Height = [Math]::Max($script:overlayWindow.MinHeight, $script:overlayWindow.ActualHeight + $eventArgs.VerticalChange)
    $eventArgs.Handled = $true
})

function Update-ReplayOverlays {
    $overlay = $script:lastView.overlay
    $showPrompt.IsEnabled = -not $script:stopping -and -not [string]::IsNullOrWhiteSpace($overlay.promptSummary)
    $showElapsed.IsEnabled = -not $script:stopping -and $null -ne $overlay.elapsed
    $promptVisible = $showPrompt.IsChecked -and $showPrompt.IsEnabled
    $timerVisible = $showElapsed.IsChecked -and $showElapsed.IsEnabled
    $promptPanel.Visibility = if ($promptVisible) { 'Visible' } else { 'Collapsed' }
    $timerPanel.Visibility = if ($timerVisible) { 'Visible' } else { 'Collapsed' }
    $promptText.Text = $overlay.promptSummary
    $promptProgress.Text = $script:lastView.progress
    $elapsedText.Text = $overlay.elapsed
    $desiredWidth = if ($promptVisible -and $timerVisible) { 820 } elseif ($promptVisible) { 720 } else { 238 }
    $script:overlayWindow.MinWidth = if ($promptVisible) { 280 } else { 238 }
    if (-not $script:overlayResized) {
        $script:overlayWindow.Width = [Math]::Min($desiredWidth, $area.Width - 32)
        $script:overlayWindow.Height = if ($promptVisible) { Get-OverlayPromptHeight $script:overlayWindow.Width $timerVisible } else { 104 }
    }
    $script:overlayWindow.MinHeight = if ($promptVisible) { 132 } else { 104 }
    Update-OverlayLayout
    if ($promptVisible -or $timerVisible) {
        $script:overlayWindow.Owner = $window
        if (-not $script:overlayWindow.IsVisible) { $script:overlayWindow.Show() }
    } else { $script:overlayWindow.Hide() }
}

function Get-OverlayPromptHeight([double]$Width, [bool]$WithTimer) {
    $timerPanel.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $stacked = $WithTimer -and $Width -lt 640
    $textWidth = $Width - 40
    if ($WithTimer -and -not $stacked) { $textWidth -= $timerPanel.DesiredSize.Width + 24 }
    $measurement = [System.Windows.Controls.TextBlock]::new()
    $measurement.FontFamily = $promptText.FontFamily
    $measurement.FontSize = $promptText.FontSize
    $measurement.FontWeight = $promptText.FontWeight
    $measurement.TextWrapping = 'Wrap'
    $measurement.Text = $promptText.Text
    $measurement.Measure([System.Windows.Size]::new([Math]::Max(1, $textWidth), [double]::PositiveInfinity))
    $height = 32 + 24 + [Math]::Ceiling($measurement.DesiredSize.Height)
    if ($stacked) { $height += $timerPanel.DesiredSize.Height + 12 }
    return [Math]::Min([Math]::Max(180, $height), [Math]::Max(132, $area.Height - 32))
}

function Set-OverlayFrameColor([System.Windows.Media.Color]$Color) {
    $brush = [System.Windows.Media.SolidColorBrush]::new($Color)
    $overlayFrame.BorderBrush = $brush
    $frameColorSwatch.Background = $brush
    $name = 'Overlay frame color: ' + ('#{0:X2}{1:X2}{2:X2}' -f $Color.R, $Color.G, $Color.B)
    $frameColor.ToolTip = $name
    [System.Windows.Automation.AutomationProperties]::SetName($frameColor, $name)
}

$frameColor.Add_Click({
    $picker = [System.Windows.Forms.ColorDialog]::new()
    $picker.FullOpen = $true
    $picker.AnyColor = $true
    $picker.Color = [System.Drawing.Color]::FromArgb($overlayFrame.BorderBrush.Color.R, $overlayFrame.BorderBrush.Color.G, $overlayFrame.BorderBrush.Color.B)
    $dialogOwner = [System.Windows.Forms.NativeWindow]::new()
    $dialogOwner.AssignHandle([System.Windows.Interop.WindowInteropHelper]::new($window).Handle)
    try {
        if ($picker.ShowDialog($dialogOwner) -eq [System.Windows.Forms.DialogResult]::OK) {
            Set-OverlayFrameColor ([System.Windows.Media.Color]::FromRgb($picker.Color.R, $picker.Color.G, $picker.Color.B))
        }
    } finally { $dialogOwner.ReleaseHandle(); $picker.Dispose() }
})
$showPrompt.Add_Checked({ Update-ReplayOverlays })
$showPrompt.Add_Unchecked({ Update-ReplayOverlays })
$showElapsed.Add_Checked({ Update-ReplayOverlays })
$showElapsed.Add_Unchecked({ Update-ReplayOverlays })
$overlayFrame.Add_MouseLeftButtonDown({ $script:overlayWindow.DragMove() })
$script:overlayWindow.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:closeAllowed) { $eventArgs.Cancel = $true; $showPrompt.IsChecked = $false; $showElapsed.IsChecked = $false }
})