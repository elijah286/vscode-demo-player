param(
    [Parameter(Mandatory = $true)][string]$NodePath,
    [string]$CodePath,
    [string]$EvidenceRoot
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $EvidenceRoot) { $EvidenceRoot = Join-Path $root '.build\compact-preview' }
. (Join-Path $root 'DemoDialogs.ps1')
$script:NodePath = (Resolve-Path -LiteralPath $NodePath).Path
$preview = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ([guid]::NewGuid().ToString('N'))
$script:LibraryRoot = Join-Path $preview 'library'
[IO.Directory]::CreateDirectory($preview) | Out-Null
$source = Join-Path $preview 'synthetic.jsonl'
$snapshot = @{
    kind = 0
    v = @{
        sessionId = 'vibereplay-synthetic-preview'
        customTitle = 'Authentication, without the friction'
        requests = @(
            @{
                result = @{}; timestamp = '2026-01-01T12:00:00.000Z'
                modelState = @{ completedAt = '2026-01-01T12:00:12.000Z' }
                message = @{ text = 'Design a simple token-based authentication flow. Explain the approach before implementation.' }
                response = @(@{ value = 'Use a login endpoint, short-lived access tokens, and a refresh endpoint with rotation. Would you like to start with the token service or the endpoints?' })
            },
            @{
                result = @{}; timestamp = '2026-01-01T12:00:15.000Z'
                modelState = @{ completedAt = '2026-01-01T12:00:30.000Z' }
                message = @{ text = 'Start with the token service. Keep this example read-only.' }
                response = @(@{ value = 'The token service would issue access tokens, validate their expiry, and rotate refresh tokens. This is a synthetic recorded example; no code or tool is executed.' })
            }
        )
    }
}
[IO.File]::WriteAllText($source, ($snapshot | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
$inspection = Invoke-DemoLibrary @{ command = 'inspect'; file = $source }
$saved = Invoke-DemoLibrary @{ command = 'capture'; file = $source; indices = @(0, 1); title = $snapshot.v.customTitle; sha256 = $inspection.sha256 }
$entry = Invoke-DemoLibrary @{ command = 'read'; id = $saved.id }
$null = Invoke-DemoLibrary @{
    command = 'summaryBatch'; id = $saved.id
    expected = Get-DemoSummaryExpected $entry.recording
    summaries = @{
        promptSummaries = @('Design a secure authentication flow and explain the approach first.', 'Start with the token service. Keep the example read-only.')
        outputSummaries = @('Plan: login endpoint, token middleware, and rotating refresh tokens. Start with the token service or the endpoints?', 'Issue short-lived tokens, validate expiry, and rotate refresh tokens. This synthetic recording executes no tools.')
    }
}
$arguments = @{ LibraryRoot = $script:LibraryRoot; NodePath = $script:NodePath; DemoId = $saved.id }
if ($CodePath) { $arguments.CodePath = $CodePath }
$started = & (Join-Path $root 'Start-DemoPlayer.ps1') @arguments
[pscustomobject]@{
    ProcessId = $started.ProcessId
    LibraryRoot = $script:LibraryRoot
    DemoId = $saved.id
    Preview = 'Native C# WPF controller with synthetic recordings. Click Open, then Play. No installation or real library changes.'
} | ConvertTo-Json
