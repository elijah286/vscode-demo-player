param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'DemoDialogs.ps1')
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'DemoDialogs.ps1'), [ref]$null, [ref]$null)
$count = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Get-Function([string]$Name) {
    return $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }.GetNewClosure(), $true)
}
function Get-Block($Scope, [string]$Variable) {
    $assignment = $Scope.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq ('$' + $Variable)
    }.GetNewClosure(), $true)
    if (-not $assignment) { throw "Missing production block: $Variable" }
    return $assignment.Right.Expression.ScriptBlock.GetScriptBlock()
}
function Pump([int]$Milliseconds) {
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $stop = [Windows.Threading.DispatcherTimer]::new()
    $stop.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $stop.Add_Tick({ $stop.Stop(); $frame.Continue = $false }.GetNewClosure())
    $stop.Start()
    try { [Windows.Threading.Dispatcher]::PushFrame($frame) } finally { $stop.Stop() }
}
$pickerFunction = Get-Function 'Show-InteractionPicker'
$pickerXaml = $pickerFunction.Find({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.TrimStart().StartsWith('<Window')
}, $true).Value
$dialog = New-DemoDialog $pickerXaml $null
foreach ($variable in @('$filterTimer', '$filterTimer.Interval')) {
    $initialization = $pickerFunction.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq $variable
    }.GetNewClosure(), $true)
    if (-not $initialization) { throw "Missing production timer initialization: $variable" }
    . ([scriptblock]::Create($initialization.Extent.Text))
}
try {
    Assert ($filterTimer.Interval.TotalMilliseconds -eq 150) 'Production history filtering must use the documented 150 ms delay.'
    $dialog.Tag = @{ UpdatingFilters = $false }
    $view = [Windows.Data.CollectionViewSource]::GetDefaultView(@(1,2,3))
    $script:refreshes = 0
    $updateCount = { $script:refreshes++ }
    $applyFilters = Get-Block $pickerFunction 'applyFilters'
    $filterTimer.Add_Tick($applyFilters)
    $textHandler = $pickerFunction.Find({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'Add_TextChanged' -and
        $node.Expression.Extent.Text -eq '$dialog.FindName($name)'
    }, $true).Arguments[0].ScriptBlock.GetScriptBlock()
    foreach ($name in @('HistorySearch', 'MinPrompts', 'MinDuration')) { $dialog.FindName($name).Add_TextChanged($textHandler) }
    $search = $dialog.FindName('HistorySearch')
    foreach ($value in @('s','sy','syn','synthetic')) { $search.Text = $value }
    Assert ($script:refreshes -eq 0) 'Rapid typing must not refresh synchronously.'
    Pump 400
    Assert ($script:refreshes -eq 1) 'A typing burst must coalesce to exactly one refresh.'
    Assert ($dialog.Tag.Filters.Search -eq 'synthetic') 'The coalesced filter must read the latest input.'
    Assert (-not $filterTimer.IsEnabled) 'Filtering must stop the timer instead of polling.'
    $search.Text = 'next'
    & $applyFilters
    Assert ($script:refreshes -eq 2 -and -not $filterTimer.IsEnabled) 'Explicit filter actions must apply immediately and cancel pending text refresh.'
    Pump 250
    Assert ($script:refreshes -eq 2) 'An immediate filter action must not leave a duplicate queued refresh.'
    $dialog.FindName('MinPrompts').Text = '-1'
    Pump 400
    Assert ($dialog.Tag.FilterError -match 'nonnegative whole numbers') 'Invalid numeric input must still report validation errors.'
    $search.Text = 'close pending'
    $closeHandler = $pickerFunction.Find({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'Add_Closed' -and $node.Extent.Text.Contains('$filterTimer.Stop()')
    }, $true).Arguments[0].ScriptBlock.GetScriptBlock()
    & $closeHandler
    Assert (-not $filterTimer.IsEnabled) 'Closing the picker must cancel its pending text filter.'
} finally { $filterTimer.Stop(); $dialog.Close() }

$exchangeFunction = Get-Function 'Show-DemoExchangeSelection'
$dialog = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
 <StackPanel><TextBlock x:Name="Count"/><Button x:Name="Save"/></StackPanel>
</Window>
'@ $null
try {
    $checks = [Collections.Generic.List[Windows.Controls.CheckBox]]::new()
    $selectionState = @{ Updating = $false }
    $updateCount = Get-Block $exchangeFunction 'updateCount'
    $setAll = Get-Block $exchangeFunction 'setAll'
    foreach ($index in 0..999) {
        $check = [Windows.Controls.CheckBox]::new()
        $check.IsChecked = $false
        $check.Add_Checked($updateCount)
        $check.Add_Unchecked($updateCount)
        $checks.Add($check)
    }
    $script:countWrites = 0
    $counter = $dialog.FindName('Count')
    # Observe Text changes directly; no timing threshold depends on machine speed.
    $descriptor = [ComponentModel.DependencyPropertyDescriptor]::FromProperty([Windows.Controls.TextBlock]::TextProperty, [Windows.Controls.TextBlock])
    $changed = [EventHandler]{ $script:countWrites++ }
    $descriptor.AddValueChanged($counter, $changed)
    try {
        & $setAll $true
        Assert ($counter.Text -eq '1000/1000 included') 'Bulk selection must include all rows.'
        Assert ($script:countWrites -eq 1) 'Selecting 1000 exchanges must write the count once, not 1000 times.'
        & $setAll $false
        Assert ($counter.Text -eq '0/1000 included' -and -not $dialog.FindName('Save').IsEnabled) 'Deselect all must preserve the empty-selection guard.'
        Assert ($script:countWrites -eq 2) 'Deselecting 1000 exchanges must also write the count once.'
        $checks[17].IsChecked = $true
        Assert ($counter.Text -eq '1/1000 included' -and $dialog.FindName('Save').IsEnabled) 'Individual changes must still update immediately.'
        Assert (-not $selectionState.Updating) 'Bulk selection must restore its notification guard.'
    } finally { $descriptor.RemoveValueChanged($counter, $changed) }
    Write-Output "Dialog performance: $count assertions passed; one filter refresh per burst, one count update per 1000-row bulk change."
} finally { $dialog.Close(); [VibeReplay.LibraryConnections]::Close() }
