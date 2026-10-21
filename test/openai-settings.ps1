param([string]$NodePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'DemoDialogs.ps1')
. (Join-Path $root 'PlayerAI.ps1')
$original = $env:LOCALAPPDATA
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('openai-settings-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$env:LOCALAPPDATA = $scratch
$assertions = 0
function Assert-True($Value, [string]$Message) {
    if (-not $Value) { throw $Message }
    $script:assertions++
}
try {
    Assert-True ((Get-PlayerAISettings).model -eq 'gpt-4.1-mini') 'Default low-cost model is available without a key.'
    Assert-True ($null -eq (Get-PlayerOpenAIKey)) 'Missing key is not fabricated.'
    $key = 'synthetic-openai-key-for-storage-tests'
    Save-PlayerAISettings 'gpt-4.1-mini' $key
    $path = Join-Path $scratch 'VSCodeDemoPlayer\ai-settings.json'
    $json = [IO.File]::ReadAllText($path)
    Assert-True (-not $json.Contains($key)) 'The key must not be saved as plaintext.'
    Assert-True ((Get-PlayerOpenAIKey) -ceq $key) 'DPAPI key round-trip works for this Windows user.'
    $encrypted = (Get-PlayerAISettings).encryptedKey
    Save-PlayerAISettings 'gpt-4o-mini'
    Assert-True ((Get-PlayerAISettings).model -eq 'gpt-4o-mini') 'Model changes persist.'
    Assert-True ((Get-PlayerAISettings).encryptedKey -ceq $encrypted) 'Model-only changes preserve the key.'
    Save-PlayerAISettings 'gpt-4.1-mini' 'synthetic-replacement-openai-key'
    Assert-True ((Get-PlayerOpenAIKey) -ceq 'synthetic-replacement-openai-key') 'Replacement key works.'
    $before = [IO.File]::ReadAllText($path)
    foreach ($invalid in @(@{ Model = '../bad'; Key = $key }, @{ Model = 'gpt-4.1-mini'; Key = "key`nwith spaces" })) {
        $failed = $false
        try { Save-PlayerAISettings $invalid.Model $invalid.Key } catch { $failed = $true }
        Assert-True $failed 'Invalid settings must fail explicitly.'
        Assert-True ([IO.File]::ReadAllText($path) -ceq $before) 'Invalid settings cannot overwrite the saved key.'
    }
    $broken = Get-PlayerAISettings
    $broken.encryptedKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not DPAPI ciphertext'))
    [IO.File]::WriteAllText($path, ($broken | ConvertTo-Json))
    $failed = $false
    try { Get-PlayerOpenAIKey | Out-Null } catch { $failed = $true }
    Assert-True $failed 'Unprotect failure cannot become a silent missing-key fallback.'
    Save-PlayerAISettings 'gpt-4.1-mini' -DeleteKey
    Assert-True ($null -eq (Get-PlayerOpenAIKey)) 'Delete works even when saved ciphertext cannot be decrypted.'
    Assert-True (-not (Get-PlayerAISettings).encryptedKey) 'Deletion removes the saved ciphertext.'
    Assert-True (@(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Filter '*.tmp').Count -eq 0) 'Atomic saves leave no temporary credential files.'
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'PlayerAI.ps1'), [ref]$null, [ref]$null)
    $xaml = $ast.Find({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like '*Title="OpenAI Settings"*' }, $true)
    $dialog = New-DemoDialog $xaml.Value $null
    try {
        Assert-True ($dialog.FindName('Key') -is [Windows.Controls.PasswordBox]) 'The key control must be masked.'
        Assert-True ($dialog.FindName('Key').Password -eq '') 'A saved key is never placed into the UI field.'
        Assert-True ($dialog.FindName('KeyLink').Inlines.FirstInline.Text -like '*platform.openai.com/api-keys*') 'The key dialog links to OpenAI key management.'
    } finally { $dialog.Close() }
    $unicodeSource = ('x' * 63999) + [char]::ConvertFromUtf32(0x1F642) + ('y' * 64001)
    $parts = @(Split-PlayerAISummarySource $unicodeSource)
    Assert-True (($parts -join '') -ceq $unicodeSource) 'Chunking must preserve every original character in order.'
    Assert-True (@($parts | Where-Object { $_.Length -gt 64000 }).Count -eq 0) 'Every API source part is bounded.'
    Assert-True ($parts[0].Length -eq 63999) 'Chunk boundaries must not split a UTF-16 surrogate pair.'
    $progress = [pscustomobject]@{ Label = [pscustomobject]@{ Text = '' } }
    $progress | Add-Member -MemberType ScriptMethod -Name FindName -Value { param($Name) return $this.Label }
    $originalInvoke = ${function:Invoke-DemoLibrary}
    try {
        function Invoke-DemoLibrary($Request, $Owner, [string]$Helper, [int]$TimeoutSeconds, [switch]$KeepOwnerEnabled) {
            $script:summaryCalls.Add($Request)
            if ($script:failSummaryCall -and $script:summaryCalls.Count -eq $script:failSummaryCall) { throw 'Synthetic part failure.' }
            return ('s' * 300)
        }
        foreach ($kind in @('input', 'output')) {
            $script:summaryCalls = [Collections.Generic.List[object]]::new()
            $script:failSummaryCall = 0
            $result = Invoke-PlayerAISummary ([pscustomobject]@{ index = 0; kind = $kind; source = $unicodeSource }) $progress $key 'gpt-4.1-mini'
            Assert-True ($result.Length -eq 300) 'A long source produces one final overlay summary.'
            Assert-True ($summaryCalls.Count -eq 4) 'Three source parts are summarized and then combined once.'
            Assert-True (@($summaryCalls | Where-Object { $_.source.Length -gt 64000 }).Count -eq 0) 'Every helper request stays within the API input budget.'
            Assert-True (($summaryCalls[0..2].source -join '') -ceq $unicodeSource) 'All original source parts reach the helper without truncation.'
            Assert-True (@($summaryCalls | Where-Object { $_.kind -ne $kind }).Count -eq 0) 'Input/output kind is preserved through reduction.'
            Assert-True ($summaryCalls[0].partial -and -not $summaryCalls[0].combine) 'Source parts have explicit incomplete-context instructions.'
            Assert-True ($summaryCalls[3].combine -and -not $summaryCalls[3].partial) 'Final reduction combines notes rather than claiming they are original output.'
        }
        $script:summaryCalls = [Collections.Generic.List[object]]::new()
        $result = Invoke-PlayerAISummary ([pscustomobject]@{ index = 0; kind = 'output'; source = ('x' * (64000 * 214)) }) $progress $key 'gpt-4.1-mini'
        Assert-True ($summaryCalls.Count -eq 217 -and $result.Length -eq 300) 'Large note sets are reduced over bounded intermediate levels, not rejected.'
        Assert-True (@($summaryCalls | Where-Object { $_.source.Length -gt 64000 }).Count -eq 0) 'Intermediate reduction requests are bounded too.'
        $script:summaryCalls = [Collections.Generic.List[object]]::new()
        $script:failSummaryCall = 2
        $failed = $false
        try { Invoke-PlayerAISummary ([pscustomobject]@{ index = 0; kind = 'output'; source = $unicodeSource }) $progress $key 'gpt-4.1-mini' | Out-Null }
        catch { $failed = $_.Exception.Message -eq 'Synthetic part failure.' }
        Assert-True ($failed -and $summaryCalls.Count -eq 2) 'A part failure stops generation explicitly without retrying or producing a partial draft.'
        $script:summaryCalls = [Collections.Generic.List[object]]::new()
        $script:failSummaryCall = 0
        Invoke-PlayerAISummary ([pscustomobject]@{ index = 0; kind = 'input'; source = 'Short prompt.' }) $progress $key 'gpt-4.1-mini' | Out-Null
        Assert-True ($summaryCalls.Count -eq 1 -and -not $summaryCalls[0].partial -and -not $summaryCalls[0].combine) 'Short sources still use exactly one request without reduction.'
    } finally { ${function:Invoke-DemoLibrary} = $originalInvoke }
    $script:NodePath = if ($NodePath) { $NodePath } else { (Get-Command node.exe -ErrorAction Stop).Source }
    $script:LibraryRoot = Join-Path $scratch 'library'
    foreach ($helper in @('openai-summaries.js', 'library-cli.js')) {
        $state = Start-DemoLibraryProcess @{ command = 'unknown-test-command' } $helper
        try {
            $arguments = $state.Process.StartInfo.Arguments
            Assert-True ($arguments.StartsWith('--use-system-ca ') -eq ($helper -eq 'openai-summaries.js')) 'Only OpenAI helper processes explicitly enable the trusted Windows certificate store.'
            Assert-True (-not $arguments.Contains('reject-unauthorized') -and -not $arguments.Contains('insecure')) 'Certificate verification must never be disabled.'
        } finally { Stop-DemoLibraryProcess $state }
    }
    Write-Output ('OPENAI SETTINGS/SOURCE CHUNKING PASSED: ' + $assertions + ' assertions; DPAPI, key controls, exact source coverage, reduction/failures and production OpenAI-only Windows trust arguments. No real key or network request.')
} finally {
    $env:LOCALAPPDATA = $original
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
