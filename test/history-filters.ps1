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
} finally { $dialog.Close() }
Write-Output ('HISTORY FILTER/XAML CHECKS PASSED: ' + $count + ' assertions; no desktop window was displayed.')
