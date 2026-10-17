# Canonical development and release runbook

## Authority and scope

This policy applies only to `elijah286/vscode-demo-player`. Parallel development
uses one registered Git worktree per feature task/owner. The existing canonical
`vscode-demo-player` checkout is exclusively the release captain's workspace.
This supersedes the former sequential-feature/single-checkout policy.
Feature or consolidation approval authorizes only the agreed local work.
Pushing, merging GitHub pull requests, publishing/tagging, deleting recovery
sources, and modifying the installed app each require explicit approval.
Never interpret a feature request as automatic shipment or installation consent.

The captain is an on-demand role. Between user requests, remain idle: no
session polling, background listeners, watchers, or automatic integrations.
Workstream handoffs and queued reports alone do not authorize a new work cycle.
When asked to pause, preserve the current candidate and stop at a safe boundary;
resume only on the user's instruction.

Repository instructions guide agents but are not access control. The root
AGENTS.md is the always-on entry point; this runbook and the worktree helper
provide the detailed contract. New requires a committed base containing the
helper, so do not start from a pre-policy base. Running sessions and old
worktrees do not automatically reload new instructions. The captain must send
them the current policy and obtain acknowledgment before their next edits.
Agents in other VS Code windows or machines are not necessarily discoverable:
they must register with the captain before writing.

## Start parallel work

Use `Manage-AgentWorktree.ps1` from a policy-bearing checkout. This project
authorizes new registered feature worktrees under the canonical checkout's
sibling `vscode-demo-player-worktrees` directory. Do not clone the repository,
repurpose recovery folders, or create ad hoc unregistered worktrees.

The captain assigns a unique lowercase kebab-case task ID, owner/session,
bounded scope, dependencies, likely overlaps, and committed base (normally local
`main`, or an explicitly approved prerequisite delivery SHA). Each feature task
gets a distinct `agent/<task-id>` branch. Task creation reserves its registration
under the shared Git directory, uses a per-task exclusive provisioning lock, and
creates the worktree from the resolved immutable base. Different task IDs can
be provisioned concurrently. No dirty files or dependencies are copied.

```powershell
# Run once by the captain, from the clean canonical checkout.
.\Manage-AgentWorktree.ps1 -Action RegisterCaptain -TaskId captain -Owner captain-session

# New feature task, from a checkout of this repository.
.\Manage-AgentWorktree.ps1 -Action New -TaskId playback-example -Owner feature-session -Scope 'Implement the approved playback change' -BaseRef main
Set-Location "$env:USERPROFILE\Documents\GitHub\vscode-demo-player-worktrees\playback-example"
.\Manage-AgentWorktree.ps1 -Action Check -TaskId playback-example -Owner feature-session
code .
```

Start/rebind the actual agent session to that folder before editing. A different
branch in the same directory, or changing only a command's directory, is not
isolation. Check verifies the actual current Git root, assigned branch/owner,
shared Git identity and base ancestry. Run it before edits/commits and after
interruptions. It permits that owner's in-progress changes; it cannot determine
who typed an individual hunk. Stop for unexplained edits or any mismatch.

Only the registered captain may write or switch branches in the canonical
checkout. Its branch must be `main` or `integration/*`. Captain sessions must
also run Check before writes. There is only one `captain` registration. The
captain may not secretly take over a feature worktree. A new session taking over
an abandoned registration requires an explicit owner/captain handoff; the helper
does not steal leases, expire records, or delete/reuse worktrees automatically.

List records with `.\Manage-AgentWorktree.ps1 -Action List`. Registrations include
owner, task, scope, base SHA, path, dependencies and status. They live privately
under `.git\agent-workstreams`, not in committed machine-specific files; JSON
updates are atomic. Provisioning failures remain visibly Failed with their
details and any partial branch/worktree preserved for explicit recovery.

Install locked dependencies within each worktree; do not borrow another
project's junction. Source changes/tests/builds run independently. File overlaps
are allowed and recorded; ownership is over a workstream's changes, not a global
file lock. Serialize only actual task dependencies or coordinated conflict fixes.

Use unique temporary libraries, control ports, profiles, build caches, output
paths, and evidence directories. Coordinate interactive desktop tests and
installation test slots only: worktrees do not isolate the shared desktop or installed
application. Never kill unrelated VS Code sessions or overwrite a user's demo
library. Those slots must not pause other agents' coding.

## Recover the currently shared checkout

1. Only for legacy mixed-checkout recovery, ask the affected writers to finish
   or pause at a safe boundary and acknowledge that they are no longer writing.
   Routine feature completion/integration does not require a global pause.
2. Record branch, HEAD, tracked diff, untracked file names, and each owner's
   attribution. Preserve a recovery copy outside the repository before moving
   anything; private source/evidence must not be uploaded.
3. Have each owner identify its exact changes, including overlapping files.
   Assign mixed hunks explicitly. Do not use `git add .`, reset, clean, stash,
   or a whole-file copy as a shortcut.
4. Integrate only attributed changes into the approved canonical branch,
   include dependencies explicitly, test, and commit only those files.
5. Compare the preserved shared changes against all delivered commits before
   declaring migration complete. Leave the original checkout intact until the
   user authorizes its cleanup.

A missing feature is an investigation item, not permission to reimplement or
delete newer code. Locate its originating session, commit, branch, or
uncommitted source; establish the expected behavior, then add a regression
test. Track the reported Editor/Agents mode toggle this way.

## Handoff and integration queue

Feature agents commit only their attributed changes and use Check again before
committing. Before handoff, finish validation in their own worktree, commit all
intended files, and declare the workstream Ready:

```powershell
.\Manage-AgentWorktree.ps1 -Action Ready -TaskId playback-example -Owner feature-session -Validation 'npm run test:unit => passed; npm run lint => passed; native UI => not run'
```

Ready refuses dirty/untracked content, unchanged base-only work, wrong owners,
paths, branches or ancestry, and missing validation evidence. It records the
exact committed delivery SHA plus commands/results. Evidence is an agent's
attestation, not proof that a command ran. A Ready branch/worktree remains
preserved; use New for the next task. Check refuses further editing of Ready
workstreams. Never amend/rebase a delivered commit behind the captain's back.

Validate the workflow with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test\agent-worktrees.ps1
```

This uses a disposable synthetic repository, concurrently provisions two
worktrees, checks ownership/branch/path/commit guards, and integrates one
delivery while the other worktree has overlapping uncommitted changes.
It never changes real registrations or dependencies. Evidence remains in the
ignored `.build\agent-worktrees` directory. Both CI workflows run this check.
The helper/tests are development tooling, not installer payload files.

Use [the pull request template](../.github/pull_request_template.md) for each
handoff, even when reporting locally before opening a PR. The captain maintains
the queue in PRs or the coordination session, with:

- Workstream, owner/session, worktree, branch, base and delivery SHAs.
- Owned/overlapping files, dependencies and integration order.
- Tests and evidence, risks, conflicts and unresolved acceptance criteria.
- State: active, blocked, ready, approved, integrated, verified, or released.
- Exact user approval, integrated SHA, and eventual tag/run/release URL.

Never mark a workstream integrated from a verbal completion report. Verify its
changes in Git. Do not mark it released until the published installer actually
contains it.

Only the captain updates the queue; agents submit handoffs/messages/approved
PRs, not competing edits to a shared tracking file. The registry is local
coordination state, not a durable cross-machine queue or release database.

For a user-authorized integration/release cycle the captain freezes a batch ID
and an explicit list of task IDs, base/delivery SHAs, dependencies and approval
scope. Other agents continue coding in independent worktrees. Later deliveries
wait for a later batch rather than entering the current candidate implicitly.
The captain verifies each delivery in Git, then integrates serially on an
`integration/<batch>` branch in the canonical checkout.
Merge the selected immutable delivery SHA (or cherry-pick the explicitly agreed commits, not
both). Resolve conflicts with the owners; do not blindly prefer either side.
Rerun targeted checks on the combined result, including tests from each included
workstream. Integrate the verified result into local main only when authorized.
Feature agents never merge main, bump release versions, tag or publish.
Unrelated scope still requires a user request.

Conflicts go back to the relevant owners as follow-up committed tasks (or are
resolved by the captain with owner agreement). Do not overwrite whole files,
pull in newer feature-branch tips, or pause unrelated agents. Rebuild/retest the
candidate after any selected fix; record the new fixed SHA.

## Reasonable integration checks

The `Windows checks` CI job runs the existing automated baseline on PRs and
`main`: unit tests, lint, and PowerShell packaging/syntax/dependency checks.
It does not claim native UI, installer, or update acceptance.

For the exact integrated SHA, choose checks relevant to the change:

1. Verify all new regression tests are actually selected by the test commands.
   A test file existing on disk does not mean it ran.
2. Run the applicable native playback and Windows controller UI harnesses from
   the README on an interactive desktop using synthetic recordings.
3. When a mode-toggle workstream is included, check both directions, retained
   behavior after restart if specified, and playback in both supported modes.
   Until a UI toggle is delivered, track its absence explicitly rather than
   claiming it shipped. Experimental mode limitations must remain explicit;
   do not silently remove its guard.
4. Verify the packaging allowlist includes every new runtime dependency/file.
5. For updater changes, run updater unit/UI checks and test the installed old
   version upgrading to the candidate with preserved library/settings,
   consent, cancellation and visible failure behavior.

Record exact commands, SHA, environment/version, results and evidence location.
A stale screenshot or an earlier branch's green tests are not a fresh test of
the integrated result. Fix relevant failures. An unavailable exhaustive test
environment does not block this personal-tool release; record what actually
ran in the handoff without claiming unperformed tests passed.

## Release and update delivery

1. Freeze the approved integration candidate. Only the captain sets a new,
   unused stable three-part version in the manifest and matching lockfile.
   This release bookkeeping is within approved scope; unrelated changes are not.
2. Run the required checks above for the final versioned SHA. Build with
   `packaging\Build-Windows.ps1` in an isolated output/cache location.
3. Run the README's installer and installed controller/native tests on a
   coordinated test installation. Do not replace a user's existing app just
   to make a harness pass. Record unavailable environments as blockers.
4. Only with explicit push approval, push the verified integration through the protected
   integration path. After its required CI passes, the captain creates and
   pushes `v<version>` only with explicit publishing approval at that same current
   `main` SHA, never at a feature SHA.
5. The tag workflow verifies the tag is current `main`, verifies version
   agreement, runs tests, builds the installer, and publishes it with its
   checksum. Releases are serialized. Manual workflow dispatch builds only;
   it does not publish.
6. Verify the successful workflow's SHA, release tag, public stable metadata,
   `VSCodeDemoPlayer-Setup.exe`, `SHA256SUMS.txt`, asset digest, and downloaded
   checksum. Verify the updater discovers that release and displays the
   expected installed/latest versions. Test upgrade from the previous
   updater-enabled installation before declaring delivery complete.
7. Record which workstream SHAs shipped in release notes and the handoff queue.
   Announce separately what was integrated, built, published, and installed.

The existing updater workstream owns the detailed API/validation contract.
Coordinate changes with it: stable release metadata, asset names, version
comparison, integrity validation, packaged helper files, and consent must agree.
Version 0.1.0 has no updater; it requires a one-time installer bootstrap.
Do not claim old installations update themselves until the shipped updater
and actual upgrade path have passed acceptance.

If any gate fails, stop publication and preserve evidence. Assign an isolated
fix workstream, integrate its selected delivery through the captain, and obtain
approval for any scope change. Never force-move a
released tag, replace an existing version's assets, or downgrade clients.
Use a new version for an approved fix or revert.

## Hosting enforcement checklist

A repository administrator must configure and verify these settings; merely
committing this document does not enable them:

- Protect `main`: require PRs, approval by the designated human/captain
  integration path, the up-to-date `Windows checks` status, and resolved review
  threads. Disable force pushes/deletion and restrict bypass access.
- Restrict creation/update/deletion of `v*` tags to the release identity.
  Feature agents must not share unrestricted release credentials.
- Serialize integration and publishing through the captain. The workflow's
  concurrency group prevents simultaneous runs, but is not an approval gate or
  a durable FIFO queue. Wait for a release to finish before starting another.
- Keep required checks/rules enabled for administrators where supported.
  Record any plan, permission, or ruleset limitations as unenforced risks.

The current release workflow does not prove human approval, native UI
acceptance, or installed upgrade acceptance. Those remain captain gates unless
separately automated and verified. Do not describe policy text as a security
boundary or claim branch/tag protection without checking the hosting settings.
