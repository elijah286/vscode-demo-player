# Parallel development and release ownership

- The release captain is on demand, not a continuous monitor. Do not poll
  sessions, run watchers, or start integration/release work without a user
  request. A workstream handoff is evidence, not a command to resume. Record
  completion in the workstream/PR; do not repeatedly wake the captain.
- Each implementation agent works on its own named branch in its own Git
  worktree. Before writing, report the absolute worktree path, branch, base
  commit, task scope, and overlapping files to the release captain.
- Never edit a checkout another agent is using, including the shared `main`
  checkout. Worktrees isolate files, not ports, installed apps, demo libraries,
  or output directories: give tests and builds separate resources too.
- Preserve existing edits. Never reset, clean, stash, switch branches, migrate
  mixed changes, or stage another agent's files to make a checkout usable.
  Stop and coordinate ownership when an existing checkout is dirty.
- Only the release captain integrates into `main`, changes release versions,
  creates release tags, publishes releases, or runs installation/update tests
  that modify the shared installed app. Feature agents do not do these things.
- The release captain does not implement product features or bug fixes. If the
  user asks the captain for development, dispatch it to an implementation agent
  in a separate named branch/worktree, even for a small fix. Give the agent a
  bounded scope, owned files, acceptance criteria, and handoff requirements.
  Product-code fixes found during integration or release checks also go to an
  implementation agent; the captain must not take them over as a shortcut.
- The captain owns coordination, review, integration/conflict resolution,
  combined validation, release policies/metadata, installer builds, publication,
  and consented installation checks. Delegation does not transfer those release
  responsibilities to feature agents.
- A user request to add/fix features or integrate the fleet authorizes the captain
  to delegate implementation, integrate that scope, run reasonable targeted
  checks, and ship the update.
  Do not request separate approval for every commit or exhaustive acceptance.
  A handoff alone is not a request to wake the idle captain.
- Fix failed checks relevant to the change before shipping. Use the user's
  production use as functional acceptance; do not block this personal tool on
  unavailable exhaustive environments or add routine release disclaimers.
- Commit only owned changes with explicit file paths; include tests and relevant
  documentation. Deliver the commit SHA, base SHA, changed files, exact test
  commands/results, remaining risks, and dependencies using the PR template.
  "Done" means ready for integration, not merged, built, installed, or released.
- Keep recordings, private transcripts, credentials, generated test evidence,
  build outputs, and machine-specific paths out of commits and release payloads.
- Follow [the integration and release runbook](docs/RELEASING.md). Read this file
  from the current integration branch when starting a new workstream.
