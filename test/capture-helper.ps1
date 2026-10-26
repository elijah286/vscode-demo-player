param(
    [Parameter(Mandatory = $true)][string]$NodePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('capture-helper-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $scratch 'native')) | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'DemoDialogs.ps1') -Destination $scratch
Copy-Item -LiteralPath (Join-Path $root 'DialogTheme.xaml') -Destination $scratch
Copy-Item -LiteralPath (Join-Path $root 'SummaryPresentation.ps1') -Destination $scratch
foreach ($file in @('PlayerShell.ps1', 'PlayerShell.cs')) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination $scratch }
$helper = @'
let input = '';
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
    const request = JSON.parse(input.replace(/^\uFEFF/, ''));
    setTimeout(() => {
        const failed = request.command === 'failure';
        process.stdout.write(JSON.stringify(failed
            ? { ok: false, error: 'Synthetic helper failure' }
            : { ok: true, result: { title: 'Synthetic result' } }));
        process.exitCode = failed ? 1 : 0;
    }, 400);
});
'@
[IO.File]::WriteAllText((Join-Path $scratch 'native\library-cli.js'), $helper)
$owner = [System.Windows.Window]::new()
$heartbeat = [System.Windows.Threading.DispatcherTimer]::new()
$heartbeat.Interval = [TimeSpan]::FromMilliseconds(20)
$script:ticks = 0
$script:disabledTicks = 0
$heartbeat.Add_Tick({
    $script:ticks++
    if ($owner.IsEnabled -and $owner.Resources.Contains('DemoPlayerOperation') -and
        -not $owner.FindName('Load').IsEnabled -and -not $owner.FindName('Summary').IsEnabled -and -not $owner.FindName('Exchange').IsEnabled) { $script:disabledTicks++ }
})
try {
    . (Join-Path $scratch 'DemoDialogs.ps1')
    $owner = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
 <StackPanel><Button x:Name="Load"/><CheckBox x:Name="ShowPrompt"/><TextBox x:Name="SavedSearch"/><TextBox x:Name="Summary"/><ComboBox x:Name="Exchange"/></StackPanel>
</Window>
'@ $null
    $script:NodePath = (Resolve-Path -LiteralPath $NodePath).Path
    $script:LibraryRoot = Join-Path $scratch 'library'
    $heartbeat.Start()
    # The delayed fixture alone cannot catch failures in the shipped CLI or large pipe output.
    Copy-Item -Path (Join-Path $root 'native\*.js') -Destination (Join-Path $scratch 'native') -Force
    $source = Join-Path $scratch 'synthetic.jsonl'
    $answer = 'Saved response ' * 100000
    $snapshot = @{ kind = 0; v = @{ sessionId = 'synthetic'; customTitle = 'Synthetic conversation'; requests = @(
        @{ result = @{}; message = @{ text = 'Synthetic prompt' }; response = @(@{ value = $answer }) }
    ) } }
    [IO.File]::WriteAllText($source, ($snapshot | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    $inspection = Invoke-DemoLibrary @{ command = 'inspect'; file = $source } $owner
    if ($inspection.turns.Count -ne 1 -or -not $inspection.turns[0].content.EndsWith($answer)) { throw 'Actual inspection lost saved response content.' }
    $saved = Invoke-DemoLibrary @{ command = 'capture'; file = $source; indices = @(0); title = 'Synthetic demo'; sha256 = $inspection.sha256 } $owner
    $entry = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id } $owner
    if ($entry.recording.turns[0].snapshot.requests[0].response[0].value -ne $answer) { throw 'Actual library read lost saved response content.' }
    $metadata = Invoke-DemoLibrary @{ command = 'metadata'; id = $saved.id } $owner
    if ($metadata.id -ne $saved.id -or $metadata.ContainsKey('recording')) { throw 'Actual metadata transported the recording or lost selection identity.' }
    $previousContext = [Threading.SynchronizationContext]::Current
    try {
        [Threading.SynchronizationContext]::SetSynchronizationContext([Windows.Threading.DispatcherSynchronizationContext]::new())
        $readResults = @(Invoke-DemoLibrary @{ command = 'read'; id = $saved.id })
        if ($readResults.Count -ne 1) { throw 'A no-owner read emitted values other than its single response.' }
        $entry = $readResults[0]
        if ($entry.recording.turns[0].snapshot.requests[0].response[0].value -ne $answer) { throw 'Dispatcher library read lost saved response content.' }
    } finally { [Threading.SynchronizationContext]::SetSynchronizationContext($previousContext) }
    $listed = @(Invoke-DemoLibrary @{ command = 'list' } $owner)
    if ($listed.Count -ne 1 -or $listed[0].id -ne $saved.id) { throw 'Actual list did not return the captured entry.' }
    $listed = @(Invoke-DemoLibrary @{ command = 'list' })
    if ($listed.Count -ne 1 -or $listed[0].id -ne $saved.id) { throw 'A no-owner list emitted values other than its captured entry.' }
    $renamed = Invoke-DemoLibrary @{ command = 'rename'; id = $saved.id; title = 'Renamed synthetic demo' } $owner
    if ($renamed.title -ne 'Renamed synthetic demo') { throw 'Actual rename was not confirmed.' }
    Invoke-DemoLibrary @{ command = 'summaries'; id = $saved.id; summaries = @('Synthetic reviewed summary'); expected = $null } $owner | Out-Null
    $export = Join-Path $scratch 'synthetic.demo-recording.json'
    Invoke-DemoLibrary @{ command = 'export'; id = $saved.id; file = $export } $owner | Out-Null
    $originalLibrary = $script:LibraryRoot
    $script:LibraryRoot = Join-Path $scratch 'import-library'
    try {
        $imported = Invoke-DemoLibrary @{ command = 'import'; file = $export } $owner
        if ($imported.presentation.overlay.promptSummary -ne 'Synthetic reviewed summary') { throw 'Actual import/export lost reviewed summaries.' }
        Invoke-DemoLibrary @{ command = 'delete'; id = $imported.id } $owner | Out-Null
        if (@(Invoke-DemoLibrary @{ command = 'list' } $owner).Count) { throw 'Actual delete did not remove the imported entry.' }
        if (@(Invoke-DemoLibrary @{ command = 'list' }).Count) { throw 'An empty no-owner list emitted an unexpected result.' }
    } finally { $script:LibraryRoot = $originalLibrary }
    $storage = Join-Path $scratch 'workspaceStorage'
    $workspace = Join-Path $storage ('a' * 32)
    $sessions = Join-Path $workspace 'chatSessions'
    $project = Join-Path $scratch 'project'
    [IO.Directory]::CreateDirectory($sessions) | Out-Null
    [IO.Directory]::CreateDirectory($project) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'workspace.json'), (@{ folder = $project } | ConvertTo-Json -Compress))
    Copy-Item -LiteralPath $source -Destination (Join-Path $sessions 'synthetic.jsonl')
    $discovery = Invoke-DemoLibrary @{ command = 'discover'; storageRoot = $storage; folder = $project } $owner
    if ($discovery.sessions.Count -ne 1) { throw 'Actual discover did not return the synthetic workspace recording.' }
    $history = Invoke-DemoLibrary @{ command = 'history'; appData = (Join-Path $scratch 'appdata'); home = (Join-Path $scratch 'home'); locations = @($sessions) } $owner
    if ($history.sessions.Count -ne 1) { throw 'Actual history did not return the isolated recording.' }
    [IO.File]::WriteAllText((Join-Path $scratch 'native\library-cli.js'), $helper)
    $script:ticks = 0
    $script:disabledTicks = 0
    $result = Invoke-DemoLibrary @{ command = 'success' } $owner
    if ($result.title -ne 'Synthetic result') { throw 'The helper did not return the expected result.' }
    if ($script:ticks -lt 3 -or $script:disabledTicks -lt 3) { throw 'The dialog did not process window events with only conflicting actions disabled while loading.' }
    if (-not $owner.FindName('ShowPrompt').IsEnabled -or -not $owner.FindName('SavedSearch').IsEnabled) { throw 'Background reads disabled independent presentation/search controls.' }
    if (-not $owner.IsEnabled -or $owner.Cursor) { throw 'The dialog did not restore its enabled state and cursor after loading.' }
    foreach ($command in @('failure')) {
        $expected = 'Synthetic helper failure'
        try { Invoke-DemoLibrary @{ command = $command } $owner; throw 'Expected helper failure.' }
        catch { if ($_.Exception.Message -notmatch $expected) { throw } }
        if (-not $owner.IsEnabled -or $owner.Cursor) { throw 'The dialog did not restore its enabled state and cursor after a helper error.' }
    }
    Write-Output 'CAPTURE HELPER PASSED: all 12 real CLI commands preserve isolated recording/summary payloads; reads work with and without a WPF owner; only conflicting actions are disabled, independent controls remain available, errors propagate, and owner state is restored.'
} finally {
    $heartbeat.Stop()
    $owner.Close()
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
