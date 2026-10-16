# Canonical checkout and release ownership

- Work in the existing `vscode-demo-player` checkout by default. Its repository
  is `https://github.com/elijah286/vscode-demo-player.git`; `main` tracks
  `origin/main`. See the README for the canonical location and commands.
- Before edits, confirm the working directory, `git rev-parse --show-toplevel`,
  `git status --short --branch`, remote identity (redact credentials), and branch.
  Stop on an unexpected root, remote, or unowned changes.
- Use branches in this checkout for sequential feature work. Coordinate one
  writer at a time before changing branches. Do not create sibling clones or
  worktrees without explicit user approval, including as a dirty-tree workaround.
- Preserve existing work. Never reset, clean, stash, discard changes, or migrate
  mixed changes to make a checkout usable. Agree on a private backup/checkpoint
  plan that includes staged, unstaged, untracked, and ignored user files first.
- Legacy sibling worktrees are recovery sources, not development defaults.
  Verify ancestry and patch equivalence before integration; do not overlay
  directories or copy Git metadata between checkouts.
- Ask separately before deleting folders, branches, stashes, backups, or remote
  branches. Show exact paths and preservation evidence first. Remove approved
  registered worktrees with Git, never force-remove a dirty worktree.
- Do not push, merge GitHub pull requests, create release tags, publish, or
  replace the installed app without explicit approval for that operation.
  Feature/integration approval alone does not authorize shipping.
- Keep recordings, private transcripts, credentials, machine-specific paths,
  generated evidence, build outputs, and temporary helpers out of commits and
  release payloads. Use ignored output directories or an external temporary
  directory. Never borrow dependencies through another project's junction.
- Use synthetic libraries, isolated profiles, and separate ports/output paths
  for tests. Do not change the real demo library, unrelated VS Code sessions,
  LabVIEW projects, global settings, or MCP configuration.
- Test the combined application with existing tooling. Report exact commands,
  results, commit/base SHAs, dependencies, exclusions, and remaining risks;
  distinguish static checks from fresh runtime acceptance.
- Work only on demand. Do not poll other sessions, run background coordination
  watchers, or treat another agent's handoff as permission to integrate/release.
- Follow [the integration and release runbook](docs/RELEASING.md). These
  instructions guide agents; they are not a security boundary.
