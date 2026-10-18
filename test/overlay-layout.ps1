param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$area = [System.Windows.Rect]::new(0, 0, 1920, 1080)
$window = [System.Windows.Window]::new()
$showPrompt = [System.Windows.Controls.CheckBox]::new()
$showElapsed = [System.Windows.Controls.CheckBox]::new()
$frameColor = [System.Windows.Controls.Button]::new()
$frameColorSwatch = [System.Windows.Controls.Border]::new()
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ReplayPresentation.ps1')
$assertions = 0

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
    Write-Output "OVERLAY LAYOUT PASSED: $assertions assertions; real WPF measure/arrange, 280-820 widths, 132-500 heights, exact 639/640 breakpoint, wrapping and toggles; exact 300-character wide-Latin, prose and CJK summaries fit measured automatic heights with/without timer; manually shortened windows scroll. No windows shown."
} finally {
    $script:closeAllowed = $true
    $script:overlayWindow.Close()
    $window.Close()
}
