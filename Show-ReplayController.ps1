param(
    [Parameter(Mandatory = $true)]
    [string]$ControlPath,
    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,
    [Parameter(Mandatory = $true)]
    [int]$ReplayProcessId
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
$profile = [System.IO.Path]::GetFullPath($ProfilePath)
$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
if ([System.IO.Path]::GetDirectoryName($profile) -ine $temporaryRoot -or [System.IO.Path]::GetFileName($profile) -notmatch '^historical-replay-(player|agents)-[a-f0-9]{32}$') {
    throw 'The controller can manage only its own isolated replay profile.'
}

[xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Replay Control" Width="224" Height="124"
        ResizeMode="NoResize" WindowStartupLocation="Manual"
        ShowActivated="False" Background="#F5F5F5" FontFamily="Segoe UI">
  <Grid Margin="12,8,12,12">
    <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="36"/></Grid.RowDefinitions>
    <TextBlock x:Name="Status" Text="Preparing" Foreground="#555555" FontSize="12"
               VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="8"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Button x:Name="PlayPause" IsEnabled="False" ToolTip="Play"
              AutomationProperties.AutomationId="PlayPause" AutomationProperties.Name="Play">
        <TextBlock x:Name="PlayIcon" FontFamily="Segoe MDL2 Assets" FontSize="16" Text="&#xE768;"/>
      </Button>
      <Button x:Name="Stop" Grid.Column="2" ToolTip="Stop and close both replay windows"
              AutomationProperties.AutomationId="Stop" AutomationProperties.Name="Stop">
        <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="16" Text="&#xE71A;"/>
      </Button>
    </Grid>
  </Grid>
</Window>
'@
$reader = [System.Xml.XmlNodeReader]::new($layout)
try { $window = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
$status = $window.FindName('Status')
$playPause = $window.FindName('PlayPause')
$playIcon = $window.FindName('PlayIcon')
$stop = $window.FindName('Stop')
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
    try { return -not [System.Diagnostics.Process]::GetProcessById($ReplayProcessId).HasExited } catch { return $false }
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

function Request-Stop {
    if ($script:stopping) { return }
    $script:stopping = $true
    $script:deadline = [DateTime]::UtcNow.AddSeconds(8)
    $status.Text = 'Stopping'
    $playPause.IsEnabled = $false
    Send-Control 'stop'
}

$playPause.Add_Click({
    if ($script:action) {
        $playPause.IsEnabled = $false
        Send-Control $script:action
    }
})
$stop.Add_Click({ Request-Stop })
$window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:closeAllowed) {
        $eventArgs.Cancel = $true
        Request-Stop
    }
})
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    try {
        if (-not (Test-ReplayAlive)) {
            $script:closeAllowed = $true
            $window.Close()
            return
        }
        if (-not $script:client -and (Test-Path -LiteralPath $ControlPath)) {
            $connection = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($ControlPath))
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
            if (-not $script:pairedVisible) {
                $script:pairedVisible = Show-PairedReplayWindow
                if (-not $script:pairedVisible) { return }
                $window.Show()
            }
            $status.Text = if ($view.progress) { $view.label + '  ' + $view.progress } else { $view.label }
            $script:action = $view.action
            $playPause.IsEnabled = [bool]$view.enabled -and -not $script:actionTask
            $playPause.ToolTip = $view.button
            [System.Windows.Automation.AutomationProperties]::SetName($playPause, $view.button)
            $playIcon.Text = switch ($view.button) {
                'Pause' { [char]0xE769 }
                'Finished' { [char]0xE73E }
                default { [char]0xE768 }
            }
        }
        if ($script:client -and -not $script:stateTask) { $script:stateTask = $script:client.GetAsync('state') }
        if (-not $script:client -and [DateTime]::UtcNow -gt $script:preparedDeadline) {
            $window.Show()
            $status.Text = 'Player not ready'
            $status.ToolTip = 'The script could not be prepared. Stop closes this isolated replay pair.'
        }
    } catch {
        $status.ToolTip = $_.Exception.Message
        $status.Text = if ($script:stopping) { 'Stopping' } else { 'Connection unavailable' }
        $script:stateTask = $null
        $script:actionTask = $null
    }
})
$window.Add_Closed({
    $timer.Stop()
    if ($script:client) { $script:client.Dispose() }
})
$application = [System.Windows.Application]::new()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$application.MainWindow = $window
$timer.Start()
$application.Run() | Out-Null