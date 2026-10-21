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
$maxHistoryGap = 0

function Assert-Layout([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
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

function Get-TimerTop {
    return $timerPanel.TranslatePoint([System.Windows.Point]::new(0, 0), $overlayContent).Y
}

function Assert-FullBubbleText($Bubble, [string]$Expected) {
    $text = $Bubble.Child.Children[1]
    Assert-Layout ($text.Text -ceq $Expected) 'Bubble must retain the entire summary.'
    $last = $text.ContentEnd.GetInsertionPosition([System.Windows.Documents.LogicalDirection]::Backward).GetCharacterRect([System.Windows.Documents.LogicalDirection]::Backward)
    Assert-Layout (-not $last.IsEmpty -and $last.Height -gt 0) 'Final character must have rendered line geometry.'
    Assert-Layout ($last.Bottom -le $text.ActualHeight + 1) 'Final line must fit within the rendered text height.'
    $bottom = $text.TranslatePoint([System.Windows.Point]::new($last.Right, $last.Bottom), $Bubble)
    Assert-Layout ($bottom.Y -le $Bubble.ActualHeight - $Bubble.Padding.Bottom + 1) 'Bubble must enclose the final text line, not clip it.'
}

function Set-History([object[]]$Messages, [string]$Run = 'run1') {
    $script:lastView.overlay.conversation.history = $Messages
    $script:lastView.overlay.conversation.run = $Run
    $script:lastView.overlay.conversation.key = $Run + ':' + $Messages.Count + ':' + ($Messages | ConvertTo-Json -Compress -Depth 4)
    Update-ReplayOverlays -MeasureOnly
}

function Message([string]$Id, [bool]$IsInput, $Text) {
    return [pscustomobject]@{ id = $Id; input = $IsInput; text = $Text }
}

function Wait-History {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $fillTimer = $script:conversationFillTimer
    $historyPanel = $conversationMessages
    $timing = [pscustomobject]@{ MaxGap = 0 }
    $pulse = [System.Windows.Threading.DispatcherTimer]::new()
    $pulse.Interval = [TimeSpan]::FromMilliseconds(10)
    $pulse.Add_Tick({
        $timing.MaxGap = [Math]::Max($timing.MaxGap, $watch.ElapsedMilliseconds)
        Assert-Layout ($watch.ElapsedMilliseconds -lt 250) "History fill blocked dispatcher for $($watch.ElapsedMilliseconds)ms with $($historyPanel.Children.Count) bubbles rendered."
        $watch.Restart()
        if (-not $fillTimer.IsEnabled) { $frame.Continue = $false }
    }.GetNewClosure())
    $pulse.Start()
    try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $pulse.Stop() }
    $script:maxHistoryGap = [Math]::Max($script:maxHistoryGap, $timing.MaxGap)
}

try {
    $promptText.Text = ('A synthetic summary that wraps across the available width. ' * 3).Trim()
    $promptProgress.Text = '1/24'
    foreach ($height in @(132, 180, 500)) {
        foreach ($width in @(280, 320, 360, 480, 639, 640, 820)) {
            Arrange-Overlay $width $height
            $stacked = $width -lt 640
            Assert-Layout ([System.Windows.Controls.Grid]::GetRow($promptPanel) -eq [int]$stacked) "Incorrect prompt row at ${width}x${height}."
            Assert-Layout ([System.Windows.Controls.Grid]::GetColumn($timerPanel) -eq $(if ($stacked) { 0 } else { 1 })) "Incorrect timer column at ${width}x${height}."
            $promptOrigin = $promptPanel.TranslatePoint([System.Windows.Point]::new(0, 0), $overlayContent)
            $timerOrigin = $timerPanel.TranslatePoint([System.Windows.Point]::new(0, 0), $overlayContent)
            if ($stacked) {
                Assert-Layout ([Math]::Abs($promptPanel.ActualWidth - $overlayContent.ActualWidth) -lt 1) 'Narrow prompt must use full width.'
                Assert-Layout ($promptOrigin.Y -ge $timerOrigin.Y + $timerPanel.ActualHeight + 11) 'Timer must be above narrow prompt.'
                Assert-Layout ($timerOrigin.Y -eq 0) 'Narrow timer must be at top.'
            } else {
                Assert-Layout ($promptOrigin.Y -eq 0 -and $timerOrigin.X -ge $promptPanel.ActualWidth + 23) 'Wide timer must be beside prompt.'
            }
            Assert-Layout ($promptPanel.ActualHeight -gt 0) 'Prompt must have remaining height.'
            Assert-Layout ($script:overlayWindow.Width -eq $width -and $script:overlayWindow.Height -eq $height) 'Layout must retain manual dimensions.'
        }
    }
    $scroll = @($promptPanel.Children | Where-Object { $_ -is [System.Windows.Controls.ScrollViewer] })[0]
    foreach ($text in @(('W' * 300), ('A faithful synthetic summary of the original request. ' * 6).Substring(0,300), ([string][char]0x754C * 300))) {
        $promptText.Text = $text
        foreach ($layout in @(@{ Width = 720; Timer = $false }, @{ Width = 820; Timer = $true }, @{ Width = 480; Timer = $true }, @{ Width = 280; Timer = $true })) {
            Arrange-Overlay $layout.Width 500 $true $layout.Timer
            $height = Get-OverlayPromptHeight $layout.Width $layout.Timer
            Arrange-Overlay $layout.Width $height $true $layout.Timer
            Assert-Layout ($promptText.Text.Length -eq 300 -and $scroll.ScrollableHeight -lt 1) "Full 300-character legacy summary must fit at $($layout.Width)."
            Assert-Layout ($height -le $area.Height - 32) 'Auto height must fit work area.'
        }
    }
    Arrange-Overlay 280 132
    Assert-Layout ($scroll.ScrollableHeight -gt 0) 'Manually shortened prompt must scroll.'
    Assert-Layout (-not $showOutput.IsChecked) 'Output must default off.'
    $showOutput = [System.Windows.Controls.CheckBox]::new()
    $showPrompt = [System.Windows.Controls.CheckBox]::new()
    $showElapsed = [System.Windows.Controls.CheckBox]::new()
    $showOutput.IsChecked = $true
    $script:lastView = [pscustomobject]@{
        progress = '1/3'
        overlay = [pscustomobject]@{
            promptSummary = 'Input 1'; elapsed = $null
            conversation = [pscustomobject]@{ history = @(); key = ''; run = 'run1'; active = $true }
        }
    }
    $messages = @(Message '0:input' $true 'Input 1')
    Set-History $messages
    Assert-Layout ($conversationMessages.Children.Count -eq 1) 'Ready must contain only input, never unrevealed output.'
    $first = $conversationMessages.Children[0]
    Assert-Layout ($first.Child.Children[0].Text -eq 'You' -and $first.Child.Children[1].Text -eq 'Input 1') 'First message must label You.'
    Assert-Layout ($conversationPanel.Visibility -eq 'Visible' -and -not $showPrompt.IsChecked) 'History input must not depend on prompt toggle.'
    Assert-Layout ($elapsedText.Text -eq 'Unavailable' -and -not $showElapsed.IsEnabled) 'Untimed history must keep fixed timer with unavailable notice.'
    $messages += Message '0:output' $false 'Output 1'
    Set-History $messages
    $second = $conversationMessages.Children[1]
    Assert-Layout ($first.HorizontalAlignment -eq 'Right' -and $second.HorizontalAlignment -eq 'Left') 'Speaker alignment is wrong.'
    Assert-Layout ($first.Background.ToString() -eq '#FF1557A5' -and $first.Child.Children[1].Foreground.ToString() -eq '#FFFFFFFF') 'You contrast is wrong.'
    Assert-Layout ($second.Background.ToString() -eq '#FFE9EDF2' -and $second.Child.Children[1].Foreground.ToString() -eq '#FF202020') 'AI contrast is wrong.'
    Assert-Layout ($second.Child.Children[0].Text -eq 'AI' -and $second.Child.Children[2].Text -eq [string][char]0x2193) 'Completed output needs AI label and arrow.'
    $transitions = $script:conversationTransitionCount
    foreach ($elapsed in @('00:00:01', '00:00:02', '00:00:02')) {
        $script:lastView.overlay.elapsed = $elapsed
        Update-ReplayOverlays -MeasureOnly
    }
    Assert-Layout ($script:conversationTransitionCount -eq $transitions -and $conversationMessages.Children[0] -eq $first) 'Polling must not duplicate or rebuild history.'
    Assert-Layout ($elapsedText.Text -eq '00:00:02' -and -not $timerPanel.HasAnimatedProperties) 'Cumulative timer must remain independent of animation.'
    $messages += Message '1:input' $true 'Input 2'
    Set-History $messages
    $messages += Message '1:output' $false 'Output 2'
    Set-History $messages
    Arrange-Overlay 820 (Get-OverlayConversationHeight 820) $false $true
    Assert-Layout ($conversationMessages.Children.Count -eq 4 -and $conversationMessages.Children[0] -eq $first) 'Short history must retain more than two bubbles and original elements.'
    Assert-Layout ($conversationPanel.ScrollableHeight -lt 1) 'Four short messages should fit naturally.'
    foreach ($text in @(('W' * 300), ('A faithful synthetic summary. ' * 12).Substring(0,300), ([string][char]0x754C * 300),
        (('W' * 239) + '.'), (('A complete summary of my recorded answer. ' * 6).Substring(0,239) + '.'), (([string][char]0x754C * 239) + '.'))) {
        Set-History @((Message '0:input' $true $text), (Message '0:output' $false $text)) 'fit'
        foreach ($width in @(280, 320, 360, 480, 639, 640, 820)) {
            Arrange-Overlay $width (Get-OverlayConversationHeight $width) $false $true
            Assert-Layout ((Get-TimerTop) -eq 0) 'Timer must stay at top at every width.'
            $origin = $conversationPanel.TranslatePoint([System.Windows.Point]::new(0,0), $overlayContent)
            Assert-Layout ($origin.Y -ge $timerPanel.ActualHeight + 11) 'History must scroll below timer.'
            foreach ($bubble in $conversationMessages.Children) {
                Assert-FullBubbleText $bubble $text
                Assert-Layout ($bubble.ActualWidth -le $conversationPanel.ViewportWidth + 1) "Bubble must wrap inside viewport at $width."
            }
            Assert-Layout ($script:overlayWindow.Height -le 600) 'Automatic history height is bounded.'
            if ($text.Length -eq 240) {
                foreach ($bubble in $conversationMessages.Children) {
                    Assert-Layout ($bubble.ActualHeight -le $conversationPanel.ViewportHeight + 1) "A complete 240-character summary must fit the automatic viewport at width $width."
                }
                if ($width -eq 820) {
                    Assert-Layout ($conversationPanel.ScrollableHeight -lt 1) 'Both complete summaries must fit together at the default window width.'
                }
            }
            Arrange-Overlay $width 260 $false $true
            $conversationPanel.ScrollToBottom()
            Arrange-Overlay $width 260 $false $true
            $latest = $conversationMessages.Children[$conversationMessages.Children.Count - 1]
            Assert-FullBubbleText $latest $text
            $body = $latest.Child.Children[1]
            $last = $body.ContentEnd.GetInsertionPosition([System.Windows.Documents.LogicalDirection]::Backward).GetCharacterRect([System.Windows.Documents.LogicalDirection]::Backward)
            $ending = $body.TranslatePoint([System.Windows.Point]::new($last.Right, $last.Bottom), $conversationPanel)
            Assert-Layout ($ending.Y -ge $last.Height -and $ending.Y -le $conversationPanel.ActualHeight + 1) 'Scrolling a short window must expose the complete final line.'
        }
    }
    $many = @(for ($index = 0; $index -lt 100; $index++) {
        Message ($index.ToString() + ':input') $true ("Input $index " + ('W' * 280))
        Message ($index.ToString() + ':output') $false ("Output $index " + ('W' * 280))
    })
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Set-History $many 'many'
    $watch.Stop()
    Assert-Layout ($watch.ElapsedMilliseconds -lt 250) "History state update exceeded 250ms: $($watch.ElapsedMilliseconds)."
    Wait-History
    Arrange-Overlay 320 400 $false $true
    Assert-Layout ($conversationMessages.Children.Count -eq 200 -and $conversationPanel.ScrollableHeight -gt 0) '100 exchanges must be bounded and scroll.'
    $conversationPanel.ScrollToTop()
    Arrange-Overlay 320 400 $false $true
    $script:lastView.overlay.elapsed = '00:00:03'
    Update-ReplayOverlays -MeasureOnly
    Arrange-Overlay 320 400 $false $true
    Assert-Layout ($conversationPanel.VerticalOffset -eq 0) 'Polling must not pull a reader away from older messages.'
    Set-History $many[0..198] 'follow'
    Wait-History
    Arrange-Overlay 320 400 $false $true
    $conversationPanel.ScrollToTop()
    Arrange-Overlay 320 400 $false $true
    Set-History $many 'follow'
    Arrange-Overlay 320 400 $false $true
    Assert-Layout ($conversationPanel.VerticalOffset -eq 0) 'Appending output must preserve an older-history reading position.'
    Set-History $many[0..197] 'new-input'
    Wait-History
    Arrange-Overlay 320 400 $false $true
    $conversationPanel.ScrollToTop()
    Arrange-Overlay 320 400 $false $true
    Set-History $many[0..198] 'new-input'
    Arrange-Overlay 320 400 $false $true
    Assert-Layout ([Math]::Abs($conversationPanel.VerticalOffset - $conversationPanel.ScrollableHeight) -lt 1) 'New input must scroll to latest.'
    Assert-Layout ((Get-TimerTop) -eq 0) 'Scrolling history must never scroll timer.'
    Set-History @((Message '0:input' $true 'New demo'), (Message '0:output' $false $null)) 'new'
    Assert-Layout ($conversationMessages.Children.Count -eq 2 -and $conversationMessages.Children[1].Child.Children[1].Text -like '*summary missing*') 'New run resets history and missing output is explicit.'
    $script:stopping = $true
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($conversationMessages.Children.Count -eq 0 -and $conversationPanel.Visibility -eq 'Collapsed') 'Stop must clear visible history immediately.'
    $script:stopping = $false
    Set-History @((Message '0:input' $true 'Restarted')) 'restart'
    Assert-Layout ($conversationMessages.Children.Count -eq 1) 'Start Over must reset to input only.'
    $script:lastView.overlay.conversation.run = 'different-selection-same-current-key'
    $script:lastView.overlay.conversation.history = @((Message '0:input' $true 'Other selection'))
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($conversationMessages.Children.Count -eq 1 -and $conversationMessages.Children[0].Child.Children[1].Text -eq 'Other selection') 'Selection identity must reset history even when the current-exchange key matches.'
    $showOutput.IsChecked = $false
    $showPrompt.IsChecked = $showElapsed.IsChecked = $true
    Update-ReplayOverlays -MeasureOnly
    Arrange-Overlay 820 180
    Assert-Layout ($showElapsed.IsEnabled -and $promptPanel.Visibility -eq 'Visible' -and $conversationPanel.Visibility -eq 'Collapsed') 'Output off must restore legacy mode and toggles.'
    Assert-Layout ([System.Windows.Controls.Grid]::GetColumn($timerPanel) -eq 1) 'Legacy wide timer position must return.'

    $controllerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Show-ReplayController.ps1'
    $tokens = $parseErrors = $null
    $controllerAst = [System.Management.Automation.Language.Parser]::ParseFile($controllerPath, [ref]$tokens, [ref]$parseErrors)
    Assert-Layout ($parseErrors.Count -eq 0) 'Controller must parse.'
    $assignment = $controllerAst.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '[xml]$layout' }, $true)
    $literal = $assignment.Right.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
    $reader = [System.Xml.XmlNodeReader]::new([xml]$literal.Value)
    try { $controller = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
    try {
        Assert-Layout (-not $controller.FindName('ShowOutput').IsChecked -and -not $controller.FindName('AutoContinue').IsChecked) 'Both new options must default off.'
        $size = [System.Windows.Size]::new($controller.Width, $controller.Height)
        $controller.Content.Measure($size)
        $controller.Content.Arrange([System.Windows.Rect]::new($size))
        $controller.Content.UpdateLayout()
        foreach ($name in @('AutoContinue', 'GeneratePromptSummaries', 'GenerateOutputSummaries', 'WindowMode')) {
            $element = $controller.FindName($name)
            $origin = $element.TranslatePoint([System.Windows.Point]::new(0,0), $controller.Content)
            Assert-Layout ($element.ActualHeight -gt 0 -and $origin.Y + $element.ActualHeight -le $controller.Content.ActualHeight) "$name must fit controller."
        }
        foreach ($name in @('Cancel-AutoContinue', 'Test-AutoContinueDue')) {
            $function = $controllerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            . ([scriptblock]::Create($function.Extent.Text))
        }
        $autoContinue = $controller.FindName('AutoContinue')
        $script:pairedVisible = $true
        $script:actionTask = $null
        $script:switching = $false
        $script:autoHandledKey = $null
        $view = [pscustomobject]@{ phase = 'review'; nextEnabled = $true; overlay = [pscustomobject]@{ promptSummary = 'Input'; conversation = [pscustomobject]@{ key = 'one'; outputSummary = ('W' * 300) } } }
        $script:lastView = $view
        $now = [DateTime]::new(2026,1,1)
        Assert-Layout (-not (Test-AutoContinueDue $view $now)) 'Manual mode must never advance.'
        $autoContinue.IsChecked = $showOutput.IsChecked = $true
        Assert-Layout (-not (Test-AutoContinueDue $view $now)) 'First completed poll must schedule, not skip newly revealed output.'
        $deadline = $script:autoDeadline
        Assert-Layout (($deadline - $now).TotalSeconds -gt 9 -and ($deadline - $now).TotalSeconds -le 10) '300 characters need a measurable reading dwell.'
        Assert-Layout (-not (Test-AutoContinueDue $view $now.AddSeconds(1)) -and $script:autoDeadline -eq $deadline) 'Repeated polls must not move deadline.'
        Assert-Layout (-not (Test-AutoContinueDue $view $deadline.AddTicks(-1))) 'May not advance before deadline.'
        Assert-Layout (Test-AutoContinueDue $view $deadline) 'Must advance at deadline.'
        Assert-Layout (-not (Test-AutoContinueDue $view $deadline.AddSeconds(10))) 'Must not send duplicate Next from a stale review poll.'
        Cancel-AutoContinue -ResetRun
        Assert-Layout (-not (Test-AutoContinueDue $view $now) -and $null -ne $script:autoDeadline) 'A fresh process replaying the same demo must schedule again, not retain a handled key.'
        Cancel-AutoContinue
        foreach ($phase in @('ready', 'typing', 'response', 'complete', 'error', 'stopping', 'stopped', 'preparing')) {
            $view.phase = $phase
            $view.overlay.conversation.key = $phase
            Assert-Layout (-not (Test-AutoContinueDue $view $now) -and $null -eq $script:autoDeadline) "Cannot advance in $phase, including paused response."
        }
        $view.phase = 'review'
        $view.overlay.conversation.key = 'cancel'
        Test-AutoContinueDue $view $now | Out-Null
        Cancel-AutoContinue -BlockCurrent
        Assert-Layout (-not (Test-AutoContinueDue $view $now.AddSeconds(30))) 'Manual action must suppress pending current advance.'
        $view.overlay.conversation.key = 'uncheck'
        Test-AutoContinueDue $view $now | Out-Null
        $autoContinue.IsChecked = $false
        Assert-Layout (-not (Test-AutoContinueDue $view $now.AddSeconds(30)) -and $null -eq $script:autoDeadline) 'Uncheck must cancel.'
        $autoContinue.IsChecked = $true
        $view.overlay.conversation.key = 'busy'
        Test-AutoContinueDue $view $now | Out-Null
        $script:actionTask = [object]::new()
        Assert-Layout (-not (Test-AutoContinueDue $view $now.AddSeconds(30))) 'In-flight manual action must prevent timer races.'
        $script:actionTask = $null
        $view.nextEnabled = $false
        Assert-Layout (-not (Test-AutoContinueDue $view $now.AddSeconds(30))) 'Last exchange never loops.'
    } finally { $controller.Close() }
    Assert-Layout (-not $window.IsVisible -and -not $script:overlayWindow.IsVisible) 'Layout acceptance must not show windows.'
    Write-Output "OVERLAY LAYOUT PASSED: $assertions assertions; hidden real WPF layouts, complete 240-character and legacy 300-character Latin/prose/CJK at 280-820 widths, final-line glyph geometry, default pair fit, short-window scrolling, 200-bubble history, follow-bottom, fixed timer, reset, missing output, maximum history dispatcher gap ${maxHistoryGap}ms (<250ms), fake-time real controller deadlines/cancellation."
} finally {
    $script:closeAllowed = $true
    $script:overlayWindow.Close()
    $window.Close()
}
