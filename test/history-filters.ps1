param([string]$ApplicationRoot)

$ErrorActionPreference = 'Stop'
if (-not $ApplicationRoot) { $ApplicationRoot = Split-Path $PSScriptRoot -Parent }
Add-Type -AssemblyName PresentationFramework
. (Join-Path $ApplicationRoot 'DemoDialogs.ps1')
$count = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw ($Label + ': expected ' + $Expected + ', got ' + $Actual) }
    $script:count++
}
$row = [pscustomobject]@{
    Title = 'Recorded [literal] conversation'; Project = 'Project A'; ProjectPath = 'C:\Work\Project A'
    ProjectKey = 'C:\Work\Project A'; Agent = 'Saved Agent'; AgentKey = 'Saved Agent'; Source = 'Code agent'
    Status = 'Partial'; LastActivity = [datetime]'2026-10-16T23:59:59'; Prompts = 4; DurationSeconds = 90
}
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' '*' '*' $null $null $null $null) $true 'No filters'
Assert-Equal (Test-DemoHistoryRow $row '[literal]' '*' '*' '*' '*' $null $null $null $null) $true 'Search is literal, not a regex'
Assert-Equal (Test-DemoHistoryRow $row 'project a' '*' '*' '*' '*' $null $null $null $null) $true 'Project search ignores case'
Assert-Equal (Test-DemoHistoryRow $row '' 'C:\Other\Project A' '*' '*' '*' $null $null $null $null) $false 'Same project name does not match a different path'
Assert-Equal (Test-DemoHistoryRow $row '' '*' 'Other Agent' '*' '*' $null $null $null $null) $false 'Agent filter'
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' 'Other source' '*' $null $null $null $null) $false 'Source filter'
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' '*' 'Ready' $null $null $null $null) $false 'Status filter'
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' '*' '*' ([datetime]'2026-10-16') ([datetime]'2026-10-16') 4 90) $true 'Inclusive dates and exact numeric thresholds'
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' '*' '*' $null ([datetime]'2026-10-15') $null $null) $false 'Date exclusion'
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' '*' '*' $null $null 5 90) $false 'Prompt threshold'
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' '*' '*' $null $null 4 91) $false 'Duration threshold'
$row.LastActivity = $null; $row.Prompts = $null; $row.DurationSeconds = $null
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' '*' '*' $null $null $null $null) $true 'Unknown metadata remains visible without filters'
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' '*' '*' ([datetime]'2026-10-16') $null $null $null) $false 'Unknown dates cannot satisfy date filters'
Assert-Equal (Test-DemoHistoryRow $row '' '*' '*' '*' '*' $null $null 0 0) $false 'Unknown numbers are not coerced to zero'

$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ApplicationRoot 'DemoDialogs.ps1'), [ref]$null, [ref]$null)
$previousSummaryRoot = $env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT
try {
    $env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT = $null
    $firstPaths = Get-DemoSummaryAuthoringPaths
    $secondPaths = Get-DemoSummaryAuthoringPaths
    Assert-Equal $firstPaths.Profile $secondPaths.Profile 'Authoring profile is persistent across launches'
    Assert-Equal $firstPaths.Profile (Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\summary-authoring') 'Authoring never uses the normal editor profile'
    Assert-Equal $firstPaths.Extensions (Join-Path $firstPaths.Profile 'extensions') 'Providers remain in a dedicated persistent directory'
    Assert-Equal $firstPaths.Workspace (Join-Path $firstPaths.Profile 'workspace') 'Repeated launches reuse a dedicated workspace'
    $env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT = Join-Path $ApplicationRoot '.build\synthetic-summary-profile'
    Assert-Equal (Get-DemoSummaryAuthoringPaths).Profile $env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT 'Acceptance can explicitly isolate the authoring profile'
    $launch = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-DemoSummaryAuthoring' }, $true).Extent.Text
    Assert-Equal $launch.Contains("'--reuse-window'") $true 'Authoring reuses its own workspace window'
    Assert-Equal $launch.Contains("'--shared-data-dir'") $true 'New VS Code shared account storage is isolated too'
    Assert-Equal $launch.Contains("['HISTORY_REPLAY_SUMMARY_INBOX']") $true 'Running authoring process receives later selections through inbox'
    Assert-Equal $launch.Contains("'HISTORY_REPLAY_SUMMARY_ENTRY'") $false 'Launcher does not rely on stale process selection environment'
    Assert-Equal $launch.Contains('[IO.File]::Move($pending, $request)') $true 'Launch requests are published atomically'
} finally { $env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT = $previousSummaryRoot }
foreach ($call in $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DemoLibrary'
}, $true)) {
    Assert-Equal $call.CommandElements.Count 3 'Every dialog library operation supplies its owner'
    Assert-Equal ($call.CommandElements[2].Extent.Text -in @('$dialog', '$Owner')) $true 'Every dialog library operation routes through its current owner'
}
$xaml = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value -like '<Window*Title="Find interaction"*'
}, $true) | Select-Object -First 1
if (-not $xaml) { throw 'Capture dialog XAML was not found.' }
$dialog = New-DemoDialog $xaml.Value $null
try {
    $grid = $dialog.FindName('Sessions')
    Assert-Equal $dialog.FindName('PickerTabs').SelectedIndex 0 'Agent conversations are the default entry'
    Assert-Equal $dialog.FindName('PickerTabs').Items.Count 2 'Saved selections share the same picker'
    Assert-Equal $dialog.FindName('Save').Content 'Use selected exchanges' 'Primary action describes the user goal'
    Assert-Equal $dialog.FindName('SavedActions').IsExpanded $false 'Library management is secondary'
    Assert-Equal $grid.GetType().Name 'DataGrid' 'History uses a table'
    Assert-Equal $grid.Columns.Count 9 'All metadata columns exist'
    Assert-Equal $grid.IsReadOnly $true 'History rows cannot edit source metadata'
    Assert-Equal $grid.Columns[6].SortMemberPath 'DurationSeconds' 'Duration sorts numerically, not by its display string'
    foreach ($name in @('Refresh', 'HistorySearch', 'ProjectFilter', 'AgentFilter', 'SourceFilter', 'StatusFilter', 'DateFrom', 'DateTo', 'MinPrompts', 'MinDuration', 'ClearFilters', 'AddLocation')) {
        Assert-Equal ($null -ne $dialog.FindName($name)) $true ('Control exists: ' + $name)
    }
    foreach ($name in @('SelectAll', 'SelectAvailable', 'ClearSelection', 'SelectionCount')) {
        Assert-Equal ($null -ne $dialog.FindName($name)) $true ('Selection control exists: ' + $name)
    }
    $turns = $dialog.FindName('Turns')
    Assert-Equal ([Windows.Controls.VirtualizingPanel]::GetIsVirtualizing($turns)) $true 'Exchange rows are virtualized'
    Assert-Equal ([Windows.Controls.VirtualizingPanel]::GetVirtualizationMode($turns)) 'Recycling' 'Exchange containers are recycled'
    $dialog.Tag = @{ UpdatingTurns = $false }
    $turns.ItemsSource = @(
        [pscustomobject]@{ Turn = [pscustomobject]@{ index = 0; error = $null } },
        [pscustomobject]@{ Turn = [pscustomobject]@{ index = 1; error = 'Malformed prompt' } },
        [pscustomobject]@{ Turn = [pscustomobject]@{ index = 2; error = $null; sdkCompletion = 'partial' } }
    )
    $turns.SelectAll()
    Assert-Equal $turns.SelectedItems.Count 3 'Select all still includes every loaded exchange'
    $selectAvailable = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'Add_Click' -and $node.Expression.Extent.Text -eq '$dialog.FindName(''SelectAvailable'')'
    }, $true)
    if (-not $selectAvailable) { throw 'Production Select available handler was not found.' }
    $script:selectionUpdates = 0
    $updatePreview = { $script:selectionUpdates++ }
    & ($selectAvailable.Arguments[0].ScriptBlock.GetScriptBlock())
    Assert-Equal $turns.SelectedItems.Count 2 'Select available excludes unreadable entries only'
    Assert-Equal $turns.SelectedItems[1].Turn.index 2 'A partial SDK exchange remains selected'
    Assert-Equal $dialog.Tag.UpdatingTurns $false 'Bulk selection guard is restored'
    Assert-Equal $script:selectionUpdates 1 'Bulk selection triggers exactly one preview update'
    function Get-CaptureBlock([string]$Variable) {
        $assignment = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq ('$' + $Variable)
        }.GetNewClosure(), $true)
        if (-not $assignment) { throw ('Production block not found: ' + $Variable) }
        return $assignment.Right.Expression.ScriptBlock.GetScriptBlock()
    }
    $sessions = $dialog.FindName('Sessions')
    $sourceBox = $dialog.FindName('Source')
    $captureStatus = $dialog.FindName('CaptureStatus')
    $title = $dialog.FindName('Title')
    $reviewed = $dialog.FindName('Reviewed')
    $preview = $dialog.FindName('Preview')
    $save = $dialog.FindName('Save')
    Assert-Equal $save.IsEnabled $false 'Save is disabled before loading'
    $script:testInspection = [pscustomobject]@{
        title = 'Mixed conversation'
        turns = @(
            [pscustomobject]@{ index = 0; prompt = 'Available'; content = 'Saved answer' },
            [pscustomobject]@{ index = 1; prompt = 'Incomplete'; error = 'Missing: completion result.' },
            [pscustomobject]@{ index = 2; prompt = 'Partial SDK'; sdkCompletion = 'partial' }
        )
    }
    function Invoke-DemoLibrary { param($Request, $Owner) return $script:testInspection }
    $loadSource = Get-CaptureBlock 'loadSource'
    & $loadSource 'synthetic.jsonl'
    Assert-Equal $turns.Items.Count 3 'Loading keeps unavailable exchanges visible'
    Assert-Equal $turns.SelectedItems.Count 2 'Loading selects only available exchanges'
    Assert-Equal $turns.SelectedItems[1].Turn.index 2 'Loading includes supported partial SDK exchanges'
    Assert-Equal $dialog.Tag.UpdatingTurns $false 'Loading restores bulk selection guard'
    $updateSaveState = Get-CaptureBlock 'updateSaveState'
    $updatePreview = Get-CaptureBlock 'updatePreview'
    $previewTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $previewTimer.Interval = [TimeSpan]::FromMinutes(1)
    $previewTick = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'Add_Tick' -and $node.Expression.Extent.Text -eq '$previewTimer'
    }, $true).Arguments[0].ScriptBlock.GetScriptBlock()
    foreach ($event in @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Arguments.Count -eq 1 -and $node.Arguments[0].Extent.Text -eq '$updateSaveState'
    }, $true))) { & ([scriptblock]::Create($event.Extent.Text)) }
    & $updatePreview
    Assert-Equal ($captureStatus.Text -match '1 unavailable exchanges excluded.*Exchange 2: Missing: completion result') $true 'Excluded count and exact reason are explicit'
    Assert-Equal $save.IsEnabled $false 'Save stays disabled until preview and review'
    & $previewTick
    $reviewed.IsChecked = $true
    Assert-Equal $save.IsEnabled $true 'Valid reviewed available selection enables Save'
    $title.Text = ' '
    Assert-Equal $save.IsEnabled $true 'Blank title uses an automatic name'
    $title.Text = 'Valid title'
    Assert-Equal $save.IsEnabled $true 'Corrected title enables Save'
    $reviewed.IsChecked = $false
    Assert-Equal $save.IsEnabled $false 'Revoking review disables Save'
    $reviewed.IsChecked = $true
    $turns.SelectAll()
    & $updatePreview
    & $previewTick
    $reviewed.IsChecked = $true
    Assert-Equal $save.IsEnabled $false 'Review cannot enable Save with unavailable selections'
    Assert-Equal ($captureStatus.Text -match 'Use Select available') $true 'Invalid selection explains recovery'
    & ($selectAvailable.Arguments[0].ScriptBlock.GetScriptBlock())
    Assert-Equal $reviewed.IsChecked $false 'Changing selection invalidates prior review'
    Assert-Equal $save.IsEnabled $false 'Selection changes disable Save while preview is pending'
    & $previewTick
    $reviewed.IsChecked = $true
    Assert-Equal $save.IsEnabled $true 'Select available recovers the valid capture workflow'
    $turns.UnselectAll()
    & $updatePreview
    & $previewTick
    Assert-Equal $save.IsEnabled $false 'Empty selection disables Save'
    Assert-Equal $reviewed.IsEnabled $false 'Empty preview cannot be acknowledged'
    Assert-Equal ($captureStatus.Text -match 'Select 1 to 100') $true 'Empty selection explains required action'
    foreach ($case in @(
        @{ Turns = @(); Selected = 0; Status = 'no saved exchanges' },
        @{ Turns = @($script:testInspection.turns[1]); Selected = 0; Status = 'No available exchanges' },
        @{ Turns = @(0..100 | ForEach-Object { [pscustomobject]@{ index = $_; prompt = 'Available' } }); Selected = 101; Status = 'at most 100' }
    )) {
        $script:testInspection = [pscustomobject]@{ title = 'Boundary conversation'; turns = $case.Turns }
        & $loadSource 'boundary.jsonl'
        Assert-Equal $turns.SelectedItems.Count $case.Selected 'Default selection is not silently capped'
        Assert-Equal ($captureStatus.Text -match $case.Status) $true ('Boundary status: ' + $case.Status)
        & $previewTick
        $reviewed.IsChecked = $true
        & $updateSaveState
        Assert-Equal $save.IsEnabled $false 'Invalid boundaries cannot be saved even with review'
    }
    $turns.SelectedItems.RemoveAt(100)
    & $updatePreview
    & $previewTick
    $reviewed.IsChecked = $true
    Assert-Equal $save.IsEnabled $true 'Exactly 100 available reviewed exchanges can be saved'
    $title.Text = ''
    & $updateSaveState
    Assert-Equal $save.IsEnabled $true 'Naming is optional'
    Assert-Equal $dialog.FindName('SelectionAiSummaries').IsEnabled $true 'AI summaries are available before leaving selection'
    Assert-Equal $dialog.FindName('SelectionSummaries').IsEnabled $true 'Manual review is available before leaving selection'
    $prepareSelection = Get-CaptureBlock 'prepareSelection'
    $dialog.Tag.Inspection | Add-Member -NotePropertyName sha256 -NotePropertyValue 'reviewed-source-hash'
    $script:preparedRequests = [System.Collections.Generic.List[object]]::new()
    $script:sourceHash = 'reviewed-source-hash'
    $script:savedSelection = [pscustomobject]@{ id = 'synthetic-selection'; recording = [pscustomobject]@{ promptSummaries = @('Original summary') } }
    function Invoke-DemoLibrary {
        param($Request, $Owner)
        $script:preparedRequests.Add($Request)
        switch ($Request.command) {
            'capture' { return $script:savedSelection }
            'read' { return $script:savedSelection }
            'inspect' { return [pscustomobject]@{ sha256 = $script:sourceHash } }
            default { throw ('Unexpected test request: ' + $Request.command) }
        }
    }
    $result = & $prepareSelection
    Assert-Equal $result.id 'synthetic-selection' 'Preparing creates a playback selection'
    Assert-Equal $script:preparedRequests[0].title 'Boundary conversation' 'Blank name preserves automatic conversation title'
    Assert-Equal ($script:preparedRequests[0].indices -join ',') ((0..99) -join ',') 'Exactly the selected exchanges are saved in source order'
    $script:savedSelection.recording.promptSummaries[0] = 'Reviewed updated summary'
    $result = & $prepareSelection
    Assert-Equal @($script:preparedRequests | Where-Object command -eq 'capture').Count 1 'Summary preparation and playback reuse one saved copy'
    Assert-Equal $result.recording.promptSummaries[0] 'Reviewed updated summary' 'Reuse reads latest reviewed summaries without reselection'
    $script:sourceHash = 'changed-source-hash'
    $failure = $null
    try { & $prepareSelection | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-Equal ($failure -match 'source changed') $true 'Reusing a selection still refuses changed source bytes'
    $script:sourceHash = 'reviewed-source-hash'
    $reviewed.IsChecked = $false
    $failure = $null
    try { & $prepareSelection | Out-Null } catch { $failure = $_.Exception.Message }
    Assert-Equal ($failure -match 'Review the selected content') $true 'Preparing summaries cannot bypass review'
    $dialog.Tag.Inspection = $null
    & $updateSaveState
    Assert-Equal $save.IsEnabled $false 'Save requires a loaded inspection'
    $previewTimer.Stop()
} finally { $dialog.Close() }
$first = [pscustomobject]@{ Turn = [pscustomobject]@{ index = 0; prompt = ('x' * 100000); content = 'FIRST CONTENT'; details = 'FIRST RAW'; error = 'Explicit unavailable reason' } }
$second = [pscustomobject]@{ Turn = [pscustomobject]@{ index = 1; prompt = 'Second'; content = 'SECOND CONTENT'; details = 'SECOND RAW' } }
Assert-Equal ((Get-DemoTurnLabel $first.Turn).Length -lt 200) $true 'Long prompts have bounded row labels'
$readable = Get-DemoSelectionPreview @($second, $first) $false
Assert-Equal ($readable.IndexOf('FIRST CONTENT') -lt $readable.IndexOf('SECOND CONTENT')) $true 'Preview follows source order'
Assert-Equal ($readable.Contains('Explicit unavailable reason')) $true 'Unavailable reason remains visible'
Assert-Equal ((Get-DemoSelectionPreview @($first) $true).Contains('FIRST RAW')) $true 'Raw preview uses original details'
Assert-Equal ((Get-DemoSelectionPreview @($first) $false).Contains('FIRST RAW')) $false 'Readable preview does not expand raw data'
$large = [pscustomobject]@{ Turn = [pscustomobject]@{ index = 0; content = ('x' * 1000000); details = ('y' * 1000000) } }
foreach ($raw in @($false, $true)) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $bounded = Get-DemoSelectionPreview @($large) $raw
    $clock.Stop()
    Assert-Equal ($bounded.Length -le 32768) $true 'Preview respects exact character budget'
    Assert-Equal ($bounded.Contains('Captured content is not truncated.')) $true 'Truncation is explicit'
    Assert-Equal ($clock.ElapsedMilliseconds -lt 100) $true 'Large preview construction stays below 100 ms'
}
Assert-Equal $large.Turn.content.Length 1000000 'Preview does not modify captured content'
Assert-Equal (Get-DemoSelectionPreview @() $false) '' 'Empty selection clears the preview'

# Exercise both sets of production handlers in their actual nested scopes, without showing a window.
$libraryFunction = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-InteractionPickerWindow'
}, $true)
$statements = $libraryFunction.Body.EndBlock.Statements
$initializeSaved = ($statements[0..($statements.Count - 3)] | ForEach-Object { $_.Extent.Text }) -join "`n"
${function:Show-InteractionPickerWindow} = [scriptblock]::Create("param(`$dialog)`n" + $initializeSaved + "`n& `$script:exercisePicker")
$script:pickerEntries = @()
$script:pickerCaptures = 0
$script:pickerAiId = $null
$script:pickerClearId = $null
$script:pickerInspection = [pscustomobject]@{
    title = 'Synthetic agent conversation'; sha256 = 'synthetic-hash'
    turns = @([pscustomobject]@{ index = 0; prompt = 'Original long prompt'; content = 'Original prompt and answer' })
}
function Invoke-DemoLibrary {
    param($Request, $Owner)
    switch ($Request.command) {
        'list' { return $script:pickerEntries }
        'inspect' { return $script:pickerInspection }
        'capture' {
            $script:pickerCaptures++
            $script:pickerEntries = @([pscustomobject]@{ id = 'picker-entry'; title = $Request.title; count = 1; createdAt = '2026-10-17'; source = 'Synthetic agent'; preview = 'Original long prompt'; notice = 'Synthetic only' })
            return $script:pickerEntries[0]
        }
        'read' { return [pscustomobject]@{ id = 'picker-entry'; recording = [pscustomobject]@{ promptSummaries = @('Latest reviewed summary') } } }
        default { throw ('Unexpected picker request: ' + $Request.command) }
    }
}
function Show-DemoError($Owner, $Failure) { throw $Failure }
function Show-DemoSummaryDialog($Owner, $Id) {
    Assert-Equal $Id 'picker-entry' 'Inline summary editor receives the prepared selection'
    return $true
}
function Show-DemoSummaryAuthoringNotice($Owner, $Id, $Scope = 'both') { $script:pickerAiId = $Id; $script:pickerAiScope = $Scope }
function Show-DemoClearSummariesNotice($Owner, $Id) { $script:pickerClearId = $Id; return $true }
$script:exercisePicker = {
    try {
        Assert-Equal $dialog.FindName('PickerTabs').SelectedIndex 0 'Live picker starts with agent history'
        $dialog.FindName('Source').Text = 'synthetic.jsonl'
        $dialog.FindName('Load').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Equal $dialog.FindName('Turns').SelectedItems.Count 1 'Live load selects available exchanges'
        $previewTimer.Stop()
        & $previewTick
        $dialog.FindName('Reviewed').IsChecked = $true
        Assert-Equal $dialog.FindName('SelectionSummaries').IsEnabled $true 'Live review enables inline summaries'
        $dialog.FindName('SelectionSummaries').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Equal $script:pickerCaptures 1 'Inline summary preparation saves once'
        Assert-Equal $dialog.FindName('Demos').Items.Count 1 'Prepared selection appears in the other tab immediately'
        $dialog.FindName('SelectionAiSummaries').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Equal $script:pickerAiId 'picker-entry' 'Inline AI authoring targets the same selection'
        Assert-Equal $script:pickerAiScope 'both' 'Existing combined generation retains its scope'
        Assert-Equal $dialog.FindName('SelectionAiResponses').Content 'Generate AI summaries of responses' 'Explicit response button label'
        Assert-Equal $dialog.FindName('SelectionAiResponses').IsEnabled $true 'Reviewed source enables response generation'
        $dialog.FindName('SelectionAiResponses').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Equal $script:pickerAiScope 'output' 'Response button selects output-only generation'
        Assert-Equal $script:pickerAiId 'picker-entry' 'Response generation reuses the prepared selection'
        Assert-Equal $script:pickerCaptures 1 'AI preparation reuses the saved selection'
        Assert-Equal $dialog.FindName('SelectionClearSummaries').IsEnabled $true 'Reviewed selection enables clearing summaries'
        $dialog.FindName('SelectionClearSummaries').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Equal $script:pickerClearId 'picker-entry' 'Inline clear targets the same prepared selection'
        Assert-Equal $script:pickerCaptures 1 'Clear preparation reuses the saved selection'
        $result = & $prepareSelection
        Assert-Equal $result.recording.promptSummaries[0] 'Latest reviewed summary' 'Playback preparation reloads reviewed AI results'
        $dialog.FindName('PickerTabs').SelectedIndex = 1
        $dialog.FindName('Demos').SelectedIndex = 0
        Assert-Equal $dialog.FindName('SavedTitle').Text 'Synthetic agent conversation' 'Saved selection has an automatic title'
        Assert-Equal $dialog.FindName('Title').Text 'Synthetic agent conversation' 'Saved-tab selection does not overwrite the conversation draft'
        Assert-Equal $dialog.FindName('Select').IsEnabled $true 'Saved selection can be used without a management step'
        Assert-Equal $dialog.FindName('AiResponses').IsEnabled $true 'Saved selection enables response generation'
        $dialog.FindName('AiResponses').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Equal $script:pickerAiScope 'output' 'Saved response button selects output-only generation'
        Assert-Equal $script:pickerAiId 'picker-entry' 'Saved response button targets selected entry'
        Assert-Equal $dialog.FindName('ClearSummaries').IsEnabled $true 'Saved selection enables clearing summaries'
        $script:pickerClearId = $null
        $dialog.FindName('ClearSummaries').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        Assert-Equal $script:pickerClearId 'picker-entry' 'Saved-tab clear targets the chosen selection'
        $dialog.FindName('SavedSearch').Text = 'No matching selection'
        Assert-Equal $dialog.FindName('Demos').Items.Count 0 'Saved search uses its own list'
        Assert-Equal $dialog.FindName('Select').IsEnabled $false 'No-match search disables the saved selection action'
        Assert-Equal $dialog.FindName('AiResponses').IsEnabled $false 'No-match search disables response generation'
        Assert-Equal $dialog.FindName('ClearSummaries').IsEnabled $false 'No-match search disables clearing'
        $dialog.FindName('Source').Text = 'different.jsonl'
        Assert-Equal $dialog.FindName('Save').IsEnabled $false 'Changing source disables playback preparation'
        Assert-Equal $dialog.FindName('SelectionAiSummaries').IsEnabled $false 'Changing source also disables AI preparation'
        Assert-Equal $dialog.FindName('SelectionAiResponses').IsEnabled $false 'Changing source disables response generation'
        Assert-Equal $dialog.FindName('SelectionClearSummaries').IsEnabled $false 'Changing source also disables clearing'
    } finally { $dialog.Close() }
}
Show-InteractionPicker $null | Out-Null
$controllerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ApplicationRoot 'Show-ReplayController.ps1'), [ref]$null, [ref]$null)
$controllerXaml = $controllerAst.Find({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like '<Window*'
}, $true)
$controller = New-DemoDialog $controllerXaml.Value $null
try {
    Assert-Equal $controller.FindName('ChooseDemo').Content 'Find interaction...' 'Controller has one task-focused entry point'
    Assert-Equal ($null -eq $controller.FindName('Capture')) $true 'Controller no longer exposes Capture'
    Assert-Equal ($null -eq $controller.FindName('Library')) $true 'Controller no longer exposes Manage Demos'
    Assert-Equal $controller.FindName('PrimaryLabel').Text 'Open' 'Preparing a target stays separate from playback'
    Assert-Equal $controller.FindName('PlayPause').IsEnabled $false 'Playback requires a selected interaction'
} finally { $controller.Close() }
$summaryFunction = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-DemoSummaryDialog'
}, $true)
$summaryXaml = $summaryFunction.Find({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like '<Window*Title="Input / Output Summaries"*'
}, $true)
$dialog = New-DemoDialog $summaryXaml.Value $null
try {
    $entry = [pscustomobject]@{ recording = [pscustomobject]@{
        turns = @(
            [pscustomobject]@{ snapshot = [pscustomobject]@{ requests = @([pscustomobject]@{ message = [pscustomobject]@{ text = 'First original query' } }) } },
            [pscustomobject]@{ snapshot = [pscustomobject]@{ requests = @([pscustomobject]@{ message = [pscustomobject]@{ text = 'Second original query' } }) } }
        )
        promptSummaries = @('First saved summary', 'Second saved summary')
        outputSummaries = @('First recorded result', 'Second recorded result')
    } }
    $outputs = @('First original answer', 'Second original answer')
    $dialog.Tag = @{ Summaries = [object[]]$entry.recording.promptSummaries.Clone(); Outputs = [object[]]$entry.recording.outputSummaries.Clone(); Index = -1 }
    $exchange = $dialog.FindName('Exchange')
    $summary = $dialog.FindName('Summary')
    foreach ($label in @('Exchange 1 - Input', 'Exchange 1 - Output', 'Exchange 2 - Input', 'Exchange 2 - Output')) {
        $exchange.Items.Add($label) | Out-Null
    }
    $storeNode = $summaryFunction.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$storeDraft'
    }, $true)
    $storeDraft = $storeNode.Right.Expression.ScriptBlock.GetScriptBlock()
    $selectionNode = $summaryFunction.Find({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_SelectionChanged'
    }, $true)
    $exchange.Add_SelectionChanged($selectionNode.Arguments[0].ScriptBlock.GetScriptBlock())
    $exchange.SelectedIndex = 0
    Assert-Equal $summary.Text 'First saved summary' 'Summary editor loads saved text'
    Assert-Equal $summary.MaxLength 300 'Manual editor uses the shared 300-character budget'
    $summary.Text = 'x' * 300
    & $storeDraft
    Assert-Equal $dialog.Tag.Summaries[0].Length 300 'A full-budget manual summary is preserved'
    $deleteNode = $summaryFunction.Find({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'Add_Click' -and $node.Expression.Extent.Text -eq '$dialog.FindName(''DeleteSummary'')'
    }, $true)
    Assert-Equal ($null -ne $deleteNode) $true 'Individual delete-summary handler exists'
    & ($deleteNode.Arguments[0].ScriptBlock.GetScriptBlock())
    & $storeDraft
    Assert-Equal ($null -eq $dialog.Tag.Summaries[0]) $true 'Individual deletion clears only the current summary'
    Assert-Equal $dialog.Tag.Summaries[1] 'Second saved summary' 'Individual deletion preserves other summaries'
    Assert-Equal $dialog.FindName('Original').Text 'First original query' 'Individual deletion never deletes the original prompt'
    $exchange.SelectedIndex = 1
    Assert-Equal $summary.Text 'First recorded result' 'Output editor loads independently saved summary'
    Assert-Equal $dialog.FindName('Original').Text 'First original answer' 'Output editor shows recorded results, not the user query'
    $summary.Text = 'o' * 300
    & $storeDraft
    Assert-Equal $dialog.Tag.Outputs[0].Length 300 'Exact output summary budget is preserved'
    & ($deleteNode.Arguments[0].ScriptBlock.GetScriptBlock())
    & $storeDraft
    Assert-Equal ($null -eq $dialog.Tag.Outputs[0]) $true 'Deleting output clears only its summary'
    Assert-Equal $dialog.Tag.Outputs[1] 'Second recorded result' 'Output deletion preserves other outputs'
    Assert-Equal $dialog.Tag.Summaries[1] 'Second saved summary' 'Output deletion preserves input summaries'
    $clearNode = $summaryFunction.Find({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'Add_Click' -and $node.Expression.Extent.Text -eq '$dialog.FindName(''Clear'')'
    }, $true)
    Assert-Equal ($null -ne $clearNode) $true 'Production clear-drafts handler exists'
    & ($clearNode.Arguments[0].ScriptBlock.GetScriptBlock())
    Assert-Equal $summary.Text '' 'Clear empties the current summary'
    Assert-Equal $dialog.Tag.Summaries.Count 2 'Clear keeps one draft slot per exchange'
    Assert-Equal (@($dialog.Tag.Summaries | Where-Object { $null -ne $_ }).Count) 0 'Clear empties every draft'
    Assert-Equal (@($dialog.Tag.Outputs | Where-Object { $null -ne $_ }).Count) 0 'Clear empties output drafts too'
    $exchange.SelectedIndex = 2
    Assert-Equal $summary.Text '' 'Changing exchanges does not restore cleared drafts'
    Assert-Equal $dialog.FindName('Original').Text 'Second original query' 'Clear preserves original query display'
    $exchange.SelectedIndex = 0
    Assert-Equal $summary.Text '' 'Returning to first exchange keeps cleared draft'
    $request = @{ command = 'summaries'; summaries = @($dialog.Tag.Summaries); expected = $entry.recording.promptSummaries }
    $roundtrip = $request | ConvertTo-Json -Compress | ConvertFrom-Json
    Assert-Equal $roundtrip.summaries.Count 2 'Cleared drafts serialize as a full array'
    Assert-Equal (@($roundtrip.summaries | Where-Object { $null -ne $_ }).Count) 0 'Cleared draft slots serialize as null'
    Assert-Equal $entry.recording.promptSummaries[0] 'First saved summary' 'Clearing drafts alone does not change saved metadata'
    Assert-Equal $entry.recording.promptSummaries[1] 'Second saved summary' 'Unselected saved metadata is also unchanged'
    $summary.Text = 'Replacement draft'
    & $storeDraft
    Assert-Equal $dialog.Tag.Summaries[0] 'Replacement draft' 'Editing after clear can save a new summary'
    Assert-Equal ($null -eq $dialog.Tag.Summaries[1]) $true 'Editing one draft keeps other drafts cleared'
} finally { $dialog.Close() }
Write-Output ('HISTORY FILTER/SELECTION/XAML CHECKS PASSED: ' + $count + ' assertions; no desktop window was displayed.')
