param(
    [string]$LibraryRoot = (Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\demos'),
    [string]$NodePath,
    [string]$CodePath,
    [switch]$Check,
    [switch]$TaskbarRelaunch
)

$ErrorActionPreference = 'Stop'
$mutex = $null
$ownsMutex = $false
try {
    . (Join-Path $PSScriptRoot 'PlayerEnvironment.ps1')
    if (-not $Check) {
        $mutex = [Threading.Mutex]::new($false, 'Local\VSCodeDemoPlayer.Installed')
        try { $ownsMutex = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'Demo Player is already running. Use its existing window or close it before starting another installed instance.' }
    }
    $profilePath = Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\taskbar-relaunch.json'
    if ($TaskbarRelaunch) {
        if ($PSBoundParameters.ContainsKey('LibraryRoot') -or $NodePath -or $CodePath -or $Check) {
            throw 'TaskbarRelaunch cannot be combined with LibraryRoot, NodePath, CodePath, or Check.'
        }
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
            throw 'The taskbar launch profile is missing. Open VS Code Demo Player from the Start menu, then pin its taskbar icon again.'
        }
        $profile = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @('LibraryRoot', 'NodePath', 'CodePath')) {
            if ($profile.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($profile.$name) -or -not [IO.Path]::IsPathRooted($profile.$name)) {
                throw ('The taskbar launch profile has an invalid ' + $name + '. Open VS Code Demo Player from the Start menu to recreate it.')
            }
        }
        $LibraryRoot = $profile.LibraryRoot
        $NodePath = $profile.NodePath
        $CodePath = $profile.CodePath
    }
    $node = Resolve-PlayerNode $NodePath
    $code = Resolve-PlayerVSCode $CodePath
    if ($Check) {
        [pscustomobject]@{ NodePath = $node; CodePath = $code; LibraryRoot = [IO.Path]::GetFullPath($LibraryRoot) } | ConvertTo-Json
        exit 0
    }
    Add-Type -Path (Join-Path $PSScriptRoot 'PlayerTaskbarIdentity.cs')
    [PlayerTaskbarIdentity]::InitializeProcess()
    # The Shell limits RelaunchCommand to MAX_PATH; keep runtime paths in app-owned data.
    $profile = @{ LibraryRoot = [IO.Path]::GetFullPath($LibraryRoot); NodePath = $node; CodePath = $code }
    [IO.Directory]::CreateDirectory((Split-Path $profilePath -Parent)) | Out-Null
    $profileTemp = $profilePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($profileTemp, ($profile | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        # Windows PowerShell otherwise converts a null backup path to an empty string.
        if (Test-Path -LiteralPath $profilePath) { [IO.File]::Replace($profileTemp, $profilePath, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($profileTemp, $profilePath) }
    } finally {
        if (Test-Path -LiteralPath $profileTemp) { Remove-Item -LiteralPath $profileTemp -Force }
    }
    & (Join-Path $PSScriptRoot 'Show-ReplayController.ps1') -LibraryRoot $LibraryRoot -NodePath $node -CodePath $code -InstalledLauncherPath (Join-Path $PSScriptRoot 'VSCodeDemoPlayer.exe')
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
