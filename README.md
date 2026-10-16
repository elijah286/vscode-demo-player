# VS Code Demo Player

**[Download the Windows installer](https://github.com/elijah286/vscode-demo-player/releases/latest/download/VSCodeDemoPlayer-Setup.exe)** |
[Releases and SHA-256 checksums](https://github.com/elijah286/vscode-demo-player/releases/latest)

## Install and launch

1. Download and run **VSCodeDemoPlayer-Setup.exe**. This is a per-user install;
   administrator access is not required.
2. Open **VS Code Demo Player** from the Windows Start menu.
3. Use **Capture Conversation** for a local saved chat, or **Manage Demos >
   Import Recording** for an exported `.demo-recording.json` package.
4. Select the demo and press **Play**. The app opens its own isolated VS Code
   window automatically; you do not need to open VS Code first.

Requires x64 Windows 10/11 and compatible desktop VS Code 1.140 or later.
Node.js is bundled: no npm, PowerShell commands, or repository checkout are
needed to use the installed app. Install VS Code separately from
https://code.visualstudio.com/ if it is not already available. Standard user
and system-wide installations are detected. Proposed APIs make compatibility
version-sensitive; a newer VS Code build is not automatically certified.

The repository is private, so downloads require an authorized GitHub account.
The initial installer is unsigned; Windows may show an unknown-publisher
warning. Follow your organization's software policy.

Upgrade by running the newer installer after closing Demo Player. Uninstall
through Windows **Installed apps** or its Start menu uninstaller. Neither
operation deletes your demo library at
`%LOCALAPPDATA%\VSCodeDemoPlayer\demos`, nor changes your normal VS Code
profile. Recordings and private conversation data are not shipped.

Local recorded-conversation playback in an isolated, native VS Code window,
with a compact Windows Play/Pause/Stop controller.

This private repository isolates the reusable playback tooling from its
original application project. It contains no original conversations, demo
selections, application source, recorded assets, or generated evidence.
The original workspace remains untouched.

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

The controller opens without a project or selected recording. Use **Capture
Conversation** to discover saved conversations from standard VS Code workspace
storage. Select a session and Load, browse to a native JSONL transcript from
another profile, or paste its path and Load.
Discovery shows project, date, and initial-snapshot titles/opening prompts
using at most 1 MiB per source for previews. Unavailable previews are labeled;
Load always reconstructs and validates the full final saved conversation.

Select up to 100 exchanges with Ctrl/Shift, inspect their full saved payloads
(including tool data), give the demo a title, acknowledge the privacy/asset
notice, and Save Demo. UI capture follows source order; the underlying capture
API also accepts explicitly ordered distinct indices. Partial or unsupported
exchanges are marked unavailable with a reason; nothing is silently dropped.
If the source changes after preview, reload and review it before capture.

The selected-demo button and **Manage Demos** open a custom searchable library,
not a system dropdown. Select, rename, delete, import, or export a recording.
Delete requires confirmation and affects only that library copy. Exports never
overwrite an existing destination, even after the standard save dialog's
overwrite confirmation; choose a new filename.

**Play** launches a dedicated VS Code window and starts the first exchange once
ready. After each answer, Play advances the next exchange; Pause/Resume freezes
the current timeline. **Stop** closes only the isolated replay window and leaves
Demo Player ready to run again. Closing Demo Player stops its paired window
before exiting. A completed demo stays visible until Stop.

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
records with identifiers, and known internal metadata. Saved question/edit and
other richer parts are refused explicitly, not converted to approximate tools
or silently omitted. External images, links, files, and workspace state are
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
assets for a `v<version>` tag. The stable download URL above follows the newest
published non-prerelease version. No code-signing certificate is configured.

Startup errors are displayed and saved to
`%LOCALAPPDATA%\VSCodeDemoPlayer\last-startup-error.log`. To check dependency
resolution without opening a UI, run
`powershell.exe -NoProfile -File .\Start-InstalledPlayer.ps1 -Check`
from the installed directory.

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
