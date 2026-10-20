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
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
    public static void Drag(int x, int y, int dx, int dy) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(100);
        mouse_event(2, 0, 0, 0, System.UIntPtr.Zero);
        System.Threading.Thread.Sleep(100);
        try {
            for (int step = 1; step <= 10; step++) {
                SetCursorPos(x + dx * step / 10, y + dy * step / 10);
                System.Threading.Thread.Sleep(30);
            }
        } finally { mouse_event(4, 0, 0, 0, System.UIntPtr.Zero); }
    }
    public static Task Invoke(AutomationElement element) {
        var pattern = (InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern);
        return Task.Run(() => pattern.Invoke());
    }
}
'@ -ReferencedAssemblies UIAutomationClient, UIAutomationTypes
$root = if ($ApplicationRoot) { (Resolve-Path -LiteralPath $ApplicationRoot).Path } else { Split-Path $PSScriptRoot -Parent }
$evidence = Join-Path ([System.IO.Path]::GetFullPath($EvidenceRoot)) ('run-' + [guid]::NewGuid().ToString('N'))
$env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT = Join-Path $evidence 'summary-authoring'
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
            @{ timestamp = 1700001000000; modelState = @{ completedAt = 1700001122000 }; result = @{}; message = @{ text = 'Show the next recorded interaction.' }; response = @(@{ value = 'Second recorded answer. No live model or tools were invoked.' }) },
            @{ message = @{ text = 'Interrupted native request without a completion result.' }; response = @(@{ value = 'Some text was saved, but completion was not.' }) }
        )
    }
}
[System.IO.File]::WriteAllText($source, ($snapshot | ConvertTo-Json -Depth 20 -Compress) + "`n", $utf8)
$sourceBeforeCapture = [IO.File]::ReadAllText($source)
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
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $element = $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw ('UI element did not become available: ' + $Property + '=' + $Value)
}

function Wait-Until([scriptblock]$Check, [string]$Description, [int]$Seconds = 60) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Check
        if ($value) { return $value }
        Start-Sleep -Milliseconds 100
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

function Invoke-DialogButton($Parent, [string]$Name) {
    $title = $Parent.Current.Name
    $button = Wait-Until {
        $dialog = Get-AppWindow $title
        if (-not $dialog) { return $null }
        $condition = [System.Windows.Automation.AndCondition]::new([System.Windows.Automation.Condition[]]@(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        ))
        $candidate = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($candidate -and $candidate.Current.IsEnabled) {
            $pattern = $null
            if ($candidate.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { return $candidate }
        }
    } ('invokable dialog button: ' + $Name)
    $script:tasks.Add([DemoUITest]::Invoke($button))
}

function Invoke-Button($Parent, [string]$Id) {
    $element = Wait-Until {
        $candidate = Find-Element $Parent 'Id' $Id
        if ($candidate -and $candidate.Current.IsEnabled) { return $candidate }
    } ('enabled UI button: ' + $Id)
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
    Invoke-Button $window 'ChooseDemo'
    $dialog = Wait-Until { Get-AppWindow 'Find interaction' } 'unified interaction picker'
    ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    $list = Find-Element $dialog 'Id' 'DemoList'
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    if ($items.Count -ne 1) { throw ('Expected one persisted demo, got ' + $items.Count) }
    ([System.Windows.Automation.SelectionItemPattern]$items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Save-WindowImage $dialog 'library.png'
    ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'AgentConversationsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    $capture = $dialog
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
    $turnList = Wait-Until { Find-Element $capture 'Id' 'CaptureTurns' } 'SDK exchange list after loading'
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
    ([System.Windows.Automation.ExpandCollapsePattern](Find-Element $capture 'Id' 'MoreFilters').GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
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
    $turnList = Wait-Until { Find-Element $capture 'Id' 'CaptureTurns' } 'large exchange list after loading'
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
    $turnList = Wait-Until { Find-Element $capture 'Id' 'CaptureTurns' } 'replacement exchange list after loading'
    Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '2 of 3 exchanges selected' } 'replacement conversation selects only available exchanges by default' | Out-Null
    if ((Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled) { throw 'Save must remain disabled before reviewing the replacement selection.' }
    if ((Find-Element $capture 'Id' 'CaptureStatus').Current.Name -notmatch '1 unavailable exchanges excluded.*Missing: completion result') { throw 'Excluded exchange count and missing saved field must be explicit.' }
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
    ([System.Windows.Automation.ExpandCollapsePattern](Find-Element $capture 'Name' 'Selection name (optional)').GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
    $title = Find-Element $capture 'Id' 'CaptureTitle'
    ([System.Windows.Automation.ValuePattern]$title.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('Captured through UI ' + [char]0x03BB)
    $reviewed = Find-Element $capture 'Id' 'CaptureReviewed'
    Wait-Until { $reviewed.Current.IsEnabled } 'latest preview is ready for privacy review' | Out-Null
    ([System.Windows.Automation.TogglePattern]$reviewed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Wait-Until { (Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled } 'reviewed valid selection can be saved' | Out-Null
    Invoke-Button $capture 'CaptureSelectAll'
    Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '3 of 3 exchanges selected' } 'Select all includes unavailable entries for inspection' | Out-Null
    Wait-Until { $reviewed.Current.IsEnabled } 'unavailable selection preview is ready' | Out-Null
    ([System.Windows.Automation.TogglePattern]$reviewed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    if ((Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled) { throw 'Acknowledging an unavailable selection must not enable Save.' }
    Invoke-Button $capture 'CaptureSelectAvailable'
    Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '2 of 3 exchanges selected' -and $reviewed.Current.IsEnabled } 'Select available restores the valid preview' | Out-Null
    if ((Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled) { throw 'Selection changes must invalidate the prior review.' }
    ([System.Windows.Automation.TogglePattern]$reviewed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Save-WindowImage $capture 'capture.png'
    if ((Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -ne '2 of 3 exchanges selected') { throw 'Preview controls or focus changes altered the selected exchanges.' }
    Invoke-Button $capture 'SaveDemo'
    Wait-Until { -not (Get-AppWindow 'Find interaction') } 'selection returns to controller' | Out-Null
    $entries = @(Invoke-DemoLibrary @{ command = 'list' })
    if ($entries.Count -ne 2) { throw 'UI capture did not persist the second demo.' }
    if (-not ($entries | Where-Object title -eq ('Captured through UI ' + [char]0x03BB))) { throw 'The PowerShell bridge did not preserve the Unicode capture title.' }
    if (($entries | Where-Object title -eq ('Captured through UI ' + [char]0x03BB)).count -ne 2) { throw 'Capture did not save both default-selected exchanges.' }
    if ([IO.File]::ReadAllText($source) -cne $sourceBeforeCapture) { throw 'Capture changed the original saved conversation.' }
    Invoke-Button $window 'ChooseDemo'
    $dialog = Wait-Until { Get-AppWindow 'Find interaction' } 'reopen unified picker'
    ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    $list = Find-Element $dialog 'Id' 'DemoList'
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    $capturedItem = @($items | Where-Object { $_.Current.Name -like '*Captured through UI*' })[0]
    if (-not $capturedItem) { throw 'Captured demo was not added to the library dialog.' }
    ([System.Windows.Automation.SelectionItemPattern]$capturedItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    ([System.Windows.Automation.ExpandCollapsePattern](Find-Element $dialog 'Id' 'SavedActions').GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
    $renameTitle = Find-Element $dialog 'Id' 'SavedTitle'
    ([System.Windows.Automation.ValuePattern]$renameTitle.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('Renamed UI demo')
    Invoke-Button $dialog 'Rename'
    Wait-Until { @(Invoke-DemoLibrary @{ command = 'list' } | Where-Object title -eq 'Renamed UI demo').Count -eq 1 } 'rename persists' | Out-Null
    $overlaySummary = 'Explain the recorded interaction and its saved reference and code edits, preserving the original query for playback while showing this shorter, reviewed description to the presentation audience.'
    $outputSummary = 'The recorded assistant showed an answer, a saved reference and archived code edits.'
    Invoke-Button $dialog 'EditPromptSummaries'
    $summaryDialog = Wait-Until { Get-AppWindow 'Input / Output Summaries' } 'input/output summary editor'
    $originalPrompt = (Find-Element $summaryDialog 'Id' 'SummaryOriginal').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    if ($originalPrompt -cne 'Show the first recorded interaction.') { throw 'Summary editor must display the full original query.' }
    (Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($overlaySummary)
    $summaryExchange = Find-Element $summaryDialog 'Id' 'SummaryExchange'
    $summaryExchange.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('{HOME}{DOWN}{ENTER}')
    Wait-Until {
        (Find-Element $summaryDialog 'Id' 'SummaryOriginal').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -like '*First recorded answer*'
    } 'output summary choice' | Out-Null
    $outputOriginal = (Find-Element $summaryDialog 'Id' 'SummaryOriginal').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    if ($outputOriginal -notlike '*First recorded answer*' -or $outputOriginal -like '*SYNTHETIC_SAVED_REPLACEMENT*') { throw 'Output review must use recorded assistant text, not raw saved edits.' }
    (Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($outputSummary)
    Invoke-Button $summaryDialog 'SaveSummaries'
    Wait-Until { -not (Get-AppWindow 'Input / Output Summaries') } 'summary save closes editor' | Out-Null
    $summaryEntry = @(Invoke-DemoLibrary @{ command = 'list' } | Where-Object title -eq 'Renamed UI demo')[0]
    if ($summaryEntry.presentation.overlay.promptSummary -cne $overlaySummary) { throw 'Manual summary did not persist through the PowerShell bridge.' }
    if ($summaryEntry.presentation.overlay.conversation.outputSummary -cne $outputSummary) { throw 'Manual output summary did not persist through the PowerShell bridge.' }
    Invoke-Button $dialog 'EditPromptSummaries'
    $summaryDialog = Wait-Until { Get-AppWindow 'Input / Output Summaries' } 'reopen summary editor'
    if ((Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -cne $overlaySummary) { throw 'Summary editor did not reload the saved summary.' }
    (Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Unsaved draft')
    Invoke-Button $summaryDialog 'Cancel'
    Wait-Until { -not (Get-AppWindow 'Input / Output Summaries') } 'cancel summary edit' | Out-Null
    Invoke-Button $dialog 'EditPromptSummaries'
    $summaryDialog = Wait-Until { Get-AppWindow 'Input / Output Summaries' } 'summary clear draft editor'
    Invoke-Button $summaryDialog 'ClearSummaryDrafts'
    if ((Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne '') { throw 'Clear all did not empty the summary draft.' }
    Invoke-Button $summaryDialog 'Cancel'
    Wait-Until { -not (Get-AppWindow 'Input / Output Summaries') } 'cancel clear draft' | Out-Null
    $preserved = Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }
    if ($preserved.recording.promptSummaries[0] -cne $overlaySummary) { throw 'Canceling clear changed saved summaries.' }
    Invoke-Button $dialog 'ClearPromptSummaries'
    $clearConsent = Wait-Until { Get-AppWindow 'Clear Prompt Summaries' } 'clear summaries confirmation'
    Invoke-DialogButton $clearConsent 'Cancel'
    Wait-Until { -not (Get-AppWindow 'Clear Prompt Summaries') } 'declined clear leaves summaries' | Out-Null
    if ((Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }).recording.promptSummaries[0] -cne $overlaySummary) { throw 'Declining clear changed the summary.' }
    Invoke-Button $dialog 'ClearPromptSummaries'
    $clearConsent = Wait-Until { Get-AppWindow 'Clear Prompt Summaries' } 'confirmed clear summaries'
    Invoke-DialogButton $clearConsent 'OK'
    Wait-Until { -not (Get-AppWindow 'Clear Prompt Summaries') } 'clear confirmation closes' | Out-Null
    $cleared = Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }
    if (@($cleared.recording.promptSummaries | Where-Object { $null -ne $_ }).Count) { throw 'Clear all left saved summaries.' }
    if (@($cleared.recording.outputSummaries | Where-Object { $null -ne $_ }).Count) { throw 'Clear all left output summaries.' }
    if (($preserved.recording.turns | ConvertTo-Json -Depth 60 -Compress) -cne ($cleared.recording.turns | ConvertTo-Json -Depth 60 -Compress)) { throw 'Clearing changed original exchanges.' }
    if ((Invoke-DemoLibrary @{ command = 'list' } | Where-Object id -eq $summaryEntry.id).presentation.overlay.promptSummary -cne 'Show the first recorded interaction.') { throw 'Clearing did not restore the default excerpt.' }
    Invoke-DemoLibrary @{ command = 'summaries'; id = $summaryEntry.id; summaries = @($overlaySummary, $null); expected = @($cleared.recording.promptSummaries) } | Out-Null
    Invoke-DemoLibrary @{ command = 'summaries'; kind = 'output'; id = $summaryEntry.id; summaries = @($outputSummary, $null); expected = @($cleared.recording.outputSummaries) } | Out-Null
    foreach ($action in @(
        @{ Button = 'AiPromptSummaries'; Title = 'AI Input / Output Summaries'; Scope = 'both' },
        @{ Button = 'AiResponseSummaries'; Title = 'AI Response Summaries'; Scope = 'output' }
    )) {
    $priorAuthoringIds = @(Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT) } | Select-Object -ExpandProperty ProcessId)
    Invoke-Button $dialog $action.Button
    $aiConsent = Wait-Until { Get-AppWindow $action.Title } 'AI authoring setup notice'
    Invoke-DialogButton $aiConsent 'OK'
    $authoring = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains($root) -and $_.CommandLine.Contains($env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT) -and
            $_.CommandLine -notlike '*--type=*' -and $_.ProcessId -notin $priorAuthoringIds
        } | Select-Object -First 1
    } 'separate isolated AI authoring process'
    $authoringId = [int]$authoring.ProcessId
    Wait-Until {
        $requests = Get-ChildItem -LiteralPath (Join-Path $env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT 'requests') -Filter '*.json' -File
        foreach ($queued in $requests) {
            $request = Get-Content -LiteralPath $queued.FullName -Raw | ConvertFrom-Json
            $requestScope = if ($request.scope) { $request.scope } else { 'both' }
            if ($request.file -eq (Join-Path $library ($summaryEntry.id + '.demo.json')) -and $requestScope -eq $action.Scope) { return $true }
        }
        return $false
    } 'authoring launch queues the correct scoped request' | Out-Null
    Wait-Until { (Get-Process -Id $authoringId).MainWindowHandle -ne [IntPtr]::Zero } 'AI authoring workbench window' 30 | Out-Null
    if (-not (Get-Process -Id $authoringId).WaitForInputIdle(5000)) { throw 'AI authoring window did not become responsive.' }
    Wait-Until {
        $ownedAuthoring = Get-Process -Id $authoringId -ErrorAction SilentlyContinue
        if (-not $ownedAuthoring) { return $true }
        if ($ownedAuthoring.MainWindowHandle -ne [IntPtr]::Zero) { $ownedAuthoring.CloseMainWindow() | Out-Null }
        return $ownedAuthoring.WaitForExit(1000)
    } 'dismiss setup dialogs and close only the synthetic authoring window' 60 | Out-Null
    $authoringId = 0
    }
    Save-WindowImage $dialog 'library-captured.png'
    Invoke-Button $dialog 'SelectDemo'
    $selectedControls = Wait-Until {
        $controls = @{}
        foreach ($id in @('PlayPause', 'ShowPrompt', 'ShowElapsed')) {
            $control = Find-Element $window 'Id' $id
            if (-not $control -or -not $control.Current.IsEnabled) { return $false }
            $controls[$id] = $control
        }
        return $controls
    } 'selected demo and both presentation controls ready'
    if ($selectedControls.PlayPause.Current.Name -ne 'Open') { throw 'A selected demo without a target must offer Open.' }
    $showPrompt = $selectedControls.ShowPrompt
    $showElapsed = $selectedControls.ShowElapsed
    if (-not $showPrompt.Current.IsEnabled -or -not $showElapsed.Current.IsEnabled) {
        throw ('Selected demo presentation options must be enabled before Open. Prompt: ' + ($showPrompt | Out-String).Trim() +
            '; elapsed: ' + ($showElapsed | Out-String).Trim() + '; controller enabled: ' + $window.Current.IsEnabled)
    }
    if (Get-AppWindow 'Playback overlay') { throw 'Presentation must default to hidden.' }
    ([System.Windows.Automation.TogglePattern]$showPrompt.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    ([System.Windows.Automation.TogglePattern]$showElapsed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    $overlay = Wait-Until { Get-AppWindow 'Playback overlay' } 'selected demo overlay before Open'
    if ((Find-Element $overlay 'Id' 'PromptText').Current.Name -cne $overlaySummary) { throw 'Selected demo prompt summary is incorrect or cancel saved an unreviewed draft.' }
    if ((Find-Element $overlay 'Id' 'ElapsedText').Current.Name -ne '00:00:00') { throw 'Selected demo timer must start at zero.' }
    if ((Find-Element $overlay 'Id' 'PromptProgress').Current.Name -ne '1/2') { throw 'Selected demo progress preview is incorrect.' }
    Save-WindowImage $overlay 'overlay-before-open.png'
    $beforeResize = $overlay.Current.BoundingRectangle
    $beforeText = (Find-Element $overlay 'Id' 'PromptText').Current.BoundingRectangle
    $grip = (Find-Element $overlay 'Id' 'OverlayResize').Current.BoundingRectangle
    $cursorBefore = [System.Windows.Forms.Cursor]::Position
    try { [DemoUITest]::Drag([int]($grip.Left + $grip.Width / 2), [int]($grip.Top + $grip.Height / 2), -280, 140) }
    finally { [System.Windows.Forms.Cursor]::Position = $cursorBefore }
    Write-Output ('RESIZE: before=' + $beforeResize + '; grip=' + $grip + '; after=' + $overlay.Current.BoundingRectangle)
    Save-WindowImage $overlay 'overlay-after-drag.png'
    Wait-Until { $bounds = $overlay.Current.BoundingRectangle; [Math]::Abs($bounds.Width - ($beforeResize.Width - 280)) -lt 4 -and [Math]::Abs($bounds.Height - ($beforeResize.Height + 140)) -lt 4 } 'bottom-right grip changes both dimensions' | Out-Null
    $resized = $overlay.Current.BoundingRectangle
    if ((Find-Element $overlay 'Id' 'PromptText').Current.BoundingRectangle.Height -le $beforeText.Height) { throw 'Summary text did not wrap into more lines after narrowing.' }
    $narrowTimer = (Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle
    $narrowPrompt = (Find-Element $overlay 'Id' 'PromptText').Current.BoundingRectangle
    if ($narrowTimer.Bottom -ge $narrowPrompt.Top) { throw 'Narrow overlay timer is not above the summary.' }
    if ($narrowPrompt.Width -lt $resized.Width - 70) { throw 'Narrow overlay did not give the text the full available width.' }
    Save-WindowImage $overlay 'overlay-resized-wrapped.png'
    $showOutput = Find-Element $window 'Id' 'ShowOutput'
    if (([System.Windows.Automation.TogglePattern]$showOutput.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw 'Output summary must default off.' }
    ([System.Windows.Automation.TogglePattern]$showOutput.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Wait-Until { (Find-Element $overlay 'Id' 'FirstText').Current.Name -ceq $overlaySummary } 'conversation starts with Input1' | Out-Null
    if ((Find-Element $overlay 'Id' 'FirstLabel').Current.Name -ne 'You' -or $showElapsed.Current.IsEnabled) { throw 'Output mode must label the input and own fixed timer visibility.' }
    $timerTop = (Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle.Top
    Save-WindowImage $overlay 'conversation-input1.png'
    Invoke-Button $window 'PlayPause'
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'isolated replay process'
    $replayId = [int]$replay.ProcessId
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' -and (Find-Element $window 'Id' 'PlayPause').Current.IsEnabled } 'Open prepares target without starting playback' 50 | Out-Null
    if ([Math]::Abs($overlay.Current.BoundingRectangle.Width - $resized.Width) -gt 2 -or [Math]::Abs($overlay.Current.BoundingRectangle.Height - $resized.Height) -gt 2) { throw 'Playback updates reset the resized overlay.' }
    if ((Find-Element $window 'Id' 'NextStep').Current.IsEnabled) { throw 'Next Step must be unavailable before the first exchange.' }
    if (([System.Windows.Automation.TogglePattern]$showPrompt.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On -or
        ([System.Windows.Automation.TogglePattern]$showElapsed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { throw 'Open must preserve presentation choices.' }
    Save-WindowImage $window 'controller-open-ready.png'
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Play') { throw 'Open started playback without a second click.' }
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'explicit Play starts playback' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' } 'paused playback' | Out-Null
    Save-WindowImage $window 'controller-paused.png'
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Start Over' -and (Find-Element $window 'Id' 'NextStep').Current.IsEnabled } 'first answer review offers restart and next exchange' | Out-Null
    Wait-Until { (Find-Element $overlay 'Id' 'SecondText').Current.Name -ceq $outputSummary } 'completed Input1 and Output1' | Out-Null
    if ((Find-Element $overlay 'Id' 'FirstText').Current.Name -cne $overlaySummary -or
        (Find-Element $overlay 'Id' 'SecondLabel').Current.Name -ne 'AI' -or
        (Find-Element $overlay 'Id' 'ElapsedText').Current.Name -ne '00:01:01') { throw 'First completion changed input, labels or cumulative recorded timer.' }
    if ([Math]::Abs((Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle.Top - $timerTop) -gt 1) { throw 'Completion moved the fixed timer.' }
    Save-WindowImage $overlay 'conversation-input1-output1.png'
    Invoke-Button $window 'NextStep'
    Wait-Until { (Find-Element $overlay 'Id' 'FirstText').Current.Name -ceq $outputSummary -and
        (Find-Element $overlay 'Id' 'SecondText').Current.Name -ceq 'Show the next recorded interaction.' } 'Output1 replaces Input1 above Input2' | Out-Null
    if ((Find-Element $overlay 'Id' 'FirstLabel').Current.Name -ne 'AI' -or
        (Find-Element $overlay 'Id' 'SecondLabel').Current.Name -ne 'You') { throw 'Next must swap speaker alignment and labels.' }
    if ([Math]::Abs((Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle.Top - $timerTop) -gt 1) { throw 'Next Step moved the fixed timer.' }
    Save-WindowImage $overlay 'conversation-output1-input2.png'
    Wait-Until { (Find-Element $window 'Id' 'Status').Current.Name -like 'Finished*' } 'second answer complete' | Out-Null
    Wait-Until { (Find-Element $overlay 'Id' 'FirstText').Current.Name -ceq 'Show the next recorded interaction.' -and
        (Find-Element $overlay 'Id' 'SecondText').Current.Name -like '*summary missing*' } 'Input2 plus explicit missing Output2 replaces previous context' | Out-Null
    if ((Find-Element $overlay 'Id' 'ElapsedText').Current.Name -ne '00:03:03' -or
        [Math]::Abs((Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle.Top - $timerTop) -gt 1) { throw 'Final output changed fixed cumulative timer semantics.' }
    Save-WindowImage $overlay 'conversation-input2-missing-output2.png'
    if ((Find-Element $window 'Id' 'NextStep').Current.IsEnabled) { throw 'Next Step must be unavailable after the final exchange.' }
    Save-WindowImage $window 'controller-finished.png'
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'Start Over restarts the selected demo' | Out-Null
    Wait-Until { (Find-Element $overlay 'Id' 'FirstText').Current.Name -ceq $overlaySummary } 'Start Over resets conversation to Input1' | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'Status').Current.Name -eq 'Exchange complete  1/2' } 'Start Over returns to first exchange' | Out-Null
    ([System.Windows.Automation.TogglePattern]$showOutput.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Wait-Until { (Find-Element $overlay 'Id' 'PromptText').Current.Name -ceq $overlaySummary -and $showElapsed.Current.IsEnabled } 'output off restores legacy input-only mode and elapsed choice' | Out-Null
    Invoke-Button $window 'Stop'
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'scoped replay closes' 20 | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'ChooseDemo').Current.IsEnabled } 'controller remains available after stop' | Out-Null
    if (-not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue)) { throw 'Stop closed the standalone controller.' }
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Open') { throw 'Stopped targets must return the primary control to Open.' }
    if (-not $showPrompt.Current.IsEnabled -or -not $showElapsed.Current.IsEnabled) { throw 'Presentation options must remain available after Stop.' }
    $overlay = Wait-Until { Get-AppWindow 'Playback overlay' } 'selected demo overlay after Stop'
    if ((Find-Element $overlay 'Id' 'PromptText').Current.Name -cne $overlaySummary -or
        (Find-Element $overlay 'Id' 'ElapsedText').Current.Name -ne '00:00:00') { throw 'Stop must restore the selected demo presentation, not stale playback progress.' }
    if ([Math]::Abs($overlay.Current.BoundingRectangle.Width - $resized.Width) -gt 2 -or [Math]::Abs($overlay.Current.BoundingRectangle.Height - $resized.Height) -gt 2) { throw 'Stop reset the resized overlay.' }
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
    Invoke-Button $window 'ChooseDemo'
    $dialog = Wait-Until { Get-AppWindow 'Find interaction' } 'persisted selections after restart'
    ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    $list = Find-Element $dialog 'Id' 'DemoList'
    if ($list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition).Count -ne 2) { throw 'Saved library did not survive application restart.' }
    ([System.Windows.Automation.WindowPattern]$dialog.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    ([System.Windows.Automation.WindowPattern]$window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    Wait-Until { -not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue) } 'reopened controller closes when idle' | Out-Null
    if ([IO.File]::ReadAllText($target) -ne $targetContent) { throw 'Playback modified the saved edit target.' }
    Write-Output 'UI ACCEPTANCE PASSED: automatic native/SDK table, filters, SDK raw-event preview, native capture/save, rename/select, manual input/output save/reopen/cancel/clear, isolated AI authoring launch/close, overlay resize/wrapping/retained size, default-off conversation checkbox, Input1 then Input1+Output1 then Output1+Input2 then Input2+missing-output guidance, labeled You/AI bubbles, fixed top cumulative 00:01:01/00:03:03 timer, output-off legacy restoration, Open without autoplay, Play/pause/resume, Next Step, final-step refusal, Start Over, scoped Stop, target closure/reopen, paused close, persistence, unchanged edit target.'
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
    if ($authoringId) {
        $authoringProcess = Get-Process -Id $authoringId -ErrorAction SilentlyContinue
        if ($authoringProcess) { $authoringProcess.CloseMainWindow() | Out-Null }
    }
    foreach ($title in @('Input / Output Summaries', 'Find interaction')) {
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
