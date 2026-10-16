param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedLatestVersion,
    [string]$ApplicationSource,
    [ValidateSet('LiveGitHub', 'AvailableUpdate', 'CheckFailure')][string]$Scenario = 'LiveGitHub'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$application = if ($ApplicationSource) { (Resolve-Path -LiteralPath $ApplicationSource).Path } else { $root }
$fixture = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('source-fixture-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $fixture 'native')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $fixture 'runtime')) | Out-Null
foreach ($name in @('Show-ReplayController.ps1', 'ReplayPresentation.ps1', 'PlayerEnvironment.ps1', 'DemoDialogs.ps1', 'PlayerUpdates.ps1')) {
    Copy-Item -LiteralPath (Join-Path $application $name) -Destination (Join-Path $fixture $name)
}
foreach ($name in @('package.json', 'library-cli.js', 'demo-library.js', 'replay.js', 'saved-parts.js', 'sdk-transcript.js', 'history-catalog.js', 'updater.js')) {
    Copy-Item -LiteralPath (Join-Path $application ('native\' + $name)) -Destination (Join-Path $fixture ('native\' + $name))
}
Copy-Item -LiteralPath $NodePath -Destination (Join-Path $fixture 'runtime\node.exe')
$version = (Get-Content -LiteralPath (Join-Path $application 'native\package.json') -Raw | ConvertFrom-Json).version
if ($Scenario -eq 'AvailableUpdate' -and [version]$ExpectedLatestVersion -le [version]$version) {
    throw 'The AvailableUpdate scenario requires ExpectedLatestVersion to be newer than the application version.'
}
[IO.File]::WriteAllText((Join-Path $fixture 'build-info.json'), (@{ version = $version } | ConvertTo-Json))
# Only a marker for installed-mode UI behavior; never executed or installed.
[IO.File]::WriteAllText((Join-Path $fixture 'VSCodeDemoPlayer.exe'), 'Synthetic source UI fixture marker; not executable.')
if ($Scenario -ne 'LiveGitHub') {
    Copy-Item -LiteralPath (Join-Path $root 'native\test\fixtures\updater-ui-helper.cjs') -Destination (Join-Path $fixture 'native\updater.js') -Force
}
$previous = $env:UPDATER_UI_SCENARIO
$previousLatest = $env:UPDATER_UI_LATEST_VERSION
try {
    $env:UPDATER_UI_SCENARIO = $Scenario
    $env:UPDATER_UI_LATEST_VERSION = $ExpectedLatestVersion
    $options = @{
        ApplicationRoot = $fixture; SourceController = $true; ExpectedCurrentVersion = $version
        ExpectedLatestVersion = $ExpectedLatestVersion; EvidenceRoot = (Join-Path $fixture 'evidence')
        CancelDownload = ($Scenario -eq 'AvailableUpdate'); ExpectCheckFailure = ($Scenario -eq 'CheckFailure')
    }
    & (Join-Path $PSScriptRoot 'updater-ui.ps1') @options
} finally {
    $env:UPDATER_UI_SCENARIO = $previous
    $env:UPDATER_UI_LATEST_VERSION = $previousLatest
}
Write-Output ('Source-only fixture: ' + $fixture)
