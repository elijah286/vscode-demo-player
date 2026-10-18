param(
    [Parameter(Mandatory = $true)][string]$NodePath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('library-lifecycle-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $scratch 'native')) | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'DemoDialogs.ps1') -Destination $scratch
$helperPath = Join-Path $scratch 'native\library-cli.js'
$pidPath = Join-Path $scratch 'native\helper.pid'
$failures = [Collections.Generic.List[string]]::new()
$owner = [Windows.Window]::new()
$heartbeat = [Windows.Threading.DispatcherTimer]::new()
$heartbeat.Interval = [TimeSpan]::FromMilliseconds(20)
$script:ticks = 0
$script:disabledTicks = 0
$heartbeat.Add_Tick({
    $script:ticks++
    if (-not $owner.IsEnabled) { $script:disabledTicks++ }
})

function Test-LifecycleCase([string]$Name, [scriptblock]$Test) {
    try { & $Test; Write-Output ('PASS: ' + $Name) }
    catch { $failures.Add($Name + ': ' + $_.Exception.Message); Write-Output ('FAIL: ' + $Name + ': ' + $_.Exception.Message) }
}

function Assert-HelperStopped {
    $helperId = [int][IO.File]::ReadAllText($pidPath)
    $running = Get-Process -Id $helperId -ErrorAction SilentlyContinue
    if ($running) {
        Stop-Process -Id $helperId
        throw 'The invocation returned while its helper process was still running.'
    }
    if (-not $owner.IsEnabled -or $owner.Cursor) { throw 'Owner state was not restored.' }
}

try {
    . (Join-Path $scratch 'DemoDialogs.ps1')
    $script:NodePath = (Resolve-Path -LiteralPath $NodePath).Path
    $script:LibraryRoot = Join-Path $scratch 'library'
    $heartbeat.Start()
    Test-LifecycleCase 'saved refresh pumps the dispatcher with reentrant controls disabled' {
        [IO.File]::WriteAllText($helperPath, @'
process.stdin.resume();
process.stdin.on('end', () => setTimeout(() => {
    process.stdout.write(JSON.stringify({ ok: true, result: [] }));
}, 400));
'@)
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scratch 'DemoDialogs.ps1'), [ref]$null, [ref]$null)
        $refresh = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$refresh'
        }, $true).Right.Expression.ScriptBlock.GetScriptBlock()
        $dialog = $owner
        $dialog.Tag = @{}
        $filter = {}
        $script:ticks = 0
        $script:disabledTicks = 0
        & $refresh
        if ($script:ticks -lt 3 -or $script:disabledTicks -lt 3) { throw 'Saved refresh blocked window events or left reentrant controls enabled.' }
    }
    Test-LifecycleCase 'the 30-second budget includes a blocked stdin write' {
        [IO.File]::WriteAllText($helperPath, @'
require('node:fs').writeFileSync(require('node:path').join(__dirname, 'helper.pid'), String(process.pid));
setTimeout(() => {}, 45000);
'@)
        $script:ticks = 0
        $script:disabledTicks = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $message = ''
        try { Invoke-DemoLibrary @{ command = 'capture'; title = ('private-fixture-content' * 12000) } $owner | Out-Null }
        catch { $message = $_.Exception.Message }
        Assert-HelperStopped
        if ($clock.Elapsed.TotalSeconds -lt 30 -or $clock.Elapsed.TotalSeconds -gt 35) { throw ('Blocked input escaped the 30-second budget: ' + $clock.Elapsed) }
        if ($message -notmatch "capture.*exceeded 30 seconds.*sending" -or $message -match 'private-fixture-content') { throw ('Missing privacy-safe operation/phase context: ' + $message) }
        if ($script:ticks -lt 10 -or $script:disabledTicks -lt 10) { throw 'Blocked input froze the owner dispatcher.' }
    }
    Test-LifecycleCase 'a written result without process exit is not confirmed success' {
        [IO.File]::WriteAllText($helperPath, @'
require('node:fs').writeFileSync(require('node:path').join(__dirname, 'helper.pid'), String(process.pid));
process.stdin.resume();
process.stdin.on('end', () => {
    process.stdout.write(JSON.stringify({ ok: true, result: { title: 'Unconfirmed result' } }));
    setTimeout(() => {}, 45000);
});
'@)
        $message = ''
        try { Invoke-DemoLibrary @{ command = 'read' } $owner | Out-Null }
        catch { $message = $_.Exception.Message }
        Assert-HelperStopped
        if ($message -notmatch "read.*exceeded 30 seconds.*exit" -or $message -notmatch 'No success was confirmed') { throw ('Unconfirmed completion lost its context: ' + $message) }
    }
    Test-LifecycleCase 'streaming history handlers send input and reap successful and failed helpers' {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scratch 'DemoDialogs.ps1'), [ref]$null, [ref]$null)
        $startScan = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$startScan'
        }, $true).Right.Expression.ScriptBlock.GetScriptBlock()
        $stopScan = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$stopScan'
        }, $true).Right.Expression.ScriptBlock.GetScriptBlock()
        $scanTick = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'Add_Tick' -and $node.Expression.Extent.Text -eq '$scanTimer'
        }, $true).Arguments[0].ScriptBlock.GetScriptBlock()
        $dialog = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
<StackPanel><Button x:Name="Refresh"/><Button x:Name="AddLocation"/><Button x:Name="Load"/><Button x:Name="Browse"/><TextBlock x:Name="DiscoveryNote"/></StackPanel>
</Window>
'@ $null
        $updateCount = {}
        $fillFilters = {}
        $scanTimer = [Windows.Threading.DispatcherTimer]::new()
        $scanTimer.Interval = [TimeSpan]::FromMilliseconds(20)
        $scanTimer.Add_Tick($scanTick)
        $guard = [Windows.Threading.DispatcherTimer]::new()
        $guard.Interval = [TimeSpan]::FromMilliseconds(20)
        $guard.Add_Tick({ if (-not $dialog.Tag.Scan -or $clock.Elapsed.TotalSeconds -gt 5) { $frame.Continue = $false } })
        try {
            foreach ($failed in @($false, $true)) {
                $dialog.Tag = @{
                    Locations = @($scratch); Rows = [Collections.Generic.List[object]]::new()
                    Warnings = [Collections.Generic.List[string]]::new()
                }
                $reply = if ($failed) { '{"ok":false,"error":"Synthetic history failure"}' } else { '{"ok":true,"result":{"notice":"Synthetic history ready"}}' }
                $tail = if ($failed) { 'setTimeout(() => {}, 45000);' } else { '' }
                [IO.File]::WriteAllText($helperPath, @'
require('node:fs').writeFileSync(require('node:path').join(__dirname, 'helper.pid'), String(process.pid));
process.stdin.resume();
process.stdin.on('end', () => {
    process.stdout.write('{"progress":{"phase":"entry","session":{"title":"Synthetic row","promptCount":1,"loadable":true}}}\n');
'@ + "`nprocess.stdout.write(" + ($reply | ConvertTo-Json -Compress) + " + '\n');`n" + $tail + "`n});")
                $clock = [Diagnostics.Stopwatch]::StartNew()
                $frame = [Windows.Threading.DispatcherFrame]::new()
                & $startScan
                $guard.Start()
                [Windows.Threading.Dispatcher]::PushFrame($frame)
                $guard.Stop()
                if ($dialog.Tag.Scan -or $dialog.Tag.Rows.Count -ne 1) { throw 'History did not complete or lost its streamed row.' }
                $expected = if ($failed) { 'Discovery failed: Synthetic history failure' } else { 'Synthetic history ready' }
                if ($dialog.FindName('DiscoveryNote').Text -ne $expected) { throw 'History completion/error was not displayed explicitly.' }
                foreach ($name in @('Refresh', 'AddLocation', 'Load', 'Browse')) {
                    if (-not $dialog.FindName($name).IsEnabled) { throw ('History did not restore ' + $name) }
                }
                Assert-HelperStopped
            }
        } finally { $guard.Stop(); & $stopScan $true; $dialog.Close() }
    }
    Test-LifecycleCase 'closing the owner cancels and reaps its helper promptly' {
        $closeTimer = [Windows.Threading.DispatcherTimer]::new()
        $closeTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $closeTimer.Add_Tick({ $closeTimer.Stop(); $owner.Close() })
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $message = ''
        try {
            $closeTimer.Start()
            Invoke-DemoLibrary @{ command = 'export' } $owner | Out-Null
        } catch { $message = $_.Exception.Message }
        finally { $closeTimer.Stop() }
        Assert-HelperStopped
        if ($clock.Elapsed.TotalSeconds -gt 5 -or $message -notmatch "export.*cancelled.*No success was confirmed") { throw ('Owner closure did not cancel explicitly and promptly: ' + $message) }
    }
    if ($failures.Count) { throw ($failures -join "`n") }
    Write-Output 'LIBRARY HELPER LIFECYCLE PASSED: 5 runtime cases; real 30-second deadlines, blocked input, completion contract, streaming history, owner routing/cancellation and process cleanup.'
} finally {
    $heartbeat.Stop()
    $owner.Close()
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
