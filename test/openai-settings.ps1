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
    Write-Output ('OPENAI SETTINGS PASSED: ' + $assertions + ' assertions; current-user DPAPI, atomic replacement/delete, masked entry and OpenAI link. No real key or network request.')
} finally {
    $env:LOCALAPPDATA = $original
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
