param(
    [Parameter(Mandatory = $true)][int]$ControllerProcessId,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [switch]$ExercisePlayback
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
$evidence = [IO.Path]::GetFullPath($EvidenceRoot)
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, $ControllerProcessId)
$script:assertions = 0
function Wait-For([scriptblock]$Check, [string]$Description, [int]$Seconds = 50) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $result = & $Check
        if ($result) { return $result }
        Start-Sleep -Milliseconds 100
    } while ($clock.Elapsed.TotalSeconds -lt $Seconds)
    throw ('Timed out: ' + $Description)
}
function Get-Controller {
    $candidate = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $condition)
    if ($candidate -and $candidate.Current.Name -eq 'VibeReplay - Demo Player') { return $candidate }
    return $null
}
function Find-Control([string]$Id) {
    $window = Get-Controller
    if (-not $window) { return $null }
    $property = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    return $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $property)
}
function Invoke-Control([string]$Id) {
    $control = Wait-For { $candidate = Find-Control $Id; if ($candidate -and $candidate.Current.IsEnabled) { $candidate } } ('available control: ' + $Id) 10
    $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Save-Controller([string]$Name) {
    $bounds = (Get-Controller).Current.BoundingRectangle
    $bitmap = [Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen([int]$bounds.X, [int]$bounds.Y, 0, 0, $bitmap.Size)
        $bitmap.Save((Join-Path $evidence $Name), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}
$window = Wait-For { Get-Controller } 'native controller'
Assert $window.Current.IsEnabled 'Controller must remain enabled.'
Assert ((Find-Control 'PrimaryLabel').Current.Name -eq 'Open') 'Prepared selection must start at Open, not autoplay.'
Save-Controller 'native-controller.png'
Invoke-Control 'CompactMode'
$mini = Wait-For { $w = Get-Controller; if ($w.Current.BoundingRectangle.Height -le 60) { $w } } 'mini strip'
Assert ($mini.Current.BoundingRectangle.Height -le 60) 'Mini strip must stay compact at the current desktop scale.'
Assert ($null -ne (Find-Control 'MiniPlayPause')) 'Mini controls must be accessible.'
Save-Controller 'native-mini.png'
Invoke-Control 'CompactMode'
if ($ExercisePlayback) {
    Invoke-Control 'PlayPause'
    Wait-For { $button = Find-Control 'PlayPause'; $button -and $button.Current.IsEnabled -and $button.Current.Name -eq 'Play' } 'isolated target ready, without autoplay' | Out-Null
    Assert ((Find-Control 'PrimaryLabel').Current.Name -eq 'Play') 'Open must prepare without starting playback.'
    Invoke-Control 'PlayPause'
    Wait-For { (Find-Control 'PrimaryLabel').Current.Name -eq 'Pause' } 'playback begins' | Out-Null
    Invoke-Control 'PlayPause'
    Wait-For { (Find-Control 'PrimaryLabel').Current.Name -eq 'Resume' } 'paused state' | Out-Null
    Invoke-Control 'PlayPause'
    Wait-For { $next = Find-Control 'NextStep'; $next -and $next.Current.IsEnabled } 'first exchange review' | Out-Null
    Assert ((Find-Control 'Status').Current.Name -match '1/2') 'First exchange must remain visible for review.'
    Invoke-Control 'NextStep'
    Wait-For { (Find-Control 'PrimaryLabel').Current.Name -eq 'Replay' -and
        (Find-Control 'Status').Current.Name -match '2/2' -and
        -not (Find-Control 'NextStep').Current.IsEnabled } 'second exchange completion' | Out-Null
    Assert (-not (Find-Control 'NextStep').Current.IsEnabled) 'Next must be disabled after the final exchange.'
    Save-Controller 'native-complete.png'
    Invoke-Control 'PlayPause'
    Wait-For { (Find-Control 'PrimaryLabel').Current.Name -eq 'Pause' } 'explicit replay before testing Stop instead of final Exit' | Out-Null
    Invoke-Control 'Stop'
    Wait-For { (Find-Control 'PrimaryLabel').Current.Name -eq 'Open' } 'scoped target closure' | Out-Null
    Assert ((Get-Controller).Current.IsEnabled) 'Controller must remain available after its paired target closes.'
}
Write-Output ("Compact desktop acceptance: " + $script:assertions + ' assertions passed. Playback exercised: ' + [bool]$ExercisePlayback + '. Controller left running with its synthetic selection.')
