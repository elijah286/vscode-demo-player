# VS Code Demo Player

**[Download the Windows installer - v0.2.12](https://github.com/elijah286/vscode-demo-player/releases/download/v0.2.12/VSCodeDemoPlayer-Setup.exe)** |
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
with a 30-second helper limit and reentrant controls disabled until done.
The same responsive, disabled-owner wait is used for saved-library refresh,
import, rename, delete and export. The budget includes sending the request:
a helper that stops reading stdin cannot freeze the window before the watchdog
starts. Closing the owning window cancels and stops that helper. History
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

The isolated helper checks exercise all 11 real CLI commands with synthetic
recordings and reviewed summaries, including a multi-megabyte response.
They also check delayed success, explicit failure, responsive saved refresh,
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

### Replay presentation controls

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

**Show summary of output** is also off by default. Enable it for a bounded
two-message conversation overlay: a right-aligned blue **You** input bubble and
a left-aligned neutral **AI** output bubble, each with a contrasting text label.
This mode includes the input even if **Show prompt summary** is unchecked, and
always pins working time at the top at every width. **Show elapsed time** is
temporarily disabled; its prior choice returns when output mode is off.
Untimed recordings show **Unavailable** rather than a fabricated duration.
The timer itself never animates or moves with the bubbles.

The first input appears before playback. Only after the entire recorded reply
finishes, a down arrow and its reviewed output summary appear below that input.
**Next Step** moves the latest output above the new input; the next completion
replaces that older context with the current input and output. At most two
messages are retained, not an accumulating transcript. Brief fade/slide
transitions honor the Windows client-area animation preference. Polling and
pause/resume do not replay transitions. Start Over, Stop and a new selection
reset the conversation deterministically. A missing/deleted output summary
shows explicit guidance to generate or edit it before playback, never an
invented success or a paraphrase of the user request.

Run the responsive layout regression without opening interactive windows:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\overlay-layout.ps1
```

The summary falls back to a bounded, whitespace-normalized excerpt of the exact
original prompt. In the interaction picker, use **Review / edit summaries...**, select an
exchange's **Input (You)** or **Output (AI)** and write or edit its overlay text
(one line, up to 300 characters). Output source previews contain only recorded
assistant text and tool status, not raw tool payloads. Leave an input blank to
use its original excerpt; blank output remains explicitly missing. Then **Save summaries** and
**Use selected exchanges** (or **Use saved selection**). Local playlists can also supply one reviewed `promptSummaries`
entry per turn, and optional `outputSummaries` (one string or `null` per turn).
Legacy packages and playlists without output fields still load.

Use **Clear all summaries...** in the interaction picker to remove all saved overlay
summaries, including AI-generated and manually edited summaries, after
confirmation. Default prompt excerpts return; original prompts/responses and
per-turn hashes are unchanged. In the manual editor, **Clear all summaries**
clears the drafts for every exchange; **Save summaries** applies that change,
while **Cancel** discards it. **Delete this summary** clears only the current
exchange's summary draft, never its original prompt.

**Generate AI summaries of responses** is an explicit response-only action beside
the conversation selection actions and on **Saved selections**. It generates
only missing output summaries, never sends or summarizes user prompts, and keeps
existing input/output summaries. Recorded assistant answer text and concise tool
status are used, with the same filtering and result-fidelity safeguards as the
combined action below. Raw tool arguments/results, reasoning and metadata remain
excluded; displayed answer text can still contain secrets, so review it before
consenting. Unsupported-only outputs still require a manual summary.

The response-only action reuses the completed provider-setup, editable review
and output-overlay features; it is not a separate summary format or playback
implementation. Approve or delete every draft and **Save reviewed summaries for
playback**, return to the picker, and use the selection. Then enable **Show summary
of output** in the controller (the output-summary checkbox). Full answers remain
unchanged in chat. Cancel, provider errors and stale output-summary edits save
no partial batch; concurrent input-only edits are preserved. To regenerate an
existing output summary, clear that output draft in **Review / edit summaries**
and save it first. The response-only scope survives provider retry, window reload
and later queued selections. The dedicated Command Palette action is
**Demo Player: Generate AI Summaries of Responses**.

The controller also offers separate **Generate AI prompt summaries (saved/total)**
and **Generate AI output summaries (saved/total)** links for the selected interaction.
These links are a pending follow-up and are not in v0.2.12. Each numerator counts
all saved summaries of that kind, including manual summaries; the denominator is
the total number of exchanges in the selected interaction, not the number eligible
for generation. Counts refresh after saved changes without reselecting. With no
interaction selected, the links show **(0/0)** and are disabled. They are also
disabled during playback; stop playback before authoring.
The prompt link generates only missing prompt summaries, including short prompts;
the output link generates only missing reply summaries. Both reuse the same
dedicated authoring profile, provider/model selection, consent and editable review.
Existing summaries are preserved. Cancellation or unsaved drafts do not increase
the counts. Unsupported-only output still needs a manual summary, not an invented
answer. **Demo Player: Generate AI Summaries of Prompts** retries prompt-only work;
the existing combined picker action retains its long-prompt eligibility rules.

These output-summary controls require v0.2.12 or later; they are not present
in v0.2.11.

**Summarize inputs / outputs with AI...**, available beside the selection action and
on the **Saved selections** tab, opens a separate, isolated VS Code
authoring window, never the playback window or your normal editor profile.
Install/enable an AI Language Model provider such as GitHub Copilot and sign in
in that window. Copilot uses your existing account/allowance: a separate API
token is not required, but a model must be available and provider limits/terms
still apply. The isolated profile does not inherit your normal VS Code sign-in
or installed extensions. It now persists its own providers and sign-in under
`%LOCALAPPDATA%\VSCodeDemoPlayer\summary-authoring` across launches. No tokens,
extensions, or settings are read/copied from the normal profile. The same
dedicated workspace receives later selections even when already running.
Do not use this workspace for normal editing. For isolated testing, set
`VSCODE_DEMO_PLAYER_SUMMARY_ROOT` to a separate synthetic profile root before
starting the controller; never point it at a normal VS Code profile.
VS Code's shared account-storage directory is isolated under the same root too.
Later selections are queued while generation/review is active; reopening the
picker action brings the existing authoring window forward without reloading it.

Before content consent, VS Code discovers/activates registered Language Model
providers. If none are ready (or discovery fails), a **modal** setup dialog
explains the problem. **Find providers** opens the GitHub Copilot extension
listing, but does not install, enable, sign in, or send prompts for you.
You may use another provider. Complete provider setup and account access in
this dedicated window, including any required reload. Then choose **Retry**,
or **Prompt summaries: Retry / set up AI** in the status bar. Reload restores
the last selection for retry. Discovery is retried explicitly, not treated as
successful generation. Dismiss/cancel leaves all library bytes unchanged;
manual summaries still work. Generation/save failures also use modal errors.
Discovery has a 15-second limit; a slow provider can be retried after setup.
Switch to the dedicated authoring window if another player window covers it.

There is no per-exchange chooser: one batch covers every unsummarized input that
exceeds the 300-character budget after whitespace normalization, plus missing
output summaries for all exchanges with supported recorded assistant text or
tool status. Exactly 300 input characters fits; 301 needs a summary.
This is a stable text budget, not a guarantee that text fits every resized
window without scrolling. Short prompts and existing summaries are preserved.
The eligible original user queries and filtered recorded assistant output/tool
status are shown for privacy review before one explicit batch consent and one
model selection. Consent covers both sources, provider terms and usage limits.
Each summary has a separate request; output requests use recorded results, not
the user's desired outcome. Raw tool arguments/results, reasoning, SDK event
archives and unsupported structures are omitted with an explicit notice;
they are not recursively dumped into provider requests. Review displayed text
for secrets before consenting. If no supported output remains, use the manual
editor; no successful outcome is assumed. Original full payloads stay local
and unchanged. No AI calls occur during presentation.
Progress identifies the exchange and summary kind. The batch is cancellable, with a
90-second limit per request. Failures, cancellation, over-context input, and
invalid/overlong output leave the entire library unchanged; no partial results
are saved. Once generation completes, a **Review input/output summaries** panel opens
automatically, with a kind-labeled exchange list, the read-only source and an
editable summary with a live character count. Use **Previous** / **Next** or
the list to compare exchanges. **Approve & next** approves one summary;
**Delete summary & next** removes only that input or output summary (inputs revert
to excerpts; outputs show a missing-summary notice). **Approve all remaining** preserves deletions. Editing an
approved or deleted summary makes it pending again. Blank, multiline and
over-budget summaries cannot be approved; delete the summary instead.
**Save reviewed summaries for playback** is available only after every draft
has been approved or deleted. It saves the reviewed batch once.
**Cancel** or closing the panel leaves the library unchanged. Switching editor
tabs retains review edits. Invalid decisions or changed exchange order/count
are rejected without saving.
Use **Demo Player: Summarize Inputs and Outputs** in that window's Command Palette to
retry a canceled batch. To regenerate saved summaries, clear them first.
Return to the picker and click **Use selected exchanges** or **Use saved selection**;
either reads the latest saved summaries without refreshing or reselecting.
Enable **Show prompt summary** in the controller to display them; this toggle
stays off by default. The native chat prompt itself intentionally remains full-length.
Close the authoring window when finished. Its dedicated profile, installed
providers and provider-managed authentication remain local for next time;
they are not shipped or committed. Playback profiles remain disposable and
never make AI requests. Live provider/account readiness requires your own
installation/sign-in and is not established by synthetic-provider tests.

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

Authoring-only native acceptance creates a synthetic multi-prompt recording
and library entry in an isolated profile when no fixture is supplied. It tests
missing-provider guidance, then supplies an in-process synthetic provider to
exercise the real consent/progress/review webview, approval/edit/delete/all
actions, 300-character playback fidelity and cancellation. No external AI
requests or real-library/profile changes occur:

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

Never install this development extension in your normal VS Code profile.
The launcher supplies a dedicated temporary profile and extension directory.

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
