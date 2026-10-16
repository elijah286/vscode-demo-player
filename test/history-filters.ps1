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
    $dialog.Tag = [pscustomobject]@{ UpdatingTurns = $false }
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
