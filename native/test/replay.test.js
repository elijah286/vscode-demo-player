const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const vm = require('node:vm');
const { readRecording, readRecordings, readPlaylist, readSnapshot, applyTranscriptRecord, recordedModel, validateEditorRecording, PlaybackClock, promptTimeline, responseTimeline, PROMPT_DURATION, RESPONSE_DURATION } = require('../replay');
const { controlView, createControlServer } = require('../control-server');
const { RecordingAgentHost } = require('../recording-agent-host');
const { WebSocket } = require('ws');
const { completedQuestions, archivedEdit, INTERNAL_PARTS, validateSavedEditGroup, savedEditText, savedEditMarkdown } = require('../saved-parts');

async function fixture(context, request) {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'replay-unit-'));
    context.after(() => fs.rm(directory, { recursive: true, force: true }));
    const file = path.join(directory, 'recording.jsonl');
    await fs.writeFile(file, JSON.stringify({ kind: 0, v: { sessionId: 'unit-fixture', requests: [request] } }) + '\n');
    return file;
}

test('keeps the exact saved request and assistant text', async context => {
    const request = { result: {}, message: { text: 'Original\r\nprompt' }, response: [{ value: '**Original** answer\r\n', supportHtml: true }] };
    const file = await fixture(context, request);
    const before = await fs.readFile(file);
    const recording = await readRecording(file, 0);
    assert.deepEqual(recording.request, request);
    assert.equal(recording.fingerprint, crypto.createHash('sha256').update(JSON.stringify(request)).digest('hex'));
    assert.deepEqual(await fs.readFile(file), before);
});

test('refuses incomplete requests and unsupported edit records', async context => {
    const incomplete = await fixture(context, { message: { text: 'Incomplete' }, response: [] });
    await assert.rejects(readRecording(incomplete, 0), /incomplete/);
    const unsupported = await fixture(context, { result: {}, message: { text: 'Edit' }, response: [{ kind: 'unknownRecordedKind' }] });
    await assert.rejects(readRecording(unsupported, 0), /unknownRecordedKind/);
    await assert.rejects(readRecording(unsupported, -1), /nonnegative/);
});

test('incomplete request diagnostics identify missing saved fields without changing the source', async context => {
    const complete = { result: {}, message: { text: 'Saved prompt' }, response: [{ value: 'Saved answer' }] };
    const cases = [
        [null, 'request record'],
        [{ ...complete, result: undefined }, 'completion result'],
        [{ ...complete, message: {} }, 'prompt text'],
        [{ ...complete, response: undefined }, 'response array'],
        [{}, 'completion result, prompt text, response array']
    ];
    for (const [request, missing] of cases) {
        const file = await fixture(context, request);
        const before = await fs.readFile(file);
        await assert.rejects(readRecording(file, 0), error => {
            assert.ok(error.message.includes('Missing: ' + missing + '.'));
            assert.match(error.message, /missing content cannot be reconstructed/);
            return true;
        });
        assert.deepEqual(await fs.readFile(file), before);
    }
    const file = await fixture(context, complete);
    await assert.rejects(readRecording(file, 1), /Missing: request record\./);
});

test('a paused clock advances exactly one wait when stepped', { timeout: 1000 }, async () => {
    const clock = new PlaybackClock(8);
    clock.setPaused(true);
    const waiting = clock.wait(10000);
    assert.equal(clock.listeners.size, 1);
    clock.step();
    await waiting;
    assert.equal(clock.paused, true);
    assert.equal(clock.steps, 0);
    assert.equal(clock.listeners.size, 0);
});

test('stop cancels a paused wait and clears its timer', { timeout: 1000 }, async () => {
    const clock = new PlaybackClock();
    clock.setPaused(true);
    const waiting = assert.rejects(clock.wait(10000), /Replay stopped/);
    clock.stop();
    await waiting;
    assert.equal(clock.listeners.size, 0);
});

test('speed is finite and bounded', () => {
    assert.throws(() => new PlaybackClock(0), /Speed/);
    const clock = new PlaybackClock(4);
    assert.ok(Number.isFinite(clock.now()));
    assert.throws(() => clock.setSpeed(Infinity), /Speed/);
    assert.throws(() => clock.setSpeed(33), /Speed/);
    clock.setSpeed(16);
    assert.equal(clock.speed, 16);
});

test('controller maps ready, playing, paused, and finished without auto-closing', () => {
    assert.equal(controlView({ phase: 'ready' }).action, 'play');
    assert.equal(controlView({ phase: 'review' }).action, 'restart');
    assert.equal(controlView({ phase: 'typing', clock: { paused: false } }).action, 'pause');
    assert.equal(controlView({ phase: 'response', clock: { paused: true } }).action, 'resume');
    const finished = controlView({ phase: 'complete', turnIndex: 2, recordings: [{}, {}] });
    assert.equal(finished.button, 'Start Over');
    assert.equal(finished.restartEnabled, true);
    assert.equal(finished.nextEnabled, false);
    const review = controlView({ phase: 'review', turnIndex: 1, recordings: [{}, {}] });
    assert.equal(review.nextEnabled, true);
    assert.equal(review.restartEnabled, true);
    for (const phase of ['ready', 'typing', 'response', 'error', 'stopping']) {
        const view = controlView({ phase, recordings: [{}, {}], turnIndex: 1 });
        assert.equal(view.nextEnabled, false);
        assert.equal(view.restartEnabled, false);
    }
});

test('working-time overlay interpolates response work and excludes user idle gaps', () => {
    const state = {
        phase: 'response', windowMode: 'Editor', turnIndex: 0, responseOrigin: 2000,
        clock: { now: () => 4500 },
        recordings: [
            { promptSummary: 'First prompt.', request: { timestamp: 1000, modelState: { completedAt: 61000 } } },
            { request: { timestamp: 100000000, modelState: { completedAt: 100061000 } } }
        ]
    };
    assert.equal(controlView(state).overlay.elapsed, '00:00:30');
    state.phase = 'review';
    state.turnIndex = 1;
    assert.equal(controlView(state).overlay.elapsed, '00:01:00');
    assert.equal(controlView(state).overlay.promptSummary, 'First prompt.');
    assert.equal(controlView(state).modeSwitchEnabled, true);
    state.phase = 'typing';
    assert.equal(controlView(state).overlay.elapsed, '00:01:00');
    assert.equal(controlView(state).modeSwitchEnabled, false);
    state.phase = 'complete';
    state.turnIndex = 2;
    assert.equal(controlView(state).overlay.elapsed, '00:02:01');
    assert.equal(controlView(state).resumeTurn, 2);
});

test('working-time overlay rejects missing endpoints and does not wrap hours', () => {
    const state = { phase: 'complete', turnIndex: 1, recordings: [{ request: { timestamp: 0, modelState: { completedAt: 360061000 } } }] };
    assert.equal(controlView(state).overlay.elapsed, '100:01:01');
    delete state.recordings[0].request.modelState;
    assert.equal(controlView(state).overlay.elapsed, null);
});

test('conversation advances only on explicit completion, with bounded identities stable over polling and pause', () => {
    const state = { phase: 'ready', presentationRun: 1, turnIndex: 0, recordings: [
        { promptSummary: 'Input1', outputSummary: 'Output1', request: { timestamp: 0, modelState: { completedAt: 60000 } } },
        { promptSummary: 'Input2', outputSummary: 'Output2', request: { timestamp: 70000, modelState: { completedAt: 130000 } } },
        { promptSummary: 'Input3', request: { timestamp: 140000, modelState: { completedAt: 200000 } } }
    ] };
    const read = () => controlView(state).overlay;
    const ready = read().conversation;
    assert.equal(ready.completed, false);
    assert.equal(ready.exchange, 1);
    assert.equal(ready.previousOutputSummary, null);
    state.phase = 'response';
    state.responseOrigin = 0;
    state.clock = { now: () => 5000, paused: false };
    assert.equal(read().elapsed, '00:01:00');
    assert.deepEqual(read().conversation, ready, 'Even 100% elapsed cannot reveal output before response renderer completes');
    state.clock.paused = true;
    assert.deepEqual(read().conversation, ready);
    state.phase = 'review'; state.turnIndex = 1;
    const complete = read().conversation;
    assert.equal(complete.completed, true);
    assert.notEqual(complete.key, ready.key);
    assert.deepEqual(read().conversation, complete);
    state.phase = 'typing';
    assert.equal(read().conversation.previousOutputSummary, 'Output1');
    assert.equal(read().promptSummary, 'Input2');
    assert.equal(read().elapsed, '00:01:00');
    state.phase = 'review'; state.turnIndex = 2;
    assert.equal(read().conversation.outputSummary, 'Output2');
    assert.equal(read().promptSummary, 'Input2');
    state.phase = 'typing';
    assert.equal(read().conversation.previousOutputSummary, 'Output2');
    assert.equal(read().promptSummary, 'Input3');
    state.phase = 'complete'; state.turnIndex = 3;
    assert.equal(read().conversation.outputSummary, null, 'Missing output is explicit, never replaced by the input or invented success');
    for (const phase of ['error', 'stopping', 'stopped']) {
        state.phase = phase; assert.equal(read().conversation.active, false);
    }
    state.phase = 'ready'; state.turnIndex = 0; state.presentationRun++;
    assert.notEqual(read().conversation.key, ready.key);
    assert.equal(read().elapsed, '00:00:00');
    const restarted = read().conversation.key;
    state.recordings[0].fingerprint = 'new selection';
    assert.notEqual(read().conversation.key, restarted, 'A new selection is not confused with the previous process run');
    const selected = read().conversation.key;
    state.recordings[0].outputSummary = 'Reviewed output edit';
    assert.notEqual(read().conversation.key, selected, 'Re-selecting reviewed metadata resets the preview even when original payload identity is unchanged');
});

test('mode changes are exposed only at complete response boundaries', () => {
    const state = { phase: 'review', windowMode: 'Agents', turnIndex: 1, recordings: [{}, {}], selection: { demoPath: 'portable.demo-recording.json' } };
    assert.equal(controlView(state).modeSwitchEnabled, true);
    assert.equal(controlView(state).resumeTurn, 1);
    assert.deepEqual(controlView(state).selection, state.selection);
    for (const phase of ['typing', 'response', 'stopping', 'error']) {
        state.phase = phase;
        assert.equal(controlView(state).modeSwitchEnabled, false);
    }
});

test('prompt preview is a bounded excerpt separate from original recording content', async context => {
    const request = { result: {}, message: { text: '  Exact\r\noriginal ' + 'word '.repeat(80) }, response: [{ value: 'Original answer' }] };
    const file = await fixture(context, request);
    const recording = await readRecording(file, 0);
    assert.equal(recording.promptSummary.length, 300);
    assert.ok(recording.promptSummary.endsWith('...'));
    assert.match(recording.promptSummary, /^Exact original /);
    assert.deepEqual(recording.request, request);
});

test('playlist summaries accept the exact 300-character budget and reject 301 without altering full prompts', async context => {
    const request = { result: {}, message: { text: 'Full original prompt '.repeat(40) }, response: [{ value: 'Original answer' }] };
    const file = await fixture(context, request);
    const directory = path.dirname(file);
    const oldAppData = process.env.APPDATA;
    process.env.APPDATA = directory;
    context.after(() => { if (oldAppData === undefined) delete process.env.APPDATA; else process.env.APPDATA = oldAppData; });
    const workspaceStorageId = 'a'.repeat(32);
    const sessionId = '11111111-1111-1111-1111-111111111111';
    const sessions = path.join(directory, 'Code', 'User', 'workspaceStorage', workspaceStorageId, 'chatSessions');
    await fs.mkdir(sessions, { recursive: true });
    await fs.copyFile(file, path.join(sessions, sessionId + '.jsonl'));
    const playlist = path.join(directory, 'synthetic.playlist.json');
    const manifest = { version: 1, workspaceStorageId, segments: [{ sessionId, requestIndex: 0, requestCount: 1 }], promptSummaries: ['x'.repeat(300)] };
    await fs.writeFile(playlist, JSON.stringify(manifest));
    const [recording] = await readPlaylist(playlist);
    assert.equal(recording.promptSummary, 'x'.repeat(300));
    assert.deepEqual(recording.request, request);
    manifest.outputSummaries = ['o'.repeat(300)];
    await fs.writeFile(playlist, JSON.stringify(manifest));
    assert.equal((await readPlaylist(playlist))[0].outputSummary.length, 300);
    for (const invalid of [['o'.repeat(301)], ['a\nb'], [''], []]) {
        manifest.outputSummaries = invalid;
        await fs.writeFile(playlist, JSON.stringify(manifest));
        await assert.rejects(readPlaylist(playlist), /output summary/);
    }
    manifest.outputSummaries = [null];
    for (const invalid of ['x'.repeat(301), 'a\nb', '']) {
        manifest.promptSummaries = [invalid];
        await fs.writeFile(playlist, JSON.stringify(manifest));
        await assert.rejects(readPlaylist(playlist), /1 to 300 characters/);
    }
});

test('private controller accepts only authorized state-appropriate controls', { timeout: 5000 }, async context => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'replay-control-test-'));
    const state = { phase: 'ready', clock: { paused: false }, recordings: [{}, {}], turnIndex: 0 };
    const invoked = [];
    const errors = [];
    const server = await createControlServer({
        controlPath: path.join(directory, 'control.json'),
        getState: () => state,
        play: () => { state.phase = 'typing'; invoked.push('play'); },
        next: () => { state.phase = 'typing'; invoked.push('next'); },
        restart: () => { state.turnIndex = 0; state.phase = 'typing'; invoked.push('restart'); },
        pause: () => { state.clock.paused = true; invoked.push('pause'); },
        resume: () => { state.clock.paused = false; invoked.push('resume'); },
        stop: () => { state.phase = 'stopping'; invoked.push('stop'); },
        onError: error => errors.push(error)
    });
    context.after(async () => { await server.close(); await fs.rm(directory, { recursive: true, force: true }); });
    const url = 'http://127.0.0.1:' + server.port;
    const headers = { Authorization: 'Bearer ' + server.token };
    const call = (endpoint, options = {}) => fetch(url + endpoint, { headers, signal: AbortSignal.timeout(1500), ...options });
    assert.equal((await fetch(url + '/state', { signal: AbortSignal.timeout(1500) })).status, 401);
    assert.equal((await call('/state', { headers: { ...headers, Origin: 'https://example.com' } })).status, 401);
    assert.equal((await call('/pause', { method: 'POST' })).status, 409);
    assert.equal((await call('/next', { method: 'POST' })).status, 409);
    assert.equal((await call('/restart', { method: 'POST' })).status, 409);
    assert.equal((await call('/play', { method: 'POST' })).status, 202);
    assert.equal((await (await call('/state')).json()).button, 'Pause');
    assert.equal((await call('/play', { method: 'POST' })).status, 409);
    assert.equal((await call('/pause', { method: 'POST' })).status, 202);
    assert.equal((await (await call('/state')).json()).button, 'Resume');
    assert.equal((await call('/resume', { method: 'POST' })).status, 202);
    state.phase = 'review';
    state.turnIndex = 1;
    assert.equal((await call('/next', { method: 'POST' })).status, 202);
    state.phase = 'complete';
    state.turnIndex = 2;
    assert.equal((await (await call('/state')).json()).label, 'Finished');
    assert.equal((await call('/play', { method: 'POST' })).status, 409);
    assert.equal((await call('/next', { method: 'POST' })).status, 409);
    assert.equal((await call('/restart', { method: 'POST' })).status, 202);
    assert.equal(state.turnIndex, 0);
    assert.equal((await call('/restart', { method: 'POST' })).status, 409);
    assert.equal((await call('/stop', { method: 'POST' })).status, 202);
    assert.deepEqual(invoked, ['play', 'pause', 'resume', 'next', 'restart', 'stop']);
    assert.deepEqual(errors, []);
});

test('prompt timeline enters exactly one character per update over two seconds', () => {
    const prompt = 'Original\r\nprompt';
    const timeline = [...promptTimeline(prompt)];
    assert.equal(timeline.length, Array.from(prompt).length);
    assert.equal(timeline[0].at, 0);
    assert.equal(timeline.at(-1).at, PROMPT_DURATION);
    assert.equal(timeline.at(-1).text, prompt);
    for (let index = 1; index < timeline.length; index++) {
        assert.equal(Array.from(timeline[index].text).length, Array.from(timeline[index - 1].text).length + 1);
        assert.ok(timeline[index].at > timeline[index - 1].at);
    }
});

test('response timeline preserves text and native tool transitions within five seconds', () => {
    const text = '**Original** assistant output, unchanged.\r\n';
    const tool = { kind: 'toolInvocationSerialized', toolCallId: 'recorded-tool', isComplete: true };
    const response = [{ value: text }, tool, { kind: 'thinking', value: 'Recorded visible text' }];
    const timeline = responseTimeline(response);
    assert.equal(timeline[0].at, 0);
    assert.equal(timeline.at(-1).at, RESPONSE_DURATION);
    assert.equal(timeline.filter(event => event.kind === 'markdown').map(event => event.value).join(''), text);
    assert.equal(timeline.find(event => event.kind === 'toolPending').part, tool);
    assert.equal(timeline.find(event => event.kind === 'toolComplete').part, tool);
});

test('an entire selected turn range is validated before playback', async context => {
    const request = { result: {}, message: { text: 'Original' }, response: [{ value: 'Original answer' }] };
    const file = await fixture(context, request);
    assert.equal((await readRecordings(file, 0, 1))[0].request.message.text, request.message.text);
    await assert.rejects(readRecordings(file, 0, 2), /absent or incomplete/);
    await assert.rejects(readRecordings(file, 0, 0), /Request count/);
});

test('Agents backend failure cannot fall back to a right-hand editor or submit input', async context => {
    const request = { result: {}, message: { text: 'Original prompt' }, response: [{ value: 'Original answer' }] };
    const file = await fixture(context, request);
    const invoked = [];
    const disposable = { dispose() {} };
    const vscode = {
        StatusBarAlignment: { Left: 0 },
        commands: { registerCommand: () => disposable, executeCommand: async command => { invoked.push(command); } },
        window: { createStatusBarItem: () => ({ show() {}, dispose() {} }) },
        workspace: { getConfiguration: () => ({ update: async () => { throw new Error('Native middle-pane backend configuration unavailable'); } }) },
        ConfigurationTarget: { Global: 1 },
        chat: {
            createChatParticipant: () => disposable,
            createChatSessionItemController: () => disposable,
            registerChatSessionContentProvider: () => disposable
        }
    };
    const module = { exports: {} };
    const sandbox = {
        module,
        require: name => name === 'vscode' ? vscode : require('../' + name.slice(2)),
        process: { env: { HISTORY_REPLAY_AGENTS: '1' } },
        console
    };
    const source = await fs.readFile(path.join(__dirname, '..', 'native-extension.js'), 'utf8');
    vm.runInNewContext(source, sandbox, { filename: 'native-extension.js' });
    const subscriptions = [];
    const api = module.exports.activate({ subscriptions });
    try {
        await assert.rejects(api.play(file, 0), /Native middle-pane backend configuration unavailable/);
    } finally {
        for (const subscription of subscriptions) subscription.dispose();
    }
    assert.deepEqual(invoked, []);
    assert.equal(api.state.typed.length, 0);
});

test('portable demo resume restores completed Editor history without replaying or executing it', async context => {
    const request = { result: {}, message: { text: 'Original packaged prompt' }, response: [{ value: 'Original packaged answer' }, { kind: 'workspaceEdit', edits: [] }] };
    const file = await fixture(context, request);
    const library = require('../demo-library');
    const inspection = await library.inspectTranscript(file);
    const recording = await library.createPackage(file, [0], 'Resume fixture', inspection.sha256);
    const demoPath = path.join(path.dirname(file), 'portable.demo-recording.json');
    await fs.writeFile(demoPath, JSON.stringify(recording));
    const disposable = { dispose() {} };
    const invoked = [];
    let failLaunch = false;
    class Part { constructor(...values) { this.values = values; } }
    class Markdown {
        constructor(value) { this.value = value; }
        appendCodeblock(value) { this.value += value; return this; }
    }
    const vscode = {
        StatusBarAlignment: { Left: 0 },
        MarkdownString: Markdown, ChatResponseMarkdownPart: Part, ChatToolInvocationPart: class extends Part {}, ChatRequestTurn: Part, ChatResponseTurn2: Part,
        commands: { registerCommand: () => disposable, executeCommand: async command => {
            invoked.push(command);
            if (failLaunch) throw new Error('Synthetic target readiness failure');
        } },
        window: { createStatusBarItem: () => ({ dispose() {} }) },
        chat: { createChatParticipant: () => disposable, createChatSessionItemController: () => disposable, registerChatSessionContentProvider: () => disposable }
    };
    const module = { exports: {} };
    const source = await fs.readFile(path.join(__dirname, '..', 'native-extension.js'), 'utf8');
    const env = { HISTORY_REPLAY_DEMO: demoPath, HISTORY_REPLAY_RESUME_TURN: '1' };
    vm.runInNewContext(source, { module, require: name => name === 'vscode' ? vscode : require('../' + name.slice(2)), process: { env }, console });
    const api = module.exports.activate({ subscriptions: [] });
    await api.prepare('');
    assert.equal(api.state.phase, 'complete');
    assert.equal(api.state.turnIndex, 1);
    assert.equal(api.state.history.length, 2);
    assert.equal(api.state.selection.demoPath, demoPath);
    assert.deepEqual(api.state.recordings[0].request, request);
    const activity = api.state.history[1].values[0].find(part => part instanceof vscode.ChatToolInvocationPart);
    assert.equal(activity.isComplete, true);
    assert.deepEqual(JSON.parse(activity.toolSpecificData.output), request.response[1]);
    assert.deepEqual(invoked, []);
    failLaunch = true;
    await assert.rejects(api.restart(), /Synthetic target readiness failure/);
    assert.equal(api.state.phase, 'error');
    assert.equal(controlView(api.state).error, 'Synthetic target readiness failure');
    assert.equal(controlView(api.state).enabled, false);
    assert.equal(api.state.turnIndex, 0);
    assert.equal(api.state.history.length, 0);
    env.HISTORY_REPLAY_RESUME_TURN = '2';
    await assert.rejects(api.prepare(''), /outside the selected recording/);
});

test('recording Agent Host answers native root handshake and rejects execution', () => {
    const host = new RecordingAgentHost();
    const request = (method, params = {}) => host.handle({ jsonrpc: '2.0', id: 'probe', method, params });
    const result = request('initialize', { channel: 'ahp-root://', protocolVersions: ['test-protocol'], clientId: 'unit-test' });
    assert.equal(result.result.protocolVersion, 'test-protocol');
    assert.equal(result.result.snapshots[0].resource, 'ahp-root://');
    assert.equal(result.result.snapshots[0].state.agents[0].provider, 'historical-replay');
    assert.deepEqual(request('listSessions').result, { items: [] });
    assert.equal(request('subscribe', { channel: 'ahp-root://' }).result.snapshot.fromSeq, 0);
    assert.equal(request('dispatch', { action: 'runTool' }).error.code, -32601);
    assert.equal(request('sendMessage').error.code, -32601);
    assert.equal(request('initialize', { channel: 'wrong', protocolVersions: [] }).error.code, -32602);
    assert.equal(request('subscribe', { channel: 'unknown' }).error.code, -32008);
});

test('recording Agent Host serves authenticated loopback requests only', { timeout: 3000 }, async context => {
    const host = new RecordingAgentHost();
    const endpoint = await host.start();
    context.after(() => endpoint.close());
    const unauthorized = new WebSocket(endpoint.address);
    await new Promise(resolve => unauthorized.once('error', resolve));
    const socket = new WebSocket(endpoint.address + '?tkn=' + endpoint.connectionToken);
    await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
    const reply = new Promise(resolve => socket.once('message', data => resolve(JSON.parse(data.toString()))));
    socket.send(JSON.stringify({ jsonrpc: '2.0', id: 7, method: 'initialize', params: { channel: 'ahp-root://', protocolVersions: ['test-protocol'], clientId: 'unit-test' } }));
    const result = await reply;
    assert.equal(result.id, 7);
    assert.equal(result.result.snapshots[0].state.activeSessions, 0);
    socket.close();
});

test('recording Agent Host exposes a session/chat inventory without granting execution', () => {
    const host = new RecordingAgentHost([{ request: { message: { text: 'Original historical prompt' }, timestamp: 1000, response: [] } }]);
    const result = host.handle({ jsonrpc: '2.0', id: 1, method: 'listSessions' }).result;
    assert.equal(result.items.length, 1);
    const session = host.snapshot(result.items[0].resource).state;
    assert.equal(session.lifecycle, 'ready');
    assert.equal(session.provider, 'historical-replay');
    const chat = host.snapshot(session.defaultChat).state;
    assert.equal(chat.interactivity, 'full');
    assert.deepEqual(chat.turns, []);
    assert.equal(host.handle({ jsonrpc: '2.0', id: 2, method: 'sendMessage' }).error.code, -32601);
});

test('native recording host emits original drafts and response parts without executing input', () => {
    const request = { requestId: 'recorded-turn', message: { text: 'Original prompt' }, timestamp: 1000, response: [] };
    const host = new RecordingAgentHost([{ request }]);
    const draft = host.draft('Ori');
    assert.equal(draft.action.type, 'chat/draftChanged');
    assert.equal(draft.action.draft.text, 'Ori');
    const started = host.beginTurn(request);
    assert.equal(started.action.message.text, request.message.text);
    const part = { kind: 'markdown', id: 'original-text', content: 'Original answer' };
    assert.equal(host.appendPart(part).action.part, part);
    const complete = host.finishTurn();
    assert.equal(complete.action.type, 'chat/turnComplete');
    assert.equal(host.snapshot(host.chatResource).state.turns[0].responseParts[0].content, 'Original answer');
    assert.equal(host.handle({ jsonrpc: '2.0', id: 2, method: 'dispatch', params: { action: { type: 'chat/turnStarted' } } }).error.code, -32601);
});

test('historical model name is used only when its recorded identifier matches the turn', () => {
    const snapshot = { inputState: { selectedModel: { identifier: 'recorded/model-one', metadata: { name: 'Original Model One' } } } };
    assert.deepEqual(recordedModel({ modelId: 'recorded/model-one' }, snapshot), { id: 'recorded/model-one', name: 'Original Model One' });
    assert.deepEqual(recordedModel({ modelId: 'recorded/model-two' }, snapshot), { id: 'recorded/model-two', name: 'recorded/model-two' });
    assert.equal(recordedModel({}, snapshot), undefined);
});

test('native model catalog and turn selection preserve recorded identity without enabling inference', () => {
    const request = { requestId: 'original', modelId: 'recorded/model-one', message: { text: 'Original prompt' }, timestamp: 1000, response: [] };
    const model = { id: request.modelId, name: 'Original Model One' };
    const host = new RecordingAgentHost([{ request, model }]);
    assert.equal(host.root.agents[0].models.length, 1);
    assert.equal(host.root.agents[0].models[0].name, model.name);
    assert.equal(host.root.agents[0].models[0].id, request.modelId);
    assert.equal(host.root.agents[0].models[0]._meta.historicalReplay, true);
    assert.equal(host.snapshot(host.chatResource).state.config.values.model.id, request.modelId);
    assert.equal(host.draft('O', request.modelId).action.draft.model.id, request.modelId);
    assert.equal(host.beginTurn(request).action.message.model.id, request.modelId);
    assert.equal(host.handle({ jsonrpc: '2.0', id: 1, method: 'sendMessage' }).error.code, -32601);
});

test('recorded view labels contain original participant, prompt, and model without replay prefixes', () => {
    const request = { modelId: 'recorded/model-one', message: { text: 'Original prompt title' }, timestamp: 1000, response: [] };
    const host = new RecordingAgentHost([{ request, responderName: 'Original Assistant', model: { id: request.modelId, name: 'Original Model' } }]);
    assert.equal(host.root.agents[0].displayName, 'Original Assistant');
    assert.equal(host.sessions[0].title, request.message.text);
    assert.equal(host.snapshot(host.chatResource).state.title, request.message.text);
    assert.equal(host.root.agents[0].models[0].name, 'Original Model');
    assert.doesNotMatch([host.root.agents[0].displayName, host.sessions[0].title, host.root.agents[0].models[0].name].join(' '), /historical replay/i);
    assert.equal(host.handle({ jsonrpc: '2.0', id: 1, method: 'sendMessage' }).error.code, -32601);
});

test('saved questions replay completed with original answers instead of asking again', () => {
    const part = { kind: 'questionCarousel', resolveId: 'saved-question', isUsed: true, questions: [{ id: 'source', type: 'text', title: 'Source', message: 'Original question' }], data: { source: 'Original answer' } };
    const display = completedQuestions(part);
    assert.equal(display.response, 'accept');
    assert.equal(display.request.questions[0].message, 'Original question');
    assert.deepEqual(display.request.answers.source, { state: 'submitted', value: { kind: 'text', value: 'Original answer' } });
    assert.throws(() => completedQuestions({ ...part, isUsed: false }), /saved answers/);
    const freeform = { ...part, questions: [{ id: 'source', type: 'singleSelect', title: 'Source', message: 'Original question', options: [], allowFreeformInput: true }], data: { source: { freeformValue: 'Original freeform answer' } } };
    assert.deepEqual(completedQuestions(freeform).request.answers.source.value.freeformValues, ['Original freeform answer']);
});

test('saved edit payloads remain exact read-only artifacts and never modify files', () => {
    const part = { kind: 'textEditGroup', uri: { fsPath: 'C:\\source\\Original.ps1' }, edits: [[{ text: 'Original saved edit', range: { startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1 } }]], done: true };
    const archive = archivedEdit(part);
    assert.deepEqual(JSON.parse(archive.content), part);
    const request = { message: { text: 'Original prompt' }, timestamp: 1000, response: [part] };
    const host = new RecordingAgentHost([{ request }]);
    host.beginTurn(request);
    host.appendSavedPart(part);
    const read = host.handle({ jsonrpc: '2.0', id: 1, method: 'resourceRead', params: { channel: 'ahp-root://', uri: archive.uri } });
    assert.deepEqual(JSON.parse(read.result.data), part);
    assert.equal(host.handle({ jsonrpc: '2.0', id: 2, method: 'resourceWrite', params: { uri: archive.uri } }).error.code, -32601);
    assert.deepEqual([...INTERNAL_PARTS], ['mcpServersStarting', 'undoStop', 'codeblockUri']);
});

test('all saved response parts are retained as display events or internal metadata', async context => {
    const questions = { kind: 'questionCarousel', resolveId: 'q', isUsed: true, questions: [{ id: 'answer', type: 'text', message: 'Original question' }], data: { answer: 'Original answer' } };
    const edit = { kind: 'textEditGroup', uri: { fsPath: 'C:\\source\\Saved.ps1' }, edits: [[{ text: 'Original saved edit', range: { startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1 } }]], done: true };
    const response = [{ value: '' }, { value: 'Original assistant text' }, questions, edit, { kind: 'undoStop', id: 'original-stop' }, { kind: 'codeblockUri', uri: { fsPath: 'C:\\source\\Saved.ps1' } }, { kind: 'mcpServersStarting' }];
    const request = { result: {}, message: { text: 'Original prompt' }, response };
    const file = await fixture(context, request);
    const recording = await readRecording(file, 0);
    const displayed = new Set(responseTimeline(recording.request.response).map(event => event.part));
    assert.equal(displayed.size + recording.internalParts.length, response.length);
    assert.deepEqual(recording.request.response, response);
    const host = new RecordingAgentHost([recording]);
    const started = host.beginTurn(recording.request);
    assert.deepEqual(started.action.message._meta.originalResponseParts, response);
});

test('saved code edits render original ranges and ordered replacements without reading or changing targets', async context => {
    const file = await fixture(context, { result: {}, message: { text: 'Recorded edit' }, response: [] });
    const before = await fs.readFile(file);
    const range = { startLineNumber: 3, startColumn: 2, endLineNumber: 4, endColumn: 8 };
    const part = {
        kind: 'textEditGroup', uri: { scheme: 'file', path: '/missing/saved-source.js', fsPath: file }, done: true,
        edits: [[{ range, text: 'first\r\nreplacement \u03bb' }], [], [{ range, text: '' }]],
        state: { applied: 2, sha1: 'saved-original-metadata' }
    };
    const original = structuredClone(part);
    assert.equal(validateSavedEditGroup(part), part);
    const display = savedEditText(part);
    assert.match(display, /Recorded code edit - not applied/);
    assert.ok(display.includes('Target: ' + file));
    assert.match(display, /range 3:2 - 4:8/);
    assert.match(display, /first\r\nreplacement \u03bb/);
    assert.ok(display.indexOf('Batch 1, replacement 1') < display.indexOf('Batch 3, replacement 1'));
    assert.match(display, /Batch 2: no replacements recorded/);
    assert.match(display, /\[Empty replacement text\]/);
    assert.match(display, /not a reconstructed before\/after diff/);
    assert.deepEqual(JSON.parse(archivedEdit(part).content), original);
    assert.deepEqual(part, original);
    assert.deepEqual(await fs.readFile(file), before);
    const absent = { ...part, uri: { scheme: 'file', path: '/nonexistent/saved-only.js' } };
    assert.match(savedEditText(absent), /file:\/nonexistent\/saved-only.js/);
    assert.match(savedEditText({ ...part, edits: [] }), /No replacement batches recorded/);
});

test('saved edit code fences contain embedded Markdown and commands without interpreting them', () => {
    const text = 'before\n``````\n[run](command:example.run)\n<script>not executable</script>\n~~~~\nafter';
    const part = {
        kind: 'textEditGroup', uri: { scheme: 'file', path: '/saved/`source`.js' }, done: true,
        edits: [[{ text, range: { startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1 } }]]
    };
    const markdown = savedEditMarkdown(part);
    assert.ok(markdown.startsWith('\n\n**Recorded code edit - not applied**\n\n'));
    assert.ok(markdown.includes('\n\n```````text\n'));
    assert.ok(markdown.endsWith('\n```````\n\n'));
    assert.ok(markdown.includes(text));
});

test('incomplete and malformed saved edits fail with specific errors across extraction and editor validation', async context => {
    const valid = {
        kind: 'textEditGroup', uri: { scheme: 'file', path: '/saved/source.js' }, done: true,
        edits: [[{ text: 'replacement', range: { startLineNumber: 1, startColumn: 1, endLineNumber: 2, endColumn: 1 } }]]
    };
    const range = valid.edits[0][0].range;
    const cases = [
        [{ ...valid, done: false }, /incomplete/],
        [{ ...valid, done: undefined }, /completion flag/],
        [{ ...valid, uri: undefined }, /target URI/],
        [{ ...valid, edits: undefined }, /edit batches/],
        [{ ...valid, edits: [{}] }, /batch 1 is not an array/],
        [{ ...valid, edits: [[null]] }, /replacement 1.*replacement text/],
        [{ ...valid, edits: [[{ range }]] }, /replacement text/],
        ...[
            undefined, { ...range, startLineNumber: 0 }, { ...range, endColumn: -1 },
            { ...range, startColumn: 1.5 }, { ...range, startLineNumber: 3 },
            { ...range, endLineNumber: 1, startColumn: 3, endColumn: 2 },
            { ...range, endLineNumber: Number.MAX_SAFE_INTEGER + 1 }
        ].map(invalid => [{ ...valid, edits: [[{ text: '', range: invalid }]] }, /invalid saved range/])
    ];
    for (const [part, pattern] of cases) {
        assert.throws(() => savedEditMarkdown(part), pattern);
        assert.throws(() => archivedEdit(part), pattern);
        const request = { result: {}, message: { text: 'Recorded edits' }, response: [part] };
        assert.throws(() => validateEditorRecording({ request }), pattern);
        const source = await fixture(context, request);
        await assert.rejects(readRecording(source, 0), pattern);
    }
    const source = await fixture(context, { result: {}, message: { text: 'Recorded edits' }, response: [valid] });
    const recording = validateEditorRecording(await readRecording(source, 0));
    assert.equal(recording.requiresSavedPartsRenderer, false);
    assert.deepEqual(recording.request.response, [valid]);
    assert.deepEqual(responseTimeline(recording.request.response).map(event => event.part), [valid]);
});

test('controller counts the current turn and waits at every response boundary', () => {
    const state = { phase: 'ready', turnIndex: 0, recordings: Array.from({ length: 7 }, () => ({})) };
    assert.equal(controlView(state).progress, '1/7');
    state.phase = 'typing';
    assert.equal(controlView(state).button, 'Pause');
    state.phase = 'review';
    state.turnIndex = 1;
    assert.equal(controlView(state).label, 'Exchange complete');
    assert.equal(controlView(state).progress, '1/7');
    assert.equal(controlView(state).action, 'restart');
    assert.equal(controlView(state).nextEnabled, true);
    state.phase = 'typing';
    assert.equal(controlView(state).progress, '2/7');
    state.phase = 'complete';
    state.turnIndex = 7;
    assert.equal(controlView(state).progress, '7/7');
    assert.equal(controlView(state).enabled, true);
    assert.equal(controlView(state).nextEnabled, false);
});

test('native JSONL updates reconstruct final fields, replaced tails, appended turns, and cleared values', async context => {
    const first = { result: {}, message: { text: 'First' }, response: [{ value: 'Partial' }, { value: 'Old tail' }] };
    const file = await fixture(context, first);
    await fs.appendFile(file, [
        { kind: 1, k: ['requests', 0, 'response', 0, 'value'], v: 'Final first answer' },
        { kind: 2, k: ['requests', 0, 'response'], i: 1, v: [{ value: 'New tail' }] },
        { kind: 2, k: ['requests'], v: [{ result: {}, message: { text: 'Second' }, response: [{ value: 'Second answer' }], temporary: true }] },
        { kind: 3, k: ['requests', 1, 'temporary'] }
    ].map(record => JSON.stringify(record)).join('\n') + '\n');
    const snapshot = await readSnapshot(file);
    assert.equal(snapshot.requests.length, 2);
    assert.deepEqual(snapshot.requests[0].response.map(part => part.value), ['Final first answer', 'New tail']);
    assert.equal(snapshot.requests[1].temporary, undefined);
    assert.equal((await readRecordings(file, 0, 2))[1].request.message.text, 'Second');
    assert.throws(() => applyTranscriptRecord(snapshot, { kind: 1, k: ['__proto__', 'polluted'], v: true }), /Invalid/);
});