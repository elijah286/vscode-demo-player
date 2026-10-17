param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('New', 'Check', 'List', 'Ready', 'RegisterCaptain')]
    [string]$Action,
    [string]$RepositoryRoot,
    [string]$TaskId,
    [string]$Owner,
    [string]$Scope,
    [string]$BaseRef = 'main',
    [string]$WorktreePath,
    [string[]]$Validation,
    [string[]]$Dependencies = @()
)

$ErrorActionPreference = 'Stop'
if (-not $RepositoryRoot) { $RepositoryRoot = $PSScriptRoot }

function Invoke-WorktreeGit([string[]]$GitArguments, [string]$Directory = $script:repository) {
    $preference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $Directory @GitArguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $preference }
    if ($code -ne 0) { throw ("Git {0} failed ({1}): {2}" -f $GitArguments[0], $code, ($output -join "`n")) }
    return $output -join "`n"
}

function Resolve-WorktreePath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Write-Registration($Record) {
    $temporary = $script:recordPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($script:recordPath)) { [IO.File]::Replace($temporary, $script:recordPath, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $script:recordPath) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Read-Registration {
    if (-not [IO.File]::Exists($script:recordPath)) { throw 'Workstream is not registered. Use New or RegisterCaptain before editing.' }
    $record = Get-Content -LiteralPath $script:recordPath -Raw | ConvertFrom-Json
    if ($record.Version -ne 1 -or $record.TaskId -ne $TaskId) { throw 'Invalid workstream registration; ask the captain to inspect it.' }
    if ($record.Owner -cne $Owner) { throw 'Owner mismatch. Do not take over another session worktree.' }
    return $record
}

function Assert-Worktree($Record, [switch]$RequireCurrent) {
    if ($Record.Status -ne 'Active') { throw ('Workstream is ' + $Record.Status + '; register a new task before further editing.') }
    $path = $Record.Worktree
    if ($RequireCurrent) {
        $current = Resolve-WorktreePath (Invoke-WorktreeGit @('rev-parse', '--show-toplevel') (Get-Location).Path)
        if ($current -ine $path) { throw 'Current working directory is not the assigned worktree. Open the assigned folder before editing.' }
    }
    if ($WorktreePath -and (Resolve-WorktreePath $WorktreePath) -ine $path) { throw 'Worktree path does not match the registration.' }
    $root = Resolve-WorktreePath (Invoke-WorktreeGit @('rev-parse', '--show-toplevel') $path)
    $common = Resolve-WorktreePath (Invoke-WorktreeGit @('rev-parse', '--path-format=absolute', '--git-common-dir') $path)
    if ($root -ine $path -or $common -ine $script:commonDirectory) { throw 'Unexpected worktree root or Git common directory.' }
    $branch = Invoke-WorktreeGit @('branch', '--show-current') $path
    if ($Record.Role -eq 'Captain') {
        if ($root -ine $script:canonical -or ($branch -ne 'main' -and $branch -notmatch '^integration/')) {
            throw 'Captain must use the canonical checkout on main or an integration/* branch.'
        }
    } elseif ($Record.Role -ne 'Feature' -or $root -ieq $script:canonical -or $branch -cne $Record.Branch) {
        throw 'Feature work requires its assigned isolated worktree and branch, never the canonical checkout.'
    }
    $null = Invoke-WorktreeGit @('merge-base', '--is-ancestor', $Record.BaseSHA, 'HEAD') $path
}

$script:repository = Resolve-WorktreePath (Invoke-WorktreeGit @('rev-parse', '--show-toplevel') $RepositoryRoot)
$remote = Invoke-WorktreeGit @('remote', 'get-url', 'origin')
if ($remote -notin @('https://github.com/elijah286/vscode-demo-player.git', 'git@github.com:elijah286/vscode-demo-player.git')) {
    throw 'Unexpected origin. This workflow is only for elijah286/vscode-demo-player.'
}
$script:commonDirectory = Resolve-WorktreePath (Invoke-WorktreeGit @('rev-parse', '--path-format=absolute', '--git-common-dir'))
$script:canonical = Split-Path $script:commonDirectory -Parent
if ((Split-Path $script:commonDirectory -Leaf) -ne '.git') { throw 'Expected the existing canonical checkout Git directory.' }
$registry = Join-Path $script:commonDirectory 'agent-workstreams'
if ($Action -eq 'List') {
    $records = @()
    if (Test-Path -LiteralPath $registry) {
        $records = @(Get-ChildItem -LiteralPath $registry -Filter '*.json' -File | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        })
    }
    ConvertTo-Json -InputObject $records -Depth 8
    return
}
if ($TaskId -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { throw 'TaskId must be a lowercase kebab-case identifier.' }
if ([string]::IsNullOrWhiteSpace($Owner)) { throw 'Owner must identify the agent/session responsible for this task.' }
$script:recordPath = Join-Path $registry ($TaskId + '.json')
if ($Action -eq 'Check') {
    $record = Read-Registration
    Assert-Worktree $record -RequireCurrent
    $record | ConvertTo-Json -Depth 8
    return
}

[IO.Directory]::CreateDirectory($registry) | Out-Null
$lock = $null
try {
    try {
        $lock = [IO.FileStream]::new((Join-Path $registry ($TaskId + '.lock')), [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
    } catch [IO.IOException] { throw 'This workstream is being updated by another process. Do not start a second writer.' }

    if ($Action -eq 'Ready') {
        $record = Read-Registration
        Assert-Worktree $record -RequireCurrent
        if ($record.Role -ne 'Feature') { throw 'Only a feature workstream can produce a Ready handoff.' }
        if (-not $Validation -or @($Validation | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) {
            throw 'Supply exact validation commands and their results, including explicit unperformed checks.'
        }
        if (Invoke-WorktreeGit @('status', '--porcelain=v1', '--untracked-files=all') $record.Worktree) {
            throw 'Ready requires all intended work committed and no untracked or unstaged changes.'
        }
        $head = Invoke-WorktreeGit @('rev-parse', 'HEAD') $record.Worktree
        if ($head -eq $record.BaseSHA) { throw 'Ready requires a delivery commit beyond the assigned base.' }
        $record.Status = 'Ready'
        $record | Add-Member NoteProperty DeliverySHA $head
        $record | Add-Member NoteProperty Validation @($Validation)
        $record | Add-Member NoteProperty ReadyAt ([DateTime]::UtcNow.ToString('o'))
        Write-Registration $record
        $record | ConvertTo-Json -Depth 8
        return
    }

    if ([IO.File]::Exists($script:recordPath)) { throw 'TaskId is already registered. Preserve its handoff and choose a new task ID.' }
    if ($Action -eq 'RegisterCaptain') {
        if ($TaskId -ne 'captain') { throw 'The sole captain registration must use TaskId captain.' }
        $root = Resolve-WorktreePath (Invoke-WorktreeGit @('rev-parse', '--show-toplevel') (Get-Location).Path)
        if ($root -ine $script:canonical) { throw 'Register the captain from the canonical checkout.' }
        $branch = Invoke-WorktreeGit @('branch', '--show-current')
        if ($branch -ne 'main' -and $branch -notmatch '^integration/') { throw 'Captain branch must be main or integration/*.' }
        if (Invoke-WorktreeGit @('status', '--porcelain=v1', '--untracked-files=all')) { throw 'Checkpoint and integrate existing work before registering the captain.' }
        $record = [pscustomobject]@{
            Version = 1; TaskId = $TaskId; Owner = $Owner; Role = 'Captain'; Status = 'Active'
            Worktree = $script:canonical; Branch = $branch
            BaseSHA = (Invoke-WorktreeGit @('rev-parse', 'HEAD')); Scope = 'Integration and release coordination'
            Dependencies = @(); CreatedAt = [DateTime]::UtcNow.ToString('o')
        }
        Write-Registration $record
        $record | ConvertTo-Json -Depth 8
        return
    }

    if ($TaskId -eq 'captain') { throw 'TaskId captain is reserved for RegisterCaptain.' }
    if ([string]::IsNullOrWhiteSpace($Scope)) { throw 'New requires a bounded task Scope.' }
    $base = Invoke-WorktreeGit @('rev-parse', '--verify', '--end-of-options', ($BaseRef + '^{commit}'))
    $null = Invoke-WorktreeGit @('cat-file', '-e', ($base + ':Manage-AgentWorktree.ps1'))
    if (-not $WorktreePath) {
        $WorktreePath = Join-Path (Join-Path (Split-Path $script:canonical -Parent) ((Split-Path $script:canonical -Leaf) + '-worktrees')) $TaskId
    }
    $WorktreePath = Resolve-WorktreePath $WorktreePath
    foreach ($line in (Invoke-WorktreeGit @('worktree', 'list', '--porcelain')) -split "`n") {
        if ($line.StartsWith('worktree ')) {
            $existing = Resolve-WorktreePath $line.Substring(9)
            if ($WorktreePath -ieq $existing -or $WorktreePath.StartsWith($existing + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'New worktrees must be outside every existing working tree.'
            }
        }
    }
    if (Test-Path -LiteralPath $WorktreePath) { throw 'Worktree destination already exists; nothing will be overwritten or deleted.' }
    $record = [pscustomobject]@{
        Version = 1; TaskId = $TaskId; Owner = $Owner; Role = 'Feature'; Status = 'Provisioning'
        Worktree = $WorktreePath; Branch = ('agent/' + $TaskId); BaseSHA = $base; Scope = $Scope
        Dependencies = @($Dependencies); CreatedAt = [DateTime]::UtcNow.ToString('o')
    }
    Write-Registration $record
    try {
        $null = Invoke-WorktreeGit @('worktree', 'add', '--no-track', '-b', $record.Branch, '--', $WorktreePath, $base)
        $record.Status = 'Active'
        Assert-Worktree $record
        Write-Registration $record
    } catch {
        $record.Status = 'Failed'
        $record | Add-Member NoteProperty Failure $_.Exception.Message
        Write-Registration $record
        throw
    }
    $record | ConvertTo-Json -Depth 8
} finally {
    if ($lock) { $lock.Dispose() }
}
