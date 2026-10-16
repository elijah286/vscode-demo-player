param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [string]$ApplicationRoot,
    [switch]$Installed
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
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
$root = if ($ApplicationRoot) { (Resolve-Path -LiteralPath $ApplicationRoot).Path } else { Split-Path $PSScriptRoot -Parent }
$evidence = Join-Path ([System.IO.Path]::GetFullPath($EvidenceRoot)) ('run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
Write-Output ('UI evidence: ' + $evidence)
$library = Join-Path $evidence 'library'
$source = Join-Path $evidence 'synthetic-source.jsonl'
$target = Join-Path $evidence 'synthetic-target.txt'
$targetContent = 'LIVE FILE SENTINEL - must not be read to reconstruct or changed by playback.'
$replacement = 'SYNTHETIC_SAVED_REPLACEMENT' + "`n" + '```' + "`n" + '[saved text, not a command](command:example.run)'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($target, $targetContent, $utf8)
$snapshot = @{
    kind = 0
    v = @{
        sessionId = 'synthetic-ui-test'
        customTitle = 'Synthetic UI acceptance'
        responderUsername = 'Recorded Assistant'
        requests = @(
            @{ timestamp = 1700000000000; modelState = @{ completedAt = 1700000061000 }; result = @{}; message = @{ text = 'Show the first recorded interaction.' }; response = @(
                @{ value = 'First recorded answer for the Demo Player acceptance test.' },
                @{ kind = 'inlineReference'; name = 'Synthetic saved reference'; inlineReference = @{ scheme = 'file'; path = '/synthetic/source.txt' } },
                @{
                    kind = 'textEditGroup'; uri = @{ fsPath = $target }; done = $true
                    edits = ,@(@{ text = $replacement; range = @{ startLineNumber = 1; startColumn = 1; endLineNumber = 1; endColumn = 1 } })
                    state = @{ applied = 1; sha1 = 'synthetic-original-metadata' }
                }
            ) },
            @{ timestamp = 1700001000000; modelState = @{ completedAt = 1700001122000 }; result = @{}; message = @{ text = 'Show the next recorded interaction.' }; response = @(@{ value = 'Second recorded answer. No live model or tools were invoked.' }) }
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
    $bounds = $Element.Current.BoundingRectangle
    $image = [System.Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($image)
    try {
        $graphics.CopyFromScreen([int]$bounds.Left, [int]$bounds.Top, 0, 0, $image.Size)
        $image.Save((Join-Path $evidence $Name), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $image.Dispose() }
}

function Start-TestPlayer {
    if (-not $Installed) {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Show-ReplayController.ps1') + '" -LibraryRoot "' + $library + '" -NodePath "' + $NodePath + '"'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $script:controllerProcess = [Diagnostics.Process]::Start($start)
        $script:controllerOutput = $script:controllerProcess.StandardOutput.ReadToEndAsync()
        $script:controllerErrors = $script:controllerProcess.StandardError.ReadToEndAsync()
        return [pscustomobject]@{ ProcessId = $script:controllerProcess.Id }
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $root 'VSCodeDemoPlayer.exe'
    $start.Arguments = '-LibraryRoot "' + $library + '"'
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) { throw 'Installed launcher failed to start.' }
    } finally { $process.Dispose() }
    $controller = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains((Join-Path $root 'Start-InstalledPlayer.ps1')) -and $_.CommandLine.Contains($library)
        } | Select-Object -First 1
    } 'installed controller process'
    return [pscustomobject]@{ ProcessId = $controller.ProcessId }
}

$tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
$originalAppData = $env:APPDATA
$originalProfile = $env:USERPROFILE
$env:APPDATA = Join-Path $evidence 'AppData'
$env:USERPROFILE = Join-Path $evidence 'Home'
$storage = Join-Path $env:APPDATA ('Code\User\workspaceStorage\' + ('a' * 32))
[IO.Directory]::CreateDirectory((Join-Path $storage 'chatSessions')) | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $storage 'chatSessions\synthetic.jsonl')
[IO.File]::WriteAllText((Join-Path $storage 'workspace.json'), (@{ folder = ([Uri]$evidence).AbsoluteUri } | ConvertTo-Json -Compress), $utf8)
$sdkId = '12345678-1234-1234-1234-123456789abc'
$sdkSource = Join-Path $env:USERPROFILE ('.copilot\session-state\' + $sdkId + '\events.jsonl')
[IO.Directory]::CreateDirectory((Split-Path $sdkSource -Parent)) | Out-Null
$sdkRecords = @(
    @{ type = 'session.start'; timestamp = '2026-10-16T12:00:00Z'; data = @{ version = 1; sessionId = $sdkId; producer = 'Synthetic SDK Agent'; context = @{ cwd = 'C:\Synthetic\SDKProject' } } },
    @{ type = 'user.message'; timestamp = '2026-10-16T12:00:01Z'; data = @{ content = 'First synthetic SDK prompt' } },
    @{ type = 'assistant.message'; timestamp = '2026-10-16T12:00:02Z'; data = @{ content = 'Before the saved tool. '; toolRequests = @(@{ name = 'recorded-only-no-execution' }) } },
    @{ type = 'tool.execution_start'; timestamp = '2026-10-16T12:00:02.100Z'; data = @{ toolCallId = 'sdk-tool'; toolName = 'recorded-only-no-execution'; arguments = @{ target = $target } } },
    @{ type = 'tool.execution_complete'; timestamp = '2026-10-16T12:00:02.200Z'; data = @{ toolCallId = 'sdk-tool'; success = $true; result = @{ content = '[Saved text, not a command](command:never.run)' } } },
    @{ type = 'assistant.message'; timestamp = '2026-10-16T12:00:02.300Z'; data = @{ content = 'First SDK final answer' } },
    @{ type = 'assistant.turn_end'; timestamp = '2026-10-16T12:00:03Z'; data = @{} },
    @{ type = 'user.message'; timestamp = '2026-10-16T12:00:04Z'; data = @{ content = 'Second synthetic SDK prompt' } },
    @{ type = 'assistant.message'; timestamp = '2026-10-16T12:00:05Z'; data = @{ content = 'Second SDK final answer' } },
    @{ type = 'assistant.turn_end'; timestamp = '2026-10-16T12:00:06Z'; data = @{} }
)
[IO.File]::WriteAllText($sdkSource, (($sdkRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }) -join "`n") + "`n", $utf8)
$launch = Start-TestPlayer
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
    $sessionList = Find-Element $capture 'Id' 'CaptureSessions'
    Wait-Until {
        ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 2 -and
        (Find-Element $capture 'Id' 'CaptureRefresh').Current.IsEnabled
    } 'automatic discovery lists the two synthetic native/SDK conversations' 65 | Out-Null
    $historySearch = Find-Element $capture 'Id' 'CaptureHistorySearch'
    ([System.Windows.Automation.ValuePattern]$historySearch.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('SDKProject')
    Wait-Until { ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 1 } 'project search filters without rescanning' | Out-Null
    $rowCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem)
    $sdkRow = $sessionList.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $rowCondition)
    ([System.Windows.Automation.SelectionItemPattern]$sdkRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Invoke-Button $capture 'Load'
    $turnList = Find-Element $capture 'Id' 'CaptureTurns'
    Wait-Until { $turnList.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition).Count -eq 2 } 'SDK conversation loads two exchanges' | Out-Null
    $rawPayload = Find-Element $capture 'Id' 'CaptureRawPayload'
    $sdkTurn = $turnList.FindFirst([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    ([System.Windows.Automation.SelectionItemPattern]$sdkTurn.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    ([System.Windows.Automation.TogglePattern]$rawPayload.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    $preview = Find-Element $capture 'Id' 'CapturePreview'
    Wait-Until { ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value -match '"sdkEvents"' } 'SDK original events appear in debounced raw preview' | Out-Null
    ([System.Windows.Automation.TogglePattern]$rawPayload.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Invoke-Button $capture 'CaptureClearFilters'
    Wait-Until { ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 2 } 'clear filters restores both rows' | Out-Null
    $agentFilter = Find-Element $capture 'Id' 'CaptureAgentFilter'
    ([System.Windows.Automation.ExpandCollapsePattern]$agentFilter.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
    $agentItem = Find-Element $agentFilter 'Name' 'Synthetic SDK Agent'
    for ($depth = 0; $agentItem -and $depth -lt 8; $depth++) {
        if ($agentItem.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::IsSelectionItemPatternAvailableProperty)) { break }
        $agentItem = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($agentItem)
    }
    if (-not $agentItem -or -not $agentItem.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::IsSelectionItemPatternAvailableProperty)) { throw 'SDK agent filter item is unavailable.' }
    ([System.Windows.Automation.SelectionItemPattern]$agentItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Wait-Until { ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 1 } 'agent filter selects SDK conversation' | Out-Null
    $minimum = Find-Element $capture 'Id' 'CaptureMinPrompts'
    ([System.Windows.Automation.ValuePattern]$minimum.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('3')
    Wait-Until { ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 0 } 'prompt threshold filters numerically' | Out-Null
    Invoke-Button $capture 'CaptureClearFilters'
    $header = Find-Element $sessionList 'Name' 'Conversation'
    $tasks.Add([DemoUITest]::Invoke($header))
    Start-Sleep -Milliseconds 200
    $tasks.Add([DemoUITest]::Invoke($header))
    Wait-Until {
        $cell = ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).GetItem(0,0)
        Find-Element $cell 'Name' 'Synthetic UI acceptance'
    } 'conversation column sorts descending' | Out-Null
    Invoke-Button $capture 'CaptureRefresh'
    Wait-Until { (Find-Element $capture 'Id' 'CaptureRefresh').Current.IsEnabled -and ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 2 } 'refresh completes without duplicate rows' 65 | Out-Null
    $sourceBox = Find-Element $capture 'Id' 'CaptureSource'
    $largeSource = Join-Path $evidence 'synthetic-selection.jsonl'
    $largeSnapshot = @{ kind = 0; v = @{ sessionId = 'selection-performance'; requests = @(0..99 | ForEach-Object {
        @{ result = @{}; message = @{ text = ('Selection turn ' + $_ + (' long prompt' * 2000)) }; response = @(@{ value = ('Saved response ' * 2000) }) }
    }) } }
    [IO.File]::WriteAllText($largeSource, ($largeSnapshot | ConvertTo-Json -Depth 15 -Compress) + "`n", $utf8)
    ([System.Windows.Automation.ValuePattern]$sourceBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($largeSource)
    Invoke-Button $capture 'Load'
    $turnList = Find-Element $capture 'Id' 'CaptureTurns'
    $selection = [System.Windows.Automation.SelectionPattern]$turnList.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
    Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '100 of 100 exchanges selected' } 'all 100 exchanges selected by default' 35 | Out-Null
    if ($selection.Current.GetSelection().Count -ne 100) { throw 'Default selection must include every exchange.' }
    $preview = Find-Element $capture 'Id' 'CapturePreview'
    Wait-Until { ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value -match 'Preview limited' } 'bounded preview of large selection' | Out-Null
    if (([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value.Length -gt 32768) { throw 'Large UI preview exceeded its character budget.' }
    $turnItems = $turnList.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    $latencies = @(foreach ($attempt in 0..9) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        ([System.Windows.Automation.SelectionItemPattern]$turnItems[$attempt % 2].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        $clock.Stop()
        $clock.Elapsed.TotalMilliseconds
    })
    $maximum = ($latencies | Measure-Object -Maximum).Maximum
    if ($maximum -ge 250) { throw ('Exchange selection exceeded 250 ms: ' + $maximum) }
    Invoke-Button $capture 'CaptureClearSelection'
    Wait-Until { $selection.Current.GetSelection().Count -eq 0 } 'clear selection' | Out-Null
    $turnList.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Wait-Until { $selection.Current.GetSelection().Count -eq 100 } 'real Ctrl+A selects all exchanges' | Out-Null
    Invoke-Button $capture 'CaptureClearSelection'
    Wait-Until { $selection.Current.GetSelection().Count -eq 0 } 'clear selection before button test' | Out-Null
    Invoke-Button $capture 'CaptureSelectAll'
    Wait-Until { $selection.Current.GetSelection().Count -eq 100 } 'Select all button selects every exchange' | Out-Null
    Write-Output ('EXCHANGE SELECTION: 100 large exchanges selected by default; actual Ctrl+A and buttons passed; maximum of 10 individual selections ' + [Math]::Round($maximum,1) + ' ms (limit 250 ms); preview <=32768 characters.')
    $sourceBox.SetFocus()
    ([System.Windows.Automation.ValuePattern]$sourceBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($source)
    Invoke-Button $capture 'Load'
    $turnList = Find-Element $capture 'Id' 'CaptureTurns'
    Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '2 of 2 exchanges selected' } 'replacement conversation selects both exchanges by default' | Out-Null
    $turnItems = $turnList.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    if ($turnItems[0].Current.Name -match 'Unavailable|Unknown') { throw 'Valid saved references must not make the exchange unavailable.' }
    if ($turnItems[0].Current.Name -notmatch '\[Read-only edits\]') { throw 'Saved code edits must be labeled as read-only, not unavailable.' }
    $preview = Find-Element $capture 'Id' 'CapturePreview'
    Wait-Until { ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value -match 'SYNTHETIC_SAVED_REPLACEMENT' } 'readable preview updated after selection' | Out-Null
    $readable = ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value
    if ($readable -notmatch 'PROMPT' -or $readable -notmatch 'Saved reference: Synthetic saved reference') { throw 'Readable capture preview is missing the prompt or reference label.' }
    if ($readable -notmatch 'Recorded code edit - not applied' -or $readable -notmatch 'SYNTHETIC_SAVED_REPLACEMENT') { throw 'Capture preview must display the archived code edit.' }
    $rawPayload = Find-Element $capture 'Id' 'CaptureRawPayload'
    ([System.Windows.Automation.TogglePattern]$rawPayload.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Wait-Until { ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value -match '"inlineReference"' } 'raw saved payload remains inspectable' | Out-Null
    ([System.Windows.Automation.TogglePattern]$rawPayload.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    $title = Find-Element $capture 'Id' 'CaptureTitle'
    ([System.Windows.Automation.ValuePattern]$title.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('Captured through UI ' + [char]0x03BB)
    $reviewed = Find-Element $capture 'Id' 'CaptureReviewed'
    Wait-Until { $reviewed.Current.IsEnabled } 'latest preview is ready for privacy review' | Out-Null
    ([System.Windows.Automation.TogglePattern]$reviewed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Save-WindowImage $capture 'capture.png'
    if ((Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -ne '2 of 2 exchanges selected') { throw 'Preview controls or focus changes altered the selected exchanges.' }
    Invoke-Button $capture 'SaveDemo'
    Wait-Until { -not (Get-AppWindow 'Capture Conversation') } 'capture dialog saves and closes' | Out-Null
    $entries = @(Invoke-DemoLibrary @{ command = 'list' })
    if ($entries.Count -ne 2) { throw 'UI capture did not persist the second demo.' }
    if (-not ($entries | Where-Object title -eq ('Captured through UI ' + [char]0x03BB))) { throw 'The PowerShell bridge did not preserve the Unicode capture title.' }
    if (($entries | Where-Object title -eq ('Captured through UI ' + [char]0x03BB)).count -ne 2) { throw 'Capture did not save both default-selected exchanges.' }
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
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Open') { throw 'A selected demo without a target must offer Open.' }
    Invoke-Button $window 'PlayPause'
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'isolated replay process'
    $replayId = [int]$replay.ProcessId
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' -and (Find-Element $window 'Id' 'PlayPause').Current.IsEnabled } 'Open prepares target without starting playback' 50 | Out-Null
    if ((Find-Element $window 'Id' 'NextStep').Current.IsEnabled) { throw 'Next Step must be unavailable before the first exchange.' }
    Save-WindowImage $window 'controller-open-ready.png'
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Play') { throw 'Open started playback without a second click.' }
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'explicit Play starts playback' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' } 'paused playback' | Out-Null
    Save-WindowImage $window 'controller-paused.png'
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Start Over' -and (Find-Element $window 'Id' 'NextStep').Current.IsEnabled } 'first answer review offers restart and next exchange' | Out-Null
    Invoke-Button $window 'NextStep'
    Wait-Until { (Find-Element $window 'Id' 'Status').Current.Name -like 'Finished*' } 'second answer complete' | Out-Null
    if ((Find-Element $window 'Id' 'NextStep').Current.IsEnabled) { throw 'Next Step must be unavailable after the final exchange.' }
    Save-WindowImage $window 'controller-finished.png'
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'Start Over restarts the selected demo' | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'Status').Current.Name -eq 'Exchange complete  1/2' } 'Start Over returns to first exchange' | Out-Null
    Invoke-Button $window 'Stop'
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'scoped replay closes' 20 | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'ChooseDemo').Current.IsEnabled } 'controller remains available after stop' | Out-Null
    if (-not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue)) { throw 'Stop closed the standalone controller.' }
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Open') { throw 'Stopped targets must return the primary control to Open.' }
    Save-WindowImage $window 'controller-after-stop.png'
    Invoke-Button $window 'PlayPause'
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'second isolated replay process'
    $replayId = [int]$replay.ProcessId
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' } 'second target becomes ready' 50 | Out-Null
    (Get-Process -Id $replayId).CloseMainWindow() | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Open' } 'closing target returns to Open' 20 | Out-Null
    if ((Find-Element $window 'Id' 'Status').Current.Name -notlike '*target closed*') { throw 'Unexpected target closure must be reported.' }
    Invoke-Button $window 'PlayPause'
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'reopened isolated target'
    $replayId = [int]$replay.ProcessId
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' } 'reopened target ready' 50 | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'second run starts explicitly' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' } 'second run pauses' | Out-Null
    ([System.Windows.Automation.WindowPattern]$window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'closing controller stops its paused replay' 20 | Out-Null
    Wait-Until { -not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue) } 'controller closes after its replay stops' | Out-Null
    $launch = Start-TestPlayer
    $script:controllerId = $launch.ProcessId
    $window = Wait-Until { Get-AppWindow 'Demo Player' } 'reopened standalone controller'
    Invoke-Button $window 'ManageDemos'
    $dialog = Wait-Until { Get-AppWindow 'Demo Library' } 'persisted library after restart'
    $list = Find-Element $dialog 'Id' 'DemoList'
    if ($list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition).Count -ne 2) { throw 'Saved library did not survive application restart.' }
    ([System.Windows.Automation.WindowPattern]$dialog.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    ([System.Windows.Automation.WindowPattern]$window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    Wait-Until { -not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue) } 'reopened controller closes when idle' | Out-Null
    if ([IO.File]::ReadAllText($target) -ne $targetContent) { throw 'Playback modified the saved edit target.' }
    Write-Output 'UI ACCEPTANCE PASSED: automatic native/SDK table, filters, SDK raw-event preview, native capture/save, rename/select, Open without autoplay, explicit Play/pause/resume, Next Step, final-step refusal, Start Over, scoped Stop, target closure/reopen, paused close, persistence, and unchanged edit target.'
} catch {
    if ($script:controllerProcess -and $script:controllerProcess.HasExited) {
        Write-Output ('Controller output: ' + $script:controllerOutput.GetAwaiter().GetResult())
        Write-Output ('Controller error: ' + $script:controllerErrors.GetAwaiter().GetResult())
    }
    $failedWindow = Get-AppWindow 'Demo Player'
    if ($failedWindow) {
        $failedStatus = Find-Element $failedWindow 'Id' 'Status'
        Write-Output ('Controller status: ' + $failedStatus.Current.Name + ' | ' + $failedStatus.Current.HelpText)
        Save-WindowImage $failedWindow 'failure.png'
    }
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
    $env:APPDATA = $originalAppData
    $env:USERPROFILE = $originalProfile
}
