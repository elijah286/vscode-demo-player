param(
    [Parameter(Mandatory = $true)][string]$NodePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('capture-helper-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $scratch 'native')) | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'DemoDialogs.ps1') -Destination $scratch
$helper = @'
let input = '';
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
    const request = JSON.parse(input);
    if (request.command === 'timeout') return setTimeout(() => {}, 60000);
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
    if (-not $owner.IsEnabled) { $script:disabledTicks++ }
})
try {
    . (Join-Path $scratch 'DemoDialogs.ps1')
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
    $previousContext = [Threading.SynchronizationContext]::Current
    try {
        [Threading.SynchronizationContext]::SetSynchronizationContext([Windows.Threading.DispatcherSynchronizationContext]::new())
        $entry = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id }
        if ($entry.recording.turns[0].snapshot.requests[0].response[0].value -ne $answer) { throw 'Dispatcher library read lost saved response content.' }
    } finally { [Threading.SynchronizationContext]::SetSynchronizationContext($previousContext) }
    [IO.File]::WriteAllText((Join-Path $scratch 'native\library-cli.js'), $helper)
    $script:ticks = 0
    $script:disabledTicks = 0
    $result = Invoke-DemoLibrary @{ command = 'success' } $owner
    if ($result.title -ne 'Synthetic result') { throw 'The helper did not return the expected result.' }
    if ($script:ticks -lt 3 -or $script:disabledTicks -lt 3) { throw 'The dialog did not process window events with controls disabled while loading.' }
    if (-not $owner.IsEnabled -or $owner.Cursor) { throw 'The dialog did not restore its enabled state and cursor after loading.' }
    foreach ($command in @('failure', 'timeout')) {
        $expected = if ($command -eq 'failure') { 'Synthetic helper failure' } else { 'exceeded 30 seconds' }
        try { Invoke-DemoLibrary @{ command = $command } $owner; throw 'Expected helper failure.' }
        catch { if ($_.Exception.Message -notmatch $expected) { throw } }
        if (-not $owner.IsEnabled -or $owner.Cursor) { throw 'The dialog did not restore its enabled state and cursor after a helper error.' }
    }
    Write-Output 'CAPTURE HELPER PASSED: real inspect/capture/read preserve large payloads with and without a WPF owner; dispatcher remains responsive, reentrant controls are disabled, results/errors propagate, 30-second timeout is enforced, and owner state is restored.'
} finally {
    $heartbeat.Stop()
    $owner.Close()
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
