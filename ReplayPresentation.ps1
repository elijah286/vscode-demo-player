Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies PresentationFramework,PresentationCore,WindowsBase,System.Xaml -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Interop;
using System.Windows.Media;
public sealed class ReplayResizeTracker {
    public bool NativeResize { get; private set; }
    public ReplayResizeTracker(Window window) {
        window.SourceInitialized += (sender, args) => {
            HwndSource.FromHwnd(new WindowInteropHelper(window).Handle).AddHook(OnMessage);
        };
    }
    public IntPtr OnMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if (message == 0x0214) NativeResize = true;
        return IntPtr.Zero;
    }
}
public static class ReplayMessageFactory {
    private static readonly Brush Blue = new SolidColorBrush(Color.FromRgb(21, 87, 165));
    private static readonly Brush Neutral = new SolidColorBrush(Color.FromRgb(233, 237, 242));
    private static readonly Brush Dark = new SolidColorBrush(Color.FromRgb(32, 32, 32));
    public static Border Create(int index, bool input, string summary) {
        string name = index == 0 ? "First" : index == 1 ? "Second" : "Message" + index;
        Brush foreground = input ? Brushes.White : Dark;
        var label = new TextBlock { Text = input ? "You" : "AI", FontSize = 12, FontWeight = FontWeights.Bold, Foreground = foreground };
        var text = new TextBlock { Text = summary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0,4,0,0), Foreground = foreground };
        AutomationProperties.SetAutomationId(label, name + "Label");
        AutomationProperties.SetAutomationId(text, name + "Text");
        var stack = new StackPanel();
        stack.Children.Add(label);
        stack.Children.Add(text);
        if (!input) {
            var arrow = new TextBlock { Text = "\u2193", Foreground = Brushes.DimGray };
            AutomationProperties.SetAutomationId(arrow, "ConversationArrow" + index);
            AutomationProperties.SetName(arrow, "Input followed by output");
            stack.Children.Add(arrow);
        }
        return new Border { Child = stack, Padding = new Thickness(12,8,12,8), CornerRadius = new CornerRadius(10),
            Margin = new Thickness(0,4,0,4), HorizontalAlignment = input ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            ToolTip = "Saved summary shown in full. If its wording is clipped, edit it against the original in Select exchanges, or delete that summary and explicitly generate it again. Playback never regenerates summaries.",
            Background = input ? Blue : Neutral };
    }
}
'@

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
        <StackPanel x:Name="ConversationMessages"/>
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
$script:overlayResizeTracker = [ReplayResizeTracker]::new($script:overlayWindow)
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
$script:conversationKey = $null
$script:conversationTransitionCount = 0
$script:conversationRun = $null
$script:conversationHistory = @()
$script:conversationFontSize = 18
$script:missingOutputSummary = 'Output summary missing. Generate or edit summaries before playback.'
$script:conversationFollow = $true
$script:conversationFillTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:conversationFillTimer.Interval = [TimeSpan]::FromMilliseconds(16)
$conversationPanel.Add_ScrollChanged({
    param($sender, $eventArgs)
    if ($eventArgs.VerticalChange -lt 0 -and $eventArgs.ExtentHeightChange -eq 0 -and $eventArgs.ViewportHeightChange -eq 0) { $script:conversationFollow = $false }
    if ($script:conversationFollow -and ($eventArgs.ExtentHeightChange -ne 0 -or $eventArgs.ViewportHeightChange -ne 0)) {
        $conversationPanel.ScrollToEnd()
    }
})
$script:outputMode = $false
$legacyElapsedTooltip = $showElapsed.ToolTip

function Update-OverlayLayout {
    if ($script:outputMode) {
        $width = if ($script:overlayWindow.ActualWidth -gt 0) { $script:overlayWindow.ActualWidth } else { $script:overlayWindow.Width }
        Set-ConversationFontSize $width
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

function Stop-ConversationTransition {
    $script:conversationFillTimer.Stop()
    foreach ($element in $conversationMessages.Children) {
        $element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    }
}

function Set-ConversationFontSize([double]$Width) {
    $fontSize = if ($Width -lt 400) { 14 } elseif ($Width -lt 640) { 16 } else { 18 }
    if ($script:conversationFontSize -eq $fontSize) { return }
    $script:conversationFontSize = $fontSize
    foreach ($bubble in $conversationMessages.Children) {
        $bubble.Child.Children[1].FontSize = $fontSize
    }
}

function Add-ConversationMessages {
    $start = $conversationMessages.Children.Count
    $limit = [Math]::Min($start + 4, $script:conversationHistory.Count)
    for ($index = $start; $index -lt $limit; $index++) {
        $message = $script:conversationHistory[$index]
        $summary = [string]$message.text
        if ([string]::IsNullOrWhiteSpace($summary)) {
            $summary = if ($message.input) { 'Input summary unavailable.' } else { $script:missingOutputSummary }
        }
        $bubble = [ReplayMessageFactory]::Create($index, [bool]$message.input, $summary)
        $bubble.Child.Children[1].FontSize = $script:conversationFontSize
        $conversationMessages.Children.Add($bubble) | Out-Null
        if ($script:conversationAnimate -and [System.Windows.SystemParameters]::ClientAreaAnimation) {
            $bubble.BeginAnimation([System.Windows.UIElement]::OpacityProperty,
                [System.Windows.Media.Animation.DoubleAnimation]::new(0, 1, [TimeSpan]::FromMilliseconds(180)))
        }
    }
    if (-not ($script:overlayResized -or $script:overlayResizeTracker.NativeResize) -and $script:outputMode -and
        $script:overlayWindow.Height -lt [Math]::Min(600, [Math]::Max(132, $area.Height - 32))) {
        $script:overlayWindow.Height = Get-OverlayConversationHeight $script:overlayWindow.Width
    }
    if ($script:conversationFollow -and $limit -gt $start) { $conversationPanel.ScrollToEnd() }
    if ($limit -ge $script:conversationHistory.Count) { $script:conversationFillTimer.Stop() }
    else { $script:conversationFillTimer.Start() }
}

$script:conversationFillTimer.Add_Tick({ Add-ConversationMessages })

function Update-Conversation($Overlay, [switch]$Immediate) {
    $conversation = $Overlay.conversation
    $key = [string]$conversation.key
    if ($script:conversationKey -ceq $key -and $script:conversationRun -ceq $conversation.run) { return }
    $history = @($conversation.history)
    if ($history.Count -gt 200) { throw 'Conversation exceeds the 100-exchange playback limit.' }
    $reset = $script:conversationRun -cne $conversation.run -or $history.Count -lt $script:conversationHistory.Count
    if (-not $reset) {
        for ($index = 0; $index -lt $script:conversationHistory.Count; $index++) {
            $before = $script:conversationHistory[$index]
            $after = $history[$index]
            if ($before.id -cne $after.id -or $before.text -cne $after.text -or $before.input -ne $after.input) { $reset = $true; break }
        }
    }
    $follow = $reset -or $conversationPanel.ScrollableHeight - $conversationPanel.VerticalOffset -lt 24
    if ($reset) {
        Stop-ConversationTransition
        $conversationMessages.Children.Clear()
        $script:conversationHistory = @()
    }
    for ($index = $script:conversationHistory.Count; $index -lt $history.Count; $index++) {
        if ($history[$index].input) { $follow = $true }
    }
    $script:conversationHistory = $history
    $script:conversationRun = $conversation.run
    $script:conversationKey = $key
    $script:conversationTransitionCount++
    Set-ConversationFontSize $script:overlayWindow.Width
    $script:conversationFollow = $follow
    $script:conversationAnimate = -not $Immediate
    Add-ConversationMessages
}

function Update-ReplayOverlays([switch]$MeasureOnly) {
    if (Get-Command Update-PlaybackEstimate -ErrorAction SilentlyContinue) { Update-PlaybackEstimate }
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
        $conversationMessages.Children.Clear()
        $script:conversationHistory = @()
        $script:conversationRun = $null
        $script:conversationKey = $null
    }
    $desiredWidth = if ($script:outputMode -or ($promptVisible -and $timerVisible)) { 820 } elseif ($promptVisible) { 720 } else { 238 }
    $script:overlayWindow.MinWidth = if ($script:outputMode -or $promptVisible) { 280 } else { 238 }
    Update-OverlayLayout
    if (-not ($script:overlayResized -or $script:overlayResizeTracker.NativeResize)) {
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
    Set-ConversationFontSize $Width
    $timerPanel.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $conversationMessages.Measure([System.Windows.Size]::new([Math]::Max(1, $Width - 58), [double]::PositiveInfinity))
    $height = 32 + $timerPanel.DesiredSize.Height + 12 + [Math]::Ceiling($conversationMessages.DesiredSize.Height)
    return [Math]::Min([Math]::Max(180, $height), [Math]::Min(600, [Math]::Max(132, $area.Height - 32)))
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