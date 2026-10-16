# Canonical consolidation checkpoint

## Release 0.2.5 integration

The user subsequently authorized integrating all fleet work directly into
`main`, pushing and publishing, confirmed other writers were paused, and
approved a local source checkpoint with ignored files preserved in place.
The seven uncommitted capture-fix files were checkpointed as `5769cf1`.
Local `main` was then fast-forwarded to that complete candidate; no source
changes were discarded and no fleet branches were deleted.

All delivered branch tips are ancestors of the candidate: SDK recovery
`deb7c2f`, conversation import `6793f79`, history catalog `0cb98e9`, replay
controls `5380369`, consolidation `086ca2f`, and capture fix `5769cf1`.
The latter selects only capturable exchanges by default, keeps unavailable
exchanges inspectable, gates Save on valid reviewed selections, and identifies
missing saved fields without changing source transcripts.

Fresh pre-publication validation used Node.js 22.23.3 and the existing local
locked dependencies. Commands below use `$node` for that runtime, `$compiler`
for the signature-verified Inno Setup 6.7.3 compiler, and private external
`$cache`, `$output`, and `$payload` locations:

| Command | Result |
| --- | --- |
| `npm run test:unit` (from `native`) | 78 passed, 0 failed |
| `npm run lint` (from `native`) | 0 errors; 4 existing browser-global warnings |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test\packaging.ps1 -NodePath $node` | 39 assertions passed |
| `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\test\history-filters.ps1` | 84 assertions passed; no desktop window displayed |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\Build-Windows.ps1 -InnoCompiler $compiler -CacheRoot $cache -OutputRoot $output` | Installer and checksum built successfully |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$payload\Start-InstalledPlayer.ps1" -Check` | Packaged Node/VS Code dependency preflight passed |

Packaged version, runtime-source hash parity, recording exclusion, and
development-dependency exclusion also passed. The first local build correctly
refused a missing compiler; provisioning the signature-verified compiler
resolved it. VS Code's test-discovery tool did not recognize the Node tests,
so the actual repository `npm run test:unit` selector ran instead.

The capture-fix owner recorded the user's decision to skip fresh desktop
acceptance. No new native UI, installer execution, or real installed-upgrade
acceptance is claimed here. The existing user installation and demo library
remain untouched. Publication must still verify CI for the release SHA,
public asset checksums/digests, and real updater discovery/download.
Main was unprotected and no repository rulesets were configured at inspection;
direct integration follows the user's instruction, not an enforced PR gate.

The sections below describe the earlier consolidation checkpoint and its
then-current authorization and environment limitations, not the later release.

## Scope and history

The approved 2026-10-16 consolidation uses the existing `vscode-demo-player`
checkout of `https://github.com/elijah286/vscode-demo-player.git`. Local work
is on `integration/canonical-consolidation`, tracking `origin/main`.
The original local `main` pointer is preserved; it was not rewritten or merged.

| Checkpoint | SHA | Treatment |
| --- | --- | --- |
| Original canonical main | `0bbad2f27866e868861fc18ee7207d2215b8a255` | Preserved |
| Approved GitHub main | `aa653dc2324898a7cfda3155e2d718672ab1c14b` | Integration baseline |
| SDK capture recovery | `deb7c2f7a39db45b116f78f19ce70a9aa408d07e` | Merged once |
| Integration merge | `e84e09b7331ec90993889a6118f3aa1320a847f3` | Both approved parents retained |
| Playback/workflow implementation | `4917e1373bd0558a417eb3c0f1919091466aae0c` | Tested source checkpoint |

The sibling conversation-import (`6793f79`), history-catalog (`0cb98e9`), and
replay-controls (`5380369`) tips were already ancestors of the approved remote
baseline. Their features were retained, not cherry-picked again. The new SDK
recovery commit preserves interrupted exchange text/reasoning and raw tool
events without inventing successful completion; it also adds Select available.

The controller now opens its isolated target separately from playback. Play
requires readiness. After an exchange, Start Over restarts the entire selected
demo, Next Step advances one prompt/response exchange, and Stop closes only the
paired target. Next Step is disabled after the final exchange. Launch failures,
readiness timeouts, playback errors, and target closure remain explicit failures.
The keyboard Step command still advances a single timed event.

## Preservation

All five source folders had private snapshots verified by per-file SHA-256,
plus a verified complete all-refs Git bundle and local configuration backup,
before integration. Snapshot manifests record branches, HEADs, working status,
ignored files, and junction targets. Their private absolute locations are kept
outside source control and reported to the user.

Three legacy dependency directories were junctions into the original application
project. Their links were preserved without traversing or modifying the target.
The canonical checkout received independent dependencies from its lockfile.
No recordings, settings, unrelated workspace, installed app, or global
VS Code/MCP configuration was intentionally changed. A generated PowerShell
module-analysis cache was preserved outside source and narrowly ignored.

No sibling folders, branches, stashes, backups, or remote branches were deleted.
Cleanup requires separate approval after confirming the exact paths, current
status, reachable commits, and preservation evidence. Use Git's registered
worktree removal commands without force; retain branches/backups unless their
deletion is separately approved.

## Verification

Toolchain: Windows, Windows PowerShell 5.1, official Node.js 22.23.3 x64 (archive
SHA-256 verified against the build's pin), npm 10.9.9, and the installed desktop
VS Code. Dependencies were installed locally with
`npm ci --ignore-scripts --no-audit --no-fund`; no lockfile changes were needed.

The following commands ran against the implementation content in `4917e13`.
Run npm commands from `native`; PowerShell commands from the checkout root.
`$node` denotes the verified Node executable and `$evidence` an external private
output directory. Native tests used the controller harness's synthetic
`synthetic-source.jsonl`, request zero, the canonical extension path, explicit
unique temporary profiles, `HISTORY_REPLAY_AGENTS=0`, and
`HISTORY_REPLAY_BACKEND_PROBE=0`.

| Command | Result |
| --- | --- |
| `npm run test:unit` | 76 passed, 0 failed |
| `npm run lint` | 0 errors; 4 existing browser-global warnings |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File test/packaging.ps1 -NodePath $node` | 39 assertions passed |
| `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File test/history-filters.ps1` | 54 assertions passed |
| `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File test/controller-ui.ps1 -NodePath $node -EvidenceRoot $evidence` | Fresh combined native/SDK capture, library, and controller UI acceptance passed |
| `npm test` | Fresh native content/timing/history and Start Over acceptance passed |
| `npm run test:references:native` | Fresh native inline-reference and retained-history acceptance passed |
| `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File test/presentation-ui.ps1 -EvidenceRoot $evidence` | Fresh Editor overlay/frame/timer/pause acceptance passed |
| `powershell.exe -NoProfile -ExecutionPolicy Bypass -File packaging/Build-Windows.ps1 -CacheRoot $cache -OutputRoot $output` | Blocked: Inno Setup 6 compiler missing; no installer produced |

The UI harness verified Open without autoplay, explicit Play, pause/resume,
Next Step, final-step disabling, Start Over returning to exchange one, scoped
Stop, target closure/reopen, paused closure, persistent synthetic libraries, and
unchanged edit targets. Selection of 100 large exchanges remained responsive
(maximum measured individual selection 17.2 ms against the 250 ms limit).
Native prompt entry measured 2001.3/2000.7 ms and responses 5015.9/5012.0 ms.

Launch/timeout/closure fault assertions execute the production controller
handlers with synthetic dependencies; they are not real OS launch-failure
experiments. An initial screen-capture failure was resolved after desktop
availability was confirmed. An initial native-test launch with an empty profile
environment value was corrected by assigning explicit unique test profiles.
Neither failed attempt is counted as acceptance.

## Exclusions and remaining gates

- Authenticated experimental Agents UI switching was not run: no dedicated,
  signed-in test profile was supplied. Existing limitations/guards remain.
- Installer build is blocked by missing Inno Setup 6. Installed-app replacement,
  installer/upgrade acceptance, and publication were not authorized or performed.
- No push, GitHub PR merge, release tag, or publication was performed.
- Legacy source folders and all recovery material remain in place pending
  explicit cleanup approval. Guidance is a workflow convention, not a security
  mechanism that can prevent every external agent from creating another checkout.