# Parallel work and release runbook

## Authority and scope

This policy applies to `elijah286/vscode-demo-player`, not the original LabVIEW
workspace. The user appoints one release captain. A user request to add/fix a
feature or integrate the fleet authorizes integration and shipment of that
scope after reasonable targeted checks. The user's production use is functional
acceptance for this personal tool; do not add per-commit approval or exhaustive
environment gates. Publishing a new release does not authorize silently installing it on a
user's computer; preserve the updater's consent behavior.

The captain is an on-demand role. Between user requests, remain idle: no
session polling, background listeners, watchers, or automatic integrations.
Workstream handoffs and queued reports alone do not authorize a new work cycle.
When asked to pause, preserve the current candidate and stop at a safe boundary;
resume only on the user's instruction.

Repository instructions guide agents but are not access control. They become
the shared baseline only when merged. Until then, the captain must send the
policy directly to active agents. Older worktrees must read the current policy.
Agents in other VS Code windows or machines are not necessarily discoverable:
they must register with the captain before writing.

## Start an isolated workstream

From a known repository, inspect `git status --short --branch` and
`git worktree list --porcelain` without altering existing work. Fetch the
approved remote baseline, then create a unique branch and sibling worktree:

```powershell
git fetch origin
git worktree add -b agent/<task> ..\vscode-demo-player-<task> origin/main
```

Replace `<task>` with a unique task name. Run all subsequent commands in that
new worktree. Tell the captain its absolute path, branch, base SHA, intended
files, dependencies, and test plan before implementation. A separate branch
inside the same checkout is not isolation. Do not copy uncommitted shared
changes into it without an agreed file-by-file attribution.

Overlapping file ownership must be declared, especially the controller,
README, manifests/lockfiles, packaging allowlist, and release workflow. Agents
can change overlapping files in isolated worktrees, but the captain determines
integration order and resolves conflicts with their owners. Feature agents
must not edit each other's worktrees or the captain's worktree.

Use unique temporary libraries, control ports, profiles, build caches, output
paths, and evidence directories. Coordinate interactive desktop tests and
installation tests: worktrees do not isolate the shared desktop or installed
application. Never kill unrelated VS Code sessions or overwrite a user's demo
library.

## Recover the currently shared checkout

1. Ask all writers to pause at a safe boundary and acknowledge the pause.
2. Record branch, HEAD, tracked diff, untracked file names, and each owner's
   attribution. Preserve a recovery copy outside the repository before moving
   anything; private source/evidence must not be uploaded.
3. Have each owner identify its exact changes, including overlapping files.
   Assign mixed hunks explicitly. Do not use `git add .`, reset, clean, stash,
   or a whole-file copy as a shortcut.
4. Reproduce only the attributed changes in the owner's isolated worktree,
   include dependencies explicitly, test, and commit only those files.
5. Compare the preserved shared changes against all delivered commits before
   declaring migration complete. Leave the original checkout intact until the
   user authorizes its cleanup.

A missing feature is an investigation item, not permission to reimplement or
delete newer code. Locate its originating session, commit, branch, or
uncommitted source; establish the expected behavior, then add a regression
test. Track the reported Editor/Agents mode toggle this way.

## Handoff and integration queue

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

The captain identifies the branches/commits covered by the user's request and
integrates serially in a clean captain-owned integration worktree.
Merge the delivered branch (or cherry-pick the explicitly agreed commits, not
both). Resolve conflicts with the owners; do not blindly prefer either side.
Rerun targeted checks on the combined result, including tests from each included
workstream. Unrelated scope still requires a user request.

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
4. Push the verified approved integration to `main` through the protected
   integration path. After its required CI passes, the captain creates and
   pushes `v<version>` at that same current `main` SHA, never at a feature SHA.
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

If any gate fails, stop publication and preserve evidence. Fix on a new
isolated branch and obtain approval for any scope change. Never force-move a
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
