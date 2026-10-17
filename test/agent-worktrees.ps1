param([string]$EvidenceRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) '.build\agent-worktrees'))

$ErrorActionPreference = 'Stop'
$manager = Join-Path (Split-Path $PSScriptRoot -Parent) 'Manage-AgentWorktree.ps1'
$scratch = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('run-' + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $scratch 'canonical fixture'
[IO.Directory]::CreateDirectory($repo) | Out-Null
$assertions = 0

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw ($Label + ': expected ' + $Expected + ', got ' + $Actual) }
    $script:assertions++
}
function Assert-Fails([scriptblock]$Code, [string]$Pattern) {
    try { & $Code | Out-Null; throw 'Expected failure did not occur.' }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        $script:assertions++
    }
}
function Invoke-FixtureGit([string[]]$Arguments) {
    $output = & git -C $repo @Arguments
    if ($LASTEXITCODE) { throw ('Synthetic git fixture failed: ' + $Arguments[0]) }
    return $output
}
function Commit-Fixture([string]$Directory, [string]$File) {
    & git -C $Directory add -- $File
    if ($LASTEXITCODE) { throw 'Fixture staging failed' }
    & git -C $Directory -c user.name=Fixture -c user.email=fixture@example.test commit -qm 'Synthetic test change' -m 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>'
    if ($LASTEXITCODE) { throw 'Fixture commit failed' }
}

$null = Invoke-FixtureGit @('init', '--initial-branch=main')
$null = Invoke-FixtureGit @('remote', 'add', 'origin', 'https://github.com/elijah286/vscode-demo-player.git')
[IO.File]::WriteAllText((Join-Path $repo 'AGENTS.md'), 'Synthetic policy fixture')
[IO.File]::WriteAllText((Join-Path $repo '.gitignore'), "*.local`n")
$null = Invoke-FixtureGit @('add', '--', 'AGENTS.md', '.gitignore')
$null = Invoke-FixtureGit @('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test', 'commit', '-qm', 'Synthetic legacy base', '-m', 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>')
$legacy = Invoke-FixtureGit @('rev-parse', 'HEAD')
[IO.File]::Copy($manager, (Join-Path $repo 'Manage-AgentWorktree.ps1'))
Commit-Fixture $repo 'Manage-AgentWorktree.ps1'
$base = Invoke-FixtureGit @('rev-parse', 'HEAD')
$workers = @()
Push-Location $repo
try {
    $captain = & $manager -RepositoryRoot $repo -Action RegisterCaptain -TaskId captain -Owner fixture-captain | ConvertFrom-Json
    Assert-Equal $captain.Role Captain 'Captain registration'
    Assert-Fails { & $manager -RepositoryRoot $repo -Action RegisterCaptain -TaskId captain -Owner other } 'already registered'
    $null = & $manager -RepositoryRoot $repo -Action Check -TaskId captain -Owner fixture-captain

    foreach ($id in @('alpha', 'beta')) {
        $output = Join-Path $scratch ($id + '.json')
        $process = Start-Process powershell.exe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $repo 'Manage-AgentWorktree.ps1') + '"'),
            '-Action', 'New', '-TaskId', $id,
            '-Owner', ('fixture-' + $id), '-Scope', 'parallel-fixture',
            '-WorktreePath', ('"' + (Join-Path $scratch ($id + ' worktree')) + '"')
        ) -RedirectStandardOutput $output -RedirectStandardError (Join-Path $scratch ($id + '.error')) -PassThru
        $null = $process.Handle
        $workers += $process
    }
    foreach ($process in $workers) {
        if (-not $process.WaitForExit(30000)) {
            Stop-Process -Id $process.Id
            throw 'Concurrent worktree provisioning timed out.'
        }
        Assert-Equal $process.ExitCode 0 'Concurrent worktree provisioning'
    }
    $alpha = Get-Content -LiteralPath (Join-Path $scratch 'alpha.json') -Raw | ConvertFrom-Json
    $beta = Get-Content -LiteralPath (Join-Path $scratch 'beta.json') -Raw | ConvertFrom-Json
    Assert-Equal $alpha.BaseSHA $base 'Alpha fixed base'
    Assert-Equal $beta.BaseSHA $base 'Beta fixed base'
    Assert-Equal (Invoke-FixtureGit @('branch', '--show-current')) main 'Captain branch unchanged'
    Assert-Equal (Invoke-FixtureGit @('status', '--porcelain')) $null 'Captain working tree unchanged'
    Assert-Fails { & $manager -RepositoryRoot $repo -Action Check -TaskId alpha -Owner fixture-alpha -WorktreePath $alpha.Worktree } 'Current working directory'
    Assert-Fails { & $manager -RepositoryRoot $repo -Action New -TaskId alpha -Owner fixture-alpha -Scope again } 'already registered'
    Assert-Fails { & $manager -RepositoryRoot $repo -Action New -TaskId nested -Owner fixture -Scope nested -WorktreePath (Join-Path $repo 'nested') } 'outside every existing'
    Assert-Fails { & $manager -RepositoryRoot $repo -Action New -TaskId occupied -Owner fixture -Scope occupied -WorktreePath $scratch } 'already exists'
    Assert-Fails { & $manager -RepositoryRoot $repo -Action New -TaskId Bad_ID -Owner fixture -Scope invalid } 'kebab-case'
    Assert-Fails { & $manager -RepositoryRoot $repo -Action New -TaskId no-scope -Owner fixture } 'bounded task Scope'
    Assert-Fails { & $manager -RepositoryRoot $repo -Action New -TaskId legacy -Owner fixture -Scope legacy -BaseRef $legacy } 'Git cat-file failed'

    Push-Location $alpha.Worktree
    try {
        $null = & $manager -RepositoryRoot $repo -Action Check -TaskId alpha -Owner fixture-alpha
        Assert-Fails { & $manager -RepositoryRoot $repo -Action Check -TaskId alpha -Owner impostor } 'Owner mismatch'
        Assert-Fails { & $manager -RepositoryRoot $repo -Action Ready -TaskId alpha -Owner fixture-alpha -Validation 'not run' } 'beyond the assigned base'
        [IO.File]::WriteAllText((Join-Path $alpha.Worktree 'change.txt'), 'alpha only')
        [IO.File]::WriteAllText((Join-Path $alpha.Worktree 'private.local'), 'ignored synthetic evidence')
        $null = & $manager -RepositoryRoot $repo -Action Check -TaskId alpha -Owner fixture-alpha
        Assert-Fails { & $manager -RepositoryRoot $repo -Action Ready -TaskId alpha -Owner fixture-alpha -Validation 'not run' } 'requires all intended work committed'
        Commit-Fixture $alpha.Worktree 'change.txt'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $beta.Worktree 'change.txt')) $false 'Working files are isolated'
        Assert-Fails { & $manager -RepositoryRoot $repo -Action Ready -TaskId alpha -Owner fixture-alpha } 'exact validation commands'
        $ready = & $manager -RepositoryRoot $repo -Action Ready -TaskId alpha -Owner fixture-alpha -Validation 'Synthetic assertions => passed; runtime UI => not run' | ConvertFrom-Json
        Assert-Equal $ready.Status Ready 'Ready status'
        Assert-Equal $ready.DeliverySHA (& git -C $alpha.Worktree rev-parse HEAD) 'Immutable delivery SHA'
        Assert-Fails { & $manager -RepositoryRoot $repo -Action Check -TaskId alpha -Owner fixture-alpha } 'register a new task'
    } finally { Pop-Location }

    Push-Location $beta.Worktree
    try {
        & git switch --quiet -c wrong-branch
        if ($LASTEXITCODE) { throw 'Fixture branch switch failed' }
        Assert-Fails { & $manager -RepositoryRoot $repo -Action Check -TaskId beta -Owner fixture-beta } 'assigned isolated worktree and branch'
        & git switch --quiet agent/beta
        if ($LASTEXITCODE) { throw 'Fixture branch restoration failed' }
        [IO.File]::WriteAllText((Join-Path $beta.Worktree 'change.txt'), 'beta uncommitted overlap')
        $null = & $manager -RepositoryRoot $repo -Action Check -TaskId beta -Owner fixture-beta
    } finally { Pop-Location }
    $null = Invoke-FixtureGit @('merge', '--quiet', '--ff-only', $ready.DeliverySHA)
    $null = & $manager -RepositoryRoot $repo -Action Check -TaskId captain -Owner fixture-captain
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $repo 'change.txt'))) 'alpha only' 'Captain integrates the selected immutable delivery'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $beta.Worktree 'change.txt'))) 'beta uncommitted overlap' 'Unrelated feature coding continues through integration'
    Assert-Equal (& git -C $alpha.Worktree rev-parse HEAD) $ready.DeliverySHA 'Delivered worktree stays unchanged'
    $records = & $manager -RepositoryRoot $repo -Action List | ConvertFrom-Json
    Assert-Equal $records.Count 3 'Registry lists captain and both feature tasks'
    $null = Invoke-FixtureGit @('branch', 'agent/blocked', $base)
    Assert-Fails { & $manager -RepositoryRoot $repo -Action New -TaskId blocked -Owner fixture -Scope collision } 'Git worktree failed'
    $failed = Get-Content -LiteralPath (Join-Path $repo '.git\agent-workstreams\blocked.json') -Raw | ConvertFrom-Json
    Assert-Equal $failed.Status Failed 'Provisioning failure is explicit and preserved'
    Assert-Equal (Invoke-FixtureGit @('branch', '--show-current')) main 'Failed provisioning leaves captain branch unchanged'
    $lockPath = Join-Path $repo '.git\agent-workstreams\locked.lock'
    $lock = [IO.FileStream]::new($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)
    try { Assert-Fails { & $manager -RepositoryRoot $repo -Action New -TaskId locked -Owner fixture -Scope collision } 'second writer' }
    finally { $lock.Dispose() }
    $null = Invoke-FixtureGit @('remote', 'set-url', 'origin', 'https://example.test/wrong.git')
    Assert-Fails { & $manager -RepositoryRoot $repo -Action List } 'Unexpected origin'
    Write-Output ('AGENT WORKTREE CHECKS PASSED: ' + $assertions + ' assertions. Synthetic evidence retained at ' + $scratch)
} finally {
    foreach ($process in $workers) {
        if (-not $process.HasExited) { Stop-Process -Id $process.Id }
        $process.Dispose()
    }
    Pop-Location
}
