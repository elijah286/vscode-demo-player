param(
    [Parameter(Mandatory = $true)][string]$InstallerPath,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [switch]$KeepInstalled
)

$ErrorActionPreference = 'Stop'
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$installedRoot = Join-Path $env:LOCALAPPDATA 'Programs\VSCodeDemoPlayer'
$executable = Join-Path $installedRoot 'VSCodeDemoPlayer.exe'
if (Test-Path -LiteralPath $executable) { throw 'This acceptance test requires no existing installed Demo Player. It will not uninstall an existing user installation.' }
$evidence = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('installer-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$dataRoot = Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer'
[IO.Directory]::CreateDirectory($dataRoot) | Out-Null
$marker = Join-Path $dataRoot ('installer-preservation-' + [guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText($marker, 'Installer acceptance marker; not a recording.')
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'VS Code Demo Player\VS Code Demo Player.lnk'
$assertions = 0

function Invoke-Setup([string]$Path, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    try {
        if (-not $process.WaitForExit(120000)) { throw ('Installer operation timed out, PID ' + $process.Id) }
        if ($process.ExitCode -ne 0) { throw ('Installer operation failed with exit code ' + $process.ExitCode) }
    } finally { $process.Dispose() }
}
function Assert-Installed {
    foreach ($file in @('VSCodeDemoPlayer.exe', 'Start-InstalledPlayer.ps1', 'runtime\node.exe', 'runtime\NODE-LICENSE.txt', 'native\node_modules\ws\LICENSE', 'native\node_modules\playwright\LICENSE', 'native\node_modules\playwright-core\LICENSE', 'build-info.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $installedRoot $file) -PathType Leaf)) { throw ('Missing installed file: ' + $file) }
        $script:assertions++
    }
    if (-not (Test-Path -LiteralPath $shortcut -PathType Leaf)) { throw 'The Start menu shortcut was not installed.' }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($shortcut)
        if ($link.TargetPath -ne $executable -or $link.WorkingDirectory -ne $installedRoot) { throw 'The Start menu shortcut has an incorrect target or working directory.' }
    } finally { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
    $script:assertions++
    $private = @(Get-ChildItem -LiteralPath $installedRoot -File -Recurse | Where-Object { $_.Name -match '\.jsonl$|\.demo(-recording)?\.json$|\.playlist\.json$|replay-control-' })
    if ($private.Count) { throw 'Private recording material was found in the installed payload.' }
    if (Test-Path -LiteralPath (Join-Path $installedRoot 'native\node_modules\eslint')) { throw 'Development dependencies were shipped.' }
    $script:assertions += 2
    $diagnostics = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installedRoot 'Start-InstalledPlayer.ps1') -Check
    if ($LASTEXITCODE -ne 0) { throw 'Installed dependency preflight failed.' }
    $result = $diagnostics | ConvertFrom-Json
    if ($result.NodePath -ne (Join-Path $installedRoot 'runtime\node.exe')) { throw 'Installed application did not select the bundled Node runtime.' }
    $script:assertions++
}

try {
    Invoke-Setup $installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/LOG="' + (Join-Path $evidence 'install.log') + '"'))
    Assert-Installed
    Invoke-Setup $installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/LOG="' + (Join-Path $evidence 'upgrade.log') + '"'))
    Assert-Installed
    Invoke-Setup (Join-Path $installedRoot 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="' + (Join-Path $evidence 'uninstall.log') + '"'))
    if ((Test-Path -LiteralPath $executable) -or (Test-Path -LiteralPath $shortcut)) { throw 'Uninstall left the launcher or Start menu shortcut behind.' }
    if (-not (Test-Path -LiteralPath $marker)) { throw 'Uninstall deleted user data.' }
    $assertions += 2
    if ($KeepInstalled) {
        Invoke-Setup $installer @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/LOG="' + (Join-Path $evidence 'reinstall.log') + '"'))
        Assert-Installed
    }
    Write-Output ('INSTALLER ACCEPTANCE PASSED: ' + $assertions + ' assertions; install, Start menu target, bundled runtime, private-data exclusion, same-version repair/upgrade, uninstall, and user-data preservation.')
    Write-Output ('Evidence: ' + $evidence)
    if ($KeepInstalled) { Write-Output ('Installed application: ' + $executable) }
} finally {
    Remove-Item -LiteralPath $marker -Force
}
