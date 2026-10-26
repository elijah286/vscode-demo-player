param(
    [string]$LibraryRoot = (Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\demos'),
    [string]$NodePath,
    [string]$CodePath,
    [string]$DemoId
)

$ErrorActionPreference = 'Stop'
$controller = Join-Path $PSScriptRoot 'Show-ReplayController.ps1'
$arguments = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $controller + '"'), '-LibraryRoot', ('"' + [System.IO.Path]::GetFullPath($LibraryRoot) + '"'))
if ($NodePath) { $arguments += @('-NodePath', ('"' + (Resolve-Path -LiteralPath $NodePath).Path + '"')) }
if ($CodePath) { $arguments += @('-CodePath', ('"' + (Resolve-Path -LiteralPath $CodePath).Path + '"')) }
if ($DemoId) {
    $id = [guid]::ParseExact($DemoId, 'D').ToString('D')
    $arguments += @('-DemoId', $id)
}
$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.Arguments = $arguments -join ' '
$process = [System.Diagnostics.Process]::Start($start)
if (-not $process) { throw 'Demo Player could not be started.' }
[pscustomobject]@{ ProcessId = $process.Id; LibraryRoot = $LibraryRoot }
