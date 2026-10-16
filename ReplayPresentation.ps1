Add-Type -AssemblyName System.Windows.Forms

[xml]$overlayLayout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Playback overlay" Width="820" MinHeight="132" SizeToContent="Height" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        ShowInTaskbar="False" ShowActivated="False" Topmost="True"
        WindowStartupLocation="Manual" FontFamily="Segoe UI"
        AutomationProperties.AutomationId="PlaybackOverlay">
  <Border x:Name="OverlayFrame" Background="#FFFFFF" BorderBrush="#F5B82E"
          BorderThickness="4" CornerRadius="8" Padding="16,12" Cursor="SizeAll">
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel x:Name="PromptPanel" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Prompt summary" Foreground="#555555" FontSize="12"/>
          <TextBlock x:Name="PromptProgress" Margin="12,0,0,0" Foreground="#555555" FontSize="12"/>
        </StackPanel>
        <TextBlock x:Name="PromptText" FontSize="18" FontWeight="SemiBold" Margin="0,8,0,0"
                   Foreground="#202020" TextWrapping="Wrap"/>
      </StackPanel>
      <StackPanel x:Name="TimerPanel" Grid.Column="1" VerticalAlignment="Center" Margin="24,0,0,0"
                  ToolTip="Recorded response time, interpolated during playback. Excludes idle gaps between turns; not model compute time.">
        <TextBlock Text="Working time (HH:MM:SS)" Foreground="#555555" FontSize="11"/>
        <TextBlock x:Name="ElapsedText" Text="00:00:00" MinWidth="164" FontFamily="Consolas"
                   FontSize="30" Foreground="#202020" Margin="0,6,0,0"/>
      </StackPanel>
    </Grid>
  </Border>
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
    $timerPanel.Margin = if ($promptVisible) { [System.Windows.Thickness]::new(24,0,0,0) } else { [System.Windows.Thickness]::new(0) }
    $desiredWidth = if ($promptVisible -and $timerVisible) { 820 } elseif ($promptVisible) { 720 } else { 238 }
    $script:overlayWindow.Width = [Math]::Min($desiredWidth, $area.Width - 32)
    $script:overlayWindow.MinHeight = if ($promptVisible) { 132 } else { 104 }
    if ($promptVisible -or $timerVisible) {
        $script:overlayWindow.Owner = $window
        if (-not $script:overlayWindow.IsVisible) { $script:overlayWindow.Show() }
    } else { $script:overlayWindow.Hide() }
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
$script:overlayWindow.Add_MouseLeftButtonDown({ $script:overlayWindow.DragMove() })
$script:overlayWindow.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:closeAllowed) { $eventArgs.Cancel = $true; $showPrompt.IsChecked = $false; $showElapsed.IsChecked = $false }
})