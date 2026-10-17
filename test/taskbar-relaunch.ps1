param(
    [Parameter(Mandatory = $true)][string]$ApplicationRoot,
    [string]$EvidenceRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) '.build\taskbar-relaunch')
)

$ErrorActionPreference = 'Stop'
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
$fixture = Join-Path $EvidenceRoot ('fixture-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$assertions = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw ($Label + ': expected ' + $Expected + ', got ' + $Actual) }
    $script:assertions++
}
foreach ($file in @('Start-InstalledPlayer.ps1', 'PlayerEnvironment.ps1', 'PlayerTaskbarIdentity.cs', 'VSCodeDemoPlayer.exe')) {
    Copy-Item -LiteralPath (Join-Path $ApplicationRoot $file) -Destination (Join-Path $fixture $file)
}
[IO.File]::WriteAllText((Join-Path $fixture 'Show-ReplayController.ps1'), @'
param([string]$LibraryRoot, [string]$NodePath, [string]$CodePath, [string]$InstalledLauncherPath)
@{ LibraryRoot = $LibraryRoot; NodePath = $NodePath; CodePath = $CodePath; InstalledLauncherPath = $InstalledLauncherPath; ProcessId = $PID } |
    ConvertTo-Json | Set-Content -LiteralPath $env:DEMO_TASKBAR_CAPTURE -Encoding UTF8
'@)
$originalLocal = $env:LOCALAPPDATA
$originalCapture = $env:DEMO_TASKBAR_CAPTURE
try {
    $env:LOCALAPPDATA = Join-Path $fixture 'App Data'
    $library = Join-Path $fixture ("Librar$([char]0xE9)'s long path " + ('x' * 80))
    $code = Join-Path $fixture 'Portable editor\Code.exe'
    [IO.Directory]::CreateDirectory((Split-Path $code -Parent)) | Out-Null
    [IO.File]::WriteAllText($code, 'path-resolution fixture; never executed')
    $node = Join-Path $ApplicationRoot 'runtime\node.exe'
    $launcher = Join-Path $fixture 'VSCodeDemoPlayer.exe'
    function Invoke-Launcher([string]$Arguments, [string]$Label) {
        $env:DEMO_TASKBAR_CAPTURE = Join-Path $fixture ($Label + '.json')
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $launcher
        $start.Arguments = $Arguments
        $start.UseShellExecute = $false
        $process = [Diagnostics.Process]::Start($start)
        try {
            if (-not $process.WaitForExit(10000)) { throw 'Synthetic launcher did not exit within ten seconds.' }
            Assert-Equal $process.ExitCode 0 'Production launcher starts successfully'
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            while (-not (Test-Path -LiteralPath $env:DEMO_TASKBAR_CAPTURE)) {
                if ([DateTime]::UtcNow -gt $deadline) {
                    $children = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = " + $process.Id) |
                        Where-Object { $_.CommandLine -like ('*' + (Join-Path $fixture 'Start-InstalledPlayer.ps1') + '*') })
                    foreach ($child in $children) { Stop-Process -Id $child.ProcessId -ErrorAction Stop }
                    throw 'Synthetic installed startup did not reach the controller fixture; inspect its isolated startup error log.'
                }
                Start-Sleep -Milliseconds 100
            }
            $result = Get-Content -LiteralPath $env:DEMO_TASKBAR_CAPTURE -Raw | ConvertFrom-Json
            $child = Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue
            if ($child -and -not $child.WaitForExit(10000)) { throw 'Synthetic installed startup did not exit.' }
            return $result
        } finally { $process.Dispose() }
    }
    $normal = Invoke-Launcher ('-LibraryRoot "' + $library + '" -NodePath "' + $node + '" -CodePath "' + $code + '"') 'explicit-launch'
    Assert-Equal $normal.LibraryRoot $library 'Launcher forwards explicit library with spaces and apostrophe'
    Assert-Equal $normal.NodePath $node 'Launcher forwards explicit Node path'
    Assert-Equal $normal.CodePath $code 'Launcher forwards portable editor path'
    Assert-Equal $normal.InstalledLauncherPath $launcher 'Installed startup supplies executable relaunch target'
    $profilePath = Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\taskbar-relaunch.json'
    $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $profile.LibraryRoot $library 'Long library is persisted outside MAX_PATH-limited command'
    $relaunch = Invoke-Launcher '-TaskbarRelaunch' 'taskbar-launch'
    foreach ($name in @('LibraryRoot', 'NodePath', 'CodePath', 'InstalledLauncherPath')) {
        Assert-Equal $relaunch.$name $normal.$name ('Taskbar relaunch preserves ' + $name)
    }
    $defaultCode = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'
    [IO.Directory]::CreateDirectory((Split-Path $defaultCode -Parent)) | Out-Null
    Copy-Item -LiteralPath $code -Destination $defaultCode
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'runtime')) | Out-Null
    Copy-Item -LiteralPath $node -Destination (Join-Path $fixture 'runtime\node.exe')
    $default = Invoke-Launcher '' 'default-launch'
    Assert-Equal $default.LibraryRoot (Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\demos') 'Normal launch ignores previous custom taskbar library'
    Assert-Equal $default.CodePath $defaultCode 'Normal launch retains standard editor discovery'
    Assert-Equal $default.NodePath (Join-Path $fixture 'runtime\node.exe') 'Normal launch retains bundled Node discovery'
    $refreshed = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal $refreshed.LibraryRoot $default.LibraryRoot 'Normal launch refreshes the next taskbar relaunch'
    $startup = [Management.Automation.Language.Parser]::ParseFile((Join-Path $fixture 'Start-InstalledPlayer.ps1'), [ref]$null, [ref]$null)
    $validation = $startup.Find({ param($item)
        $item -is [Management.Automation.Language.IfStatementAst] -and $item.Clauses[0].Item1.Extent.Text -eq '$TaskbarRelaunch'
    }, $true)
    Assert-Equal ($null -ne $validation) $true 'Production relaunch profile validation exists'
    $validate = [scriptblock]::Create($validation.Clauses[0].Item2.Extent.Text.TrimStart('{').TrimEnd('}'))
    $NodePath = $null
    $CodePath = $null
    $Check = $false
    foreach ($invalid in @('missing', 'malformed', 'relative', 'wrong-type')) {
        switch ($invalid) {
            missing { Remove-Item -LiteralPath $profilePath }
            malformed { [IO.File]::WriteAllText($profilePath, '{') }
            relative { [IO.File]::WriteAllText($profilePath, '{"LibraryRoot":"relative","NodePath":"C:\\node.exe","CodePath":"C:\\Code.exe"}') }
            wrong-type { [IO.File]::WriteAllText($profilePath, '{"LibraryRoot":42,"NodePath":"C:\\node.exe","CodePath":"C:\\Code.exe"}') }
        }
        try { & $validate; throw 'Expected profile validation failure.' }
        catch {
            if ($_.Exception.Message -eq 'Expected profile validation failure.') { throw }
            if ($_.Exception.Message -notmatch 'profile' -and $_.FullyQualifiedErrorId -notmatch 'ConvertFromJsonCommand') { throw }
            $assertions++
        }
    }
    $NodePath = $node
    try { & $validate; throw 'Expected incompatible arguments failure.' }
    catch {
        if ($_.Exception.Message -notmatch 'cannot be combined') { throw }
        $assertions++
    }
    $summary = "TASKBAR RELAUNCH PASSED: $assertions assertions; production EXE and installed startup, long explicit paths, profile relaunch, ordinary defaults, refreshed profile and explicit invalid/missing profile failures. Only isolated app data and controller fixtures used; no installed app, library, editor, registry or pins touched."
    [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'result.txt'), $summary)
    Write-Output $summary
} finally {
    $env:LOCALAPPDATA = $originalLocal
    $env:DEMO_TASKBAR_CAPTURE = $originalCapture
}
