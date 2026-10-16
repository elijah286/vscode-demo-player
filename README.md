# VS Code Demo Player

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

The standalone library, Capture Conversation dialog, portable demo packages,
and import/rename/delete workflow are **not implemented yet**. This extraction
is the baseline for that work, not a claim that those features are finished.

## Requirements

- Windows PowerShell 5.1 with WPF.
- A compatible desktop VS Code installed under
  `%LOCALAPPDATA%\Programs\Microsoft VS Code\Code.exe`.
- Node.js 22.16 or newer and npm.
- Access to a saved native VS Code chat transcript.

The extension uses proposed VS Code APIs. Its declared minimum is VS Code
1.140; compatibility with each installed build requires a native test.
Agents mode is experimental and retains its existing integration guard.
Use Editor mode for the baseline player.

## Setup and playback

```powershell
Set-Location .\native
npm ci
Set-Location ..
.\Start-Replay.ps1 -SessionPath 'C:\Recordings\conversation.jsonl' -RequestIndex 0 -RequestCount 2
```

Both windows prepare before playback. Play advances the selected exchange;
after an answer, the controller waits for the next Play. Stop or closing the
controller closes its isolated replay window, not your working editor.
The current controller exits with that replay session; persistent library
management is planned.

Never install this development extension in your normal VS Code profile.
The launcher supplies a dedicated temporary profile and extension directory.

Existing local playlist manifests can be supplied using `-PlaylistPath`.
They refer to native workspace-storage session IDs on the same computer;
they are not portable packages. No machine-specific default playlist is used.

## Export helper

```powershell
.\Export-OriginalChat.ps1 -SessionPath 'C:\Recordings\conversation.jsonl' -OutputPath 'C:\Recordings\excerpt.native-chat.json' -RequestCount 2
```

This legacy helper exports complete requests from the **first snapshot only**.
It does not implement the proposed portable package or reconstruct later
updates. The playback reader reconstructs updates separately.

## Validation

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

At extraction, all 23 unit tests and PowerShell syntax checks passed. ESLint
reported four existing browser-global warnings in `native-composer.js`
(`document`, `requestAnimationFrame`, and `TextUpdateEvent`). A strict
zero-warning lint gate therefore does not pass. Native visual playback was
not rerun as part of repository isolation.

## Layout

- [Start-Replay.ps1](Start-Replay.ps1): isolated VS Code and controller launcher.
- [Show-ReplayController.ps1](Show-ReplayController.ps1): compact WPF popup.
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
