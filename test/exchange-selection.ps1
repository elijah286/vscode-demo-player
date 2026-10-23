param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'DemoDialogs.ps1')
$script:saved = $null
$script:cancel = $false
$script:stale = $false
$script:legacy = $false
$script:entry = [pscustomobject]@{ recording = [pscustomobject]@{
    turns = @(0..2 | ForEach-Object { [pscustomobject]@{ snapshot = [pscustomobject]@{ requests = @([pscustomobject]@{ message = [pscustomobject]@{ text = "Original input $_" } }) } } })
    promptSummaries = @('Reviewed input', $null, 'Last input')
    outputSummaries = @($null, 'Reviewed output', $null)
    playbackIncluded = @($true, $false, $true)
} }

function Assert-Selection([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-DemoLibrary($Request, $Owner) {
    switch ($Request.command) {
        'read' { return $script:entry }
        'summarySources' { return @('Original output 0', 'Original output 1', 'Original output 2') }
        'summaryBatch' {
            if ($script:stale) { throw 'Playback inclusion changed since opening this editor. Reopen it before saving.' }
            $script:saved = $Request
        }
        default { throw 'Unexpected test library operation.' }
    }
}

function New-DemoDialog([string]$Xaml, $Owner) {
    $reader = [Xml.XmlNodeReader]::new([xml]$Xaml)
    try { $native = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
    $dialog = [pscustomobject]@{ Native = $native; DialogResult = $null }
    $dialog | Add-Member ScriptMethod FindName { param($Name) return $this.Native.FindName($Name) }
    $dialog | Add-Member ScriptMethod ShowDialog {
        $checks = $this.FindName('Exchanges').Children
        Assert-Selection ($checks.Count -eq 3) 'All exchanges must be shown, including excluded ones.'
        Assert-Selection ($checks[0].IsChecked -and $checks[1].IsChecked -eq $script:legacy -and $checks[2].IsChecked) 'Saved inclusion must initialize each checkbox; legacy recordings include all.'
        if (-not $script:legacy) {
            Assert-Selection ($checks[0].Content.Text -match 'Reviewed input' -and $checks[1].Content.Text -match 'Reviewed output') 'Rows must prefer reviewed input/output summaries.'
        } else {
            Assert-Selection ($checks[0].Content.Text -match 'Original input 0') 'Legacy prompts must use source excerpts.'
        }
        Assert-Selection ($checks[0].Content.Text -match 'Original output 0') 'Missing summaries must fall back to readable source.'
        if ($script:cancel) { return $false }
        $click = [Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)
        $this.FindName('None').RaiseEvent($click)
        Assert-Selection (-not $this.FindName('Save').IsEnabled) 'An empty selection must not be saved.'
        $this.FindName('All').RaiseEvent($click)
        Assert-Selection ($this.FindName('Save').IsEnabled -and $checks[1].IsChecked) 'Select all must include previously excluded exchanges.'
        $checks[1].IsChecked = $false
        Assert-Selection ($this.FindName('Count').Text -eq '2/3 included') 'Counts must follow individual checkbox changes.'
        $this.FindName('Save').RaiseEvent($click)
        if ($script:stale) {
            Assert-Selection ($this.FindName('Error').Text -match 'Reopen') 'A stale-save error must remain visible.'
            Assert-Selection ($null -eq $this.DialogResult) 'A failed save must not close as success.'
        } else {
            Assert-Selection ($this.DialogResult -eq $true) 'A successful save must accept the selection.'
        }
        return $this.DialogResult
    }
    return $dialog
}

Show-DemoExchangeSelection $null 'synthetic' | Out-Null
Assert-Selection (($script:saved.summaries.playbackIncluded -join ',') -eq 'True,False,True') 'Save must preserve nonconsecutive original indices.'
Assert-Selection (($script:saved.summaries.promptSummaries -join '|') -eq 'Reviewed input||Last input') 'Selection must preserve summaries.'
$script:saved = $null
$script:cancel = $true
Show-DemoExchangeSelection $null 'synthetic' | Out-Null
Assert-Selection ($null -eq $script:saved) 'Cancel must not write.'
$script:cancel = $false
$script:stale = $true
Show-DemoExchangeSelection $null 'synthetic' | Out-Null
Assert-Selection ($null -eq $script:saved) 'A stale save must not write.'
$script:stale = $false
$script:legacy = $true
$script:entry.recording.promptSummaries = $null
$script:entry.recording.outputSummaries = $null
$script:entry.recording.playbackIncluded = $null
Show-DemoExchangeSelection $null 'synthetic' | Out-Null
Assert-Selection ($script:saved.summaries.promptSummaries.Count -eq 3 -and $script:saved.summaries.outputSummaries.Count -eq 3) 'Legacy recordings must save full aligned empty summary arrays.'
Write-Output 'EXCHANGE SELECTION PASSED: hidden real WPF controls; summaries/source previews, saved inclusion, select/deselect all, empty guard, individual counts, nonconsecutive save, cancel and stale-save error.'
