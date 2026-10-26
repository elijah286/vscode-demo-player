param([Parameter(Mandatory = $true)][string]$NodePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'DemoDialogs.ps1')
$script:NodePath = (Resolve-Path -LiteralPath $NodePath).Path
$script:LibraryRoot = Join-Path ([IO.Path]::GetTempPath()) ('vibereplay-worker-' + [guid]::NewGuid().ToString('N'))
$script:PersistentLibrary = $true
$assertions = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
try {
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
    $blocked = Join-Path $script:LibraryRoot 'blocked.js'
    [IO.File]::WriteAllText($blocked, "process.stdin.resume(); setInterval(() => {}, 1000);")
    $connection = [VibeReplay.LibraryConnection]::new($script:NodePath, $blocked, $script:LibraryRoot)
    try {
        $blockedId = $connection.ProcessId
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $failed = $false
        try { $connection.Request('{}', 1, [Threading.CancellationToken]::None) | Out-Null }
        catch { $failed = $_.Exception.ToString() -match 'deadline.*No success was confirmed' }
        Assert $failed 'A stalled worker must fail explicitly at its deadline.'
        Assert ($clock.ElapsedMilliseconds -lt 4000) 'Cancellation must not wait on blocked stdout.'
        Assert (-not (Get-Process -Id $blockedId -ErrorAction SilentlyContinue)) 'Cancellation must stop only the blocked worker.'
    } finally { $connection.Dispose() }
    Write-Output ("Persistent library: " + $assertions + ' assertions passed.')
} finally {
    [VibeReplay.LibraryConnections]::Close()
    if (Test-Path -LiteralPath $script:LibraryRoot) { Remove-Item -LiteralPath $script:LibraryRoot -Recurse -Force }
}
