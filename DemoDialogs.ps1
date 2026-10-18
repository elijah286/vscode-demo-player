function Start-DemoLibraryProcess([hashtable]$Request) {
    if (-not $script:NodePath) {
        $script:NodePath = Resolve-PlayerNode
    }
    $Request.root = $script:LibraryRoot
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($Request | ConvertTo-Json -Depth 10 -Compress))
    $operation = if ($Request.command -in @('list', 'discover', 'history', 'inspect', 'capture', 'import', 'rename', 'summaries', 'delete', 'export', 'read')) { $Request.command } else { 'unknown' }
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $script:NodePath
    $start.Arguments = '"' + (Join-Path $PSScriptRoot 'native\library-cli.js') + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $state = @{
        Process = $null; Input = $null; InputClosed = $false; Cancelled = $false
        Operation = $operation; Clock = [Diagnostics.Stopwatch]::StartNew()
    }
    try {
        $state.Process = [System.Diagnostics.Process]::Start($start)
        if (-not $state.Process) { throw 'The demo library helper could not start.' }
        # Do not block the dispatcher (or the watchdog) on a helper that is not reading stdin.
        $state.Input = $state.Process.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
        return $state
    } catch {
        if ($state.Process) { Stop-DemoLibraryProcess $state } else { $state.Clock.Stop() }
        throw
    }
}

function Complete-DemoLibraryInput($State) {
    if (-not $State.InputClosed -and $State.Input.IsCompleted) {
        $State.Input.GetAwaiter().GetResult()
        $State.Process.StandardInput.BaseStream.Close()
        $State.InputClosed = $true
    }
}

function Stop-DemoLibraryProcess($State) {
    try {
        if (-not $State.Process.HasExited) { $State.Process.Kill() }
        if (-not $State.Process.WaitForExit(2000)) { throw 'The demo library helper did not exit after it was stopped.' }
    } finally {
        try {
            $State.Process.StandardInput.BaseStream.Dispose()
            $State.Process.StandardOutput.Dispose()
            $State.Process.StandardError.Dispose()
        } finally { $State.Process.Dispose(); $State.Clock.Stop() }
    }
}

function Invoke-DemoLibrary([hashtable]$Request, $Owner) {
    $state = Start-DemoLibraryProcess $Request
    $process = $state.Process
    $timer = $null
    $onTick = $null
    $onClosed = $null
    $ownerStateSaved = $false
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if ($Owner) {
            $enabled = $Owner.IsEnabled
            $cursor = $Owner.Cursor
            $ownerStateSaved = $true
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $completeInput = ${function:Complete-DemoLibraryInput}
            $onTick = {
                try {
                    & $completeInput $state
                    if ($state.Process.HasExited -or $state.Clock.ElapsedMilliseconds -ge 30000) { $frame.Continue = $false }
                } catch { $state.Failure = $_; $frame.Continue = $false }
            }.GetNewClosure()
            $onClosed = { $state.Cancelled = $true; $frame.Continue = $false }.GetNewClosure()
            $timer.Add_Tick($onTick)
            $Owner.Add_Closed($onClosed)
            $Owner.IsEnabled = $false
            $Owner.Cursor = [System.Windows.Input.Cursors]::Wait
            $timer.Start()
            [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        } else {
            do {
                Complete-DemoLibraryInput $state
                if ($process.HasExited) { break }
                $process.WaitForExit(50) | Out-Null
            } while ($state.Clock.ElapsedMilliseconds -lt 30000)
        }
        if ($state.Cancelled) {
            throw ("The demo library operation '" + $state.Operation + "' was cancelled because its window closed. No success was confirmed. Refresh the library before retrying.")
        }
        if ($state.Failure) { throw $state.Failure }
        if (-not $process.HasExited) {
            $phase = if ($state.InputClosed) { 'waiting for helper exit' } else { 'sending the request' }
            throw ("The demo library operation '" + $state.Operation + "' exceeded 30 seconds while " + $phase + '. No success was confirmed. Refresh the library before retrying.')
        }
        Complete-DemoLibraryInput $state
        if (-not $state.InputClosed) { throw 'The demo library helper exited before the request was sent. No success was confirmed.' }
        if (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($output, $errors), 2000)) { throw 'Timed out reading the library helper output.' }
        $text = $output.GetAwaiter().GetResult()
        if (-not $text) { throw ('The demo library helper returned no result. ' + $errors.GetAwaiter().GetResult()) }
        $response = ConvertFrom-Json -InputObject $text
        if (-not $response.ok -or $process.ExitCode -ne 0) { throw $response.error }
        return $response.result
    } finally {
        if ($timer) { $timer.Stop(); $timer.Remove_Tick($onTick) }
        if ($onClosed) { $Owner.Remove_Closed($onClosed) }
        try { Stop-DemoLibraryProcess $state }
        finally {
            if ($ownerStateSaved) { $Owner.IsEnabled = $enabled; $Owner.Cursor = $cursor }
        }
    }
}

function New-DemoDialog([string]$Xaml, $Owner) {
    $reader = [System.Xml.XmlNodeReader]::new([xml]$Xaml)
    try { $dialog = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
    $dialog.Owner = $Owner
    return $dialog
}

function Show-DemoError($Owner, $Failure) {
    [System.Windows.MessageBox]::Show($Owner, $Failure.Exception.Message, 'Demo Player', 'OK', 'Error') | Out-Null
}

function Select-DemoFile($Owner, [string]$Filter) {
    $picker = [Microsoft.Win32.OpenFileDialog]::new()
    $picker.Filter = $Filter
    if ($picker.ShowDialog($Owner)) { return $picker.FileName }
    return $null
}

function Select-DemoFolder($Owner) {
    Add-Type -AssemblyName System.Windows.Forms
    $picker = [System.Windows.Forms.FolderBrowserDialog]::new()
    $picker.Description = 'Select a VS Code user-data/profile folder, workspaceStorage, agentSessionData, SDK session-state, or a directory of JSONL transcripts.'
    $picker.ShowNewFolderButton = $false
    $nativeOwner = [System.Windows.Forms.NativeWindow]::new()
    try {
        $nativeOwner.AssignHandle(([System.Windows.Interop.WindowInteropHelper]::new($Owner)).Handle)
        if ($picker.ShowDialog($nativeOwner) -eq [System.Windows.Forms.DialogResult]::OK) { return $picker.SelectedPath }
        return $null
    } finally { $nativeOwner.ReleaseHandle(); $picker.Dispose() }
}

function Test-DemoHistoryRow($Row, [string]$Search, [string]$Project, [string]$Agent, [string]$Source, [string]$Status, $From, $To, $MinPrompts, $MinDuration) {
    if ($Search -and ($Row.Title + ' ' + $Row.Project + ' ' + $Row.ProjectPath + ' ' + $Row.Agent + ' ' + $Row.Source).IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    foreach ($pair in @(@($Project, $Row.ProjectKey), @($Agent, $Row.AgentKey), @($Source, $Row.Source), @($Status, $Row.Status))) {
        if ($pair[0] -and $pair[0] -ne '*' -and $pair[0] -ne $pair[1]) { return $false }
    }
    if ($From -and (-not $Row.LastActivity -or $Row.LastActivity.Date -lt $From.Date)) { return $false }
    if ($To -and (-not $Row.LastActivity -or $Row.LastActivity.Date -gt $To.Date)) { return $false }
    if ($null -ne $MinPrompts -and ($null -eq $Row.Prompts -or $Row.Prompts -lt $MinPrompts)) { return $false }
    if ($null -ne $MinDuration -and ($null -eq $Row.DurationSeconds -or $Row.DurationSeconds -lt $MinDuration)) { return $false }
    return $true
}

function Get-DemoTurnLabel($Turn) {
    $prompt = [string]$Turn.prompt
    if ($prompt.Length -gt 160) { $prompt = $prompt.Substring(0,160) + '...' }
    $label = ($Turn.index + 1).ToString() + '. ' + ($prompt -replace '\s+', ' ')
    if ($Turn.error) { return '[Unavailable] ' + $label }
    if ($Turn.status -eq 'archived-edits') { return '[Read-only edits] ' + $label }
    if ($Turn.status -eq 'archived-events') { return '[Read-only events] ' + $label }
    return $label
}

function Select-DemoAvailableTurns($Turns) {
    $Turns.UnselectAll()
    foreach ($item in $Turns.Items) {
        if (-not $item.Turn.error) { $Turns.SelectedItems.Add($item) | Out-Null }
    }
}

function Get-DemoSelectionPreview([object[]]$Items, [bool]$RawPayload) {
    $text = [Text.StringBuilder]::new()
    $truncated = $false
    foreach ($item in @($Items | Sort-Object { $_.Turn.index })) {
        $turn = $item.Turn
        $header = 'EXCHANGE ' + ($turn.index + 1) + "`r`n"
        if ($turn.error) { $header += 'UNAVAILABLE: ' + $turn.error + "`r`n" }
        if ($RawPayload) { $header += "FULL SAVED PAYLOAD (includes prompt, response, tools, and metadata):`r`n" }
        $content = if ($RawPayload) { [string]$turn.details } else { [string]$turn.content }
        foreach ($part in @($header, $content, "`r`n`r`n----------------`r`n`r`n")) {
            $remaining = 32512 - $text.Length
            if ($part.Length -gt $remaining) {
                [void]$text.Append($part, 0, $remaining)
                $truncated = $true
                break
            }
            [void]$text.Append($part)
        }
        if ($truncated) { break }
    }
    if ($truncated) {
        [void]$text.Append("`r`n[Preview limited to 32 KiB of text for responsiveness. Select fewer exchanges to review them separately; inspect the source file for oversized content. Captured content is not truncated.]")
    }
    return $text.ToString()
}

function Show-InteractionPicker($Owner) {
    $dialog = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Find interaction"
 Width="1180" Height="820" MinWidth="850" MinHeight="620" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
 <TabControl x:Name="PickerTabs" Margin="12" SelectedIndex="0">
 <TabItem Header="Agent conversations" AutomationProperties.AutomationId="AgentConversationsTab">
 <Grid Margin="8">
  <Grid.RowDefinitions>
   <RowDefinition Height="Auto"/><RowDefinition Height="2*" MinHeight="90"/><RowDefinition Height="Auto"/>
   <RowDefinition Height="3*" MinHeight="120"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <StackPanel Margin="0,0,0,8">
  <DockPanel>
   <Button x:Name="Browse" DockPanel.Dock="Right" Content="Browse transcript..." Padding="10,5"/>
   <Button x:Name="AddLocation" DockPanel.Dock="Right" Content="Add history location..." Padding="10,5" Margin="6,0" AutomationProperties.AutomationId="CaptureAddLocation"/>
   <Button x:Name="Refresh" DockPanel.Dock="Right" Content="Refresh history" Padding="10,5" AutomationProperties.AutomationId="CaptureRefresh"/>
   <TextBlock x:Name="DiscoveryNote" Text="Discovering local conversations..." TextWrapping="Wrap" Margin="0,0,12,0" AutomationProperties.AutomationId="CaptureDiscoveryNote"/>
  </DockPanel>
  <WrapPanel Margin="0,7,0,0">
   <TextBlock Text="Search" VerticalAlignment="Center" Margin="0,0,6,0"/>
   <TextBox x:Name="HistorySearch" Width="240" Margin="0,0,10,0" ToolTip="Filter titles, projects, agents and sources. Does not rescan disk." AutomationProperties.AutomationId="CaptureHistorySearch"/>
   <TextBlock Text="Project" VerticalAlignment="Center" Margin="0,0,6,0"/>
   <ComboBox x:Name="ProjectFilter" Width="190" DisplayMemberPath="Label" Margin="0,0,10,0" AutomationProperties.AutomationId="CaptureProjectFilter"/>
   <TextBlock Text="Agent" VerticalAlignment="Center" Margin="0,0,6,0"/>
   <ComboBox x:Name="AgentFilter" Width="150" DisplayMemberPath="Label" Margin="0,0,10,0" AutomationProperties.AutomationId="CaptureAgentFilter"/>
   <Button x:Name="ClearFilters" Content="Clear filters" Padding="8,2" AutomationProperties.AutomationId="CaptureClearFilters"/>
  </WrapPanel>
  <Expander x:Name="MoreFilters" Header="More filters: activity, source, status, prompt count and duration" Margin="0,7,0,0" AutomationProperties.AutomationId="MoreFilters">
  <WrapPanel Margin="0,5,0,0">
   <TextBlock Text="Activity from" VerticalAlignment="Center" Margin="0,0,5,0"/>
   <DatePicker x:Name="DateFrom" Width="120" Margin="0,0,7,0" AutomationProperties.AutomationId="CaptureDateFrom"/>
   <TextBlock Text="to" VerticalAlignment="Center" Margin="0,0,5,0"/>
   <DatePicker x:Name="DateTo" Width="120" Margin="0,0,10,0" AutomationProperties.AutomationId="CaptureDateTo"/>
   <ComboBox x:Name="SourceFilter" Width="140" DisplayMemberPath="Label" Margin="0,0,7,0" AutomationProperties.AutomationId="CaptureSourceFilter"/>
   <ComboBox x:Name="StatusFilter" Width="150" DisplayMemberPath="Label" Margin="0,0,10,0" AutomationProperties.AutomationId="CaptureStatusFilter"/>
   <TextBlock Text="Min prompts" VerticalAlignment="Center" Margin="0,0,5,0"/>
   <TextBox x:Name="MinPrompts" Width="45" Margin="0,0,8,0" AutomationProperties.AutomationId="CaptureMinPrompts"/>
   <TextBlock Text="Min duration (s)" VerticalAlignment="Center" Margin="0,0,5,0"/>
   <TextBox x:Name="MinDuration" Width="60" AutomationProperties.AutomationId="CaptureMinDuration"/>
  </WrapPanel>
  </Expander>
  <DockPanel Margin="0,5,0,0">
   <Button x:Name="Details" Content="Discovery details" DockPanel.Dock="Right" Padding="6,1"/>
   <TextBlock x:Name="HistoryCount" Text="Click column headers to sort. Duration is recorded activity span, not working time." TextWrapping="Wrap"/>
  </DockPanel>
  </StackPanel>
  <DataGrid x:Name="Sessions" Grid.Row="1" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" CanUserDeleteRows="False"
   SelectionMode="Single" SelectionUnit="FullRow" EnableRowVirtualization="True" EnableColumnVirtualization="True" AutomationProperties.AutomationId="CaptureSessions">
   <DataGrid.RowStyle><Style TargetType="DataGridRow"><Setter Property="ToolTip" Value="{Binding Detail}"/></Style></DataGrid.RowStyle>
   <DataGrid.Columns>
    <DataGridTextColumn Header="Conversation" Binding="{Binding Title}" Width="180"/>
    <DataGridTextColumn Header="Project / workspace" Binding="{Binding Project}" SortMemberPath="Project" Width="135"/>
    <DataGridTextColumn Header="Agent / producer" Binding="{Binding Agent, TargetNullValue=Not recorded}" Width="110"/>
    <DataGridTextColumn Header="Last activity" Binding="{Binding LastActivity, StringFormat=yyyy-MM-dd HH:mm:ss, TargetNullValue=Not recorded}" Width="140"/>
    <DataGridTextColumn Header="Started" Binding="{Binding Started, StringFormat=yyyy-MM-dd HH:mm:ss, TargetNullValue=Not recorded}" Width="140"/>
    <DataGridTextColumn Header="Prompts" Binding="{Binding Prompts, TargetNullValue=Not indexed}" Width="65"/>
    <DataGridTextColumn Header="Duration" Binding="{Binding Duration, TargetNullValue=Not recorded}" SortMemberPath="DurationSeconds" Width="80"/>
    <DataGridTextColumn Header="Source" Binding="{Binding Source}" Width="110"/>
    <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="130"/>
   </DataGrid.Columns>
  </DataGrid>
  <DockPanel Grid.Row="2" Margin="0,10,0,6">
   <Button x:Name="Load" Content="Load conversation" DockPanel.Dock="Right" Padding="12,5"/>
   <TextBox x:Name="Source" ToolTip="Select a conversation or browse/paste a saved JSONL transcript. Source files are never modified." Margin="0,0,12,0" VerticalContentAlignment="Center" AutomationProperties.AutomationId="CaptureSource"/>
  </DockPanel>
  <Grid Grid.Row="3">
   <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
   <Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="3*"/></Grid.ColumnDefinitions>
   <StackPanel Margin="0,0,0,4">
    <TextBlock x:Name="SelectionCount" VerticalAlignment="Center" AutomationProperties.AutomationId="CaptureSelectionCount"/>
    <WrapPanel Margin="0,4,0,0">
     <Button x:Name="SelectAll" Content="Select all (Ctrl+A)" Padding="8,2" AutomationProperties.AutomationId="CaptureSelectAll"/>
     <Button x:Name="SelectAvailable" Content="Select available" Padding="8,2" Margin="6,0,0,0" AutomationProperties.AutomationId="CaptureSelectAvailable"/>
     <Button x:Name="ClearSelection" Content="Clear selection" Padding="8,2" Margin="6,0,0,0" AutomationProperties.AutomationId="CaptureClearSelection"/>
    </WrapPanel>
   </StackPanel>
   <ListBox x:Name="Turns" Grid.Row="1" SelectionMode="Extended" DisplayMemberPath="Label" AutomationProperties.AutomationId="CaptureTurns"
    VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling"
    ScrollViewer.CanContentScroll="True" ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
   <TextBox x:Name="Preview" Grid.Column="1" Grid.RowSpan="2" Margin="12,0,0,0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AutomationProperties.AutomationId="CapturePreview"/>
  </Grid>
  <StackPanel Grid.Row="4" Margin="0,8,0,0">
   <CheckBox x:Name="RawPayload" Content="Show full saved payload (tools and metadata)" Margin="0,0,0,6" AutomationProperties.AutomationId="CaptureRawPayload"/>
   <TextBlock Text="1. Find a conversation. 2. Load and select up to 100 exchanges. 3. Review or summarize prompts. 4. Use for playback. Selections are saved locally for reuse; originals are never changed." TextWrapping="Wrap"/>
   <Expander Header="Selection name (optional)" Margin="0,5,0,8">
    <TextBox x:Name="Title" MaxLength="160" AutomationProperties.AutomationId="CaptureTitle"/>
   </Expander>
   <CheckBox x:Name="Reviewed" Content="I reviewed the selected content for secrets. External assets are not bundled; playback uses saved payloads only." AutomationProperties.AutomationId="CaptureReviewed"/>
  </StackPanel>
  <StackPanel Grid.Row="5" Margin="0,12,0,0">
   <TextBlock x:Name="CaptureStatus" TextWrapping="Wrap" Margin="0,0,0,8"/>
   <WrapPanel HorizontalAlignment="Right">
    <Button x:Name="SelectionSummaries" Content="Review / edit summaries..." IsEnabled="False" Padding="10,6" Margin="0,0,8,0" AutomationProperties.AutomationId="SelectionSummaries"/>
    <Button x:Name="SelectionAiSummaries" Content="Summarize long prompts with AI..." IsEnabled="False" Padding="10,6" Margin="0,0,8,0" AutomationProperties.AutomationId="SelectionAiSummaries"/>
    <Button x:Name="SelectionClearSummaries" Content="Clear all summaries..." IsEnabled="False" Padding="10,6" Margin="0,0,8,0" AutomationProperties.AutomationId="SelectionClearSummaries"/>
    <Button x:Name="Save" Content="Use selected exchanges" IsEnabled="False" Padding="18,6" AutomationProperties.AutomationId="SaveDemo"/>
   </WrapPanel>
  </StackPanel>
 </Grid>
 </TabItem>
 <TabItem Header="Saved selections" AutomationProperties.AutomationId="SavedSelectionsTab">
 <Grid Margin="12">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="100"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <DockPanel Margin="0,0,0,10">
   <Button x:Name="SavedRefresh" Content="Refresh" DockPanel.Dock="Right" Padding="12,6" Margin="8,0,0,0" AutomationProperties.AutomationId="RefreshDemos"/>
   <TextBlock Text="Search saved selections" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,8,0"/>
   <TextBox x:Name="SavedSearch" ToolTip="Search titles, sources, and opening prompts" VerticalContentAlignment="Center" AutomationProperties.AutomationId="DemoSearch"/>
  </DockPanel>
  <ListBox x:Name="Demos" Grid.Row="1" DisplayMemberPath="Label" AutomationProperties.AutomationId="DemoList"/>
  <TextBox x:Name="SavedPreview" Grid.Row="2" Margin="0,8,0,8" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
  <Expander x:Name="SavedActions" Grid.Row="3" Header="Selection actions: rename, import, export, remove" Margin="0,0,0,10" AutomationProperties.AutomationId="SavedActions">
   <StackPanel>
    <DockPanel Margin="0,8">
     <Button x:Name="Rename" Content="Rename" DockPanel.Dock="Right" Padding="12,5" Margin="8,0,0,0"/>
     <TextBox x:Name="SavedTitle" MaxLength="160" ToolTip="Edit the selected title"/>
    </DockPanel>
    <StackPanel Orientation="Horizontal">
     <Button x:Name="Import" Content="Import recording..." Padding="12,6"/>
     <Button x:Name="Export" Content="Export..." Padding="12,6" Margin="8,0,0,0"/>
     <Button x:Name="Delete" Content="Remove saved selection" Padding="12,6" Margin="8,0,0,0"/>
    </StackPanel>
   </StackPanel>
  </Expander>
  <StackPanel Grid.Row="4">
   <WrapPanel Margin="0,0,0,8">
    <Button x:Name="Summaries" Content="Review / edit summaries..." Padding="12,6" AutomationProperties.AutomationId="EditPromptSummaries"/>
    <Button x:Name="AiSummaries" Content="Summarize long prompts with AI..." Padding="12,6" Margin="8,0,0,0" AutomationProperties.AutomationId="AiPromptSummaries"/>
    <Button x:Name="ClearSummaries" Content="Clear all summaries..." Padding="12,6" Margin="8,0,0,0" AutomationProperties.AutomationId="ClearPromptSummaries"/>
   </WrapPanel>
   <DockPanel>
    <Button x:Name="Select" Content="Use saved selection" DockPanel.Dock="Right" Padding="18,6" AutomationProperties.AutomationId="SelectDemo"/>
    <TextBlock x:Name="Count" VerticalAlignment="Center" Margin="12,0"/>
   </DockPanel>
  </StackPanel>
 </Grid>
 </TabItem>
 </TabControl>
</Window>
'@ $Owner
    $dialog.Width = [Math]::Min($dialog.Width, [System.Windows.SystemParameters]::WorkArea.Width - 24)
    $dialog.Height = [Math]::Min($dialog.Height, [System.Windows.SystemParameters]::WorkArea.Height - 24)
    $dialog.Tag = @{
        File = $null; Inspection = $null; Result = $null; Scan = $null; Locations = @()
        PreparedKey = $null; PreparedEntry = $null; Entries = @()
        Rows = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
        Warnings = [System.Collections.Generic.List[string]]::new()
        UpdatingFilters = $false; FilterError = ''; Filters = @{}; UpdatingTurns = $false
    }
    $sessions = $dialog.FindName('Sessions')
    $turns = $dialog.FindName('Turns')
    $preview = $dialog.FindName('Preview')
    $title = $dialog.FindName('Title')
    $reviewed = $dialog.FindName('Reviewed')
    $captureStatus = $dialog.FindName('CaptureStatus')
    $sourceBox = $dialog.FindName('Source')
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($dialog.Tag.Rows)
    $sessions.ItemsSource = $dialog.Tag.Rows
    $view.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('LastActivity', [System.ComponentModel.ListSortDirection]::Descending))
    $view.Filter = [Predicate[object]]{
        param($row)
        $f = $dialog.Tag.Filters
        if ($dialog.Tag.FilterError) { return $false }
        return Test-DemoHistoryRow $row $f.Search $f.Project $f.Agent $f.Source $f.Status $f.From $f.To $f.MinPrompts $f.MinDuration
    }
    $updateCount = {
        $dialog.FindName('HistoryCount').Text = if ($dialog.Tag.FilterError) { $dialog.Tag.FilterError } else {
            $sessions.Items.Count.ToString() + ' of ' + $dialog.Tag.Rows.Count + ' conversations. Click headers to sort; duration is recorded activity span.'
        }
    }
    $applyFilters = {
        if ($dialog.Tag.UpdatingFilters) { return }
        $f = @{
            Search = $dialog.FindName('HistorySearch').Text
            Project = $dialog.FindName('ProjectFilter').SelectedItem.Value
            Agent = $dialog.FindName('AgentFilter').SelectedItem.Value
            Source = $dialog.FindName('SourceFilter').SelectedItem.Value
            Status = $dialog.FindName('StatusFilter').SelectedItem.Value
            From = $dialog.FindName('DateFrom').SelectedDate
            To = $dialog.FindName('DateTo').SelectedDate
            MinPrompts = $null; MinDuration = $null
        }
        $dialog.Tag.FilterError = ''
        if ($f.From -and $f.To -and $f.From -gt $f.To) { $dialog.Tag.FilterError = 'The activity start date must not be after the end date.' }
        foreach ($name in @('MinPrompts', 'MinDuration')) {
            $text = $dialog.FindName($name).Text
            if ($text) {
                $number = 0
                if (-not [int]::TryParse($text, [ref]$number) -or $number -lt 0) {
                    $dialog.Tag.FilterError = 'Minimum prompts and duration must be nonnegative whole numbers.'
                } else { $f[$name] = $number }
            }
        }
        $dialog.Tag.Filters = $f
        $view.Refresh()
        & $updateCount
    }
    $fillFilters = {
        $dialog.Tag.UpdatingFilters = $true
        try {
            foreach ($spec in @(
                @('ProjectFilter', 'ProjectKey', 'All projects'),
                @('AgentFilter', 'AgentKey', 'All agents'),
                @('SourceFilter', 'Source', 'All sources'),
                @('StatusFilter', 'Status', 'All statuses')
            )) {
                $control = $dialog.FindName($spec[0])
                $previous = $control.SelectedItem.Value
                $control.Items.Clear()
                $control.Items.Add([pscustomobject]@{ Label = $spec[2]; Value = '*' }) | Out-Null
                foreach ($value in @($dialog.Tag.Rows | ForEach-Object { $_.($spec[1]) } | Sort-Object -Unique)) {
                    $label = if ($value -eq '<no workspace>') { 'No workspace' } elseif ($value -eq '<not recorded>') { 'Not recorded' } else { $value }
                    $control.Items.Add([pscustomobject]@{ Label = $label; Value = $value }) | Out-Null
                }
                $selected = @($control.Items | Where-Object { $_.Value -eq $previous })
                $control.SelectedItem = if ($selected.Count) { $selected[0] } else { $control.Items[0] }
            }
        } finally { $dialog.Tag.UpdatingFilters = $false }
        & $applyFilters
    }
    foreach ($name in @('HistorySearch', 'MinPrompts', 'MinDuration')) { $dialog.FindName($name).Add_TextChanged($applyFilters) }
    foreach ($name in @('ProjectFilter', 'AgentFilter', 'SourceFilter', 'StatusFilter')) { $dialog.FindName($name).Add_SelectionChanged($applyFilters) }
    foreach ($name in @('DateFrom', 'DateTo')) { $dialog.FindName($name).Add_SelectedDateChanged($applyFilters) }
    foreach ($name in @('DateFrom', 'DateTo')) {
        $dialog.FindName($name).Add_DateValidationError({
            param($sender, $args)
            $args.ThrowException = $false
            $dialog.Tag.FilterError = 'Enter a valid activity date or clear the date field.'
            $view.Refresh()
            & $updateCount
        })
    }
    $dialog.FindName('ClearFilters').Add_Click({
        $dialog.Tag.UpdatingFilters = $true
        try {
            foreach ($name in @('HistorySearch', 'MinPrompts', 'MinDuration')) { $dialog.FindName($name).Text = '' }
            foreach ($name in @('ProjectFilter', 'AgentFilter', 'SourceFilter', 'StatusFilter')) { $dialog.FindName($name).SelectedIndex = 0 }
            foreach ($name in @('DateFrom', 'DateTo')) { $dialog.FindName($name).SelectedDate = $null }
        } finally { $dialog.Tag.UpdatingFilters = $false }
        & $applyFilters
    })
    $scanTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $scanTimer.Interval = [TimeSpan]::FromMilliseconds(50)
    $stopScan = {
        param([bool]$Cancel)
        $scanTimer.Stop()
        $scan = $dialog.Tag.Scan
        if ($scan) {
            try { Stop-DemoLibraryProcess $scan }
            finally { $dialog.Tag.Scan = $null }
        }
        foreach ($name in @('Refresh', 'AddLocation', 'Load', 'Browse')) { $dialog.FindName($name).IsEnabled = $true }
    }
    $startScan = {
        if ($dialog.Tag.Scan) { return }
        try {
            $scan = Start-DemoLibraryProcess @{ command = 'history'; locations = @($dialog.Tag.Locations); progress = $true }
            $dialog.Tag.Scan = $scan
            $scan.Line = $scan.Process.StandardOutput.ReadLineAsync()
            $scan.Errors = $scan.Process.StandardError.ReadToEndAsync()
            $scan.Result = $null
            $scan.End = $false
            $dialog.Tag.Rows.Clear()
            $dialog.Tag.Warnings.Clear()
            foreach ($name in @('Refresh', 'AddLocation', 'Load', 'Browse')) { $dialog.FindName($name).IsEnabled = $false }
            $dialog.FindName('DiscoveryNote').Text = 'Discovering known local history stores (no whole-drive search)...'
            & $updateCount
            $scanTimer.Start()
        } catch {
            & $stopScan $true
            $dialog.FindName('DiscoveryNote').Text = 'Discovery failed: ' + $_.Exception.Message
        }
    }
    $scanTimer.Add_Tick({
        try {
            $scan = $dialog.Tag.Scan
            if (-not $scan) { return }
            if ($scan.Clock.Elapsed.TotalSeconds -ge 60) { throw 'History discovery exceeded 60 seconds. Partial rows remain visible; refresh to retry.' }
            Complete-DemoLibraryInput $scan
            for ($read = 0; $read -lt 50 -and -not $scan.End -and $scan.Line.IsCompleted; $read++) {
                $line = $scan.Line.GetAwaiter().GetResult()
                if ($null -eq $line) { $scan.End = $true; break }
                $message = ConvertFrom-Json -InputObject $line
                if ($message.progress) {
                    $event = $message.progress
                    if ($event.phase -eq 'warning') { $dialog.Tag.Warnings.Add($event.message) }
                    elseif ($event.phase -eq 'entry') {
                        $entry = $event.session
                        $started = if ($entry.started) { ([datetimeoffset]$entry.started).LocalDateTime } else { $null }
                        $last = if ($entry.lastActivity) { ([datetimeoffset]$entry.lastActivity).LocalDateTime } else { $null }
                        $duration = if ($null -ne $entry.durationSeconds) { [TimeSpan]::FromSeconds($entry.durationSeconds).ToString('g') } else { $null }
                        $dialog.Tag.Rows.Add([pscustomobject]@{
                            Title = $entry.title; Project = $entry.project; ProjectPath = $entry.projectPath
                            ProjectKey = if ($entry.projectPath) { $entry.projectPath } else { '<no workspace>' }
                            Agent = $entry.agent; AgentKey = if ($entry.agent) { $entry.agent } else { '<not recorded>' }
                            Started = $started; LastActivity = $last; DurationSeconds = $entry.durationSeconds; Duration = $duration
                            Prompts = $entry.promptCount; Source = $entry.source; Status = $entry.status
                            Detail = $entry.title + "`n" + $entry.detail + "`n" + $entry.projectPath + "`n" + $entry.file
                            File = $entry.file; Loadable = $entry.loadable
                        })
                    } elseif ($event.message) { $dialog.FindName('DiscoveryNote').Text = $event.message }
                } elseif ($message.ok) { $scan.Result = $message.result }
                else { throw $message.error }
                $scan.Line = $scan.Process.StandardOutput.ReadLineAsync()
            }
            & $updateCount
            if ($scan.End -and $scan.Process.HasExited -and $scan.Errors.IsCompleted) {
                if ($scan.Process.ExitCode -ne 0 -or -not $scan.Result) { throw ('History helper returned no successful result. ' + $scan.Errors.GetAwaiter().GetResult()) }
                $dialog.FindName('DiscoveryNote').Text = $scan.Result.notice
                & $stopScan $false
                & $fillFilters
            }
        } catch {
            $failure = $_.Exception.Message
            & $stopScan $true
            $dialog.Tag.Warnings.Add($failure)
            $dialog.FindName('DiscoveryNote').Text = 'Discovery failed: ' + $failure
            & $fillFilters
        }
    })
    $dialog.FindName('Refresh').Add_Click($startScan)
    $dialog.FindName('AddLocation').Add_Click({
        try {
            $folder = Select-DemoFolder $dialog
            if ($folder -and $folder -notin $dialog.Tag.Locations) { $dialog.Tag.Locations += $folder; & $startScan }
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Details').Add_Click({
        $reviewed.IsChecked = $false
        $preview.Text = "History discovery uses known VS Code, Insiders, profile, agent and SDK/CLI stores. No whole-drive crawl.`r`n" +
            "Metadata indexing is limited to 8 MiB per recording, 256 MiB total and 10,000 recordings per refresh. Larger sources remain listed for Load.`r`n" +
            "Additional locations (this dialog):`r`n" + ($dialog.Tag.Locations -join "`r`n") +
            "`r`nWarnings:`r`n" + ($dialog.Tag.Warnings -join "`r`n")
    })
    $dialog.Add_ContentRendered($startScan)
    $dialog.Add_Closed({ & $stopScan $true })
    & $fillFilters
    $sourceBox.Add_TextChanged({
        if ($sourceBox.Text -ne $dialog.Tag.File) {
            $dialog.Tag.Inspection = $null
            $turns.ItemsSource = $null
            $preview.Text = ''
            $reviewed.IsChecked = $false
            $captureStatus.Text = 'Load this conversation to preview and select exchanges.'
        }
    })
    $sessions.Add_SelectionChanged({
        if ($sessions.SelectedItem) {
            $sourceBox.Text = $sessions.SelectedItem.File
            $captureStatus.Text = $sessions.SelectedItem.Detail
        }
    })
    $loadSource = {
        param([string]$File)
        $captureStatus.Text = 'Loading the saved conversation...'
        $inspection = Invoke-DemoLibrary @{ command = 'inspect'; file = $File } $dialog
        $dialog.Tag.File = $File
        $dialog.Tag.Inspection = $inspection
        $dialog.FindName('Source').Text = $File
        $dialog.Tag.UpdatingTurns = $true
        try {
            $turns.ItemsSource = @($inspection.turns | ForEach-Object {
                [pscustomobject]@{ Label = Get-DemoTurnLabel $_; Turn = $_ }
            })
            Select-DemoAvailableTurns $turns
        } finally { $dialog.Tag.UpdatingTurns = $false }
        $displayTitle = if ($sessions.SelectedItem -and $sessions.SelectedItem.File -eq $File) { $sessions.SelectedItem.Title } else { $inspection.title }
        if ([string]::IsNullOrWhiteSpace($displayTitle)) { $displayTitle = 'Agent interaction' }
        $dialog.Tag.DefaultTitle = $displayTitle
        $title.Text = if ($displayTitle.Length -gt 160) { $displayTitle.Substring(0,160) } else { $displayTitle }
        $reviewed.IsChecked = $false
        & $updatePreview
    }
    $dialog.FindName('Load').Add_Click({
        try {
            if (-not $sourceBox.Text) { throw 'Select a saved session, paste a file path, or use Browse.' }
            if ($sessions.SelectedItem -and $sessions.SelectedItem.File -eq $sourceBox.Text -and -not $sessions.SelectedItem.Loadable) {
                throw $sessions.SelectedItem.Detail
            }
            & $loadSource $sourceBox.Text
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Browse').Add_Click({
        try {
            $file = Select-DemoFile $dialog 'Saved VS Code or Copilot SDK transcripts (*.jsonl)|*.jsonl'
            if ($file) { & $loadSource $file }
        } catch { Show-DemoError $dialog $_ }
    })
    $updateSaveState = {
        $unavailable = @($turns.SelectedItems | Where-Object { $_.Turn.error })
        $dialog.FindName('Save').IsEnabled = (
            $null -ne $dialog.Tag.Inspection -and
            $turns.SelectedItems.Count -ge 1 -and $turns.SelectedItems.Count -le 100 -and
            $unavailable.Count -eq 0 -and $reviewed.IsEnabled -and $reviewed.IsChecked -eq $true
        )
        foreach ($name in @('SelectionSummaries', 'SelectionAiSummaries', 'SelectionClearSummaries')) {
            $dialog.FindName($name).IsEnabled = $dialog.FindName('Save').IsEnabled
        }
    }
    $reviewed.Add_Checked($updateSaveState)
    $reviewed.Add_Unchecked($updateSaveState)
    $title.Add_TextChanged($updateSaveState)
    $previewTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
    $previewTimer.Interval = [TimeSpan]::FromMilliseconds(75)
    $previewTimer.Add_Tick({
        $previewTimer.Stop()
        if ($dialog.Tag.Inspection) {
            $preview.Text = Get-DemoSelectionPreview @($turns.SelectedItems) ([bool]$dialog.FindName('RawPayload').IsChecked)
            $reviewed.IsEnabled = $turns.SelectedItems.Count -gt 0
            & $updateSaveState
        }
    })
    $dialog.Add_Closed({ $previewTimer.Stop() })
    $updatePreview = {
        if ($dialog.Tag.UpdatingTurns) { return }
        $reviewed.IsChecked = $false
        $reviewed.IsEnabled = $false
        $preview.Text = ''
        $dialog.FindName('SelectionCount').Text = $turns.SelectedItems.Count.ToString() + ' of ' + $turns.Items.Count + ' exchanges selected'
        $unavailable = @($turns.SelectedItems | Where-Object { $_.Turn.error })
        $sourceUnavailable = @($turns.Items | Where-Object { $_.Turn.error })
        $captureStatus.Text = if ($turns.SelectedItems.Count -gt 100) {
            'Playback supports at most 100 exchanges. Reduce the selection.'
        } elseif ($unavailable.Count) {
            $first = $unavailable[0].Turn
            $unavailable.Count.ToString() + ' selected exchanges cannot be used for playback. Use Select available. Exchange ' + ($first.index + 1) + ': ' + $first.error
        } elseif (-not $turns.SelectedItems.Count) {
            if (-not $turns.Items.Count) { 'This conversation has no saved exchanges.' }
            elseif ($sourceUnavailable.Count -eq $turns.Items.Count) { 'No available exchanges can be replayed from this saved conversation.' }
            else { 'Select 1 to 100 available exchanges.' }
        } else { 'Review the selected content, optionally summarize prompts, then Use selected exchanges.' }
        if ($sourceUnavailable.Count -and -not $unavailable.Count) {
            $first = $sourceUnavailable[0].Turn
            $captureStatus.Text += ' ' + $sourceUnavailable.Count + ' unavailable exchanges excluded; still visible for inspection. Exchange ' + ($first.index + 1) + ': ' + $first.error
        }
        & $updateSaveState
        $previewTimer.Stop()
        $previewTimer.Start()
    }
    $dialog.FindName('SelectAll').Add_Click({ $turns.SelectAll() })
    $dialog.FindName('SelectAvailable').Add_Click({
        $dialog.Tag.UpdatingTurns = $true
        try {
            Select-DemoAvailableTurns $turns
        } finally { $dialog.Tag.UpdatingTurns = $false }
        & $updatePreview
    })
    $dialog.FindName('ClearSelection').Add_Click({ $turns.UnselectAll() })
    $turns.Add_PreviewKeyDown({
        param($sender, $args)
        if ($args.Key -eq [System.Windows.Input.Key]::A -and
            ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            $sender.SelectAll()
            $args.Handled = $true
        }
    })
    $turns.Add_SelectionChanged($updatePreview)
    $dialog.FindName('RawPayload').Add_Checked($updatePreview)
    $dialog.FindName('RawPayload').Add_Unchecked($updatePreview)
    $prepareSelection = {
        if (-not $dialog.Tag.Inspection) { throw 'Load a conversation first.' }
        if (-not $reviewed.IsChecked) { throw 'Review the selected content and acknowledge the privacy and asset notice.' }
        $selected = @($turns.SelectedItems | Sort-Object { $_.Turn.index })
        if ($selected.Count -lt 1 -or $selected.Count -gt 100) { throw 'Select 1 to 100 exchanges.' }
        $unavailable = @($selected | Where-Object { $_.Turn.error })
        if ($unavailable.Count) {
            $first = $unavailable[0].Turn
            throw ('Use Select available to exclude ' + $unavailable.Count + ' unavailable exchanges. Exchange ' + ($first.index + 1) + ': ' + $first.error)
        }
        $indices = @($selected | ForEach-Object { [int]$_.Turn.index })
        $selectionTitle = if ([string]::IsNullOrWhiteSpace($title.Text)) { $dialog.Tag.DefaultTitle } else { $title.Text }
        if ($selectionTitle.Length -gt 160) { $selectionTitle = $selectionTitle.Substring(0,160) }
        $key = @($dialog.Tag.File, $dialog.Tag.Inspection.sha256, $selectionTitle, ($indices -join ',')) | ConvertTo-Json -Compress
        if ($dialog.Tag.PreparedKey -eq $key) {
            $current = Invoke-DemoLibrary @{ command = 'inspect'; file = $dialog.Tag.File } $dialog
            if ($current.sha256 -ne $dialog.Tag.Inspection.sha256) { throw 'The source changed. Reload and review it before continuing.' }
            return Invoke-DemoLibrary @{ command = 'read'; id = $dialog.Tag.PreparedEntry.id } $dialog
        }
        $entry = Invoke-DemoLibrary @{ command = 'capture'; file = $dialog.Tag.File; sha256 = $dialog.Tag.Inspection.sha256; title = $selectionTitle; indices = $indices } $dialog
        $dialog.Tag.PreparedKey = $key
        $dialog.Tag.PreparedEntry = $entry
        return $entry
    }
    $dialog.FindName('SelectionSummaries').Add_Click({
        try {
            $entry = & $prepareSelection
            Show-DemoSummaryDialog $dialog $entry.id | Out-Null
            & $refresh
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('SelectionAiSummaries').Add_Click({
        try {
            $entry = & $prepareSelection
            Show-DemoSummaryAuthoringNotice $dialog $entry.id
            & $refresh
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('SelectionClearSummaries').Add_Click({
        try {
            $entry = & $prepareSelection
            if (Show-DemoClearSummariesNotice $dialog $entry.id) { & $refresh }
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Save').Add_Click({
        try {
            $dialog.Tag.Result = & $prepareSelection
            $dialog.DialogResult = $true
        } catch { Show-DemoError $dialog $_ }
    })
    return Show-InteractionPickerWindow $dialog
}

function Start-DemoSummaryAuthoring([string]$Id, $Owner) {
    Invoke-DemoLibrary @{ command = 'read'; id = $Id } $Owner | Out-Null
    $code = Resolve-PlayerVSCode $script:CodePath
    $profile = Join-Path ([IO.Path]::GetTempPath()) ('historical-summary-authoring-' + [guid]::NewGuid().ToString('N'))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $code
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.Arguments = @(
        '--new-window', '--user-data-dir', ('"' + $profile + '"'),
        '--extensions-dir', ('"' + (Join-Path $profile 'extensions') + '"'),
        ('--extensionDevelopmentPath="' + (Join-Path $PSScriptRoot 'native') + '"'),
        '--enable-proposed-api=local.historical-transcript-replay',
        '--disable-workspace-trust', '--skip-welcome', '--skip-release-notes', '--disable-telemetry'
    ) -join ' '
    $start.EnvironmentVariables.Remove('ELECTRON_RUN_AS_NODE')
    foreach ($key in @($start.EnvironmentVariables.Keys)) {
        if ($key -like 'HISTORY_REPLAY_*') { $start.EnvironmentVariables.Remove($key) }
    }
    $start.EnvironmentVariables['HISTORY_REPLAY_SUMMARY_ENTRY'] = Join-Path $script:LibraryRoot ($Id + '.demo.json')
    $process = [Diagnostics.Process]::Start($start)
    if (-not $process) { throw 'The isolated VS Code summary authoring window could not start.' }
    $process.Dispose()
}

function Show-DemoSummaryDialog($Owner, [string]$Id) {
    $entry = Invoke-DemoLibrary @{ command = 'read'; id = $Id } $Owner
    $dialog = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Prompt Summaries"
 Width="760" Height="540" MinWidth="500" MinHeight="400" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
 <Grid Margin="16">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="100"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Text="Summaries change only the floating overlay. Playback keeps the complete original prompts. Blank uses the original excerpt. Summaries are included when exporting." TextWrapping="Wrap" Margin="0,0,0,12"/>
  <ComboBox x:Name="Exchange" Grid.Row="1" Margin="0,0,0,10" AutomationProperties.AutomationId="SummaryExchange"/>
  <TextBox x:Name="Original" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AutomationProperties.AutomationId="SummaryOriginal"/>
  <TextBlock Grid.Row="3" Text="Overlay summary (up to 300 characters, one line)" Margin="0,12,0,6"/>
  <TextBox x:Name="Summary" Grid.Row="4" MaxLength="300" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AutomationProperties.AutomationId="SummaryText"/>
  <WrapPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
   <Button x:Name="Clear" Content="Clear all summaries" Padding="16,6" Margin="0,0,8,0" AutomationProperties.AutomationId="ClearSummaryDrafts"/>
   <Button x:Name="DeleteSummary" Content="Delete this summary" Padding="16,6" Margin="0,0,8,0" AutomationProperties.AutomationId="DeletePromptSummary"/>
   <Button x:Name="Cancel" Content="Cancel" IsCancel="True" Padding="16,6" Margin="0,0,8,0"/>
   <Button x:Name="Save" Content="Save summaries" Padding="16,6" AutomationProperties.AutomationId="SaveSummaries"/>
  </WrapPanel>
 </Grid>
</Window>
'@ $Owner
    $drafts = [object[]]::new($entry.recording.turns.Count)
    if ($null -ne $entry.recording.promptSummaries) { $drafts = [object[]]$entry.recording.promptSummaries.Clone() }
    $dialog.Tag = @{ Summaries = $drafts; Index = -1 }
    $exchange = $dialog.FindName('Exchange')
    $summary = $dialog.FindName('Summary')
    for ($index = 0; $index -lt $entry.recording.turns.Count; $index++) {
        $exchange.Items.Add(('Exchange ' + ($index + 1))) | Out-Null
    }
    $storeDraft = {
        if ($dialog.Tag.Index -ge 0) {
            $dialog.Tag.Summaries[$dialog.Tag.Index] = if ([string]::IsNullOrWhiteSpace($summary.Text)) { $null } else { $summary.Text.Trim() }
        }
    }
    $exchange.Add_SelectionChanged({
        & $storeDraft
        $dialog.Tag.Index = $exchange.SelectedIndex
        if ($exchange.SelectedIndex -ge 0) {
            $dialog.FindName('Original').Text = $entry.recording.turns[$exchange.SelectedIndex].snapshot.requests[0].message.text
            $summary.Text = [string]$dialog.Tag.Summaries[$exchange.SelectedIndex]
        }
    })
    $exchange.SelectedIndex = 0
    $dialog.FindName('Clear').Add_Click({
        $dialog.Tag.Summaries = [object[]]::new($entry.recording.turns.Count)
        $summary.Text = ''
    })
    $dialog.FindName('DeleteSummary').Add_Click({ $summary.Text = '' })
    $dialog.FindName('Save').Add_Click({
        try {
            & $storeDraft
            Invoke-DemoLibrary @{ command = 'summaries'; id = $Id; summaries = @($dialog.Tag.Summaries); expected = $entry.recording.promptSummaries } $dialog | Out-Null
            $dialog.DialogResult = $true
        } catch { Show-DemoError $dialog $_ }
    })
    return $dialog.ShowDialog()
}

function Show-DemoSummaryAuthoringNotice($Owner, [string]$Id) {
    $answer = [System.Windows.MessageBox]::Show($Owner, 'Generate summaries for all unsummarized prompts longer than the 300-character summary budget in this selection. Short prompts and existing summaries are preserved. An isolated VS Code authoring window opens; enable an AI provider and sign in there if needed. One consent and model selection cover the batch, with one provider request per long prompt. After generation a review panel opens automatically: compare originals, edit, approve individually, delete only summaries, or approve all. Save the reviewed batch, return here to use the selection, and enable Show prompt summary in the controller. Playback keeps the full original prompts and never calls AI.', 'AI Prompt Summaries', 'OKCancel', 'Information')
    if ($answer -eq 'OK') { Start-DemoSummaryAuthoring $Id $Owner }
}

function Show-DemoClearSummariesNotice($Owner, [string]$Id) {
    $entry = Invoke-DemoLibrary @{ command = 'read'; id = $Id } $Owner
    $answer = [System.Windows.MessageBox]::Show($Owner, 'Clear all saved summaries for this selection, including AI-generated and manually edited summaries? Original prompts, responses and recordings are unchanged. The overlay will use the default prompt excerpts.', 'Clear Prompt Summaries', 'OKCancel', 'Question')
    if ($answer -ne 'OK') { return $false }
    Invoke-DemoLibrary @{ command = 'summaries'; id = $Id; summaries = @([object[]]::new($entry.recording.turns.Count)); expected = $entry.recording.promptSummaries } $Owner | Out-Null
    return $true
}

function Show-InteractionPickerWindow($dialog) {
    # Keep this scope alive while the shared picker dispatches both tab handlers.
    $list = $dialog.FindName('Demos')
    $search = $dialog.FindName('SavedSearch')
    $filter = {
        $selectedId = if ($list.SelectedItem) { $list.SelectedItem.Entry.id } else { $null }
        $list.Items.Clear()
        $needle = $search.Text
        foreach ($entry in $dialog.Tag.Entries) {
            if ($needle -and ($entry.title + ' ' + $entry.source + ' ' + $entry.preview).IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $item = [pscustomobject]@{ Label = $entry.title + ' | ' + $entry.count + ' exchanges | ' + $entry.createdAt; Entry = $entry }
            $list.Items.Add($item) | Out-Null
            if ($entry.id -eq $selectedId) { $list.SelectedItem = $item }
        }
        $dialog.FindName('Count').Text = $list.Items.Count.ToString() + ' saved selections'
    }
    $refresh = {
        $dialog.Tag.Entries = @(Invoke-DemoLibrary @{ command = 'list' } $dialog)
        & $filter
    }
    $search.Add_TextChanged({ & $filter })
    $dialog.FindName('SavedRefresh').Add_Click({
        try { & $refresh } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Summaries').Add_Click({
        try {
            if (-not $list.SelectedItem) { throw 'Select a demo to edit its prompt summaries.' }
            if (Show-DemoSummaryDialog $dialog $list.SelectedItem.Entry.id) { & $refresh }
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('AiSummaries').Add_Click({
        try {
            if (-not $list.SelectedItem) { throw 'Select a demo to summarize.' }
            Show-DemoSummaryAuthoringNotice $dialog $list.SelectedItem.Entry.id
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('ClearSummaries').Add_Click({
        try {
            if (-not $list.SelectedItem) { throw 'Select a demo to clear its summaries.' }
            if (Show-DemoClearSummariesNotice $dialog $list.SelectedItem.Entry.id) { & $refresh }
        } catch { Show-DemoError $dialog $_ }
    })
    $list.Add_SelectionChanged({
        $entry = if ($list.SelectedItem) { $list.SelectedItem.Entry } else { $null }
        $dialog.FindName('SavedTitle').Text = if ($entry) { $entry.title } else { '' }
        $dialog.FindName('SavedPreview').Text = if ($entry) { $entry.source + "`r`n" + $entry.preview + "`r`n" + $entry.notice } else { '' }
        foreach ($name in @('Select', 'Summaries', 'AiSummaries', 'ClearSummaries', 'Rename', 'Export', 'Delete')) {
            $dialog.FindName($name).IsEnabled = $null -ne $entry
        }
    })
    $dialog.FindName('Import').Add_Click({
        try {
            $file = Select-DemoFile $dialog 'Demo recording packages (*.demo-recording.json)|*.demo-recording.json|JSON files (*.json)|*.json'
            if ($file) {
                $answer = [System.Windows.MessageBox]::Show($dialog, 'Import this local recording? It may contain sensitive content. Review it before sharing. No recorded tools will execute.', 'Import Recording', 'YesNo', 'Warning')
                if ($answer -eq 'Yes') { Invoke-DemoLibrary @{ command = 'import'; file = $file } $dialog | Out-Null; & $refresh }
            }
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Rename').Add_Click({
        try {
            if (-not $list.SelectedItem) { throw 'Select a demo to rename.' }
            Invoke-DemoLibrary @{ command = 'rename'; id = $list.SelectedItem.Entry.id; title = $dialog.FindName('SavedTitle').Text } $dialog | Out-Null
            & $refresh
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Delete').Add_Click({
        try {
            if (-not $list.SelectedItem) { throw 'Select a demo to delete.' }
            $entry = $list.SelectedItem.Entry
            if ([System.Windows.MessageBox]::Show($dialog, ('Delete "' + $entry.title + '" from this library? Original conversation storage and exported copies will not be changed.'), 'Delete Demo', 'YesNo', 'Warning') -eq 'Yes') {
                Invoke-DemoLibrary @{ command = 'delete'; id = $entry.id } $dialog | Out-Null
                & $refresh
            }
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Export').Add_Click({
        try {
            if (-not $list.SelectedItem) { throw 'Select a demo to export.' }
            $picker = [Microsoft.Win32.SaveFileDialog]::new()
            $picker.Filter = 'Demo recording packages (*.demo-recording.json)|*.demo-recording.json'
            $picker.FileName = 'recording.demo-recording.json'
            if ($picker.ShowDialog($dialog)) {
                Invoke-DemoLibrary @{ command = 'export'; id = $list.SelectedItem.Entry.id; file = $picker.FileName } $dialog | Out-Null
                [System.Windows.MessageBox]::Show($dialog, 'Recording exported. Review the package for sensitive content before sharing.', 'Demo Player') | Out-Null
            }
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Select').Add_Click({
        try {
            if (-not $list.SelectedItem) { throw 'Choose a saved selection first.' }
            $dialog.Tag.Result = Invoke-DemoLibrary @{ command = 'read'; id = $list.SelectedItem.Entry.id } $dialog
            $dialog.DialogResult = $true
        } catch { Show-DemoError $dialog $_ }
    })
    foreach ($name in @('Select', 'Summaries', 'AiSummaries', 'ClearSummaries', 'Rename', 'Export', 'Delete')) {
        $dialog.FindName($name).IsEnabled = $false
    }
    & $refresh
    if ($dialog.ShowDialog()) { return $dialog.Tag.Result }
    return $null
}
