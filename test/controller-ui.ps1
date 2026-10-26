param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [string]$ApplicationRoot,
    [switch]$Installed,
    [switch]$PlaybackOnly,
    [switch]$SummaryOnly,
    [switch]$RecoveryOnly,
    [switch]$DecoderOnly,
    [switch]$TranslationOnly,
    [switch]$PickerOnly,
    [switch]$LargeSummarySources
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System.Threading.Tasks;
using System.Windows.Automation;
public static class DemoUITest {
    private delegate bool EnumWindowCallback(System.IntPtr handle, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowCallback callback, System.IntPtr parameter);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(System.IntPtr handle, out uint processId);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int GetWindowText(System.IntPtr handle, System.Text.StringBuilder text, int count);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int GetWindowTextLength(System.IntPtr handle);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool IsWindowVisible(System.IntPtr handle);
    public static AutomationElement FindWindow(int processId, string title) {
        var found = System.IntPtr.Zero;
        bool completed = EnumWindows((handle, parameter) => {
            uint owner;
            GetWindowThreadProcessId(handle, out owner);
            if (owner != processId || !IsWindowVisible(handle)) return true;
            var text = new System.Text.StringBuilder(GetWindowTextLength(handle) + 1);
            GetWindowText(handle, text, text.Capacity);
            if (text.ToString() != title) return true;
            found = handle;
            return false;
        }, System.IntPtr.Zero);
        if (found != System.IntPtr.Zero) {
            try {
                var element = AutomationElement.FromHandle(found);
                return element.Current.ControlType == ControlType.Window ? element : null;
            } catch (ElementNotAvailableException) {
                return null;
            }
        }
        if (!completed) throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        return null;
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
    public static void Drag(int x, int y, int dx, int dy) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(100);
        mouse_event(2, 0, 0, 0, System.UIntPtr.Zero);
        System.Threading.Thread.Sleep(100);
        try {
            for (int step = 1; step <= 10; step++) {
                SetCursorPos(x + dx * step / 10, y + dy * step / 10);
                System.Threading.Thread.Sleep(30);
            }
        } finally { mouse_event(4, 0, 0, 0, System.UIntPtr.Zero); }
    }
    public static Task Invoke(AutomationElement element) {
        var pattern = (InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern);
        return Task.Run(() => pattern.Invoke());
    }
}
'@ -ReferencedAssemblies UIAutomationClient, UIAutomationTypes
$root = if ($ApplicationRoot) { (Resolve-Path -LiteralPath $ApplicationRoot).Path } else { Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'compact-automation.ps1')
$evidence = Join-Path ([System.IO.Path]::GetFullPath($EvidenceRoot)) ('run-' + [guid]::NewGuid().ToString('N'))
$env:VSCODE_DEMO_PLAYER_SUMMARY_ROOT = Join-Path $evidence 'summary-authoring'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
Write-Output ('UI evidence: ' + $evidence)
$testCodePath = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'
$openAIPreload = Join-Path $evidence 'openai-preload.js'
[IO.File]::WriteAllText($openAIPreload, @'
const fs = require('node:fs');
const path = require('node:path');
if (process.argv[1]?.endsWith('library-cli.js')) {
    const promises = require('node:fs/promises');
    const open = promises.open;
    promises.open = async (...args) => {
        if (String(args[0]).endsWith('.demo.json') && fs.existsSync(path.join(__dirname, 'delay-library'))) {
            await new Promise(resolve => setTimeout(resolve, 5000));
        }
        return open(...args);
    };
}
if (process.argv[1]?.endsWith('library-cli.js') || process.argv[1]?.endsWith('library-worker.js')) {
    const write = process.stdout.write.bind(process.stdout);
    process.stdout.write = (text, ...args) => {
        if (typeof text === 'string' && text.trim().startsWith('{')) {
            const response = JSON.parse(text);
            if (response.ok && Array.isArray(response.result) && typeof response.result[0]?.issue === 'string') {
                if (fs.existsSync(path.join(__dirname, 'fail-validation'))) {
                    response.ok = false;
                    response.error = 'Synthetic local validation failure.';
                    delete response.result;
                    text = JSON.stringify(response) + '\n';
                }
                if (fs.existsSync(path.join(__dirname, 'delay-validation'))) {
                    setTimeout(() => write(text, ...args), 2000);
                    return true;
                }
            }
        }
        return write(text, ...args);
    };
}
if (!process.argv[1]?.endsWith('openai-summaries.js')) return;
const write = process.stdout.write.bind(process.stdout);
process.stdout.write = (text, ...args) => {
    const marker = path.join(__dirname, 'legacy-review-draft');
    const response = JSON.parse(text);
    if (fs.existsSync(marker) && response.ok && typeof response.result === 'string' && response.result.includes('output')) {
        response.result = 'I checked ' + 'x'.repeat(1446) + '.';
        text = JSON.stringify(response);
    }
    return write(text, ...args);
};
global.fetch = async (url, options) => {
    if (url !== 'https://api.openai.com/v1/responses') throw new Error('Unexpected synthetic API endpoint');
    if (!['synthetic-openai-key-for-ui-tests', 'synthetic-replaced-openai-key-for-ui-tests'].some(key => options.headers.Authorization === 'Bearer ' + key)) throw new Error('Unexpected synthetic key');
    const body = JSON.parse(options.body);
    if (body.store !== false || body.tools || options.redirect !== 'error') throw new Error('Unsafe synthetic API request');
    const languages = {
        'Simplified Chinese': '\u6211\u9009\u62e9\u84dd\u8272\u3002\u8981\u7ee7\u7eed\u5417\uff1f',
        French: 'Je choisis le bleu. Continuer ?',
        German: 'Ich w\u00e4hle Blau. Fortfahren?',
        Italian: 'Scelgo il blu. Continuare?',
        English: 'I choose blue. Continue?'
    };
    if (body.input.startsWith('Translate this presentation summary into ')) {
        const language = Object.keys(languages).find(name => body.input.startsWith('Translate this presentation summary into ' + name));
        const marker = 'Source summary (JSON): ';
        const source = JSON.parse(body.input.slice(body.input.lastIndexOf(marker) + marker.length));
        if (!language || !/^Synthetic OpenAI (input|output) summary\.$/.test(source)) throw new Error('Translation leaked original exchanges or unexpected context');
        const schema = body.text?.format?.schema?.properties?.summary;
        if (body.text.format.strict !== true || JSON.stringify(schema) !== '{"type":"string"}') throw new Error('Translation restored a decoder character cap or lost strict structure');
        fs.appendFileSync(path.join(__dirname, 'translation-requests.jsonl'), JSON.stringify({ language, source, schema }) + '\n');
        return Response.json({ status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: JSON.stringify({ summary: languages[language] }) }] }] });
    }
    const kind = body.input.startsWith('Summarize what the recorded assistant') ? 'output' : 'input';
    const correcting = body.input.includes('AUTOMATIC LENGTH CORRECTION:');
    const schema = body.text?.format?.schema?.properties?.summary;
    if (body.text.format.strict !== true || JSON.stringify(schema) !== '{"type":"string"}') throw new Error('Generation restored a decoder character cap or lost strict structure');
    fs.appendFileSync(path.join(__dirname, 'openai-requests.jsonl'), JSON.stringify({ kind, model: body.model, correcting, schema }) + '\n');
    const reject = path.join(__dirname, 'reject-next-key');
    if (fs.existsSync(reject)) { fs.unlinkSync(reject); return Response.json({ error: { message: 'Synthetic rejected key' } }, { status: 401 }); }
    if (fs.existsSync(path.join(__dirname, 'delay-summary'))) return new Promise(() => {});
    if (correcting && fs.existsSync(path.join(__dirname, 'delay-rewrite'))) await new Promise(resolve => setTimeout(resolve, 2500));
    const overflow = path.join(__dirname, 'overlong-summary');
    const length = kind === 'output' && !correcting && fs.existsSync(overflow) ? Number(fs.readFileSync(overflow, 'utf8')) : 0;
    const complete = 'I want automated tests for the synthetic dashboard, including plugin loading, failed connections and runtime errors. '.repeat(3) + 'I need to build and maintain automated tests.';
    const summary = fs.existsSync(path.join(__dirname, 'decoder-complete')) ? complete :
        kind === 'output' && fs.existsSync(path.join(__dirname, 'recover-output')) ? 'I set a !' :
        length ? 'I checked ' + 'x'.repeat(length - 11) + '.' : correcting ? 'I checked the result. Should I use blue or green?' : 'Synthetic OpenAI ' + kind + ' summary.';
    return Response.json({ status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: JSON.stringify({ summary }) }] }] });
};
'@)
$library = Join-Path $evidence 'library'
$source = Join-Path $evidence 'synthetic-source.jsonl'
$target = Join-Path $evidence 'synthetic-target.txt'
$targetContent = 'LIVE FILE SENTINEL - must not be read to reconstruct or changed by playback.'
$replacement = 'SYNTHETIC_SAVED_REPLACEMENT' + "`n" + '```' + "`n" + '[saved text, not a command](command:example.run)'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($target, $targetContent, $utf8)
$snapshot = @{
    kind = 0
    v = @{
        sessionId = 'synthetic-ui-test'
        customTitle = 'Synthetic UI acceptance'
        responderUsername = 'Recorded Assistant'
        requests = @(
            @{ timestamp = 1700000000000; modelState = @{ completedAt = 1700000061000 }; result = @{}; message = @{ text = 'Show the first recorded interaction.' }; response = @(
                @{ value = 'First recorded answer for the Demo Player acceptance test.' },
                @{ kind = 'inlineReference'; name = 'Synthetic saved reference'; inlineReference = @{ scheme = 'file'; path = '/synthetic/source.txt' } },
                @{
                    kind = 'textEditGroup'; uri = @{ fsPath = $target }; done = $true
                    edits = ,@(@{ text = $replacement; range = @{ startLineNumber = 1; startColumn = 1; endLineNumber = 1; endColumn = 1 } })
                    state = @{ applied = 1; sha1 = 'synthetic-original-metadata' }
                }
            ) },
            @{ timestamp = 1700001000000; modelState = @{ completedAt = 1700001122000 }; result = @{}; message = @{ text = 'Show the next recorded interaction.' }; response = @(@{ value = 'Second recorded answer. No live model or tools were invoked.' }) },
            @{ message = @{ text = 'Interrupted native request without a completion result.' }; response = @(@{ value = 'Some text was saved, but completion was not.' }) }
        )
    }
}
[System.IO.File]::WriteAllText($source, ($snapshot | ConvertTo-Json -Depth 20 -Compress) + "`n", $utf8)
if ($LargeSummarySources) {
    $snapshot.v.requests[1].response[0].value += (' Synthetic saved response text.' * 40000) + ' Final synthetic outcome: failed.'
    [System.IO.File]::WriteAllText($source, ($snapshot | ConvertTo-Json -Depth 20 -Compress) + "`n", $utf8)
}
$sourceBeforeCapture = [IO.File]::ReadAllText($source)
. (Join-Path $root 'DemoDialogs.ps1')
$script:NodePath = (Resolve-Path -LiteralPath $NodePath).Path
$script:LibraryRoot = $library
$inspection = Invoke-DemoLibrary @{ command = 'inspect'; file = $source }
$saved = Invoke-DemoLibrary @{ command = 'capture'; file = $source; indices = @(0,1); title = 'Synthetic UI demo'; sha256 = $inspection.sha256 }

function Find-Element($Parent, [string]$Property, [string]$Value) {
    if ($Property -eq 'Id') { Expand-CompactControllerTools $Parent $Value }
    $identifier = switch ($Property) {
        'Name' { [System.Windows.Automation.AutomationElement]::NameProperty }
        'Id' { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    }
    $condition = [System.Windows.Automation.PropertyCondition]::new($identifier, $Value)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        if ($Parent.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window) {
            $currentWindow = [DemoUITest]::FindWindow($Parent.Current.ProcessId, $Parent.Current.Name)
            if ($currentWindow) { $Parent = $currentWindow }
        }
        $element = $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw ('UI element did not become available: ' + $Property + '=' + $Value)
}

function Wait-Until([scriptblock]$Check, [string]$Description, [int]$Seconds = 60) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $value = & $Check
        if ($value) { return $value }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw ('UI acceptance timed out: ' + $Description)
}

function Get-AppWindow([string]$Title) {
    # Owned modal HWNDs must be found without traversing unrelated desktop controls.
    if ($Title -eq 'Demo Player') {
        $compact = [DemoUITest]::FindWindow([int]$script:controllerId, 'VibeReplay - Demo Player')
        if ($compact) { return $compact }
    }
    return [DemoUITest]::FindWindow([int]$script:controllerId, $Title)
}

function Invoke-DialogButton($Parent, [string]$Name) {
    $title = $Parent.Current.Name
    $button = Wait-Until {
        $dialog = Get-AppWindow $title
        if (-not $dialog) { return $null }
        $condition = [System.Windows.Automation.AndCondition]::new([System.Windows.Automation.Condition[]]@(
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        ))
        $candidate = $dialog.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($candidate -and $candidate.Current.IsEnabled) {
            $pattern = $null
            if ($candidate.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { return $candidate }
        }
    } ('invokable dialog button: ' + $Name)
    $script:tasks.Add([DemoUITest]::Invoke($button))
}

function Invoke-Button($Parent, [string]$Id) {
    $element = Wait-Until {
        $candidate = Find-Element $Parent 'Id' $Id
        if ($candidate -and $candidate.Current.IsEnabled) { return $candidate }
    } ('enabled UI button: ' + $Id)
    $script:tasks.Add([DemoUITest]::Invoke($element))
}

function Invoke-AISummaryAction($Parent, [string]$Scope = 'Both') {
    Invoke-Button $Parent 'AiPromptSummaries'
    $scopeDialog = Wait-Until { Get-AppWindow 'Generate AI summaries' } 'one consolidated summary action'
    ([System.Windows.Automation.SelectionItemPattern](Find-Element $scopeDialog 'Id' ('SummaryScope' + $Scope)).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Invoke-Button $scopeDialog 'ContinueSummaryScope'
}

function Get-ComboItem($Combo, [string]$Name) {
    Wait-Until { $Combo.Current.IsEnabled } ('enabled combo: ' + $Name) | Out-Null
    ([System.Windows.Automation.ExpandCollapsePattern]$Combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
    $item = Find-Element $Combo 'Name' $Name
    for ($depth = 0; $item -and $depth -lt 8; $depth++) {
        if ($item.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::IsSelectionItemPatternAvailableProperty)) { break }
        $item = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($item)
    }
    if (-not $item -or -not $item.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::IsSelectionItemPatternAvailableProperty)) {
        throw ('Selectable combo item unavailable: ' + $Name)
    }
    return $item
}

function Select-ComboItem($Combo, [string]$Name) {
    $item = Get-ComboItem $Combo $Name
    ([System.Windows.Automation.SelectionItemPattern]$item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Wait-Until { $Combo.Current.IsEnabled } ('selected combo ready: ' + $Name) | Out-Null
    ([System.Windows.Automation.ExpandCollapsePattern]$Combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Collapse()
}

function Save-WindowImage($Element, [string]$Name) {
    $Element.SetFocus()
    $bounds = $Element.Current.BoundingRectangle
    $image = [System.Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($image)
    try {
        $graphics.CopyFromScreen([int]$bounds.Left, [int]$bounds.Top, 0, 0, $image.Size)
        $image.Save((Join-Path $evidence $Name), [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $image.Dispose() }
}

function Start-TestPlayer {
    if (-not $Installed) {
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Show-ReplayController.ps1') + '" -LibraryRoot "' + $library + '" -NodePath "' + $NodePath + '" -CodePath "' + $testCodePath + '"'
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.EnvironmentVariables['NODE_OPTIONS'] = '--require "' + $openAIPreload.Replace('\', '\\') + '"'
        $script:controllerProcess = [Diagnostics.Process]::Start($start)
        $script:controllerOutput = $script:controllerProcess.StandardOutput.ReadToEndAsync()
        $script:controllerErrors = $script:controllerProcess.StandardError.ReadToEndAsync()
        return [pscustomobject]@{ ProcessId = $script:controllerProcess.Id }
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $root 'VSCodeDemoPlayer.exe'
    $start.Arguments = '-LibraryRoot "' + $library + '" -CodePath "' + $testCodePath + '"'
    $start.UseShellExecute = $false
    $start.EnvironmentVariables['NODE_OPTIONS'] = '--require "' + $openAIPreload.Replace('\', '\\') + '"'
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(10000) -or $process.ExitCode -ne 0) { throw 'Installed launcher failed to start.' }
    } finally { $process.Dispose() }
    $controller = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains((Join-Path $root 'Start-InstalledPlayer.ps1')) -and $_.CommandLine.Contains($library)
        } | Select-Object -First 1
    } 'installed controller process'
    return [pscustomobject]@{ ProcessId = $controller.ProcessId }
}

function Stop-FailedTestControllers {
    $owned = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine.Contains($library) -and
        ($_.CommandLine.Contains((Join-Path $root 'Show-ReplayController.ps1')) -or
         $_.CommandLine.Contains((Join-Path $root 'Start-InstalledPlayer.ps1')))
    })
    foreach ($candidate in $owned) {
        Stop-Process -Id $candidate.ProcessId -ErrorAction Stop
        Write-Warning ('Stopped owned failed-test controller ' + $candidate.ProcessId + '; the real library and unrelated applications were not touched.')
    }
}

$tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
$originalAppData = $env:APPDATA
$originalProfile = $env:USERPROFILE
$originalLocalAppData = $env:LOCALAPPDATA
$env:APPDATA = Join-Path $evidence 'AppData'
$env:USERPROFILE = Join-Path $evidence 'Home'
$env:LOCALAPPDATA = Join-Path $evidence 'LocalAppData'
$storage = Join-Path $env:APPDATA ('Code\User\workspaceStorage\' + ('a' * 32))
[IO.Directory]::CreateDirectory((Join-Path $storage 'chatSessions')) | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $storage 'chatSessions\synthetic.jsonl')
[IO.File]::WriteAllText((Join-Path $storage 'workspace.json'), (@{ folder = ([Uri]$evidence).AbsoluteUri } | ConvertTo-Json -Compress), $utf8)
$sdkId = '12345678-1234-1234-1234-123456789abc'
$sdkSource = Join-Path $env:USERPROFILE ('.copilot\session-state\' + $sdkId + '\events.jsonl')
[IO.Directory]::CreateDirectory((Split-Path $sdkSource -Parent)) | Out-Null
$sdkRecords = @(
    @{ type = 'session.start'; timestamp = '2026-10-16T12:00:00Z'; data = @{ version = 1; sessionId = $sdkId; producer = 'Synthetic SDK Agent'; context = @{ cwd = 'C:\Synthetic\SDKProject' } } },
    @{ type = 'user.message'; timestamp = '2026-10-16T12:00:01Z'; data = @{ content = 'First synthetic SDK prompt' } },
    @{ type = 'assistant.message'; timestamp = '2026-10-16T12:00:02Z'; data = @{ content = 'Before the saved tool. '; toolRequests = @(@{ name = 'recorded-only-no-execution' }) } },
    @{ type = 'tool.execution_start'; timestamp = '2026-10-16T12:00:02.100Z'; data = @{ toolCallId = 'sdk-tool'; toolName = 'recorded-only-no-execution'; arguments = @{ target = $target } } },
    @{ type = 'tool.execution_complete'; timestamp = '2026-10-16T12:00:02.200Z'; data = @{ toolCallId = 'sdk-tool'; success = $true; result = @{ content = '[Saved text, not a command](command:never.run)' } } },
    @{ type = 'assistant.message'; timestamp = '2026-10-16T12:00:02.300Z'; data = @{ content = 'First SDK final answer' } },
    @{ type = 'assistant.turn_end'; timestamp = '2026-10-16T12:00:03Z'; data = @{} },
    @{ type = 'user.message'; timestamp = '2026-10-16T12:00:04Z'; data = @{ content = 'Second synthetic SDK prompt' } },
    @{ type = 'assistant.message'; timestamp = '2026-10-16T12:00:05Z'; data = @{ content = 'Second SDK final answer' } },
    @{ type = 'assistant.turn_end'; timestamp = '2026-10-16T12:00:06Z'; data = @{} }
)
[IO.File]::WriteAllText($sdkSource, (($sdkRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress }) -join "`n") + "`n", $utf8)
$uiFailed = $false
$replayId = 0
try {
    $launch = Start-TestPlayer
    $script:controllerId = $launch.ProcessId
    $window = Wait-Until { Get-AppWindow 'Demo Player' } 'standalone controller'
    if ($PickerOnly) {
        $mixedSource = Join-Path $evidence 'mixed-events.jsonl'
        $eventRequests = @(0..5 | ForEach-Object {
            @{ result = @{}; message = @{ text = $(if ($_ -in @(2,5)) { '' } else { 'Recorded event prompt ' + $_ }) }
                response = @(@{ kind = 'recordedSdkEvent'; events = @(@{ type = 'synthetic.saved.event'; data = @{ index = $_ } }) }) }
        })
        [IO.File]::WriteAllText($mixedSource, (@{kind=0;v=@{requests=$eventRequests}} | ConvertTo-Json -Depth 20 -Compress), $utf8)
        $mixedBefore = [IO.File]::ReadAllText($mixedSource)
        Invoke-Button $window 'ChooseDemo'
        $capture = Wait-Until { Get-AppWindow 'Find interaction' } 'mixed-availability picker'
        ([System.Windows.Automation.SelectionItemPattern](Find-Element $capture 'Id' 'AgentConversationsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        $sourceBox = Wait-Until { $box = Find-Element $capture 'Id' 'CaptureSource'; if ($box.Current.IsEnabled) { $box } } 'discovery finishes before loading mixed source' 65
        ([System.Windows.Automation.ValuePattern]$sourceBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($mixedSource)
        Invoke-Button $capture 'Load'
        Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '4 of 6 exchanges selected' } 'four read-only event exchanges available by default' | Out-Null
        if ((Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled) { throw 'Picker enabled capture before privacy review.' }
        Invoke-Button $capture 'CaptureSelectAll'
        $reviewed = Find-Element $capture 'Id' 'CaptureReviewed'
        Wait-Until { $reviewed.Current.IsEnabled -and (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '6 of 6 exchanges selected' } 'mixed selection preview ready' | Out-Null
        ([System.Windows.Automation.TogglePattern]$reviewed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
        Wait-Until { (Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled } 'available subset actionable after review' | Out-Null
        if ((Find-Element $capture 'Id' 'SaveDemo').Current.Name -ne 'Use 4 available exchanges' -or
            (Find-Element $capture 'Id' 'CaptureStatus').Current.Name -notmatch '2 unavailable selected exchanges will be skipped') { throw 'Mixed selection did not explain the exact available subset.' }
        foreach ($id in @('SelectionSummaries','SelectionAiSummaries','SelectionClearSummaries')) {
            if (-not (Find-Element $capture 'Id' $id).Current.IsEnabled) { throw ('Mixed selection blocked summary action: ' + $id) }
        }
        Save-WindowImage $capture 'mixed-available-actions.png'
        Invoke-Button $capture 'SaveDemo'
        Wait-Until { -not (Get-AppWindow 'Find interaction') -and (Find-Element $window 'Id' 'ChooseDemo').Current.IsEnabled } 'capture uses only four available exchanges' | Out-Null
        $captured = @(Invoke-DemoLibrary @{command='list'}) | Where-Object id -ne $saved.id
        if (@($captured).Count -ne 1 -or $captured.count -ne 4) { throw 'Mixed capture did not persist exactly four available exchanges.' }
        $entry = Invoke-DemoLibrary @{command='read';id=$captured.id}
        if ((@($entry.recording.turns | ForEach-Object sourceIndex) -join ',') -cne '0,1,3,4') { throw 'Mixed capture lost stable original indices.' }
        $badSource = Join-Path $evidence 'unavailable-events.jsonl'
        [IO.File]::WriteAllText($badSource, (@{kind=0;v=@{requests=@($eventRequests[2],$eventRequests[5])}} | ConvertTo-Json -Depth 20 -Compress), $utf8)
        Invoke-Button $window 'ChooseDemo'
        $capture = Wait-Until { Get-AppWindow 'Find interaction' } 'all-unavailable picker'
        ([System.Windows.Automation.SelectionItemPattern](Find-Element $capture 'Id' 'AgentConversationsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        $sourceBox = Wait-Until { $box = Find-Element $capture 'Id' 'CaptureSource'; if ($box.Current.IsEnabled) { $box } } 'discovery finishes before loading unavailable source' 65
        ([System.Windows.Automation.ValuePattern]$sourceBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($badSource)
        Invoke-Button $capture 'Load'
        Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '0 of 2 exchanges selected' } 'all unavailable entries remain visible' | Out-Null
        Invoke-Button $capture 'CaptureSelectAll'
        Wait-Until { (Find-Element $capture 'Id' 'CaptureStatus').Current.Name -match 'No available selected exchanges' } 'explicit all-unavailable feedback' | Out-Null
        foreach ($id in @('SaveDemo','SelectionSummaries','SelectionAiSummaries','SelectionClearSummaries')) {
            if ((Find-Element $capture 'Id' $id).Current.IsEnabled) { throw ('All-unavailable selection enabled action: ' + $id) }
        }
        if ([IO.File]::ReadAllText($mixedSource) -cne $mixedBefore -or [IO.File]::ReadAllText($source) -cne $sourceBeforeCapture -or
            (Test-Path (Join-Path $evidence 'openai-requests.jsonl'))) { throw 'Picker changed a source or sent an AI request.' }
        ([System.Windows.Automation.WindowPattern]$capture.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
        Write-Output 'PICKER UI ACCEPTANCE PASSED: six exchanges/two unavailable; default four read-only event exchanges, explicit mixed subset and enabled capture/summary actions after privacy review, exact stable indices0,1,3,4 persisted, all-unavailable entries visible with disabled actions and explicit feedback; no source changes or AI requests.'
        return
    }
    if ($SummaryOnly -or $TranslationOnly -or $RecoveryOnly -or $DecoderOnly) {
        $entryPath = Join-Path $library ($saved.id + '.demo.json')
        $before = [IO.File]::ReadAllText($entryPath)
        Invoke-Button $window 'ChooseDemo'
        $dialog = Wait-Until { Get-AppWindow 'Find interaction' } 'summary action picker'
        ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        $item = Wait-Until {
            $list = Find-Element $dialog 'Id' 'DemoList'
            $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
            if ($items.Count -eq 1) { return $items[0] }
        } 'saved synthetic entry for constrained summaries'
        ([System.Windows.Automation.SelectionItemPattern]$item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        Invoke-Button $dialog 'AiPromptSummaries'
        $scopeDialog = Wait-Until { Get-AppWindow 'Generate AI summaries' } 'scope cancellation'
        Invoke-Button $scopeDialog 'CancelSummaryScope'
        Wait-Until { -not (Get-AppWindow 'Generate AI summaries') } 'scope cancellation returns to selection' | Out-Null
        if ([IO.File]::ReadAllText($entryPath) -cne $before -or (Test-Path (Join-Path $evidence 'openai-requests.jsonl'))) { throw 'Cancelling scope wrote data or sent a request.' }
        if ($RecoveryOnly) {
            [IO.File]::WriteAllText((Join-Path $evidence 'recover-output'), 'synthetic completed content rejection', $utf8)
            foreach ($action in @('Cancel', 'Save')) {
                Invoke-AISummaryAction $dialog 'Both'
                if ($action -eq 'Cancel') {
                    $settingsDialog = Wait-Until { Get-AppWindow 'OpenAI Settings' } 'synthetic key for recovered generation'
                    ([System.Windows.Automation.ValuePattern](Find-Element $settingsDialog 'Id' 'OpenAIKey').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('synthetic-openai-key-for-ui-tests')
                    Invoke-Button $settingsDialog 'SaveOpenAISettings'
                }
                $consent = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'recovery source/charge consent'
                Invoke-Button $consent 'ConfirmOpenAIGeneration'
                $review = Wait-Until { Get-AppWindow 'Review AI Summaries' } 'exhausted drafts retained in review'
                if ((Find-Element $review 'Id' 'SummaryReviewInstructions').Current.Name -notmatch 'recovered below, not approved or saved') { throw 'Recovered drafts lack an explicit warning.' }
                Wait-Until { (Find-Element $review 'Id' 'SummaryReviewStatus').Current.Name -match 'recovered draft needs correction' } 'authoritative local validation rejects recovered draft' | Out-Null
                if ((Find-Element $review 'Id' 'SaveSummaries').Current.IsEnabled) { throw 'Rejected recovered drafts enabled Save.' }
                $inputDraft = (Find-Element $review 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
                if ($inputDraft -cne 'Synthetic OpenAI input summary.') { throw 'A later rejected output discarded the earlier valid input draft.' }
                Select-ComboItem (Find-Element $review 'Id' 'SummaryExchange') 'Exchange 1 - Output (AI)'
                $box = [System.Windows.Automation.ValuePattern](Find-Element $review 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                if ($box.Current.Value -cne 'I set a !') { throw 'The exact completed rejected draft was lost or altered.' }
                if ($action -eq 'Save') {
                    $delayValidation = Join-Path $evidence 'delay-validation'
                    [IO.File]::WriteAllText($delayValidation, 'synthetic local validation delay', $utf8)
                    $box.SetValue('I updated the!')
                    Wait-Until { (Find-Element $review 'Id' 'SummaryReviewStatus').Current.Name -match 'Checking recovered AI drafts' } 'Save guarded during asynchronous validation' | Out-Null
                    if ((Find-Element $review 'Id' 'SaveSummaries').Current.IsEnabled) { throw 'Pending validation enabled Save.' }
                    Wait-Until { (Find-Element $review 'Id' 'SummaryReviewStatus').Current.Name -match 'recovered draft needs correction' } 'invalid edited draft remains rejected' | Out-Null
                    if ((Find-Element $review 'Id' 'SaveSummaries').Current.IsEnabled) { throw 'Invalid edits bypassed recovered draft validation.' }
                    Remove-Item -LiteralPath $delayValidation
                    $failValidation = Join-Path $evidence 'fail-validation'
                    [IO.File]::WriteAllText($failValidation, 'synthetic local validation failure', $utf8)
                    $box.SetValue('I checked the result.')
                    Wait-Until { (Find-Element $review 'Id' 'SummaryReviewStatus').Current.Name -match 'validation failed:.*Synthetic local validation failure' } 'local validation failure is explicit and blocks Save' | Out-Null
                    if ((Find-Element $review 'Id' 'SaveSummaries').Current.IsEnabled) { throw 'Local validation failure enabled Save.' }
                    Remove-Item -LiteralPath $failValidation
                    $box.SetValue('I checked the result. (It passed.)')
                    Select-ComboItem (Find-Element $review 'Id' 'SummaryExchange') 'Exchange 2 - Output (AI)'
                    Invoke-Button $review 'DeletePromptSummary'
                    Wait-Until { (Find-Element $review 'Id' 'SaveSummaries').Current.IsEnabled } 'corrected and explicitly deleted drafts can save' | Out-Null
                    Invoke-Button $review 'SaveSummaries'
                } else { Invoke-Button $review 'Cancel' }
                Wait-Until { -not (Get-AppWindow 'Review AI Summaries') } 'recovery explicit save/cancel' | Out-Null
                if ($action -eq 'Cancel' -and [IO.File]::ReadAllText($entryPath) -cne $before) { throw 'Cancel changed library bytes.' }
            }
            $entry = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id }
            if (@($entry.recording.promptSummaries | Where-Object { $_ -ceq 'Synthetic OpenAI input summary.' }).Count -ne 2 -or
                $entry.recording.outputSummaries[0] -cne 'I checked the result. (It passed.)' -or $null -ne $entry.recording.outputSummaries[1]) {
                throw 'Atomic recovery save lost valid drafts, explicit edits, or deletion.'
            }
            $requests = @(Get-Content (Join-Path $evidence 'openai-requests.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
            if ($requests.Count -ne 20 -or @($requests | Where-Object { $_.kind -eq 'output' }).Count -ne 16) { throw 'Recovery or editing exceeded the exact four-attempt output budget.' }
            if ([IO.File]::ReadAllText($target) -cne $targetContent -or [IO.File]::ReadAllText($source) -cne $sourceBeforeCapture) { throw 'Recovery changed original sources.' }
            Write-Output 'RECOVERY UI ACCEPTANCE PASSED: picker/action/consent, exact4 requests per rejected output, prior valid input drafts and exact failed text retained, explicit warning, pending/invalid Save blocked, invalid edit rejected, complete parenthesized correction accepted, explicit deletion, Cancel byte-preserving, atomic Save, exact20 synthetic requests and no paid requests while editing; originals unchanged.'
            return
        }
        if ($DecoderOnly) { [IO.File]::WriteAllText((Join-Path $evidence 'decoder-complete'), 'synthetic complete output beyond old decoder cap', $utf8) }
        foreach ($scope in @('Both','Input','Output')) {
            Invoke-AISummaryAction $dialog $scope
            if ($scope -eq 'Both') {
                $settingsDialog = Wait-Until { Get-AppWindow 'OpenAI Settings' } 'synthetic key for constrained generation'
                ([System.Windows.Automation.ValuePattern](Find-Element $settingsDialog 'Id' 'OpenAIKey').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('synthetic-openai-key-for-ui-tests')
                Invoke-Button $settingsDialog 'SaveOpenAISettings'
            }
            $consent = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'constrained generation source/charge consent'
            if ((Find-Element $consent 'Id' 'OpenAIConsentNotice').Current.Name -notmatch 'Length and completeness are checked locally') { throw 'Consent omitted the actual local validation contract.' }
            Invoke-Button $consent 'ConfirmOpenAIGeneration'
            $review = Wait-Until { Get-AppWindow 'Review AI Summaries' } 'constrained summary review'
            $draft = (Find-Element $review 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
            if ($DecoderOnly) {
                if ($draft.Length -le 300 -or $draft.Length -gt 600 -or -not $draft.EndsWith('I need to build and maintain automated tests.')) { throw 'Decoder completion lost the whole final thought or changed the local length bound.' }
            } elseif ($draft.Length -gt 600 -or $draft -notmatch '^Synthetic OpenAI (input|output) summary\.$') { throw 'Generation did not produce a complete bounded review draft.' }
            if ($scope -eq 'Both') {
                Invoke-Button $review 'Cancel'
            } else { Invoke-Button $review 'SaveSummaries' }
            Wait-Until { -not (Get-AppWindow 'Review AI Summaries') } 'explicit summary save/cancel' | Out-Null
            $entry = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id }
            if ($scope -eq 'Both' -and [IO.File]::ReadAllText($entryPath) -cne $before) { throw 'Cancel saved the combined drafts.' }
            if ($scope -eq 'Input' -and (@($entry.recording.promptSummaries | Where-Object { $_ }).Count -ne 2 -or
                @($entry.recording.outputSummaries | Where-Object { $_ }).Count)) { throw 'Input scope changed outputs or omitted prompts.' }
        }
        $entry = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id }
        if (@($entry.recording.outputSummaries | Where-Object { $_ }).Count -ne 2) { throw 'Output scope did not save the two outputs.' }
        $requests = @(Get-Content (Join-Path $evidence 'openai-requests.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        if ($requests.Count -ne 8 -or @($requests | Where-Object correcting).Count) { throw 'Constrained valid drafts made extra rewrite requests.' }
        if ([IO.File]::ReadAllText($target) -cne $targetContent -or [IO.File]::ReadAllText($source) -cne $sourceBeforeCapture) { throw 'Summary generation changed original sources.' }
        if ($DecoderOnly) {
            foreach ($text in @($entry.recording.promptSummaries) + @($entry.recording.outputSummaries)) {
                if ($text.Length -le 300 -or $text.Length -gt 600 -or -not $text.EndsWith('I need to build and maintain automated tests.')) { throw 'Saved decoder-completion summary lost final meaning or exceeded the app limit.' }
            }
            Write-Output 'DECODER COMPLETION UI PASSED: actual picker/generation/consent, no decoder character cap on eight requests/all scopes, every complete draft >300 and <=600 UTF-16 units with final assignment retained, explicit Cancel unchanged, explicit input/output Save, saved final thoughts verified, original sources unchanged. Synthetic only.'
            return
        }
        Write-Output 'SUMMARY UI ACCEPTANCE PASSED: one action, combined/input/output scopes, scope cancel without requests/writes, consent explains local validation, strict JSON structure without decoder character caps on all8 synthetic requests, complete bounded drafts, explicit combined cancel/input-save/output-save, originals unchanged. No live key/request. Live model fidelity NOT certified by this synthetic check.'
        if ($TranslationOnly) {
            Invoke-Button $dialog 'SelectDemo'
            Wait-Until { -not (Get-AppWindow 'Find interaction') -and (Find-Element $window 'Id' 'TranslateSummaries').Current.IsEnabled } 'selected English summaries ready for translation' | Out-Null
            $english = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id }
            $originalTurns = $english.recording.turns | ConvertTo-Json -Depth 60 -Compress
            $chinese = [string][char]0x6211 + [char]0x9009 + [char]0x62E9 + [char]0x84DD + [char]0x8272 + [char]0x3002 + [char]0x8981 + [char]0x7EE7 + [char]0x7EED + [char]0x5417 + [char]0xFF1F
            foreach ($language in @('Simplified Chinese (Mandarin)','French','German','Italian','English','Simplified Chinese (Mandarin)')) {
                $beforeTranslation = [IO.File]::ReadAllText($entryPath)
                Invoke-Button $window 'TranslateSummaries'
                $translationDialog = Wait-Until { Get-AppWindow 'Translate Summaries' } 'translation source consent and language selector'
                $languageBox = Find-Element $translationDialog 'Id' 'SummaryTranslationLanguage'
                $selectedLanguage = ([System.Windows.Automation.SelectionPattern]$languageBox.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)).Current.GetSelection()[0].Current.Name
                if ($selectedLanguage -ne 'Simplified Chinese (Mandarin)') { throw 'Simplified Chinese must default on every translation dialog.' }
                if ((Find-Element $translationDialog 'Id' 'SummaryTranslationSources').Current.Name -match 'Show the first recorded interaction') { throw 'Translation consent includes original exchanges.' }
                if ($language -ne 'Simplified Chinese (Mandarin)') {
                    Select-ComboItem $languageBox $language
                }
                Invoke-Button $translationDialog 'ConfirmSummaryTranslation'
                $review = Wait-Until { Get-AppWindow 'Review AI Summaries' } 'translated summary draft review'
                $draft = (Find-Element $review 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
                if ($draft.Length -gt 600) { throw 'Translation exceeded the summary length limit.' }
                $saveChinese = $language -eq 'Simplified Chinese (Mandarin)' -and (Test-Path (Join-Path $evidence 'translation-cancelled'))
                if ($saveChinese) {
                    if ($draft -cne $chinese) { throw 'Simplified Chinese draft lost Unicode text.' }
                    Invoke-Button $review 'SaveSummaries'
                } else {
                    Invoke-Button $review 'Cancel'
                    [IO.File]::WriteAllText((Join-Path $evidence 'translation-cancelled'), 'synthetic review cancelled')
                }
                Wait-Until { -not (Get-AppWindow 'Review AI Summaries') } 'translation review explicit save/cancel' | Out-Null
                if (-not $saveChinese -and [IO.File]::ReadAllText($entryPath) -cne $beforeTranslation) { throw 'Cancelled translation changed saved metadata.' }
            }
            $translatedEntry = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id }
            if (($translatedEntry.recording.turns | ConvertTo-Json -Depth 60 -Compress) -cne $originalTurns) { throw 'Translation altered original English exchanges.' }
            foreach ($summary in @($translatedEntry.recording.promptSummaries) + @($translatedEntry.recording.outputSummaries)) {
                if ($summary -cne $chinese) { throw 'Explicit Chinese save did not preserve aligned Unicode summaries.' }
            }
            if (($translatedEntry.recording.summaryVariants.original.promptSummaries | ConvertTo-Json -Compress) -cne
                ($english.recording.promptSummaries | ConvertTo-Json -Compress)) { throw 'Original summary version was not retained.' }
            ([System.Windows.Automation.TogglePattern](Find-Element $window 'Id' 'ShowPrompt').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
            $overlay = Wait-Until { Get-AppWindow 'Playback overlay' } 'language-selectable prompt overlay'
            foreach ($choice in @('Original','Simplified Chinese (Mandarin)')) {
                $displayLanguage = Find-Element $window 'Id' 'SummaryDisplayLanguage'
                Wait-Until { $displayLanguage.Current.IsEnabled } 'saved-language selector available' | Out-Null
                Select-ComboItem $displayLanguage $choice
                $expectedText = if ($choice -eq 'Original') { 'Synthetic OpenAI input summary.' } else { $chinese }
                Wait-Until { (Find-Element $overlay 'Id' 'PromptText').Current.Name -ceq $expectedText -and $displayLanguage.Current.IsEnabled } 'offline prompt-only language switch' | Out-Null
            }
            ([System.Windows.Automation.TogglePattern](Find-Element $window 'Id' 'ShowOutput').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
            $overlay = Wait-Until { Get-AppWindow 'Playback overlay' } 'Chinese summary overlay'
            Invoke-Button $window 'PlayPause'
            $replay = Wait-Until {
                Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
            } 'isolated English recording with Chinese summaries'
            $replayId = [int]$replay.ProcessId
            Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' } 'translated recording prepares without autoplay' 50 | Out-Null
            if ((Find-Element $window 'Id' 'SummaryDisplayLanguage').Current.IsEnabled) { throw 'Playback target allows a language change.' }
            Invoke-Button $window 'PlayPause'
            Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Start Over' } 'first original exchange completes with Chinese overlay' | Out-Null
            if ((Find-Element $overlay 'Id' 'FirstText').Current.Name -cne $chinese -or
                (Find-Element $overlay 'Id' 'SecondText').Current.Name -cne $chinese) { throw 'Completed prompt/reply overlay did not display saved Simplified Chinese.' }
            Save-WindowImage $overlay 'simplified-chinese-pair.png'
            Invoke-Button $window 'Stop'
            Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) -and (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Open' } 'only scoped translation-test playback stops' 20 | Out-Null
            Select-ComboItem (Find-Element $window 'Id' 'SummaryDisplayLanguage') 'Original'
            Wait-Until { (Find-Element $overlay 'Id' 'FirstText').Current.Name -ceq 'Synthetic OpenAI input summary.' } 'Original conversation overlay restored offline' | Out-Null
            Invoke-Button $window 'PlayPause'
            $replay = Wait-Until {
                Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
            } 'isolated Original-language playback'
            $replayId = [int]$replay.ProcessId
            Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' } 'Original recording prepares' 50 | Out-Null
            Invoke-Button $window 'PlayPause'
            Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Start Over' } 'Original reply completes' | Out-Null
            if ((Find-Element $overlay 'Id' 'FirstText').Current.Name -cne 'Synthetic OpenAI input summary.' -or
                (Find-Element $overlay 'Id' 'SecondText').Current.Name -cne 'Synthetic OpenAI output summary.') { throw 'Original input/reply playback did not restore saved English summaries.' }
            Invoke-Button $window 'Stop'
            Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) -and (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Open' } 'Original-language playback stops' 20 | Out-Null
            Select-ComboItem (Find-Element $window 'Id' 'SummaryDisplayLanguage') 'Simplified Chinese (Mandarin)'
            Wait-Until { (Find-Element $overlay 'Id' 'FirstText').Current.Name -ceq $chinese -and (Find-Element $window 'Id' 'SummaryDisplayLanguage').Current.IsEnabled } 'Chinese selection saved before restart' | Out-Null
            ([System.Windows.Automation.WindowPattern]$window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
            Wait-Until { -not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue) } 'only synthetic controller closes for restart' | Out-Null
            $launch = Start-TestPlayer
            $script:controllerId = $launch.ProcessId
            $window = Wait-Until { Get-AppWindow 'Demo Player' } 'restarted language-aware controller'
            Invoke-Button $window 'ChooseDemo'
            $dialog = Wait-Until { Get-AppWindow 'Find interaction' } 'persisted language selection'
            ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
            $item = Wait-Until {
                $items = (Find-Element $dialog 'Id' 'DemoList').FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
                if ($items.Count -eq 1) { return $items[0] }
            } 'reloaded language-versioned recording'
            ([System.Windows.Automation.SelectionItemPattern]$item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
            Invoke-Button $dialog 'SelectDemo'
            Wait-Until { -not (Get-AppWindow 'Find interaction') -and (Find-Element $window 'Id' 'SummaryDisplayLanguage').Current.IsEnabled } 'saved language restored after restart' | Out-Null
            $persistedEntry = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id }
            $restartedCombo = Find-Element $window 'Id' 'SummaryDisplayLanguage'
            $persistedItem = Get-ComboItem $restartedCombo 'Simplified Chinese (Mandarin)'
            $isSelected = ([System.Windows.Automation.SelectionItemPattern]$persistedItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Current.IsSelected
            if ($persistedEntry.recording.summaryLanguage -cne 'zh-CN' -or -not $isSelected) { throw 'Restart lost the saved display language or its selected visible item.' }
            ([System.Windows.Automation.ExpandCollapsePattern]$restartedCombo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Collapse()
            $translationRequests = @(Get-Content (Join-Path $evidence 'translation-requests.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
            if ($translationRequests.Count -ne 24) { throw 'Unexpected translation request count or hidden retries.' }
            if ([IO.File]::ReadAllText($source) -cne $sourceBeforeCapture -or [IO.File]::ReadAllText($target) -cne $targetContent) { throw 'Translation/playback changed original source or edit target.' }
            Write-Output 'TRANSLATION/LANGUAGE UI ACCEPTANCE PASSED: all5 translation choices, cancel preservation, separate Chinese and Original versions, offline switching both directions in prompt-only and conversation modes, real native playback in Chinese and Original, playback gating, controller restart persistence, unchanged English exchanges/source/edit target. Exactly24 synthetic translation requests: offline switches/restart make no additional calls. No live paid-provider fidelity claim.'
        }
        return
    }
    $play = Find-Element $window 'Id' 'PlayPause'
    if ($play.Current.IsEnabled) { throw 'Play must be disabled without a selected demo.' }
    foreach ($id in @('GeneratePromptSummaries', 'GenerateOutputSummaries')) {
        $link = Find-Element $window 'Id' $id
        if ($link.Current.IsEnabled -or $link.Current.Name -notmatch '\(0/0\)$') { throw 'Summary links require an interaction and start at0/0.' }
    }
    Save-WindowImage $window 'controller-empty.png'
    Invoke-Button $window 'ChooseDemo'
    $dialog = Wait-Until { Get-AppWindow 'Find interaction' } 'unified interaction picker'
    if ($PlaybackOnly) {
        $overlaySummary = 'Explain the recorded interaction and its saved reference and code edits, preserving the original query for playback while showing this shorter, reviewed description to the presentation audience.'
        $outputSummary = 'The recorded assistant showed an answer, a saved reference and archived code edits.'
        $entry = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id }
        Invoke-DemoLibrary @{ command = 'summaryBatch'; id = $saved.id
            summaries = @{ promptSummaries = @($overlaySummary,$null); outputSummaries = @($outputSummary,$null) }
            expected = @{ promptSummaries = $entry.recording.promptSummaries; outputSummaries = $entry.recording.outputSummaries }
        } | Out-Null
        ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        $list = Find-Element $dialog 'Id' 'DemoList'
        $item = Wait-Until {
            $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
            if ($items.Count -eq 1) { return $items[0] }
        } 'focused playback fixture'
        ([System.Windows.Automation.SelectionItemPattern]$item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        Write-Output 'PLAYBACK-ONLY SCOPE: configuration/authoring acceptance not run; playback timing, rendering, pause, reselection and scoped lifecycle are tested.'
    } else {
    ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Wait-Until {
        (Find-Element $dialog 'Id' 'DemoList').FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition).Count -eq 1 -and
        (Find-Element $dialog 'Id' 'RefreshDemos').Current.IsEnabled
    } 'initial saved selections load without blocking dialog display' | Out-Null
    $list = Find-Element $dialog 'Id' 'DemoList'
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    if ($items.Count -ne 1) { throw ('Expected one persisted demo, got ' + $items.Count) }
    [IO.File]::WriteAllText((Join-Path $evidence 'delay-library'), 'synthetic delayed read')
    Invoke-Button $dialog 'RefreshDemos'
    $working = Wait-Until { Get-AppWindow 'Working - Demo Player' } 'visible library activity feedback'
    if ((Find-Element $working 'Id' 'LibraryActivity').Current.Name -notlike 'Loading saved selections*') { throw 'Slow library operation has no meaningful activity text.' }
    $search = Find-Element $dialog 'Id' 'DemoSearch'
    if (-not $dialog.Current.IsEnabled -or -not $search.Current.IsEnabled) { throw 'Background library work disabled the whole configuration window or search.' }
    $inputClock = [Diagnostics.Stopwatch]::StartNew()
    ([System.Windows.Automation.ValuePattern]$search.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('Synthetic')
    $inputClock.Stop()
    if ($inputClock.Elapsed.TotalMilliseconds -gt 250) { throw ('Search input blocked during background library work: ' + $inputClock.Elapsed.TotalMilliseconds + 'ms.') }
    Invoke-Button $working 'CancelLibraryOperation'
    $cancelled = Wait-Until { Get-AppWindow 'Operation cancelled' } 'explicit cancellation feedback'
    Invoke-DialogButton $cancelled 'OK'
    Remove-Item -LiteralPath (Join-Path $evidence 'delay-library')
    Wait-Until { -not (Get-AppWindow 'Working - Demo Player') -and (Find-Element $dialog 'Id' 'RefreshDemos').Current.IsEnabled } 'cancelled read restores conflicting actions' | Out-Null
    Write-Output ('BACKGROUND LIBRARY UI PASSED: visible activity/cancel, enabled owner and live search; search input ' + [Math]::Round($inputClock.Elapsed.TotalMilliseconds,1) + 'ms (limit250ms).')
    $list = Find-Element $dialog 'Id' 'DemoList'
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    ([System.Windows.Automation.SelectionItemPattern]$items[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Save-WindowImage $dialog 'library.png'
    ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'AgentConversationsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    $capture = $dialog
    $sessionList = Find-Element $capture 'Id' 'CaptureSessions'
    Wait-Until {
        ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 2 -and
        (Find-Element $capture 'Id' 'CaptureRefresh').Current.IsEnabled
    } 'automatic discovery lists the two synthetic native/SDK conversations' 65 | Out-Null
    $historySearch = Find-Element $capture 'Id' 'CaptureHistorySearch'
    ([System.Windows.Automation.ValuePattern]$historySearch.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('SDKProject')
    Wait-Until { ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 1 } 'project search filters without rescanning' | Out-Null
    $rowCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::DataItem)
    $sdkRow = $sessionList.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $rowCondition)
    ([System.Windows.Automation.SelectionItemPattern]$sdkRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Invoke-Button $capture 'Load'
    $turnList = Wait-Until { Find-Element $capture 'Id' 'CaptureTurns' } 'SDK exchange list after loading'
    Wait-Until { $turnList.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition).Count -eq 2 } 'SDK conversation loads two exchanges' | Out-Null
    $rawPayload = Find-Element $capture 'Id' 'CaptureRawPayload'
    $sdkTurn = $turnList.FindFirst([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    ([System.Windows.Automation.SelectionItemPattern]$sdkTurn.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    ([System.Windows.Automation.TogglePattern]$rawPayload.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    $preview = Find-Element $capture 'Id' 'CapturePreview'
    Wait-Until { ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value -match '"sdkEvents"' } 'SDK original events appear in debounced raw preview' | Out-Null
    ([System.Windows.Automation.TogglePattern]$rawPayload.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Invoke-Button $capture 'CaptureClearFilters'
    Wait-Until { ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 2 } 'clear filters restores both rows' | Out-Null
    $agentFilter = Find-Element $capture 'Id' 'CaptureAgentFilter'
    ([System.Windows.Automation.ExpandCollapsePattern]$agentFilter.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
    $agentItem = Find-Element $agentFilter 'Name' 'Synthetic SDK Agent'
    for ($depth = 0; $agentItem -and $depth -lt 8; $depth++) {
        if ($agentItem.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::IsSelectionItemPatternAvailableProperty)) { break }
        $agentItem = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($agentItem)
    }
    if (-not $agentItem -or -not $agentItem.GetCurrentPropertyValue([System.Windows.Automation.AutomationElement]::IsSelectionItemPatternAvailableProperty)) { throw 'SDK agent filter item is unavailable.' }
    ([System.Windows.Automation.SelectionItemPattern]$agentItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Wait-Until { ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 1 } 'agent filter selects SDK conversation' | Out-Null
    ([System.Windows.Automation.ExpandCollapsePattern](Find-Element $capture 'Id' 'MoreFilters').GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
    $minimum = Find-Element $capture 'Id' 'CaptureMinPrompts'
    ([System.Windows.Automation.ValuePattern]$minimum.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('3')
    Wait-Until { ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 0 } 'prompt threshold filters numerically' | Out-Null
    Invoke-Button $capture 'CaptureClearFilters'
    $header = Find-Element $sessionList 'Name' 'Conversation'
    foreach ($sort in @(
        @{ Title = 'First synthetic SDK prompt'; Direction = 'ascending' },
        @{ Title = 'Synthetic UI acceptance'; Direction = 'descending' }
    )) {
        $tasks.Add([DemoUITest]::Invoke($header))
        $sortedTitle = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $sort.Title)
        Wait-Until {
            $grid = [System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)
            if ($grid.Current.RowCount -eq 2) {
                $cell = $grid.GetItem(0,0)
                if ($cell) { $cell.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $sortedTitle) }
            }
        } ('conversation column sorts ' + $sort.Direction) | Out-Null
    }
    Invoke-Button $capture 'CaptureRefresh'
    Wait-Until { (Find-Element $capture 'Id' 'CaptureRefresh').Current.IsEnabled -and ([System.Windows.Automation.GridPattern]$sessionList.GetCurrentPattern([System.Windows.Automation.GridPattern]::Pattern)).Current.RowCount -eq 2 } 'refresh completes without duplicate rows' 65 | Out-Null
    $sourceBox = Find-Element $capture 'Id' 'CaptureSource'
    $largeSource = Join-Path $evidence 'synthetic-selection.jsonl'
    $largeSnapshot = @{ kind = 0; v = @{ sessionId = 'selection-performance'; requests = @(0..99 | ForEach-Object {
        @{ result = @{}; message = @{ text = ('Selection turn ' + $_ + (' long prompt' * 2000)) }; response = @(@{ value = ('Saved response ' * 2000) }) }
    }) } }
    [IO.File]::WriteAllText($largeSource, ($largeSnapshot | ConvertTo-Json -Depth 15 -Compress) + "`n", $utf8)
    ([System.Windows.Automation.ValuePattern]$sourceBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($largeSource)
    Invoke-Button $capture 'Load'
    $turnList = Wait-Until { Find-Element $capture 'Id' 'CaptureTurns' } 'large exchange list after loading'
    $selection = [System.Windows.Automation.SelectionPattern]$turnList.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
    Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '100 of 100 exchanges selected' } 'all 100 exchanges selected by default' 35 | Out-Null
    if ($selection.Current.GetSelection().Count -ne 100) { throw 'Default selection must include every exchange.' }
    $preview = Find-Element $capture 'Id' 'CapturePreview'
    Wait-Until { ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value -match 'Preview limited' } 'bounded preview of large selection' | Out-Null
    if (([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value.Length -gt 32768) { throw 'Large UI preview exceeded its character budget.' }
    $turnItems = $turnList.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    $latencies = @(foreach ($attempt in 0..9) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        ([System.Windows.Automation.SelectionItemPattern]$turnItems[$attempt % 2].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
        $clock.Stop()
        $clock.Elapsed.TotalMilliseconds
    })
    $maximum = ($latencies | Measure-Object -Maximum).Maximum
    if ($maximum -ge 250) { throw ('Exchange selection exceeded 250 ms: ' + $maximum) }
    Invoke-Button $capture 'CaptureClearSelection'
    Wait-Until { $selection.Current.GetSelection().Count -eq 0 } 'clear selection' | Out-Null
    $turnList.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Wait-Until { $selection.Current.GetSelection().Count -eq 100 } 'real Ctrl+A selects all exchanges' | Out-Null
    Invoke-Button $capture 'CaptureClearSelection'
    Wait-Until { $selection.Current.GetSelection().Count -eq 0 } 'clear selection before button test' | Out-Null
    Invoke-Button $capture 'CaptureSelectAll'
    Wait-Until { $selection.Current.GetSelection().Count -eq 100 } 'Select all button selects every exchange' | Out-Null
    Write-Output ('EXCHANGE SELECTION: 100 large exchanges selected by default; actual Ctrl+A and buttons passed; maximum of 10 individual selections ' + [Math]::Round($maximum,1) + ' ms (limit 250 ms); preview <=32768 characters.')
    $sourceBox.SetFocus()
    ([System.Windows.Automation.ValuePattern]$sourceBox.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue($source)
    Invoke-Button $capture 'Load'
    $turnList = Wait-Until { Find-Element $capture 'Id' 'CaptureTurns' } 'replacement exchange list after loading'
    Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '2 of 3 exchanges selected' } 'replacement conversation selects only available exchanges by default' | Out-Null
    if ((Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled) { throw 'Save must remain disabled before reviewing the replacement selection.' }
    if ((Find-Element $capture 'Id' 'CaptureStatus').Current.Name -notmatch '1 unavailable exchanges excluded.*Missing: completion result') { throw 'Excluded exchange count and missing saved field must be explicit.' }
    $turnItems = $turnList.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    if ($turnItems[0].Current.Name -match 'Unavailable|Unknown') { throw 'Valid saved references must not make the exchange unavailable.' }
    if ($turnItems[0].Current.Name -notmatch '\[Read-only edits\]') { throw 'Saved code edits must be labeled as read-only, not unavailable.' }
    $preview = Find-Element $capture 'Id' 'CapturePreview'
    Wait-Until { ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value -match 'SYNTHETIC_SAVED_REPLACEMENT' } 'readable preview updated after selection' | Out-Null
    $readable = ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value
    if ($readable -notmatch 'PROMPT' -or $readable -notmatch 'Saved reference: Synthetic saved reference') { throw 'Readable capture preview is missing the prompt or reference label.' }
    if ($readable -notmatch 'Recorded code edit - not applied' -or $readable -notmatch 'SYNTHETIC_SAVED_REPLACEMENT') { throw 'Capture preview must display the archived code edit.' }
    $rawPayload = Find-Element $capture 'Id' 'CaptureRawPayload'
    ([System.Windows.Automation.TogglePattern]$rawPayload.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Wait-Until { ([System.Windows.Automation.ValuePattern]$preview.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).Current.Value -match '"inlineReference"' } 'raw saved payload remains inspectable' | Out-Null
    ([System.Windows.Automation.TogglePattern]$rawPayload.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    ([System.Windows.Automation.ExpandCollapsePattern](Find-Element $capture 'Name' 'Selection name (optional)').GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
    $title = Find-Element $capture 'Id' 'CaptureTitle'
    ([System.Windows.Automation.ValuePattern]$title.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('Captured through UI ' + [char]0x03BB)
    $reviewed = Find-Element $capture 'Id' 'CaptureReviewed'
    Wait-Until { $reviewed.Current.IsEnabled } 'latest preview is ready for privacy review' | Out-Null
    ([System.Windows.Automation.TogglePattern]$reviewed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Wait-Until { (Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled } 'reviewed valid selection can be saved' | Out-Null
    Invoke-Button $capture 'CaptureSelectAll'
    Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '3 of 3 exchanges selected' } 'Select all includes unavailable entries for inspection' | Out-Null
    Wait-Until { $reviewed.Current.IsEnabled } 'unavailable selection preview is ready' | Out-Null
    ([System.Windows.Automation.TogglePattern]$reviewed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    if (-not (Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled) { throw 'Reviewing a mixed selection must enable its available exchanges.' }
    if ((Find-Element $capture 'Id' 'SaveDemo').Current.Name -ne 'Use 2 available exchanges') { throw 'Mixed selection must explicitly identify the usable subset.' }
    if ((Find-Element $capture 'Id' 'CaptureStatus').Current.Name -notmatch '1 unavailable selected exchanges will be skipped') { throw 'Mixed selection must explain which content is skipped.' }
    Invoke-Button $capture 'CaptureSelectAvailable'
    Wait-Until { (Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -eq '2 of 3 exchanges selected' -and $reviewed.Current.IsEnabled } 'Select available restores the valid preview' | Out-Null
    if ((Find-Element $capture 'Id' 'SaveDemo').Current.IsEnabled) { throw 'Selection changes must invalidate the prior review.' }
    ([System.Windows.Automation.TogglePattern]$reviewed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Save-WindowImage $capture 'capture.png'
    if ((Find-Element $capture 'Id' 'CaptureSelectionCount').Current.Name -ne '2 of 3 exchanges selected') { throw 'Preview controls or focus changes altered the selected exchanges.' }
    Invoke-Button $capture 'SaveDemo'
    Wait-Until { -not (Get-AppWindow 'Find interaction') } 'selection returns to controller' | Out-Null
    Start-Sleep -Seconds 3
    if (Get-AppWindow 'Find interaction') { throw 'Use selected exchanges reopened the picker after returning to the controller.' }
    if (-not (Find-Element $window 'Id' 'ChooseDemo').Current.IsEnabled) { throw 'Completed selection left the controller locked.' }
    $entries = @(Invoke-DemoLibrary @{ command = 'list' })
    if ($entries.Count -ne 2) { throw 'UI capture did not persist the second demo.' }
    if (-not ($entries | Where-Object title -eq ('Captured through UI ' + [char]0x03BB))) { throw 'The PowerShell bridge did not preserve the Unicode capture title.' }
    if (($entries | Where-Object title -eq ('Captured through UI ' + [char]0x03BB)).count -ne 2) { throw 'Capture did not save both default-selected exchanges.' }
    if ([IO.File]::ReadAllText($source) -cne $sourceBeforeCapture) { throw 'Capture changed the original saved conversation.' }
    Invoke-Button $window 'ChooseDemo'
    $dialog = Wait-Until { Get-AppWindow 'Find interaction' } 'reopen unified picker'
    Start-Sleep -Seconds 3
    if ((Find-Element $window 'Id' 'ChooseDemo').Current.IsEnabled) { throw 'Background summary refresh re-enabled the controller beneath its modal picker.' }
    ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    $list = Find-Element $dialog 'Id' 'DemoList'
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
    $capturedItem = @($items | Where-Object { $_.Current.Name -like '*Captured through UI*' })[0]
    if (-not $capturedItem) { throw 'Captured demo was not added to the library dialog.' }
    ([System.Windows.Automation.SelectionItemPattern]$capturedItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    ([System.Windows.Automation.ExpandCollapsePattern](Find-Element $dialog 'Id' 'SavedActions').GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)).Expand()
    $renameTitle = Find-Element $dialog 'Id' 'SavedTitle'
    ([System.Windows.Automation.ValuePattern]$renameTitle.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('Renamed UI demo')
    Invoke-Button $dialog 'Rename'
    Wait-Until { @(Invoke-DemoLibrary @{ command = 'list' } | Where-Object title -eq 'Renamed UI demo').Count -eq 1 } 'rename persists' | Out-Null
    $overlaySummary = 'Explain the recorded interaction and its saved reference and code edits, preserving the original query for playback while showing this shorter, reviewed description to the presentation audience.'
    $outputSummary = 'The recorded assistant showed an answer, a saved reference and archived code edits.'
    Invoke-Button $dialog 'EditPromptSummaries'
    $summaryDialog = Wait-Until { Get-AppWindow 'Input / Output Summaries' } 'input/output summary editor'
    $originalPrompt = (Find-Element $summaryDialog 'Id' 'SummaryOriginal').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    if ($originalPrompt -cne 'Show the first recorded interaction.') { throw 'Summary editor must display the full original query.' }
    (Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($overlaySummary)
    $summaryExchange = Find-Element $summaryDialog 'Id' 'SummaryExchange'
    $summaryExchange.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait('{HOME}{DOWN}{ENTER}')
    Wait-Until {
        (Find-Element $summaryDialog 'Id' 'SummaryOriginal').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -like '*First recorded answer*'
    } 'output summary choice' | Out-Null
    $outputOriginal = (Find-Element $summaryDialog 'Id' 'SummaryOriginal').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    if ($outputOriginal -notlike '*First recorded answer*' -or $outputOriginal -like '*SYNTHETIC_SAVED_REPLACEMENT*') { throw 'Output review must use recorded assistant text, not raw saved edits.' }
    (Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($outputSummary)
    Invoke-Button $summaryDialog 'SaveSummaries'
    Wait-Until { -not (Get-AppWindow 'Input / Output Summaries') } 'summary save closes editor' | Out-Null
    $summaryEntry = @(Invoke-DemoLibrary @{ command = 'list' } | Where-Object title -eq 'Renamed UI demo')[0]
    if ($summaryEntry.presentation.overlay.promptSummary -cne $overlaySummary) { throw 'Manual summary did not persist through the PowerShell bridge.' }
    if ($summaryEntry.presentation.overlay.conversation.outputSummary -cne $outputSummary) { throw 'Manual output summary did not persist through the PowerShell bridge.' }
    Invoke-Button $dialog 'EditPromptSummaries'
    $summaryDialog = Wait-Until { Get-AppWindow 'Input / Output Summaries' } 'reopen summary editor'
    if ((Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -cne $overlaySummary) { throw 'Summary editor did not reload the saved summary.' }
    (Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue('Unsaved draft')
    ([System.Windows.Automation.TogglePattern](Find-Element $summaryDialog 'Id' 'IncludeInPlayback').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Invoke-Button $summaryDialog 'Cancel'
    Wait-Until { -not (Get-AppWindow 'Input / Output Summaries') } 'cancel summary edit' | Out-Null
    if (@((Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }).recording.playbackIncluded | Where-Object { $_ -eq $false }).Count) { throw 'Cancel wrote inclusion drafts.' }
    Invoke-Button $dialog 'EditPromptSummaries'
    $summaryDialog = Wait-Until { Get-AppWindow 'Input / Output Summaries' } 'inclusion editor'
    ([System.Windows.Automation.TogglePattern](Find-Element $summaryDialog 'Id' 'IncludeInPlayback').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Invoke-Button $summaryDialog 'SaveSummaries'
    Wait-Until { -not (Get-AppWindow 'Input / Output Summaries') } 'inclusion saved' | Out-Null
    $excluded = Invoke-DemoLibrary @{ command = 'metadata'; id = $summaryEntry.id }
    if ($excluded.count -ne 1 -or $excluded.totalCount -ne 2 -or $excluded.presentation.overlay.promptSummary -ne 'Show the next recorded interaction.') { throw 'Exclusion must change playback/count, not shift summary alignment.' }
    Invoke-Button $dialog 'EditPromptSummaries'
    $summaryDialog = Wait-Until { Get-AppWindow 'Input / Output Summaries' } 'reinclude original exchange'
    if ((Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -cne $overlaySummary) { throw 'Excluded original summary disappeared from editor.' }
    ([System.Windows.Automation.TogglePattern](Find-Element $summaryDialog 'Id' 'IncludeInPlayback').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Invoke-Button $summaryDialog 'SaveSummaries'
    Wait-Until { -not (Get-AppWindow 'Input / Output Summaries') } 'reinclusion saved' | Out-Null
    Invoke-Button $dialog 'EditPromptSummaries'
    $summaryDialog = Wait-Until { Get-AppWindow 'Input / Output Summaries' } 'summary clear draft editor'
    Invoke-Button $summaryDialog 'ClearSummaryDrafts'
    Wait-Until {
        (Find-Element $summaryDialog 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -eq ''
    } 'clear all empties the summary draft' | Out-Null
    Invoke-Button $summaryDialog 'Cancel'
    Wait-Until { -not (Get-AppWindow 'Input / Output Summaries') } 'cancel clear draft' | Out-Null
    $preserved = Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }
    if ($preserved.recording.promptSummaries[0] -cne $overlaySummary) { throw 'Canceling clear changed saved summaries.' }
    Invoke-Button $dialog 'ClearPromptSummaries'
    $clearConsent = Wait-Until { Get-AppWindow 'Clear Prompt Summaries' } 'clear summaries confirmation'
    Invoke-DialogButton $clearConsent 'Cancel'
    Wait-Until { -not (Get-AppWindow 'Clear Prompt Summaries') } 'declined clear leaves summaries' | Out-Null
    if ((Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }).recording.promptSummaries[0] -cne $overlaySummary) { throw 'Declining clear changed the summary.' }
    Invoke-Button $dialog 'ClearPromptSummaries'
    $clearConsent = Wait-Until { Get-AppWindow 'Clear Prompt Summaries' } 'confirmed clear summaries'
    Invoke-DialogButton $clearConsent 'OK'
    Wait-Until { -not (Get-AppWindow 'Clear Prompt Summaries') } 'clear confirmation closes' | Out-Null
    $cleared = Wait-Until {
        $state = Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }
        if (-not @($state.recording.promptSummaries | Where-Object { $null -ne $_ }).Count -and
            -not @($state.recording.outputSummaries | Where-Object { $null -ne $_ }).Count) { return $state }
    } 'confirmed clear persists all input and output summaries'
    if (@($cleared.recording.promptSummaries | Where-Object { $null -ne $_ }).Count) { throw 'Clear all left saved summaries.' }
    if (@($cleared.recording.outputSummaries | Where-Object { $null -ne $_ }).Count) { throw 'Clear all left output summaries.' }
    if (($preserved.recording.turns | ConvertTo-Json -Depth 60 -Compress) -cne ($cleared.recording.turns | ConvertTo-Json -Depth 60 -Compress)) { throw 'Clearing changed original exchanges.' }
    if ((Invoke-DemoLibrary @{ command = 'list' } | Where-Object id -eq $summaryEntry.id).presentation.overlay.promptSummary -cne 'Show the first recorded interaction.') { throw 'Clearing did not restore the default excerpt.' }
    Invoke-DemoLibrary @{ command = 'summaries'; id = $summaryEntry.id; summaries = @($overlaySummary, $null); expected = @($cleared.recording.promptSummaries) } | Out-Null
    Invoke-DemoLibrary @{ command = 'summaries'; kind = 'output'; id = $summaryEntry.id; summaries = @($outputSummary, $null); expected = @($cleared.recording.outputSummaries) } | Out-Null
    Invoke-AISummaryAction $dialog
    $settingsDialog = Wait-Until { Get-AppWindow 'OpenAI Settings' } 'missing key prompts inside the player'
    if (-not (Find-Element $settingsDialog 'Id' 'OpenAIKey').Current.IsPassword) { throw 'API key entry must be masked.' }
    Find-Element $settingsDialog 'Id' 'OpenAIKeyLink' | Out-Null
    Invoke-Button $settingsDialog 'CancelOpenAISettings'
    Wait-Until { -not (Get-AppWindow 'OpenAI Settings') } 'cancel missing key' | Out-Null
    if (Test-Path -LiteralPath (Join-Path $evidence 'openai-requests.jsonl')) { throw 'Canceling key entry sent an API request.' }
    Invoke-AISummaryAction $dialog
    $settingsDialog = Wait-Until { Get-AppWindow 'OpenAI Settings' } 'enter synthetic key'
    ([System.Windows.Automation.ValuePattern](Find-Element $settingsDialog 'Id' 'OpenAIKey').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('synthetic-openai-key-for-ui-tests')
    Invoke-Button $settingsDialog 'SaveOpenAISettings'
    $aiConsent = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'review shown sources before transmission'
    Invoke-Button $aiConsent 'CancelOpenAIGeneration'
    Wait-Until { -not (Get-AppWindow 'Generate OpenAI Summaries') } 'decline content transmission' | Out-Null
    if (Test-Path -LiteralPath (Join-Path $evidence 'openai-requests.jsonl')) { throw 'Declining source consent sent an API request.' }
    foreach ($action in @(
        @{ Scope = 'Both'; Kind = 'input'; Save = $false },
        @{ Scope = 'Output'; Kind = 'output'; Save = $true }
    )) {
        Invoke-AISummaryAction $dialog $action.Scope
        $aiConsent = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'saved key reused without prompting'
        Invoke-Button $aiConsent 'ConfirmOpenAIGeneration'
        $review = Wait-Until { Get-AppWindow 'Review AI Summaries' } 'OpenAI drafts reviewed in the player'
        $draft = (Find-Element $review 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        if ($draft -ne ('Synthetic OpenAI ' + $action.Kind + ' summary.')) { throw 'The generated draft is missing from the review dialog.' }
        if ($action.Save) { Invoke-Button $review 'SaveSummaries' } else { Invoke-Button $review 'Cancel' }
        Wait-Until { -not (Get-AppWindow 'Review AI Summaries') } 'close AI draft review' | Out-Null
    }
    $generatedEntry = Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }
    if ($generatedEntry.recording.promptSummaries[0] -cne $overlaySummary -or $generatedEntry.recording.promptSummaries[1] -or
        $generatedEntry.recording.outputSummaries[1] -cne 'Synthetic OpenAI output summary.') { throw 'AI save/cancel did not preserve its scope or existing manual summaries.' }
    Invoke-DemoLibrary @{ command = 'summaries'; kind = 'output'; id = $summaryEntry.id; summaries = @($outputSummary, $null); expected = @($generatedEntry.recording.outputSummaries) } | Out-Null
    foreach ($length in @(601, 1201, 1457, 4096)) {
        [IO.File]::WriteAllText((Join-Path $evidence 'overlong-summary'), [string]$length)
        $beforeRecovery = [IO.File]::ReadAllText((Join-Path $library ($summaryEntry.id + '.demo.json')))
        foreach ($saveRecovery in @($false, $true)) {
            Invoke-AISummaryAction $dialog
            $aiConsent = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'overlong generation consent'
            if ((Find-Element $aiConsent 'Id' 'OpenAIConsentNotice').Current.Name -notmatch '180-220.*600.*4 requests.*1200') { throw 'Consent must explain budgets and bounded billed rewrites.' }
            $requestsBefore = @(Get-Content -LiteralPath (Join-Path $evidence 'openai-requests.jsonl')).Count
            Invoke-Button $aiConsent 'ConfirmOpenAIGeneration'
            $review = Wait-Until { Get-AppWindow 'Review AI Summaries' } 'mixed valid and overlong batch review'
            $text = [System.Windows.Automation.ValuePattern](Find-Element $review 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            if ($text.Current.Value -cne 'Synthetic OpenAI input summary.') { throw 'An overlong output discarded the valid input draft.' }
            if (-not (Find-Element $review 'Id' 'SaveSummaries').Current.IsEnabled) { throw 'Automatically fitted mixed batch must be saveable without manual edits.' }
            $choice = Find-Element $review 'Id' 'SummaryExchange'
            $choice.SetFocus()
            [System.Windows.Forms.SendKeys]::SendWait('{END}{ENTER}')
            Wait-Until { $text.Current.Value -ceq 'I checked the result. Should I use blue or green?' } 'complete automatic rewrite visible before review' | Out-Null
            $batchRequests = @(Get-Content -LiteralPath (Join-Path $evidence 'openai-requests.jsonl') | Select-Object -Skip $requestsBefore | ForEach-Object { $_ | ConvertFrom-Json })
            $sourceRequests = @($batchRequests | Where-Object { $_.kind -eq 'output' -and -not $_.correcting }).Count
            if (@($batchRequests | Where-Object { $_.correcting }).Count -ne $sourceRequests -or
                @($batchRequests | Where-Object { $_.kind -eq 'input' }).Count -ne 1) { throw 'Every overflowing output part/combination must make exactly one correction; valid input must not retry.' }
            if ([IO.File]::ReadAllText((Join-Path $library ($summaryEntry.id + '.demo.json'))) -cne $beforeRecovery) { throw 'Generation or review changed saved bytes before explicit save.' }
            $requestsAtReview = @(Get-Content -LiteralPath (Join-Path $evidence 'openai-requests.jsonl')).Count
            if ($saveRecovery) {
                Invoke-Button $review 'SaveSummaries'
            } else { Invoke-Button $review 'Cancel' }
            Wait-Until { -not (Get-AppWindow 'Review AI Summaries') } 'finish overflow review' | Out-Null
            if (@(Get-Content -LiteralPath (Join-Path $evidence 'openai-requests.jsonl')).Count -ne $requestsAtReview) { throw 'Review/save must not make further model requests.' }
            if (-not $saveRecovery -and [IO.File]::ReadAllText((Join-Path $library ($summaryEntry.id + '.demo.json'))) -cne $beforeRecovery) { throw 'Canceling overflow review changed saved bytes.' }
        }
        $recovered = Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }
        if ($recovered.recording.promptSummaries[1] -cne 'Synthetic OpenAI input summary.' -or
            $recovered.recording.outputSummaries[1] -cne 'I checked the result. Should I use blue or green?' -or
            $recovered.recording.promptSummaries[0] -cne $overlaySummary -or $recovered.recording.outputSummaries[0] -cne $outputSummary) { throw 'Mixed overflow recovery did not atomically preserve/save the correct summaries.' }
        Invoke-DemoLibrary @{ command = 'summaryBatch'; id = $summaryEntry.id
            summaries = @{ promptSummaries = @($overlaySummary, $null); outputSummaries = @($outputSummary, $null) }
            expected = @{ promptSummaries = @($recovered.recording.promptSummaries); outputSummaries = @($recovered.recording.outputSummaries) }
        } | Out-Null
    }
    Remove-Item -LiteralPath (Join-Path $evidence 'overlong-summary')
    [IO.File]::WriteAllText((Join-Path $evidence 'legacy-review-draft'), 'Simulate old in-flight helper result')
    Invoke-AISummaryAction $dialog
    $aiConsent = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'legacy generation consent'
    Invoke-Button $aiConsent 'ConfirmOpenAIGeneration'
    $review = Wait-Until { Get-AppWindow 'Review AI Summaries' } 'legacy unsaved 1457 draft'
    Remove-Item -LiteralPath (Join-Path $evidence 'legacy-review-draft')
    if ((Find-Element $review 'Id' 'SaveSummaries').Current.IsEnabled) { throw 'Legacy invalid draft must not be saveable unchanged.' }
    $beforeLegacy = [IO.File]::ReadAllText((Join-Path $library ($summaryEntry.id + '.demo.json')))
    $includeState = (Find-Element $review 'Id' 'IncludeInPlayback').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState
    Invoke-Button $review 'RepairSummaryLengths'
    $repairConsent = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'legacy repair paid consent'
    if ((Find-Element $repairConsent 'Id' 'OpenAIConsentSources').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -notmatch 'Unsaved AI draft to shorten') { throw 'Repair consent must preview the draft and source.' }
    [IO.File]::WriteAllText((Join-Path $evidence 'delay-rewrite'), 'Exercise responsive correction/cancel')
    Invoke-Button $repairConsent 'ConfirmOpenAIGeneration'
    $repairProgress = Wait-Until { Get-AppWindow 'Generating AI Summaries' } 'cancellable length correction'
    Wait-Until { (Find-Element $repairProgress 'Id' 'OpenAISummaryProgress').Current.Name -match 'Automatically shortening, request 1/4' } 'live correction request counter' | Out-Null
    $responseClock = [Diagnostics.Stopwatch]::StartNew()
    $progressText = (Find-Element $repairProgress 'Id' 'OpenAISummaryProgress').Current.Name
    $responseClock.Stop()
    if ($responseClock.Elapsed.TotalMilliseconds -gt 250 -or $progressText -notmatch '4 requests.*completion or cancel') { throw 'Length correction blocked UI or omitted the request limit/cancellation guidance.' }
    Write-Output ('LENGTH CORRECTION RESPONSIVENESS: ' + [Math]::Round($responseClock.Elapsed.TotalMilliseconds, 1) + 'ms (limit250ms).')
    Invoke-Button $repairProgress 'CancelOpenAISummaryProgress'
    Wait-Until { -not (Get-AppWindow 'Generating AI Summaries') } 'cancel length rewrite' | Out-Null
    Wait-Until { (Find-Element $review 'Id' 'SummaryReviewStatus').Current.Name -match 'AI shortening canceled' } 'explicit correction cancellation status' | Out-Null
    Remove-Item -LiteralPath (Join-Path $evidence 'delay-rewrite')
    if ((Find-Element $review 'Id' 'SaveSummaries').Current.IsEnabled) { throw 'Canceled legacy repair replaced invalid drafts.' }
    if ([IO.File]::ReadAllText((Join-Path $library ($summaryEntry.id + '.demo.json'))) -cne $beforeLegacy) { throw 'Canceled rewrite changed saved bytes.' }
    Invoke-Button $review 'RepairSummaryLengths'
    $repairConsent = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'retry canceled repair explicitly'
    Invoke-Button $repairConsent 'ConfirmOpenAIGeneration'
    Wait-Until { (Find-Element $review 'Id' 'SaveSummaries').Current.IsEnabled } 'legacy automatic repair enables save without typing' | Out-Null
    if ((Find-Element $review 'Id' 'IncludeInPlayback').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne $includeState) { throw 'Repair changed inclusion.' }
    if ((Find-Element $review 'Id' 'SummaryText').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -cne 'Synthetic OpenAI input summary.') { throw 'Repair changed the valid companion draft.' }
    if ([IO.File]::ReadAllText((Join-Path $library ($summaryEntry.id + '.demo.json'))) -cne $beforeLegacy) { throw 'Repair saved before explicit Save.' }
    Invoke-Button $review 'Cancel'
    Wait-Until { -not (Get-AppWindow 'Review AI Summaries') } 'cancel repaired legacy batch' | Out-Null
    if ([IO.File]::ReadAllText((Join-Path $library ($summaryEntry.id + '.demo.json'))) -cne $beforeLegacy) { throw 'Cancel repaired legacy batch changed bytes.' }
    Write-Output 'AUTOMATIC FIT UI PASSED: 601/1201/1457/4096 -> complete <=600 drafts, exact bounded requests, Save enabled without typing, mixed batch atomic save/cancel, legacy 1457 repair preserves valid drafts/inclusion/bytes.'
    Save-WindowImage $dialog 'library-captured.png'
    }
    Invoke-Button $dialog 'SelectDemo'
    $selectedControls = Wait-Until {
        $controls = @{}
        foreach ($id in @('PlayPause', 'ShowPrompt', 'ShowElapsed')) {
            $control = Find-Element $window 'Id' $id
            if (-not $control -or -not $control.Current.IsEnabled) { return $false }
            $controls[$id] = $control
        }
        return $controls
    } 'selected demo and both presentation controls ready'
    if ($selectedControls.PlayPause.Current.Name -ne 'Open') { throw 'A selected demo without a target must offer Open.' }
    $speed = [System.Windows.Automation.RangeValuePattern](Find-Element $window 'Id' 'PlaybackSpeed').GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
    foreach ($setting in @(@{ Value = 100; Total = '00:00:03'; Label = 'user 0.1s / reply 1s' }, @{ Value = 50; Total = '00:00:09'; Label = 'user 1.05s / reply 3s' }, @{ Value = 0; Total = '00:00:14'; Label = 'user 2s / reply 5s' })) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $speed.SetValue($setting.Value)
        $watch.Stop()
        if ($watch.ElapsedMilliseconds -ge 250) { throw "Live speed change blocked UI: $($watch.ElapsedMilliseconds)ms" }
        Wait-Until { (Find-Element $window 'Id' 'RunEstimate').Current.Name -eq ('Estimated total: ' + $setting.Total + ' + manual waits') } 'full selected run estimate follows slider without opening native playback' | Out-Null
        if ((Find-Element $window 'Id' 'SpeedLabel').Current.Name -notlike ('*' + $setting.Label)) { throw 'Speed label does not match phase timing.' }
    }
    if (-not $PlaybackOnly) {
    foreach ($action in @(
        @{ Id = 'GeneratePromptSummaries' },
        @{ Id = 'GenerateOutputSummaries' }
    )) {
        $link = Wait-Until {
            $candidate = Find-Element $window 'Id' $action.Id
            if ($candidate.Current.IsEnabled -and $candidate.Current.Name -match '\(1/2\)$') { return $candidate }
        } 'controller links display separate saved summaries out of total exchanges'
        Invoke-Button $window $action.Id
        $notice = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'scoped controller consent'
        Invoke-Button $notice 'CancelOpenAIGeneration'
        Wait-Until { -not (Get-AppWindow 'Generate OpenAI Summaries') } 'controller authoring cancellation' | Out-Null
    }
    $settingsButton = Find-Element $window 'Id' 'AISettings'
    if ($settingsButton.Current.BoundingRectangle.Right -gt (Find-Element $window 'Id' 'CheckUpdates').Current.BoundingRectangle.Left) { throw 'Settings must be left of Check for updates.' }
    Invoke-Button $window 'AISettings'
    $settingsDialog = Wait-Until { Get-AppWindow 'OpenAI Settings' } 'manage saved key'
    $settingsPath = Join-Path $env:LOCALAPPDATA 'VSCodeDemoPlayer\ai-settings.json'
    if ([IO.File]::ReadAllText($settingsPath).Contains('synthetic-openai-key-for-ui-tests')) { throw 'The settings file contains a plaintext key.' }
    Invoke-Button $settingsDialog 'DeleteOpenAIKey'
    Wait-Until { -not (Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json).encryptedKey } 'saved key deletion' | Out-Null
    Invoke-Button $settingsDialog 'CancelOpenAISettings'
    Wait-Until { -not (Get-AppWindow 'OpenAI Settings') } 'close settings after deletion' | Out-Null
    Invoke-Button $window 'GeneratePromptSummaries'
    $settingsDialog = Wait-Until { Get-AppWindow 'OpenAI Settings' } 'generation prompts again after deletion'
    ([System.Windows.Automation.ValuePattern](Find-Element $settingsDialog 'Id' 'OpenAIKey').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('synthetic-openai-key-for-ui-tests')
    Invoke-Button $settingsDialog 'SaveOpenAISettings'
    $notice = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'rejected key test consent'
    [IO.File]::WriteAllText((Join-Path $evidence 'reject-next-key'), 'synthetic')
    Invoke-Button $notice 'ConfirmOpenAIGeneration'
    $settingsDialog = Wait-Until { Get-AppWindow 'OpenAI Settings' } 'rejected key prompts for replacement'
    if ((Find-Element $settingsDialog 'Id' 'OpenAISettingsError').Current.Name -notlike '*rejected*') { throw 'Rejected key is not reported explicitly.' }
    ([System.Windows.Automation.ValuePattern](Find-Element $settingsDialog 'Id' 'OpenAIKey').GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)).SetValue('synthetic-replaced-openai-key-for-ui-tests')
    Invoke-Button $settingsDialog 'SaveOpenAISettings'
    Wait-Until { -not (Get-AppWindow 'OpenAI Settings') } 'replacement saved without automatic paid retry' | Out-Null
    if (Get-AppWindow 'Review AI Summaries') { throw 'Rejected-key generation must not create reviewable success.' }
    Invoke-Button $window 'GeneratePromptSummaries'
    $notice = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'explicit retry after key replacement'
    Invoke-Button $notice 'ConfirmOpenAIGeneration'
    $review = Wait-Until { Get-AppWindow 'Review AI Summaries' } 'prompt-only AI review'
    Invoke-Button $review 'SaveSummaries'
    Wait-Until { -not (Get-AppWindow 'Review AI Summaries') } 'AI prompt save' | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'GeneratePromptSummaries').Current.Name -match '\(2/2\)$' } 'AI prompt save updates the counter' | Out-Null
    $generatedEntry = Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }
    if ($generatedEntry.recording.promptSummaries[1] -ne 'Synthetic OpenAI input summary.') { throw 'AI prompt summary was not saved.' }
    Invoke-DemoLibrary @{ command = 'summaries'; id = $summaryEntry.id; summaries = @($overlaySummary, $null); expected = @($generatedEntry.recording.promptSummaries) } | Out-Null
    [IO.File]::WriteAllText((Join-Path $evidence 'delay-summary'), 'synthetic')
    Invoke-Button $window 'GenerateOutputSummaries'
    $notice = Wait-Until { Get-AppWindow 'Generate OpenAI Summaries' } 'generation cancellation consent'
    Invoke-Button $notice 'ConfirmOpenAIGeneration'
    $generating = Wait-Until { Get-AppWindow 'Generating AI Summaries' } 'cancellable OpenAI request'
    Invoke-Button $generating 'CancelOpenAISummaryProgress'
    Wait-Until { -not (Get-AppWindow 'Generating AI Summaries') -and (Find-Element $window 'Id' 'ChooseDemo').Current.IsEnabled } 'cancel request restores the controller' | Out-Null
    Remove-Item -LiteralPath (Join-Path $evidence 'delay-summary')
    if (Get-AppWindow 'Review AI Summaries') { throw 'Canceled generation opened a partial review.' }
    Write-Output 'OPENAI UI PASSED: masked key/link, consent cancellation, encrypted retention/delete/re-prompt, rejected-key replacement, explicit retry, combined/prompt/output drafts, save/cancel, counters, progress cancellation, Settings left of updates. All HTTP responses synthetic; no real API key or paid request.'
    if ($LargeSummarySources) {
        $requests = @(Get-Content -LiteralPath (Join-Path $evidence 'openai-requests.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        if (@($requests | Where-Object { $_.kind -eq 'output' }).Count -lt 40) { throw 'The >1MiB output did not exercise multiple bounded requests and combination.' }
        Write-Output 'LARGE SUMMARY UI PASSED: short prompts with a >1MiB reply reach consent and chunked combined/output generation, editable review/save/cancel and counters.'
        return
    }
    $countEntry = Invoke-DemoLibrary @{ command = 'read'; id = $summaryEntry.id }
    Invoke-DemoLibrary @{ command = 'summaries'; kind = 'output'; id = $summaryEntry.id; summaries = @($outputSummary, 'Manually saved second reply'); expected = @($countEntry.recording.outputSummaries) } | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'GenerateOutputSummaries').Current.Name -match '\(2/2\)$' } 'controller observes external summary save without reselecting' | Out-Null
    if ((Find-Element $window 'Id' 'GeneratePromptSummaries').Current.Name -notmatch '\(1/2\)$') { throw 'Output saves changed prompt count.' }
    Invoke-DemoLibrary @{ command = 'summaries'; kind = 'output'; id = $summaryEntry.id; summaries = @($outputSummary, $null); expected = @($outputSummary, 'Manually saved second reply') } | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'GenerateOutputSummaries').Current.Name -match '\(1/2\)$' } 'controller observes summary clear without reselecting' | Out-Null
    }
    foreach ($id in @('ShowPrompt','ShowElapsed','ShowOutput')) { $selectedControls[$id] = Find-Element $window 'Id' $id }
    Save-WindowImage $window 'controller-summary-links.png'
    $showPrompt = $selectedControls.ShowPrompt
    $showElapsed = $selectedControls.ShowElapsed
    if (-not $showPrompt.Current.IsEnabled -or -not $showElapsed.Current.IsEnabled) {
        throw ('Selected demo presentation options must be enabled before Open. Prompt: ' + ($showPrompt | Out-String).Trim() +
            '; elapsed: ' + ($showElapsed | Out-String).Trim() + '; controller enabled: ' + $window.Current.IsEnabled)
    }
    if (Get-AppWindow 'Playback overlay') { throw 'Presentation must default to hidden.' }
    ([System.Windows.Automation.TogglePattern]$showPrompt.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    ([System.Windows.Automation.TogglePattern]$showElapsed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    $overlay = Wait-Until { Get-AppWindow 'Playback overlay' } 'selected demo overlay before Open'
    if ((Find-Element $overlay 'Id' 'PromptText').Current.Name -cne $overlaySummary) { throw 'Selected demo prompt summary is incorrect or cancel saved an unreviewed draft.' }
    if ((Find-Element $overlay 'Id' 'ElapsedText').Current.Name -ne '00:00:00') { throw 'Selected demo timer must start at zero.' }
    if ((Find-Element $overlay 'Id' 'PromptProgress').Current.Name -ne '1/2') { throw 'Selected demo progress preview is incorrect.' }
    Save-WindowImage $overlay 'overlay-before-open.png'
    $beforeResize = $overlay.Current.BoundingRectangle
    $beforeText = (Find-Element $overlay 'Id' 'PromptText').Current.BoundingRectangle
    $grip = (Find-Element $overlay 'Id' 'OverlayResize').Current.BoundingRectangle
    $cursorBefore = [System.Windows.Forms.Cursor]::Position
    try { [DemoUITest]::Drag([int]($grip.Left + $grip.Width / 2), [int]($grip.Top + $grip.Height / 2), -280, 140) }
    finally { [System.Windows.Forms.Cursor]::Position = $cursorBefore }
    Write-Output ('RESIZE: before=' + $beforeResize + '; grip=' + $grip + '; after=' + $overlay.Current.BoundingRectangle)
    Save-WindowImage $overlay 'overlay-after-drag.png'
    Wait-Until { $bounds = $overlay.Current.BoundingRectangle; [Math]::Abs($bounds.Width - ($beforeResize.Width - 280)) -lt 4 -and [Math]::Abs($bounds.Height - ($beforeResize.Height + 140)) -lt 4 } 'bottom-right grip changes both dimensions' | Out-Null
    $resized = $overlay.Current.BoundingRectangle
    if ((Find-Element $overlay 'Id' 'PromptText').Current.BoundingRectangle.Height -le $beforeText.Height) { throw 'Summary text did not wrap into more lines after narrowing.' }
    $narrowTimer = (Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle
    $narrowPrompt = (Find-Element $overlay 'Id' 'PromptText').Current.BoundingRectangle
    if ($narrowTimer.Bottom -ge $narrowPrompt.Top) { throw 'Narrow overlay timer is not above the summary.' }
    if ($narrowPrompt.Width -lt $resized.Width - 70) { throw 'Narrow overlay did not give the text the full available width.' }
    Save-WindowImage $overlay 'overlay-resized-wrapped.png'
    $showOutput = Find-Element $window 'Id' 'ShowOutput'
    if (([System.Windows.Automation.TogglePattern]$showOutput.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw 'Output summary must default off.' }
    $playbackEntryId = if ($PlaybackOnly) { $saved.id } else { $summaryEntry.id }
    $completeOutputEntry = Invoke-DemoLibrary @{ command = 'read'; id = $playbackEntryId }
    $secondOutputSummary = 'I showed the next recorded answer.'
    Invoke-DemoLibrary @{ command = 'summaries'; kind = 'output'; id = $playbackEntryId
        summaries = @($outputSummary, $secondOutputSummary); expected = @($completeOutputEntry.recording.outputSummaries) } | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'GenerateOutputSummaries').Current.Name -match '\(2/2\)$' } 'controller observes complete output summaries' | Out-Null
    ([System.Windows.Automation.TogglePattern]$showOutput.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Wait-Until { (Find-Element $overlay 'Id' 'FirstText').Current.Name -ceq $overlaySummary } 'conversation starts with Input1' | Out-Null
    if ((Find-Element $overlay 'Id' 'FirstLabel').Current.Name -ne 'You' -or -not $showElapsed.Current.IsEnabled) { throw 'Output mode must label the input and keep recorded time independently selectable.' }
    $elapsedToggle = [System.Windows.Automation.TogglePattern]$showElapsed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $elapsedToggle.Toggle()
    Wait-Until { (Find-Element $overlay 'Id' 'ElapsedText').Current.IsOffscreen } 'unchecked recorded time hides timer in output mode' | Out-Null
    if ((Find-Element $overlay 'Id' 'FirstText').Current.Name -cne $overlaySummary -or -not $overlay.Current.IsEnabled) { throw 'Hiding time also hid or damaged conversation summaries.' }
    $elapsedToggle.Toggle()
    Wait-Until { -not (Find-Element $overlay 'Id' 'ElapsedText').Current.IsOffscreen -and
        (Find-Element $overlay 'Id' 'ElapsedText').Current.Name -eq '00:00:00' } 'checked recorded time restores real zero preview' | Out-Null
    $timerTop = (Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle.Top
    Save-WindowImage $overlay 'conversation-input1.png'
    Invoke-Button $window 'PlayPause'
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'isolated replay process'
    $replayId = [int]$replay.ProcessId
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' -and (Find-Element $window 'Id' 'PlayPause').Current.IsEnabled } 'Open prepares target without starting playback' 50 | Out-Null
    $fitArea = [System.Windows.SystemParameters]::WorkArea
    $expectedFit = Get-DemoSummaryLayout $overlaySummary $outputSummary $resized.Width ($fitArea.Width - 32) ($fitArea.Height - 32)
    $expectedHeight = [Math]::Max($resized.Height, $expectedFit.Height)
    if (-not $expectedFit.Fits -or [Math]::Abs($overlay.Current.BoundingRectangle.Width - $expectedFit.Width) -gt 2 -or
        [Math]::Abs($overlay.Current.BoundingRectangle.Height - $expectedHeight) -gt 2) { throw 'Playback must preserve manual dimensions except the exact growth required for the complete prompt/reply pair.' }
    $resized = $overlay.Current.BoundingRectangle
    if ((Find-Element $window 'Id' 'NextStep').Current.IsEnabled) { throw 'Next Step must be unavailable before the first exchange.' }
    if (([System.Windows.Automation.TogglePattern]$showPrompt.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On -or
        ([System.Windows.Automation.TogglePattern]$showElapsed.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { throw 'Open must preserve presentation choices.' }
    Save-WindowImage $window 'controller-open-ready.png'
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Play') { throw 'Open started playback without a second click.' }
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'explicit Play starts playback' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' } 'paused playback' | Out-Null
    Save-WindowImage $window 'controller-paused.png'
    Wait-Until { (Find-Element $window 'Id' 'SelectExchanges').Current.IsEnabled } 'selection enabled while paused' | Out-Null
    Invoke-Button $window 'SelectExchanges'
    $exchangeDialog = Wait-Until { Get-AppWindow 'Select exchanges' } 'paused exchange checklist'
    ([System.Windows.Automation.InvokePattern](Find-Element $exchangeDialog 'Name' 'Cancel').GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
    Wait-Until { -not (Get-AppWindow 'Select exchanges') } 'cancel returns to paused playback' | Out-Null
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Resume' -or
        -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue)) { throw 'Cancel must preserve the paused process.' }
    Invoke-Button $window 'SelectExchanges'
    $exchangeDialog = Wait-Until { Get-AppWindow 'Select exchanges' } 'save paused checklist'
    Invoke-Button $exchangeDialog 'SaveExchangeSelection'
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'old scoped target closes for reselection' 20 | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' -and
        (Find-Element $window 'Id' 'PlayPause').Current.IsEnabled } 'saved selection waits for explicit Resume' 50 | Out-Null
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'reselection target'
    $replayId = [int]$replay.ProcessId
    Start-Sleep -Milliseconds 800
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Resume' -or
        (Find-Element $window 'Id' 'NextStep').Current.IsEnabled) { throw 'Saving a paused selection must not autoplay.' }
    Save-WindowImage $window 'controller-reselection-waiting.png'
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Start Over' -and (Find-Element $window 'Id' 'NextStep').Current.IsEnabled } 'first answer review offers restart and next exchange' | Out-Null
    Wait-Until { (Find-Element $overlay 'Id' 'SecondText').Current.Name -ceq $outputSummary } 'completed Input1 and Output1' | Out-Null
    if ((Find-Element $overlay 'Id' 'FirstText').Current.Name -cne $overlaySummary -or
        (Find-Element $overlay 'Id' 'SecondLabel').Current.Name -ne 'AI' -or
        (Find-Element $overlay 'Id' 'ElapsedText').Current.Name -ne '00:01:01') { throw 'First completion changed input, labels or cumulative recorded timer.' }
    if ([Math]::Abs((Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle.Top - $timerTop) -gt 1) { throw 'Completion moved the fixed timer.' }
    $pairInput = (Find-Element $overlay 'Id' 'FirstText').Current.BoundingRectangle
    $pairOutput = (Find-Element $overlay 'Id' 'SecondText').Current.BoundingRectangle
    $fixedTimer = (Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle
    if ($pairInput.Top -le $fixedTimer.Bottom -or $pairOutput.Bottom -gt $resized.Bottom - 16 -or
        $pairInput.Height -le 0 -or $pairOutput.Height -le 0) { throw 'Both complete summaries must be visible together between the fixed timer and overlay bottom.' }
    Save-WindowImage $overlay 'conversation-input1-output1.png'
    Invoke-Button $window 'NextStep'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'second exchange starts before reselection' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'SelectExchanges').Current.IsEnabled } 'pause a later exchange with completed history' | Out-Null
    $pausedAuto = [System.Windows.Automation.TogglePattern](Find-Element $window 'Id' 'AutoContinue').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $pausedAuto.Toggle()
    Invoke-Button $window 'SelectExchanges'
    $exchangeDialog = Wait-Until { Get-AppWindow 'Select exchanges' } 'keep second exchange and earlier history'
    Invoke-Button $exchangeDialog 'SaveExchangeSelection'
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'later reselection closes old scoped target' 20 | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' -and
        (Find-Element $window 'Id' 'PlayPause').Current.IsEnabled } 'later exchange waits for Resume despite Auto continue' 50 | Out-Null
    Start-Sleep -Milliseconds 2500
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Resume' -or
        (Find-Element $window 'Id' 'NextStep').Current.IsEnabled) { throw 'A later paused reselection autoplayed from reconstructed review history.' }
    ([System.Windows.Automation.TogglePattern](Find-Element $window 'Id' 'AutoContinue').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'later reselection target'
    $replayId = [int]$replay.ProcessId
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'Resume uses the guarded next command for a later exchange' | Out-Null
    Wait-Until { (Find-Element $overlay 'Id' 'FirstText').Current.Name -ceq $overlaySummary -and
        (Find-Element $overlay 'Id' 'Message2Text').Current.Name -ceq 'Show the next recorded interaction.' } 'Input2 appends below retained Input1 and Output1' | Out-Null
    if ((Find-Element $overlay 'Id' 'FirstLabel').Current.Name -ne 'You' -or
        (Find-Element $overlay 'Id' 'SecondLabel').Current.Name -ne 'AI' -or
        (Find-Element $overlay 'Id' 'Message2Label').Current.Name -ne 'You') { throw 'History must preserve all speaker labels.' }
    $nextTimerBounds = (Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle
    if ([Math]::Abs($nextTimerBounds.Top - $timerTop) -gt 1) { throw ('Next Step moved the fixed timer. Expected top=' + $timerTop + '; actual=' + $nextTimerBounds + '; overlay=' + $overlay.Current.BoundingRectangle) }
    Save-WindowImage $overlay 'conversation-output1-input2.png'
    Wait-Until { (Find-Element $window 'Id' 'Status').Current.Name -like 'Finished*' } 'second answer complete' | Out-Null
    Wait-Until { (Find-Element $overlay 'Id' 'Message2Text').Current.Name -ceq 'Show the next recorded interaction.' -and
        (Find-Element $overlay 'Id' 'Message3Text').Current.Name -ceq $secondOutputSummary } 'Output2 appends to four-message history' | Out-Null
    if ((Find-Element $overlay 'Id' 'ElapsedText').Current.Name -ne '00:03:03' -or
        [Math]::Abs((Find-Element $overlay 'Id' 'ElapsedText').Current.BoundingRectangle.Top - $timerTop) -gt 1) { throw 'Final output changed fixed cumulative timer semantics.' }
    Save-WindowImage $overlay 'conversation-input2-output2.png'
    if ((Find-Element $window 'Id' 'NextStep').Current.IsEnabled) { throw 'Next Step must be unavailable after the final exchange.' }
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Replay' -or
        (Find-Element $window 'Id' 'Stop').Current.Name -ne 'Close recording') { throw 'Finished playback must offer Replay and Close recording without exiting VibeReplay.' }
    $elapsedToggle.Toggle()
    Wait-Until { (Find-Element $overlay 'Id' 'ElapsedText').Current.IsOffscreen } 'completed recording also respects unchecked timer' | Out-Null
    $elapsedToggle.Toggle()
    Wait-Until { -not (Find-Element $overlay 'Id' 'ElapsedText').Current.IsOffscreen -and
        (Find-Element $overlay 'Id' 'ElapsedText').Current.Name -eq '00:03:03' } 'completed recorded duration restores without resetting history' | Out-Null
    Start-Sleep -Milliseconds 800
    if (-not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) -or
        (Find-Element $overlay 'Id' 'Message3Text').Current.Name -cne $secondOutputSummary) { throw 'Finished playback must retain its window and last reply.' }
    Save-WindowImage $window 'controller-finished.png'
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'Start Over restarts the selected demo' | Out-Null
    Wait-Until { (Find-Element $overlay 'Id' 'FirstText').Current.Name -ceq $overlaySummary } 'Start Over resets conversation to Input1' | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'Status').Current.Name -eq 'Exchange complete  1/2' } 'Start Over returns to first exchange' | Out-Null
    $auto = Find-Element $window 'Id' 'AutoContinue'
    $autoPattern = [System.Windows.Automation.TogglePattern]$auto.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($autoPattern.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw 'Auto continue must default off.' }
    $dwell = [Diagnostics.Stopwatch]::StartNew()
    $autoPattern.Toggle()
    Start-Sleep -Milliseconds 1000
    if ((Find-Element $window 'Id' 'Status').Current.Name -ne 'Exchange complete  1/2') { throw 'Auto continue skipped newly revealed output before reading dwell.' }
    Wait-Until { (Find-Element $window 'Id' 'Status').Current.Name -like 'Finished*' } 'Auto continue finishes final exchange without Next Step' 30 | Out-Null
    if ($dwell.Elapsed.TotalSeconds -lt 2 -or (Find-Element $window 'Id' 'NextStep').Current.IsEnabled) { throw 'Auto continue missed dwell or looped after last exchange.' }
    $autoPattern.Toggle()
    Invoke-Button $window 'Stop'
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'close finished recording closes only its replay target' 20 | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'ChooseDemo').Current.IsEnabled -and
        (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Open' } 'finished recording returns to the app without exiting' | Out-Null
    if (-not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue)) { throw 'Closing the finished recording exited VibeReplay.' }
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' } 'same recording can reopen without restarting VibeReplay' 50 | Out-Null
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'reopened target after closing finished recording'
    $replayId = [int]$replay.ProcessId
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'Status').Current.Name -eq 'Exchange complete  1/2' } 'manual restart after auto run' | Out-Null
    ([System.Windows.Automation.TogglePattern]$showOutput.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Wait-Until { (Find-Element $overlay 'Id' 'PromptText').Current.Name -ceq $overlaySummary -and $showElapsed.Current.IsEnabled } 'output off restores legacy input-only mode and elapsed choice' | Out-Null
    $advance = [Diagnostics.Stopwatch]::StartNew()
    $autoPattern.Toggle()
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'prompt-only auto-continue starts the next exchange immediately' | Out-Null
    $advance.Stop()
    if ($advance.ElapsedMilliseconds -ge 1500) { throw ('Prompt-only auto-continue retained an artificial wait: ' + $advance.ElapsedMilliseconds + 'ms') }
    $autoPattern.Toggle()
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Replay' } 'prompt-only final exchange completes' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'restart first exchange for changed selection' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'SelectExchanges').Current.IsEnabled } 'pause first exchange before excluding it' | Out-Null
    Invoke-Button $window 'SelectExchanges'
    $exchangeDialog = Wait-Until { Get-AppWindow 'Select exchanges' } 'exclude current exchange checklist'
    ([System.Windows.Automation.TogglePattern](Find-Element $exchangeDialog 'Id' 'ExchangeSelection0').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Invoke-Button $exchangeDialog 'SaveExchangeSelection'
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'old target closes after excluding current' 20 | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' -and
        (Find-Element $window 'Id' 'PlayPause').Current.IsEnabled } 'next selected exchange waits for Resume' 50 | Out-Null
    Start-Sleep -Milliseconds 800
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Resume') { throw 'Excluding current exchange caused autoplay.' }
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $overlay 'Id' 'PromptText').Current.Name -eq 'Show the next recorded interaction.' } 'Resume starts next original exchange, not the excluded first one' | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Replay' } 'selected second exchange finishes' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'restart selected second exchange' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'SelectExchanges').Current.IsEnabled } 'pause last original exchange' | Out-Null
    Invoke-Button $window 'SelectExchanges'
    $exchangeDialog = Wait-Until { Get-AppWindow 'Select exchanges' } 'select only an earlier original exchange'
    foreach ($index in @(0,1)) {
        ([System.Windows.Automation.TogglePattern](Find-Element $exchangeDialog 'Id' "ExchangeSelection$index").GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    }
    Invoke-Button $exchangeDialog 'SaveExchangeSelection'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Replay' -and
        (Find-Element $window 'Id' 'PlayPause').Current.IsEnabled } 'no following included exchange finishes without looping backwards' 50 | Out-Null
    Start-Sleep -Milliseconds 800
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Replay') { throw 'End-of-selection looped backwards automatically.' }
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'restart earlier exchange explicitly before Stop' | Out-Null
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'final reselection target'
    $replayId = [int]$replay.ProcessId
    Write-Output ('PAUSED SELECTION AND DELAY PASSED: cancel preserves process; keep-current restarts; remove-current resumes next original; no following exchange finishes; saves do not autoplay; prompt-only next transition ' + $advance.ElapsedMilliseconds + 'ms (<1500ms).')
    Invoke-Button $window 'Stop'
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'scoped replay closes' 20 | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'ChooseDemo').Current.IsEnabled } 'controller remains available after stop' | Out-Null
    if (-not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue)) { throw 'Stop closed the standalone controller.' }
    if ((Find-Element $window 'Id' 'PlayPause').Current.Name -ne 'Open') { throw 'Stopped targets must return the primary control to Open.' }
    Invoke-Button $window 'SelectExchanges'
    $exchangeDialog = Wait-Until { Get-AppWindow 'Select exchanges' } 'restore complete synthetic selection'
    ([System.Windows.Automation.TogglePattern](Find-Element $exchangeDialog 'Id' 'ExchangeSelection1').GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    Invoke-Button $exchangeDialog 'SaveExchangeSelection'
    Wait-Until { -not (Get-AppWindow 'Select exchanges') } 'idle selection restored' | Out-Null
    if (-not $showPrompt.Current.IsEnabled -or -not $showElapsed.Current.IsEnabled) { throw 'Presentation options must remain available after Stop.' }
    $overlay = Wait-Until { Get-AppWindow 'Playback overlay' } 'selected demo overlay after Stop'
    if ((Find-Element $overlay 'Id' 'PromptText').Current.Name -cne $overlaySummary -or
        (Find-Element $overlay 'Id' 'ElapsedText').Current.Name -ne '00:00:00') { throw 'Stop must restore the selected demo presentation, not stale playback progress.' }
    if ([Math]::Abs($overlay.Current.BoundingRectangle.Width - $resized.Width) -gt 2 -or [Math]::Abs($overlay.Current.BoundingRectangle.Height - $resized.Height) -gt 2) { throw ('Stop reset the resized overlay. Expected=' + $resized + '; actual=' + $overlay.Current.BoundingRectangle) }
    Save-WindowImage $window 'controller-after-stop.png'
    Invoke-Button $window 'PlayPause'
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'second isolated replay process'
    $replayId = [int]$replay.ProcessId
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' } 'second target becomes ready' 50 | Out-Null
    (Get-Process -Id $replayId).CloseMainWindow() | Out-Null
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Open' } 'closing target returns to Open' 20 | Out-Null
    if ((Find-Element $window 'Id' 'Status').Current.Name -notlike '*target closed*') { throw 'Unexpected target closure must be reported.' }
    Invoke-Button $window 'PlayPause'
    $replay = Wait-Until {
        Get-CimInstance Win32_Process -Filter "Name='Code.exe'" | Where-Object { $_.CommandLine -like '*--extensionDevelopmentPath*' -and $_.CommandLine.Contains($root) -and $_.CommandLine -like '*historical-replay-player-*' -and $_.CommandLine -notlike '*--type=*' } | Select-Object -First 1
    } 'reopened isolated target'
    $replayId = [int]$replay.ProcessId
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Play' } 'reopened target ready' 50 | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Pause' } 'second run starts explicitly' | Out-Null
    Invoke-Button $window 'PlayPause'
    Wait-Until { (Find-Element $window 'Id' 'PlayPause').Current.Name -eq 'Resume' } 'second run pauses' | Out-Null
    ([System.Windows.Automation.WindowPattern]$window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    Wait-Until { -not (Get-Process -Id $replayId -ErrorAction SilentlyContinue) } 'closing controller stops its paused replay' 20 | Out-Null
    Wait-Until { -not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue) } 'controller closes after its replay stops' | Out-Null
    $launch = Start-TestPlayer
    $script:controllerId = $launch.ProcessId
    $window = Wait-Until { Get-AppWindow 'Demo Player' } 'reopened standalone controller'
    Invoke-Button $window 'ChooseDemo'
    $dialog = Wait-Until { Get-AppWindow 'Find interaction' } 'persisted selections after restart'
    ([System.Windows.Automation.SelectionItemPattern](Find-Element $dialog 'Id' 'SavedSelectionsTab').GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    $list = Find-Element $dialog 'Id' 'DemoList'
    Wait-Until {
        $list = Find-Element $dialog 'Id' 'DemoList'
        $list.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition).Count -eq $(if ($PlaybackOnly) { 1 } else { 2 })
    } 'expected saved selections finish loading after application restart' | Out-Null
    ([System.Windows.Automation.WindowPattern]$dialog.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    ([System.Windows.Automation.WindowPattern]$window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close()
    Wait-Until { -not (Get-Process -Id $controllerId -ErrorAction SilentlyContinue) } 'reopened controller closes when idle' | Out-Null
    if ([IO.File]::ReadAllText($target) -ne $targetContent) { throw 'Playback modified the saved edit target.' }
    if ($PlaybackOnly) {
        Write-Output 'PLAYBACK UI ACCEPTANCE PASSED: exact live speed estimates, retained resize/wrapping, full-pair visibility/history/timer, output reading dwell, prompt-only immediate next, pause/cancel/reselection/current/next/end, explicit Resume without autoplay, scoped Stop/close, persisted selections and unchanged edit target. Configuration/authoring acceptance NOT RUN in this focused command.'
    } else {
        Write-Output 'UI ACCEPTANCE PASSED: automatic native/SDK table, filters, capture/save, rename/select, manual input/output save/reopen/cancel/clear, inclusion cancel/exclude/reinclude with stable summaries/counts, direct synthetic OpenAI settings/consent/review/recovery, retained resize/wrapping, default-off output and Auto continue, Input1 then Input1+Output1 then retained history+Input2 then four bubbles with explicit missing Output2, labeled You/AI, fixed cumulative 00:01:01/00:03:03 timer, Auto continue reading dwell and final-step refusal without Next, manual restart, output-off legacy restoration, Open without autoplay, Play/pause/resume, Next Step, scoped Stop/close, persistence, unchanged edit target. No paid requests or real library/settings changes.'
    }
} catch {
    $uiFailed = $true
    Write-Output $_.ScriptStackTrace
    Write-Output $_.Exception.Message
    if ($script:controllerProcess -and $script:controllerProcess.HasExited) {
        Write-Output ('Controller output: ' + $script:controllerOutput.GetAwaiter().GetResult())
        Write-Output ('Controller error: ' + $script:controllerErrors.GetAwaiter().GetResult())
    }
    $failedWindow = Get-AppWindow 'Demo Player'
    if ($failedWindow) {
        $statusCondition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'Status')
        $failedStatus = $failedWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $statusCondition)
        if ($failedStatus) { Write-Output ('Controller status: ' + $failedStatus.Current.Name + ' | ' + $failedStatus.Current.HelpText) }
        else {
            $failedWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                ForEach-Object { Write-Output ('Failure dialog: ' + $_.Current.Name) }
        }
        Save-WindowImage $failedWindow 'failure.png'
    }
    $failedOverlay = Get-AppWindow 'Playback overlay'
    if ($failedOverlay) {
        Write-Output ('Failure overlay bounds: ' + $failedOverlay.Current.BoundingRectangle)
        Save-WindowImage $failedOverlay 'failure-overlay.png'
    }
    throw
} finally {
    if ($uiFailed) { Stop-FailedTestControllers }
    foreach ($title in @('Generating AI Summaries', 'Review AI Summaries', 'Generate OpenAI Summaries', 'OpenAI Settings', 'Input / Output Summaries', 'Find interaction')) {
        $child = Get-AppWindow $title
        if ($child) { ([System.Windows.Automation.WindowPattern]$child.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close() }
    }
    $remaining = Get-AppWindow 'Demo Player'
    if ($remaining) { ([System.Windows.Automation.WindowPattern]$remaining.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)).Close() }
    if ($replayId) {
        $process = Get-Process -Id $replayId -ErrorAction SilentlyContinue
        if ($process) { $process.CloseMainWindow() | Out-Null }
    }
    if (-not $uiFailed) {
        foreach ($task in $tasks) {
            if (-not $task.Wait(3000)) { Write-Warning 'An automation invocation did not finish within its cleanup timeout.' }
        }
    }
    $env:APPDATA = $originalAppData
    $env:USERPROFILE = $originalProfile
    $env:LOCALAPPDATA = $originalLocalAppData
}
