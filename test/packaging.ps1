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
    Write-Output ('PACKAGING CHECKS PASSED: ' + $assertions + ' assertions, including source syntax, dependency resolution, missing dependencies, user/system/portable VS Code, and paths with spaces.')
} finally {
    $env:LOCALAPPDATA = $original.Local
    $env:ProgramFiles = $original.Program
    ${env:ProgramFiles(x86)} = $original.X86
    $env:ProgramW6432 = $original.W6432
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
