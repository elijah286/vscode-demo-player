param(
    [string]$ControlPath,
    [string]$ProfilePath,
    [int]$ReplayProcessId,
    [string]$LibraryRoot = (Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\demos'),
    [string]$NodePath,
    [string]$CodePath,
    [string]$InstalledLauncherPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName UIAutomationClient
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ReplayWindowVisibility {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int left, int top, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
}
'@
$script:standalone = -not $ReplayProcessId -and -not $ControlPath -and -not $ProfilePath
$script:LibraryRoot = [System.IO.Path]::GetFullPath($LibraryRoot)
$script:NodePath = $NodePath
$script:CodePath = $CodePath
. (Join-Path $PSScriptRoot 'PlayerEnvironment.ps1')
. (Join-Path $PSScriptRoot 'DemoDialogs.ps1')
. (Join-Path $PSScriptRoot 'PlayerUpdates.ps1')
$profile = $null
$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
if (-not $script:standalone) {
    if (-not $ReplayProcessId -or -not $ControlPath -or -not $ProfilePath) { throw 'Attach mode requires a process ID, control path, and profile path.' }
    $profile = [System.IO.Path]::GetFullPath($ProfilePath)
    if ([System.IO.Path]::GetDirectoryName($profile) -ine $temporaryRoot -or [System.IO.Path]::GetFileName($profile) -notmatch '^historical-replay-(player|agents)-[a-f0-9]{32}$') {
    throw 'The controller can manage only its own isolated replay profile.'
    }
}

[xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Demo Player" Width="360" Height="402" Topmost="True"
        ResizeMode="NoResize" WindowStartupLocation="Manual"
        ShowActivated="False" Background="#F5F5F5" FontFamily="Segoe UI">
  <Grid Margin="12,8,12,12">
    <Grid.RowDefinitions><RowDefinition Height="38"/><RowDefinition Height="32"/><RowDefinition Height="36"/><RowDefinition Height="12"/><RowDefinition Height="32"/><RowDefinition Height="8"/><RowDefinition Height="24"/><RowDefinition Height="24"/><RowDefinition Height="36"/><RowDefinition Height="36"/><RowDefinition Height="48"/></Grid.RowDefinitions>
    <Button x:Name="ChooseDemo" Content="Select a demo..." HorizontalContentAlignment="Left" Padding="8,0"
            AutomationProperties.AutomationId="ChooseDemo"/>
    <TextBlock x:Name="Status" Grid.Row="1" Text="Preparing" Foreground="#555555" FontSize="12"
               VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    <Grid Grid.Row="2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions>
      <Button x:Name="PlayPause" IsEnabled="False" ToolTip="Play"
              AutomationProperties.AutomationId="PlayPause" AutomationProperties.Name="Play">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock x:Name="PlayIcon" FontFamily="Segoe MDL2 Assets" FontSize="14" Text="&#xE768;" VerticalAlignment="Center"/>
                    <TextBlock x:Name="PrimaryLabel" Text="Open" Margin="6,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
      </Button>
            <Button x:Name="NextStep" Grid.Column="2" IsEnabled="False" ToolTip="Next Step" AutomationProperties.AutomationId="NextStep" AutomationProperties.Name="Next Step">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="14" Text="&#xE72A;" VerticalAlignment="Center"/>
                    <TextBlock Text="Next Step" Margin="6,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
            </Button>
            <Button x:Name="Stop" Grid.Column="4" ToolTip="Stop playback"
              AutomationProperties.AutomationId="Stop" AutomationProperties.Name="Stop">
        <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="16" Text="&#xE71A;"/>
      </Button>
    </Grid>
    <Grid Grid.Row="4">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="Capture" Content="Capture Conversation" AutomationProperties.AutomationId="CaptureConversation"/>
      <Button x:Name="Library" Grid.Column="2" Content="Manage Demos" AutomationProperties.AutomationId="ManageDemos"/>
    </Grid>
        <CheckBox x:Name="ShowPrompt" Grid.Row="6" Content="Show prompt summary" IsEnabled="False"
                            VerticalContentAlignment="Center" AutomationProperties.AutomationId="ShowPrompt"/>
        <CheckBox x:Name="ShowElapsed" Grid.Row="7" Content="Show elapsed time" IsEnabled="False"
                            VerticalContentAlignment="Center" AutomationProperties.AutomationId="ShowElapsed"
                            ToolTip="Interpolated response work. Excludes user idle gaps; holds during typing and pauses."/>
        <Grid Grid.Row="8" Margin="0,4,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
            <TextBlock Text="Overlay frame" VerticalAlignment="Center" FontSize="12" Foreground="#555555"/>
            <Button x:Name="FrameColor" Grid.Column="1" Padding="3" ToolTip="Overlay frame color: #F5B82E"
                            AutomationProperties.AutomationId="FrameColor" AutomationProperties.Name="Overlay frame color: #F5B82E">
                <Border x:Name="FrameColorSwatch" Width="26" Height="16" Background="#F5B82E" BorderBrush="#777777" BorderThickness="1" CornerRadius="2"/>
            </Button>
        </Grid>
        <ComboBox x:Name="WindowMode" Grid.Row="9" Margin="0,6,0,0" AutomationProperties.AutomationId="WindowMode"
                            ToolTip="Playback UI. Agents is experimental and requires sign-in in its dedicated window. Switch between turns.">
            <ComboBoxItem Tag="Editor" Content="VS Code"/>
            <ComboBoxItem Tag="Agents" Content="Agents (experimental)"/>
        </ComboBox>
    <DockPanel Grid.Row="10" Margin="0,12,0,0">
      <Button x:Name="CheckUpdates" DockPanel.Dock="Right" Content="Check for updates" Padding="8,0" AutomationProperties.AutomationId="CheckUpdates"/>
      <TextBlock x:Name="UpdateNotice" FontSize="11" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,8,0" AutomationProperties.AutomationId="UpdateNotice"/>
    </DockPanel>
  </Grid>
</Window>
'@
$reader = [System.Xml.XmlNodeReader]::new($layout)
try { $window = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
if ($InstalledLauncherPath) {
    Add-Type -AssemblyName System.Drawing
    $icon = [Drawing.Icon]::ExtractAssociatedIcon($InstalledLauncherPath)
    if (-not $icon) { throw 'The installed taskbar launcher has no icon. Reinstall VS Code Demo Player.' }
    try {
        $window.Icon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($icon.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
    } finally { $icon.Dispose() }
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
    [PlayerTaskbarIdentity]::InitializeWindow($handle, $InstalledLauncherPath)
}
$status = $window.FindName('Status')
$playPause = $window.FindName('PlayPause')
$playIcon = $window.FindName('PlayIcon')
$primaryLabel = $window.FindName('PrimaryLabel')
$nextStep = $window.FindName('NextStep')
$stop = $window.FindName('Stop')
$chooseDemo = $window.FindName('ChooseDemo')
$capture = $window.FindName('Capture')
$library = $window.FindName('Library')
$checkUpdates = $window.FindName('CheckUpdates')
$updateNotice = $window.FindName('UpdateNotice')
$showPrompt = $window.FindName('ShowPrompt')
$showElapsed = $window.FindName('ShowElapsed')
$frameColor = $window.FindName('FrameColor')
$frameColorSwatch = $window.FindName('FrameColorSwatch')
$windowMode = $window.FindName('WindowMode')
$area = [System.Windows.SystemParameters]::WorkArea
$window.Left = [Math]::Max($area.Left, $area.Right - $window.Width - 16)
$window.Top = [Math]::Max($area.Top, $area.Bottom - $window.Height - 16)
$script:client = $null
$script:stateTask = $null
$script:actionTask = $null
$script:action = $null
$script:stopping = $false
$script:stopSent = $false
$script:closeAllowed = $false
$script:fallbackSent = $false
$script:deadline = [DateTime]::MaxValue
$script:preparedDeadline = [DateTime]::UtcNow.AddSeconds(45)
$script:pairedVisible = $false
$script:selectedDemo = $null
$script:exitRequested = $false
$script:connectionFailures = 0
$script:lastFault = $null
$script:lastView = $null
$script:replayMode = 'Editor'
$script:modeUpdating = $false
$script:switching = $false
$script:switchView = $null
$windowMode.SelectedIndex = 0
. (Join-Path $PSScriptRoot 'ReplayPresentation.ps1')

function Set-IdleView {
    $script:lastView = $script:selectedDemo.presentation
    $status.Text = if ($script:lastFault) { 'Stopped: ' + $script:lastFault } elseif ($script:selectedDemo) { 'Selected - ' + $script:selectedDemo.count + ' exchanges' } else { 'Select or capture a conversation' }
    $status.ToolTip = $status.Text
    $chooseDemo.Content = if ($script:selectedDemo) { $script:selectedDemo.title } else { 'Select a demo...' }
    $chooseDemo.ToolTip = $chooseDemo.Content
    $playPause.IsEnabled = [bool]$script:selectedDemo
    $playPause.ToolTip = 'Open'
    $primaryLabel.Text = 'Open'
    [System.Windows.Automation.AutomationProperties]::SetName($playPause, 'Open')
    $playIcon.Text = [char]0xE8A7
    $nextStep.IsEnabled = $false
    $stop.IsEnabled = $false
    $chooseDemo.IsEnabled = $true
    $capture.IsEnabled = $true
    $library.IsEnabled = $true
    $windowMode.IsEnabled = $true
    Update-ReplayOverlays
}

function Reset-ReplaySession {
    if ($script:client) { $script:client.Dispose() }
    $script:client = $null
    $script:stateTask = $null
    $script:actionTask = $null
    $script:ReplayProcessId = 0
    $script:action = $null
    $script:stopping = $false
    $script:stopSent = $false
    $script:fallbackSent = $false
    $script:pairedVisible = $false
    $script:connectionFailures = 0
    $script:lastView = $null
    Update-ReplayOverlays
    if (-not $script:standalone -or $script:exitRequested) {
        $script:closeAllowed = $true
        $window.Close()
    } else { Set-IdleView }
}

function Start-DemoReplay {
    if (-not $script:selectedDemo) { throw 'Select a demo first.' }
    # Validate the saved entry again before launching a new isolated process.
    Invoke-DemoLibrary @{ command = 'read'; id = $script:selectedDemo.id } | Out-Null
    $demoPath = Join-Path $script:LibraryRoot ($script:selectedDemo.id + '.demo.json')
    $launchArguments = @{ DemoPath = $demoPath; NoController = $true; CodePath = $script:CodePath; WindowMode = $script:replayMode }
    $started = & (Join-Path $PSScriptRoot 'Start-Replay.ps1') @launchArguments
    $script:ReplayProcessId = $started.ProcessId
    $script:ControlPath = $started.ControlPath
    $script:profile = $started.ProfilePath
    $script:preparedDeadline = [DateTime]::UtcNow.AddSeconds(45)
    $script:lastFault = $null
    $status.Text = 'Preparing isolated playback'
    $playPause.IsEnabled = $false
    $primaryLabel.Text = 'Opening'
    $nextStep.IsEnabled = $false
    $stop.IsEnabled = $true
    $chooseDemo.IsEnabled = $false
    $capture.IsEnabled = $false
    $library.IsEnabled = $false
    $windowMode.IsEnabled = $false
}

$openLibrary = {
    try {
        $selected = Show-DemoLibraryDialog $window
        if ($selected) { $script:selectedDemo = $selected }
        $entries = @(Invoke-DemoLibrary @{ command = 'list' })
        if ($script:selectedDemo) { $script:selectedDemo = $entries | Where-Object id -eq $script:selectedDemo.id | Select-Object -First 1 }
        $script:lastFault = $null
        Set-IdleView
    } catch { Show-DemoError $window $_ }
}
$chooseDemo.Add_Click($openLibrary)
$library.Add_Click($openLibrary)
$capture.Add_Click({
    try {
        $selected = Show-CaptureDialog $window
        if ($selected) { $script:selectedDemo = $selected; $script:lastFault = $null; Set-IdleView }
    } catch { Show-DemoError $window $_ }
})

function Show-PairedReplayWindow {
    $process = [System.Diagnostics.Process]::GetProcessById($ReplayProcessId)
    $process.Refresh()
    $handle = $process.MainWindowHandle
    if ($handle -eq [IntPtr]::Zero) { return $false }
    [ReplayWindowVisibility]::ShowWindowAsync($handle, 9) | Out-Null
    $width = [Math]::Min(1280, [Math]::Max(320, $area.Width - 48))
    $height = [Math]::Min(850, [Math]::Max(280, $area.Height - 180))
    [ReplayWindowVisibility]::SetWindowPos($handle, [IntPtr]::Zero, [int]($area.Left + 24), [int]($area.Top + 24), [int]$width, [int]$height, 0x0040) | Out-Null
    [ReplayWindowVisibility]::SetForegroundWindow($handle) | Out-Null
    return [ReplayWindowVisibility]::IsWindowVisible($handle)
}

function Test-ReplayAlive {
    if (-not $ReplayProcessId) { return $false }
    try { return -not [System.Diagnostics.Process]::GetProcessById($ReplayProcessId).HasExited }
    catch [System.ArgumentException] { return $false }
}

function Close-ScopedReplayWindow {
    $processes = Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object {
        $_.ProcessId -eq $ReplayProcessId -and $_.CommandLine -and
        $_.CommandLine.IndexOf($profile, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine -like '*--user-data-dir*' -and $_.CommandLine -notlike '*--type=*'
    }
    foreach ($process in $processes) {
        $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$process.ProcessId)
        $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
        foreach ($element in $windows) {
            $pattern = $null
            if ($element.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$pattern)) { $pattern.Close() }
        }
    }
}

function Send-Control([string]$Action) {
    if (-not $script:client -or $script:actionTask) { return }
    $script:actionTask = $script:client.PostAsync($Action, [System.Net.Http.StringContent]::new(''))
    if ($Action -eq 'stop') { $script:stopSent = $true }
}

function Start-SwitchedPlayback {
    if ($script:client) { $script:client.Dispose() }
    if ($script:actionTask -and $script:actionTask.Status -eq 'RanToCompletion') { $script:actionTask.Result.Dispose() }
    $script:client = $null
    $script:stateTask = $null
    $script:actionTask = $null
    $selection = $script:switchView.selection
    $arguments = @{
        WindowMode = $script:replayMode
        UserDataPath = $script:profile
        ResumeTurn = [int]$script:switchView.resumeTurn
        NoController = $true
        CodePath = $script:CodePath
    }
    if ($selection.demoPath) { $arguments.DemoPath = $selection.demoPath }
    elseif ($selection.playlistPath) { $arguments.PlaylistPath = $selection.playlistPath }
    else { $arguments.SessionPath = $selection.file; $arguments.RequestIndex = [int]$selection.requestIndex; $arguments.RequestCount = [int]$selection.requestCount }
    $launch = & (Join-Path $PSScriptRoot 'Start-Replay.ps1') @arguments
    $script:ControlPath = $launch.ControlPath
    $script:ReplayProcessId = $launch.ProcessId
    $script:stopSent = $false
    $script:pairedVisible = $false
    $script:preparedDeadline = [DateTime]::UtcNow.AddSeconds(45)
    $script:switching = $false
    $script:connectionFailures = 0
    $status.Text = 'Preparing ' + $script:replayMode
}

$windowMode.Add_SelectionChanged({
    if ($script:modeUpdating -or $script:switching -or -not $windowMode.IsEnabled) { return }
    $mode = [string]$windowMode.SelectedItem.Tag
    if (-not $ReplayProcessId) { $script:replayMode = $mode; return }
    if (-not $script:lastView.modeSwitchEnabled -or $mode -eq $script:lastView.windowMode) { return }
    $script:switchView = $script:lastView
    $script:replayMode = $mode
    $script:switching = $true
    $script:deadline = [DateTime]::UtcNow.AddSeconds(15)
    $windowMode.IsEnabled = $false
    $playPause.IsEnabled = $false
    $nextStep.IsEnabled = $false
    $status.Text = 'Switching to ' + $mode
    Send-Control 'stop'
})

function Request-Stop {
    if (-not $ReplayProcessId) { return }
    if ($script:stopping) { return }
    $script:stopping = $true
    $script:switching = $false
    $script:deadline = [DateTime]::UtcNow.AddSeconds(8)
    $status.Text = 'Stopping'
    $playPause.IsEnabled = $false
    $nextStep.IsEnabled = $false
    Update-ReplayOverlays
    Send-Control 'stop'
}

$playPause.Add_Click({
    if ($script:standalone -and -not $ReplayProcessId) {
        try { Start-DemoReplay } catch {
            $script:lastFault = $_.Exception.Message
            Set-IdleView
            Show-DemoError $window $_
        }
        return
    }
    if ($script:action) {
        $playPause.IsEnabled = $false
        $nextStep.IsEnabled = $false
        Send-Control $script:action
    }
})
$nextStep.Add_Click({
    if ($nextStep.IsEnabled -and $script:lastView.nextEnabled) {
        $playPause.IsEnabled = $false
        $nextStep.IsEnabled = $false
        Send-Control 'next'
    }
})
$stop.Add_Click({ Request-Stop })
$window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:closeAllowed -and $ReplayProcessId) {
        $eventArgs.Cancel = $true
        $script:exitRequested = $true
        Request-Stop
    }
    if (-not $eventArgs.Cancel -and $InstalledLauncherPath) {
        [PlayerTaskbarIdentity]::ClearWindow([System.Windows.Interop.WindowInteropHelper]::new($window).Handle)
    }
})
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    try {
        if ($script:switching) {
            if (-not (Test-ReplayAlive)) { Start-SwitchedPlayback }
            elseif ([DateTime]::UtcNow -gt $script:deadline) {
                $status.Text = 'Switch waiting for window close'
                $status.ToolTip = 'Close only the isolated playback window normally to finish switching. No process will be killed.'
                $script:deadline = [DateTime]::MaxValue
            }
            return
        }
        if (-not $ReplayProcessId) { return }
        if (-not (Test-ReplayAlive)) {
            if (-not $script:stopping) {
                $script:lastFault = if ($script:pairedVisible) { 'The isolated VS Code target closed.' } else { 'The isolated player exited before it was ready.' }
            }
            Reset-ReplaySession
            return
        }
        if (-not $script:pairedVisible -and -not $script:stopping -and [DateTime]::UtcNow -gt $script:preparedDeadline) {
            $window.Show()
            $script:lastFault = 'Player was not ready within 45 seconds.'
            Request-Stop
        }
        if (-not $script:client -and (Test-Path -LiteralPath $ControlPath)) {
            try { $descriptorText = [System.IO.File]::ReadAllText($ControlPath) }
            catch [System.IO.IOException] {
                if ([DateTime]::UtcNow -lt $script:preparedDeadline) { return }
                throw
            }
            $connection = ConvertFrom-Json -InputObject $descriptorText
            if ($connection.version -ne 1 -or $connection.port -lt 1 -or $connection.port -gt 65535 -or $connection.token -notmatch '^[a-f0-9]{64}$') {
                throw 'Invalid private replay control descriptor.'
            }
            $handler = [System.Net.Http.HttpClientHandler]::new()
            $handler.UseProxy = $false
            $script:client = [System.Net.Http.HttpClient]::new($handler)
            $script:client.Timeout = [TimeSpan]::FromSeconds(1)
            $script:client.BaseAddress = [uri]('http://127.0.0.1:' + $connection.port + '/')
            $script:client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $connection.token)
        }
        if ($script:actionTask -and $script:actionTask.IsCompleted) {
            $response = $script:actionTask.GetAwaiter().GetResult()
            try { $response.EnsureSuccessStatusCode() | Out-Null } finally { $response.Dispose() }
            $script:actionTask = $null
        }
        if ($script:stopping) {
            if (-not $script:stopSent -and -not $script:actionTask) { Send-Control 'stop' }
            if ([DateTime]::UtcNow -gt $script:deadline) {
                if (-not $script:fallbackSent) {
                    $script:fallbackSent = $true
                    $script:deadline = [DateTime]::UtcNow.AddSeconds(6)
                    Close-ScopedReplayWindow
                } else {
                    $status.Text = 'Close replay window to finish'
                    $status.ToolTip = 'The isolated VS Code window has not closed. Close it normally; other editor windows are not affected.'
                    $script:deadline = [DateTime]::MaxValue
                }
            }
            return
        }
        if ($script:stateTask -and $script:stateTask.IsCompleted) {
            $response = $script:stateTask.GetAwaiter().GetResult()
            try {
                $response.EnsureSuccessStatusCode() | Out-Null
                $view = ConvertFrom-Json -InputObject ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult())
            } finally { $response.Dispose() }
            $script:stateTask = $null
            $script:connectionFailures = 0
            if (-not $script:pairedVisible) {
                $script:pairedVisible = Show-PairedReplayWindow
                if (-not $script:pairedVisible) { return }
                $window.Show()
            }
            $status.Text = if ($view.progress) { $view.label + '  ' + $view.progress } else { $view.label }
            if ($view.phase -eq 'error') {
                $script:lastFault = if ($view.error) { $view.error } else { 'Recorded playback failed.' }
                $status.Text = 'Replay error: ' + $script:lastFault
                $status.ToolTip = $status.Text
            }
            $script:action = $view.action
            $playPause.IsEnabled = [bool]$view.enabled -and -not $script:actionTask
            $nextStep.IsEnabled = [bool]$view.nextEnabled -and -not $script:actionTask
            $playPause.ToolTip = $view.button
            $primaryLabel.Text = $view.button
            [System.Windows.Automation.AutomationProperties]::SetName($playPause, $view.button)
            $playIcon.Text = switch ($view.button) {
                'Pause' { [char]0xE769 }
                'Start Over' { [char]0xE72C }
                default { [char]0xE768 }
            }
            $script:lastView = $view
            $script:replayMode = $view.windowMode
            $script:modeUpdating = $true
            try { $windowMode.SelectedIndex = if ($view.windowMode -eq 'Agents') { 1 } else { 0 } } finally { $script:modeUpdating = $false }
            $windowMode.IsEnabled = [bool]$view.modeSwitchEnabled -and -not $script:actionTask
            Update-ReplayOverlays
        }
        if ($script:client -and -not $script:stateTask) { $script:stateTask = $script:client.GetAsync('state') }
    } catch {
        $script:connectionFailures++
        $script:lastFault = $_.Exception.Message
        $status.ToolTip = $_.Exception.Message
        $status.Text = if ($script:stopping) { 'Stopping' } else { 'Connection unavailable' }
        $script:stateTask = $null
        $script:actionTask = $null
        $playPause.IsEnabled = $false
        $nextStep.IsEnabled = $false
        if ($script:connectionFailures -ge 3 -and -not $script:stopping) { Request-Stop }
    }
})
$window.Add_Closed({
    $timer.Stop()
    $script:updateTimer.Stop()
    try { Stop-PlayerUpdateOperation } catch { Set-PlayerUpdateFailure $_ }
    $script:closeAllowed = $true
    $script:overlayWindow.Close()
    if ($script:client) { $script:client.Dispose() }
})
$application = [System.Windows.Application]::new()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$application.MainWindow = $window
Initialize-PlayerUpdates
if ($script:standalone) { Set-IdleView; $window.Show() }
else {
    $chooseDemo.IsEnabled = $false
    $chooseDemo.Content = 'Selected transcript'
    $capture.IsEnabled = $false
    $library.IsEnabled = $false
}
$timer.Start()
$application.Run() | Out-Null
Start-PlayerUpdateHandoff