param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [string]$ApplicationRoot
)
$ErrorActionPreference = 'Stop'
$root = if ($ApplicationRoot) { (Resolve-Path -LiteralPath $ApplicationRoot).Path } else { Split-Path $PSScriptRoot -Parent }
. (Join-Path $root 'DemoDialogs.ps1')
$script:NodePath = (Resolve-Path -LiteralPath $NodePath).Path
$script:LibraryRoot = Join-Path ([IO.Path]::GetTempPath()) ('vibereplay-worker-' + [guid]::NewGuid().ToString('N'))
$script:PersistentLibrary = $true
$inputEncoding = [Console]::InputEncoding
$assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
try {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($true)
    $first = @(Invoke-DemoLibrary @{ command = 'list' })
    Assert ($first.Count -eq 0) 'Empty library list must remain empty.'
    $worker = [VibeReplay.LibraryConnections]::Get($script:NodePath, (Join-Path $root 'native\library-worker.js'), $script:LibraryRoot)
    $workerId = $worker.ProcessId
    $null = Invoke-DemoLibrary @{ command = 'list' }
    Assert ($worker.ProcessId -eq $workerId -and $worker.IsAlive) 'Queries must reuse the live worker.'
    $failed = $false
    try { Invoke-DemoLibrary @{ command = 'unknown' } | Out-Null } catch { $failed = $_.Exception.Message -match 'Unknown demo library command' }
    Assert $failed 'Engine errors must not become empty successful results.'
    $null = Invoke-DemoLibrary @{ command = 'list' }
    Assert $worker.IsAlive 'A command error must not break subsequent requests.'
    $owner = [VibeReplay.ControllerWindow]::new()
    try {
        $result = @(Invoke-DemoLibrary @{ command = 'list' } $owner)
        Assert ($result.Count -eq 0) 'Inline controller operations must return the actual empty result.'
        Assert ($owner.FindName('OperationPanel').Visibility -eq 'Collapsed') 'Inline activity must close without another dialog.'
        Assert (-not $owner.Resources.Contains('DemoPlayerOperation')) 'Inline operation must clear its reentrancy guard.'
    } finally { $owner.Close() }
    [VibeReplay.LibraryConnections]::Close()
    Assert (-not (Get-Process -Id $workerId -ErrorAction SilentlyContinue)) 'Closing the controller must stop its own worker.'
    [IO.Directory]::CreateDirectory($script:LibraryRoot) | Out-Null
    $slow = Join-Path $script:LibraryRoot 'slow.js'
    [IO.File]::WriteAllText($slow, @'
const readline = require('node:readline');
readline.createInterface({ input: process.stdin }).on('line', line => {
    const packet = JSON.parse(line.replace(/^\uFEFF/, ''));
    setTimeout(() => process.stdout.write(JSON.stringify({ version: 1, id: packet.id, ok: true, result: packet.request.text }) + '\n'), 32000);
});
'@)
    $connection = [VibeReplay.LibraryConnection]::new($script:NodePath, $slow, $script:LibraryRoot)
    try {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $unicode = (-join @([char]0x4E2D, [char]0x6587)) + [char]::ConvertFromUtf32(0x1F642)
        $reply = [DemoLibraryJson]::Parse($connection.Request((@{ text = $unicode } | ConvertTo-Json -Compress), [Threading.CancellationToken]::None))
        Assert ($clock.ElapsedMilliseconds -ge 32000) 'Persistent work must complete beyond the former 30-second cutoff.'
        Assert ($reply.result -ceq $unicode) 'Persistent requests and responses must preserve Chinese and supplementary Unicode, independent of the console code page.'
        Assert $connection.IsAlive 'Completing a slow request must retain the reusable worker.'
    } finally { $connection.Dispose() }
    $blocked = Join-Path $script:LibraryRoot 'blocked.js'
    [IO.File]::WriteAllText($blocked, "process.stdin.resume(); setInterval(() => {}, 1000);")
    $connection = [VibeReplay.LibraryConnection]::new($script:NodePath, $blocked, $script:LibraryRoot)
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        $blockedId = $connection.ProcessId
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $failed = $false
        $cancellation.CancelAfter(1000)
        try { $connection.Request('{}', $cancellation.Token) | Out-Null }
        catch { $failed = $_.Exception.ToString() -match 'cancelled.*No success was confirmed' }
        Assert $failed 'Explicit cancellation must interrupt a silent worker and report no confirmed success.'
        Assert ($clock.ElapsedMilliseconds -lt 4000) 'Cancellation must not wait on blocked stdout.'
        Assert (-not (Get-Process -Id $blockedId -ErrorAction SilentlyContinue)) 'Cancellation must stop only the blocked worker.'
    } finally { $cancellation.Dispose(); $connection.Dispose() }
    Write-Output ("Persistent library: " + $assertions + ' assertions passed.')
} finally {
    [Console]::InputEncoding = $inputEncoding
    [VibeReplay.LibraryConnections]::Close()
    if (Test-Path -LiteralPath $script:LibraryRoot) { Remove-Item -LiteralPath $script:LibraryRoot -Recurse -Force }
}
