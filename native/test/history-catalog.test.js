const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { pathToFileURL } = require('node:url');
const { DatabaseSync } = require('node:sqlite');
const { spawnSync } = require('node:child_process');
const { discoverHistory, FILE_LIMIT } = require('../history-catalog');
const library = require('../demo-library');
const { sdkSnapshot, sdkEventMarkdown } = require('../sdk-transcript');
const { readRecordings } = require('../replay');
const { nativeResponsePart } = require('../native-response');
const { RecordingAgentHost } = require('../recording-agent-host');
const { archivedEdit } = require('../saved-parts');

const id = '12345678-1234-1234-1234-123456789abc';
function sdkEvents() {
    const record = (type, data, seconds) => ({ id: type + seconds, type, data, timestamp: new Date(Date.UTC(2026, 9, 16, 12, 0, seconds)).toISOString() });
    return [
        record('session.start', { version: 1, sessionId: id, producer: 'Recorded Agent', selectedModel: 'saved-model', context: { cwd: 'C:\\RecordedProject' } }, 0),
        record('user.message', { content: 'First SDK prompt', attachments: [{ path: 'not-bundled.png' }] }, 1),
        record('assistant.turn_start', {}, 2),
        record('assistant.message', { content: 'Before the recorded tool', toolRequests: [{ name: 'saved-tool' }] }, 3),
        record('tool.execution_start', { toolCallId: 'call-1', toolName: 'saved-tool', arguments: { literal: '[text](command:never.run)' } }, 4),
        record('tool.execution_complete', { toolCallId: 'call-1', success: true, result: { content: 'Original result\n````\n[never run](command:never.run)' } }, 5),
        record('assistant.message', { content: 'Original final answer', model: 'saved-model' }, 6),
        record('assistant.turn_end', {}, 7),
        record('user.message', { content: 'Second SDK prompt' }, 10),
        record('assistant.message', { content: 'Second final answer' }, 11),
        record('assistant.turn_end', {}, 12)
    ];
}

async function setup(context) {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'history-catalog-test-'));
    context.after(() => fs.rm(root, { recursive: true, force: true }));
    const appData = path.join(root, 'AppData');
    const home = path.join(root, 'Home');
    const workspace = path.join(appData, 'Code', 'User', 'workspaceStorage', 'a'.repeat(32));
    const native = path.join(workspace, 'chatSessions', 'saved.jsonl');
    await fs.mkdir(path.dirname(native), { recursive: true });
    await fs.writeFile(path.join(workspace, 'workspace.json'), JSON.stringify({ folder: pathToFileURL(path.join(root, 'Project A')).href }));
    const nativeSnapshot = { customTitle: 'Old title', responderUsername: 'Native Agent', creationDate: Date.UTC(2026, 9, 16, 11), requests: [
        { result: {}, timestamp: Date.UTC(2026, 9, 16, 11, 0, 10), message: { text: 'First native prompt' }, response: [{ value: 'Saved native answer' }] },
        { timestamp: Date.UTC(2026, 9, 16, 11, 1), message: { text: 'Incomplete native prompt' }, response: [] }
    ] };
    await fs.writeFile(native, JSON.stringify({ kind: 0, v: nativeSnapshot }) + '\n');
    const db = new DatabaseSync(path.join(workspace, 'state.vscdb'));
    try {
        db.exec('CREATE TABLE ItemTable (key TEXT, value TEXT)');
        db.prepare('INSERT INTO ItemTable VALUES (?, ?)').run('chat.ChatSessionStore.index', JSON.stringify({
            entries: { saved: { title: 'VS Code title', timing: { created: Date.UTC(2026, 9, 16, 11), lastRequestEnded: Date.UTC(2026, 9, 16, 11, 2) } } }
        }));
    } finally { db.close(); }
    const events = path.join(home, '.copilot', 'session-state', id, 'events.jsonl');
    await fs.mkdir(path.dirname(events), { recursive: true });
    await fs.writeFile(events, sdkEvents().map(event => JSON.stringify(event)).join('\n') + '\n');
    const agentFile = path.join(appData, 'Code', 'agentSessionData', id, 'session.db');
    await fs.mkdir(path.dirname(agentFile), { recursive: true });
    const agent = new DatabaseSync(agentFile);
    try {
        agent.exec('CREATE TABLE session_metadata (key TEXT, value TEXT)');
        const put = agent.prepare('INSERT INTO session_metadata VALUES (?, ?)');
        put.run('customTitle', JSON.stringify('Title in Agents'));
        put.run('copilot.workingDirectory', JSON.stringify('C:\\RecordedProject'));
        put.run('defaultChatProviderData', JSON.stringify({ sdkSessionId: id }));
    } finally { agent.close(); }
    return { root, appData, home, native, events, agentFile, nativeSnapshot };
}

test('catalog automatically discovers native and linked agent history, deduplicates SDK files and computes recorded metadata', async context => {
    const fixture = await setup(context);
    const beforeNative = await fs.readFile(fixture.native);
    const beforeDb = await fs.readFile(fixture.agentFile);
    const messages = [];
    const result = await discoverHistory(fixture, event => messages.push(event));
    assert.equal(result.sessions.length, 2);
    assert.equal(result.warningCount, 0);
    const native = result.sessions.find(row => row.file === fixture.native);
    assert.equal(native.title, 'VS Code title');
    assert.equal(native.project, 'Project A');
    assert.equal(native.agent, 'Native Agent');
    assert.equal(native.promptCount, 2);
    assert.equal(native.durationSeconds, 120);
    assert.equal(native.status, 'Partial');
    assert.match(native.detail, /1 of 2/);
    const sdk = result.sessions.find(row => row.file === fixture.events);
    assert.equal(sdk.title, 'Title in Agents');
    assert.equal(sdk.project, 'RecordedProject');
    assert.equal(sdk.agent, 'Recorded Agent');
    assert.equal(sdk.durationSeconds, 12);
    assert.equal(sdk.promptCount, 2);
    assert.equal(sdk.status, 'Read-only parts');
    assert.equal(result.sessions[0].file, fixture.events);
    assert.equal(messages.filter(event => event.phase === 'entry').length, 2);
    assert.ok(messages.some(event => event.phase === 'source'));
    assert.deepEqual(await fs.readFile(fixture.native), beforeNative);
    assert.deepEqual(await fs.readFile(fixture.agentFile), beforeDb);
});

test('profiles, Insiders, multi-root/empty windows and explicit locations are discovered without a recursive disk crawl', async context => {
    const fixture = await setup(context);
    const paths = [
        path.join(fixture.appData, 'Code', 'User', 'profiles', 'profile-one', 'workspaceStorage', 'b'.repeat(32), 'chatSessions'),
        path.join(fixture.appData, 'Code - Insiders', 'User', 'globalStorage', 'emptyWindowChatSessions'),
        path.join(fixture.root, 'Extra')
    ];
    for (const directory of paths) {
        await fs.mkdir(directory, { recursive: true });
        await fs.copyFile(fixture.native, path.join(directory, 'copy.jsonl'));
    }
    await fs.writeFile(path.join(path.dirname(paths[0]), 'workspace.json'), JSON.stringify({ workspace: pathToFileURL(path.join(fixture.root, 'Team.code-workspace')).href }));
    const ignored = path.join(fixture.root, 'DoNotSearch', 'nested');
    await fs.mkdir(ignored, { recursive: true });
    await fs.copyFile(fixture.native, path.join(ignored, 'private.jsonl'));
    const result = await discoverHistory({ ...fixture, locations: [paths[2], paths[2]] });
    assert.equal(result.sessions.length, 5);
    assert.ok(result.sessions.some(row => row.project === 'Team.code-workspace'));
    assert.ok(result.sessions.some(row => row.source.includes('Insiders') && row.project === 'No workspace'));
    assert.ok(!result.sessions.some(row => row.file.includes('DoNotSearch')));
    await assert.rejects(discoverHistory({ ...fixture, locations: [fixture.native] }), /not a directory/);
    await assert.rejects(discoverHistory({ ...fixture, locations: ['relative'] }), /absolute/);
});

test('corrupt and missing recordings remain visible with errors; large metadata is deferred without inventing counts or duration', async context => {
    const fixture = await setup(context);
    const extra = path.join(fixture.root, 'Extra');
    await fs.mkdir(extra);
    const large = path.join(extra, 'large.jsonl');
    const handle = await fs.open(large, 'w');
    try { await handle.truncate(FILE_LIMIT + 1); } finally { await handle.close(); }
    await fs.writeFile(path.join(extra, 'broken.jsonl'), '{invalid');
    await fs.unlink(fixture.events);
    const result = await discoverHistory({ ...fixture, locations: [extra] });
    assert.equal(result.sessions.length, 4);
    const deferred = result.sessions.find(row => row.file === large);
    assert.equal(deferred.status, 'Load to inspect');
    assert.equal(deferred.promptCount, null);
    assert.equal(deferred.durationSeconds, null);
    assert.equal(deferred.loadable, true);
    assert.match(deferred.detail, /8 MiB/);
    assert.equal(result.sessions.find(row => row.file === fixture.events).status, 'Unavailable');
    assert.equal(result.warningCount, 2);
    assert.equal(result.warnings.length, 2);
});

test('SDK capture preserves selected original events, tool results and attachments metadata after sources disappear', async context => {
    const fixture = await setup(context);
    const inspection = await library.inspectTranscript(fixture.events);
    assert.equal(inspection.turns.length, 2);
    assert.equal(inspection.turns[0].error, undefined);
    assert.match(inspection.notice, /SDK text and tool transitions are normalized/);
    const value = await library.createPackage(fixture.events, [0], 'SDK capture', inspection.sha256);
    assert.equal(value.source.kind, 'copilot-sdk-jsonl');
    const request = value.turns[0].snapshot.requests[0];
    assert.deepEqual(request.sdkEvents, sdkEvents().slice(1, 8));
    assert.deepEqual(request.sdkEvents[0].data.attachments, [{ path: 'not-bundled.png' }]);
    assert.equal(request.response.find(part => part.kind === 'toolInvocationSerialized').isComplete, true);
    const direct = await readRecordings(fixture.events, 0, 2);
    assert.equal(direct[1].request.message.text, 'Second SDK prompt');
    const archive = request.response.find(part => part.kind === 'recordedSdkEvent');
    const markdown = sdkEventMarkdown(archive);
    assert.match(markdown, /read-only, never executed/);
    assert.ok(markdown.includes('`````text'));
    assert.ok(markdown.includes('command:never.run'));
    const root = path.join(fixture.root, 'Library');
    const added = await library.addPackage(root, value);
    await fs.unlink(fixture.events);
    const playback = await library.packageRecordings(path.join(root, added.id + '.demo.json'));
    assert.deepEqual(playback[0].request, request);
    assert.equal(playback.length, 1);
    const exported = path.join(fixture.root, 'sdk.demo-recording.json');
    await library.exportDemo(root, added.id, exported);
    assert.deepEqual((await library.readPackage(exported)).turns, value.turns);
});

test('SDK unfinished and unmatchable tool activity remains capturable without inventing completion', async context => {
    const fixture = await setup(context);
    assert.throws(() => sdkSnapshot([{ type: 'session.start', data: { version: 2 } }]), /version 1/);
    assert.throws(() => sdkSnapshot([{ type: 'session.start', data: { version: 1 } }]), /missing its identifier/);
    assert.throws(() => sdkSnapshot([sdkEvents()[0], { type: 'bad', data: null }]), /Malformed/);
    const cases = [
        sdkEvents().slice(0, 7),
        sdkEvents().filter(event => event.type !== 'tool.execution_complete').slice(0, 7),
        sdkEvents().filter(event => event.type !== 'tool.execution_start')
    ];
    const invalidList = sdkEvents();
    invalidList.find(event => event.type === 'assistant.message').data.toolRequests = 'malformed';
    cases.push(invalidList);
    const missingStatus = sdkEvents();
    delete missingStatus.find(event => event.type === 'tool.execution_complete').data.success;
    cases.push(missingStatus);
    for (const records of cases) {
        await fs.writeFile(fixture.events, records.map(event => JSON.stringify(event)).join('\n') + '\n');
        const inspection = await library.inspectTranscript(fixture.events);
        assert.equal(inspection.turns[0].error, undefined);
        const value = await library.createPackage(fixture.events, [0], 'Saved SDK', inspection.sha256);
        const request = value.turns[0].snapshot.requests[0];
        const original = records.slice(1, records.findIndex((event, index) => index > 1 && event.type === 'user.message') === -1 ?
            records.length : records.findIndex((event, index) => index > 1 && event.type === 'user.message'));
        assert.deepEqual(request.sdkEvents, original);
        assert.ok(request.response.filter(part => part.kind === 'toolInvocationSerialized').every(part => part.isComplete));
        if (request.sdkCompletion === 'partial') assert.equal(request.result, undefined);
        assert.ok(request.response.some(part => part.kind === 'recordedSdkEvent'));
    }
});

test('SDK steering boundaries preserve recorded text, reasoning and cross-prompt tool events through export/import', async context => {
    const fixture = await setup(context);
    const start = sdkEvents()[0];
    const records = [
        start,
        { type: 'user.message', data: { content: 'Start some work' } },
        { type: 'assistant.message', id: 'thought-1', data: { content: 'Actual recorded progress', reasoningText: 'Actual saved reasoning', toolRequests: [{ name: 'saved-tool' }] } },
        { type: 'tool.execution_start', data: { toolCallId: 'cross-prompt', toolName: 'saved-tool', arguments: { original: true } } },
        { type: 'user.message', data: { content: 'A follow-up while the tool is running' } },
        { type: 'tool.execution_complete', data: { toolCallId: 'cross-prompt', success: true, result: { content: 'Actual recorded result' } } },
        { type: 'assistant.turn_end', data: {} },
        { type: 'assistant.turn_start', data: {} },
        { type: 'user.message', data: { content: 'A prompt with no saved answer yet' } }
    ];
    await fs.writeFile(fixture.events, records.map(event => JSON.stringify(event)).join('\n') + '\n');
    const before = await fs.readFile(fixture.events);
    const inspection = await library.inspectTranscript(fixture.events);
    assert.equal(inspection.turns.length, 3);
    assert.ok(inspection.turns.every(turn => !turn.error));
    assert.ok(inspection.turns[0].content.includes('Actual recorded progress'));
    assert.ok(inspection.turns[0].content.includes('Actual saved reasoning'));
    assert.ok(inspection.turns[1].content.includes('Actual recorded result'));
    const value = await library.createPackage(fixture.events, [0, 1, 2], 'Recorded steering', inspection.sha256);
    const requests = value.turns.map(turn => turn.snapshot.requests[0]);
    assert.deepEqual(requests.flatMap(request => request.sdkEvents), records.slice(1));
    assert.ok(requests.every(request => request.sdkCompletion === 'partial' && request.result === undefined));
    assert.equal(requests.flatMap(request => request.response).filter(part => part.kind === 'toolInvocationSerialized').length, 0);
    assert.deepEqual(requests[0].response.find(part => part.kind === 'thinking'), { kind: 'thinking', id: 'thought-1', value: 'Actual saved reasoning' });
    assert.deepEqual(requests[0].response.find(part => part.kind === 'recordedSdkEvent').events, [records[3]]);
    const root = path.join(fixture.root, 'Library');
    const added = await library.addPackage(root, value);
    const exported = path.join(fixture.root, 'steering.demo-recording.json');
    await library.exportDemo(root, added.id, exported);
    assert.deepEqual((await library.readPackage(exported)).turns, value.turns);
    assert.equal((await library.packageRecordings(exported)).length, 3);
    assert.deepEqual(await fs.readFile(fixture.events), before);
});

test('malformed SDK prompt text is still rejected without blocking inspection of the other prompts', async context => {
    const fixture = await setup(context);
    const records = sdkEvents();
    records.find(event => event.type === 'user.message').data.content = null;
    await fs.writeFile(fixture.events, records.map(event => JSON.stringify(event)).join('\n') + '\n');
    const inspection = await library.inspectTranscript(fixture.events);
    assert.match(inspection.turns[0].error, /prompt is missing its text/);
    assert.equal(inspection.turns[1].error, undefined);
    await assert.rejects(library.createPackage(fixture.events, [0], 'Bad prompt', inspection.sha256), /prompt is missing/);
    assert.equal((await library.createPackage(fixture.events, [1], 'Good prompt', inspection.sha256)).turns.length, 1);
});

test('SDK archives render as native read-only activity and remain read-only host artifacts', () => {
    const part = sdkSnapshot(sdkEvents()).requests[0].response.find(part => part.kind === 'recordedSdkEvent');
    const vscode = {
        MarkdownString: class { constructor(value) { this.value = value; } },
        ChatResponseMarkdownPart: class { constructor(value) { this.value = value; } },
        ChatToolInvocationPart: class {}
    };
    const shown = nativeResponsePart(vscode, { kind: 'recordedSdkEvent', part });
    assert.ok(shown instanceof vscode.ChatToolInvocationPart);
    assert.deepEqual(JSON.parse(shown.toolSpecificData.output), part.events);
    assert.equal(shown.isComplete, true);
    assert.match(shown.pastTenseMessage, /read-only, never executed/);
    assert.equal(shown.value, undefined);
    const request = { message: { text: 'Recorded SDK prompt' }, response: [part] };
    const host = new RecordingAgentHost([{ request }]);
    host.beginTurn(request);
    host.appendSavedPart(part);
    const artifact = archivedEdit(part);
    const read = host.handle({ jsonrpc: '2.0', id: 1, method: 'resourceRead', params: { channel: 'ahp-root://', uri: artifact.uri } });
    assert.deepEqual(JSON.parse(read.result.data), part);
    assert.equal(host.handle({ jsonrpc: '2.0', id: 2, method: 'resourceWrite', params: { uri: artifact.uri } }).error.code, -32601);
});

test('metadata read limit accepts exactly 8 MiB and defers the next byte; legacy JSON remains visibly unsupported', async context => {
    const fixture = await setup(context);
    const extra = path.join(fixture.root, 'Extra');
    await fs.mkdir(extra);
    const content = JSON.stringify({ kind: 0, v: fixture.nativeSnapshot }) + '\n';
    const bytes = Buffer.byteLength(content);
    await fs.writeFile(path.join(extra, 'exact.jsonl'), content + ' '.repeat(FILE_LIMIT - bytes));
    await fs.writeFile(path.join(extra, 'over.jsonl'), content + ' '.repeat(FILE_LIMIT - bytes + 1));
    await fs.writeFile(path.join(extra, 'legacy.json'), JSON.stringify(fixture.nativeSnapshot));
    const result = await discoverHistory({ ...fixture, locations: [extra] });
    const exact = result.sessions.find(row => row.file.endsWith('exact.jsonl'));
    assert.equal(exact.status, 'Partial');
    assert.equal(exact.promptCount, 2);
    const over = result.sessions.find(row => row.file.endsWith('over.jsonl'));
    assert.equal(over.status, 'Load to inspect');
    assert.equal(over.promptCount, null);
    const legacy = result.sessions.find(row => row.file.endsWith('legacy.json'));
    assert.equal(legacy.status, 'Unavailable');
    assert.match(legacy.detail, /Legacy JSON snapshot/);
    await assert.rejects(discoverHistory({ ...fixture, locations: Array(21).fill(extra) }), /at most 20/);
});

test('oversized database/workspace metadata is bounded in bytes and reported without hiding recordings', async context => {
    const fixture = await setup(context);
    const workspace = path.dirname(path.dirname(fixture.native));
    const index = new DatabaseSync(path.join(workspace, 'state.vscdb'));
    try {
        index.prepare('UPDATE ItemTable SET value = ?').run(JSON.stringify({ entries: { saved: { title: '\u00e9'.repeat(FILE_LIMIT / 2) } } }));
    } finally { index.close(); }
    const agent = new DatabaseSync(fixture.agentFile);
    try {
        agent.prepare('UPDATE session_metadata SET value = ? WHERE key = ?').run(JSON.stringify('\u00e9'.repeat(1024 * 1024)), 'customTitle');
    } finally { agent.close(); }
    await fs.writeFile(path.join(workspace, 'workspace.json'), ' '.repeat(1024 * 1024 + 1));
    const result = await discoverHistory(fixture);
    assert.equal(result.sessions.length, 3);
    assert.equal(result.sessions.find(row => row.file === fixture.native).title, 'Old title');
    assert.equal(result.sessions.find(row => row.file === fixture.events).status, 'Read-only parts');
    assert.match(result.sessions.find(row => row.file === fixture.agentFile).detail, /1 MiB per-value/);
    assert.ok(result.warnings.some(message => message.includes('8 MiB metadata')));
    assert.ok(result.warnings.some(message => message.includes('no larger than 1 MiB')));
});

test('a malformed exchange or title cannot hide valid exchanges; duration includes saved completion after a stale index', async context => {
    const fixture = await setup(context);
    fixture.nativeSnapshot.customTitle = { invalid: true };
    fixture.nativeSnapshot.requests[0].modelState = { completedAt: Date.UTC(2026, 9, 16, 11, 4) };
    fixture.nativeSnapshot.requests[1].response = { malformed: true };
    const workspace = path.dirname(path.dirname(fixture.native));
    const db = new DatabaseSync(path.join(workspace, 'state.vscdb'));
    try {
        db.prepare('UPDATE ItemTable SET value = ?').run(JSON.stringify({ entries: { saved: { title: {}, timing: { created: Date.UTC(2026, 9, 16, 11), lastRequestEnded: Date.UTC(2026, 9, 16, 11, 2) } } } }));
    } finally { db.close(); }
    await fs.writeFile(fixture.native, JSON.stringify({ kind: 0, v: fixture.nativeSnapshot }) + '\n');
    const result = await discoverHistory(fixture);
    const row = result.sessions.find(row => row.file === fixture.native);
    assert.equal(row.status, 'Partial');
    assert.equal(row.loadable, true);
    assert.equal(row.title, 'First native prompt');
    assert.equal(row.durationSeconds, 240);
    assert.ok(result.warnings.some(message => message.includes('Invalid saved title metadata')));
    const inspection = await library.inspectTranscript(fixture.native);
    assert.equal(inspection.title, 'First native prompt');
    assert.equal(inspection.turns[0].error, undefined);
    assert.ok(inspection.turns[1].error);
});

test('history CLI streams bounded progress/entries and ends with a summary, without scanning real user data', async context => {
    const fixture = await setup(context);
    const result = spawnSync(process.execPath, [path.join(__dirname, '..', 'library-cli.js')], {
        input: JSON.stringify({ command: 'history', root: path.join(fixture.root, 'Library'), appData: fixture.appData, home: fixture.home, progress: true }),
        encoding: 'utf8', timeout: 10000
    });
    assert.equal(result.status, 0, result.stderr);
    const messages = result.stdout.trim().split('\n').map(line => JSON.parse(line));
    assert.equal(messages.filter(message => message.progress?.phase === 'entry').length, 2);
    assert.equal(messages.at(-1).ok, true);
    assert.equal(messages.at(-1).result.count, 2);
    assert.equal(messages.at(-1).result.sessions, undefined);
});
