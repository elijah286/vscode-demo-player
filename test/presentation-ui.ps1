param(
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [string]$ProfilePath,
    [switch]$TestAgents
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
$root = Split-Path $PSScriptRoot -Parent
$evidence = Join-Path ([System.IO.Path]::GetFullPath($EvidenceRoot)) ('presentation-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($evidence) | Out-Null
$source = Join-Path $evidence 'synthetic.jsonl'
$requests = @(
    @{ timestamp = 1700000000000; modelState = @{ completedAt = 1700000061000 }; result = @{}; message = @{ text = 'Show the first recorded interaction.' }; response = @(@{ value = 'The first recorded answer.' }, @{ kind = 'workspaceEdit'; edits = @() }) },
    @{ timestamp = 1700001000000; modelState = @{ completedAt = 1700001122000 }; result = @{}; message = @{ text = 'Show the next recorded interaction.' }; response = @(@{ value = 'The second recorded answer.' }) }
)
[System.IO.File]::WriteAllText($source, (@{ kind = 0; v = @{ sessionId = 'synthetic-presentation'; requests = $requests } } | ConvertTo-Json -Depth 12 -Compress) + "`n", [System.Text.UTF8Encoding]::new($false))
$arguments = @{ SessionPath = $source; RequestCount = 2; WindowMode = 'Editor' }
if ($ProfilePath) { $arguments.UserDataPath = $ProfilePath }
$script:pair = & (Join-Path $root 'Start-Replay.ps1') @arguments

function Find-Element($Parent, [string]$Id) {
    if (-not $Parent) { return $null }
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    return $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Find-Window([string]$Title) {
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$script:pair.ControllerProcessId)
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    $namedWindow = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Title),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window))
    foreach ($window in $windows) {
        if ($window.Current.Name -eq $Title -and -not $window.Current.IsOffscreen) { return $window }
        $child = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $namedWindow)
        if ($child -and -not $child.Current.IsOffscreen) { return $child }
    }
    return $null
}

function Wait-Condition([scriptblock]$Check, [string]$Message, [int]$Milliseconds = 15000) {
    if (-not [System.Threading.SpinWait]::SpinUntil([Func[bool]]$Check, $Milliseconds)) { throw $Message }
}

function Read-State {
    try {
        $descriptor = Get-ChildItem -LiteralPath $script:pair.ProfilePath -Filter 'replay-control-*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $descriptor) { return $null }
        $connection = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($descriptor.FullName))
        return Invoke-RestMethod -Uri ('http://127.0.0.1:' + $connection.port + '/state') -Headers @{ Authorization = 'Bearer ' + $connection.token } -TimeoutSec 2
    } catch { return $null }
}

function Invoke-Button([string]$Id) {
    $button = Find-Element (Find-Window 'Demo Player') $Id
    Wait-Condition { $button.Current.IsEnabled -and ($Id -ne 'PlayPause' -or $button.Current.Name -eq (Read-State).button) } ('Button unavailable: ' + $Id)
    $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Toggle-Option([string]$Id) {
    (Find-Element (Find-Window 'Demo Player') $Id).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
}

function Test-Visible([string]$Id) {
    $element = Find-Element (Find-Window 'Playback overlay') $Id
    return $null -ne $element -and -not $element.Current.IsOffscreen
}

function Save-Overlay([string]$Name) {
    $bounds = (Find-Window 'Playback overlay').Current.BoundingRectangle
    $image = [System.Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($image)
    try {
        $graphics.CopyFromScreen([int]$bounds.Left, [int]$bounds.Top, 0, 0, $image.Size)
        $image.Save((Join-Path $evidence $Name), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $image.Dispose() }
}

function Switch-Mode([string]$Name, [string]$Mode) {
    $before = Read-State
    $selector = Find-Element (Find-Window 'Demo Player') 'WindowMode'
    Wait-Condition { $selector.Current.IsEnabled } 'Mode selector is unavailable between turns.'
    $selector.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    $selector.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-Condition { $state = Read-State; $state.windowMode -eq $Mode -and $state.modeSwitchEnabled } ('Mode switch failed: ' + $Mode) 60000
    $after = Read-State
    if ($after.resumeTurn -ne $before.resumeTurn -or $after.overlay.elapsedMs -ne $before.overlay.elapsedMs) { throw 'Mode switching changed progress or elapsed work.' }
    $process = Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:pair.ProfilePath) -and $_.CommandLine -like '*--user-data-dir*' -and $_.CommandLine -notlike '*--type=*' }
    $script:pair.ProcessId = $process.ProcessId
    Write-Output ('PASS: native switch to ' + $Mode + ' retains completed history and working time.')
}

try {
    Wait-Condition { $window = Find-Window 'Demo Player'; $window -and (Find-Element $window 'ShowPrompt').Current.IsEnabled } 'Presentation controller did not become ready.' 45000
    if (Find-Window 'Playback overlay') { throw 'Overlay must default to hidden.' }
    Toggle-Option 'ShowPrompt'
    Toggle-Option 'ShowElapsed'
    Wait-Condition { (Test-Visible 'PromptText') -and (Test-Visible 'ElapsedText') } 'Combined overlay is missing.'
    Save-Overlay 'combined-amber.png'
    if ((Find-Element (Find-Window 'Playback overlay') 'ElapsedText').Current.Name -ne '00:00:00') { throw 'Expected HH:MM:SS at Ready.' }
    Toggle-Option 'ShowPrompt'
    Wait-Condition { -not (Test-Visible 'PromptText') -and (Test-Visible 'ElapsedText') } 'Timer-only layout failed.'
    Save-Overlay 'timer-only.png'
    Toggle-Option 'ShowPrompt'
    Toggle-Option 'ShowElapsed'
    Wait-Condition { (Test-Visible 'PromptText') -and -not (Test-Visible 'ElapsedText') } 'Summary-only layout failed.'
    Toggle-Option 'ShowElapsed'
    Invoke-Button 'FrameColor'
    Wait-Condition { Find-Window 'Color' } 'Native color picker did not open.'
    $picker = Find-Window 'Color'
    $editCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    $edits = $picker.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition)
    $rgb = foreach ($value in @('245', '184', '46')) { foreach ($edit in $edits) { $pattern = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); if ($pattern.Current.Value -eq $value) { $pattern } } }
    if (@($rgb).Count -ne 3) { throw 'Could not identify native RGB inputs.' }
    $rgb[0].SetValue('64'); $rgb[1].SetValue('156'); $rgb[2].SetValue('219')
    $ok = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'OK')
    $picker.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $ok).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Condition { (Find-Element (Find-Window 'Demo Player') 'FrameColor').Current.Name -eq 'Overlay frame color: #409CDB' } 'Custom frame color was not applied.'
    Save-Overlay 'custom-frame.png'
    $image = [System.Drawing.Bitmap]::new((Join-Path $evidence 'custom-frame.png'))
    try { $pixel = $image.GetPixel([int]($image.Width / 2), 2); if ($pixel.R -ne 64 -or $pixel.G -ne 156 -or $pixel.B -ne 219) { throw 'Rendered frame RGB does not match the selected color.' } } finally { $image.Dispose() }
    Invoke-Button 'PlayPause'
    Wait-Condition { (Read-State).phase -eq 'response' -and (Read-State).overlay.elapsedMs -gt 0 } 'Stopwatch did not advance during output.'
    Invoke-Button 'PlayPause'
    Wait-Condition { (Read-State).button -eq 'Resume' } 'Pause did not take effect.'
    $paused = Read-State
    foreach ($sample in 1..4) { if ((Read-State).overlay.elapsedMs -ne $paused.overlay.elapsedMs) { throw 'Working time advanced while paused.' } }
    if ((Find-Element (Find-Window 'Demo Player') 'WindowMode').Current.IsEnabled) { throw 'Mode switch must remain disabled during a paused response.' }
    Invoke-Button 'PlayPause'
    Wait-Condition { (Read-State).phase -eq 'review' } 'First turn did not enter review.'
    if ((Read-State).overlay.elapsed -ne '00:01:01') { throw 'First recorded interval is incorrect.' }
    if ($TestAgents) {
        if (-not $ProfilePath) { throw 'Agents testing requires an explicitly supplied, closed, signed-in dedicated test profile.' }
        Switch-Mode 'Agents (experimental)' 'Agents'
        Switch-Mode 'VS Code' 'Editor'
    } else { Write-Output 'NOT RUN: authenticated Agents UI switches; supply -TestAgents -ProfilePath with a coordinated test profile.' }
    Invoke-Button 'PlayPause'
    Wait-Condition { (Read-State).phase -eq 'complete' } 'Second turn did not complete.'
    if ((Read-State).overlay.elapsed -ne '00:03:03') { throw 'Stopwatch included an idle gap or lost response time.' }
    Save-Overlay 'finished.png'
    Invoke-Button 'Stop'
    Wait-Condition { -not (Get-Process -Id $script:pair.ControllerProcessId -ErrorAction SilentlyContinue) } 'Attached controller did not close.'
    Wait-Condition { -not (Get-Process -Id $script:pair.ProcessId -ErrorAction SilentlyContinue) } 'Paired replay did not close.'
    Write-Output ('PRESENTATION UI PASSED. Evidence: ' + $evidence)
} finally {
    $window = Find-Window 'Demo Player'
    if ($window) { $window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close() }
}