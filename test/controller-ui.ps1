param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System.Threading.Tasks;
using System.Windows.Automation;
public static class DemoUITest {
    public static Task Invoke(AutomationElement element) {
        var pattern = (InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern);
        return Task.Run(() => pattern.Invoke());
    }
}
'@ -ReferencedAssemblies UIAutomationClient, UIAutomationTypes
$root = Split-Path $PSScriptRoot -Parent
$evidence = Join-Path ([System.IO.Path]::GetFullPath($EvidenceRoot)) ('run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
Write-Output ('UI evidence: ' + $evidence)
$library = Join-Path $evidence 'library'
$source = Join-Path $evidence 'synthetic-source.jsonl'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$snapshot = @{
    kind = 0
    v = @{
        sessionId = 'synthetic-ui-test'
        customTitle = 'Synthetic UI acceptance'
        responderUsername = 'Recorded Assistant'
        requests = @(
            @{ result = @{}; message = @{ text = 'Show the first recorded interaction.' }; response = @(@{ value = 'First recorded answer for the Demo Player acceptance test.' }) },
            @{ result = @{}; message = @{ text = 'Show the next recorded interaction.' }; response = @(@{ value = 'Second recorded answer. No live model or tools were invoked.' }) }
        )
    }
}
[System.IO.File]::WriteAllText($source, ($snapshot | ConvertTo-Json -Depth 20 -Compress) + "`n", $utf8)
. (Join-Path $root 'DemoDialogs.ps1')
$script:NodePath = (Resolve-Path -LiteralPath $NodePath).Path
$script:LibraryRoot = $library
$inspection = Invoke-DemoLibrary @{ command = 'inspect'; file = $source }
$saved = Invoke-DemoLibrary @{ command = 'capture'; file = $source; indices = @(0,1); title = 'Synthetic UI demo'; sha256 = $inspection.sha256 }

function Find-Element($Parent, [string]$Property, [string]$Value) {
    $identifier = switch ($Property) {
        'Name' { [System.Windows.Automation.AutomationElement]::NameProperty }
        'Id' { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    }
    $condition = [System.Windows.Automation.PropertyCondition]::new($identifier, $Value)
    return $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Wait-Until([scriptblock]$Check, [string]$Description, [int]$Seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Check
        if ($value) { return $value }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw ('UI acceptance timed out: ' + $Description)
}

function Get-AppWindow([string]$Title) {
    $condition = [System.Windows.Automation.AndCondition]::new([System.Windows.Automation.Condition[]]@(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$script:controllerId),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Title),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
    ))
    return [System.Windows.Automation.AutomationElement]::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Invoke-Button($Parent, [string]$Id) {
    $element = Find-Element $Parent 'Id' $Id
    if (-not $element -or -not $element.Current.IsEnabled) { throw ('UI button is unavailable: ' + $Id) }
    $script:tasks.Add([DemoUITest]::Invoke($element))
}

function Save-WindowImage($Element, [string]$Name) {
    $Element.SetFocus()
    Start-Sleep -Milliseconds 400
    $bounds = $Element.Current.BoundingRectangle
    $image = [System.Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($image)
    try {
        $graphics.CopyFromScreen([int]$bounds.Left, [int]$bounds.Top, 0, 0, $image.Size)
        $image.Save((Join-Path $evidence $Name), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $image.Dispose() }
}

$tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
$launch = & (Join-Path $root 'Start-DemoPlayer.ps1') -LibraryRoot $library -NodePath $NodePath
$script:controllerId = $launch.ProcessId
$replayId = 0
try {
    $window = Wait-Until { Get-AppWindow 'Demo Player' } 'standalone controller'
    $play = Find-Element $window 'Id' 'PlayPause'
    if ($play.Current.IsEnabled) { throw 'Play must be disabled without a selected demo.' }
    Save-WindowImage $window 'controller-empty.png'
    Invoke-Button $window 'ManageDemos'
    $dialog = Wait-Until { Get-AppWindow 'Demo Library' } 'custom demo library'
    $list = Find-Element $dialog 'Id' 'DemoList'
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    if ($items.Count -ne 1) { throw ('Expected one persisted demo, got ' + $items.Count) }
    ([System.Windows.Automation.SelectionItemPattern]$items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Save-WindowImage $dialog 'library.png'
    Invoke-Button $dialog 'CaptureConversation'
    $capture = Wait-Until { Get-AppWindow 'Capture Conversation' } 'capture dialog'
    $sourceBox = Find-Element $capture 'Id' 'CaptureSource'
    ([System.Windows.Automation.ValuePattern]$sourceBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($source)
    Invoke-Button $capture 'Load'
    $turnList = Find-Element $capture 'Id' 'CaptureTurns'
    Wait-Until { $turnList.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition).Count -eq 2 } 'capture source loads two turns' | Out-Null
    $turnItems = $turnList.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($item in $turnItems) { ([System.Windows.Automation.SelectionItemPattern]$item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).AddToSelection() }
    $title = Find-Element $capture 'Id' 'CaptureTitle'
    ([System.Windows.Automation.ValuePattern]$title.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('Captured through UI ' + [char]0x03BB)
    $reviewed = Find-Element $capture 'Id' 'CaptureReviewed'
    ([System.Windows.Automation.TogglePattern]$reviewed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Save-WindowImage $capture 'capture.png'
    Invoke-Button $capture 'SaveDemo'
    Wait-Until { -not (Get-AppWindow 'Capture Conversation') } 'capture dialog saves and closes' | Out-Null
    $entries = @(Invoke-DemoLibrary @{ command = 'list' })
    if ($entries.Count -ne 2) { throw 'UI capture did not persist the second demo.' }
    if (-not ($entries | Where-Object title -eq ('Captured through UI ' + [char]0x03BB))) { throw 'The PowerShell bridge did not preserve the Unicode capture title.' }
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    $capturedItem = @($items | Where-Object { $_.Current.Name -like '*Captured through UI*' })[0]
    if (-not $capturedItem) { throw 'Captured demo was not added to the library dialog.' }
    ([System.Windows.Automation.SelectionItemPattern]$capturedItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    $renameTitle = Find-Element $dialog 'Id' 'Title'
    ([System.Windows.Automation.ValuePattern]$renameTitle.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('Renamed UI demo')
    Invoke-Button $dialog 'Rename'
    Wait-Until { @(Invoke-DemoLibrary @{ command = 'list' } | Where-Object title -eq 'Renamed UI demo').Count -eq 1 } 'rename persists' | Out-Null
    Save-WindowImage $dialog 'library-captured.png'
    Invoke-Button $dialog 'SelectDemo'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.IsEnabled } 'selected demo ready' | Out-Null
    Invoke-Button $window 'PlayPause'
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'isolated replay process'
    $replayId = [int]$replay.ProcessId
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'playback automatically starts after preparation' 50 | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' } 'paused playback' | Out-Null
    Save-WindowImage $window 'controller-paused.png'
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' } 'first answer review' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Finished' } 'second answer complete' | Out-Null
    Save-WindowImage $window 'controller-finished.png'
    Invoke-Button $window 'Stop'
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'scoped replay closes' 20 | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'ChooseDemo').Current.IsEnabled } 'controller remains available after stop' | Out-Null
    if (-not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue)) { throw 'Stop closed the standalone controller.' }
    Save-WindowImage $window 'controller-after-stop.png'
    Invoke-Button $window 'PlayPause'
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'second isolated replay process'
    $replayId = [int]$replay.ProcessId
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'second run starts' 50 | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' } 'second run pauses' | Out-Null
    ([System.Windows.Automation.WindowPattern]$window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'closing controller stops its paused replay' 20 | Out-Null
    Wait-Until { -not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue) } 'controller closes after its replay stops' | Out-Null
    $launch = & (Join-Path $root 'Start-DemoPlayer.ps1') -LibraryRoot $library -NodePath $NodePath
    $script:controllerId = $launch.ProcessId
    $window = Wait-Until { Get-AppWindow 'Demo Player' } 'reopened standalone controller'
    Invoke-Button $window 'ManageDemos'
    $dialog = Wait-Until { Get-AppWindow 'Demo Library' } 'persisted library after restart'
    $list = Find-Element $dialog 'Id' 'DemoList'
    if ($list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition).Count -ne 2) { throw 'Saved library did not survive application restart.' }
    ([System.Windows.Automation.WindowPattern]$dialog.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    ([System.Windows.Automation.WindowPattern]$window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    Wait-Until { -not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue) } 'reopened controller closes when idle' | Out-Null
    Write-Output 'UI ACCEPTANCE PASSED: empty launch, capture preview/save, rename/select, play/pause/resume, review/completion, scoped stop, controller reuse, close during paused replay, and persisted library after restart.'
} catch {
    Write-Output $_.ScriptStackTrace
    throw
} finally {
    foreach ($title in @('Capture Conversation', 'Demo Library')) {
        $child = Get-AppWindow $title
        if ($child) { ([System.Windows.Automation.WindowPattern]$child.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close() }
    }
    $remaining = Get-AppWindow 'Demo Player'
    if ($remaining) { ([System.Windows.Automation.WindowPattern]$remaining.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close() }
    if ($replayId) {
        $process = Get-Process -Id $replayId -ErrorAction SilentlyContinue
        if ($process) { $process.CloseMainWindow() | Out-Null }
    }
    foreach ($task in $tasks) {
        if (-not $task.Wait(3000)) { Write-Warning 'An automation invocation did not finish within its cleanup timeout.' }
    }
}
