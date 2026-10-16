const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
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

test('discovery lists native sources across projects without reading or modifying conversations', async context => {
    const { directory, source } = await fixture(context);
    const storageRoot = path.join(directory, 'storage');
    const workspace = path.join(storageRoot, 'a'.repeat(32));
    await fs.mkdir(path.join(workspace, 'chatSessions'), { recursive: true });
    await fs.writeFile(path.join(workspace, 'workspace.json'), JSON.stringify({ folder: 'file:///C:/Example' }));
    const target = path.join(workspace, 'chatSessions', 'saved.jsonl');
    await fs.copyFile(source, target);
    const result = await library.discoverSessions(storageRoot);
    assert.equal(result.sessions.length, 1);
    assert.equal(result.sessions[0].project, 'file:///C:/Example');
    assert.equal(result.sessions[0].file, target);
    assert.equal(result.sessions[0].title, 'Original conversation');
    assert.equal(result.sessions[0].preview, 'First original prompt\r\n\u03bb');
    await fs.writeFile(path.join(workspace, 'chatSessions', 'damaged.jsonl'), '{incomplete');
    const withError = await library.discoverSessions(storageRoot);
    assert.match(withError.sessions.find(session => session.session === 'damaged.jsonl').preview, /Preview unavailable/);
    const missing = await library.discoverSessions(path.join(directory, 'missing'));
    assert.deepEqual(missing.sessions, []);
    assert.match(missing.notice, /No standard/);
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
