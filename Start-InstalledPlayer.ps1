param(
    [string]$LibraryRoot = (Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\demos'),
    [string]$NodePath,
    [string]$CodePath,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$mutex = $null
$ownsMutex = $false
try {
    . (Join-Path $PSScriptRoot 'PlayerEnvironment.ps1')
    $node = Resolve-PlayerNode $NodePath
    $code = Resolve-PlayerVSCode $CodePath
    if ($Check) {
        [pscustomobject]@{ NodePath = $node; CodePath = $code; LibraryRoot = [IO.Path]::GetFullPath($LibraryRoot) } | ConvertTo-Json
        exit 0
    }
    $mutex = [Threading.Mutex]::new($false, 'Local\VSCodeDemoPlayer.Installed')
    try { $ownsMutex = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Demo Player is already running. Use its existing window or close it before starting another installed instance.' }
    & (Join-Path $PSScriptRoot 'Show-ReplayController.ps1') -LibraryRoot $LibraryRoot -NodePath $node -CodePath $code
} catch {
    if ($Check) { Write-Error $_; exit 1 }
    $message = $_.Exception.Message
    try {
        $logRoot = Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer'
        [IO.Directory]::CreateDirectory($logRoot) | Out-Null
        [IO.File]::WriteAllText((Join-Path $logRoot 'last-startup-error.log'), ([DateTime]::UtcNow.ToString('o') + "`r`n" + $_.ToString() + "`r`n" + $_.ScriptStackTrace))
    } catch { $message += "`r`nThe startup error could not be saved: " + $_.Exception.Message }
    Add-Type -AssemblyName PresentationFramework
    [Windows.MessageBox]::Show($message, 'VS Code Demo Player - startup failed', 'OK', 'Error') | Out-Null
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
