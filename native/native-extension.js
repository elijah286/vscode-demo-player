const vscode = require('vscode');
const { readRecordings, readPlaylist, validateEditorRecording, PlaybackClock, promptTimeline, responseTimeline, PROMPT_DURATION, RESPONSE_DURATION } = require('./replay');
const { createControlServer } = require('./control-server');
const { RecordingAgentHost } = require('./recording-agent-host');
const { NativeComposer } = require('./native-composer');
const { packageRecordings } = require('./demo-library');
const { nativeResponsePart } = require('./native-response');

function activate(context) {
    if (process.env.HISTORY_REPLAY_SUMMARY_ENTRY || process.env.HISTORY_REPLAY_SUMMARY_INBOX) {
        const { activateSummaryAuthoring, activateSummaryInbox } = require('./prompt-summary-authoring');
        const authoring = process.env.HISTORY_REPLAY_SUMMARY_INBOX
            ? activateSummaryInbox(context, vscode, process.env.HISTORY_REPLAY_SUMMARY_INBOX)
            : activateSummaryAuthoring(context, vscode, process.env.HISTORY_REPLAY_SUMMARY_ENTRY);
        void vscode.commands.executeCommand('setContext', 'demoPlayer.summaryAuthoring', true)
            .then(() => process.env.HISTORY_REPLAY_SUMMARY_INBOX ? undefined : authoring.run(),
                error => vscode.window.showErrorMessage('Prompt summary authoring could not start: ' + error.message, { modal: true }));
        return authoring;
    }
    const capabilities = {
        nativeSessions: typeof vscode.chat.registerChatSessionContentProvider === 'function',
        nativeToolParts: typeof vscode.ChatToolInvocationPart === 'function',
        nativeThinkingParts: typeof vscode.ChatResponseThinkingProgressPart === 'function',
        nativeSessionController: typeof vscode.chat.createChatSessionItemController === 'function'
    };
    context.subscriptions.push(vscode.commands.registerCommand('historyReplay.probe', () => capabilities));
    const state = { phase: 'idle', windowMode: process.env.HISTORY_REPLAY_AGENTS === '1' ? 'Agents' : 'Editor', recording: undefined, recordings: [], turnIndex: 0, history: [], clock: undefined, typed: [], emitted: [], loaded: [] };
    let controlServer;
    let controlReady;
    let recordingHost;
    let recordingEndpoint;
    let nativeComposer;
    const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1000);
    status.text = '$(history) Historical replay | No live execution';
    status.tooltip = 'Recorded transcript playback. No model requests, tool execution, or file edits.';
    status.command = 'historyReplay.pause';
    context.subscriptions.push(status);
    const participant = vscode.chat.createChatParticipant('history-replay.player', async () => {
        throw new Error('This player accepts historical recordings only; live requests are disabled.');
    });
    context.subscriptions.push(participant);
    const controller = vscode.chat.createChatSessionItemController('history-replay', async () => {});
    context.subscriptions.push(controller);

    async function openReplaySession() {
        if (process.env.HISTORY_REPLAY_AGENTS === '1') {
            throw new Error('Agents middle-pane playback is not integrated. Replay is blocked rather than opening the right-hand editor or submitting to Copilot.');
        }
        await vscode.commands.executeCommand('workbench.action.chat.openNewSessionSidebar.history-replay');
    }

    function nativeEvent(event) {
        return nativeResponsePart(vscode, event);
    }

    function savedHistory(recording = state.recording) {
        const parts = responseTimeline(recording.request.response)
            .filter(event => event.kind !== 'toolPending')
            .map(nativeEvent);
        return [
            new vscode.ChatRequestTurn(recording.request.message.text, undefined, [], 'history-replay.player', []),
            new vscode.ChatResponseTurn2(parts, {}, 'history-replay.player')
        ];
    }

    async function streamRecording(stream, token) {
        const cancellation = token.onCancellationRequested(() => state.clock.stop());
        try {
            for (const event of responseTimeline(state.recording.request.response)) {
                await state.clock.waitUntil(state.responseOrigin + event.at);
                stream.push(nativeEvent(event));
                if (event.kind === 'markdown') state.emitted.push({ kind: 'markdown', value: event.value });
                else if (event.kind === 'thinking') state.emitted.push({ kind: 'thinking', value: event.part.value });
                else if (event.kind === 'toolComplete') state.emitted.push({ kind: 'toolInvocationSerialized', toolCallId: event.part.toolCallId });
                else if (event.kind !== 'toolPending') state.emitted.push({ kind: event.kind, original: event.part });
            }
            await state.clock.waitUntil(state.responseOrigin + RESPONSE_DURATION);
            state.metrics.responseFinished = performance.now();
            state.resolveResponse();
        } catch (error) {
            state.phase = state.stopRequested ? 'stopped' : 'error';
            if (!state.stopRequested) state.error = error.message;
            state.rejectResponse(error);
        } finally {
            cancellation.dispose();
            status.text = '$(history) Historical replay | ' + state.phase;
        }
    }

    context.subscriptions.push(vscode.chat.registerChatSessionContentProvider('history-replay', {
        provideChatSessionContent(resource) {
            state.loaded.push(resource.toString());
            if (state.phase !== 'response') return {
                title: state.recordings[0]?.request.message.text.slice(0, 65) ?? '',
                history: state.history,
                requestHandler: async () => { throw new Error('Use the replay controls; live submission is disabled.'); }
            };
            return {
                title: state.recording.request.message.text.slice(0, 65),
                history: [...state.history, new vscode.ChatRequestTurn(state.recording.request.message.text, undefined, [], 'history-replay.player', [])],
                requestHandler: undefined,
                activeResponseCallback: streamRecording
            };
        }
    }, participant));

    async function prepare(file, requestIndex = 0, requestCount = 1) {
        state.presentationRun = (state.presentationRun ?? 0) + 1;
        if (['loading', 'typing', 'response', 'stopping'].includes(state.phase)) throw new Error('A replay is already active.');
        state.phase = 'loading';
        state.stopRequested = false;
        state.error = undefined;
        try {
            state.recordings = process.env.HISTORY_REPLAY_DEMO
                ? await packageRecordings(process.env.HISTORY_REPLAY_DEMO)
                : process.env.HISTORY_REPLAY_PLAYLIST ? await readPlaylist(process.env.HISTORY_REPLAY_PLAYLIST) : await readRecordings(file, requestIndex, requestCount);
            if (recordingEndpoint) {
                await recordingEndpoint.close();
                recordingEndpoint = undefined;
                recordingHost = undefined;
            }
            if (process.env.HISTORY_REPLAY_AGENTS !== '1') state.recordings.forEach(validateEditorRecording);
            const resumeTurn = Number(process.env.HISTORY_REPLAY_RESUME_TURN ?? '0');
            if (!Number.isInteger(resumeTurn) || resumeTurn < 0 || resumeTurn > state.recordings.length) throw new Error('Resume turn is outside the selected recording.');
            state.selection = { file, requestIndex, requestCount, playlistPath: process.env.HISTORY_REPLAY_PLAYLIST, demoPath: process.env.HISTORY_REPLAY_DEMO };
            state.turnIndex = resumeTurn;
            state.history = state.windowMode === 'Editor'
                ? state.recordings.slice(0, resumeTurn).flatMap(savedHistory)
                : state.recordings.slice(0, resumeTurn).flatMap(recording => [recording.request.message, { originalResponse: recording.request.response }]);
            state.phase = resumeTurn === state.recordings.length ? 'complete' : resumeTurn ? 'review' : 'ready';
        } catch (error) {
            state.phase = 'error';
            throw error;
        }
    }

    async function playNext(options = {}) {
        if (!['ready', 'review'].includes(state.phase)) throw new Error('The script is not waiting for its next turn.');
        if (process.env.HISTORY_REPLAY_AGENTS === '1') return playNextInMiddlePane(options);
        state.recording = state.recordings[state.turnIndex];
        state.clock = new PlaybackClock(1);
        state.typed = [];
        state.emitted = [];
        state.metrics = { typingUpdates: [] };
        state.phase = 'typing';
        status.text = '$(history) Historical replay | Typing recorded prompt';
        try {
            await openReplaySession();
            await vscode.commands.executeCommand('notifications.clearAll');
            const prompt = state.recording.request.message.text;
            if (!nativeComposer) {
                nativeComposer = new NativeComposer();
                await nativeComposer.connect(Number(process.env.HISTORY_REPLAY_CDP_PORT), 'Editor');
                    const composer = nativeComposer;
                    context.subscriptions.push({ dispose: () => { composer.close().catch(console.error); } });
            }
            await nativeComposer.focus();
            const typingOrigin = state.clock.now();
            state.metrics.typing = await nativeComposer.typePrompt(prompt, PROMPT_DURATION, state.clock);
            state.typed = [...promptTimeline(prompt)].map(event => event.text);
            state.metrics.typingUpdates = state.metrics.typing.frames.map(frame => frame.elapsed);
            await state.clock.waitUntil(typingOrigin + PROMPT_DURATION);
            state.responseOrigin = state.clock.now();
            state.metrics.promptFinished = performance.now();
            if (options.afterTyping) await options.afterTyping();
            state.phase = 'response';
            status.text = '$(history) Historical replay | Streaming recorded response';
            const response = new Promise((resolve, reject) => {
                state.resolveResponse = resolve;
                state.rejectResponse = reject;
            });
            await openReplaySession();
            await response;
            state.history.push(...savedHistory());
            state.turnIndex++;
            state.phase = state.turnIndex < state.recordings.length ? 'review' : 'complete';
            status.text = '$(history) Historical replay | ' + (state.phase === 'review' ? 'Review - Play for next turn' : 'Finished');
            return { fingerprint: state.recording.fingerprint, prompt, parts: state.emitted.length, metrics: state.metrics };
        } catch (error) {
            state.clock.stop();
            state.phase = state.stopRequested ? 'stopped' : 'error';
            if (!state.stopRequested) state.error = error.message;
            status.text = '$(history) Historical replay | ' + (state.stopRequested ? 'Stopped' : 'Error');
            throw error;
        }
    }

    async function play(file, requestIndex = 0, options = {}) {
        await prepare(file, requestIndex, options.requestCount ?? 1);
        return playNext(options);
    }

    async function restart() {
        if (!['review', 'complete'].includes(state.phase)) throw new Error('Start Over is available only after an exchange completes.');
        state.presentationRun = (state.presentationRun ?? 0) + 1;
        state.phase = 'loading';
        if (recordingEndpoint) {
            await recordingEndpoint.close();
            recordingEndpoint = undefined;
            recordingHost = undefined;
        }
        if (nativeComposer) {
            await nativeComposer.close();
            nativeComposer = undefined;
        }
        state.clock?.stop();
        state.clock = undefined;
        state.turnIndex = 0;
        state.history = [];
        state.typed = [];
        state.emitted = [];
        state.error = undefined;
        state.phase = 'ready';
        return playNext();
    }

    async function waitForHost(predicate, message) {
        let timer;
        let check;
        try {
            await new Promise((resolve, reject) => {
                timer = setTimeout(() => reject(new Error(message)), 15000);
                check = setInterval(() => { if (predicate()) resolve(); }, 50);
            });
        } finally {
            clearTimeout(timer);
            clearInterval(check);
        }
    }

    function publishHostEvent(event, identities, turnIndex) {
        if (!identities.has(event.part)) identities.set(event.part, 'recorded-' + turnIndex + '-' + identities.size);
        const id = identities.get(event.part);
        if (event.kind === 'markdown') {
            recordingHost.appendDelta(id, event.value);
            return { kind: 'markdown', value: event.value };
        }
        if (event.kind === 'thinking') {
            recordingHost.appendPart({ kind: 'reasoning', id, content: Array.isArray(event.part.value) ? event.part.value.join('') : event.part.value });
            return { kind: 'thinking', value: event.part.value };
        }
        if (event.kind === 'toolPending') {
            const part = event.part;
            recordingHost.appendPart({ kind: 'toolCall', toolCall: { toolCallId: part.toolCallId, toolName: part.toolId, displayName: part.toolId, status: 'running', invocationMessage: typeof part.invocationMessage === 'string' ? part.invocationMessage : { markdown: part.invocationMessage?.value ?? '' } } });
        } else if (event.kind === 'toolComplete') {
            const part = event.part;
            recordingHost.completeTool(part.toolCallId, { success: !part.isError, pastTenseMessage: typeof part.pastTenseMessage === 'string' ? part.pastTenseMessage : { markdown: part.pastTenseMessage?.value ?? '' } });
            return { kind: 'toolInvocationSerialized', toolCallId: part.toolCallId };
        } else {
            recordingHost.appendSavedPart(event.part);
            return { kind: event.kind, original: event.part };
        }
    }

    async function connectMiddlePane() {
        if (!recordingHost) {
            recordingHost = new RecordingAgentHost(state.recordings);
            for (const [index, recording] of state.recordings.slice(0, state.turnIndex).entries()) {
                recordingHost.beginTurn(recording.request);
                const identities = new Map();
                for (const event of responseTimeline(recording.request.response)) publishHostEvent(event, identities, index);
                recordingHost.finishTurn(RESPONSE_DURATION);
            }
            const endpoint = await recordingHost.start();
            recordingEndpoint = endpoint;
            context.subscriptions.push({ dispose: () => { endpoint.close().catch(console.error); } });
            const configuration = vscode.workspace.getConfiguration('chat');
            await configuration.update('remoteAgentHostsEnabled', true, vscode.ConfigurationTarget.Global);
            await configuration.update('remoteAgentHosts', [{ name: state.recordings[0]?.responderName || 'Recorded conversation', address: recordingEndpoint.address, connectionToken: recordingEndpoint.connectionToken }], vscode.ConfigurationTarget.Global);
            await waitForHost(() => recordingHost.observedMethods.includes('listSessions'), 'Native Agents did not load the recorded-session inventory.');
        }
        const resource = recordingHost.sessions[0].resource;
        await vscode.commands.executeCommand('vscode.open', vscode.Uri.parse('agent-host-session://historical-replay/' + resource.slice(resource.lastIndexOf('/') + 1)));
        await waitForHost(() => recordingHost.observedSubscriptions.includes(recordingHost.chatResource), 'Native Agents did not open the recorded middle-pane conversation.');
    }

    async function playNextInMiddlePane(options) {
        await connectMiddlePane();
        await vscode.commands.executeCommand('notifications.clearAll');
        if (!nativeComposer) {
            nativeComposer = new NativeComposer();
            await nativeComposer.connect(Number(process.env.HISTORY_REPLAY_CDP_PORT));
                const composer = nativeComposer;
                context.subscriptions.push({ dispose: () => { composer.close().catch(console.error); } });
        }
        await nativeComposer.focus();
        state.recording = state.recordings[state.turnIndex];
        state.clock = new PlaybackClock(1);
        state.typed = [];
        state.emitted = [];
        state.metrics = { typingUpdates: [] };
        state.phase = 'typing';
        const prompt = state.recording.request.message.text;
        try {
            const origin = state.clock.now();
            state.metrics.typing = await nativeComposer.typePrompt(prompt, PROMPT_DURATION, state.clock);
            state.typed = [...promptTimeline(prompt)].map(event => event.text);
            state.metrics.typingUpdates = state.metrics.typing.frames.map(frame => frame.elapsed);
            await state.clock.waitUntil(origin + PROMPT_DURATION);
            state.responseOrigin = state.clock.now();
            state.metrics.promptFinished = performance.now();
            if (options.afterTyping) await options.afterTyping();
            state.phase = 'response';
            await state.clock.waitUntil(state.responseOrigin + 100);
            await nativeComposer.clear();
            recordingHost.beginTurn(state.recording.request);
            const identities = new Map();
            for (const event of responseTimeline(state.recording.request.response)) {
                await state.clock.waitUntil(state.responseOrigin + event.at);
                const emitted = publishHostEvent(event, identities, state.turnIndex);
                if (emitted) state.emitted.push(emitted);
            }
            await state.clock.waitUntil(state.responseOrigin + RESPONSE_DURATION);
            recordingHost.finishTurn(RESPONSE_DURATION);
            state.metrics.responseFinished = performance.now();
            state.history.push(state.recording.request.message, { originalResponse: state.recording.request.response });
            state.turnIndex++;
            state.phase = state.turnIndex < state.recordings.length ? 'review' : 'complete';
            return { fingerprint: state.recording.fingerprint, prompt, parts: state.emitted.length, metrics: state.metrics };
        } catch (error) {
            state.clock.stop();
            state.phase = 'error';
            throw error;
        }
    }

    context.subscriptions.push(vscode.commands.registerCommand('historyReplay.play', play));
    async function startSelected() {
        if (['ready', 'review'].includes(state.phase) && state.recordings.length) return playNext();
        if (state.phase === 'complete') throw new Error('The selected script has finished. Stop closes the replay pair.');
        const file = process.env.HISTORY_REPLAY_FILE;
        if (!file) throw new Error('Launch this isolated player with Start-Replay.ps1 to select the source transcript.');
        return play(file, Number(process.env.HISTORY_REPLAY_REQUEST ?? '3'), { requestCount: Number(process.env.HISTORY_REPLAY_REQUEST_COUNT ?? '1') });
    }
    async function closePlayer() {
        state.stopRequested = true;
        state.phase = 'stopping';
        state.clock?.stop();
        await vscode.commands.executeCommand('workbench.action.closeWindow');
    }
    context.subscriptions.push(vscode.commands.registerCommand('historyReplay.start', startSelected));
    context.subscriptions.push(vscode.commands.registerCommand('historyReplay.pause', () => {
        if (state.clock) {
            state.clock.setPaused(!state.clock.paused);
            status.text = '$(history) Historical replay | ' + (state.clock.paused ? 'Paused' : state.phase);
        }
    }));
    context.subscriptions.push(vscode.commands.registerCommand('historyReplay.step', () => state.clock?.step()));
    context.subscriptions.push(vscode.commands.registerCommand('historyReplay.stop', () => {
        if (controlServer) return closePlayer();
        state.clock?.stop();
    }));
    if (process.env.HISTORY_REPLAY_CONTROL_PATH) {
        controlReady = (async () => {
            await prepare(process.env.HISTORY_REPLAY_FILE, Number(process.env.HISTORY_REPLAY_REQUEST ?? '3'), Number(process.env.HISTORY_REPLAY_REQUEST_COUNT ?? '1'));
            if (process.env.HISTORY_REPLAY_AGENTS === '1') await connectMiddlePane();
            else await openReplaySession();
            await vscode.commands.executeCommand('notifications.clearAll');
            status.text = '$(history) Historical replay | Ready';
            controlServer = await createControlServer({
                controlPath: process.env.HISTORY_REPLAY_CONTROL_PATH,
                getState: () => state,
                play: startSelected,
                next: playNext,
                restart,
                pause: () => state.clock?.setPaused(true),
                resume: () => state.clock?.setPaused(false),
                stop: closePlayer,
                onError: error => {
                    if (state.phase !== 'stopping' && state.phase !== 'stopped') {
                        state.phase = 'error';
                        state.error = error.message;
                        status.text = '$(history) Historical replay | Error';
                        console.error('Historical replay controller:', error);
                    }
                }
            });
            context.subscriptions.push({ dispose: () => { controlServer.close().catch(console.error); } });
        })().catch(error => {
            state.phase = 'error';
            status.text = '$(history) Historical replay | Error';
            console.error('Historical replay preparation:', error);
            throw error;
        });
        controlReady.catch(() => {});
    }
    async function startBackendProbe() {
        if (process.env.HISTORY_REPLAY_BACKEND_PROBE !== '1') throw new Error('The native backend probe is available only in an isolated test host.');
        recordingHost = new RecordingAgentHost(state.recordings);
        const endpoint = await recordingHost.start();
        context.subscriptions.push({ dispose: () => { endpoint.close().catch(console.error); } });
        const configuration = vscode.workspace.getConfiguration('chat');
        await configuration.update('remoteAgentHostsEnabled', true, vscode.ConfigurationTarget.Global);
        await configuration.update('remoteAgentHosts', [{ name: state.recordings[0]?.responderName || 'Recorded conversation', address: endpoint.address, connectionToken: endpoint.connectionToken }], vscode.ConfigurationTarget.Global);
        return recordingHost;
    }
    return { capabilities, state, play, prepare, playNext, restart, controlReady, startBackendProbe };
}

function deactivate() {}

module.exports = { activate, deactivate };