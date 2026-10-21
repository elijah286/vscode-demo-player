param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [string]$ApplicationRoot
)

$ErrorActionPreference = 'Stop'
if (-not $ApplicationRoot) { $ApplicationRoot = Split-Path $PSScriptRoot -Parent }
. (Join-Path $ApplicationRoot 'PlayerEnvironment.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('demo-packaging-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$original = @{ Local = $env:LOCALAPPDATA; Program = $env:ProgramFiles; X86 = ${env:ProgramFiles(x86)}; W6432 = $env:ProgramW6432 }
$assertions = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw ($Label + ': expected ' + $Expected + ', got ' + $Actual) }
    $script:assertions++
}
function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    try { & $Action; throw 'Expected an error, but the operation succeeded.' }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        $script:assertions++
    }
}
function Test-VSCodeUpdateGuard {
    $name = 'demo-player-update-test-' + [guid]::NewGuid().ToString('N')
    $guard = [scriptblock]::Create(${function:Assert-PlayerVSCodeLaunchAvailable}.ToString().Replace("'vscode-updating'", "'$name'"))
    & $guard
    $script:assertions++
    $mutex = [Threading.Mutex]::new($false, $name)
    try {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Assert-Fails { & $guard } 'VS Code is currently being updated.*Restart to Update.*recordings and summaries have not been changed'
        Assert-Equal ($clock.ElapsedMilliseconds -lt 1000) $true 'Update guard fails before the editor startup timeout'
        $mutex.WaitOne() | Out-Null
        try { Assert-Fails { & $guard } 'VS Code is currently being updated' }
        finally { $mutex.ReleaseMutex() }
    } finally { $mutex.Dispose() }
    & $guard
    $script:assertions++
    $launcherAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ApplicationRoot 'Start-Replay.ps1'), [ref]$null, [ref]$null)
    $check = $launcherAst.Find({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-PlayerVSCodeLaunchAvailable'
    }, $true)
    $createProfile = $launcherAst.Find({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -eq 'CreateDirectory'
    }, $true)
    Assert-Equal ($null -ne $check -and $null -ne $createProfile -and $check.Extent.StartOffset -lt $createProfile.Extent.StartOffset) $true 'Update guard runs before creating a profile or launching VS Code'
}
function Test-ControllerFailures {
    $controller = Join-Path $ApplicationRoot 'Show-ReplayController.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($controller, [ref]$null, [ref]$null)
    $tickNode = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -eq '$timer' -and $node.Member.Value -eq 'Add_Tick'
    }, $true)
    $clickNode = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -eq '$playPause' -and $node.Member.Value -eq 'Add_Click'
    }, $true)
    $stopNode = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Request-Stop'
    }, $true)
    Assert-Equal ($null -ne $tickNode -and $null -ne $clickNode -and $null -ne $stopNode) $true 'Production lifecycle handlers exist'
    $tick = $tickNode.Arguments[0].ScriptBlock.GetScriptBlock()
    ${function:Request-Stop} = $stopNode.Body.GetScriptBlock()
    function Test-ReplayAlive { return $script:alive }
    function Reset-ReplaySession { $script:resetObserved = $true }
    function Show-DemoError($Owner, $Failure) { $script:reportedFailure = $Failure.Exception.Message; $script:failureDialogs++ }
    function Update-ReplayOverlays {}
    function Send-Control([string]$Action) { $script:sentAction = $Action; $script:stopSent = $true }
    $status = [pscustomobject]@{ Text = ''; ToolTip = '' }
    $playPause = [pscustomobject]@{ IsEnabled = $true }
    $nextStep = [pscustomobject]@{ IsEnabled = $true }
    $window = [pscustomobject]@{}
    $window | Add-Member -MemberType ScriptMethod -Name Show -Value {}
    $script:ReplayProcessId = 42
    $script:standalone = $true
    $script:exitRequested = $false
    $script:failureDialogs = 0
    $script:switching = $false
    $script:stopping = $false
    $script:pairedVisible = $true
    $script:alive = $false
    & $tick
    Assert-Equal $script:resetObserved $true 'Closed target resets session'
    Assert-Equal $script:lastFault 'The isolated VS Code target closed.' 'Unexpected closure is not success'
    Assert-Equal $script:failureDialogs 0 'Normal window closure does not open an error dialog'
    $script:pairedVisible = $false
    & $tick
    Assert-Equal $script:lastFault 'The isolated player exited before it was ready.' 'Early launch exit is explicit'
    Assert-Equal $script:reportedFailure $script:lastFault 'Early launch exit is displayed, not just reset to Open'
    Assert-Equal $script:failureDialogs 1 'Early launch exit reports one error'
    $script:stopping = $true
    & $tick
    Assert-Equal $script:failureDialogs 1 'User stop before readiness does not show a startup error'
    $script:stopping = $false
    $script:alive = $true
    $script:preparedDeadline = [DateTime]::UtcNow.AddSeconds(-1)
    $script:ControlPath = Join-Path $scratch 'missing-control.json'
    $script:client = $null
    $script:actionTask = $null
    $script:stateTask = $null
    $script:connectionFailures = 0
    & $tick
    Assert-Equal $script:lastFault 'Player was not ready within 45 seconds.' 'Readiness timeout is explicit'
    Assert-Equal $script:stopping $true 'Readiness timeout requests scoped stop'
    Assert-Equal $script:sentAction 'stop' 'Timed-out target is not played'
    Assert-Equal $playPause.IsEnabled $false 'Timed-out primary control remains disabled'
    Assert-Equal $nextStep.IsEnabled $false 'Timed-out Next Step remains disabled'
    $script:stopping = $false
    $script:connectionStop = $false
    $script:pairedVisible = $true
    $script:preparedDeadline = [DateTime]::UtcNow.AddMinutes(1)
    $script:connectionFailures = 0
    $script:client = [pscustomobject]@{}
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $cancelled = [Threading.Tasks.TaskCompletionSource[object]]::new()
        $cancelled.SetCanceled()
        $script:stateTask = $cancelled.Task
        & $tick
    }
    Assert-Equal $script:stopping $true 'Repeated connection cancellation requests scoped stop'
    Assert-Equal $script:connectionStop $true 'Connection-driven stop is distinct from user stop'
    $script:alive = $false
    & $tick
    Assert-Equal ($script:lastFault -like 'The isolated VS Code target closed. Control connection failed:*') $true 'Connection-driven exit reports target closure and retains its cause'
    $script:connectionStop = $false
    $script:lastFault = 'User stop preserves existing status'
    & $tick
    Assert-Equal $script:lastFault 'User stop preserves existing status' 'User stop is not relabeled as unexpected closure'
    $script:ReplayProcessId = 0
    $script:standalone = $true
    function Start-DemoReplay { throw 'Synthetic target launch failure' }
    function Set-IdleView { $script:idleObserved = $true }
    function Show-DemoError($Owner, $Failure) { $script:reportedFailure = $Failure.Exception.Message }
    & ($clickNode.Arguments[0].ScriptBlock.GetScriptBlock())
    Assert-Equal $script:idleObserved $true 'Launch failure restores idle controls'
    Assert-Equal $script:lastFault 'Synthetic target launch failure' 'Launch failure is retained in status'
    Assert-Equal $script:reportedFailure $script:lastFault 'Launch failure is displayed rather than reported as success'
    $refreshNode = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Refresh-ControllerSummaries'
    }, $true)
    $window = [pscustomobject]@{ IsEnabled = $true; Resources = @{ DemoPlayerOperation = @{} } }
    $script:selectedDemo = [pscustomobject]@{ id = 'synthetic' }
    $script:summaryRefreshing = $false
    $script:pickerOpen = $false
    $script:launching = $false
    $script:summaryLinksUpdated = $false
    function Update-ControllerSummaryLinks { $script:summaryLinksUpdated = $true }
    & $refreshNode.Body.GetScriptBlock()
    Assert-Equal $script:summaryLinksUpdated $false 'Automatic refresh never re-enters an active background operation'
    Assert-Equal $script:summaryRefreshing $false 'Skipped refresh leaves the operation state intact'
}
try {
    $scripts = @(Get-ChildItem -LiteralPath $ApplicationRoot -Filter '*.ps1' -File)
    foreach ($directory in @('test', 'packaging')) {
        $path = Join-Path $ApplicationRoot $directory
        if (Test-Path -LiteralPath $path) { $scripts += Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File }
    }
    $scripts | ForEach-Object {
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$parseErrors) | Out-Null
        if ($parseErrors) { throw ($_.Name + ': ' + ($parseErrors.Message -join '; ')) }
        $script:assertions++
    }
    Test-ControllerFailures
    Test-VSCodeUpdateGuard
    $installer = Get-Content -LiteralPath (Join-Path $ApplicationRoot 'packaging\DemoPlayer.iss') -Raw
    $appShortcuts = @($installer -split '\r?\n' | Where-Object { $_ -match '^Name:.*Filename: "\{app\}\\VSCodeDemoPlayer.exe"' })
    Assert-Equal $appShortcuts.Count 2 'Start menu and optional desktop app shortcuts exist'
    foreach ($shortcut in $appShortcuts) {
        Assert-Equal ($shortcut -match 'AppUserModelID: "VSCodeDemoPlayer.Desktop"') $true 'Installed shortcut has stable app identity'
    }
    Assert-Equal ($installer -match 'FinishedLabel=.*launch it, right-click its taskbar icon, then choose Pin to taskbar') $true 'Finish page explains manual pinning'
    Assert-Equal ($installer -match 'Flags: nowait postinstall skipifsilent') $true 'Optional finish launch and silent-install behavior retained'
    $build = Get-Content -LiteralPath (Join-Path $ApplicationRoot 'packaging\Build-Windows.ps1') -Raw
    Assert-Equal ($build -match "'PlayerTaskbarIdentity.cs'") $true 'Taskbar runtime helper is allowlisted'
    Assert-Equal ($build -match "'prompt-summary-review.js'") $true 'Automatic summary review runtime is allowlisted'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $ApplicationRoot 'native\prompt-summary-review.js') -PathType Leaf) $true 'Summary review runtime exists'
    $startup = Get-Content -LiteralPath (Join-Path $ApplicationRoot 'Start-InstalledPlayer.ps1') -Raw
    Assert-Equal ($startup -match '\[PlayerTaskbarIdentity\]::InitializeProcess\(\)') $true 'Installed startup sets process identity'
    Assert-Equal ($startup -match '-InstalledLauncherPath \(Join-Path \$PSScriptRoot ''VSCodeDemoPlayer.exe''\)') $true 'Installed startup supplies launcher rather than PowerShell'
    Assert-Equal (Resolve-PlayerNode $NodePath) (Resolve-Path -LiteralPath $NodePath).Path 'Explicit Node runtime'
    Assert-Fails { Resolve-PlayerNode (Join-Path $scratch 'missing.exe') } 'does not exist'
    $env:LOCALAPPDATA = Join-Path $scratch 'User App Data'
    $env:ProgramFiles = Join-Path $scratch 'Program Files'
    ${env:ProgramFiles(x86)} = Join-Path $scratch 'Program Files (x86)'
    $env:ProgramW6432 = $env:ProgramFiles
    Assert-Fails { Resolve-PlayerVSCode } 'VS Code was not found'
    $systemCode = Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'
    [IO.Directory]::CreateDirectory((Split-Path $systemCode -Parent)) | Out-Null
    [IO.File]::WriteAllText($systemCode, 'path-resolution fixture, not executable')
    Assert-Equal (Resolve-PlayerVSCode) $systemCode 'System-wide VS Code discovery'
    $userCode = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'
    [IO.Directory]::CreateDirectory((Split-Path $userCode -Parent)) | Out-Null
    [IO.File]::WriteAllText($userCode, 'path-resolution fixture, not executable')
    Assert-Equal (Resolve-PlayerVSCode) $userCode 'User VS Code preference'
    Assert-Equal (Resolve-PlayerVSCode $systemCode) $systemCode 'Explicit portable VS Code'
    Assert-Fails { Resolve-PlayerVSCode $NodePath } 'CodePath must point'
    $wrong = Join-Path $scratch 'wrong.exe'
    [IO.File]::WriteAllText($wrong, 'not Code')
    Assert-Fails { Resolve-PlayerVSCode $wrong } 'CodePath must point'
    Write-Output ('PACKAGING CHECKS PASSED: ' + $assertions + ' assertions, including source syntax, production controller launch/timeout/closure handlers with synthetic failures, dependency resolution, missing dependencies, user/system/portable VS Code, and paths with spaces.')
} finally {
    $env:LOCALAPPDATA = $original.Local
    $env:ProgramFiles = $original.Program
    ${env:ProgramFiles(x86)} = $original.X86
    $env:ProgramW6432 = $original.W6432
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
