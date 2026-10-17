param(
    [string]$InnoCompiler,
    [string]$CacheRoot,
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core') { throw 'Run this build with Windows PowerShell 5.1 (powershell.exe), not pwsh.' }
$root = Split-Path $PSScriptRoot -Parent
if (-not $CacheRoot) { $CacheRoot = Join-Path $root '.build' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $root 'dist' }
$cache = [IO.Path]::GetFullPath($CacheRoot)
$output = [IO.Path]::GetFullPath($OutputRoot)
[IO.Directory]::CreateDirectory($cache) | Out-Null
[IO.Directory]::CreateDirectory($output) | Out-Null
$manifest = Get-Content -LiteralPath (Join-Path $root 'native\package.json') -Raw | ConvertFrom-Json
$version = $manifest.version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'The package version must be a three-part release version.' }
if (-not $InnoCompiler) {
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base) {
            foreach ($relative in @('Inno Setup 6\ISCC.exe', 'Programs\Inno Setup 6\ISCC.exe')) {
                $candidate = Join-Path $base $relative
                if (Test-Path -LiteralPath $candidate) { $InnoCompiler = $candidate; break }
            }
        }
        if ($InnoCompiler) { break }
    }
}
if (-not $InnoCompiler -or -not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) {
    throw 'Inno Setup 6 is required. Install it from https://jrsoftware.org/isdl.php or supply -InnoCompiler pointing to ISCC.exe.'
}

$nodeVersion = '22.23.3'
$archiveName = 'node-v' + $nodeVersion + '-win-x64.zip'
$archiveHash = '2b0ff57b049cda1bbcea2240eec20467018713c1efe1f7360c2681859b90ed71'
$archive = Join-Path $cache $archiveName
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest -UseBasicParsing -Uri ('https://nodejs.org/dist/v' + $nodeVersion + '/' + $archiveName) -OutFile $archive -TimeoutSec 180
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveHash) { throw 'The Node.js archive SHA-256 does not match the pinned official release. Remove the cached archive and retry.' }
$nodeRoot = Join-Path $cache ('node-v' + $nodeVersion + '-win-x64')
if (-not (Test-Path -LiteralPath (Join-Path $nodeRoot 'node.exe'))) { Expand-Archive -LiteralPath $archive -DestinationPath $cache }
$node = Join-Path $nodeRoot 'node.exe'
$npm = Join-Path $nodeRoot 'node_modules\npm\bin\npm-cli.js'
$payload = Join-Path $cache ('payload-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory((Join-Path $payload 'native')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $payload 'runtime')) | Out-Null

$rootFiles = @('Start-InstalledPlayer.ps1', 'Start-DemoPlayer.ps1', 'Start-Replay.ps1', 'Show-ReplayController.ps1', 'DemoDialogs.ps1', 'ReplayPresentation.ps1', 'PlayerEnvironment.ps1', 'PlayerUpdates.ps1', 'Install-PlayerUpdate.ps1', 'README.md')
$nativeFiles = @('package.json', 'package-lock.json', 'native-extension.js', 'native-response.js', 'native-composer.js', 'recording-agent-host.js', 'replay.js', 'saved-parts.js', 'sdk-transcript.js', 'history-catalog.js', 'control-server.js', 'demo-library.js', 'library-cli.js', 'updater.js', 'prompt-summary-authoring.js')
foreach ($file in $rootFiles) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $payload $file) }
foreach ($file in $nativeFiles) { Copy-Item -LiteralPath (Join-Path $root ('native\' + $file)) -Destination (Join-Path $payload ('native\' + $file)) }
Copy-Item -LiteralPath $node -Destination (Join-Path $payload 'runtime\node.exe')
Copy-Item -LiteralPath (Join-Path $nodeRoot 'LICENSE') -Destination (Join-Path $payload 'runtime\NODE-LICENSE.txt')
& $node $npm ci --omit=dev --ignore-scripts --no-audit --no-fund --prefix (Join-Path $payload 'native')
if ($LASTEXITCODE -ne 0) { throw 'Installing the locked production dependencies failed.' }
& $node -e "for (const name of process.argv.slice(1)) require(name);" (Join-Path $payload 'native\native-composer.js') (Join-Path $payload 'native\native-response.js') (Join-Path $payload 'native\recording-agent-host.js') (Join-Path $payload 'native\demo-library.js') (Join-Path $payload 'native\updater.js')
if ($LASTEXITCODE -ne 0) { throw 'The production payload cannot load its runtime dependencies.' }
$environment = @{
    version = $version
    architecture = 'win-x64'
    node = $nodeVersion
    nodeArchiveSha256 = $archiveHash
    minimumVSCode = $manifest.engines.vscode
}
$environment | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $payload 'build-info.json') -Encoding UTF8

$compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$launcher = Join-Path $payload 'VSCodeDemoPlayer.exe'
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Windows.Forms.dll ("/out:$launcher") (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Compiling the Windows launcher failed.' }

& $InnoCompiler /Qp ("/DAppVersion=$version") ("/DPayloadDir=$payload") ("/DArtifactDir=$output") (Join-Path $PSScriptRoot 'DemoPlayer.iss')
if ($LASTEXITCODE -ne 0) { throw 'Building the Windows installer failed.' }
$installer = Join-Path $output 'VSCodeDemoPlayer-Setup.exe'
$digest = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $output 'SHA256SUMS.txt'), ($digest + '  VSCodeDemoPlayer-Setup.exe' + "`n"), [Text.UTF8Encoding]::new($false))
Write-Output ('Installer: ' + $installer)
Write-Output ('Payload: ' + $payload)
