function Invoke-DemoLibrary([hashtable]$Request, $Owner) {
    if (-not $script:NodePath) {
        $script:NodePath = Resolve-PlayerNode
    }
    $Request.root = $script:LibraryRoot
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
    $process = [System.Diagnostics.Process]::Start($start)
    if (-not $process) { throw 'The demo library helper could not start.' }
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $writer = [System.IO.StreamWriter]::new($process.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($false), 4096, $true)
        try { $writer.Write(($Request | ConvertTo-Json -Depth 10 -Compress)); $writer.Flush() }
        finally { $writer.Dispose() }
        $process.StandardInput.Close()
        $exited = $false
        if ($Owner) {
            $enabled = $Owner.IsEnabled
            $cursor = $Owner.Cursor
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(50)
            $elapsed = [Diagnostics.Stopwatch]::StartNew()
            $timer.Add_Tick({
                if ($process.HasExited -or $elapsed.ElapsedMilliseconds -ge 30000) { $frame.Continue = $false }
            })
            try {
                $Owner.IsEnabled = $false
                $Owner.Cursor = [System.Windows.Input.Cursors]::Wait
                $timer.Start()
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                $exited = $process.HasExited
            } finally {
                $timer.Stop()
                $elapsed.Stop()
                $Owner.IsEnabled = $enabled
                $Owner.Cursor = $cursor
            }
        } else { $exited = $process.WaitForExit(30000) }
        if (-not $exited) {
            $process.Kill()
            throw 'The demo library operation exceeded 30 seconds. No success was confirmed. Refresh the library before retrying.'
        }
        if (-not [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($output, $errors), 2000)) { throw 'Timed out reading the library helper output.' }
        $text = $output.GetAwaiter().GetResult()
        if (-not $text) { throw ('The demo library helper returned no result. ' + $errors.GetAwaiter().GetResult()) }
        $response = ConvertFrom-Json -InputObject $text
        if (-not $response.ok -or $process.ExitCode -ne 0) { throw $response.error }
        return $response.result
    } finally { $process.Dispose() }
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
    $picker.Description = 'Select the project folder whose VS Code conversations you want to import.'
    $picker.ShowNewFolderButton = $false
    $nativeOwner = [System.Windows.Forms.NativeWindow]::new()
    try {
        $nativeOwner.AssignHandle(([System.Windows.Interop.WindowInteropHelper]::new($Owner)).Handle)
        if ($picker.ShowDialog($nativeOwner) -eq [System.Windows.Forms.DialogResult]::OK) { return $picker.SelectedPath }
        return $null
    } finally { $nativeOwner.ReleaseHandle(); $picker.Dispose() }
}

function Show-CaptureDialog($Owner) {
    $dialog = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Capture Conversation"
 Width="900" Height="740" MinWidth="720" MinHeight="620" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
 <Grid Margin="16">
  <Grid.RowDefinitions>
   <RowDefinition Height="Auto"/><RowDefinition Height="110"/><RowDefinition Height="Auto"/>
   <RowDefinition Height="140"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <StackPanel Margin="0,0,0,8">
  <DockPanel>
   <Button x:Name="Browse" DockPanel.Dock="Right" Content="Browse transcript..." Padding="12,5"/>
   <TextBlock x:Name="DiscoveryNote" Text="Choose a project folder to list only its saved VS Code conversations, or browse to a transcript." TextWrapping="Wrap" Margin="0,0,12,0"/>
  </DockPanel>
  <DockPanel Margin="0,8,0,0">
   <Button x:Name="ChooseFolder" Content="Choose folder..." DockPanel.Dock="Right" Padding="12,5" AutomationProperties.AutomationId="CaptureChooseFolder"/>
   <Button x:Name="FindSessions" Content="Find conversations" DockPanel.Dock="Right" Padding="12,5" Margin="8,0" AutomationProperties.AutomationId="CaptureFindSessions"/>
   <TextBox x:Name="Folder" ToolTip="Project directory (not the VS Code storage directory)" VerticalContentAlignment="Center" AutomationProperties.AutomationId="CaptureFolder"/>
  </DockPanel>
  </StackPanel>
  <ListBox x:Name="Sessions" Grid.Row="1" DisplayMemberPath="Label" AutomationProperties.AutomationId="CaptureSessions"/>
  <DockPanel Grid.Row="2" Margin="0,10,0,6">
   <Button x:Name="Load" Content="Load conversation" DockPanel.Dock="Right" Padding="12,5"/>
   <TextBox x:Name="Source" ToolTip="Select a session, paste a native JSONL file path, or use Browse" Margin="0,0,12,0" VerticalContentAlignment="Center" AutomationProperties.AutomationId="CaptureSource"/>
  </DockPanel>
  <ListBox x:Name="Turns" Grid.Row="3" SelectionMode="Extended" DisplayMemberPath="Label" AutomationProperties.AutomationId="CaptureTurns"/>
  <TextBox x:Name="Preview" Grid.Row="4" Margin="0,8,0,8" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AutomationProperties.AutomationId="CapturePreview"/>
  <StackPanel Grid.Row="5">
   <CheckBox x:Name="RawPayload" Content="Show full saved payload (tools and metadata)" Margin="0,0,0,6" AutomationProperties.AutomationId="CaptureRawPayload"/>
   <TextBlock Text="Demo title (1-160 characters). Select up to 100 exchanges with Ctrl/Shift; playback follows source order." TextWrapping="Wrap"/>
   <TextBox x:Name="Title" Margin="0,5,0,8" MaxLength="160" AutomationProperties.AutomationId="CaptureTitle"/>
   <CheckBox x:Name="Reviewed" Content="I reviewed the selected content for secrets. External assets are not bundled; playback uses saved payloads only." AutomationProperties.AutomationId="CaptureReviewed"/>
  </StackPanel>
  <DockPanel Grid.Row="6" Margin="0,12,0,0">
   <Button x:Name="Save" Content="Save Demo" DockPanel.Dock="Right" Padding="18,6" AutomationProperties.AutomationId="SaveDemo"/>
   <TextBlock x:Name="CaptureStatus" TextWrapping="Wrap" Margin="0,0,12,0"/>
  </DockPanel>
 </Grid>
</Window>
'@ $Owner
    $dialog.Tag = @{ File = $null; Inspection = $null; Result = $null; Folder = $null }
    $sessions = $dialog.FindName('Sessions')
    $turns = $dialog.FindName('Turns')
    $preview = $dialog.FindName('Preview')
    $title = $dialog.FindName('Title')
    $reviewed = $dialog.FindName('Reviewed')
    $captureStatus = $dialog.FindName('CaptureStatus')
    $sourceBox = $dialog.FindName('Source')
    $folderBox = $dialog.FindName('Folder')
    $discover = {
        $sessions.Items.Clear()
        $sourceBox.Text = ''
        $dialog.FindName('DiscoveryNote').Text = 'Finding conversations for the selected folder...'
        $discovery = Invoke-DemoLibrary @{ command = 'discover'; folder = $folderBox.Text } $dialog
        $dialog.Tag.Folder = $folderBox.Text
        $dialog.FindName('DiscoveryNote').Text = $discovery.notice
        foreach ($session in $discovery.sessions) {
            $sessions.Items.Add([pscustomobject]@{
                Label = $session.title + ' | ' + $session.modified
                File = $session.file
            }) | Out-Null
        }
    }
    $folderBox.Add_TextChanged({
        if ($folderBox.Text -ne $dialog.Tag.Folder) {
            $sessions.Items.Clear()
            $sourceBox.Text = ''
            $dialog.FindName('DiscoveryNote').Text = 'Find conversations to refresh the list for this folder.'
        }
    })
    $dialog.FindName('FindSessions').Add_Click({
        try { & $discover }
        catch { $dialog.FindName('DiscoveryNote').Text = 'Discovery failed: ' + $_.Exception.Message }
    })
    $dialog.FindName('ChooseFolder').Add_Click({
        try {
            $folder = Select-DemoFolder $dialog
            if ($folder) { $folderBox.Text = $folder; & $discover }
        } catch { $dialog.FindName('DiscoveryNote').Text = 'Discovery failed: ' + $_.Exception.Message }
    })
    $sourceBox.Add_TextChanged({
        if ($sourceBox.Text -ne $dialog.Tag.File) {
            $dialog.Tag.Inspection = $null
            $turns.Items.Clear()
            $preview.Text = ''
            $reviewed.IsChecked = $false
            $captureStatus.Text = 'Load this conversation to preview it before capture.'
        }
    })
    $sessions.Add_SelectionChanged({
        if ($sessions.SelectedItem) { $sourceBox.Text = $sessions.SelectedItem.File }
    })
    $loadSource = {
        param([string]$File)
        $captureStatus.Text = 'Loading the saved conversation...'
        $inspection = Invoke-DemoLibrary @{ command = 'inspect'; file = $File } $dialog
        $dialog.Tag.File = $File
        $dialog.Tag.Inspection = $inspection
        $dialog.FindName('Source').Text = $File
        $turns.Items.Clear()
        foreach ($turn in $inspection.turns) {
            $label = ($turn.index + 1).ToString() + '. ' + ($turn.prompt -replace '\s+', ' ')
            if ($turn.error) { $label = '[Unavailable] ' + $label }
            elseif ($turn.status -eq 'archived-edits') { $label = '[Read-only edits] ' + $label }
            $turns.Items.Add([pscustomobject]@{ Label = $label; Turn = $turn }) | Out-Null
        }
        $title.Text = if ($inspection.title.Length -gt 160) { $inspection.title.Substring(0,160) } else { $inspection.title }
        $preview.Text = $inspection.notice
        $reviewed.IsChecked = $false
        $captureStatus.Text = 'Select exchanges, review their saved content, then Save Demo.'
    }
    $dialog.FindName('Load').Add_Click({
        try {
            if (-not $sourceBox.Text) { throw 'Select a saved session, paste a file path, or use Browse.' }
            & $loadSource $sourceBox.Text
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Browse').Add_Click({
        try {
            $file = Select-DemoFile $dialog 'Native VS Code transcripts (*.jsonl)|*.jsonl'
            if ($file) { & $loadSource $file }
        } catch { Show-DemoError $dialog $_ }
    })
    $updatePreview = {
        $reviewed.IsChecked = $false
        $parts = @($turns.SelectedItems | Sort-Object { $_.Turn.index } | ForEach-Object {
            $turn = $_.Turn
            $problem = if ($turn.error) { "`r`nUNAVAILABLE: " + $turn.error } else { '' }
            $content = if ($dialog.FindName('RawPayload').IsChecked) {
                "FULL SAVED PAYLOAD (includes prompt, response, tools, and metadata):`r`n" + $turn.details
            } else { $turn.content }
            'EXCHANGE ' + ($turn.index + 1) + $problem + "`r`n" + $content
        })
        $preview.Text = $parts -join "`r`n`r`n----------------`r`n`r`n"
    }
    $turns.Add_SelectionChanged($updatePreview)
    $dialog.FindName('RawPayload').Add_Checked($updatePreview)
    $dialog.FindName('RawPayload').Add_Unchecked($updatePreview)
    $dialog.FindName('Save').Add_Click({
        try {
            if (-not $dialog.Tag.Inspection) { throw 'Load a conversation first.' }
            if (-not $reviewed.IsChecked) { throw 'Review the selected content and acknowledge the privacy and asset notice.' }
            $selected = @($turns.SelectedItems | Sort-Object { $_.Turn.index })
            if ($selected.Count -lt 1 -or $selected.Count -gt 100) { throw 'Select 1 to 100 exchanges.' }
            if (@($selected | Where-Object { $_.Turn.error }).Count) { throw 'The selection contains incomplete or unsupported exchanges. Their exact errors are shown in the preview.' }
            $indices = @($selected | ForEach-Object { [int]$_.Turn.index })
            $dialog.Tag.Result = Invoke-DemoLibrary @{ command = 'capture'; file = $dialog.Tag.File; sha256 = $dialog.Tag.Inspection.sha256; title = $title.Text; indices = $indices } $dialog
            $dialog.DialogResult = $true
        } catch { Show-DemoError $dialog $_ }
    })
    if ($dialog.ShowDialog()) { return $dialog.Tag.Result }
    return $null
}

function Show-DemoLibraryDialog($Owner) {
    $dialog = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Demo Library"
 Width="780" Height="580" MinWidth="650" MinHeight="500" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
 <Grid Margin="16">
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="100"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <DockPanel Margin="0,0,0,10">
   <Button x:Name="Capture" Content="Capture Conversation" DockPanel.Dock="Right" Padding="12,6" Margin="8,0,0,0" AutomationProperties.AutomationId="CaptureConversation"/>
   <Button x:Name="Import" Content="Import Recording" DockPanel.Dock="Right" Padding="12,6" Margin="8,0,0,0"/>
   <TextBlock Text="Search" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,8,0"/>
   <TextBox x:Name="Search" ToolTip="Search demos by title, source, or opening prompt" VerticalContentAlignment="Center" AutomationProperties.AutomationId="DemoSearch"/>
  </DockPanel>
  <ListBox x:Name="Demos" Grid.Row="1" DisplayMemberPath="Label" AutomationProperties.AutomationId="DemoList"/>
  <TextBox x:Name="Preview" Grid.Row="2" Margin="0,8,0,8" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
  <DockPanel Grid.Row="3" Margin="0,0,0,10">
   <Button x:Name="Rename" Content="Rename" DockPanel.Dock="Right" Padding="12,5" Margin="8,0,0,0"/>
   <TextBox x:Name="Title" MaxLength="160" ToolTip="Edit the selected demo title"/>
  </DockPanel>
  <DockPanel Grid.Row="4">
   <Button x:Name="Select" Content="Select Demo" DockPanel.Dock="Right" Padding="18,6" AutomationProperties.AutomationId="SelectDemo"/>
   <Button x:Name="Export" Content="Export..." DockPanel.Dock="Left" Padding="12,6"/>
   <Button x:Name="Delete" Content="Delete" DockPanel.Dock="Left" Padding="12,6" Margin="8,0,0,0"/>
   <TextBlock x:Name="Count" VerticalAlignment="Center" Margin="12,0,12,0"/>
  </DockPanel>
 </Grid>
</Window>
'@ $Owner
    $dialog.Tag = @{ Entries = @(); Result = $null }
    $list = $dialog.FindName('Demos')
    $search = $dialog.FindName('Search')
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
        $dialog.FindName('Count').Text = $list.Items.Count.ToString() + ' demos'
    }
    $refresh = {
        $dialog.Tag.Entries = @(Invoke-DemoLibrary @{ command = 'list' })
        & $filter
    }
    $search.Add_TextChanged({ & $filter })
    $list.Add_SelectionChanged({
        $entry = if ($list.SelectedItem) { $list.SelectedItem.Entry } else { $null }
        $dialog.FindName('Title').Text = if ($entry) { $entry.title } else { '' }
        $dialog.FindName('Preview').Text = if ($entry) { $entry.source + "`r`n" + $entry.preview + "`r`n" + $entry.notice } else { '' }
    })
    $dialog.FindName('Capture').Add_Click({
        try {
            $result = Show-CaptureDialog $dialog
            if ($result) { & $refresh }
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Import').Add_Click({
        try {
            $file = Select-DemoFile $dialog 'Demo recording packages (*.demo-recording.json)|*.demo-recording.json|JSON files (*.json)|*.json'
            if ($file) {
                $answer = [System.Windows.MessageBox]::Show($dialog, 'Import this local recording? It may contain sensitive content. Review it before sharing. No recorded tools will execute.', 'Import Recording', 'YesNo', 'Warning')
                if ($answer -eq 'Yes') { Invoke-DemoLibrary @{ command = 'import'; file = $file } | Out-Null; & $refresh }
            }
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Rename').Add_Click({
        try {
            if (-not $list.SelectedItem) { throw 'Select a demo to rename.' }
            Invoke-DemoLibrary @{ command = 'rename'; id = $list.SelectedItem.Entry.id; title = $dialog.FindName('Title').Text } | Out-Null
            & $refresh
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Delete').Add_Click({
        try {
            if (-not $list.SelectedItem) { throw 'Select a demo to delete.' }
            $entry = $list.SelectedItem.Entry
            if ([System.Windows.MessageBox]::Show($dialog, ('Delete "' + $entry.title + '" from this library? Original conversation storage and exported copies will not be changed.'), 'Delete Demo', 'YesNo', 'Warning') -eq 'Yes') {
                Invoke-DemoLibrary @{ command = 'delete'; id = $entry.id } | Out-Null
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
                Invoke-DemoLibrary @{ command = 'export'; id = $list.SelectedItem.Entry.id; file = $picker.FileName } | Out-Null
                [System.Windows.MessageBox]::Show($dialog, 'Recording exported. Review the package for sensitive content before sharing.', 'Demo Player') | Out-Null
            }
        } catch { Show-DemoError $dialog $_ }
    })
    $dialog.FindName('Select').Add_Click({
        if ($list.SelectedItem) { $dialog.Tag.Result = $list.SelectedItem.Entry; $dialog.DialogResult = $true }
    })
    & $refresh
    if ($dialog.ShowDialog()) { return $dialog.Tag.Result }
    return $null
}
