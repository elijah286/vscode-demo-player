function Resolve-PlayerVSCode([string]$CodePath) {
    if ($CodePath) {
        $resolved = (Resolve-Path -LiteralPath $CodePath -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf) -or [IO.Path]::GetFileName($resolved) -ine 'Code.exe') {
            throw 'CodePath must point to a desktop VS Code Code.exe.'
        }
        return $resolved
    }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe')
    )
    foreach ($base in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates += Join-Path $base 'Microsoft VS Code\Code.exe' }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'VS Code was not found. Install desktop VS Code from https://code.visualstudio.com/ and try again. For a portable installation, use -CodePath pointing to Code.exe.'
}

function Assert-PlayerVSCodeLaunchAvailable {
    $updateMutex = $null
    try {
        # VS Code blocks on the mutex's existence, even when no thread owns it.
        if ([Threading.Mutex]::TryOpenExisting('vscode-updating', [ref]$updateMutex)) {
            throw 'VS Code is currently being updated and is refusing new playback windows. Save your work in VS Code and choose Restart to Update to finish the update, then try Open again. Your recordings and summaries have not been changed.'
        }
    } finally {
        if ($updateMutex) { $updateMutex.Dispose() }
    }
}

function Resolve-PlayerNode([string]$NodePath) {
    if (-not $NodePath) {
        $bundled = Join-Path $PSScriptRoot 'runtime\node.exe'
        if (Test-Path -LiteralPath $bundled -PathType Leaf) { $NodePath = $bundled }
        else {
            $command = Get-Command node.exe -ErrorAction SilentlyContinue
            if ($command) { $NodePath = $command.Source }
        }
    }
    if (-not $NodePath) { throw 'Node.js 22.16 or newer is required for source checkouts. Use the Windows installer to get the bundled runtime, or pass -NodePath.' }
    $resolved = (Resolve-Path -LiteralPath $NodePath -ErrorAction Stop).Path
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $resolved
    $start.Arguments = '--version'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    if (-not $process) { throw 'The Node.js runtime could not start.' }
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(5000)) {
            $process.Kill()
            throw 'The Node.js version check exceeded five seconds.'
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($output, $errors), 2000)) { throw 'Timed out reading the Node.js version.' }
        $text = $output.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0 -or $text -notmatch '^v(\d+)\.(\d+)\.(\d+)$') {
            throw ('Node.js did not report a valid version. ' + $errors.GetAwaiter().GetResult())
        }
        if ([version]$text.Substring(1) -lt [version]'22.16.0') { throw ('Node.js 22.16 or newer is required; found ' + $text + '.') }
        return $resolved
    } finally { $process.Dispose() }
}
