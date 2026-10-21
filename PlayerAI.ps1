function Get-PlayerAISettings {
    $path = Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\ai-settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ version = 1; model = 'gpt-4.1-mini'; encryptedKey = $null } }
    $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($settings.version -ne 1 -or $settings.model -isnot [string] -or $settings.model -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,179}$' -or
        ($null -ne $settings.encryptedKey -and $settings.encryptedKey -isnot [string])) {
        throw 'OpenAI settings are invalid. Restore a valid settings file before continuing.'
    }
    return $settings
}

function Save-PlayerAISettings([string]$Model, [string]$ApiKey, [switch]$DeleteKey) {
    if ($Model -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,179}$') { throw 'Enter a valid OpenAI model ID.' }
    $settings = Get-PlayerAISettings
    $settings.model = $Model
    if ($DeleteKey) { $settings.encryptedKey = $null }
    elseif ($ApiKey) {
        if ($ApiKey -notmatch '^[\x21-\x7e]{20,512}$') { throw 'Enter a valid OpenAI API key (no spaces or line breaks).' }
        Add-Type -AssemblyName System.Security
        $bytes = [Text.Encoding]::UTF8.GetBytes($ApiKey)
        try {
            $settings.encryptedKey = [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect(
                $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
        } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    $path = Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\ai-settings.json'
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($settings | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Get-PlayerOpenAIKey {
    $settings = Get-PlayerAISettings
    if (-not $settings.encryptedKey) { return $null }
    Add-Type -AssemblyName System.Security
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($settings.encryptedKey),
        $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($bytes) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Show-PlayerAISettings($Owner, [switch]$RequireKey, [switch]$Rejected) {
    $settings = Get-PlayerAISettings
    $dialog = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="OpenAI Settings" Width="580" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
 <StackPanel Margin="18">
  <TextBlock Text="OpenAI API summaries" FontSize="18" Margin="0,0,0,10"/>
  <TextBlock Text="Enter your own OpenAI API key. API usage is billed separately from ChatGPT subscriptions. The saved key is encrypted for this Windows user; it is never included in recordings or exports." TextWrapping="Wrap"/>
  <TextBlock Margin="0,10"><Hyperlink x:Name="KeyLink" AutomationProperties.AutomationId="OpenAIKeyLink">Get an API key at platform.openai.com/api-keys</Hyperlink></TextBlock>
  <TextBlock x:Name="KeyStatus" TextWrapping="Wrap" Margin="0,0,0,8" AutomationProperties.AutomationId="OpenAIKeyStatus"/>
  <TextBlock Text="New / replacement API key (leave blank to keep the saved key)"/>
  <PasswordBox x:Name="Key" Margin="0,6,0,12" MaxLength="512" AutomationProperties.AutomationId="OpenAIKey"/>
  <TextBlock Text="OpenAI model ID (default: gpt-4.1-mini, low-cost and low-latency)"/>
  <TextBox x:Name="Model" Margin="0,6,0,12" MaxLength="180" AutomationProperties.AutomationId="OpenAIModel"/>
  <TextBlock x:Name="Error" Foreground="#B00020" TextWrapping="Wrap" Margin="0,0,0,10" AutomationProperties.AutomationId="OpenAISettingsError"/>
  <WrapPanel HorizontalAlignment="Right">
   <Button x:Name="Delete" Content="Delete saved key" Padding="12,6" Margin="0,0,8,0" AutomationProperties.AutomationId="DeleteOpenAIKey"/>
   <Button Content="Cancel" IsCancel="True" Padding="12,6" Margin="0,0,8,0" AutomationProperties.AutomationId="CancelOpenAISettings"/>
   <Button x:Name="Save" Content="Save settings" Padding="12,6" AutomationProperties.AutomationId="SaveOpenAISettings"/>
  </WrapPanel>
 </StackPanel>
</Window>
'@ $Owner
    $dialog.FindName('Model').Text = $settings.model
    $dialog.FindName('KeyStatus').Text = if ($settings.encryptedKey) { 'A key is saved for this Windows user. Its value is never displayed.' } else { 'No API key is saved. Enter a key to generate summaries.' }
    $dialog.FindName('Delete').IsEnabled = [bool]$settings.encryptedKey
    if ($Rejected) { $dialog.FindName('Error').Text = 'OpenAI rejected the saved key. Enter a replacement; no summaries were saved. Retry generation explicitly after saving.' }
    $dialog.FindName('KeyLink').Add_Click({
        try { [Diagnostics.Process]::Start([Diagnostics.ProcessStartInfo]@{ FileName = 'https://platform.openai.com/api-keys'; UseShellExecute = $true }) | Out-Null }
        catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Delete').Add_Click({
        try {
            Save-PlayerAISettings ($dialog.FindName('Model').Text) -DeleteKey
            $dialog.FindName('Key').Clear()
            $dialog.FindName('KeyStatus').Text = 'The saved key has been deleted. AI generation will ask for a key again.'
            $dialog.FindName('Delete').IsEnabled = $false
        } catch { $dialog.FindName('Error').Text = $_.Exception.Message }
    })
    $dialog.FindName('Save').Add_Click({
        try {
            $key = $dialog.FindName('Key').Password
            if ($RequireKey -and -not $key -and ($Rejected -or -not (Get-PlayerAISettings).encryptedKey)) { throw 'Enter an OpenAI API key to continue, or cancel.' }
            Save-PlayerAISettings ($dialog.FindName('Model').Text.Trim()) $key
            $dialog.FindName('Key').Clear()
            $dialog.DialogResult = $true
        } catch { $dialog.FindName('Error').Text = $_.Exception.Message }
    })
    try { return $dialog.ShowDialog() }
    finally { $dialog.FindName('Key').Clear() }
}

function Split-PlayerAISummarySource([string]$Source, [int]$MaxLength = 64000) {
    for ($offset = 0; $offset -lt $Source.Length;) {
        $length = [Math]::Min($MaxLength, $Source.Length - $offset)
        if ($offset + $length -lt $Source.Length -and [char]::IsHighSurrogate($Source[$offset + $length - 1])) { $length-- }
        $Source.Substring($offset, $length)
        $offset += $length
    }
}

function Invoke-PlayerAISummary($Candidate, $Progress, [string]$ApiKey, [string]$Model) {
    $parts = @(Split-PlayerAISummarySource $Candidate.source)
    $combine = $false
    $closingContext = ''
    if ($Candidate.kind -eq 'output' -and $parts.Count -gt 1) {
        $offset = [Math]::Max(0, $Candidate.source.Length - 3600)
        if ($offset -gt 0 -and [char]::IsLowSurrogate($Candidate.source[$offset])) { $offset++ }
        $closingContext = "`n`nRecorded assistant closing context (verbatim source, not another exchange; preserve any question and choices):`n" + $Candidate.source.Substring($offset)
    }
    do {
        $notes = [Collections.Generic.List[string]]::new()
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $phase = if ($combine) { 'Combining summaries' } else { 'Summarizing source' }
            $Progress.FindName('Progress').Text = 'Exchange ' + ($Candidate.index + 1) + ' ' + $Candidate.kind + ': ' + $phase + ', part ' + ($index + 1) + '/' + $parts.Count
            $summary = Invoke-DemoLibrary @{
                command = 'generateSummary'; apiKey = $ApiKey; model = $Model
                source = ($parts[$index] + $(if ($combine) { $closingContext } else { '' })); kind = $Candidate.kind; partial = ($parts.Count -gt 1); combine = $combine
            } $Progress -Helper 'openai-summaries.js' -TimeoutSeconds 95 -KeepOwnerEnabled
            $notes.Add($summary)
        }
        if ($parts.Count -eq 1) { return $summary }
        $parts = @(Split-PlayerAISummarySource ($notes -join "`n") 60000)
        $combine = $true
    } while ($parts.Count)
    throw 'The recorded summary source is empty. No summary was generated.'
}

function Invoke-DemoOpenAISummaries($Owner, [string]$Id, [ValidateSet('both','input','output')][string]$Scope) {
    if ($script:openAISummaryBusy) { throw 'An AI summary is already being generated or reviewed.' }
    $script:openAISummaryBusy = $true
    try {
        $prepared = Invoke-DemoLibrary @{ command = 'prepareSummaries'; id = $Id; scope = $Scope } $Owner -Helper 'openai-summaries.js'
        if (-not @($prepared.candidates).Count) {
            [Windows.MessageBox]::Show($Owner, 'No missing supported summaries need generation. Existing summaries are kept. Outputs without supported recorded text/tool status require manual summaries.', 'AI Summaries') | Out-Null
            return
        }
        if (-not (Get-PlayerAISettings).encryptedKey -and -not (Show-PlayerAISettings $Owner -RequireKey)) { return }
        $settings = Get-PlayerAISettings
        $consent = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Generate OpenAI Summaries" Width="780" Height="540" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
 <DockPanel Margin="16">
  <TextBlock x:Name="Notice" DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,12" AutomationProperties.AutomationId="OpenAIConsentNotice"/>
  <WrapPanel DockPanel.Dock="Bottom" HorizontalAlignment="Right" Margin="0,12,0,0">
   <Button Content="Cancel" IsCancel="True" Padding="14,6" Margin="0,0,8,0" AutomationProperties.AutomationId="CancelOpenAIGeneration"/>
   <Button x:Name="Generate" Content="Generate summaries" Padding="14,6" AutomationProperties.AutomationId="ConfirmOpenAIGeneration"/>
  </WrapPanel>
  <TextBox x:Name="Sources" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AutomationProperties.AutomationId="OpenAIConsentSources"/>
 </DockPanel>
</Window>
'@ $Owner
        $consent.FindName('Notice').Text = 'Send the ' + @($prepared.candidates).Count + ' sources shown below to OpenAI using model ' + $settings.model + '? API charges apply per request. Long sources are automatically split into bounded parts, then their summaries are combined with additional requests; no source text is dropped. Review for secrets before consenting. Only shown source text, intermediate summaries and summarization instructions are sent, with API response storage disabled (OpenAI retention policies still apply). Raw tool arguments/results, reasoning and metadata are excluded. Existing summaries are kept; unsupported outputs need manual editing. Nothing is saved until you review and save the drafts. Canceling cannot undo requests or their charges.'
        $consent.FindName('Sources').Text = (@($prepared.candidates | ForEach-Object { 'Exchange ' + ($_.index + 1) + ' - ' + $_.kind + "`r`n" + $_.source }) -join "`r`n`r`n---`r`n`r`n")
        $consent.FindName('Generate').Add_Click({ $consent.DialogResult = $true })
        if (-not $consent.ShowDialog()) { return }
        $key = Get-PlayerOpenAIKey
        $progress = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="Generating AI Summaries" Width="480" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
 <StackPanel Margin="18">
  <TextBlock x:Name="Progress" TextWrapping="Wrap" AutomationProperties.AutomationId="OpenAISummaryProgress"/>
  <ProgressBar IsIndeterminate="True" Height="12" Margin="0,14"/>
  <Button Content="Cancel" IsCancel="True" Padding="14,6" HorizontalAlignment="Right" AutomationProperties.AutomationId="CancelOpenAISummaryProgress"/>
 </StackPanel>
</Window>
'@ $Owner
        $progress.Tag = @{ Started = $false; Closed = $false; Drafts = [Collections.Generic.List[object]]::new(); Failure = $null }
        $progress.Add_Closed({ $progress.Tag.Closed = $true })
        $progress.Add_ContentRendered({
            if ($progress.Tag.Started) { return }
            $progress.Tag.Started = $true
            try {
                foreach ($candidate in $prepared.candidates) {
                    $progress.FindName('Progress').Text = 'Generating ' + ($progress.Tag.Drafts.Count + 1) + '/' + @($prepared.candidates).Count + ': Exchange ' + ($candidate.index + 1) + ' ' + $candidate.kind
                    $summary = Invoke-PlayerAISummary $candidate $progress $key $settings.model
                    $progress.Tag.Drafts.Add([pscustomobject]@{ index = $candidate.index; kind = $candidate.kind; summary = $summary })
                }
                $progress.DialogResult = $true
            } catch {
                $progress.Tag.Failure = $_
                if (-not $progress.Tag.Closed) { $progress.DialogResult = $false }
            }
        })
        if ($progress.ShowDialog()) {
            Show-DemoSummaryDialog $Owner $Id ([pscustomobject]@{ Entry = $prepared.entry; Outputs = $prepared.outputs; Drafts = @($progress.Tag.Drafts.ToArray()) }) | Out-Null
        } elseif ($progress.Tag.Failure) {
            if ($progress.Tag.Failure.Exception.Data['OpenAIAuth']) {
                Show-PlayerAISettings $Owner -RequireKey -Rejected | Out-Null
            } else { throw $progress.Tag.Failure }
        }
    } finally { $key = $null; $script:openAISummaryBusy = $false }
}
