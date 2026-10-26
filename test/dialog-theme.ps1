param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'DemoDialogs.ps1')
$count = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Layout($Window) {
    $width = if ([double]::IsNaN($Window.Width)) { 600 } else { $Window.Width }
    $height = if ([double]::IsNaN($Window.Height)) { 600 } else { $Window.Height }
    $width -= 16
    $height -= 40
    $Window.Content.Measure([Windows.Size]::new($width, $height))
    $Window.Content.Arrange([Windows.Rect]::new(0, 0, $width, $height))
    $Window.Content.UpdateLayout()
}
function Get-RenderedText($Visual) {
    if ($Visual -is [Windows.Controls.TextBlock]) { $Visual.Text }
    for ($index = 0; $index -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Visual); $index++) {
        Get-RenderedText ([Windows.Media.VisualTreeHelper]::GetChild($Visual, $index))
    }
}
$windows = [Collections.Generic.List[Windows.Window]]::new()
try {
    foreach ($file in @('DemoDialogs.ps1', 'PlayerAI.ps1', 'PlayerUpdates.ps1')) {
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$null, [ref]$errors)
        Assert (-not $errors) "$file must parse."
        foreach ($literal in $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.TrimStart().StartsWith('<Window')
        }, $true)) {
            $window = New-DemoDialog $literal.Value $null
            $windows.Add($window)
            Layout $window
            Assert ($window.Content.ActualWidth -gt 0) "$($window.Title) must lay out."
            if (-not [Windows.SystemParameters]::HighContrast) {
                Assert ($window.Background.ToString() -eq '#FF1F2D2D') "$($window.Title) must share the controller surface."
                Assert ($window.Foreground.ToString() -eq '#FFDEEAE4') "$($window.Title) must use readable foreground."
                Assert ([object]::ReferenceEquals($window.Resources.MergedDictionaries[0], $script:DemoDialogTheme)) 'Dialogs must reuse parsed resources.'
            }
            if ($window.FindName('PickerTabs')) { $picker = $window; $pickerMarkup = $literal.Value }
            if ($window.FindName('Key')) {
                Assert ($window.FindName('Key') -is [Windows.Controls.PasswordBox]) 'API keys must remain masked.'
            }
        }
    }
    Assert ($windows.Count -ge 10) 'All preparation, progress, settings, translation and update dialogs must be exercised.'
    $sessions = $picker.FindName('Sessions')
    $sessions.ItemsSource = @(0..4999 | ForEach-Object {
        [pscustomobject]@{ Title = "Synthetic interaction $_"; Project = 'Demo project'; Agent = 'Demo agent'
            LastActivity = [datetime]'2026-10-26'; Started = [datetime]'2026-10-25'; Prompts = 4
            Duration = '0:03:12'; DurationSeconds = 192; Source = 'Synthetic'; Status = 'Ready'; Detail = 'Synthetic fixture only' }
    })
    Layout $picker
    Assert ($sessions.EnableRowVirtualization -and $sessions.EnableColumnVirtualization) 'History grid must virtualize both dimensions.'
    Assert ([Windows.Controls.VirtualizingPanel]::GetVirtualizationMode($sessions) -eq 'Recycling') 'History rows must be recycled.'
    $realized = 0
    foreach ($index in 0..4999) {
        if ($null -ne $sessions.ItemContainerGenerator.ContainerFromIndex($index)) { $realized++ }
    }
    Assert ($realized -gt 0 -and $realized -lt 100) "Only visible history rows should be realized, got $realized of 5000."
    $sessions.ScrollIntoView($sessions.Items[4999])
    Layout $picker
    Assert ($null -ne $sessions.ItemContainerGenerator.ContainerFromIndex(4999)) 'Virtualized history must scroll to its last conversation.'
    $afterScroll = 0
    foreach ($index in 0..4999) {
        if ($null -ne $sessions.ItemContainerGenerator.ContainerFromIndex($index)) { $afterScroll++ }
    }
    Assert ($afterScroll -lt 100) "Scrolling must keep history realization bounded, got $afterScroll of 5000."
    Assert ($picker.FindName('Reviewed').IsChecked -ne $true) 'Privacy review must not be pre-accepted.'
    Assert (-not $picker.FindName('Save').IsEnabled) 'Empty selection must not enable playback.'
    $tabs = $picker.FindName('PickerTabs')
    $tabs.SelectedIndex = 1
    Layout $picker
    Assert ($tabs.SelectedContent -eq $picker.FindName('Demos').Parent) 'Saved selections tab must remain reachable.'
    Assert ([Windows.Controls.VirtualizingPanel]::GetIsVirtualizing($picker.FindName('Demos'))) 'Saved library must virtualize.'
    $tabs.SelectedIndex = 0
    $picker.Width = $picker.MinWidth
    $picker.Height = $picker.MinHeight
    Layout $picker
    $save = $picker.FindName('Save')
    $bounds = $save.TransformToAncestor($picker.Content).TransformBounds([Windows.Rect]::new(0, 0, $save.ActualWidth, $save.ActualHeight))
    Assert ($bounds.Right -le $picker.Content.ActualWidth -and $bounds.Bottom -le $picker.Content.ActualHeight) 'Primary capture action must fit at the minimum dialog size, allowing for native window chrome.'
    $picker.Width = 1180
    $picker.Height = 872
    $tabs.SelectedIndex = 0
    $sessions.SelectedIndex = 0
    $sessions.ScrollIntoView($sessions.Items[0])
    foreach ($spec in @(@('ProjectFilter', 'All projects'), @('AgentFilter', 'All agents'))) {
        $filter = $picker.FindName($spec[0])
        $filter.Items.Add([pscustomobject]@{ Label = $spec[1]; Value = '*' }) | Out-Null
        $filter.SelectedIndex = 0
    }
    $picker.FindName('Turns').ItemsSource = @(
        [pscustomobject]@{ Label = '1. Prepare the demonstration' },
        [pscustomobject]@{ Label = '2. Review the recorded answer' },
        [pscustomobject]@{ Label = '3. Replay selected exchanges' }
    )
    $picker.FindName('DiscoveryNote').Text = 'Local conversations - synthetic preview'
    $picker.FindName('SelectionCount').Text = 'Choose exchanges to preview'
    $picker.FindName('Preview').Text = "Review original content here before playback.`r`nOriginal recordings are never changed."
    Layout $picker
    Assert (@(Get-RenderedText ($picker.FindName('ProjectFilter'))) -contains 'All projects') 'Project selection must display its label, not an object serialization.'
    Assert (@(Get-RenderedText ($picker.FindName('AgentFilter'))) -contains 'All agents') 'Agent selection must display its label, not an object serialization.'
    $evidence = Join-Path $root '.build\dialog-theme'
    [IO.Directory]::CreateDirectory($evidence) | Out-Null
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$picker.Content.ActualWidth, [int]$picker.Content.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($picker.Content)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $evidence 'interaction-picker.png'))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $contrastFactory = [scriptblock]::Create(${function:New-DemoDialog}.ToString().Replace('[System.Windows.SystemParameters]::HighContrast', '$true'))
    $contrastWindow = & $contrastFactory @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
 <TextBlock x:Name="Error" Foreground="#B00020"/>
</Window>
'@ $null
    try {
        Assert ($contrastWindow.Resources.MergedDictionaries.Count -eq 0) 'High contrast must bypass the custom palette.'
        Assert ($contrastWindow.Content -is [Windows.Controls.TextBlock]) 'High contrast must retain native content and chrome.'
        Assert ($contrastWindow.FindName('Error').Foreground -eq [Windows.SystemColors]::WindowTextBrush) 'High-contrast error text must use system colors.'
    } finally { $contrastWindow.Close() }
    $smallFactory = [scriptblock]::Create(${function:New-DemoDialog}.ToString().Replace(
        '[System.Windows.SystemParameters]::WorkArea', '([System.Windows.Rect]::new(0, 0, 800, 600))'))
    $smallWindow = & $smallFactory $pickerMarkup $null
    try {
        $smallWindow.FindName('Sessions').ItemsSource = $sessions.ItemsSource
        Layout $smallWindow
        Assert ($smallWindow.Width -eq 776 -and $smallWindow.Height -eq 576) 'Dialogs must fit a small work area without changing global display settings.'
        $viewport = $smallWindow.Content
        Assert ($viewport -is [Windows.Controls.ScrollViewer]) 'Small work areas must provide a scrollable fallback.'
        $viewport.ScrollToRightEnd()
        $viewport.ScrollToBottom()
        Layout $smallWindow
        $action = $smallWindow.FindName('Save')
        $bounds = $action.TransformToAncestor($viewport).TransformBounds([Windows.Rect]::new(0, 0, $action.ActualWidth, $action.ActualHeight))
        Assert ($bounds.Top -ge 0 -and $bounds.Bottom -le $viewport.ActualHeight -and $bounds.Right -le $viewport.ActualWidth) 'The primary action must remain reachable on a small work area.'
        $smallRows = $smallWindow.FindName('Sessions')
        $smallRealized = 0
        foreach ($index in 0..4999) {
            if ($null -ne $smallRows.ItemContainerGenerator.ContainerFromIndex($index)) { $smallRealized++ }
        }
        Assert ($smallRealized -gt 0 -and $smallRealized -lt 100) 'Outer scrolling must not disable inner history virtualization.'
    } finally { $smallWindow.Close() }
    $scrollWindow = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="360" Height="300">
 <ScrollViewer x:Name="Scroll" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Auto">
  <Border Width="2000" Height="2000"/>
 </ScrollViewer>
</Window>
'@ $null
    try {
        Layout $scrollWindow
        $scroll = $scrollWindow.FindName('Scroll')
        $scroll.ScrollToHorizontalOffset(100)
        $scroll.ScrollToVerticalOffset(100)
        Layout $scrollWindow
        Assert ($scroll.HorizontalOffset -eq 100 -and $scroll.VerticalOffset -eq 100) 'Themed scrollbars must preserve both scroll axes.'
        foreach ($axis in @('Horizontal', 'Vertical')) {
            $bar = $scroll.Template.FindName("PART_${axis}ScrollBar", $scroll)
            $track = $bar.Template.FindName('PART_Track', $bar)
            Assert ($null -ne $track) "$axis scrollbar must expose its standard track."
            Assert ($track.Maximum -eq $bar.Maximum -and $track.Value -eq $bar.Value) "$axis track must retain range bindings."
            $page = $bar.Template.FindName('PageForward', $bar)
            if (-not [Windows.SystemParameters]::HighContrast) {
                $before = if ($axis -eq 'Horizontal') { $scroll.HorizontalOffset } else { $scroll.VerticalOffset }
                $page.Command.Execute($null, $page)
                Layout $scrollWindow
                $after = if ($axis -eq 'Horizontal') { $scroll.HorizontalOffset } else { $scroll.VerticalOffset }
                Assert ($after -gt $before) "$axis scrollbar page command must scroll in the correct direction."
            }
        }
    } finally { $scrollWindow.Close() }
    Write-Output "Dialog theme: $count assertions passed across $($windows.Count) real WPF dialogs; $realized/5000 history rows realized. Offscreen evidence: $evidence"
} finally {
    foreach ($window in $windows) { $window.Close() }
    [VibeReplay.LibraryConnections]::Close()
}
