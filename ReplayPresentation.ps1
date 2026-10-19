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
      <ScrollViewer x:Name="ConversationPanel" Grid.Row="1" Visibility="Collapsed"
                    AutomationProperties.AutomationId="ConversationPanel" AutomationProperties.Name="Input and output summaries"
                    VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel x:Name="ConversationMessages">
          <StackPanel.RenderTransform><TranslateTransform/></StackPanel.RenderTransform>
          <Border x:Name="FirstBubble" Padding="12,8" CornerRadius="10" Margin="0,0,0,4">
            <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
            <StackPanel>
              <TextBlock x:Name="FirstLabel" FontSize="12" FontWeight="Bold" AutomationProperties.AutomationId="FirstLabel"/>
              <TextBlock x:Name="FirstText" FontSize="18" TextWrapping="Wrap" Margin="0,4,0,0" AutomationProperties.AutomationId="FirstText"/>
            </StackPanel>
          </Border>
          <TextBlock x:Name="ConversationArrow" Text="&#x2193;" FontSize="24" Foreground="#555555"
                     HorizontalAlignment="Center" Visibility="Collapsed"
                     AutomationProperties.AutomationId="ConversationArrow"
                     AutomationProperties.Name="Input followed by output"/>
          <Border x:Name="SecondBubble" Padding="12,8" CornerRadius="10" Margin="0,4,0,0">
            <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
            <StackPanel>
              <TextBlock x:Name="SecondLabel" FontSize="12" FontWeight="Bold" AutomationProperties.AutomationId="SecondLabel"/>
              <TextBlock x:Name="SecondText" FontSize="18" TextWrapping="Wrap" Margin="0,4,0,0" AutomationProperties.AutomationId="SecondText"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
      <StackPanel x:Name="TimerPanel" Grid.Column="1" VerticalAlignment="Center" Margin="24,0,0,0"
                  ToolTip="Recorded response time, interpolated during playback. Excludes idle gaps between turns; not model compute time.">
        <TextBlock Text="Working time (HH:MM:SS)" Foreground="#555555" FontSize="11"/>
        <TextBlock x:Name="ElapsedText" Text="00:00:00" MinWidth="164" FontFamily="Consolas"
                   AutomationProperties.AutomationId="ElapsedText"
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
$conversationPanel = $script:overlayWindow.FindName('ConversationPanel')
$conversationMessages = $script:overlayWindow.FindName('ConversationMessages')
$conversationArrow = $script:overlayWindow.FindName('ConversationArrow')
$firstBubble = $script:overlayWindow.FindName('FirstBubble')
$firstLabel = $script:overlayWindow.FindName('FirstLabel')
$firstText = $script:overlayWindow.FindName('FirstText')
$secondBubble = $script:overlayWindow.FindName('SecondBubble')
$secondLabel = $script:overlayWindow.FindName('SecondLabel')
$secondText = $script:overlayWindow.FindName('SecondText')
$script:conversationKey = $null
$script:conversationTransitionCount = 0
$script:displayedConversation = $null
$script:pendingConversation = $null
$script:conversationTransitionPhase = 'idle'
$script:conversationTransitionTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:conversationTransitionTimer.Interval = [TimeSpan]::FromMilliseconds(160)
$script:outputMode = $false
$legacyElapsedTooltip = $showElapsed.ToolTip

function Update-OverlayLayout {
    if ($script:outputMode) {
        $width = if ($script:overlayWindow.ActualWidth -gt 0) { $script:overlayWindow.ActualWidth } else { $script:overlayWindow.Width }
        $firstText.FontSize = $secondText.FontSize = if ($width -lt 400) { 14 } elseif ($width -lt 640) { 16 } else { 18 }
        $overlayContent.RowDefinitions[0].Height = [System.Windows.GridLength]::Auto
        $overlayContent.RowDefinitions[1].Height = [System.Windows.GridLength]::new(1, 'Star')
        $overlayContent.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(0)
        [System.Windows.Controls.Grid]::SetColumn($timerPanel, 0)
        $timerPanel.VerticalAlignment = 'Top'
        $timerPanel.HorizontalAlignment = 'Left'
        $timerPanel.Margin = [System.Windows.Thickness]::new(0,0,0,12)
        return
    }
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

function Set-ConversationBubble($Bubble, $Label, $Text, [bool]$IsInput, [string]$Summary) {
    $Bubble.HorizontalAlignment = if ($IsInput) { 'Right' } else { 'Left' }
    $Bubble.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($IsInput) { '#1557A5' } else { '#E9EDF2' }))
    $Label.Foreground = $Text.Foreground = if ($IsInput) { [System.Windows.Media.Brushes]::White } else { [System.Windows.Media.BrushConverter]::new().ConvertFromString('#202020') }
    $Label.Text = if ($IsInput) { 'You' } else { 'AI' }
    $Text.Text = $Summary
}

function Stop-ConversationTransition {
    $script:conversationTransitionTimer.Stop()
    $script:pendingConversation = $null
    $script:conversationTransitionPhase = 'idle'
    foreach ($element in @($conversationMessages, $firstBubble, $secondBubble)) {
        $element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $element.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    }
    $conversationArrow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
}

function Complete-ConversationTransition {
    $target = $script:pendingConversation
    if ($null -eq $target) { return }
    Stop-ConversationTransition
    Set-ConversationBubble $firstBubble $firstLabel $firstText $target.FirstInput $target.FirstSummary
    Set-ConversationBubble $secondBubble $secondLabel $secondText $target.SecondInput $target.SecondSummary
    $secondBubble.Visibility = if ($target.HasSecond) { 'Visible' } else { 'Collapsed' }
    $conversationArrow.Visibility = if ($target.Completed) { 'Visible' } else { 'Collapsed' }
    $script:displayedConversation = $target
    $conversationPanel.ScrollToTop()
    if ([System.Windows.SystemParameters]::ClientAreaAnimation) {
        $incoming = if ($target.RetainFirst) { $secondBubble } else { $conversationMessages }
        $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180))
        $incoming.BeginAnimation([System.Windows.UIElement]::OpacityProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(0, 1, $duration))
        $incoming.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(8, 0, $duration))
        if ($target.Completed) {
            $conversationArrow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(1, 0.35, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(700))))
        }
    }
    if (-not $script:overlayResized -and $script:outputMode) {
        $script:overlayWindow.Height = Get-OverlayConversationHeight $script:overlayWindow.Width
    }
}

$script:conversationTransitionTimer.Add_Tick({ Complete-ConversationTransition })

function Update-Conversation($Overlay, [switch]$Immediate) {
    $conversation = $Overlay.conversation
    $key = [string]$conversation.key
    if ($script:conversationKey -ceq $key) { return }
    $previous = $script:displayedConversation
    Stop-ConversationTransition
    $script:conversationKey = $key
    $script:conversationTransitionCount++
    $missing = 'Output summary missing. Generate or edit summaries before playback.'
    $inputSummary = [string]$Overlay.promptSummary
    if ([string]::IsNullOrWhiteSpace($inputSummary)) { $inputSummary = 'Input summary unavailable.' }
    $target = [pscustomobject]@{
        FirstInput = $true; FirstSummary = $inputSummary; SecondInput = $false
        SecondSummary = ''; HasSecond = $false; Completed = [bool]$conversation.completed
        RetainFirst = $false
    }
    if ($conversation.completed) {
        $outputSummary = [string]$conversation.outputSummary
        if ([string]::IsNullOrWhiteSpace($outputSummary)) { $outputSummary = $missing }
        $target.SecondSummary = $outputSummary
        $target.HasSecond = $true
    } elseif ([int]$conversation.exchange -gt 1) {
        $precedingOutput = [string]$conversation.previousOutputSummary
        if ([string]::IsNullOrWhiteSpace($precedingOutput)) { $precedingOutput = $missing }
        $target.FirstInput = $false
        $target.FirstSummary = $precedingOutput
        $target.SecondInput = $true
        $target.SecondSummary = $inputSummary
        $target.HasSecond = $true
    }
    $rollover = $null -ne $previous -and $previous.HasSecond -and $target.HasSecond -and
        $previous.SecondInput -eq $target.FirstInput -and $previous.SecondSummary -ceq $target.FirstSummary
    $target.RetainFirst = $rollover -or ($null -ne $previous -and $previous.FirstInput -eq $target.FirstInput -and $previous.FirstSummary -ceq $target.FirstSummary -and $target.HasSecond)
    $script:pendingConversation = $target
    if (-not $Immediate -and $null -ne $previous -and [System.Windows.SystemParameters]::ClientAreaAnimation) {
        $script:conversationTransitionPhase = 'outgoing'
        $duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(160))
        if ($rollover) {
            $firstBubble.BeginAnimation([System.Windows.UIElement]::OpacityProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(1, 0, $duration))
            $firstBubble.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(0, -8, $duration))
            $origin = $secondBubble.TranslatePoint([System.Windows.Point]::new(0, 0), $conversationMessages)
            $destination = $firstBubble.TranslatePoint([System.Windows.Point]::new(0, 0), $conversationMessages)
            $secondBubble.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(0, $destination.Y - $origin.Y, $duration))
            $conversationArrow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(1, 0, $duration))
        } elseif ($target.RetainFirst) {
            Complete-ConversationTransition
            return
        } else {
            $conversationMessages.BeginAnimation([System.Windows.UIElement]::OpacityProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(1, 0, $duration))
            $conversationMessages.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, [System.Windows.Media.Animation.DoubleAnimation]::new(0, -8, $duration))
        }
        $script:conversationTransitionTimer.Start()
        return
    }
    Complete-ConversationTransition
}

function Update-ReplayOverlays([switch]$MeasureOnly) {
    $overlay = $script:lastView.overlay
    $script:outputMode = [bool]$showOutput.IsChecked
    $conversationActive = $script:outputMode -and -not $script:stopping -and $overlay.conversation.active
    $showOutput.IsEnabled = -not $script:stopping -and [bool]$overlay.conversation.active
    $showPrompt.IsEnabled = -not $script:stopping -and -not [string]::IsNullOrWhiteSpace($overlay.promptSummary)
    $showElapsed.IsEnabled = -not $script:outputMode -and -not $script:stopping -and $null -ne $overlay.elapsed
    $showElapsed.ToolTip = if ($script:outputMode) { 'Working time is always shown at the top while Show summary of output is on. Turn it off to change this toggle.' } else { $legacyElapsedTooltip }
    $promptVisible = -not $script:outputMode -and $showPrompt.IsChecked -and $showPrompt.IsEnabled
    $timerVisible = $conversationActive -or ($showElapsed.IsChecked -and $showElapsed.IsEnabled)
    $promptPanel.Visibility = if ($promptVisible) { 'Visible' } else { 'Collapsed' }
    $conversationPanel.Visibility = if ($conversationActive) { 'Visible' } else { 'Collapsed' }
    $timerPanel.Visibility = if ($timerVisible) { 'Visible' } else { 'Collapsed' }
    $promptText.Text = $overlay.promptSummary
    $promptProgress.Text = $script:lastView.progress
    $elapsedText.Text = if ($script:outputMode -and $null -eq $overlay.elapsed) { 'Unavailable' } else { $overlay.elapsed }
    if ($conversationActive) { Update-Conversation $overlay -Immediate:$MeasureOnly } else {
        Stop-ConversationTransition
        $script:displayedConversation = $null
        $script:conversationKey = $null
    }
    $desiredWidth = if ($script:outputMode -or ($promptVisible -and $timerVisible)) { 820 } elseif ($promptVisible) { 720 } else { 238 }
    $script:overlayWindow.MinWidth = if ($script:outputMode -or $promptVisible) { 280 } else { 238 }
    Update-OverlayLayout
    if (-not $script:overlayResized) {
        $script:overlayWindow.Width = [Math]::Min($desiredWidth, $area.Width - 32)
        $script:overlayWindow.Height = if ($conversationActive) { Get-OverlayConversationHeight $script:overlayWindow.Width } elseif ($promptVisible) { Get-OverlayPromptHeight $script:overlayWindow.Width $timerVisible } else { 104 }
    }
    $script:overlayWindow.MinHeight = if ($script:outputMode -or $promptVisible) { 132 } else { 104 }
    Update-OverlayLayout
    if ($MeasureOnly) { return }
    if ($promptVisible -or $timerVisible) {
        $script:overlayWindow.Owner = $window
        if (-not $script:overlayWindow.IsVisible) { $script:overlayWindow.Show() }
    } else { $script:overlayWindow.Hide() }
}

function Get-OverlayConversationHeight([double]$Width) {
    $firstText.FontSize = $secondText.FontSize = if ($Width -lt 400) { 14 } elseif ($Width -lt 640) { 16 } else { 18 }
    $timerPanel.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $conversationMessages.Measure([System.Windows.Size]::new([Math]::Max(1, $Width - 58), [double]::PositiveInfinity))
    $height = 32 + $timerPanel.DesiredSize.Height + 12 + [Math]::Ceiling($conversationMessages.DesiredSize.Height)
    return [Math]::Min([Math]::Max(180, $height), [Math]::Max(132, $area.Height - 32))
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
$showOutput.Add_Checked({ Update-ReplayOverlays })
$showOutput.Add_Unchecked({ Update-ReplayOverlays })
$overlayFrame.Add_MouseLeftButtonDown({ $script:overlayWindow.DragMove() })
$script:overlayWindow.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:closeAllowed) { $eventArgs.Cancel = $true; $showPrompt.IsChecked = $false; $showElapsed.IsChecked = $false; $showOutput.IsChecked = $false }
})
$script:overlayWindow.Add_Closed({ Stop-ConversationTransition })