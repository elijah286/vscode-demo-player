# VS Code Demo Player

**[Download the Windows installer - v0.2.27](https://github.com/elijah286/vscode-demo-player/releases/download/v0.2.27/VSCodeDemoPlayer-Setup.exe)** |
[Releases and SHA-256 checksums](https://github.com/elijah286/vscode-demo-player/releases/latest)

## Install and launch

1. Download and run **VSCodeDemoPlayer-Setup.exe**. This is a per-user install;
   administrator access is not required.
2. Open **VS Code Demo Player** from the Windows Start menu.
3. Click **Find interaction...**, find a local agent conversation, load it,
   select exchanges, and review the preview. Optionally summarize long prompts,
   then click **Use selected exchanges**. Previous selections are in the same
   picker's **Saved selections** tab; import is under **Selection actions**.
4. Press **Open** to prepare its isolated VS Code target.
   Once ready, press **Play** to start the first recorded exchange.

To pin the installed app, launch **VS Code Demo Player**, right-click its
taskbar icon, then choose **Pin to taskbar**. Windows does not allow setup to
silently pin apps; setup only shows these instructions and retains its optional
launch checkbox. Silent installs do not launch the app. The installed controller
uses its own stable Windows app identity and relaunches **VSCodeDemoPlayer.exe**,
not PowerShell, retaining the library and explicit runtime/editor paths.
If an older version was pinned as PowerShell, unpin that old shortcut yourself
and pin the newly launched Demo Player instead. Setup never changes existing pins.
Source-run controllers keep their normal PowerShell identity.
Taskbar relaunch uses the last successful installed launch's paths, stored in
`%LOCALAPPDATA%\VSCodeDemoPlayer\taskbar-relaunch.json` to stay within Windows'
taskbar command-length limit. Ordinary Start menu launches still use the default
library (or their explicit arguments), not this profile. Missing or invalid
profiles produce a startup error; launching normally recreates the profile.

Requires x64 Windows 10/11 and compatible desktop VS Code 1.140 or later.
Node.js is bundled: no npm, PowerShell commands, or repository checkout are
needed to use the installed app. Install VS Code separately from
https://code.visualstudio.com/ if it is not already available. Standard user
and system-wide installations are detected. Proposed APIs make compatibility
version-sensitive; a newer VS Code build is not automatically certified.

The repository and installer releases are public; no GitHub sign-in is needed.
The initial installer is unsigned; Windows may show an unknown-publisher
warning. Follow your organization's software policy.

Upgrade by running the newer installer after closing Demo Player. Uninstall
through Windows **Installed apps** or its Start menu uninstaller. Neither
operation deletes your demo library at
`%LOCALAPPDATA%\VSCodeDemoPlayer\demos`, nor changes your normal VS Code
profile. Recordings and private conversation data are not shipped.

Local recorded-conversation playback in an isolated, native VS Code window,
with a compact Windows Play/Pause/Stop controller.

This repository isolates the reusable playback tooling from its
original application project. It contains no original conversations, demo
selections, application source, recorded assets, or generated evidence.
The original workspace remains untouched.

## Parallel development and the canonical checkout

Use the existing `%USERPROFILE%\Documents\GitHub\vscode-demo-player` folder,
connected to `https://github.com/elijah286/vscode-demo-player.git`. Open it with
**File > Open Folder** or `code .` from that folder for release-captain work.
`main` tracks `origin/main`. The canonical checkout is captain-only; each feature
agent uses a separate registered Git worktree, branch and VS Code session.
Separate branches in one directory do not isolate agents. Legacy siblings remain
recovery sources, not alternate defaults; independent clones require approval.

Before editing, verify the Git root, branch/status, upstream, and sanitized
origin. Read
[AGENTS.md](AGENTS.md) and [the workflow runbook](docs/RELEASING.md).
Use the launcher below and run its Check action in the assigned worktree before
editing/committing. The captain integrates committed delivery SHAs while other
agents continue coding; only the selected release batch is frozen.
Consolidation is not permission to delete recovery sources, push, or publish.
The [consolidation checkpoint](docs/CONSOLIDATION.md) records integrated commits,
preservation, test results, exclusions, and remaining gates.

For feature work, provision an isolated folder from a committed policy-bearing
base (replace the example ID, owner/session and scope with the assigned task):

```powershell
Set-Location "$env:USERPROFILE\Documents\GitHub\vscode-demo-player"
.\Manage-AgentWorktree.ps1 -Action New -TaskId example-feature -Owner my-session -Scope 'Implement the assigned feature'
Set-Location "$env:USERPROFILE\Documents\GitHub\vscode-demo-player-worktrees\example-feature"
.\Manage-AgentWorktree.ps1 -Action Check -TaskId example-feature -Owner my-session
code .
```

Start the agent in that exact folder. New does not copy dirty files or
dependencies, change the captain's branch, install packages, push, or delete
anything. Registration lives privately in the shared Git directory, not in
committed machine-specific files. See the runbook for captain registration,
Ready handoffs, overlapping files, and recovery of pre-policy work.

For source development, install Node.js 22.23.3 with npm. In the assigned worktree:

```powershell
Set-Location native
npm ci
npm run test:unit
npm run lint
Set-Location ..
.\Start-DemoPlayer.ps1 -NodePath (Get-Command node.exe).Source
```

Install dependencies separately in each worktree; never borrow another project's
`node_modules` through a junction. Keep recordings/settings, generated evidence,
and temporary helpers outside tracked application source. Use synthetic libraries
and isolated profiles for the validation commands below, not the real demo library.

**Open** never starts playback. While the target prepares, playback remains
disabled; failures and readiness timeouts are reported. After each exchange,
**Start Over** restarts the entire selected demo, **Next Step** plays the next
prompt/response exchange, and **Stop** closes only the paired target. Next Step
is disabled after the final exchange. Closing the target returns the controller
to Open. The extension's separate keyboard **Step** command still advances one
timed event; it is not the controller's Next Step.

## Application updates

The installed app checks the latest stable GitHub release at startup. Click
**Check for updates** to see **Installed version** and **Latest available
version**, retry a check, or install a newer release. Checks run in the
background and do not interrupt playback. A startup check never installs
anything automatically.

**Install update...** asks for confirmation. After consent, the app downloads
the installer from this repository, checks its size and SHA-256 against both
the checksum file and GitHub's asset digest, and stops only its own playback.
An external helper waits for Demo Player to exit, verifies the installer again,
runs the per-user installer, checks the installed version, and restarts the app.
The demo library and explicit library/VS Code paths are preserved. Closing the
update dialog during download cancels it without changing the installation.

No GitHub credentials are stored. No recordings or conversation data are sent
to GitHub; checks request only public release metadata and assets. GitHub can
observe the normal network request metadata, such as the client IP address.
Only stable three-part versions are supported; equal/older versions,
prereleases, drafts, unrelated URLs, and incomplete releases are refused.
The installer remains unsigned: SHA-256 verifies release integrity, not an
independent publisher identity or protection against repository compromise.

Metadata requests have a 15-second network limit; installer downloads have a
120-second limit. The UI caps each whole check at 30 seconds and each download
operation at 180 seconds, with no retries. The installer helper waits at most
30 seconds for app exit and five minutes for installation; it does not kill
the installer or unrelated editor processes. Errors are displayed in the update
window/footer and saved to `%LOCALAPPDATA%\VSCodeDemoPlayer\last-update-error.log`.
Update handoff results and installer logs remain under
`%LOCALAPPDATA%\VSCodeDemoPlayer\updates`; successful installer binaries are
removed after installation.

**One-time bootstrap:** version 0.1.0 has no updater. Install the latest download
once to get this feature; subsequent releases can be installed from inside the
app. Source checkouts can check versions but cannot replace themselves.

Updater source/UI acceptance uses an isolated synthetic application fixture,
without installing anything or touching the shared installed app:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\updater-source-ui.ps1 -NodePath 'C:\Tools\node\node.exe' -EvidenceRoot .\.build\updater-ui -ExpectedLatestVersion '0.1.0'
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\updater-source-ui.ps1 -NodePath 'C:\Tools\node\node.exe' -EvidenceRoot .\.build\updater-ui -ExpectedLatestVersion '9.9.9' -Scenario AvailableUpdate
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\updater-source-ui.ps1 -NodePath 'C:\Tools\node\node.exe' -EvidenceRoot .\.build\updater-ui -ExpectedLatestVersion '0.2.1' -Scenario CheckFailure
```

For the first command, replace `ExpectedLatestVersion` with the current public
stable release. The live scenario exercises the real GitHub check. The other
scenarios replace only the disposable fixture's update helper with synthetic
metadata/slow-download/offline responses, exercising declined consent,
cancellation, cleanup, and visible errors. They never execute an installer.
The available-update fixture uses the supplied expected version, which must be
newer than the application version; it is not tied to a particular release.
Canceled-download cleanup uses Node directly, including for directory paths
that exceed Windows PowerShell's legacy path-length limit.
Owned update windows are found beneath their controller in the Windows UI
Automation tree, not assumed to be direct desktop children.

The release captain must additionally run the real installed upgrade test:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\updater-ui.ps1 -ExpectedCurrentVersion '0.2.0' -ExpectedLatestVersion '0.2.1' -EvidenceRoot .\.build\upgrade-acceptance -InstallUpdate
```

This last test requires the expected newer stable release to be published and
explicit permission to update the installed app. It tests declined consent,
confirmed installation during paused synthetic playback, automatic restart,
and preserved library bytes. Source/UI fixture success is not installed-upgrade
acceptance; the pre-updater 0.1.0 release always needs a manual bootstrap.

The earlier updater-dialog acceptance timeout was a UI test lookup bug, not a
missing dialog: owned WPF windows must be searched as descendants. A disposable,
read-only copy of the existing local 0.2.0 application's sources passed startup
and manual public-GitHub checks with that correction; it does not require
bootstrap for this dialog issue. The actual 0.2.0-to-new-release installation
still requires the captain's installed-upgrade gate.

Updater branch validation covers numeric versions, stable-release/asset/URL
validation, rate-limit/offline/malformed responses, digest/size/corrupt/truncated
downloads, interrupted-stream cleanup, source UI version display, declined
consent, confirmed-download cancellation, and visible check failures.
Cancellation cleanup uses a five-second helper limit (plus two-second exit/output
limits) so Windows PowerShell's legacy long-path deletion does not leave partial
downloads silently. UI fixtures keep their logs/downloads and synthetic libraries
in their explicit evidence directory, not the real user library.

## Current scope

- Native VS Code transcript loading, including saved JSONL updates.
- Contiguous exchange selection and local cross-session playlists.
- Fixed presentation timing: two-second prompt entry and five-second output.
- Explicit advancement between exchanges, pause/resume, and stop.
- An authenticated loopback control channel and separate Windows popup.
- Recorded tool displays only: no model requests or actual tool execution.

- Standalone Demo Player, custom searchable library, capture, and package import/export.
- Persistent rename/delete operations; original conversation storage is never edited.
- Deterministic capture from reviewed native transcripts, not model-authored exports.

## Requirements for running from source

- Windows PowerShell 5.1 with WPF.
- A compatible desktop VS Code user or system installation.
- Node.js 22.16 or newer and npm.
- Access to a saved native VS Code chat transcript.

The extension uses proposed VS Code APIs. Its declared minimum is VS Code
1.140; compatibility with each installed build requires a native test.
Agents mode is experimental and retains its existing integration guard.
Use Editor mode for the baseline player.

## Setup and playback

These commands are for source development. Installed users use the Start menu.

```powershell
Set-Location .\native
npm ci
Set-Location ..
.\Start-DemoPlayer.ps1
```

The controller opens without a project or selected recording. **Capture
Conversation** automatically discovers local history and displays a sortable
table: conversation title, project/workspace, agent/producer, last activity,
start time, prompt count, duration, source and status. No project-directory
selection is required. Project means the recorded workspace association, not a
guess based on which repository was discussed or edited. Multi-root workspaces
show their saved workspace name; empty-window sessions show **No workspace**.

Discovery probes known VS Code and Insiders workspace/profile stores,
empty-window chat stores, newer agent-session databases, and the current user's
Copilot SDK/CLI session-state directory. Agent databases are opened read-only
and their SDK recording links are followed. The same recording is listed once,
even when found through multiple sources. Nothing recursively crawls the drive.
**Add history location...** adds a VS Code user-data/profile root,
workspaceStorage, agentSessionData, SDK session-state, or a directory of JSONL
transcripts for the current dialog. **Browse transcript...** and manual JSONL
paths remain available.

Search filters titles, project names/paths, agents and sources without rescanning.
Project, agent, source, status, inclusive activity-date filters, minimum prompt
count and minimum duration can be combined. Click column headers to sort (newest
recorded activity is the default). **Clear filters** restores the complete table;
**Refresh history** explicitly rescans for new/changed recordings.
Duration is the span from the first to last recorded activity, not elapsed model
working time. Missing dates/agents/duration display **Not recorded**; deferred
prompt counts display **Not indexed**. File modification times are not invented
conversation timestamps.

Discovery streams progress and rows in the background while filters and the
window stay responsive. It is limited to 60 seconds, 10,000 recordings, 8 MiB
per recording metadata read, and 256 MiB total recording metadata reads per refresh.
Workspace metadata and agent database values are limited to 1 MiB each; saved
title indexes are limited to 8 MiB each. Larger recording sources
remain listed as **Load to inspect** rather than disappearing. **Discovery
details** shows errors and limits; row tooltips explain partial, unavailable
and unsupported sources. Chat titles use the VS Code index where available.
Loading reconstructs and validates the full selected recording (100 MiB maximum)
with a 30-second helper limit and conflicting actions disabled until done.
Request serialization, helper I/O and response decoding run in a background
runspace, including asynchronous worker startup. The window itself remains
enabled: searches and independent presentation controls still respond.
Transport JSON uses the in-box .NET decoder with case-insensitive dictionaries
and arrays instead of recursively allocating PowerShell note-property wrappers
for the entire recording. This reduces garbage-collection pauses during large
responses. Small, explicit WPF view models remain unchanged; values, arrays,
case-insensitive field access and save/export JSON are preserved. Malformed JSON,
empty property names and case-ambiguous property names still fail explicitly.
Slow library operations show an activity label, elapsed seconds, an animated
indicator and **Cancel operation**. Closing that activity window also cancels.
Saved selections start loading after the picker is visible, rather than
delaying its appearance. The same background wait is used for saved-library
refresh, import, rename, delete and export. The budget includes sending the request:
a helper that stops reading stdin cannot freeze the window before the watchdog
starts. Closing the owning window cancels and stops that helper. This explicit
owner-close cancellation is logged as a warning instead of reopening an error
dialog for the closed window; it still never confirms a successful operation.
History
discovery retains its separate 60-second budget and streamed progress.

Success requires a complete successful response **and** a zero-exit helper.
Output alone does not confirm success if the helper remains running. Timeout
errors identify the operation and whether it stalled sending the request or
waiting for helper exit, without adding recording paths, titles or content.
The helper is stopped and its exit awaited before controls are restored.
Library requests use UTF-8 streaming decoding, including split Unicode characters
and the optional leading byte-order mark emitted by some Windows PowerShell
console encodings. Malformed JSON still fails explicitly; task completion does
not add extra values to the returned library results.
Timeout/cancellation is not a rollback: a write may already have reached disk.
Refresh the library before retrying; no automatic retry or lock removal occurs.

The isolated helper checks exercise all 12 real CLI commands with synthetic
recordings and reviewed summaries, including a multi-megabyte response.
They enforce a 250 ms dispatcher/input-delay budget while serializing 5,000
request objects and decoding 20,000 response objects, and check independent
controls, explicit cancellation, delayed success, failure, responsive saved refresh,
blocked stdin, output without process exit, streamed history and owner-close
cancellation against the unchanged 30-second deadline:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\capture-helper.ps1 -NodePath 'C:\Tools\node\node.exe'
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\library-helper-lifecycle.ps1 -NodePath 'C:\Tools\node\node.exe'
```

These checks use temporary libraries, do not show windows or access real recordings,
and remove their fixtures afterward. A passing check does not diagnose a timeout
on a different recording; record which action failed (load, save, library
refresh, etc.) and reproduce with a sanitized synthetic fixture before
changing the timeout.

SDK event recordings normalize saved prompts, assistant text and tool transitions
for playback. Original selected events, tool-result data, initial context and
attachment metadata remain in the raw payload. Other event metadata is available
in a collapsible native **Recorded SDK events** activity entry, not streamed
into the assistant's reply as JSON. Expand the entry to inspect its read-only
output; no saved tool is executed.
External attachments are not bundled. Saved SDK text, reasoning and tool results
can be replayed even when a follow-up prompt interrupted the work or no final
answer was recorded. Unfinished or unmatchable tools stay in the read-only event
archive rather than appearing as live or successfully completed tool calls.
The original completion state and events remain in the full saved payload.
Agent databases with no supported SDK link remain visible but unavailable;
local-only database turns are not yet a supported playback format.
Legacy JSON snapshots are also listed with an explicit unsupported-format reason;
they are not silently hidden or treated as JSONL recordings.
SDK captures use provenance kind `copilot-sdk-jsonl` in the existing version-1
package; older players that only support native recordings will reject them.
Captures containing unfinished SDK exchanges require this player update; earlier
SDK-capable builds still reject exchanges without a completed final answer.

Available exchanges are selected when a conversation loads. Unavailable entries
remain visible for inspection; the status reports how many were excluded and
the first reason. Use **Select all** or
**Ctrl+A** while the exchange list has focus, **Clear selection**, or Ctrl/Shift
to adjust the selection. **Select available** excludes genuinely unreadable
exchanges, including after using Select all. Use selected exchanges stays disabled for empty,
unavailable, or oversized selections, until the current preview is ready and
reviewed. The conversation title is used automatically; a custom selection name
is optional. A selection can contain up to 100 exchanges; larger
selections show an explicit warning rather than being silently reduced.
Review the readable prompt/response preview. Exchange rows use short labels and
recycled containers; preview updates are coalesced over 75 ms and limited to
32,768 characters so large saved tool payloads do not stall selection.
Enable **Show full saved payload** to preview original tool data and metadata.
An explicit notice identifies previews that exceed the display budget; select
fewer exchanges or inspect the source file to review oversized content.
Capture always preserves the full selected content, not the shortened preview.
Acknowledge the privacy/asset notice, optionally use **Summarize prompts with AI...**
or **Review / edit summaries...**, then **Use selected exchanges**.
Selections are saved locally for reuse without a separate capture/save step.
Preparing summaries and then using the same selection reuses its saved copy.
UI capture follows source order; the underlying capture
API also accepts explicitly ordered distinct indices. Partial or unsupported
native exchanges are marked unavailable with a reason; nothing is silently dropped.
An absent/incomplete request error identifies missing saved fields (request
record, completion result, prompt text, or response array). It does not
necessarily mean the entire exchange disappeared: interrupted or still-saving
native requests may lack a completion result even when some text is present.
Reload after saving completes; the player cannot reconstruct missing content.
If the source changes after preview, reload and review it before capture.
Saved inline file/symbol references are supported in Editor playback as inert,
escaped labels; linked external content is not fetched or bundled. Completed
saved text edit groups are supported in Editor capture/playback and labeled
**Read-only edits**. They display the recorded target, ordered edit batches,
1-based ranges (exclusive end), and replacement text in a collapsible native
activity entry marked **Recorded code edit - not applied**, rather than a large
code block in the assistant's reply. Expand the entry to inspect the read-only
output. Empty replacements and batches are labeled
explicitly. The player neither reads nor modifies the target files and does not
invent original contents or a before/after diff. Original edit payloads, including
extra metadata, remain intact through capture, export/import, and playback.
Missing completion flags, malformed batches, missing replacement text/targets,
and invalid ranges are rejected with specific errors and remain inspectable in
the raw preview. Unknown response kinds are also rejected, never silently dropped.
Serialized confirmations, task progress and workspace edits also use labeled
read-only activity entries rather than raw JSON in the reply. These completed
display entries do not execute recorded actions or claim edits were applied.
Assistant prose, intentional code examples, thinking and actual recorded tool
transitions keep their original content and native presentation, including when
completed exchanges are restored as history.
Question carousels still require the experimental saved-parts renderer and remain
explicitly unavailable in baseline Editor capture.

To validate saved-activity presentation in a fresh isolated VS Code profile,
run `node test-native.js --artifacts` from `native`. This generates a synthetic
two-turn recording with large XML edit/event payloads, checks that each activity
starts collapsed and expands on demand, and exercises retained history and
Start Over. It does not use the demo library or change recorded target files.

The controller has one selection entry point: **Find interaction...** (or the
current interaction title). It opens a single picker, starting with searchable
agent history and a side-by-side exchange list/readable preview.
The **Saved selections** tab searches previously prepared selections.
Rename, import, export, and remove live in its collapsed **Selection actions**
section, not in competing controller workflows. Removal requires confirmation
and affects only that library copy. Exports never
overwrite an existing destination, even after the standard save dialog's
overwrite confirmation; choose a new filename.

**Open** launches a dedicated VS Code window without playback. Once ready,
**Play** starts the first exchange. After each answer, **Next Step** advances
one exchange or **Start Over** restarts the selected demo. Pause/Resume freezes
the current timeline. **Stop** closes only the isolated replay window and leaves
Demo Player ready to run again. Closing Demo Player stops its paired window
before exiting. A completed demo stays visible until Stop.
Validation and target launch run in the background with visible activity;
mode-switch launches do too. During that short launch phase, conflicting
actions are disabled, but the controller still processes window/presentation
events. Closing then waits for the launch result so the controller can stop
only its own isolated target, rather than leaving it orphaned.
Selecting or refreshing one entry reads only that entry's validated metadata;
it no longer re-reads the entire library or transfers the full recording to the
UI merely to update summary counters.

### Replay presentation controls

Use the **Playback speed** slider at any time, including while paused. Its normal
end is **2 seconds per user prompt / 5 seconds per reply**; its fastest end is
**100 ms per user prompt / 1 second per reply**, with linear values between.
The label shows both durations. A change preserves progress within the current
phase and applies to the remaining typing/output in both Editor and Agents modes.
The speed choice lasts for this controller session, including replay and mode switches.
Recorded working-time totals do not change with presentation speed. Auto-continue's
output-summary reading dwell also decreases with speed. **Estimated total** updates immediately as
the slider moves and covers the full included selection, not just the remaining
exchanges. With Auto continue on it includes output-summary reading time between
exchanges (2-10 seconds at normal speed, 0.4-2 seconds at fastest speed, never
after the final reply). Without
Auto continue it shows playback time **+ manual waits**, not an invented duration
for those waits. Startup, rendering/transport overhead and pauses are excluded,
so this is an estimate, distinct from the original cumulative working-time timer.
Moving the slider only uses cached counts/reading totals; it does not rescan
recordings or call a helper on the UI dispatcher.

Once a saved interaction is loaded, **Select exchanges...** opens a scrollable
checklist with input/output summaries (source excerpts when no summary is saved),
individual checkboxes, **Select all**, **Deselect all**, and an included count.
**Use selected exchanges** saves the selection in original order;
at least one exchange must be included. Cancel writes nothing. You can also change
the selection while playback is paused. Saving prepares the current exchange from
its beginning if it remains included, otherwise the next included exchange.
Playback stays waiting for **Resume**; if none follows, it finishes without
looping to earlier exchanges. Cancel leaves the paused exchange untouched.
The isolated playback window reopens to reload the saved selection.
Originals and reviewed summaries are preserved,
and concurrent summary/inclusion changes are rejected rather than overwritten.

After the final reply, the playback window and summary overlay stay open on the
last exchange. **Replay** restarts the selected exchanges; the stop button becomes
**Exit** (tooltip and accessible name) and closes the isolated playback/controller
windows. Closing the controller also closes its paired replay window normally.
No unrelated editor window or process is terminated.

The **VS Code / Agents (experimental)** selector chooses the native playback UI.
During playback, switching is allowed only between complete responses. It closes
and reopens only the dedicated replay window, retaining the selected portable
package or transcript range, completed history, progress, and working-time total.
It is disabled during typing/output, including a paused response. No model request
or recorded tool execution is submitted. Agents requires a compatible, signed-in
dedicated window; its authentication/native UI gate remains experimental.

**Show prompt summary** and **Show elapsed time** are off by default. Either or
both appear in one movable, rounded overlay with an orange-yellow frame. Use
either checkbox as soon as a demo is selected, before **Open**: the overlay
previews its first prompt and starts valid recorded timing at **00:00:00**.
Opening playback preserves these choices; Stop restores the selected-demo preview.
The timer remains disabled when the saved recording lacks valid timing endpoints.
Click the **Overlay frame** swatch to use the native Windows color picker. Overlay
choices and color survive mode switches within that controller session; they
are not saved as global settings. Drag the overlay's bottom-right grip to resize
its width and height. Text wraps to the available width; a vertical scrollbar
keeps text accessible in a short window. With both options enabled, widths below
640 WPF layout units place the timer at the top and give the summary the full
width and remaining height below it. Wider windows keep the side-by-side layout.
Until you manually resize, the overlay measures the actual summary font and
available width and adjusts its height to fit, bounded by the screen work area.
Your chosen dimensions survive prompt
updates, checkbox changes, Stop, and mode switches within that controller session.

**Show summary of output** is also off by default. Enable it for a scrolling
text-message history: right-aligned blue **You** input bubbles and
a left-aligned neutral **AI** output bubble, each with a contrasting text label.
This mode includes the input even if **Show prompt summary** is unchecked, and
always pins working time at the top at every width. **Show elapsed time** is
temporarily disabled; its prior choice returns when output mode is off.
Untimed recordings show **Unavailable** rather than a fabricated duration.
The timer itself never animates or moves with the bubbles.

The first input appears before playback. Only after the entire recorded reply
finishes, a down arrow and its reviewed output summary appear below that input.
**Next Step** appends the next input at the bottom. Previous messages remain,
bounded to the current recording (at most 100 included exchanges / 200 bubbles).
Each new input or revealed reply returns to the current exchange. Its complete
prompt and reply must be visible together without scrolling. The overlay measures
the real WPF bubbles, font, timer and padding, and grows within the monitor work
area when necessary. A manual resize is retained only while the current pair still
fits; it cannot make the pair clip. Older history remains scrollable between
exchange transitions, below the fixed timer.

Review/save and opening playback with output summaries enabled check included
pairs using the same rendered layout, not just character counts. If a pair cannot
fit even at the screen's available width and height, shorten it in **Review / edit
summaries**; the full draft is retained and saving/playback is blocked with an
explicit exchange number. Native VS Code review performs the same Windows layout
check before saving. Enabling output summaries on an already-open, incompatible
recording turns that option back off with an explanation. No text is truncated,
automatically rewritten or regenerated. New AI generation, unlike saved/manual
summary editing, includes bounded length correction covered by its consent notice.
Brief incoming fades honor the Windows client-area animation preference. Polling and
pause/resume do not replay transitions. Start Over, Stop and a new selection
reset the conversation deterministically. A missing/deleted output summary
shows explicit guidance to generate or edit it before playback, never an
invented success or a paraphrase of the user request.

**Auto continue** defaults off. When enabled, a completed exchange waits for a
nonblocking reading dwell before advancing: one second plus one second per 35
output-summary characters, bounded to 2-10 seconds at normal speed and scaled
down linearly to 20% at the fastest speed. Only the newly revealed output needs
this dwell: with output summaries off, auto-continue advances on the next control
poll without an artificial reading wait, including in prompt-only mode. Unchecking,
manual Next Step, Pause/Start Over, Stop, selection/mode changes, or connection
failure cancel pending advancement. It never advances from preparation, ready,
paused or faulted states, and the last exchange finishes without looping.

Run the responsive layout regression without opening interactive windows:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\overlay-layout.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\exchange-selection.ps1
```

The summary falls back to a bounded, whitespace-normalized excerpt of the exact
original prompt. In the interaction picker, use **Review / edit summaries...**, select an
exchange's **Input (You)** or **Output (AI)** and write or edit its overlay text
(one line, up to 1200 characters). Output source previews contain only recorded
assistant text and tool status, not raw tool payloads. Leave an input blank to
use its original excerpt; blank output remains explicitly missing. Then **Save summaries** and
**Use selected exchanges** (or **Use saved selection**). Local playlists can also supply one reviewed `promptSummaries`
entry per turn, and optional `outputSummaries` (one string or `null` per turn).
Legacy packages and playlists without output fields still load.

The editor's **Include in playback** checkbox belongs to the original exchange
(both its input and output), not its summary. Excluded exchanges remain visible
and editable here for re-inclusion. The included/total count updates in the editor;
at least one exchange must remain included. Save commits inclusion and summaries
atomically with stale-editor protection; Cancel writes nothing. Next-run playback,
timing, progress, generation candidates and summary-link counts use included
exchanges only, in their original saved order. The complete recording, source
indices, payload hashes and all summaries remain unchanged by exclusion.
Export/import preserves the optional `playbackIncluded` boolean array aligned to
the original saved turns; legacy recordings include every turn.

Output summaries must preserve the actual question the assistant asked, including
alternatives or a requested decision, especially the final question answered by a
following "yes"/"no". Both provider prompts (including partial/combined requests)
and review guidance require this, retain speaker voice and forbid invented
questions or successful outcomes. Existing saved summaries are not rewritten or
sent for paid regeneration automatically. Review/edit them manually, or explicitly
delete and save the relevant summary, then generate its missing replacement and
review before saving.
Both AI providers also receive the preceding included exchange's original input
and supported assistant output as explicitly labeled, untrusted context, bounded
to 4,000 characters with any omitted middle marked. This relates short answers
to the question/choices they answer without treating earlier results as current
success. Excluded exchanges are not sent as neighboring context. The consent
preview shows all additional context before generation, including for prompt-only
generation, which now sends prior assistant context but still generates inputs only.
Existing summaries are not regenerated automatically; delete a saved summary
explicitly before generating a contextual replacement.
For long output sources, every combination request also retains up to
3,600 trailing characters of the original assistant source as verbatim grounding,
so its closing question/choices do not depend solely on a partial model summary.
This is part of the already displayed/consented source, not another exchange.

New AI drafts target **180-220 characters or fewer**, with a **600-character
safety limit** to accommodate complete sentences and explicit questions/choices,
not a fixed display box. Incidental details should be omitted before questions
or qualifications; the additional room is not a request for longer replies.
Both providers automatically rewrite completed, well-formed overlong drafts before
review. Each source part/combination permits **at most 4 requests**: one generation
and up to three length corrections, with a fixed **90-second total deadline**
(the player's helper watchdog allows 95 seconds including process overhead).
Corrections resend the consented source/context and previous draft, prioritizing
the recorded answer, final unanswered question/choices and qualifications over
incidental detail. Each intermediate summary must fit 600 before combination.
One source-consent notice covers these additional, potentially billed requests;
progress describes generation/correction, limits and source/combination parts.
Cancel stops further work but cannot undo sent requests or charges. Exhaustion
fails the batch explicitly: no invalid or partial batch is offered as successful
or saved; retry generation explicitly or choose another model.
Draft transport remains bounded at 4096 characters; larger responses fail
explicitly, never silently slice or become a saved summary. Valid first results
use no correction requests. There are no automatic retries for malformed,
incomplete/refused, authentication, TLS, billing, rate-limit or network failures.

For older/in-flight unsaved overlong AI drafts, **Automatically shorten AI summaries**
in the open player/native review repairs unchanged generated drafts only, after
source/draft preview and paid-request consent (up to 4 correction requests per
part). Valid/manual edited summaries, inclusion and other review decisions are
kept; cancellation/failure leaves the batch unchanged. Save remains explicit and
atomic. An already-running older app cannot gain new controls: reopen the updated
app and regenerate unsaved drafts; saved recordings are never silently mutated.
Human-edited text may exceed the AI limit but must fit the 1200-character save limit.
Speak directly in the original speaker's voice: "I want...", "Can you...?" or
"Yes.", not "User wants to..." or "The assistant...". For a user question,
the output summary must lead with the actual recorded answer and qualifications;
if the reply did not answer, it must say so, never invent an answer.
Generation rejects malformed, visibly unfinished or role-narrated drafts explicitly,
without slicing text or retrying those failures.
This includes obvious dangling endings such as "I set a !"; punctuation alone
does not prove grammatical completeness. Local checks are not a semantic
guarantee, so review the draft against its recorded source.
Manual summaries allow **1200 characters** (a bounded four-times-legacy review
budget for complete saved text); existing summaries are unchanged.
Editors report invalid lengths instead of silently clipping pasted text.
The overlay wraps the full saved text and scrolls when resized too short.
Manual dimensions are retained for both the resize thumb and native window-edge
resizing, including through playback updates, output-mode changes and Stop.
History fills in batches of four bubbles per dispatcher tick so wrapping long
summaries does not monopolize input handling as a conversation grows.
An older summary already saved mid-word cannot be restored by enlarging the
window: edit it against the retained original, or explicitly delete just that
summary and consent to generate its replacement. Nothing is cleared automatically.

Use **Clear all summaries...** in the interaction picker to remove all saved overlay
summaries, including AI-generated and manually edited summaries, after
confirmation. Default prompt excerpts return; original prompts/responses and
per-turn hashes are unchanged. In the manual editor, **Clear all summaries**
clears the drafts for every exchange; **Save summaries** applies that change,
while **Cancel** discards it. **Delete this summary** clears only the current
exchange's summary draft, never its original prompt.

**Generate AI summaries...** is the single generation action on both picker tabs.
It offers **Inputs and outputs** (default), **Inputs only**, and **Outputs only**;
canceling this scope picker makes no request or saved-selection change.
**Outputs only** generates
only missing output summaries, never generates prompt summaries, and keeps
existing input/output summaries. It sends the paired user question/request as
explicitly previewed context (up to 4,000 characters). Longer context keeps its
opening and closing portions with a visible middle-omitted notice; missing context
must not be inferred. Context is not evidence that an action succeeded.
Recorded assistant answer text and concise tool
status are used, with the same filtering and result-fidelity safeguards as the
combined action below. Raw tool arguments/results, reasoning and metadata remain
excluded; displayed answer text can still contain secrets, so review it before
consenting. Unsupported-only outputs still require a manual summary.

Starting with v0.2.15, every application AI-summary action uses the OpenAI API
directly, without depending on VS Code providers, Copilot sign-in, model-access
permissions or a separate authoring window. Playback still never invokes AI.

The controller also offers separate **Generate AI prompt summaries (saved/total)**
and **Generate AI output summaries (saved/total)** links for the selected interaction.
These links require v0.2.13 or later. Each numerator counts
all saved summaries of that kind, including manual summaries; the denominator is
the total number of exchanges in the selected interaction, not the number eligible
for generation. Counts refresh after saved changes without reselecting. With no
interaction selected, the links show **(0/0)** and are disabled. They are also
disabled during playback; stop playback before authoring.
The prompt link generates only missing prompt summaries, including short prompts;
the output link generates only missing reply summaries. Both reuse the same
in-app key settings, source consent and editable review.
Existing summaries are preserved. Cancellation or unsaved drafts do not increase
the counts. Unsupported-only output still needs a manual summary, not an invented
answer. The combined picker action generates all missing prompts, including
short prompts, plus supported missing output summaries.

These output-summary controls require v0.2.12 or later; they are not present
in v0.2.11.

### Translate the summary window

Select an interaction, generate or manually save its summaries, and stop playback.
Choose **Translate summaries...** in the controller. **Simplified Chinese
(Mandarin)** is selected by default; **French**, **German**, **Italian**, and
**English** are also available. The action uses the same saved OpenAI API key
and model as summary generation.

The consent dialog shows exactly which saved summaries will be sent. Only
included exchanges with saved input/output summaries are translated; excluded
exchanges and missing summaries are left alone. Original English prompt/reply
exchanges, tool payloads and neighboring context are not sent for translation.
API charges and OpenAI retention policies apply, even if you later cancel.
Each summary permits up to four requests for length correction within 90 seconds;
failed/refused requests are not retried automatically.

Choose **Translate and review**, check/edit the drafts against the originals,
then **Save summaries**. Saving replaces only the saved overlay summaries,
including their exported copies; it does not translate or modify the English
chat, recordings, payload hashes or replayed prompts/replies. Both the prompt-only
summary and input/output conversation window use the saved translation.
There is no separate English-summary backup or per-language cache: translate
again with **English**, or edit/regenerate summaries, to return to English.
Canceling review leaves saved summaries unchanged. Saved translations work
offline during playback; translation itself requires access to OpenAI.

**Settings**, immediately left of **Check for updates**, lets you save, replace
or delete an OpenAI API key and change the model ID. AI generation prompts for
a key only when one is missing or OpenAI rejects it. Enter the key in the masked
field, never in a recording or chat. The dialog links to
[OpenAI API keys](https://platform.openai.com/api-keys). API usage is billed
separately from ChatGPT subscriptions; your project needs API billing, quota and
model access. The default is **gpt-4.1-mini**, a low-cost, low-latency model.
Changing the model does not test access or send a request.
The model must support Responses API strict JSON-schema outputs with string
patterns; the default has been verified with real prompt and reply summaries.

Starting with v0.2.17, only the OpenAI helper enables Node's trusted Windows
certificate store. This supports HTTPS inspection with a certificate trusted
by Windows without disabling TLS verification, changing global settings, or
copying certificates. Certificate, DNS, timeout and other connection failures
are reported separately; a certificate failure is not reported as a timeout.
If a certificate is still untrusted, ask your network administrator to check
the chain rather than disabling certificate validation.

The key is encrypted with Windows DPAPI for the current Windows user in
`%LOCALAPPDATA%\VSCodeDemoPlayer\ai-settings.json`; the model ID is not secret.
The saved key is never displayed or included in recordings, exports, command-line
arguments or application logs. DPAPI is not protection from other software running
as your Windows user. Deleting the saved key removes its local ciphertext; revoke
the key at OpenAI if it may have been exposed. Older VS Code authoring profiles
are left untouched and are no longer used by application AI actions.

**Generate AI summaries...** with **Inputs and outputs** on either picker tab generates the
missing prompts and supported outputs in the current selection. Each short source
uses one HTTPS request to `https://api.openai.com/v1/responses`, with no tools
and `store: false`. This does not override OpenAI's service data-retention rules.
The response uses a strict JSON schema with a required string summary and a
server-enforced [Structured Outputs string pattern](https://developers.openai.com/api/docs/guides/structured-outputs#supported-schemas)
limiting it to 300 Unicode characters on one line.
Even 300 supplementary characters fit the existing 600 UTF-16-unit AI limit.
The same constraint applies to inputs, outputs, source chunks, combination and
legacy shortening. Length is constrained during generation, not just requested
in a prompt. The schema does **not** force terminal punctuation, append anything,
or cut text; local one-line, length, voice and complete-statement validation still
reject malformed or incomplete content before review. A model that rejects the
required pattern fails explicitly with model-selection guidance; there is no
retry with a weaker schema. The optional VS Code language-model authoring path
does not expose this API constraint and retains its bounded correction safeguards.
The **Generate OpenAI Summaries** consent dialog shows the exact text being
sent and selected model before any request. Review it for secrets: displayed
answer text may contain private content even after filtering. Raw tool
arguments/results, reasoning, SDK event archives and unsupported structures are
excluded with a notice, not recursively dumped. Output requests summarize
recorded results rather than the user's desired outcome. Unsupported-only
outputs need manual summaries; no success is invented. Full recordings remain
local and unchanged, but the consented text is sent to OpenAI.

Progress identifies the exchange and summary kind. **Cancel** stops the helper;
already sent requests may still incur charges. There is a 90-second limit per
request, including bounded automatic length correction as described above. Long sources are automatically split into
parts of at most 64,000 characters. Each part is summarized in order, then
intermediate summaries are combined into one overlay summary with additional
bounded requests; no original source is silently truncated. Both source and
combination requests incur API charges and are covered by the source-consent
notice. Progress shows source/combination phase and part number; cancellation
or any part failure stops the batch without saving partial drafts. Short
sources use one request each when the first draft fits, with no cap on their aggregate batch size.
A rejected key opens replacement settings;
save a replacement and explicitly start generation again. Billing, access,
network and invalid-output failures are reported explicitly. Cancellation or
failure saves no partial batch. Existing recording storage limits still apply;
the former 64,000-character source / 1 MiB whole-selection rejection is removed.

After successful generation, **Review AI Summaries** opens the existing
input/output editor with generated drafts, original source previews and a live
character count. Select each **Input (You)** or **Output (AI)** to review/edit it.
Summaries must be one line and at most 1200 characters. **Delete this summary**
or **Clear all summaries** changes only drafts until **Save summaries** is clicked.
**Cancel** or closing the editor saves nothing. Existing summaries are preserved
unless you edit them. To regenerate a saved summary, clear and save it first.
Stale concurrent edits are rejected atomically rather than overwritten.

Return to **Use selected exchanges** or **Use saved selection**; no refresh or
reselection is needed. Enable **Show prompt summary** and/or **Show summary of
output** in the controller to display saved summaries in the presentation dialog.
Both toggles stay off by default, and the original full chat text is unchanged.
Manual summaries work without a key or network access.

Summaries are optional package metadata and survive export/import. Concurrent
summary edits are rejected rather than overwritten; reopen the editor to reload.
Input and output batches save atomically against both opening revisions; a
concurrent manual output edit or clear cannot be overwritten by stale AI review.
Packages or playlists with summaries above 200 characters require this update;
older players enforce their earlier limit and reject them.
Original prompts, responses, per-turn payload hashes, and source bytes are
unchanged. Playback always types the full original prompt, never invokes AI,
and works without sign-in or network access. No recording-specific summaries
are shipped.

Legacy VS Code-provider authoring-only native acceptance creates a synthetic multi-prompt recording
and library entry in an isolated profile when no fixture is supplied. It tests
missing-provider guidance, then supplies an in-process synthetic provider to
exercise the real consent/progress/review webview, approval/edit/delete/all
actions, 300-character playback fidelity and cancellation. No external AI
requests or real-library/profile changes occur. This tests the retained
development-only provider path, not the application's direct OpenAI integration.
The production integration is covered by `test\openai-settings.ps1`,
`native\test\openai-summaries.test.js`, and `test\controller-ui.ps1` with isolated
profiles and synthetic HTTP responses; these do not establish real key/account
readiness or incur OpenAI charges:

```powershell
Set-Location native
node .\test-native.js --summaries
```

The **HH:MM:SS** stopwatch sums recorded prompt-to-response-completion intervals
and interpolates each interval during the accelerated output. It holds during
typing, Pause, and review, excluding idle gaps between responses and later user
prompts. It is presentation timing, not recovered token timing or model compute
time. Missing, invalid, overlapping, or out-of-order endpoints disable the timer
instead of guessing. Hours do not wrap at 24. Capture a screen region containing
the overlay; a window-only recorder may omit it.

The release-captain handoff and remaining acceptance gates are documented in
[docs/replay-controls-handoff.md](docs/replay-controls-handoff.md). A source branch
passing tests does not mean these controls are in the downloadable installer.

For a portable Node runtime outside PATH, pass its executable explicitly:

```powershell
.\Start-DemoPlayer.ps1 -NodePath 'C:\Tools\node\node.exe'
```

For portable VS Code, also pass `-CodePath 'C:\Tools\VSCode\Code.exe'`.
The installed executable accepts the same `-CodePath` and `-LibraryRoot`
options, and uses its bundled Node runtime by default.

The library defaults to `%LOCALAPPDATA%\VSCodeDemoPlayer\demos`, outside the
repository. `-LibraryRoot` chooses a separate library. Multiple players may
read it; concurrent writes are rejected with a visible busy error. After a
helper crash, inspect the library and ensure no writer is running before
manually removing `.library.lock`. Library helper operations time out after
30 seconds, startup after 45 seconds, and HTTP calls after one second.
If VS Code's updater is preventing new windows, Open fails immediately with
instructions to save your work and choose **Restart to Update** in VS Code,
rather than waiting for startup to time out. The update guard checks the
`vscode-updating` mutex's presence, not thread ownership, matching VS Code's
startup behavior. It does not stop, bypass, or modify the updater or other editor
windows. Recordings and summaries remain unchanged. Unexpected target exit
before readiness also displays an error instead of only resetting to Open.
Three consecutive connection failures initiate stop. Stop first allows eight
seconds for normal closure, then requests scoped window closure and waits six
more seconds; if it still cannot close, it asks you to close that isolated
window normally rather than killing the IDE.

The original direct launcher remains available:

```powershell
.\Start-Replay.ps1 -SessionPath 'C:\Recordings\conversation.jsonl' -RequestIndex 0 -RequestCount 2
.\Start-Replay.ps1 -DemoPath 'C:\Recordings\example.demo-recording.json'
```

Direct-launch mode retains its paired-controller lifetime: Stop closes both.

Do not install this development extension globally in your normal VS Code profile.
The playback launcher supplies a dedicated temporary profile and extension directory.
Summary authoring instead loads it only in its dedicated development window,
using your existing AI setup as described above.

Existing local playlist manifests can be supplied using `-PlaylistPath`.
They refer to native workspace-storage session IDs on the same computer;
they are not portable packages. No machine-specific default playlist is used.

## Export helper

Use **Export...** in the library for the portable format. **Import Recording**
validates the format, version, supported response parts, and content hashes
before adding it. A package includes only selected request payloads and the
minimal session/model metadata needed for playback; the source transcript is
not required afterward. Display-title renames are stored separately from the
original capture.

Version 1 is a single UTF-8 `.demo-recording.json` file with:

- `format: "vscode-demo-recording"`, `version: 1`, UUID, title, and capture date.
- Source filename/session ID and SHA-256 of the previewed source bytes.
- Ordered `turns`, each with its source index, minimal native snapshot, and
  SHA-256 of that snapshot's JSON representation.
- An explicit fidelity/asset notice.

Hashes detect accidental content changes; they are not authentication,
redaction, or proof that the source recorded every action. Only one supported
native VS Code JSONL source is captured per demo. Other agents need a future
format adapter, not a prompt asking a model to invent the package.

The current Editor package renderer accepts Markdown, thinking, completed tool
records with identifiers, recorded inline file/URI/location references, and
known internal metadata. References retain their native inline anchors in
streamed output and subsequent conversation history. Serialized URI components,
absolute paths, symbol locations, and saved source ranges are validated without
reading or requiring the referenced file. Executable URI schemes and malformed
references are rejected explicitly. Supported saved questions/edits and
other archived parts are displayed as untrusted read-only
JSON code blocks, not editable or live widgets; Agents uses its supported saved
displays. Unknown native part kinds and incomplete native tool records are
refused explicitly; interrupted SDK tool events remain available as read-only
archives.
External images, links, files, and workspace state are
**not bundled**. The capture tool does not retrieve their contents. Native
Markdown may retain links; do not activate external links during a recording.
This is portable conversation-payload playback,
not a reproducible project/hardware execution environment.

Limits: 100 MiB per input/package/library entry, 100 exchanges per demo, 1,000
demos per library, and 10,000 turns per inspected transcript. Discovery shows the
200 most recently saved native sessions across at most 5,000 storage folders
and 10,000 session files. Other sources can be selected manually.

### Legacy helper

```powershell
.\Export-OriginalChat.ps1 -SessionPath 'C:\Recordings\conversation.jsonl' -OutputPath 'C:\Recordings\excerpt.native-chat.json' -RequestCount 2
```

This legacy helper exports complete requests from the **first snapshot only**.
It does not implement the proposed portable package or reconstruct later
updates. The playback reader reconstructs updates separately.

## Validation

### Build the Windows installer

Install [Inno Setup 6](https://jrsoftware.org/isdl.php), then run from a
Windows PowerShell 5.1 terminal:

```powershell
.\packaging\Build-Windows.ps1
```

If the compiler is not in a standard installation location, pass
`-InnoCompiler 'C:\Tools\InnoSetup\ISCC.exe'`.
The build downloads the pinned official Node.js 22.23.3 x64 archive, verifies
its SHA-256, and installs only locked production npm dependencies into a fresh
allowlisted payload. It does not package local recordings, source transcripts,
development dependencies, or your normal VS Code installation. Node's license
and the production dependency licenses are included.

Outputs are `dist\VSCodeDemoPlayer-Setup.exe` and `dist\SHA256SUMS.txt`.
The release version comes from `native/package.json`. The GitHub Actions
release workflow runs tests and builds on Windows before publishing both
assets for a `v<version>` tag. The Releases link above follows the newest
published non-prerelease version; the versioned
installer link is pinned to the named release. No code-signing certificate is
configured.

Startup errors are displayed and saved to
`%LOCALAPPDATA%\VSCodeDemoPlayer\last-startup-error.log`. To check dependency
resolution without opening a UI, run
`powershell.exe -NoProfile -File .\Start-InstalledPlayer.ps1 -Check`
from the installed directory.

Taskbar identity acceptance without installing or changing any pins (coordinate
the shared desktop slot first, then supply a disposable build payload):

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\taskbar-identity.ps1 -ApplicationRoot '<build-payload>' -EvidenceRoot .\.build\taskbar-identity
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test\taskbar-relaunch.ps1 -ApplicationRoot '<build-payload>' -EvidenceRoot .\.build\taskbar-relaunch
```

This opens and closes a synthetic WPF window, runs the production installed-only
window initialization, and independently reads back the native process ID and
window property store. It checks the launcher command and argument round-trip,
display name, executable icon location, source-run isolation, and explicit
failure handling. It also checks native property cleanup on close while
cancelled replay closes retain their identity. It does not pin/unpin, create
shortcuts, run an installer,
launch VS Code, or access the real demo library. The relaunch harness runs the
production launcher/startup with a controller fixture and redirected app data,
checking long custom paths, saved-profile relaunch, ordinary defaults, and
explicit missing/invalid-profile failures. Packaging checks additionally
verify shortcut AppUserModelIDs, the finish-page text, optional/silent launch,
and the runtime helper allowlist. Actual manual pin/relaunch and installed
upgrade acceptance remain separate interactive release checks.

Installer acceptance (on a machine with no existing installed Demo Player):

```powershell
.\test\installer.ps1 -InstallerPath .\dist\VSCodeDemoPlayer-Setup.exe -EvidenceRoot .\.build\acceptance -KeepInstalled
.\test\controller-ui.ps1 -NodePath "$env:LOCALAPPDATA\Programs\VSCodeDemoPlayer\runtime\node.exe" -EvidenceRoot .\.build\acceptance -ApplicationRoot "$env:LOCALAPPDATA\Programs\VSCodeDemoPlayer" -Installed
```

The installer harness refuses to replace an existing user installation, tests
same-version repair/upgrade and uninstall, and verifies data preservation and
the Start menu shortcut. `-KeepInstalled` reinstalls the tested app afterward.
The installed UI harness launches the executable without a Node override and
tests capture, library persistence, Play/Pause/Stop, completion, controller
reuse, and closure during paused playback using synthetic conversations.

Release 0.1.0 was checked locally on Windows x64 with VS Code 1.142.0:
33 unit tests, 19 packaging/syntax assertions, 38 installer assertions, and
the installed executable's interactive UI harness passed. Native tests against
the installed extension verified two original synthetic prompts/responses and
history; measured prompt entry was 2.007/2.011 seconds and output was
5.014/5.009 seconds. This is not a test on a second physical computer or a
guarantee of compatibility with every newer VS Code build. Lint has zero errors
and four pre-existing browser-global warnings.

For native content and timing checks against the installed extension, set
`HISTORY_REPLAY_TEST_EXTENSION` to
`%LOCALAPPDATA%\Programs\VSCodeDemoPlayer\native` before running the native
test below. The test harness and development dependencies stay in the source
checkout; they are not shipped.

### Source tests

```powershell
Set-Location .\native
npm run test:unit
npm run lint
```

`test:unit` selects the native-reference regressions explicitly, including
capture/export/import fidelity, serialized URI/location variants, native-anchor
conversion, malformed ranges, and refusal to turn unknown parts into tool calls.

For synthetic summary/provider-recovery acceptance (no external AI requests):

```powershell
$env:HISTORY_REPLAY_TEST_PROFILE = 'C:\Temp\unique-synthetic-summary-profile'
node .\test-native.js --summaries
```

Use a new empty profile path and reserve the interactive desktop slot first.
This launches a normal isolated development window via a generated local driver:
VS Code suppresses modal dialogs in extension-test mode. Only that synthetic
profile sets custom dialog style for automation. Acceptance exercises real
missing-provider guidance, explicit retry/provider search/cancel, repeated
production-launcher foregrounding/inbox delivery, and the full synthetic-model
review/save/cancel flow. Result JSON, screenshots and local driver stay under
the test profile. Unit tests separately cover throwing/stalled discovery,
setup-command failures and reload/last-selection recovery. None of these tests
certifies a live provider, account sign-in, allowance, or external model access.

An explicitly authorized live check is available separately:

```powershell
$env:HISTORY_REPLAY_TEST_PROFILE = 'C:\Temp\unique-live-summary-evidence'
node .\test-native.js --existing-ai
```

Unlike `--summaries`, this opens a separate development window using your normal
VS Code AI setup. It sends exactly two tiny fabricated examples (one input and
one reply), not real recordings, using your provider/account allowance. Approve
any provider model-access prompt yourself. It does not install extensions, copy
credentials, change global settings, or quit unrelated editor windows. The
evidence path is not a user-data/profile override in this mode. Reserve the
desktop slot and obtain explicit live-request consent before running it.

For native reference rendering and retained-history verification:

```powershell
$env:HISTORY_REPLAY_TEST_SOURCE = 'C:\Recordings\reference-regression.jsonl'
npm run test:references:native
```

Use two complete exchanges, with at least one inline reference in the first.
This test verifies visible native inline anchors, preserved reference payloads,
exact prompt/answer text, and retained anchors after the second exchange.
Optional `HISTORY_REPLAY_TEST_EVIDENCE` selects a local screenshot directory.
Coordinate an interactive desktop test slot before running it; never commit
real source transcripts or their screenshots.

To run the existing native two-turn visual test with a suitable local source:

```powershell
$env:HISTORY_REPLAY_TEST_SOURCE = 'C:\Recordings\conversation.jsonl'
$env:HISTORY_REPLAY_TEST_REQUEST = '0'
npm test
```

The selected two complete turns must contain nonempty, multi-character prompts
and visible Markdown answers supported by the Editor renderer. The test opens
an isolated VS Code instance and saves screenshots beneath the temporary
`VSCode-Demo-Player\visual` directory. Do not commit that evidence or source data.
Unit and lint success alone do not establish native UI acceptance.

The capture/library and original playback unit suites run together. ESLint
retains four existing browser-global warnings in `native-composer.js`
(`document`, `requestAnimationFrame`, and `TextUpdateEvent`). A strict
zero-warning lint gate therefore does not pass.

Validation of the capture/library implementation passed 33 unit tests,
PowerShell syntax checks, the interactive Windows acceptance harness, and
native two-turn content/timing/history verification with synthetic recordings.
The measured native prompt durations were approximately 2.0 seconds and response
durations approximately 5.0 seconds. These are synthetic playback checks, not
new execution of the original projects or hardware.

The Windows UI acceptance harness creates synthetic recordings in an explicit
evidence directory, captures through the actual dialog, renames/selects a demo,
and exercises play/pause/resume, review, completion, and scoped stop:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\controller-ui.ps1 -NodePath 'C:\Tools\node\node.exe' -EvidenceRoot 'C:\Temp\demo-player-ui'
```

Run UI tests only on an interactive desktop. It opens and normally closes only
its own test windows. Evidence and synthetic library files stay in the supplied
directory and must not be committed.
Use source-controller mode (omit `-Installed`) for routine tests of a packaged
payload. Installed-launcher mode holds the app's single-instance mutex and must
use a coordinated desktop/installation slot, not run alongside the user's app.
The harness waits for asynchronous saved selections to load after restart and
stops only its exact failed-test controllers if acceptance fails, so a failed
test cannot leave the installed-app mutex held.

## Layout

- [Start-Replay.ps1](Start-Replay.ps1): isolated VS Code and controller launcher.
- [Start-DemoPlayer.ps1](Start-DemoPlayer.ps1): standalone application entry point.
- [Show-ReplayController.ps1](Show-ReplayController.ps1): compact WPF popup.
- [DemoDialogs.ps1](DemoDialogs.ps1): custom library/capture dialogs and bounded helper bridge.
- [native/demo-library.js](native/demo-library.js): deterministic capture and local library.
- [Export-OriginalChat.ps1](Export-OriginalChat.ps1): legacy snapshot exporter.
- [native/](native/): extension, transcript reader, control server, and tests.

## Privacy and fidelity

Recorded conversations can contain confidential prompts, file paths, code,
tool payloads, and credentials. Keep them outside this repository and review
them before sharing. Ignore rules are a precaution, not a redaction system.
Original storage is read-only during playback. Tool status and streaming
timelines are presentation reconstructions, not original execution timings.

The project-specific browser mockup and source-dependent manual probes were
deliberately not copied. No new license grant is made by this extraction.
