param(
    [string]$ControlPath,
    [string]$ProfilePath,
    [int]$ReplayProcessId,
    [string]$LibraryRoot = (Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\demos'),
    [string]$NodePath,
    [string]$CodePath,
    [string]$DemoId,
    [string]$InstalledLauncherPath,
    [switch]$LegacyController
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
$script:PersistentLibrary = -not $LegacyController
. (Join-Path $PSScriptRoot 'DemoDialogs.ps1')
. (Join-Path $PSScriptRoot 'PlayerAI.ps1')
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
        Title="Demo Player" Width="360" Height="682" Topmost="True"
        ResizeMode="NoResize" WindowStartupLocation="Manual"
        ShowActivated="False" Background="#F5F5F5" FontFamily="Segoe UI">
  <Grid Margin="12,8,12,12">
    <Grid.RowDefinitions><RowDefinition Height="38"/><RowDefinition Height="32"/><RowDefinition Height="36"/><RowDefinition Height="12"/><RowDefinition Height="32"/><RowDefinition Height="8"/><RowDefinition Height="48"/><RowDefinition Height="24"/><RowDefinition Height="48"/><RowDefinition Height="36"/><RowDefinition Height="36"/><RowDefinition Height="48"/><RowDefinition Height="36"/><RowDefinition Height="92"/><RowDefinition Height="36"/><RowDefinition Height="44"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="15" Margin="0,4,0,0">
      <TextBlock Text="Summary language" FontSize="11"/>
      <ComboBox x:Name="SummaryLanguage" DisplayMemberPath="label" SelectedValuePath="value" IsEnabled="False"
                AutomationProperties.AutomationId="SummaryDisplayLanguage"
                ToolTip="Choose Original or a saved translation. Stop playback before switching. No API request is made."/>
    </StackPanel>
    <Button x:Name="TranslateSummaries" Grid.Row="14" Content="Translate summaries..." IsEnabled="False"
            Margin="0,6,0,0" AutomationProperties.AutomationId="TranslateSummaries"
            ToolTip="Translate saved summaries only, using your OpenAI API key. Original prompts and replies stay unchanged."/>
    <Button x:Name="ChooseDemo" Content="Find interaction..." HorizontalContentAlignment="Left" Padding="8,0"
            AutomationProperties.AutomationId="ChooseDemo"/>
    <TextBlock x:Name="Status" Grid.Row="1" Text="Preparing" Foreground="#555555" FontSize="12"
               VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
    <Grid Grid.Row="2">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/><ColumnDefinition Width="6"/><ColumnDefinition Width="64"/></Grid.ColumnDefinitions>
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
        <StackPanel Orientation="Horizontal">
          <TextBlock FontFamily="Segoe MDL2 Assets" FontSize="16" Text="&#xE71A;" VerticalAlignment="Center"/>
          <TextBlock x:Name="ExitLabel" Text="Exit" Visibility="Collapsed" Margin="4,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
      </Button>
    </Grid>
    <CheckBox x:Name="AutoContinue" Grid.Row="4" Content="Auto continue" IsChecked="False"
              VerticalAlignment="Center" AutomationProperties.AutomationId="AutoContinue"
              ToolTip="Advance after completion and 2-10 seconds to read the visible summary. Uncheck to stay on this exchange."/>
    <Button x:Name="SelectExchanges" Grid.Row="12" Content="Select exchanges..." IsEnabled="False"
            AutomationProperties.AutomationId="SelectExchanges" ToolTip="Choose exchanges before playback or while paused. Saving while paused prepares the current included exchange, or the next included exchange, without autoplay."/>
    <StackPanel Grid.Row="13" Margin="0,8,0,0">
      <TextBlock x:Name="SpeedLabel" Text="Speed: user 2.0s / reply 5.0s" FontSize="12"/>
      <Slider x:Name="PlaybackSpeed" Minimum="0" Maximum="100" Value="0" TickFrequency="1" IsSnapToTickEnabled="True"
              AutomationProperties.AutomationId="PlaybackSpeed" AutomationProperties.Name="Playback speed"
              ToolTip="Left: user 2s / reply 5s. Right: user 0.1s / reply 1s. Changes apply immediately to the current phase."/>
      <TextBlock Text="Normal                                      Fast" FontSize="11" Foreground="#555555"/>
      <TextBlock x:Name="RunEstimate" Text="Estimated total: select an interaction" FontSize="11"
                 AutomationProperties.AutomationId="RunEstimate"
                 ToolTip="Full selected run at this speed, including auto-continue reading delays when enabled. Excludes startup, rendering/transport overhead, manual waits and pauses; not the original working-time timer."/>
    </StackPanel>
        <StackPanel Grid.Row="6">
        <CheckBox x:Name="ShowPrompt" Content="Show prompt summary" IsEnabled="False"
                            VerticalContentAlignment="Center" AutomationProperties.AutomationId="ShowPrompt"/>
        <Button x:Name="GeneratePromptSummaries" Content="Generate AI prompt summaries (0/0)" IsEnabled="False"
                HorizontalAlignment="Left" Padding="0,2" Background="Transparent" BorderThickness="0"
                Foreground="#0066CC" Cursor="Hand" AutomationProperties.AutomationId="GeneratePromptSummaries"
                ToolTip="Generate missing prompt summaries. Counts include all saved summaries, including manual ones."/>
        </StackPanel>
        <CheckBox x:Name="ShowElapsed" Grid.Row="7" Content="Show elapsed time" IsEnabled="False"
                            VerticalContentAlignment="Center" AutomationProperties.AutomationId="ShowElapsed"
                            ToolTipService.ShowOnDisabled="True"
                            ToolTip="Interpolated response work. Excludes user idle gaps; holds during typing and pauses."/>
        <StackPanel Grid.Row="8">
        <CheckBox x:Name="ShowOutput" Content="Show summary of output" IsChecked="False" IsEnabled="False"
                            VerticalContentAlignment="Center" AutomationProperties.AutomationId="ShowOutput"
                            ToolTip="Show input and output summaries as a conversation, with working time always at the top."/>
        <Button x:Name="GenerateOutputSummaries" Content="Generate AI output summaries (0/0)" IsEnabled="False"
                HorizontalAlignment="Left" Padding="0,2" Background="Transparent" BorderThickness="0"
                Foreground="#0066CC" Cursor="Hand" AutomationProperties.AutomationId="GenerateOutputSummaries"
                ToolTip="Generate missing reply summaries. Counts include all saved summaries, including manual ones."/>
        </StackPanel>
        <Grid Grid.Row="9" Margin="0,4,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
            <TextBlock Text="Overlay frame" VerticalAlignment="Center" FontSize="12" Foreground="#555555"/>
            <Button x:Name="FrameColor" Grid.Column="1" Padding="3" ToolTip="Overlay frame color: #F5B82E"
                            AutomationProperties.AutomationId="FrameColor" AutomationProperties.Name="Overlay frame color: #F5B82E">
                <Border x:Name="FrameColorSwatch" Width="26" Height="16" Background="#F5B82E" BorderBrush="#777777" BorderThickness="1" CornerRadius="2"/>
            </Button>
        </Grid>
        <ComboBox x:Name="WindowMode" Grid.Row="10" Margin="0,6,0,0" AutomationProperties.AutomationId="WindowMode"
                            ToolTip="Playback UI. Agents is experimental and requires sign-in in its dedicated window. Switch between turns.">
            <ComboBoxItem Tag="Editor" Content="VS Code"/>
            <ComboBoxItem Tag="Agents" Content="Agents (experimental)"/>
        </ComboBox>
    <DockPanel Grid.Row="11" Margin="0,12,0,0">
      <Button x:Name="CheckUpdates" DockPanel.Dock="Right" Content="Check for updates" Padding="8,0" AutomationProperties.AutomationId="CheckUpdates"/>
      <Button x:Name="AISettings" DockPanel.Dock="Right" Content="Settings" Padding="8,0" Margin="0,0,6,0" AutomationProperties.AutomationId="AISettings" ToolTip="OpenAI API key and summary model"/>
      <TextBlock x:Name="UpdateNotice" FontSize="11" TextWrapping="Wrap" VerticalAlignment="Center" Margin="0,0,8,0" AutomationProperties.AutomationId="UpdateNotice"/>
    </DockPanel>
  </Grid>
</Window>
'@
if ($LegacyController) {
    $reader = [System.Xml.XmlNodeReader]::new($layout)
    try { $window = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
} else {
    . (Join-Path $PSScriptRoot 'PlayerShell.ps1')
    $window = [VibeReplay.ControllerWindow]::new()
}
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
$checkUpdates = $window.FindName('CheckUpdates')
$window.FindName('AISettings').Add_Click({ try { Show-PlayerAISettings $window | Out-Null } catch { Show-DemoError $window $_ } })
$updateNotice = $window.FindName('UpdateNotice')
$showPrompt = $window.FindName('ShowPrompt')
$showElapsed = $window.FindName('ShowElapsed')
$showOutput = $window.FindName('ShowOutput')
$autoContinue = $window.FindName('AutoContinue')
$selectExchanges = $window.FindName('SelectExchanges')
$playbackSpeed = $window.FindName('PlaybackSpeed')
$speedLabel = $window.FindName('SpeedLabel')
$runEstimate = $window.FindName('RunEstimate')
$playbackSpeed.Add_ValueChanged({ Cancel-AutoContinue; Update-PlaybackEstimate })
$generatePromptSummaries = $window.FindName('GeneratePromptSummaries')
$generateOutputSummaries = $window.FindName('GenerateOutputSummaries')
$translateSummaries = $window.FindName('TranslateSummaries')
$summaryLanguage = $window.FindName('SummaryLanguage')
$summaryLanguage.Add_SelectionChanged({
    if ($script:summaryLanguageUpdating -or -not $summaryLanguage.SelectedItem -or -not $script:selectedDemo) { return }
    $language = [string]$summaryLanguage.SelectedItem.value
    if ($language -eq $script:selectedDemo.summaryLanguage) { return }
    try {
        if ($script:ReplayProcessId -or $script:pickerOpen -or $script:summaryRefreshing -or $script:launching -or $window.Resources.Contains('DemoPlayerOperation')) {
            throw 'Stop playback and close other operations before switching summary language.'
        }
        $entry = Invoke-DemoLibrary @{ command = 'read'; id = $script:selectedDemo.id } $window
        $script:selectedDemo = Invoke-DemoLibrary @{
            command = 'summaryLanguage'; id = $script:selectedDemo.id; language = $language
            expected = Get-DemoSummaryExpected $entry.recording
        } $window
        $script:summaryStamp = $null
        Set-IdleView
    } catch { Show-DemoError $window $_ }
    finally { Update-ControllerSummaryLinks }
})
$translateSummaries.Add_Click({
    try {
        if (-not $script:selectedDemo -or $script:ReplayProcessId -or $script:pickerOpen) { throw 'Select an interaction and stop playback before translating summaries.' }
        Invoke-DemoSummaryTranslation $window $script:selectedDemo.id
        $script:summaryStamp = $null
        Refresh-ControllerSummaries
    } catch { Show-DemoError $window $_ }
})
$frameColor = $window.FindName('FrameColor')
$frameColorSwatch = $window.FindName('FrameColorSwatch')
$windowMode = $window.FindName('WindowMode')
$area = [System.Windows.SystemParameters]::WorkArea
$window.Content.Measure([Windows.Size]::new($window.Width, [double]::PositiveInfinity))
$window.Left = [Math]::Max($area.Left, $area.Right - $window.Width - 16)
$window.Top = [Math]::Max($area.Top, $area.Bottom - $window.Content.DesiredSize.Height - 16)
$script:client = $null
$script:stateTask = $null
$script:actionTask = $null
$script:action = $null
$script:stopping = $false
$script:connectionStop = $false
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
$script:summaryStamp = $null
$script:summaryRefreshing = $false
$script:summaryRefreshAt = [DateTime]::MinValue
$script:pickerOpen = $false
$script:launching = $false
$script:autoDeadline = $null
$script:autoKey = $null
$script:autoHandledKey = $null
$script:selectionResumePending = $false
$windowMode.SelectedIndex = 0
. (Join-Path $PSScriptRoot 'ReplayPresentation.ps1')

function Update-ControllerSummaryLinks {
    $total = if ($script:selectedDemo) { $script:selectedDemo.count } else { 0 }
    $inputs = if ($script:selectedDemo) { $script:selectedDemo.summaryCounts.input } else { 0 }
    $outputs = if ($script:selectedDemo) { $script:selectedDemo.summaryCounts.output } else { 0 }
    $generatePromptSummaries.Content = "Generate AI prompt summaries ($inputs/$total)"
    $generateOutputSummaries.Content = "Generate AI output summaries ($outputs/$total)"
    $enabled = [bool]$script:selectedDemo -and -not $script:ReplayProcessId -and -not $script:summaryRefreshing -and -not $script:pickerOpen -and -not $script:launching -and -not $window.Resources.Contains('DemoPlayerOperation')
    $generatePromptSummaries.IsEnabled = $enabled
    $generateOutputSummaries.IsEnabled = $enabled
    $translateSummaries.IsEnabled = $enabled -and ($inputs -gt 0 -or $outputs -gt 0)
    if ($null -ne $summaryLanguage) {
        $script:summaryLanguageUpdating = $true
        try {
            $languageStamp = [string]$script:selectedDemo.id + ':' + (@($script:selectedDemo.summaryLanguages | ForEach-Object { $_.value }) -join ',')
            if ($summaryLanguage.Tag -cne $languageStamp) {
                $summaryLanguage.Items.Clear()
                foreach ($item in @($script:selectedDemo.summaryLanguages)) {
                    if ($null -ne $item) {
                        $summaryLanguage.Items.Add([pscustomobject]@{ value = [string]$item.value; label = [string]$item.label }) | Out-Null
                    }
                }
                $summaryLanguage.Tag = $languageStamp
            }
            $summaryLanguage.SelectedItem = @($summaryLanguage.Items | Where-Object { $_.value -eq $script:selectedDemo.summaryLanguage }) | Select-Object -First 1
            $summaryLanguage.IsEnabled = $enabled -and $summaryLanguage.Items.Count -gt 1
        } finally { $script:summaryLanguageUpdating = $false }
    }
    $pausedSelection = $script:ReplayProcessId -and $script:lastView.action -eq 'resume' -and
        $null -ne $script:lastView.originalIndex -and -not $script:actionTask -and -not $script:stopping -and -not $script:switching
    $selectExchanges.IsEnabled = [bool]$script:selectedDemo -and ($enabled -or ($pausedSelection -and
        -not $script:pickerOpen -and -not $script:launching -and -not $script:summaryRefreshing -and -not $window.Resources.Contains('DemoPlayerOperation')))
}

function Refresh-ControllerSummaries {
    if (-not $script:selectedDemo -or $script:ReplayProcessId -or $script:summaryRefreshing -or $script:pickerOpen -or $script:launching -or $window.Resources.Contains('DemoPlayerOperation') -or -not $window.IsEnabled) { return }
    $script:summaryRefreshing = $true
    Update-ControllerSummaryLinks
    try {
        $path = Join-Path $script:LibraryRoot ($script:selectedDemo.id + '.demo.json')
        $stamp = if (Test-Path -LiteralPath $path -PathType Leaf) {
            $file = Get-Item -LiteralPath $path
            $file.LastWriteTimeUtc.Ticks.ToString() + ':' + $file.Length
        } else { 'missing' }
        if ($stamp -eq $script:summaryStamp) { return }
        $script:selectedDemo = if ($stamp -eq 'missing') { $null } else {
            Invoke-DemoLibrary @{ command = 'metadata'; id = $script:selectedDemo.id } $window
        }
        $script:summaryStamp = $stamp
        Set-IdleView
    } catch {
        $script:summaryRefreshAt = [DateTime]::MaxValue
        Show-DemoError $window $_
    } finally {
        $script:summaryRefreshing = $false
        Update-ControllerSummaryLinks
    }
}

function Invoke-ControllerSummaryAuthoring([ValidateSet('input', 'output')][string]$Scope) {
    try {
        if (-not $script:selectedDemo -or $script:ReplayProcessId -or $script:pickerOpen) { throw 'Select an interaction, close the picker and stop playback before generating summaries.' }
        Show-DemoSummaryAuthoringNotice $window $script:selectedDemo.id $Scope
        Refresh-ControllerSummaries
    } catch { Show-DemoError $window $_ }
}
$generatePromptSummaries.Add_Click({ Invoke-ControllerSummaryAuthoring 'input' })
$generateOutputSummaries.Add_Click({ Invoke-ControllerSummaryAuthoring 'output' })
function Get-ReselectionResumeTurn($Recording, [int]$OriginalIndex) {
    $before = 0
    for ($index = 0; $index -lt $Recording.turns.Count; $index++) {
        if ($null -ne $Recording.playbackIncluded -and -not $Recording.playbackIncluded[$index]) { continue }
        if ($index -ge $OriginalIndex) { break }
        $before++
    }
    return $before
}

$selectExchanges.Add_Click({
    try {
        if (-not $selectExchanges.IsEnabled) { return }
        $wasPaused = [bool]$script:ReplayProcessId
        $originalIndex = $script:lastView.originalIndex
        $script:pickerOpen = $true
        Update-ControllerSummaryLinks
        Cancel-AutoContinue -BlockCurrent
        if (Show-DemoExchangeSelection $window $script:selectedDemo.id) {
            if ($wasPaused) {
                if (-not $script:ReplayProcessId -or $script:lastView.action -ne 'resume' -or $script:actionTask) {
                    throw 'Selection was saved, but playback is no longer paused. Pause or reopen playback before applying the changed selection.'
                }
                $entry = Invoke-DemoLibrary @{ command = 'read'; id = $script:selectedDemo.id } $window
                if ($showOutput.IsChecked) {
                    $fitArea = Get-DemoSummaryWorkArea $script:overlayWindow
                    Assert-DemoSummaryPairs $entry.recording $script:overlayWindow.Width ($fitArea.Width - 32) ($fitArea.Height - 32)
                }
                $script:selectedDemo = Invoke-DemoLibrary @{ command = 'metadata'; id = $script:selectedDemo.id } $window
                $script:switchView = $script:lastView.PSObject.Copy()
                $script:switchView.resumeTurn = Get-ReselectionResumeTurn $entry.recording ([int]$originalIndex)
                $script:selectionResumePending = $true
                $script:switching = $true
                $script:deadline = [DateTime]::UtcNow.AddSeconds(15)
                $playPause.IsEnabled = $false
                $nextStep.IsEnabled = $false
                $status.Text = 'Preparing changed exchange selection'
                Send-Control 'stop'
            } else {
                $script:summaryStamp = $null
            }
        }
    } catch { Show-DemoError $window $_ }
    finally {
        $script:pickerOpen = $false
        if (-not $script:ReplayProcessId) { Refresh-ControllerSummaries }
        Update-ControllerSummaryLinks
    }
})

function Set-IdleView {
    if ($window -is [VibeReplay.ControllerWindow]) { $window.SetRecording($false) }
    if ($window.FindName('PlaybackProgress')) { $window.FindName('PlaybackProgress').Value = 0 }
    $script:selectionResumePending = $false
    Cancel-AutoContinue -ResetRun
    $script:lastView = $script:selectedDemo.presentation
    $status.Text = if ($script:lastFault) { 'Stopped: ' + $script:lastFault } elseif ($script:selectedDemo) { 'Selected - ' + $script:selectedDemo.count + ' exchanges' } else { 'Find an agent interaction to replay' }
    $status.ToolTip = $status.Text
    $chooseDemo.Content = if ($script:selectedDemo) { $script:selectedDemo.title } else { 'Find interaction...' }
    $chooseDemo.ToolTip = $chooseDemo.Content
    $playPause.IsEnabled = [bool]$script:selectedDemo
    $playPause.ToolTip = 'Open'
    $primaryLabel.Text = 'Open'
    [System.Windows.Automation.AutomationProperties]::SetName($playPause, 'Open')
    $playIcon.Text = [char]0xE8A7
    $nextStep.IsEnabled = $false
    $stop.IsEnabled = $false
    $window.FindName('ExitLabel').Visibility = 'Collapsed'
    $chooseDemo.IsEnabled = -not $script:pickerOpen
    $windowMode.IsEnabled = $true
    Update-ControllerSummaryLinks
    Update-ReplayOverlays
}

function Reset-ReplaySession {
    Cancel-AutoContinue -ResetRun
    if ($script:client) { $script:client.Dispose() }
    $script:client = $null
    $script:stateTask = $null
    $script:actionTask = $null
    $script:ReplayProcessId = 0
    $script:action = $null
    $script:stopping = $false
    $script:connectionStop = $false
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
    if ($window -is [VibeReplay.ControllerWindow]) { $window.SetRecording($true) }
    $script:launching = $true
    $status.Text = 'Validating selection and opening isolated playback...'
    try {
        $summaryArea = Get-DemoSummaryWorkArea $(if ($script:overlayWindow.IsVisible) { $script:overlayWindow } else { $window })
        $started = Invoke-DemoBackgroundOperation {
            param($Token, $Root, $Library, $Node, $Id, $Code, $Mode, $CheckFit, $FitWidth, $FitMaxWidth, $FitMaxHeight)
            . (Join-Path $Root 'DemoDialogs.ps1')
            $script:LibraryRoot = $Library
            $script:NodePath = $Node
            if (-not $Node) { . (Join-Path $Root 'PlayerEnvironment.ps1'); $script:NodePath = Resolve-PlayerNode }
            Invoke-DemoLibrary @{ command = 'metadata'; id = $Id } | Out-Null
            if ($CheckFit) {
                $entry = Invoke-DemoLibrary @{ command = 'read'; id = $Id }
                Assert-DemoSummaryPairs $entry.recording $FitWidth $FitMaxWidth $FitMaxHeight
            }
            $launchArguments = @{ DemoPath = (Join-Path $Library ($Id + '.demo.json')); NoController = $true; CodePath = $Code; WindowMode = $Mode }
            & (Join-Path $Root 'Start-Replay.ps1') @launchArguments
        } @($PSScriptRoot, $script:LibraryRoot, $script:NodePath, $script:selectedDemo.id, $script:CodePath, $script:replayMode,
            [bool]$showOutput.IsChecked, $script:overlayWindow.Width, ($summaryArea.Width - 32), ($summaryArea.Height - 32)) $window 'Opening isolated playback' -Cancellable $false
    } finally { $script:launching = $false }
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
    $windowMode.IsEnabled = $false
    Update-ControllerSummaryLinks
    if ($script:exitRequested) { Request-Stop }
}

$openLibrary = {
    if ($script:pickerOpen) { return }
    $script:pickerOpen = $true
    $chooseDemo.IsEnabled = $false
    Update-ControllerSummaryLinks
    try {
        $selected = Show-InteractionPicker $window
        if ($selected) { $script:selectedDemo = $selected }
        $script:summaryStamp = $null
        $script:summaryRefreshAt = [DateTime]::MinValue
        $script:lastFault = $null
        Set-IdleView
    } catch { Show-DemoError $window $_ }
    finally {
        $script:pickerOpen = $false
        $chooseDemo.IsEnabled = -not $script:ReplayProcessId
        Update-ControllerSummaryLinks
    }
}
$chooseDemo.Add_Click($openLibrary)

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

function Cancel-AutoContinue([switch]$BlockCurrent, [switch]$ResetRun) {
    if ($ResetRun) { $script:autoHandledKey = $null }
    if ($BlockCurrent -and $script:lastView.overlay.conversation.key) {
        $script:autoHandledKey = $script:lastView.overlay.conversation.key
    }
    $script:autoDeadline = $null
    $script:autoKey = $null
}

function Get-ReadingDwellSeconds([string]$Text) {
    return [Math]::Min(10, [Math]::Max(2, 1 + $Text.Length / 35.0))
}

function Get-EstimatedRunMilliseconds($Profile, [int]$Speed, [bool]$Auto, [bool]$Output, [bool]$Prompt) {
    $milliseconds = $Profile.count * (7000 - 59 * $Speed)
    if ($Auto -and $Output) {
        $milliseconds += $Profile.outputDwellMilliseconds * (1 - 0.008 * $Speed)
    }
    return $milliseconds
}

function Update-PlaybackEstimate {
    $speed = [int]$playbackSpeed.Value
    $speedLabel.Text = 'Speed: user {0:0.##}s / reply {1:0.##}s' -f (2 - 0.019 * $speed), (5 - 0.04 * $speed)
    $profile = $script:lastView.estimateProfile
    if ($null -eq $profile) { $runEstimate.Text = 'Estimated total: select an interaction'; return }
    $milliseconds = Get-EstimatedRunMilliseconds $profile $speed ([bool]$autoContinue.IsChecked) ([bool]$showOutput.IsChecked) ([bool]$showPrompt.IsChecked)
    $duration = [TimeSpan]::FromSeconds([Math]::Ceiling($milliseconds / 1000))
    $formatted = '{0:00}:{1:00}:{2:00}' -f [Math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds
    $runEstimate.Text = 'Estimated total: ' + $formatted + $(if ($autoContinue.IsChecked) { ' (auto)' } else { ' + manual waits' })
}

function Test-AutoContinueDue($View, [DateTime]$Now = [DateTime]::UtcNow) {
    if (-not $autoContinue.IsChecked -or $script:stopping -or $script:switching -or $script:pickerOpen -or $script:selectionResumePending -or
        -not $script:pairedVisible -or $View.phase -ne 'review' -or -not $View.nextEnabled) {
        Cancel-AutoContinue
        return $false
    }
    $key = [string]$View.overlay.conversation.key
    if (-not $key -or $key -ceq $script:autoHandledKey) { return $false }
    if ($key -cne $script:autoKey) {
        $script:autoKey = $key
        $text = if ($showOutput.IsChecked) { [string]$View.overlay.conversation.outputSummary } else { '' }
        if ($showOutput.IsChecked -and [string]::IsNullOrWhiteSpace($text)) { $text = $script:missingOutputSummary }
        $seconds = if ($showOutput.IsChecked) { (Get-ReadingDwellSeconds $text) * (1 - 0.008 * [int]$playbackSpeed.Value) } else { 0 }
        $script:autoDeadline = $Now.AddSeconds($seconds)
    }
    if ($script:actionTask -or $Now -lt $script:autoDeadline) { return $false }
    $script:autoHandledKey = $key
    Cancel-AutoContinue
    return $true
}

$autoContinue.Add_Unchecked({ Cancel-AutoContinue })
$autoContinue.Add_Checked({ Update-PlaybackEstimate })
$autoContinue.Add_Unchecked({ Update-PlaybackEstimate })
$showPrompt.Add_Checked({ Update-PlaybackEstimate })
$showPrompt.Add_Unchecked({ Update-PlaybackEstimate })
$showOutput.Add_Checked({ Cancel-AutoContinue; Update-PlaybackEstimate })
$showOutput.Add_Unchecked({ Cancel-AutoContinue; Update-PlaybackEstimate })

function Send-Control([string]$Action) {
    if (-not $Action.StartsWith('speed?')) { Cancel-AutoContinue -BlockCurrent }
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
    $script:launching = $true
    try {
        $launch = Invoke-DemoBackgroundOperation {
            param($Token, $Launcher, $LaunchArguments)
            & $Launcher @LaunchArguments
        } @((Join-Path $PSScriptRoot 'Start-Replay.ps1'), $arguments) $window ('Opening ' + $script:replayMode + ' playback') -Cancellable $false
    } finally { $script:launching = $false }
    $script:ControlPath = $launch.ControlPath
    $script:ReplayProcessId = $launch.ProcessId
    $script:stopSent = $false
    $script:pairedVisible = $false
    $script:preparedDeadline = [DateTime]::UtcNow.AddSeconds(45)
    $script:switching = $false
    $script:connectionFailures = 0
    $status.Text = 'Preparing ' + $script:replayMode
    if ($script:exitRequested) { Request-Stop }
}

$windowMode.Add_SelectionChanged({
    if ($script:modeUpdating -or $script:switching -or -not $windowMode.IsEnabled) { return }
    Cancel-AutoContinue -BlockCurrent
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
    param([switch]$ConnectionFailure)
    Cancel-AutoContinue -BlockCurrent
    if (-not $ReplayProcessId) { return }
    if ($script:stopping) { return }
    $script:stopping = $true
    $script:connectionStop = [bool]$ConnectionFailure
    $script:switching = $false
    $script:deadline = [DateTime]::UtcNow.AddSeconds(8)
    $status.Text = 'Stopping'
    $playPause.IsEnabled = $false
    $nextStep.IsEnabled = $false
    Update-ReplayOverlays
    Send-Control 'stop'
}

$playPause.Add_Click({
    Cancel-AutoContinue -BlockCurrent
    if ($script:standalone -and -not $ReplayProcessId) {
        try { Start-DemoReplay } catch {
            $script:lastFault = $_.Exception.Message
            Set-IdleView
            Show-DemoError $window $_
        }
        return
    }
    if ($script:action) {
        $script:selectionResumePending = $false
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
$stop.Add_Click({
    if ($script:lastView.phase -eq 'complete') { $script:exitRequested = $true }
    Request-Stop
})
$window.Add_Closing({
    param($sender, $eventArgs)
    if ($script:launching) {
        $eventArgs.Cancel = $true
        $script:exitRequested = $true
        $status.Text = 'Finishing launch before closing its isolated target...'
        return
    }
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
        if ($script:launching) { return }
        if (-not $ReplayProcessId -and [DateTime]::UtcNow -ge $script:summaryRefreshAt) {
            $script:summaryRefreshAt = [DateTime]::UtcNow.AddSeconds(2)
            Refresh-ControllerSummaries
        }
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
            $startupFailureToReport = -not $script:pairedVisible -and (-not $script:stopping -or $script:connectionStop)
            if (-not $script:stopping -or $script:connectionStop) {
                $connectionFailure = if ($script:connectionStop) { $script:lastFault } else { $null }
                $script:lastFault = if ($script:pairedVisible) { 'The isolated VS Code target closed.' } else { 'The isolated player exited before it was ready.' }
                if ($connectionFailure) { $script:lastFault += ' Control connection failed: ' + $connectionFailure }
            }
            Reset-ReplaySession
            if ($startupFailureToReport -and $script:standalone -and -not $script:exitRequested) {
                $failure = [Management.Automation.ErrorRecord]::new(
                    [InvalidOperationException]::new($script:lastFault),
                    'ReplayStartupFailed', [Management.Automation.ErrorCategory]::OpenError, $null)
                Show-DemoError $window $failure
            }
            return
        }
        if (-not $script:pairedVisible -and -not $script:stopping -and [DateTime]::UtcNow -gt $script:preparedDeadline) {
            $window.Show()
            $status.Text = 'Waiting for player readiness'
            $status.ToolTip = 'Startup is still in progress. Wait for readiness or use Stop to close only the isolated playback window.'
            $script:preparedDeadline = [DateTime]::MaxValue
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
            if ($window.FindName('PlaybackProgress') -and $view.total -gt 0) {
                $window.FindName('PlaybackProgress').Value = 100 * $view.current / $view.total
            }
            if ($view.phase -eq 'error') {
                $script:lastFault = if ($view.error) { $view.error } else { 'Recorded playback failed.' }
                $status.Text = 'Replay error: ' + $script:lastFault
                $status.ToolTip = $status.Text
            }
            $script:action = $view.action
            $stop.ToolTip = if ($view.phase -eq 'complete') { 'Exit and close playback windows' } else { 'Stop playback' }
            $window.FindName('ExitLabel').Visibility = if ($view.phase -eq 'complete') { 'Visible' } else { 'Collapsed' }
            [System.Windows.Automation.AutomationProperties]::SetName($stop, $(if ($view.phase -eq 'complete') { 'Exit' } else { 'Stop' }))
            $playPause.IsEnabled = [bool]$view.enabled -and -not $script:actionTask
            $nextStep.IsEnabled = [bool]$view.nextEnabled -and -not $script:actionTask
            $playPause.ToolTip = $view.button
            $primaryLabel.Text = $view.button
            [System.Windows.Automation.AutomationProperties]::SetName($playPause, $view.button)
            $playIcon.Text = switch ($view.button) {
                'Pause' { [char]0xE769 }
                'Start Over' { [char]0xE72C }
                'Replay' { [char]0xE72C }
                default { [char]0xE768 }
            }
            $script:lastView = $view
            if ($script:selectionResumePending) {
                if ($view.phase -in @('ready', 'review')) {
                    $script:action = if ($view.phase -eq 'ready') { 'play' } else { 'next' }
                    $primaryLabel.Text = 'Resume'
                    $playPause.ToolTip = 'Resume at the selected exchange'
                    [System.Windows.Automation.AutomationProperties]::SetName($playPause, 'Resume')
                    $nextStep.IsEnabled = $false
                } elseif ($view.phase -eq 'complete') { $script:selectionResumePending = $false }
            }
            Update-ControllerSummaryLinks
            $script:replayMode = $view.windowMode
            $script:modeUpdating = $true
            try { $windowMode.SelectedIndex = if ($view.windowMode -eq 'Agents') { 1 } else { 0 } } finally { $script:modeUpdating = $false }
            $windowMode.IsEnabled = [bool]$view.modeSwitchEnabled -and -not $script:actionTask
            Update-ReplayOverlays
            if (-not $script:actionTask -and $null -ne $view.timing -and [int]$view.timing.speed -ne [int]$playbackSpeed.Value) {
                Send-Control ('speed?value=' + [int]$playbackSpeed.Value)
            }
            if (Test-AutoContinueDue $view) {
                $playPause.IsEnabled = $false
                $nextStep.IsEnabled = $false
                Send-Control 'next'
            }
        }
        if ($script:client -and -not $script:stateTask) { $script:stateTask = $script:client.GetAsync('state') }
    } catch {
        Cancel-AutoContinue -BlockCurrent
        $script:connectionFailures++
        $script:lastFault = $_.Exception.Message
        $status.ToolTip = $_.Exception.Message
        $status.Text = if ($script:stopping) { 'Stopping' } else { 'Connection unavailable' }
        $script:stateTask = $null
        $script:actionTask = $null
        $playPause.IsEnabled = $false
        $nextStep.IsEnabled = $false
    }
})
$window.Add_Closed({
    $timer.Stop()
    $script:updateTimer.Stop()
    try { Stop-PlayerUpdateOperation } catch { Set-PlayerUpdateFailure $_ }
    $script:closeAllowed = $true
    $script:overlayWindow.Close()
    if ($script:client) { $script:client.Dispose() }
    [VibeReplay.LibraryConnections]::Close()
})
$application = [System.Windows.Application]::new()
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$application.MainWindow = $window
Initialize-PlayerUpdates
if ($DemoId) {
    if (-not $script:standalone) { throw 'DemoId is available only in standalone mode.' }
    $script:selectedDemo = Invoke-DemoLibrary @{ command = 'metadata'; id = $DemoId }
}
if ($script:standalone) { Set-IdleView; $window.Show() }
else {
    $chooseDemo.IsEnabled = $false
    $chooseDemo.Content = 'Selected transcript'
}
$timer.Start()
$application.Run() | Out-Null
Start-PlayerUpdateHandoff