# Parallel worktrees and release ownership

- This project is `https://github.com/elijah286/vscode-demo-player.git`.
  The canonical `%USERPROFILE%\Documents\GitHub\vscode-demo-player` checkout
  belongs exclusively to the registered release captain. `main` tracks
  `origin/main`. Feature agents must never edit or switch branches there.
- Parallel feature development is authorized by default in separate registered
  Git worktrees of this repository, one owner/session and task per worktree.
  This replaces the former single-checkout/sequential-feature policy.
  Do not create independent clones or reuse legacy recovery folders.
- Before editing, read [the runbook](docs/RELEASING.md), obtain a task ID,
  owner/session, scope, dependencies and committed base SHA. Use
  `Manage-AgentWorktree.ps1 -Action New` to provision a feature worktree.
  Open that exact folder in the agent's VS Code session; a different branch
  or a shell-only directory change is not session isolation.
- Run `Manage-AgentWorktree.ps1 -Action Check -TaskId <id> -Owner <session>`
  from the assigned worktree before edits, commits, and after interruptions.
  Confirm Git root, sanitized origin, branch, common directory and registration.
  Stop on ownership/path/branch mismatch or unexpected changes. Never take over
  another worktree or switch its branch to unblock yourself.
- Feature agents commit only their attributed changes, validate them, and use
  `-Action Ready` with exact commands/results for a fixed delivery SHA.
  Use [the handoff template](.github/pull_request_template.md). The captain alone
  maintains the integration/release queue. Ready is not integrated or released.
  Start the next task in a newly registered worktree; preserve the delivered one.
- Other agents keep coding while the captain integrates selected immutable SHAs
  serially in the canonical checkout. Freeze a release batch, not all agents.
  Resolve dependencies/conflicting hunks with their owners; no directory overlays,
  mixed uncommitted transfers, or copying Git metadata between checkouts.
- Preserve all existing work. Never reset, clean, stash, discard or migrate mixed
  changes to obtain a usable checkout. Agree on a private checkpoint including
  staged, unstaged, untracked and ignored user files before recovery/migration.
  Pause only affected writers for that exceptional operation, not routine work.
- Ask separately before deleting folders, worktrees, branches, stashes, backups
  or remote branches. Show exact paths and preservation evidence. Use Git to
  remove approved registered worktrees; never force-remove a dirty worktree.
- Only the captain handles integration, versioning and release preparation.
  Pushing, merging GitHub PRs, tagging, publishing and replacing the installed app
  each require explicit approval. Feature/integration approval is not shipping
  approval. Do not silently enable watchers or process queued work without a
  user-authorized cycle/batch.
- Keep private recordings, transcripts, credentials, machine paths, generated
  evidence and build outputs out of commits and releases. Install dependencies
  within each worktree; never borrow another project's dependency junction.
  Use separate synthetic libraries, profiles, ports and output/cache directories.
- Unit tests/builds may run concurrently. Coordinate only shared interactive
  desktop/installer test slots, not other agents' coding. Do not alter the real
  library, unrelated editor sessions, LabVIEW projects, global settings or MCP.
- Report exact validation commands/results, base/delivery/integrated SHAs,
  dependencies, exclusions and risks. Distinguish static checks, fresh runtime
  acceptance, local integration, publication and installation.
- Older/running sessions do not automatically reload policy. The captain sends
  them the current instructions and obtains acknowledgment before their next
  edits. Registry/preflight checks guide cooperating agents; they are not a
  security boundary or automatic interception of every editor/tool action.
