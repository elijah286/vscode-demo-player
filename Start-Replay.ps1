param(
    [string]$SessionPath,
    [ValidateRange(0, 100)]
    [int]$RequestIndex = 0,
    [ValidateRange(1, 100)]
    [int]$RequestCount = 1,
    [string]$PlaylistPath,
    [string]$DemoPath,
    [switch]$NoController,
    [string]$ExtensionPath,
    [string]$CodePath,
    [ValidateSet('Editor', 'Agents')]
    [string]$WindowMode = 'Editor',
    [string]$UserDataPath,
    [ValidateRange(0, 100)]
    [int]$ResumeTurn = 0,
    [ValidateRange(0, 65535)]
    [int]$RemoteDebuggingPort = 0
)

$ErrorActionPreference = 'Stop'
if (@(@($SessionPath, $PlaylistPath, $DemoPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne 1) {
    throw 'Specify exactly one of SessionPath, PlaylistPath, or DemoPath.'
}
$source = if ($SessionPath) { (Resolve-Path -LiteralPath $SessionPath).Path } else { '' }
if (-not $ExtensionPath) {
    if (-not $PSScriptRoot) { throw 'Pass ExtensionPath when invoking this launcher as a script block.' }
    $ExtensionPath = Join-Path $PSScriptRoot 'native'
}
$extension = (Resolve-Path -LiteralPath $ExtensionPath).Path
if ($PlaylistPath) { $PlaylistPath = (Resolve-Path -LiteralPath $PlaylistPath).Path }
if ($DemoPath) { $DemoPath = (Resolve-Path -LiteralPath $DemoPath).Path }
$controllerScript = Join-Path ([System.IO.Path]::GetDirectoryName($extension)) 'Show-ReplayController.ps1'
if (-not (Test-Path -LiteralPath $controllerScript)) { throw 'The replay controller script was not found.' }
. (Join-Path $PSScriptRoot 'PlayerEnvironment.ps1')
$code = Resolve-PlayerVSCode $CodePath
Assert-PlayerVSCodeLaunchAvailable
$profile = if ($UserDataPath) { [System.IO.Path]::GetFullPath($UserDataPath) } else { Join-Path ([System.IO.Path]::GetTempPath()) ('historical-replay-player-' + [guid]::NewGuid().ToString('N')) }
$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
if ([System.IO.Path]::GetDirectoryName($profile) -ine $temporaryRoot -or [System.IO.Path]::GetFileName($profile) -notmatch '^historical-replay-(player|agents)-[a-f0-9]{32}$') {
    throw 'Use a dedicated temporary replay profile, never the normal editor profile.'
}
$existing = Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object {
    $_.CommandLine -and $_.CommandLine.IndexOf($profile, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
    $_.CommandLine -like '*--user-data-dir*' -and $_.CommandLine -notlike '*--type=*'
}
if ($existing) { throw 'This dedicated replay profile is already open. Close its window normally before launching a new paired controller.' }
[System.IO.Directory]::CreateDirectory($profile) | Out-Null
$controlPath = Join-Path $profile ('replay-control-' + [guid]::NewGuid().ToString('N') + '.json')
$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = $code
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$arguments = @(
    '--new-window',
    '--user-data-dir', ('"' + $profile + '"'),
    '--extensions-dir', ('"' + (Join-Path $profile 'extensions') + '"'),
    ('--extensionDevelopmentPath="' + $extension + '"'),
    '--enable-proposed-api=local.historical-transcript-replay',
    '--disable-workspace-trust',
    '--skip-welcome',
    '--skip-release-notes',
    '--disable-telemetry'
)
if (-not $RemoteDebuggingPort) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { $RemoteDebuggingPort = $listener.LocalEndpoint.Port } finally { $listener.Stop() }
}
if ($WindowMode -eq 'Agents') { $arguments += '--agents' }
else { $arguments += @('--disable-extensions', '--disable-extension=github.copilot-chat', '--disable-extension=github.copilot') }
if ($RemoteDebuggingPort) { $arguments += @('--remote-debugging-address=127.0.0.1', ('--remote-debugging-port=' + $RemoteDebuggingPort)) }
$start.Arguments = $arguments -join ' '
$start.EnvironmentVariables.Remove('ELECTRON_RUN_AS_NODE')
$start.EnvironmentVariables.Remove('HISTORY_REPLAY_SUMMARY_ENTRY')
$start.EnvironmentVariables['HISTORY_REPLAY_FILE'] = $source
$start.EnvironmentVariables['HISTORY_REPLAY_REQUEST'] = [string]$RequestIndex
$start.EnvironmentVariables['HISTORY_REPLAY_REQUEST_COUNT'] = [string]$RequestCount
$start.EnvironmentVariables['HISTORY_REPLAY_CONTROL_PATH'] = $controlPath
$start.EnvironmentVariables['HISTORY_REPLAY_AGENTS'] = if ($WindowMode -eq 'Agents') { '1' } else { '0' }
$start.EnvironmentVariables['HISTORY_REPLAY_CDP_PORT'] = [string]$RemoteDebuggingPort
$start.EnvironmentVariables['HISTORY_REPLAY_RESUME_TURN'] = [string]$ResumeTurn
if ($PlaylistPath) { $start.EnvironmentVariables['HISTORY_REPLAY_PLAYLIST'] = $PlaylistPath }
else { $start.EnvironmentVariables.Remove('HISTORY_REPLAY_PLAYLIST') }
if ($DemoPath) { $start.EnvironmentVariables['HISTORY_REPLAY_DEMO'] = $DemoPath }
else { $start.EnvironmentVariables.Remove('HISTORY_REPLAY_DEMO') }
$process = [System.Diagnostics.Process]::Start($start)
if ($null -eq $process) { throw 'The isolated replay window could not be started.' }
$process.StandardInput.Close()
$null = $process.StandardOutput.BaseStream.CopyToAsync([System.IO.Stream]::Null)
$null = $process.StandardError.BaseStream.CopyToAsync([System.IO.Stream]::Null)
$controllerProcess = $null
if (-not $NoController) {
$controllerStart = [System.Diagnostics.ProcessStartInfo]::new()
$controllerStart.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$controllerStart.UseShellExecute = $false
$controllerStart.CreateNoWindow = $true
$controllerStart.Arguments = @(
    '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + $controllerScript + '"'),
    '-ControlPath', ('"' + $controlPath + '"'),
    '-ProfilePath', ('"' + $profile + '"'),
    '-ReplayProcessId', [string]$process.Id
) -join ' '
$controllerProcess = [System.Diagnostics.Process]::Start($controllerStart)
if ($null -eq $controllerProcess) { throw 'The replay controller could not be started. Close the isolated replay window normally.' }
}
[pscustomobject]@{
    ProcessId = $process.Id
    ControllerProcessId = if ($controllerProcess) { $controllerProcess.Id } else { $null }
    ProfilePath = $profile
    ControlPath = $controlPath
    WindowMode = $WindowMode
    RemoteDebuggingPort = $RemoteDebuggingPort
    Controller = 'Play/Pause and Stop in the separate Replay Control window'
    StartReplay = 'Ctrl+Alt+R'
    PauseResume = 'Ctrl+Alt+P'
    Step = 'Ctrl+Alt+Right'
    Stop = 'Ctrl+Alt+S'
    RequestIndex = $RequestIndex
    RequestCount = $RequestCount
    PlaylistPath = $PlaylistPath
    DemoPath = $DemoPath
    PromptMilliseconds = 2000
    ResponseMilliseconds = 5000
}