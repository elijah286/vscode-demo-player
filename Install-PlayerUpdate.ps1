param([Parameter(Mandatory = $true)][string]$JobPath)

$ErrorActionPreference = 'Stop'
try {
    $jobFile = (Resolve-Path -LiteralPath $JobPath).Path
    $directory = Split-Path $jobFile -Parent
    $updateRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\updates'))
    if ((Split-Path $directory -Parent) -ine $updateRoot -or (Split-Path $directory -Leaf) -notmatch '^pending-[a-f0-9]{32}$' -or (Split-Path $jobFile -Leaf) -ne 'install-job.json') {
        throw 'The update handoff file is not in an owned update directory.'
    }
    $job = [IO.File]::ReadAllText($jobFile) | ConvertFrom-Json
    $installer = Join-Path $directory 'VSCodeDemoPlayer-Setup.exe'
    if ($job.installerPath -ine $installer -or $job.sha256 -notmatch '^[a-f0-9]{64}$' -or $job.version -notmatch '^\d+\.\d+\.\d+$' -or $job.parentId -le 0) { throw 'Invalid update handoff contract.' }
    $executable = Join-Path $job.installRoot 'VSCodeDemoPlayer.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'The original installed application was not found.' }
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $job.sha256) { throw 'The installer changed after download verification. No update was started.' }
    $parent = $null
    try { $parent = [Diagnostics.Process]::GetProcessById([int]$job.parentId) }
    catch [ArgumentException] { Write-Output 'The original application has already exited.' }
    if ($parent) {
        try {
            $parent.WaitForExit()
        } finally { $parent.Dispose() }
    }
    $setup = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $job.installRoot + '"'), ('/LOG="' + (Join-Path $directory 'installer.log') + '"')) -PassThru
    try {
        $setup.WaitForExit()
        if ($setup.ExitCode -ne 0) { throw ('The installer failed with exit code ' + $setup.ExitCode + '. See ' + (Join-Path $directory 'installer.log')) }
    } finally { $setup.Dispose() }
    $installed = [IO.File]::ReadAllText((Join-Path $job.installRoot 'build-info.json')) | ConvertFrom-Json
    if ($installed.version -ne $job.version) { throw 'The installer exited but the expected application version was not found. Success was not confirmed.' }
    foreach ($value in @($job.libraryRoot, $job.codePath)) {
        if ([string]::IsNullOrWhiteSpace($value) -or $value.Contains('"')) { throw 'Invalid path in the restart contract.' }
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executable
    $start.UseShellExecute = $false
    $library = [regex]::Replace([string]$job.libraryRoot, '(\\+)$', '$1$1')
    $code = [regex]::Replace([string]$job.codePath, '(\\+)$', '$1$1')
    $start.Arguments = '-LibraryRoot "' + $library + '" -CodePath "' + $code + '"'
    $restarted = [Diagnostics.Process]::Start($start)
    if (-not $restarted) { throw 'The update installed, but Demo Player could not be restarted. Launch it from Start.' }
    $restarted.Dispose()
    [IO.File]::WriteAllText((Join-Path $directory 'result.json'), (@{ ok = $true; version = $installed.version } | ConvertTo-Json))
    Remove-Item -LiteralPath $installer -Force
} catch {
    $message = $_.Exception.Message
    try {
        $root = Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'last-update-error.log'), ([DateTime]::UtcNow.ToString('o') + "`r`n" + $_.ToString() + "`r`n" + $_.ScriptStackTrace))
    } catch { $message += "`r`nThe update failure could not be logged: " + $_.Exception.Message }
    Add-Type -AssemblyName PresentationFramework
    [Windows.MessageBox]::Show($message, 'Demo Player - update failed', 'OK', 'Error') | Out-Null
    exit 1
}
