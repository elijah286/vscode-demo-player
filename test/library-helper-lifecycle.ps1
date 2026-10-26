param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [string]$ApplicationRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = if ($ApplicationRoot) { (Resolve-Path -LiteralPath $ApplicationRoot).Path } else { Split-Path $PSScriptRoot -Parent }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('library-lifecycle-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $scratch 'native')) | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'DemoDialogs.ps1') -Destination $scratch
Copy-Item -LiteralPath (Join-Path $root 'SummaryPresentation.ps1') -Destination $scratch
Copy-Item -LiteralPath (Join-Path $root 'PlayerShell.ps1') -Destination $scratch
$shellFile = if (Test-Path -LiteralPath (Join-Path $root 'VibeReplay.Shell.dll')) { 'VibeReplay.Shell.dll' } else { 'PlayerShell.cs' }
Copy-Item -LiteralPath (Join-Path $root $shellFile) -Destination $scratch
$helperPath = Join-Path $scratch 'native\library-cli.js'
$pidPath = Join-Path $scratch 'native\helper.pid'
$failures = [Collections.Generic.List[string]]::new()
$owner = [Windows.Window]::new()
$heartbeat = [Windows.Threading.DispatcherTimer]::new()
$heartbeat.Interval = [TimeSpan]::FromMilliseconds(20)
$script:ticks = 0
$script:disabledTicks = 0
$script:latencyClock = $null
$heartbeat.Add_Tick({
    $script:ticks++
    if ($owner.IsEnabled -and $owner.Resources.Contains('DemoPlayerOperation') -and -not $owner.FindName('Load').IsEnabled) { $script:disabledTicks++ }
    if ($script:latencyClock) {
        $now = $script:latencyClock.Elapsed.TotalMilliseconds
        $script:maxInputDelay = [Math]::Max($script:maxInputDelay, $now - $script:lastInput)
        $script:lastInput = $now
        $owner.FindName('SavedSearch').Text = 'Responsive search ' + $script:ticks
        $owner.FindName('ShowPrompt').IsChecked = -not $owner.FindName('ShowPrompt').IsChecked
    }
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
    Test-LifecycleCase 'decoded JSON preserves case-insensitive fields, values, arrays and explicit invalid-input errors' {
        $json = '{"Title":"Synthetic title","count":42,"nested":{"MixedCase":true,"zero":0,"empty":"","missing":null,"items":[{"index":19999}]},"emptyArray":[],"emptyObject":{},"unicode":"\ud83d\ude42","escaped":"line\nquote\""}'
        $decoded = [DemoLibraryJson]::Parse($json)
        if ($decoded.title -cne 'Synthetic title' -or $decoded.Count -ne 42 -or
            -not $decoded.nested.mixedcase -or $decoded.nested.zero -ne 0 -or
            $decoded.nested.empty -cne '' -or $null -ne $decoded.nested.missing -or
            $decoded.nested.items.Count -ne 1 -or $decoded.nested.items[0].index -ne 19999 -or
            $decoded.emptyArray.Count -ne 0 -or $decoded.emptyObject.Count -ne 0 -or
            $decoded.unicode -cne [char]::ConvertFromUtf32(0x1F642) -or $decoded.escaped -cne "line`nquote`"") {
            throw 'Decoded JSON changed case-insensitive access or a value/array shape.'
        }
        $roundtrip = $decoded | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json
        if ($roundtrip.count -ne 42 -or $roundtrip.nested.items[0].index -ne 19999 -or
            $roundtrip.emptyArray.Count -ne 0 -or $roundtrip.unicode -cne $decoded.unicode) {
            throw 'Decoded metadata must roundtrip through existing JSON save/export requests.'
        }
        $numericJson = '{"values":[0,-1,2147483648,9223372036854775807,1.25,1e-20],"date":"/Date(0)/","disabled":false}'
        $reference = ConvertFrom-Json $numericJson
        $actual = [DemoLibraryJson]::Parse($numericJson)
        for ($index = 0; $index -lt $reference.values.Count; $index++) {
            if ($actual.values[$index] -cne $reference.values[$index] -or
                $actual.values[$index].GetType() -ne $reference.values[$index].GetType()) {
                throw 'Numeric values/types changed from the existing Windows PowerShell decoder.'
            }
        }
        if ($actual.date -cne $reference.date -or $actual.date.GetType() -ne $reference.date.GetType() -or
            $actual.disabled -cne $false) { throw 'Date or boolean decoding changed.' }
        foreach ($invalid in @('not json', '{"a":1,"A":2}', '{"":1}', '{"nested":[{"a":1,"A":2}]}')) {
            $failed = $false
            try { [DemoLibraryJson]::Parse($invalid) | Out-Null } catch { $failed = $true }
            if (-not $failed) { throw 'Invalid or ambiguous JSON was accepted without an error.' }
        }
    }
    $owner = New-DemoDialog @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
 <StackPanel><Button x:Name="Load"/><CheckBox x:Name="ShowPrompt"/><TextBox x:Name="SavedSearch"/></StackPanel>
</Window>
'@ $null
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
    Test-LifecycleCase 'large request serialization and response decoding keep input delays below 250ms' {
        [IO.File]::WriteAllText($helperPath, @'
process.stdin.resume();
process.stdin.on('end', () => {
    const items = Array.from({ length: 20000 }, (_, index) => ({
        index, message: { text: 'Synthetic nested payload '.repeat(8), metadata: { flags: [true, false], number: index } }
    }));
    process.stdout.write(JSON.stringify({ ok: true, result: { items } }));
});
'@)
        $rows = @(for ($i = 0; $i -lt 5000; $i++) { @{ index = $i; nested = @{ text = 'Synthetic request'; values = @(1,2,3) } } })
        $script:lastInput = 0
        $script:maxInputDelay = 0
        $script:latencyClock = [Diagnostics.Stopwatch]::StartNew()
        try {
            $result = Invoke-DemoLibrary @{ command = 'inspect'; rows = $rows } $owner
            $script:maxInputDelay = [Math]::Max($script:maxInputDelay, $script:latencyClock.Elapsed.TotalMilliseconds - $script:lastInput)
        } finally { $script:latencyClock = $null }
        if ($result.items.Count -ne 20000 -or $result.items[19999].message.metadata.number -ne 19999) { throw 'Large JSON result lost its shape or content.' }
        if ($script:maxInputDelay -gt 250) { throw ('Input was blocked for ' + [Math]::Round($script:maxInputDelay,1) + 'ms (limit250ms).') }
        if (-not $owner.IsEnabled -or -not $owner.FindName('ShowPrompt').IsEnabled -or -not $owner.FindName('SavedSearch').IsEnabled) { throw 'Independent UI controls were disabled.' }
        Write-Output ('MAXIMUM BACKGROUND INPUT DELAY: ' + [Math]::Round($script:maxInputDelay,1) + 'ms (limit250ms); 5000 request objects,20000 response objects.')
    }
    Test-LifecycleCase 'user cancellation promptly reaps the worker helper and restores conflicting controls' {
        [IO.File]::WriteAllText($helperPath, @'
require('node:fs').writeFileSync(require('node:path').join(__dirname, 'helper.pid'), String(process.pid));
process.stdin.resume();
setTimeout(() => {}, 45000);
'@)
        $cancel = [Windows.Threading.DispatcherTimer]::new()
        $cancel.Interval = [TimeSpan]::FromMilliseconds(300)
        $cancel.Add_Tick({ if (Test-Path -LiteralPath $pidPath) { $owner.Resources['DemoPlayerOperation'].Cancellation.Cancel(); $cancel.Stop() } })
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $cancel.Start()
        try {
            try { Invoke-DemoLibrary @{ command = 'read' } $owner | Out-Null; throw 'Cancellation incorrectly returned success.' }
            catch { if (-not $_.Exception.Data['DemoPlayerOperationCancelled']) { throw } }
        } finally { $cancel.Stop() }
        Assert-HelperStopped
        if ($clock.Elapsed.TotalSeconds -gt 3 -or -not $owner.FindName('Load').IsEnabled -or $owner.Resources.Contains('DemoPlayerOperation')) { throw 'Cancellation did not promptly restore the window and release its worker.' }
    }
    Test-LifecycleCase 'a blocked stdin write remains responsive and can be explicitly canceled' {
        [IO.File]::WriteAllText($helperPath, @'
require('node:fs').writeFileSync(require('node:path').join(__dirname, 'helper.pid'), String(process.pid));
setTimeout(() => {}, 45000);
'@)
        $script:ticks = 0
        $script:disabledTicks = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $message = ''
        $cancel = [Windows.Threading.DispatcherTimer]::new()
        $cancel.Interval = [TimeSpan]::FromMilliseconds(500)
        $cancel.Add_Tick({ $cancel.Stop(); $owner.Resources['DemoPlayerOperation'].Cancellation.Cancel() })
        $cancel.Start()
        try { Invoke-DemoLibrary @{ command = 'capture'; title = ('private-fixture-content' * 12000) } $owner | Out-Null; throw 'Blocked input returned success.' }
        catch { $message = $_.Exception.Message }
        finally { $cancel.Stop() }
        Assert-HelperStopped
        if ($clock.Elapsed.TotalSeconds -gt 3) { throw ('Blocked input ignored cancellation: ' + $clock.Elapsed) }
        if ($message -notmatch 'cancelled.*No success was confirmed' -or $message -match 'private-fixture-content') { throw ('Missing privacy-safe cancellation context: ' + $message) }
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
        $cancel = [Windows.Threading.DispatcherTimer]::new()
        $cancel.Interval = [TimeSpan]::FromMilliseconds(500)
        $cancel.Add_Tick({ $cancel.Stop(); $owner.Resources['DemoPlayerOperation'].Cancellation.Cancel() })
        $cancel.Start()
        try { Invoke-DemoLibrary @{ command = 'read' } $owner | Out-Null; throw 'Unconfirmed result returned success.' }
        catch { $message = $_.Exception.Message }
        finally { $cancel.Stop() }
        Assert-HelperStopped
        if ($message -notmatch 'cancelled.*No success was confirmed') { throw ('Unconfirmed completion lost its context: ' + $message) }
    }
    Test-LifecycleCase 'active helper completes after the former 30-second cutoff without being killed' {
        [IO.File]::WriteAllText($helperPath, @'
require('node:fs').writeFileSync(require('node:path').join(__dirname, 'helper.pid'), String(process.pid));
process.stdin.resume();
process.stdin.on('end', () => {
    const updates = setInterval(() => process.stdout.write(' '), 250);
    setTimeout(() => {
        clearInterval(updates);
        process.stdout.write(JSON.stringify({ ok: true, result: { title: 'Completed after 30 seconds' } }));
    }, 32000);
});
'@)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $script:ticks = 0
        $result = Invoke-DemoLibrary @{ command = 'list' } $owner
        Assert-HelperStopped
        if ($clock.Elapsed.TotalSeconds -lt 32 -or $result.title -ne 'Completed after 30 seconds') { throw 'Slow active helper did not complete successfully past the former deadline.' }
        if ($script:ticks -lt 100) { throw 'Slow operation blocked the dispatcher.' }
    }
    Test-LifecycleCase 'update polling preserves live work and explicit cancellation reaps the helper and cleans its download' {
        Copy-Item -LiteralPath (Join-Path $root 'PlayerUpdates.ps1') -Destination $scratch
        . (Join-Path $scratch 'PlayerUpdates.ps1')
        . (Join-Path $root 'PlayerEnvironment.ps1')
        function Set-PlayerUpdateFailure($Failure) { throw $Failure }
        [IO.File]::WriteAllText((Join-Path $scratch 'native\updater.js'), @'
process.stdin.resume();
process.stdin.on('end', () => setInterval(() => process.stdout.write(' '), 100));
'@)
        $download = Join-Path $scratch 'pending-update'
        [IO.Directory]::CreateDirectory($download) | Out-Null
        [IO.File]::WriteAllText((Join-Path $download 'partial.exe'), 'Synthetic partial download; not executable.')
        $updateNotice = [pscustomobject]@{ Text = ''; ToolTip = '' }
        $script:playerUpdate = @{
            Process = $null; Pending = $null; Version = '0.1.0'; Result = $null
            Directory = $download; Dialog = $null; Notice = ''; Detail = ''
        }
        try {
            Start-PlayerUpdateOperation 'check'
            $helperId = $script:playerUpdate.Process.Id
            $script:playerUpdate.Deadline = [DateTime]::UtcNow.AddSeconds(-1)
            Receive-PlayerUpdateOperation
            if (-not $script:playerUpdate.Process -or $script:playerUpdate.Process.HasExited -or
                $script:playerUpdate.Notice -ne 'Checking updates...') { throw 'Elapsed time stopped a live update helper.' }
            $owner.Resources.Add('DemoPlayerOperation', @{})
            $script:ticks = 0
            Stop-PlayerUpdateOperation
            if (Get-Process -Id $helperId -ErrorAction SilentlyContinue) { throw 'Explicit update cancellation left its helper running.' }
            if ($script:playerUpdate.Process -or $script:playerUpdate.Directory -or (Test-Path -LiteralPath $download)) { throw 'Canceled download was not cleaned completely.' }
            if ($script:ticks -lt 1 -or -not $owner.Resources.Contains('DemoPlayerOperation')) { throw 'Cleanup blocked the dispatcher or interfered with an independent library operation.' }
        } finally {
            $owner.Resources.Remove('DemoPlayerOperation')
            Stop-PlayerUpdateOperation
        }
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
                $dialog.Tag.Scan.Clock.Stop()
                $dialog.Tag.Scan.Clock = [pscustomobject]@{ Elapsed = [TimeSpan]::FromSeconds(61) }
                $dialog.Tag.Scan.Clock | Add-Member ScriptMethod Stop {}
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
        $failure = $null
        try {
            $closeTimer.Start()
            Invoke-DemoLibrary @{ command = 'export' } $owner | Out-Null
        } catch { $failure = $_; $message = $_.Exception.Message }
        finally { $closeTimer.Stop() }
        Assert-HelperStopped
        if ($clock.Elapsed.TotalSeconds -gt 5 -or $message -notmatch "export.*cancelled.*No success was confirmed") { throw ('Owner closure did not cancel explicitly and promptly: ' + $message) }
        if ($failure.Exception -isnot [OperationCanceledException] -or -not $failure.Exception.Data['DemoPlayerOwnerClosed']) { throw 'Owner closure lost its explicit cancellation type/context.' }
        $warnings = @(& { Show-DemoError $owner $failure } 3>&1)
        if ($warnings.Count -ne 1 -or $warnings[0] -isnot [Management.Automation.WarningRecord] -or $warnings[0].Message -ne $message) {
            throw 'Closed-window cancellation must be logged without reopening a modal error.'
        }
    }
    if ($failures.Count) { throw ($failures -join "`n") }
    Write-Output 'LIBRARY HELPER LIFECYCLE PASSED: 10 runtime cases; compatible JSON, 250ms large-JSON input budget, independent controls, explicit cancellation, active completion beyond 30 seconds, blocked input, completion contract, update cancellation/cleanup, streaming history, owner routing and process cleanup.'
} finally {
    $heartbeat.Stop()
    $owner.Close()
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
