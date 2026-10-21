param(
    [Parameter(Mandatory = $true)][string]$ExpectedCurrentVersion,
    [Parameter(Mandatory = $true)][string]$ExpectedLatestVersion,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [string]$ApplicationRoot,
    [switch]$SourceController,
    [switch]$ExpectCheckFailure,
    [switch]$CancelDownload,
    [switch]$InstallUpdate
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System.Threading.Tasks;
using System.Windows.Automation;
public static class UpdateUITest {
    public static Task Invoke(AutomationElement element) {
        var pattern = (InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern);
        return Task.Run(() => pattern.Invoke());
    }
}
'@ -ReferencedAssemblies UIAutomationClient, UIAutomationTypes
$root = Split-Path $PSScriptRoot -Parent
$installed = if ($ApplicationRoot) { (Resolve-Path -LiteralPath $ApplicationRoot).Path } else { Join-Path $env:LOCALAPPDATA 'Programs\VSCodeDemoPlayer' }
$entry = Join-Path $installed $(if ($SourceController) { 'Show-ReplayController.ps1' } else { 'Start-InstalledPlayer.ps1' })
if ($SourceController -and $InstallUpdate) { throw 'SourceController mode cannot run an installer. Only the captain may run shared installation/update acceptance.' }
if (($CancelDownload -or $ExpectCheckFailure) -and -not $SourceController) { throw 'Failure/cancellation fixtures run only in SourceController mode.' }
$evidence = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('update-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$library = Join-Path $evidence 'library'
$script:tasks = [Collections.Generic.List[Threading.Tasks.Task]]::new()
$script:controllerId = 0
$replayId = 0

function Wait-Until([scriptblock]$Action, [string]$Label, [int]$Seconds = 20) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Action
        if ($value) { return $value }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    throw ('Updater UI timeout: ' + $Label)
}
function Find-Control($Parent, [string]$Id) {
    return $Parent.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id))
}
function Get-Window([string]$Name) {
    $condition = [Windows.Automation.AndCondition]::new([Windows.Automation.Condition[]]@(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$script:controllerId),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $Name)
    ))
    return [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}
function Click-Control($Parent, [string]$Id) {
    $control = Find-Control $Parent $Id
    if (-not $control -or -not $control.Current.IsEnabled) { throw ('Unavailable updater test control: ' + $Id) }
    $script:tasks.Add([UpdateUITest]::Invoke($control))
}
function Close-Window($Window) {
    if ($Window) { ([Windows.Automation.WindowPattern]$Window.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern)).Close() }
}
function Get-Controller {
    return Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($entry) -and $_.CommandLine.Contains($library) } | Select-Object -First 1
}
function Save-Image($Window, [string]$Name) {
    $bounds = $Window.Current.BoundingRectangle
    $bitmap = [Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen([int]$bounds.Left, [int]$bounds.Top, 0, 0, $bitmap.Size); $bitmap.Save((Join-Path $evidence $Name)) }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Open-Updates($Window) {
    Click-Control $Window 'CheckUpdates'
    $dialog = Wait-Until { Get-Window 'Demo Player Updates' } 'update dialog'
    Wait-Until {
        (Find-Control $dialog 'LatestVersion').Current.Name -eq $ExpectedLatestVersion -and
        (Find-Control $dialog 'RetryUpdate').Current.IsEnabled
    } 'latest public version is displayed' 40 | Out-Null
    return $dialog
}
function Answer-Confirmation([string]$Answer) {
    $confirmation = Wait-Until { Get-Window 'Install Demo Player update?' } 'explicit install confirmation'
    $button = $confirmation.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $Answer))
    if (-not $button) { throw ('Missing confirmation button: ' + $Answer) }
    $script:tasks.Add([UpdateUITest]::Invoke($button))
    Wait-Until { -not (Get-Window 'Install Demo Player update?') } 'confirmation dismissed' | Out-Null
}

. (Join-Path $root 'DemoDialogs.ps1')
$script:NodePath = Join-Path $installed 'runtime\node.exe'
$script:LibraryRoot = $library
$source = Join-Path $evidence 'synthetic.jsonl'
$snapshot = @{ kind = 0; v = @{ sessionId = 'update-ui-test'; requests = @(@{ result = @{}; message = @{ text = 'This is a synthetic update handoff test.' }; response = @(@{ value = 'The update must stop only this playback and preserve this saved library.' }) }) } }
[IO.File]::WriteAllText($source, ($snapshot | ConvertTo-Json -Depth 15 -Compress) + "`n", [Text.UTF8Encoding]::new($false))
$inspection = Invoke-DemoLibrary @{ command = 'inspect'; file = $source }
$saved = Invoke-DemoLibrary @{ command = 'capture'; file = $source; indices = @(0); title = 'Updater preservation test'; sha256 = $inspection.sha256 }
$recording = Join-Path $library ($saved.id + '.demo.json')
$beforeHash = (Get-FileHash -LiteralPath $recording -Algorithm SHA256).Hash
$start = [Diagnostics.ProcessStartInfo]::new()
if ($SourceController) {
    $start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $entry + '" -LibraryRoot "' + $library + '" -NodePath "' + $script:NodePath + '"'
} else {
    $start.FileName = Join-Path $installed 'VSCodeDemoPlayer.exe'
    $start.Arguments = '-LibraryRoot "' + $library + '"'
}
$start.UseShellExecute = $false
if ($SourceController) { $start.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $evidence 'appdata' }
$launcher = [Diagnostics.Process]::Start($start)
$launcher.Dispose()
try {
    $controller = Wait-Until { Get-Controller } 'installed controller'
    $script:controllerId = [int]$controller.ProcessId
    $window = Wait-Until { Get-Window 'Demo Player' } 'main window'
    Wait-Until { (Find-Control $window 'UpdateNotice').Current.Name -notmatch 'Checking|Not checked' } 'startup update check finishes' 40 | Out-Null
    if ($ExpectCheckFailure) {
        Click-Control $window 'CheckUpdates'
        $failedDialog = Wait-Until { Get-Window 'Demo Player Updates' } 'failure update dialog'
        Wait-Until { (Find-Control $failedDialog 'UpdateStatus').Current.Name -like '*Synthetic offline failure*' } 'visible check failure' 40 | Out-Null
        if ((Find-Control $failedDialog 'CurrentVersion').Current.Name -ne $ExpectedCurrentVersion -or (Find-Control $failedDialog 'InstallUpdate').Current.IsEnabled) { throw 'Failed metadata must not enable installation or hide the installed version.' }
        Save-Image $failedDialog 'check-failure.png'
        Close-Window $failedDialog
        Write-Output 'UPDATE FAILURE UI PASSED: startup/manual offline error visible, installed version retained, install disabled.'
        return
    }
    $dialog = Open-Updates $window
    if ((Find-Control $dialog 'CurrentVersion').Current.Name -ne $ExpectedCurrentVersion) { throw 'The updater displayed an incorrect installed version.' }
    $available = [version]$ExpectedLatestVersion -gt [version]$ExpectedCurrentVersion
    if ((Find-Control $dialog 'InstallUpdate').Current.IsEnabled -ne $available) { throw 'The updater offered the wrong install availability.' }
    Save-Image $dialog 'versions.png'
    if ($available) {
        Click-Control $dialog 'InstallUpdate'
        Answer-Confirmation 'No'
        if (-not (Get-Controller) -or (Get-Content -LiteralPath (Join-Path $installed 'build-info.json') -Raw | ConvertFrom-Json).version -ne $ExpectedCurrentVersion) { throw 'Declining consent changed the application.' }
    }
    if ($CancelDownload) {
        if (-not $available) { throw 'The cancellation fixture must advertise a newer version.' }
        Click-Control $dialog 'InstallUpdate'
        Answer-Confirmation 'Yes'
        Wait-Until { (Find-Control $window 'UpdateNotice').Current.Name -like '*Downloading update*' } 'confirmed download starts' | Out-Null
        Close-Window $dialog
        Wait-Until { (Find-Control $window 'UpdateNotice').Current.Name -like '*Download canceled*' } 'download canceled visibly' | Out-Null
        if (-not (Get-Controller) -or (Get-FileHash -LiteralPath $recording -Algorithm SHA256).Hash -ne $beforeHash) { throw 'Canceling the update closed the app or changed the library.' }
        $pendingRoot = Join-Path $evidence 'appdata\VSCodeDemoPlayer\updates'
        if ((Test-Path -LiteralPath $pendingRoot) -and @(Get-ChildItem -LiteralPath $pendingRoot -Directory).Count) { throw 'Cancellation left a pending download directory.' }
        Write-Output 'UPDATE CANCELLATION UI PASSED: explicit consent, download cancellation, pending-file cleanup, unchanged library, and current app remains open.'
        return
    }
    Close-Window $dialog
    if ($InstallUpdate) {
        if (-not $available) { throw 'A newer published version is required for the real update test.' }
        Click-Control $window 'ChooseDemo'
        $libraryWindow = Wait-Until { Get-Window 'Find interaction' } 'interaction picker'
        ([System.Windows.Automation.SelectionItemPattern](Find-Control $libraryWindow 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        $list = Find-Control $libraryWindow 'DemoList'
        $items = Wait-Until {
            $loaded = $list.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
            if ($loaded.Count -eq 1) { ,$loaded }
        } 'synthetic saved selection finishes loading'
        ([Windows.Automation.SelectionItemPattern]$items[0].GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        Click-Control $libraryWindow 'SelectDemo'
        Wait-Until { (Find-Control $window 'PlayPause').Current.IsEnabled } 'demo selected' | Out-Null
        Click-Control $window 'PlayPause'
        Wait-Until {
            $primary = Find-Control $window 'PlayPause'
            $primary.Current.IsEnabled -and $primary.Current.Name -in @('Play', 'Pause')
        } 'playback target opens' 50 | Out-Null
        if ((Find-Control $window 'PlayPause').Current.Name -eq 'Play') {
            Click-Control $window 'PlayPause'
        }
        Wait-Until { (Find-Control $window 'PlayPause').Current.Name -eq 'Pause' } 'playback starts' 50 | Out-Null
        Click-Control $window 'PlayPause'
        Wait-Until { (Find-Control $window 'PlayPause').Current.Name -eq 'Resume' } 'playback paused' | Out-Null
        $replay = Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($installed) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
        if (-not $replay) { throw 'The isolated playback process was not found.' }
        $replayId = [int]$replay.ProcessId
        $dialog = Open-Updates $window
        Click-Control $dialog 'InstallUpdate'
        Answer-Confirmation 'Yes'
        $oldId = $script:controllerId
        $newController = Wait-Until { $candidate = Get-Controller; if ($candidate -and $candidate.ProcessId -ne $oldId) { $candidate } } 'download, verified install and automatic restart' 240
        $script:controllerId = [int]$newController.ProcessId
        $window = Wait-Until { Get-Window 'Demo Player' } 'restarted app window'
        if (Get-Process -Id $replayId -ErrorAction SilentlyContinue) { throw 'The old isolated playback remained open after updating.' }
        if ((Get-FileHash -LiteralPath $recording -Algorithm SHA256).Hash -ne $beforeHash) { throw 'The update changed the saved demo.' }
        $dialog = Open-Updates $window
        if ((Find-Control $dialog 'CurrentVersion').Current.Name -ne $ExpectedLatestVersion -or (Find-Control $dialog 'InstallUpdate').Current.IsEnabled) { throw 'The restarted app did not show the newly installed version as up to date.' }
        Save-Image $dialog 'updated.png'
        Close-Window $dialog
        Write-Output 'LIVE SELF-UPDATE PASSED: version display, declined consent, confirmed download/hash verification, paused-playback shutdown, installer handoff, automatic restart, and unchanged saved library.'
    } else { Write-Output 'UPDATE UI PASSED: startup check, manual check, installed/latest version display, and same/newer-installed release handling.' }
    Write-Output ('Evidence: ' + $evidence)
} finally {
    Close-Window (Get-Window 'Install Demo Player update?')
    Close-Window (Get-Window 'Demo Player Updates')
    Close-Window (Get-Window 'Find interaction')
    Close-Window (Get-Window 'Demo Player')
    $remaining = Get-Process -Id $script:controllerId -ErrorAction SilentlyContinue
    if ($remaining -and -not $remaining.WaitForExit(20000)) { Write-Warning 'The updater test app did not finish closing normally.' }
    foreach ($task in $script:tasks) {
        if (-not $task.Wait(3000)) { Write-Warning 'An updater test invocation did not finish.' }
    }
}
