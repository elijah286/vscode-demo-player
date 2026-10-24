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
    $lastChild = $Bubble.Child.Children[$Bubble.Child.Children.Count - 1]
    $childBottom = $lastChild.TranslatePoint([System.Windows.Point]::new(0, $lastChild.ActualHeight), $Bubble)
    Assert-Layout ($childBottom.Y -le $Bubble.ActualHeight - $Bubble.Padding.Bottom + 1) 'Arrow and all text must fit above bubble bottom padding.'
    $line = $text.ContentStart.GetLineStartPosition(0)
    $lineCount = 0
    while ($null -ne $line) {
        $lineCount++
        $line = $line.GetLineStartPosition(1)
    }
    Assert-Layout ($lineCount -gt 0) 'Saved text must have measured WPF lines.'
    if ($Expected.Length -gt 300 -and $Bubble.ActualWidth -lt 400) {
        Assert-Layout ($lineCount -gt 1) 'Long saved summaries must wrap onto real measured lines.'
    }
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

function Invoke-FitProtocol([object[]]$Pairs) {
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $helper = Join-Path (Split-Path $PSScriptRoot -Parent) 'SummaryPresentation.ps1'
    $process.StartInfo.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $helper + '" -ValidateStdin'
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardInput = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        $process.Start() | Out-Null
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write((ConvertTo-Json -InputObject $Pairs -Depth 4 -Compress))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { Stop-Process -Id $process.Id -Force; throw 'Windows PowerShell fit protocol exceeded 30 seconds.' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; ErrorText = $stderr.GetAwaiter().GetResult(); Output = $stdout.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}

try {
    $protocol = Invoke-FitProtocol @(1..100 | ForEach-Object { @{exchange = $_; input = 'A complete prompt?'; output = 'Yes, a complete answer.'} })
    Assert-Layout ($protocol.ExitCode -eq 0) ("Windows PowerShell must measure 100 JSON pairs individually, not concatenate the array into one giant exchange. Exit: $($protocol.ExitCode). $($protocol.ErrorText)")
    $protocol = Invoke-FitProtocol @(@{exchange=1; input='A short prompt?'; output='Yes.'}, @{exchange=2; input=('W' * 10000); output=('W' * 10000)})
    Assert-Layout ($protocol.ExitCode -ne 0 -and $protocol.ErrorText -like '*Exchange 2:*cannot fit together*') 'Native fit validation must reject and identify the individual unfit pair, without saving or concatenating exchange numbers.'
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
    $fitCases = 0
    $unfitCases = 0
    foreach ($screen in @(@(800,600), @(1366,768), @(1920,1080))) {
        $area = [System.Windows.Rect]::new(0, 0, $screen[0], $screen[1])
        foreach ($text in @(('W' * 239 + '.'), ('A complete question and answer. ' * 18), ([string][char]0x754C * 600), ('W' * 1200))) {
            $fit = Get-DemoSummaryLayout $text $text 280 ($area.Width - 32) ($area.Height - 32)
            if (-not $fit.Fits) {
                $unfitCases++
                Assert-Layout ($fit.Width -eq $area.Width - 32 -and $fit.Height -gt $area.Height - 32) 'Unfit text must be rejected only after measuring at the available work-area width.'
                continue
            }
            $fitCases++
            Set-History @((Message '0:input' $true $text), (Message '0:output' $false $text)) 'measured-pair'
            $script:overlayWindow.Width = 280
            $script:overlayWindow.Height = 180
            Assert-Layout (Ensure-CurrentSummaryPairFits) 'A measured fit must apply successfully.'
            Arrange-Overlay $script:overlayWindow.Width $script:overlayWindow.Height $false $true
            $conversationPanel.ScrollToEnd()
            $conversationPanel.UpdateLayout()
            Assert-Layout ($script:overlayWindow.Width -le $area.Width - 32 -and $script:overlayWindow.Height -le $area.Height - 32) 'Window growth must stay inside the screen work area.'
            Assert-Layout ($conversationPanel.ScrollableHeight -lt 1) 'The complete current pair must fit simultaneously without scrolling.'
            foreach ($bubble in $conversationMessages.Children) {
                Assert-FullBubbleText $bubble $text
                $body = $bubble.Child.Children[1]
                $firstGlyph = $body.ContentStart.GetInsertionPosition([System.Windows.Documents.LogicalDirection]::Forward).GetCharacterRect([System.Windows.Documents.LogicalDirection]::Forward)
                $lastGlyph = $body.ContentEnd.GetInsertionPosition([System.Windows.Documents.LogicalDirection]::Backward).GetCharacterRect([System.Windows.Documents.LogicalDirection]::Backward)
                $firstPoint = $body.TranslatePoint([System.Windows.Point]::new($firstGlyph.Left, $firstGlyph.Top), $conversationPanel)
                $lastPoint = $body.TranslatePoint([System.Windows.Point]::new($lastGlyph.Right, $lastGlyph.Bottom), $conversationPanel)
                Assert-Layout ($firstPoint.Y -ge 0 -and $lastPoint.Y -le $conversationPanel.ViewportHeight + 1) 'Both the first and final glyph of BOTH summaries must be visible in the viewport at once.'
            }
            $script:overlayWindow.MinHeight = 132
        }
    }
    Assert-Layout ($fitCases -ge 6 -and $unfitCases -ge 1) 'Measured screen-fit coverage must include successful pairs and explicit rejection.'
    $recording = [pscustomobject]@{
        turns = @([pscustomobject]@{ snapshot = [pscustomobject]@{ requests = @([pscustomobject]@{ message = [pscustomobject]@{ text = 'Original question' } }) } })
        promptSummaries = @('W' * 1200)
        outputSummaries = @('W' * 1200)
        playbackIncluded = @($true)
    }
    $beforeFitCheck = $recording | ConvertTo-Json -Depth 8 -Compress
    $fitFailure = ''
    try { Assert-DemoSummaryPairs $recording 280 768 568 } catch { $fitFailure = $_.Exception.Message }
    Assert-Layout ($fitFailure -like 'Exchange 1:*cannot fit together*No text was truncated*') 'Preflight must name the exact included exchange and actionable fit failure.'
    Assert-Layout (($recording | ConvertTo-Json -Depth 8 -Compress) -ceq $beforeFitCheck) 'Fit validation must never truncate or mutate saved summaries.'
    $recording.playbackIncluded[0] = $false
    Assert-DemoSummaryPairs $recording 280 768 568
    Assert-Layout ($true) 'Excluded exchanges must not block summary playback.'
    $recording.promptSummaries[0] = $null
    Assert-Layout ((Get-DemoPlaybackInput $recording 0) -ceq 'Original question') 'Deleted input summaries must validate their real playback excerpt.'
    $area = [System.Windows.Rect]::new(0, 0, 1920, 1080)
    foreach ($text in @(('W' * 300), ('A faithful synthetic summary. ' * 12).Substring(0,300), ([string][char]0x754C * 300),
        ('I inspected the settings. ' * 10 + 'I set a !'),
        ('I inspected the settings. ' * 16 + 'Should I use blue or green?'),
        ('I inspected the settings. ' * 45 + 'Should I use blue or green?'),
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
            if ($width -eq 360) {
                Arrange-Overlay 360 560 $false $true
                foreach ($bubble in $conversationMessages.Children) {
                    Assert-FullBubbleText $bubble $text
                    Assert-Layout ($bubble.ToolTip -like '*explicitly generate it again*') 'Legacy malformed summaries need explicit edit/regeneration guidance, not an automatic paid repair.'
                }
            }
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
    $script:overlayResized = $true
    Set-History @((Message '0:input' $true 'A short prompt.')) 'late-layout'
    Arrange-Overlay 280 260 $false $true
    Set-History @((Message '0:input' $true 'A short prompt.'), (Message '0:output' $false ('W' * 300))) 'late-layout'
    Arrange-Overlay 280 260 $false $true
    Arrange-Overlay 280 260 $false $true
    Assert-Layout ($conversationPanel.ScrollableHeight -gt 0) 'Late-layout regression must actually overflow.'
    Assert-Layout ($conversationPanel.ScrollableHeight - $conversationPanel.VerticalOffset -lt 1) 'New output must follow its final line after layout changes the scroll extent.'
    Arrange-Overlay 320 300 $false $true
    Arrange-Overlay 320 300 $false $true
    Assert-Layout ($script:conversationFollow -and $conversationPanel.ScrollableHeight - $conversationPanel.VerticalOffset -lt 1) 'Resizing the viewport must keep the latest reply ending visible without being mistaken for scrolling up.'
    $script:overlayResized = $false
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
    Assert-Layout ($conversationPanel.ScrollableHeight - $conversationPanel.VerticalOffset -lt 1) 'A newly revealed reply must return to the current pair; history remains scrollable between transitions.'
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
    $handled = $false
    $null = $script:overlayResizeTracker.OnMessage([IntPtr]::Zero, 0x0005, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$handled)
    Assert-Layout (-not $script:overlayResizeTracker.NativeResize -and -not $handled) 'Automatic WM_SIZE must not disable automatic sizing or swallow window messages.'
    $null = $script:overlayResizeTracker.OnMessage([IntPtr]::Zero, 0x0214, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$handled)
    Assert-Layout ($script:overlayResizeTracker.NativeResize -and -not $handled) 'Native edge/grip sizing must be tracked without intercepting native resizing.'
    $script:overlayWindow.Width = 480
    $script:overlayWindow.Height = 260
    Update-ReplayOverlays -MeasureOnly
    Assert-Layout ($script:overlayWindow.Width -eq 480 -and $script:overlayWindow.Height -eq 260) 'Polling and restored legacy mode must retain native manual dimensions just like thumb resizing.'

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
        foreach ($name in @('AutoContinue', 'GeneratePromptSummaries', 'GenerateOutputSummaries', 'WindowMode', 'SelectExchanges', 'PlaybackSpeed', 'SpeedLabel', 'RunEstimate')) {
            $element = $controller.FindName($name)
            $origin = $element.TranslatePoint([System.Windows.Point]::new(0,0), $controller.Content)
            Assert-Layout ($element.ActualHeight -gt 0 -and $origin.Y + $element.ActualHeight -le $controller.Content.ActualHeight) "$name must fit controller."
        }
        Assert-Layout ($controller.FindName('PlaybackSpeed').Minimum -eq 0 -and $controller.FindName('PlaybackSpeed').Maximum -eq 100 -and $controller.FindName('PlaybackSpeed').Value -eq 0) 'Speed slider must default to normal across the complete 0-100 range.'
        $stopHandler = $controllerAst.Find({ param($node) $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Expression.Extent.Text -eq '$stop' -and $node.Member.Value -eq 'Add_Click' }, $true)
        $stopAction = $stopHandler.Arguments[0].ScriptBlock.GetScriptBlock()
        function Request-Stop { $script:testStopRequested = $true }
        foreach ($phase in @('response', 'complete')) {
            $script:lastView = [pscustomobject]@{ phase = $phase }
            $script:exitRequested = $false
            $script:testStopRequested = $false
            & $stopAction
            Assert-Layout ($script:testStopRequested -and $script:exitRequested -eq ($phase -eq 'complete')) 'Exit must close the controller after the final exchange; mid-run Stop must retain it.'
        }
        foreach ($name in @('Cancel-AutoContinue', 'Test-AutoContinueDue', 'Get-ReadingDwellSeconds', 'Get-EstimatedRunMilliseconds', 'Update-PlaybackEstimate')) {
            $function = $controllerAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            . ([scriptblock]::Create($function.Extent.Text))
        }
        $autoContinue = $controller.FindName('AutoContinue')
        $playbackSpeed = $controller.FindName('PlaybackSpeed')
        $speedLabel = $controller.FindName('SpeedLabel')
        $runEstimate = $controller.FindName('RunEstimate')
        $profile = [pscustomobject]@{ count = 3; outputDwellMilliseconds = 12000; promptDwellMilliseconds = 4000; noSummaryDwellMilliseconds = 4000 }
        $script:lastView = [pscustomobject]@{ estimateProfile = $profile }
        foreach ($case in @(@(0,21000), @(50,12150), @(100,3300))) {
            Assert-Layout ((Get-EstimatedRunMilliseconds $profile $case[0] $false $false $false) -eq $case[1]) 'Full-run base estimate must match exact phase timing at endpoints and midpoint.'
            Assert-Layout ((Get-EstimatedRunMilliseconds $profile $case[0] $true $true $false) -eq $case[1] + 12000) 'Auto estimate must include output reading dwell only between exchanges.'
        }
        Assert-Layout ((Get-EstimatedRunMilliseconds $profile 100 $true $false $true) -eq 7300) 'Prompt dwell selection must match auto continue.'
        $single = [pscustomobject]@{ count = 1; outputDwellMilliseconds = 0; promptDwellMilliseconds = 0; noSummaryDwellMilliseconds = 0 }
        Assert-Layout ((Get-EstimatedRunMilliseconds $single 100 $true $true $true) -eq 1100) 'One fast exchange needs exactly 100ms user plus 1000ms reply and no final reading dwell.'
        Assert-Layout ((Get-EstimatedRunMilliseconds $single 0 $false $false $false) -eq 7000) 'One normal exchange retains the default seven-second phase total.'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $playbackSpeed.Add_ValueChanged({ Update-PlaybackEstimate })
        $playbackSpeed.Value = 100
        $watch.Stop()
        Assert-Layout ($watch.ElapsedMilliseconds -lt 250) 'Live speed estimate must update without blocking dispatcher.'
        Assert-Layout ($runEstimate.Text -eq 'Estimated total: 00:00:04 + manual waits') 'Moving real WPF slider must immediately update full-run estimate.'
        Assert-Layout ($speedLabel.Text -eq 'Speed: user 0.1s / reply 1s') 'Fast speed label must show actual engine endpoints.'
        $autoContinue.IsChecked = $true
        $showOutput.IsChecked = $true
        Update-PlaybackEstimate
        Assert-Layout ($runEstimate.Text -eq 'Estimated total: 00:00:16 (auto)') 'Auto estimate must include the reading interval.'
        $autoContinue.IsChecked = $false
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
    Write-Output "OVERLAY LAYOUT PASSED: $assertions assertions; hidden real WPF layouts, 240/300 and >300-character saved summaries (including reported fragment) at 280-820 widths and 360x560, measured line counts, final-line/arrow/padding bounds, short-window scrolling, 200-bubble history, follow-bottom, fixed timer, maximum history dispatcher gap ${maxHistoryGap}ms (<250ms), real slider endpoint/midpoint totals, fake-time controller deadlines/cancellation."
} finally {
    $script:closeAllowed = $true
    $script:overlayWindow.Close()
    $window.Close()
}
