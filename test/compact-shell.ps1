param([string]$NodePath)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'PlayerShell.ps1')
$assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
$window = [VibeReplay.ControllerWindow]::new()
try {
    $window.Content.Measure([Windows.Size]::new(280, [double]::PositiveInfinity))
    $window.Content.Arrange([Windows.Rect]::new(0, 0, 280, $window.Content.DesiredSize.Height))
    $window.Content.UpdateLayout()
    Assert ($window.Width -eq 280) 'Default controller must be 280 layout units wide.'
    Assert ($window.Content.DesiredSize.Height -le 226) 'Default controller must fit the approved 226-unit compact height.'
    $names = @('ChooseDemo', 'Status', 'PlayPause', 'PlayIcon', 'PrimaryLabel', 'NextStep', 'Stop', 'ExitLabel',
        'AutoContinue', 'ShowPrompt', 'ShowElapsed', 'ShowOutput', 'FrameColor', 'FrameColorSwatch', 'WindowMode',
        'SpeedLabel', 'PlaybackSpeed', 'RunEstimate', 'SummaryLanguage', 'SelectExchanges', 'GeneratePromptSummaries',
        'GenerateOutputSummaries', 'TranslateSummaries', 'AISettings', 'CheckUpdates', 'UpdateNotice',
        'OperationPanel', 'LibraryActivity', 'CancelLibraryOperation')
    foreach ($name in $names) { Assert ($null -ne $window.FindName($name)) ("Missing compatibility surface: " + $name) }
    Assert (-not $window.FindName('PlayPause').IsEnabled) 'Play must be disabled without a selection.'
    Assert (-not $window.FindName('PresentationOptions').IsExpanded) 'Presentation settings must start collapsed.'
    Assert (-not $window.FindName('PreparationOptions').IsExpanded) 'Preparation tools must start collapsed.'
    $window.SetMini($true)
    $window.Content.Measure([Windows.Size]::new(280, [double]::PositiveInfinity))
    $window.Content.Arrange([Windows.Rect]::new(0, 0, 280, $window.Content.DesiredSize.Height))
    $window.Content.UpdateLayout()
    Assert ($window.Content.DesiredSize.Height -eq 48) 'Mini controller must be exactly 48 layout units tall.'
    $window.SetMini($false)
    $window.FindName('PresentationOptions').IsExpanded = $true
    $window.FindName('PreparationOptions').IsExpanded = $true
    $window.SetRecording($true)
    Assert (-not $window.FindName('PresentationOptions').IsExpanded) 'Entering playback must collapse presentation settings.'
    Assert (-not $window.FindName('PreparationOptions').IsExpanded) 'Entering playback must collapse preparation tools.'
    Assert ($window.Topmost) 'Floating controller must be topmost by default.'
    Assert ($window.ResizeMode -eq 'NoResize') 'The controller must not become a dashboard by resizing.'
    Write-Output ("Compact shell: " + $assertions + ' assertions passed (offscreen WPF layout, not desktop acceptance).')
} finally { $window.Close(); [VibeReplay.LibraryConnections]::Close() }
