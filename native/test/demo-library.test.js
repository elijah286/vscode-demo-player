const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { DatabaseSync } = require('node:sqlite');
const library = require('../demo-library');

async function fixture(context) {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'demo-library-test-'));
    context.after(() => fs.rm(directory, { recursive: true, force: true }));
    const source = path.join(directory, 'source.jsonl');
    const tool = { kind: 'toolInvocationSerialized', toolId: 'saved-tool', toolCallId: 'original-call', isComplete: true, invocationMessage: 'Recorded operation', toolSpecificData: { original: 'payload' } };
    const requests = [
        { result: {}, message: { text: 'First original prompt\r\n\u03bb' }, modelId: 'recorded/model', response: [{ value: 'Partial' }, tool] },
        { result: {}, message: { text: 'Second original prompt' }, response: [{ value: 'Second original answer' }] },
        { message: { text: 'Incomplete' }, response: [] }
    ];
    await fs.writeFile(source, [
        { kind: 0, v: { sessionId: 'original-session', customTitle: 'Original conversation', responderUsername: 'Original Assistant', inputState: { selectedModel: { identifier: 'recorded/model', metadata: { name: 'Original Model' } } }, requests } },
        { kind: 1, k: ['requests', 0, 'response', 0, 'value'], v: 'Final original answer\r\n\u03bb' }
    ].map(record => JSON.stringify(record)).join('\n') + '\n');
    const root = path.join(directory, 'library');
    const inspection = await library.inspectTranscript(source);
    return { directory, source, root, inspection, requests, tool };
}

test('capture reconstructs final state, preserves payloads and order, and excludes unselected turns', async context => {
    const { source, inspection, tool } = await fixture(context);
    const before = await fs.readFile(source);
    assert.match(inspection.turns[2].error, /incomplete/);
    assert.match(inspection.turns[0].details, /original-call/);
    const recording = await library.createPackage(source, [1, 0], 'Selected demo', inspection.sha256);
    assert.deepEqual(recording.turns.map(turn => turn.sourceIndex), [1, 0]);
    assert.equal(recording.turns[1].snapshot.requests[0].response[0].value, 'Final original answer\r\n\u03bb');
    assert.deepEqual(recording.turns[1].snapshot.requests[0].response[1], tool);
    assert.equal(recording.turns[1].snapshot.requests[0].message.text, 'First original prompt\r\n\u03bb');
    assert.equal(recording.turns[1].snapshot.inputState.selectedModel.metadata.name, 'Original Model');
    assert.ok(recording.turns.every(turn => turn.snapshot.requests.length === 1));
    assert.deepEqual(await fs.readFile(source), before);
});

test('preview fingerprint prevents capturing a changed conversation', async context => {
    const { source, inspection } = await fixture(context);
    await fs.appendFile(source, JSON.stringify({ kind: 1, k: ['customTitle'], v: 'Changed' }) + '\n');
    await assert.rejects(library.createPackage(source, [0], 'Demo', inspection.sha256), /changed after preview/);
    await assert.rejects(library.createPackage(source, [0], 'Demo'), /Inspect/);
});

test('completed code edits survive capture, library storage, export/import and missing original files', async context => {
    const { directory, source, root } = await fixture(context);
    const target = path.join(directory, 'original-source.js');
    await fs.writeFile(target, 'Live file contents must not be changed.');
    const edit = {
        kind: 'textEditGroup', uri: { fsPath: target }, done: true,
        edits: [[{ text: 'saved\r\nreplacement \u03bb', range: { startLineNumber: 4, startColumn: 1, endLineNumber: 5, endColumn: 2 } }]],
        state: { sha1: 'saved-metadata', applied: 1 }
    };
    await fs.appendFile(source, JSON.stringify({ kind: 2, k: ['requests', 0, 'response'], v: [edit] }) + '\n');
    const inspected = await library.inspectTranscript(source);
    assert.equal(inspected.turns[0].status, 'archived-edits');
    assert.equal(inspected.turns[0].error, undefined);
    assert.equal(inspected.turns[1].status, 'ready');
    assert.equal(inspected.turns[2].status, 'unavailable');
    assert.match(inspected.turns[0].content, /Recorded code edit - not applied/);
    assert.match(inspected.turns[0].content, /range 4:1 - 5:2/);
    assert.match(inspected.turns[0].content, /saved\r\nreplacement \u03bb/);
    assert.deepEqual(JSON.parse(inspected.turns[0].details).response.at(-1), edit);
    const value = await library.createPackage(source, [0, 1], 'Saved edits', inspected.sha256);
    const added = await library.addPackage(root, value);
    const exported = path.join(directory, 'saved-edits.demo-recording.json');
    await library.exportDemo(root, added.id, exported);
    assert.equal(await fs.readFile(target, 'utf8'), 'Live file contents must not be changed.');
    await fs.unlink(target);
    await fs.unlink(source);
    const imported = await library.addPackage(path.join(directory, 'imported'), await library.readPackage(exported));
    const playback = await library.packageRecordings(path.join(directory, 'imported', imported.id + '.demo.json'));
    assert.deepEqual(playback[0].request.response.at(-1), edit);
    assert.equal(playback[0].requiresSavedPartsRenderer, false);
    assert.equal(playback[1].request.message.text, 'Second original prompt');
    await assert.rejects(fs.stat(target), { code: 'ENOENT' });
    const changed = structuredClone(value);
    changed.turns[0].snapshot.requests[0].response.at(-1).edits[0][0].text = 'tampered';
    assert.throws(() => library.validatePackage(changed), /hash mismatch/);
});

test('large replacement payloads remain exact and malformed parts do not prevent inspecting other exchanges', async context => {
    const { source } = await fixture(context);
    const edit = {
        kind: 'textEditGroup', uri: { scheme: 'file', path: '/missing/source.js' }, done: true,
        edits: [[{ text: 'x'.repeat(1024 * 1024 + 1), range: { startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1 } }]]
    };
    await fs.appendFile(source, JSON.stringify({ kind: 2, k: ['requests', 0, 'response'], v: [edit] }) + '\n');
    const inspected = await library.inspectTranscript(source);
    const captured = await library.createPackage(source, [0], 'Large saved replacement', inspected.sha256);
    assert.equal(captured.turns[0].snapshot.requests[0].response.at(-1).edits[0][0].text, edit.edits[0][0].text);
    assert.ok(inspected.turns[0].content.includes(edit.edits[0][0].text));
    await fs.appendFile(source, JSON.stringify({ kind: 1, k: ['requests', 0, 'response', 2, 'done'], v: false }) + '\n');
    const incomplete = await library.inspectTranscript(source);
    assert.match(incomplete.turns[0].error, /code edit is incomplete/);
    assert.match(incomplete.turns[0].details, /"done": false/);
    assert.equal(incomplete.turns[1].status, 'ready');
    await assert.rejects(library.createPackage(source, [0], 'Incomplete edit', incomplete.sha256), /code edit is incomplete/);
    await fs.appendFile(source, JSON.stringify({ kind: 2, k: ['requests', 1, 'response'], v: [null] }) + '\n');
    const invalidPart = await library.inspectTranscript(source);
    assert.match(invalidPart.turns[1].error, /invalid saved response part/);
    assert.equal(invalidPart.turns.length, 3);
});

test('capture refuses incomplete, unsupported, duplicate, empty, out-of-range, and excessive selections', async context => {
    const { source, inspection } = await fixture(context);
    for (const indices of [[], [0, 0], [-1], [0.5], Array.from({ length: 101 }, (_, index) => index)]) {
        await assert.rejects(library.createPackage(source, indices, 'Demo', inspection.sha256), /Select/);
    }
    await assert.rejects(library.createPackage(source, [2], 'Demo', inspection.sha256), /incomplete/);
    await assert.rejects(library.createPackage(source, [99], 'Demo', inspection.sha256), /incomplete/);
    await fs.appendFile(source, JSON.stringify({ kind: 2, k: ['requests', 0, 'response'], v: [{ kind: 'workspaceEdit' }] }) + '\n');
    const updated = await library.inspectTranscript(source);
    assert.match(updated.turns[0].error, /cannot render/);
    await assert.rejects(library.createPackage(source, [0], 'Demo', updated.sha256), /No content was discarded/);
});

test('packages play after source removal, survive export/import, and preserve renamed metadata separately', async context => {
    const { source, root, directory, inspection } = await fixture(context);
    const recording = await library.createPackage(source, [0, 1], 'Capture title', inspection.sha256);
    const added = await library.addPackage(root, recording);
    await fs.unlink(source);
    const file = path.join(root, added.id + '.demo.json');
    const playback = await library.packageRecordings(file);
    assert.equal(playback.length, 2);
    assert.equal(playback[0].model.name, 'Original Model');
    assert.equal(playback[0].request.response[0].value, 'Final original answer\r\n\u03bb');
    const renamed = await library.renameDemo(root, added.id, 'Presentation title');
    assert.equal(renamed.title, 'Presentation title');
    assert.equal((await library.readEntry(root, added.id)).recording.title, 'Capture title');
    assert.deepEqual((await library.readEntry(root, added.id)).recording, recording);
    const exported = path.join(directory, 'export.demo-recording.json');
    await library.exportDemo(root, added.id, exported);
    assert.equal((await library.readPackage(exported)).title, 'Presentation title');
    await assert.rejects(library.exportDemo(root, added.id, exported), /EEXIST/);
    const imported = await library.addPackage(path.join(directory, 'another-library'), await library.readPackage(exported));
    assert.equal(imported.title, 'Presentation title');
    assert.deepEqual((await library.packageRecordings(exported)).map(turn => turn.request), playback.map(turn => turn.request));
    await library.deleteDemo(root, added.id);
    assert.deepEqual(await library.listDemos(root), []);
    assert.ok((await fs.stat(exported)).isFile());
});

test('corrupt packages, unsupported versions, duplicate imports, and unsafe entry IDs are refused', async context => {
    const { source, root, inspection } = await fixture(context);
    const recording = await library.createPackage(source, [0], 'Demo', inspection.sha256);
    const changed = structuredClone(recording);
    changed.turns[0].snapshot.requests[0].message.text = 'Modified';
    assert.throws(() => library.validatePackage(changed), /hash mismatch/);
    assert.throws(() => library.validatePackage({ ...recording, version: 2 }), /Unsupported/);
    const added = await library.addPackage(root, recording);
    await assert.rejects(library.addPackage(root, recording), /already/);
    await assert.rejects(library.deleteDemo(root, '..\\outside'), /identifier/);
    await assert.rejects(library.renameDemo(root, added.id, '   '), /title/);
    await fs.writeFile(path.join(root, added.id + '.demo.json'), '{}');
    await assert.rejects(library.listDemos(root), /Invalid library entry/);
});

test('busy libraries fail visibly and leave existing recordings untouched', async context => {
    const { source, root, inspection } = await fixture(context);
    await fs.mkdir(root);
    await fs.writeFile(path.join(root, '.library.lock'), '');
    const recording = await library.createPackage(source, [0], 'Demo', inspection.sha256);
    await assert.rejects(library.addPackage(root, recording), /library is busy/);
    assert.deepEqual(await fs.readdir(root), ['.library.lock']);
});

test('discovery requires a directory and lists only its exact workspace, without modifying sources', async context => {
    const { directory, source } = await fixture(context);
    const folder = path.join(directory, 'Example Project');
    await fs.mkdir(folder);
    const storageRoot = path.join(directory, 'storage');
    const workspace = path.join(storageRoot, 'a'.repeat(32));
    await fs.mkdir(path.join(workspace, 'chatSessions'), { recursive: true });
    await fs.writeFile(path.join(workspace, 'workspace.json'), JSON.stringify({ folder: pathToFileURL(folder).href }));
    const target = path.join(workspace, 'chatSessions', 'saved.jsonl');
    await fs.copyFile(source, target);
    const other = path.join(storageRoot, 'b'.repeat(32));
    await fs.mkdir(path.join(other, 'chatSessions'), { recursive: true });
    await fs.writeFile(path.join(other, 'workspace.json'), JSON.stringify({ folder: pathToFileURL(folder + '-other').href }));
    await fs.copyFile(source, path.join(other, 'chatSessions', 'unrelated.jsonl'));
    const before = await fs.readFile(target);
    const result = await library.discoverSessions(storageRoot, folder + path.sep);
    assert.equal(result.sessions.length, 1);
    assert.equal(result.sessions[0].project, folder + path.sep);
    assert.equal(result.sessions[0].file, target);
    assert.equal(result.sessions[0].title, 'Original conversation');
    assert.equal(result.sessions[0].preview, 'First original prompt\r\n\u03bb');
    await fs.writeFile(path.join(workspace, 'chatSessions', 'damaged.jsonl'), '{incomplete');
    assert.deepEqual(await fs.readFile(target), before);
    await assert.rejects(library.discoverSessions(storageRoot), /Select a project folder/);
    await assert.rejects(library.discoverSessions(storageRoot, source), /existing project directory/);
    const withError = await library.discoverSessions(storageRoot, folder);
    assert.match(withError.sessions.find(session => session.session === 'damaged.jsonl').preview, /Preview unavailable/);
    const missing = await library.discoverSessions(path.join(directory, 'missing'), folder);
    assert.deepEqual(missing.sessions, []);
    assert.match(missing.notice, /No standard/);
});

test('discovery and inspection use the VS Code index title, even for an initial snapshot above 1 MiB', async context => {
    const { directory, source } = await fixture(context);
    const workspace = path.join(directory, 'storage', 'a'.repeat(32));
    const folder = path.join(directory, 'Project #1');
    await fs.mkdir(folder);
    await fs.mkdir(path.join(workspace, 'chatSessions'), { recursive: true });
    await fs.writeFile(path.join(workspace, 'workspace.json'), JSON.stringify({ folder: pathToFileURL(folder).href }));
    const id = '12345678-1234-1234-1234-123456789abc';
    const target = path.join(workspace, 'chatSessions', id + '.jsonl');
    const snapshot = { customTitle: 'Stale title', requests: [{ result: {}, message: { text: 'Opening prompt' }, response: [{ value: 'x'.repeat(1024 * 1024 + 1) }] }] };
    await fs.writeFile(target, JSON.stringify({ kind: 0, v: snapshot }) + '\n');
    const db = new DatabaseSync(path.join(workspace, 'state.vscdb'));
    try {
        db.exec('CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)');
        db.prepare('INSERT INTO ItemTable VALUES (?, ?)').run('chat.ChatSessionStore.index', JSON.stringify({ version: 1, entries: { [id]: { title: 'Title shown in VS Code' } } }));
    } finally { db.close(); }
    const before = await fs.readFile(path.join(workspace, 'state.vscdb'));
    const found = await library.discoverSessions(path.dirname(workspace), folder);
    assert.equal(found.sessions[0].title, 'Title shown in VS Code');
    assert.equal((await library.inspectTranscript(target)).title, 'Title shown in VS Code');
    assert.deepEqual(await fs.readFile(path.join(workspace, 'state.vscdb')), before);
    await fs.unlink(path.join(workspace, 'state.vscdb'));
    await fs.appendFile(target, JSON.stringify({ kind: 1, k: ['customTitle'], v: 'Final saved title' }) + '\n');
    assert.equal((await library.discoverSessions(path.dirname(workspace), folder)).sessions[0].title, 'Final saved title');
    await fs.writeFile(path.join(workspace, 'state.vscdb'), 'damaged database');
    const damaged = await library.discoverSessions(path.dirname(workspace), folder);
    assert.equal(damaged.sessions[0].title, 'Final saved title');
    assert.match(damaged.notice, /titles could not be read/);
    assert.match((await library.inspectTranscript(source)).notice, /Recorded payloads only/);
});

test('inline file and symbol references remain capturable with readable previews and preserved raw payloads', async context => {
    const { source } = await fixture(context);
    const references = [
        { kind: 'inlineReference', name: 'Saved file', inlineReference: { scheme: 'file', path: '/example/source.js' } },
        { kind: 'inlineReference', inlineReference: { name: 'savedSymbol', location: { uri: { scheme: 'file', path: '/example/source.js' }, range: { startLineNumber: 3 } } } }
    ];
    for (const part of references) {
        await fs.appendFile(source, JSON.stringify({ kind: 2, k: ['requests', 0, 'response'], v: [part] }) + '\n');
    }
    const inspected = await library.inspectTranscript(source);
    assert.equal(inspected.turns[0].error, undefined);
    assert.match(inspected.turns[0].content, /PROMPT\nFirst original prompt/);
    assert.match(inspected.turns[0].content, /Final original answer/);
    assert.match(inspected.turns[0].content, /Saved reference: Saved file/);
    assert.match(inspected.turns[0].content, /Saved reference: savedSymbol/);
    assert.match(inspected.turns[0].content, /Recorded tool: saved-tool/);
    assert.deepEqual(JSON.parse(inspected.turns[0].details).response.slice(-2), references);
    const recorded = await library.createPackage(source, [0], 'Reference demo', inspected.sha256);
    assert.deepEqual(recorded.turns[0].snapshot.requests[0].response.slice(-2), references);
    await fs.appendFile(source, JSON.stringify({ kind: 2, k: ['requests', 1, 'response'], v: [{ kind: 'inlineReference' }] }) + '\n');
    assert.match((await library.inspectTranscript(source)).turns[1].error, /missing its URI/);
});

test('CLI uses JSON stdin, round-trips Unicode, and reports errors with a failing exit code', async context => {
    const { source, root, inspection } = await fixture(context);
    const cli = path.join(__dirname, '..', 'library-cli.js');
    const call = request => spawnSync(process.execPath, [cli], { input: JSON.stringify({ root, ...request }), encoding: 'utf8', timeout: 5000 });
    const captured = call({ command: 'capture', file: source, indices: [0], title: 'Demo \u03bb', sha256: inspection.sha256 });
    assert.equal(captured.status, 0, captured.stderr);
    assert.equal(JSON.parse(captured.stdout).result.title, 'Demo \u03bb');
    const listed = call({ command: 'list' });
    assert.equal(JSON.parse(listed.stdout).result.length, 1);
    const failed = call({ command: 'unknown' });
    assert.equal(failed.status, 1);
    assert.equal(JSON.parse(failed.stdout).ok, false);
    assert.match(JSON.parse(failed.stdout).error, /Unknown/);
});

test('capture accepts exactly 100 exchanges and 160 title characters, refusing the next value', async context => {
    const { source } = await fixture(context);
    const requests = Array.from({ length: 100 }, (_, index) => ({
        result: {}, message: { text: 'Recorded prompt ' + index }, response: [{ value: 'Recorded answer ' + index }]
    }));
    await fs.writeFile(source, JSON.stringify({ kind: 0, v: { requests } }) + '\n');
    const inspection = await library.inspectTranscript(source);
    const indices = requests.map((request, index) => index);
    const recording = await library.createPackage(source, indices, 'x'.repeat(160), inspection.sha256);
    assert.equal(recording.turns.length, 100);
    assert.equal(recording.title.length, 160);
    await assert.rejects(library.createPackage(source, [...indices, 100], 'Demo', inspection.sha256), /1 to 100/);
    await assert.rejects(library.createPackage(source, [0], 'x'.repeat(161), inspection.sha256), /1 to 160/);
});

test('oversized files and incomplete tool activity fail explicitly', async context => {
    const { source, directory } = await fixture(context);
    await fs.appendFile(source, JSON.stringify({ kind: 1, k: ['requests', 0, 'response', 1, 'isComplete'], v: false }) + '\n');
    assert.match((await library.inspectTranscript(source)).turns[0].error, /tool activity is incomplete/);
    const large = path.join(directory, 'oversized.json');
    const handle = await fs.open(large, 'w');
    try { await handle.truncate(library.MAX_BYTES + 1); } finally { await handle.close(); }
    await assert.rejects(library.readPackage(large), /no larger than 100 MiB/);
});
