param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$area = [System.Windows.Rect]::new(0, 0, 1920, 1080)
$window = [System.Windows.Window]::new()
$showPrompt = [System.Windows.Controls.CheckBox]::new()
$showElapsed = [System.Windows.Controls.CheckBox]::new()
$showOutput = [System.Windows.Controls.CheckBox]::new()
$frameColor = [System.Windows.Controls.Button]::new()
$frameColorSwatch = [System.Windows.Controls.Border]::new()
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ReplayPresentation.ps1')
$assertions = 0

function Assert-Layout([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}

function Wait-ConversationTransition {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $waitTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $waitTimer.Interval = [TimeSpan]::FromMilliseconds(350)
    $waitTimer.Add_Tick({ $waitTimer.Stop(); $frame.Continue = $false }.GetNewClosure())
    $waitTimer.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $waitTimer.Stop() }
    Assert-Layout ($null -eq $script:pendingConversation -and -not $script:conversationTransitionTimer.IsEnabled) 'The real dispatcher must finish the queued outgoing/incoming transition.'
}

function Get-TimerGeometry {
    $origin = $timerPanel.TranslatePoint([System.Windows.Point]::new(0, 0), $script:overlayWindow.Content)
    return [System.Windows.Rect]::new($origin.X, $origin.Y, $timerPanel.ActualWidth, $timerPanel.ActualHeight)
}

function Arrange-Overlay([double]$Width, [double]$Height, [bool]$Prompt = $true, [bool]$Timer = $true) {
    $script:overlayWindow.Width = $Width
    $script:overlayWindow.Height = $Height
    $promptPanel.Visibility = if ($Prompt) { 'Visible' } else { 'Collapsed' }
    $timerPanel.Visibility = if ($Timer) { 'Visible' } else { 'Collapsed' }
    Update-OverlayLayout
    $size = [System.Windows.Size]::new($Width, $Height)
    $script:overlayWindow.Content.Measure($size)
    $script:overlayWindow.Content.Arrange([System.Windows.Rect]::new($size))
    $script:overlayWindow.Content.UpdateLayout()
}

try {
    $promptText.Text = ('A synthetic summary that wraps across the available width. ' * 3).Trim()
    $promptProgress.Text = '1/24'
    foreach ($height in @(132, 180, 500)) {
        foreach ($width in @(280, 320, 480, 639, 640, 820)) {
            Arrange-Overlay $width $height
            $stacked = $width -lt 640
            Assert-Layout ([System.Windows.Controls.Grid]::GetRow($promptPanel) -eq [int]$stacked) "Incorrect prompt row at ${width}x${height}."
            Assert-Layout ([System.Windows.Controls.Grid]::GetColumn($timerPanel) -eq $(if ($stacked) { 0 } else { 1 })) "Incorrect timer column at ${width}x${height}."
            $promptOrigin = $promptPanel.TranslatePoint([System.Windows.Point]::new(0, 0), $overlayContent)
            $timerOrigin = $timerPanel.TranslatePoint([System.Windows.Point]::new(0, 0), $overlayContent)
            if ($stacked) {
                Assert-Layout ([Math]::Abs($promptPanel.ActualWidth - $overlayContent.ActualWidth) -lt 1) "Summary does not use full width at ${width}x${height}."
                Assert-Layout ($promptOrigin.Y -ge $timerOrigin.Y + $timerPanel.ActualHeight + 11) "Timer is not above the summary at ${width}x${height}."
                Assert-Layout ([Math]::Abs($promptOrigin.Y + $promptPanel.ActualHeight - $overlayContent.ActualHeight) -lt 1) "Summary does not use remaining height at ${width}x${height}."
                Assert-Layout ($timerOrigin.Y -eq 0) "Timer is not at the top at ${width}x${height}."
            } else {
                Assert-Layout ($promptOrigin.Y -eq 0) "Wide summary does not start at the top at ${width}x${height}."
                Assert-Layout ($timerOrigin.X -ge $promptPanel.ActualWidth + 23) "Wide timer is not beside the summary at ${width}x${height}."
            }
            Assert-Layout ($promptPanel.ActualHeight -gt 0) "Summary has no remaining height at ${width}x${height}."
            Assert-Layout ($script:overlayWindow.Width -eq $width -and $script:overlayWindow.Height -eq $height) 'Layout reset the user dimensions.'
        }
    }
    foreach ($width in @(280, 480, 820)) {
        Arrange-Overlay $width 320 $true $false
        Assert-Layout ([System.Windows.Controls.Grid]::GetRow($promptPanel) -eq 0 -and [Math]::Abs($promptPanel.ActualWidth - $overlayContent.ActualWidth) -lt 1) "Summary-only layout reserved timer space at $width."
        Arrange-Overlay $width 320 $false $true
        Assert-Layout ([System.Windows.Controls.Grid]::GetColumn($timerPanel) -eq 1 -and $timerPanel.Margin.Left -eq 0) "Timer-only layout has a phantom summary gap at $width."
        Arrange-Overlay $width 320
        Assert-Layout ([System.Windows.Controls.Grid]::GetRow($promptPanel) -eq $(if ($width -lt 640) { 1 } else { 0 })) "Combined layout did not recover after toggles at $width."
    }
    Arrange-Overlay 320 500
    $narrowTextHeight = $promptText.DesiredSize.Height
    Arrange-Overlay 639 500
    Assert-Layout ($narrowTextHeight -gt $promptText.DesiredSize.Height) 'Text did not rewrap when narrowing the stacked layout.'
    Assert-Layout ($promptText.TextWrapping -eq 'Wrap') 'Wrapping was disabled.'
    Assert-Layout ($elapsedText.Text -eq '00:00:00' -and $promptProgress.Text -eq '1/24') 'Layout modified timing or progress.'
    $scroll = @($promptPanel.Children | Where-Object { $_ -is [System.Windows.Controls.ScrollViewer] })[0]
    foreach ($text in @(('W' * 300), ('A faithful synthetic summary of the original request. ' * 6).Substring(0,300), ([string][char]0x754C * 300))) {
        $promptText.Text = $text
        foreach ($layout in @(@{ Width = 720; Timer = $false }, @{ Width = 820; Timer = $true }, @{ Width = 480; Timer = $true }, @{ Width = 280; Timer = $true })) {
            Arrange-Overlay $layout.Width 500 $true $layout.Timer
            $height = Get-OverlayPromptHeight $layout.Width $layout.Timer
            Arrange-Overlay $layout.Width $height $true $layout.Timer
            Assert-Layout ($promptText.Text.Length -eq 300) 'The exact summary budget was shortened.'
            Assert-Layout ($scroll.ScrollableHeight -lt 1) "A 300-character summary does not fit the auto-sized ${height} high overlay at width $($layout.Width), timer $($layout.Timer). Scrollable height $($scroll.ScrollableHeight)."
            Assert-Layout ($height -le $area.Height - 32) 'Automatic sizing exceeds the work area.'
        }
    }
    Arrange-Overlay 280 132
    Assert-Layout ($scroll.ScrollableHeight -gt 0) 'A manually shortened overlay must scroll instead of truncating.'
    Assert-Layout (-not $showOutput.IsChecked) 'Output summaries must default off.'
    # Detached checkboxes let state tests drive the real updater without showing any windows.
    $showOutput = [System.Windows.Controls.CheckBox]::new()
    $showPrompt = [System.Windows.Controls.CheckBox]::new()
    $showElapsed = [System.Windows.Controls.CheckBox]::new()
    $showOutput.IsChecked = $true
    $script:lastView = [pscustomobject]@{
        progress = '1/2'
        overlay = [pscustomobject]@{
            promptSummary = 'Input 1'
            elapsed = $null
            conversation = [pscustomobject]@{
                exchange = 1; completed = $false; previousOutputSummary = $null
                outputSummary = $null; key = 'run1:1:input'; active = $true
            }
        }
    }
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($firstText.Text -eq 'Input 1' -and $firstLabel.Text -eq 'You' -and $secondBubble.Visibility -eq 'Collapsed') 'Ready must show Input 1 only.'
    Assert-Layout ($conversationPanel.Visibility -eq 'Visible' -and -not $showPrompt.IsChecked) 'Conversation input must not depend on Show prompt summary.'
    Assert-Layout ($timerPanel.Visibility -eq 'Visible' -and $elapsedText.Text -eq 'Unavailable') 'Untimed conversation must keep its timer header.'
    Assert-Layout (-not $showElapsed.IsEnabled -and $showElapsed.ToolTip -like '*always shown at the top*') 'Elapsed toggle must explain why it is disabled.'
    $state = $script:lastView.overlay.conversation
    $state.completed = $true
    $state.outputSummary = 'Output 1'
    $state.key = 'run1:1:output'
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($firstText.Text -eq 'Input 1' -and $secondText.Text -eq 'Output 1' -and $secondLabel.Text -eq 'AI') 'First completion must pair Input 1 and Output 1.'
    Assert-Layout ($conversationArrow.Visibility -eq 'Visible') 'Completed pair must have a semantic down arrow.'
    Assert-Layout (($conversationMessages.HasAnimatedProperties -or $secondBubble.HasAnimatedProperties) -eq [System.Windows.SystemParameters]::ClientAreaAnimation) 'Conversation motion must respect the system animation setting.'
    Assert-Layout ($firstBubble.HorizontalAlignment -eq 'Right' -and $secondBubble.HorizontalAlignment -eq 'Left') 'You must be right aligned and AI left aligned.'
    Assert-Layout ($firstBubble.Background.ToString() -eq '#FF1557A5' -and $firstText.Foreground.ToString() -eq '#FFFFFFFF') 'You needs contrasting white text on blue.'
    Assert-Layout ($secondBubble.Background.ToString() -eq '#FFE9EDF2' -and $secondText.Foreground.ToString() -eq '#FF202020') 'AI needs contrasting dark text on neutral.'
    $transitions = $script:conversationTransitionCount
    foreach ($elapsed in @('00:00:01', '00:00:02', '00:00:02')) {
        $script:lastView.overlay.elapsed = $elapsed
        Update-ReplayOverlays -MeasureOnly
    }
    Assert-Layout ($script:conversationTransitionCount -eq $transitions) 'Polling, elapsed changes or pause must not replay the transition.'
    Assert-Layout ($elapsedText.Text -eq '00:00:02') 'Conversation must use the existing cumulative elapsed value.'
    Assert-Layout (-not $timerPanel.HasAnimatedProperties -and -not $overlayContent.HasAnimatedProperties) 'Do not animate the timer or the whole panel.'
    $state.exchange = 2
    $state.completed = $false
    $state.previousOutputSummary = 'Output 1'
    $state.outputSummary = $null
    $state.key = 'run1:2:input'
    $script:lastView.overlay.promptSummary = 'Input 2'
    Arrange-Overlay 820 400 $false $true
    $timerBeforeTransition = Get-TimerGeometry
    Update-Conversation $script:lastView.overlay
    Assert-Layout ((Get-TimerGeometry) -eq $timerBeforeTransition) 'Next outgoing motion must not change actual WPF timer geometry.'
    if ([System.Windows.SystemParameters]::ClientAreaAnimation) {
        Assert-Layout ($script:conversationTransitionPhase -eq 'outgoing' -and $firstText.Text -eq 'Input 1' -and $secondText.Text -eq 'Output 1') 'Next must retain the old pair during the outgoing animation, not replace it immediately.'
        Assert-Layout ($firstBubble.HasAnimatedProperties -and $secondBubble.RenderTransform.HasAnimatedProperties) 'Next must fade old input while the retained output moves up.'
        $transitions = $script:conversationTransitionCount
        Update-Conversation $script:lastView.overlay
        Assert-Layout ($script:conversationTransitionCount -eq $transitions -and $script:conversationTransitionPhase -eq 'outgoing') 'Polling during an outgoing animation must not cancel or restart it.'
        Wait-ConversationTransition
    }
    Update-ReplayOverlays -MeasureOnly
    Arrange-Overlay 820 (Get-OverlayConversationHeight 820) $false $true
    Assert-Layout ((Get-TimerGeometry) -eq $timerBeforeTransition) 'Next incoming layout must preserve actual WPF timer geometry.'
    Assert-Layout ($firstLabel.Text -eq 'AI' -and $firstText.Text -eq 'Output 1' -and $secondLabel.Text -eq 'You' -and $secondText.Text -eq 'Input 2') 'Next input must retain only the preceding output above Input 2.'
    Assert-Layout ($conversationArrow.Visibility -eq 'Collapsed') 'Do not imply that previous output is the current response.'
    $state.completed = $true
    $state.outputSummary = 'Output 2'
    $state.key = 'run1:2:output'
    Arrange-Overlay 820 400 $false $true
    $timerBeforeTransition = Get-TimerGeometry
    Update-Conversation $script:lastView.overlay
    Assert-Layout ((Get-TimerGeometry) -eq $timerBeforeTransition) 'Completion outgoing motion must not change actual WPF timer geometry.'
    if ([System.Windows.SystemParameters]::ClientAreaAnimation) {
        Assert-Layout ($script:conversationTransitionPhase -eq 'outgoing' -and $firstText.Text -eq 'Output 1' -and $secondText.Text -eq 'Input 2') 'Completion must keep the prior output visible until its outgoing fade finishes.'
        Assert-Layout ($firstBubble.HasAnimatedProperties -and $secondBubble.RenderTransform.HasAnimatedProperties) 'Completion must fade the prior output and slide the current input upward.'
        Wait-ConversationTransition
    }
    Update-ReplayOverlays -MeasureOnly
    Arrange-Overlay 820 (Get-OverlayConversationHeight 820) $false $true
    Assert-Layout ((Get-TimerGeometry) -eq $timerBeforeTransition) 'Completion incoming layout must preserve actual WPF timer geometry.'
    Assert-Layout ($firstText.Text -eq 'Input 2' -and $secondText.Text -eq 'Output 2') 'Second completion must discard Output 1 and pair Input 2 with Output 2.'
    foreach ($id in @('FirstLabel', 'FirstText', 'SecondLabel', 'SecondText', 'ConversationArrow', 'ElapsedText')) {
        $element = $script:overlayWindow.FindName($id)
        $peer = [System.Windows.Automation.Peers.TextBlockAutomationPeer]::new($element)
        Assert-Layout ($peer.GetAutomationId() -ceq $id) "Missing stable automation ID $id."
        $expectedName = if ($id -eq 'ConversationArrow') { 'Input followed by output' } else { $element.Text }
        Assert-Layout ($peer.GetName() -ceq $expectedName) "Incorrect automation name for $id."
    }
    foreach ($text in @(('W' * 300), ('A faithful synthetic summary of the original request. ' * 6).Substring(0,300), ([string][char]0x754C * 300))) {
        $script:lastView.overlay.promptSummary = $text
        $state.outputSummary = $text
        $state.key += ':text'
        Update-ReplayOverlays -MeasureOnly
        foreach ($width in @(280, 320, 480, 639, 640, 820)) {
            $height = Get-OverlayConversationHeight $width
            Arrange-Overlay $width $height $false $true
            Assert-Layout ($conversationPanel.ScrollableHeight -lt 1) "Two 300-character bubbles must fit automatic height ${height} at width $width; scroll $($conversationPanel.ScrollableHeight)."
            Assert-Layout ($height -le $area.Height - 32) 'Conversation automatic height exceeds the work area.'
            $timerOrigin = $timerPanel.TranslatePoint([System.Windows.Point]::new(0, 0), $overlayContent)
            $conversationOrigin = $conversationPanel.TranslatePoint([System.Windows.Point]::new(0, 0), $overlayContent)
            Assert-Layout ($timerOrigin.Y -eq 0 -and $conversationOrigin.Y -ge $timerPanel.ActualHeight + 11) "Conversation timer must stay fixed at the top at width $width."
            Assert-Layout ($firstText.Text.Length -eq 300 -and $secondText.Text.Length -eq 300) 'Conversation summaries must not be shortened.'
        }
    }
    Arrange-Overlay 280 132 $false $true
    Assert-Layout ($conversationPanel.ScrollableHeight -gt 0 -and $conversationPanel.ViewportHeight -gt 0) 'Manual conversation sizes must scroll two bubbles below the fixed timer.'
    $state.outputSummary = $null
    $state.key = 'run1:2:missing'
    Update-ReplayOverlays -MeasureOnly
    $missing = 'Output summary missing. Generate or edit summaries before playback.'
    Assert-Layout ($secondText.Text -eq $missing) 'Missing output must not fall back to input or raw content.'
    $state.completed = $false
    $state.previousOutputSummary = $null
    $state.key = 'run1:2:previous-missing'
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($firstText.Text -eq $missing) 'Missing preceding output must be explicit.'
    $state.key = 'pending-before-stop:2:false'
    $script:lastView.overlay.promptSummary = 'Pending input that must never reappear'
    Update-Conversation $script:lastView.overlay
    $state.active = $false
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($conversationPanel.Visibility -eq 'Collapsed' -and $timerPanel.Visibility -eq 'Collapsed' -and $null -eq $script:conversationKey) 'Stop/error must hide conversation and clear semantic identity.'
    Assert-Layout ($null -eq $script:pendingConversation -and -not $script:conversationTransitionTimer.IsEnabled) 'Stop must cancel pending transitions so they cannot restore stale bubbles.'
    $state.active = $true
    $script:stopping = $true
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($conversationPanel.Visibility -eq 'Collapsed' -and -not $showOutput.IsEnabled) 'An in-flight stop must hide conversation even before the next server view.'
    $script:stopping = $false
    $state.active = $true
    $state.exchange = 1
    $state.key = 'run2:1:input'
    $script:lastView.overlay.promptSummary = 'Restarted input'
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($firstText.Text -eq 'Restarted input' -and $secondBubble.Visibility -eq 'Collapsed') 'Restart/demo selection must not retain preceding bubbles.'
    $transitions = $script:conversationTransitionCount
    $state.key = 'other-demo:1:input'
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($script:conversationTransitionCount -eq $transitions + 1) 'A new playback identity must transition even at the same exchange.'
    $showOutput.IsChecked = $false
    $showElapsed.IsChecked = $true
    $showPrompt.IsChecked = $true
    $script:overlayResized = $false
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($showElapsed.IsEnabled -and $showElapsed.IsChecked -and $showPrompt.IsChecked) 'Turning output off must restore retained legacy toggles.'
    Assert-Layout ($conversationPanel.Visibility -eq 'Collapsed' -and $promptPanel.Visibility -eq 'Visible') 'Output off must restore the legacy prompt.'
    Arrange-Overlay 820 180
    Assert-Layout ([System.Windows.Controls.Grid]::GetColumn($timerPanel) -eq 1 -and [System.Windows.Controls.Grid]::GetRow($promptPanel) -eq 0) 'Output off must restore the exact legacy wide layout.'
    Assert-Layout (-not $script:overlayWindow.IsVisible -and -not $window.IsVisible) 'Layout tests must never show windows.'
    $controllerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Show-ReplayController.ps1'
    $tokens = $parseErrors = $null
    $controllerAst = [System.Management.Automation.Language.Parser]::ParseFile($controllerPath, [ref]$tokens, [ref]$parseErrors)
    Assert-Layout ($parseErrors.Count -eq 0) 'Controller must parse successfully.'
    $layoutAssignment = $controllerAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '[xml]$layout'
    }, $true)
    $layoutLiteral = $layoutAssignment.Right.Find({ param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true)
    $controllerXml = [xml]$layoutLiteral.Value
    $controllerReader = [System.Xml.XmlNodeReader]::new($controllerXml)
    try { $controllerWindow = [System.Windows.Markup.XamlReader]::Load($controllerReader) } finally { $controllerReader.Dispose() }
    try {
        $outputControl = $controllerWindow.FindName('ShowOutput')
        Assert-Layout ($outputControl.Content -ceq 'Show summary of output' -and -not $outputControl.IsChecked) 'Controller output toggle needs the exact ASCII label and must default off.'
        Assert-Layout ([System.Windows.Controls.ToolTipService]::GetShowOnDisabled($controllerWindow.FindName('ShowElapsed'))) 'The disabled elapsed toggle must still display its explanation tooltip.'
        $controllerSize = [System.Windows.Size]::new($controllerWindow.Width, $controllerWindow.Height)
        $controllerWindow.Content.Measure($controllerSize)
        $controllerWindow.Content.Arrange([System.Windows.Rect]::new($controllerSize))
        $controllerWindow.Content.UpdateLayout()
        Assert-Layout ($outputControl.ActualHeight -gt 0 -and [System.Windows.Controls.Grid]::GetRow($outputControl) -eq 8) 'Controller output toggle must occupy its own measured row.'
        Assert-Layout ([System.Windows.Controls.Grid]::GetRow($controllerWindow.FindName('WindowMode')) -eq 10) 'Adding output must preserve the mode selector below it.'
        Assert-Layout (-not $controllerWindow.IsVisible) 'Controller layout must remain hidden.'
    } finally { $controllerWindow.Close() }
    Write-Output "OVERLAY LAYOUT PASSED: $assertions assertions; real hidden WPF measure/arrange, legacy layouts and toggles, bounded two-message states, semantic transitions/polling, stop/restart/demo identity, missing outputs, fixed untimed timer, controller checkbox, 300-character wide-Latin/prose/CJK pairs at 280-820 widths, manual scrolling. No windows shown."
} finally {
    $script:closeAllowed = $true
    $script:overlayWindow.Close()
    $window.Close()
}
