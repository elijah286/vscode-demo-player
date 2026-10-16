const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { recordedReference, inlineReferenceLabel, savedEditMarkdown } = require('../saved-parts');
const { nativeResponsePart } = require('../native-response');
const { responseTimeline, extractRecording, validateEditorRecording } = require('../replay');
const library = require('../demo-library');

const fileUri = { $mid: 1, scheme: 'file', path: '/C:/Recorded/Missing folder', fsPath: 'C:\\Recorded\\Missing folder', external: 'file:///c%3A/Recorded/Missing%20folder', _sep: 1 };
const reference = { kind: 'inlineReference', inlineReference: fileUri };

function nativeStub() {
    const calls = [];
    const vscode = {
        MarkdownString: class { constructor(value) { this.value = value; } },
        ChatResponseMarkdownPart: class { constructor(value) { this.value = value; } },
        Uri: {
            from: value => ({ type: 'components', value }),
            parse: (value, strict) => ({ type: 'string', value, strict }),
            file: value => ({ type: 'file', value })
        },
        Range: class { constructor(...coordinates) { this.coordinates = coordinates; } },
        Location: class { constructor(uri, range) { this.uri = uri; this.range = range; } },
        ChatResponseAnchorPart: class { constructor(value, title) { this.value = value; this.title = title; calls.push('anchor'); } },
        ChatToolInvocationPart: class { constructor() { calls.push('tool'); throw new Error('A reference must never become a tool call.'); } }
    };
    return { vscode, calls };
}

test('serialized VS Code URI references become native anchors without accessing the original path', () => {
    const { vscode, calls } = nativeStub();
    const before = structuredClone(reference);
    const recording = extractRecording('', { requests: [{ result: {}, message: { text: 'Original prompt' }, response: [reference] }] }, 0);
    validateEditorRecording(recording);
    const event = responseTimeline(recording.request.response)[0];
    const displayed = nativeResponsePart(vscode, event);
    assert.ok(displayed instanceof vscode.ChatResponseAnchorPart);
    assert.deepEqual(displayed.value, { type: 'components', value: { scheme: 'file', path: fileUri.path } });
    assert.deepEqual(calls, ['anchor']);
    assert.deepEqual(reference, before);
});

test('URI, filesystem, and serialized external reference forms are validated explicitly', () => {
    for (const value of ['https://example.test/docs?q=saved#section', 'C:\\Recorded\\Missing.txt', '\\\\server\\share\\recorded.txt', { fsPath: 'C:\\Recorded\\Missing.txt' }, { external: 'file:///C:/Recorded/Missing.txt' }]) {
        const target = recordedReference({ kind: 'inlineReference', inlineReference: value });
        assert.ok(['string', 'file'].includes(target.uri.kind));
        assert.equal(typeof inlineReferenceLabel({ kind: 'inlineReference', inlineReference: value }), 'string');
    }
    for (const value of [undefined, {}, 'relative/path', 'command:workbench.action.files.openFile', 'javascript:alert(1)', { scheme: 'command', path: 'run' }]) {
        assert.throws(() => recordedReference({ kind: 'inlineReference', inlineReference: value }), /reference.*(URI|scheme|file path)/i);
    }
    assert.throws(() => recordedReference({ kind: 'inlineReference', inlineReference: { scheme: 'file', path: '/C:/file', query: 1 } }), /component/);
});

test('saved editor locations preserve one-based source ranges as zero-based native ranges', () => {
    const { vscode } = nativeStub();
    const part = { kind: 'inlineReference', name: 'Original source label', inlineReference: { uri: fileUri, range: { startLineNumber: 3, startColumn: 2, endLineNumber: 5, endColumn: 9 } } };
    const displayed = nativeResponsePart(vscode, { kind: 'inlineReference', part });
    assert.equal(displayed.title, 'Original source label');
    assert.ok(displayed.value instanceof vscode.Location);
    assert.deepEqual(displayed.value.range.coordinates, [2, 1, 4, 8]);
    assert.deepEqual(displayed.value.uri.value, { scheme: 'file', path: fileUri.path });
});

test('serialized API ranges, symbol locations, and URI query/fragment metadata survive', () => {
    const range = { start: { line: 1, character: 0 }, end: { line: 2, character: 8 } };
    for (const savedRange of [range, [range.start, range.end]]) {
        const part = { kind: 'inlineReference', inlineReference: { name: 'Saved symbol', location: { uri: { ...fileUri, authority: '', query: 'saved=1', fragment: 'L2' }, range: savedRange } } };
        const target = recordedReference(part);
        assert.equal(target.title, 'Saved symbol');
        assert.deepEqual(target.range, [1, 0, 2, 8]);
        assert.equal(target.uri.value.query, 'saved=1');
        assert.equal(target.uri.value.fragment, 'L2');
    }
    const externalSymbol = recordedReference({ kind: 'inlineReference', inlineReference: { name: 'Saved external symbol', location: { uri: { external: 'https://example.test/source' }, range } } });
    assert.equal(externalSymbol.title, 'Saved external symbol');
    assert.deepEqual(externalSymbol.range, [1, 0, 2, 8]);
    for (const invalid of [null, {}, { startLineNumber: 0, startColumn: 1, endLineNumber: 1, endColumn: 1 }, { start: { line: 2, character: 0 }, end: { line: 1, character: 0 } }]) {
        assert.throws(() => recordedReference({ kind: 'inlineReference', inlineReference: { uri: fileUri, range: invalid } }), /invalid source range/);
    }
});

test('capture, import, playback, and history timelines retain inline references and exact assistant text', async context => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'reference-capture-test-'));
    context.after(() => fs.rm(directory, { recursive: true, force: true }));
    const source = path.join(directory, 'conversation.jsonl');
    const request = { result: {}, message: { text: 'Original request' }, response: [{ value: 'Original prefix ' }, reference, { value: ' original suffix.' }] };
    await fs.writeFile(source, JSON.stringify({ kind: 0, v: { requests: [request] } }) + '\n');
    const original = await fs.readFile(source);
    const preview = await library.inspectTranscript(source);
    assert.equal(preview.turns[0].error, undefined);
    const recording = await library.createPackage(source, [0], 'Reference demo', preview.sha256);
    const root = path.join(directory, 'library');
    const entry = await library.addPackage(root, recording);
    const exported = path.join(directory, 'export.demo-recording.json');
    await library.exportDemo(root, entry.id, exported);
    await library.addPackage(path.join(directory, 'imported'), await library.readPackage(exported));
    assert.deepEqual(await fs.readFile(source), original);
    await fs.unlink(source);
    const selected = (await library.packageRecordings(exported))[0];
    assert.deepEqual(selected.request, request);
    const timeline = responseTimeline(selected.request.response);
    assert.deepEqual(timeline.filter(event => event.kind === 'inlineReference').map(event => event.part), [reference]);
    assert.equal(timeline.filter(event => event.kind === 'markdown').map(event => event.value).join(''), 'Original prefix  original suffix.');
    assert.equal(timeline.filter(event => ['toolPending', 'toolComplete'].includes(event.kind)).length, 0);
});

test('combined native renderer preserves read-only edit formatting without applying edits or replacing reference anchors', () => {
    const { vscode, calls } = nativeStub();
    const part = {
        kind: 'textEditGroup', done: true, uri: { fsPath: 'C:\\Synthetic\\Missing.txt' },
        edits: [[{ text: '```\n[saved replacement](command:example.run)', range: { startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1 } }]]
    };
    const before = structuredClone(part);
    const displayed = nativeResponsePart(vscode, { kind: 'textEditGroup', part });
    assert.ok(displayed instanceof vscode.ChatResponseMarkdownPart);
    assert.equal(displayed.value.value, savedEditMarkdown(part));
    assert.equal(displayed.value.isTrusted, false);
    assert.equal(displayed.value.supportHtml, false);
    assert.deepEqual(part, before);
    assert.deepEqual(calls, []);
    assert.throws(() => nativeResponsePart(vscode, { kind: 'textEditGroup', part: { ...part, done: false } }), /incomplete/);
});

test('unsupported display kinds still fail instead of falling through to a fabricated tool record', () => {
    const { vscode, calls } = nativeStub();
    assert.throws(() => nativeResponsePart(vscode, { kind: 'futureDisplayPart', part: {} }), /no renderer/);
    assert.deepEqual(calls, []);
    const malformed = { result: {}, message: { text: 'Original request' }, response: [{ kind: 'inlineReference', inlineReference: {} }] };
    assert.throws(() => validateEditorRecording(extractRecording('', { requests: [malformed] }, 0)), /no supported absolute URI/);
});
