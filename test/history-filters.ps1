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
$xaml = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value -like '<Window*Title="Capture Conversation"*'
}, $true) | Select-Object -First 1
if (-not $xaml) { throw 'Capture dialog XAML was not found.' }
$dialog = New-DemoDialog $xaml.Value $null
try {
    $grid = $dialog.FindName('Sessions')
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
    Assert-Equal $save.IsEnabled $false 'Blank title disables Save'
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
Write-Output ('HISTORY FILTER/SELECTION/XAML CHECKS PASSED: ' + $count + ' assertions; no desktop window was displayed.')
