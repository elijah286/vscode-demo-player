function Set-PlayerUpdateView {
    $state = $script:playerUpdate
    $updateNotice.Text = 'v' + $state.Version + ' | ' + $state.Notice
    $updateNotice.ToolTip = $state.Detail
    if ($state.Dialog) {
        $state.Dialog.FindName('CurrentVersion').Text = $state.Version
        $state.Dialog.FindName('LatestVersion').Text = $state.Latest
        $state.Dialog.FindName('UpdateStatus').Text = $state.Detail
        $state.Dialog.FindName('RetryUpdate').IsEnabled = -not $state.Process -and -not $state.Pending
        $state.Dialog.FindName('InstallUpdate').IsEnabled = $state.Installed -and $state.Result -and $state.Result.updateAvailable -and -not $state.Process -and -not $state.Pending
    }
}

function Stop-PlayerUpdateOperation {
    $state = $script:playerUpdate
    if ($state.Process) {
        try {
            if (-not $state.Process.HasExited) {
                $state.Process.Kill()
                if (-not $state.Process.WaitForExit(2000)) { throw 'The update helper did not exit after cancellation.' }
            }
        } finally { $state.Process.Dispose(); $state.Process = $null }
    }
    if ($state.Directory -and -not $state.Pending -and (Test-Path -LiteralPath $state.Directory)) {
        $cleanup = [Diagnostics.ProcessStartInfo]::new()
        $cleanup.FileName = Resolve-PlayerNode $script:NodePath
        $cleanup.Arguments = '-e "require(''node:fs'').rmSync(process.argv[1],{recursive:true,force:true})" "' + $state.Directory + '"'
        $cleanup.UseShellExecute = $false
        $cleanup.CreateNoWindow = $true
        $cleanup.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($cleanup)
        if (-not $process) { throw 'The canceled-download cleanup helper could not start.' }
        try {
            $errors = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(5000)) {
                $process.Kill()
                if (-not $process.WaitForExit(2000)) { throw 'The canceled-download cleanup helper did not exit after its time limit.' }
                throw 'Canceled-download cleanup exceeded five seconds.'
            }
            if (-not $errors.Wait(2000)) { throw 'Timed out reading canceled-download cleanup errors.' }
            if ($process.ExitCode -ne 0) { throw ('Canceled-download cleanup failed: ' + $errors.GetAwaiter().GetResult()) }
        } finally { $process.Dispose() }
    }
}

function Start-PlayerUpdateOperation([string]$Command) {
    $state = $script:playerUpdate
    if ($state.Process -or $state.Pending) { return }
    $request = @{ command = $Command; currentVersion = $state.Version }
    if ($Command -eq 'download') {
        $state.Directory = Join-Path $env:LOCALAPPDATA ('VSCodeDemoPlayer\updates\pending-' + [guid]::NewGuid().ToString('N'))
        $request.directory = $state.Directory
        $request.version = $state.Result.latestVersion
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Resolve-PlayerNode $script:NodePath
    $start.Arguments = '"' + (Join-Path $PSScriptRoot 'native\updater.js') + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    $state.Process = [Diagnostics.Process]::Start($start)
    if (-not $state.Process) { throw 'The update helper could not start.' }
    $state.Output = $state.Process.StandardOutput.ReadToEndAsync()
    $state.Errors = $state.Process.StandardError.ReadToEndAsync()
    $state.Process.StandardInput.Write(($request | ConvertTo-Json -Compress))
    $state.Process.StandardInput.Close()
    $state.Command = $Command
    $state.Deadline = [DateTime]::UtcNow.AddSeconds($(if ($Command -eq 'check') { 30 } else { 180 }))
    $state.Notice = if ($Command -eq 'check') { 'Checking updates...' } else { 'Downloading update...' }
    $state.Detail = if ($Command -eq 'check') { 'Checking the latest public GitHub release. Playback remains available.' } else { 'Downloading and verifying the installer. Close this update window to cancel the download.' }
    Set-PlayerUpdateView
}

function Set-PlayerUpdateFailure($Failure) {
    $state = $script:playerUpdate
    $message = $Failure.Exception.Message
    try { Stop-PlayerUpdateOperation } catch { $message += ' Cleanup: ' + $_.Exception.Message }
    $state.Result = $null
    $state.Notice = if ($state.Command -eq 'download') { 'Update download failed' } else { 'Update check failed' }
    $state.Detail = $message
    try {
        $root = Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'last-update-error.log'), ([DateTime]::UtcNow.ToString('o') + "`r`n" + $message))
    } catch { $state.Detail += ' Logging: ' + $_.Exception.Message }
    Set-PlayerUpdateView
}

function Receive-PlayerUpdateOperation {
    $state = $script:playerUpdate
    if (-not $state.Process) { return }
    try {
        if ([DateTime]::UtcNow -gt $state.Deadline) { throw 'The update operation exceeded its time limit. Try again later.' }
        if (-not $state.Process.HasExited) { return }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($state.Output, $state.Errors), 2000)) { throw 'Timed out reading the update helper result.' }
        $response = $state.Output.GetAwaiter().GetResult() | ConvertFrom-Json
        if (-not $response -or -not $response.ok -or $state.Process.ExitCode -ne 0) {
            $reason = if ($response.error) { $response.error } else { $state.Errors.GetAwaiter().GetResult() }
            throw ('Update operation failed: ' + $reason)
        }
        $state.Process.Dispose()
        $state.Process = $null
        if ($state.Command -eq 'check') {
            $state.Result = $response.result
            $state.Latest = $response.result.latestVersion
            $state.Notice = if ($response.result.updateAvailable) { 'Update ' + $state.Latest + ' available' } elseif ($response.result.installedIsNewer) { 'Newer than public release' } else { 'Up to date' }
            $state.Detail = if ($response.result.updateAvailable) { 'A newer version is available. Install only when you are ready to stop playback and restart Demo Player.' } elseif ($response.result.installedIsNewer) { 'Your installed version is newer than the latest stable GitHub release. No downgrade will be offered.' } else { 'You have the latest stable release.' }
            if (-not $state.Installed) { $state.Detail += ' Running from source: use the Windows installer to enable in-app installation.' }
        } else {
            $ready = $response.result
            if ($ready.directory -ine $state.Directory -or $ready.installerPath -ine (Join-Path $state.Directory 'VSCodeDemoPlayer-Setup.exe') -or $ready.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid verified-installer response.' }
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-PlayerUpdate.ps1') -Destination (Join-Path $state.Directory 'Install-PlayerUpdate.ps1')
            $job = @{
                installerPath = $ready.installerPath; sha256 = $ready.sha256; version = $ready.version
                installRoot = $PSScriptRoot; parentId = $PID
                libraryRoot = $script:LibraryRoot; codePath = (Resolve-PlayerVSCode $script:CodePath)
            }
            $jobPath = Join-Path $state.Directory 'install-job.json'
            [IO.File]::WriteAllText($jobPath, ($job | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            $state.Pending = $jobPath
            $state.Notice = 'Stopping for update...'
            $state.Detail = 'The installer is verified. Waiting for this app and its own playback window to close before installing.'
            $script:exitRequested = $true
            if ($ReplayProcessId) { Request-Stop }
            else { $script:closeAllowed = $true; $window.Close() }
        }
        Set-PlayerUpdateView
    } catch { Set-PlayerUpdateFailure $_ }
}

function Show-PlayerUpdateDialog {
    $state = $script:playerUpdate
    if ($state.Dialog) { $state.Dialog.Activate() | Out-Null; return }
    $dialog = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
 xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Demo Player Updates"
 Width="480" Height="290" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
 <Grid Margin="18">
  <Grid.RowDefinitions><RowDefinition Height="30"/><RowDefinition Height="30"/><RowDefinition Height="*"/><RowDefinition Height="36"/></Grid.RowDefinitions>
  <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
  <TextBlock Text="Installed version:"/><TextBlock x:Name="CurrentVersion" Grid.Column="1" FontWeight="SemiBold" AutomationProperties.AutomationId="CurrentVersion"/>
  <TextBlock Text="Latest available version:" Grid.Row="1"/><TextBlock x:Name="LatestVersion" Grid.Row="1" Grid.Column="1" FontWeight="SemiBold" AutomationProperties.AutomationId="LatestVersion"/>
  <TextBlock x:Name="UpdateStatus" Grid.Row="2" Grid.ColumnSpan="2" TextWrapping="Wrap" Margin="0,12,0,12" AutomationProperties.AutomationId="UpdateStatus"/>
  <Button x:Name="RetryUpdate" Grid.Row="3" Content="Check again" Margin="0,0,12,0" AutomationProperties.AutomationId="RetryUpdate"/>
  <Button x:Name="InstallUpdate" Grid.Row="3" Grid.Column="1" Content="Install update..." IsEnabled="False" AutomationProperties.AutomationId="InstallUpdate"/>
 </Grid>
</Window>
'@ $window
    $state.Dialog = $dialog
    $dialog.FindName('RetryUpdate').Add_Click({
        try { Start-PlayerUpdateOperation 'check' } catch { Set-PlayerUpdateFailure $_ }
    })
    $dialog.FindName('InstallUpdate').Add_Click({
        $answer = [Windows.MessageBox]::Show($script:playerUpdate.Dialog, ('Install version ' + $script:playerUpdate.Result.latestVersion + "?`r`n`r`nDemo Player will download and verify the installer, stop its own playback, install, and restart. Your demo library is preserved."), 'Install Demo Player update?', 'YesNo', 'Question', 'No')
        if ($answer -eq 'Yes') {
            try { Start-PlayerUpdateOperation 'download' } catch { Set-PlayerUpdateFailure $_ }
        }
    })
    $dialog.Add_Closed({
        $script:playerUpdate.Dialog = $null
        if ($script:playerUpdate.Command -eq 'download' -and $script:playerUpdate.Process -and -not $script:playerUpdate.Pending) {
            try {
                Stop-PlayerUpdateOperation
                $script:playerUpdate.Notice = 'Download canceled'
                $script:playerUpdate.Detail = 'The update download was canceled. The current application was not changed.'
                Set-PlayerUpdateView
            } catch { Set-PlayerUpdateFailure $_ }
        }
    })
    Set-PlayerUpdateView
    $dialog.Show()
    try { Start-PlayerUpdateOperation 'check' } catch { Set-PlayerUpdateFailure $_ }
}

function Initialize-PlayerUpdates {
    $metadata = Join-Path $PSScriptRoot 'build-info.json'
    $installed = (Test-Path -LiteralPath $metadata -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'VSCodeDemoPlayer.exe') -PathType Leaf) -and $script:standalone
    $versionFile = if ($installed) { $metadata } else { Join-Path $PSScriptRoot 'native\package.json' }
    $version = ([IO.File]::ReadAllText($versionFile) | ConvertFrom-Json).version
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'The application version is missing or invalid.' }
    $script:playerUpdate = @{
        Version = $version; Latest = 'Not checked'; Notice = 'Not checked'; Detail = 'Check GitHub for a stable release.'
        Installed = $installed; Process = $null; Pending = $null; Result = $null; Dialog = $null; Directory = $null
    }
    $checkUpdates.Add_Click({
        try { Show-PlayerUpdateDialog }
        catch { Set-PlayerUpdateFailure $_; Show-DemoError $window $_ }
    })
    $script:updateTimer = [Windows.Threading.DispatcherTimer]::new()
    $script:updateTimer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:updateTimer.Add_Tick({ Receive-PlayerUpdateOperation })
    $script:updateTimer.Start()
    Set-PlayerUpdateView
    if ($installed) {
        try { Start-PlayerUpdateOperation 'check' } catch { Set-PlayerUpdateFailure $_ }
    }
}

function Start-PlayerUpdateHandoff {
    if (-not $script:playerUpdate.Pending) { return }
    $job = $script:playerUpdate.Pending
    $runner = Join-Path (Split-Path $job -Parent) 'Install-PlayerUpdate.ps1'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $runner + '" -JobPath "' + $job + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    if (-not $process) { throw 'The verified update installer could not be started. The current installation was not replaced.' }
    $process.Dispose()
}
