const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { fileURLToPath } = require('node:url');
const { sdkSnapshot } = require('./sdk-transcript');
const { applyTranscriptRecord, extractRecording, validateEditorRecording, kindOf } = require('./replay');
const { INTERNAL_PARTS, inlineReferenceLabel, savedEditText } = require('./saved-parts');
const { controlView } = require('./control-server');

const FORMAT = 'vscode-demo-recording';
const MAX_BYTES = 100 * 1024 * 1024;
const MAX_TURNS = 100;
const MAX_DEMOS = 1000;
const NOTICE = 'Recorded payloads only. External files, images, and link targets are not bundled. Tool transitions and timing are reconstructed for presentation.';
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const contentHash = value => hash(JSON.stringify(value));

function serializeBounded(value, indentation) {
    const text = JSON.stringify(value, null, indentation);
    if (Buffer.byteLength(text) > MAX_BYTES) throw new Error('The recording exceeds the 100 MiB storage limit.');
    return text;
}

function titleOf(value) {
    if (typeof value !== 'string' || !value.trim() || value.trim().length > 160) throw new Error('A demo title must contain 1 to 160 characters.');
    return value.trim();
}

function defaultLibraryRoot() {
    if (!process.env.LOCALAPPDATA) throw new Error('LOCALAPPDATA is not set. Supply an explicit library root.');
    return path.join(process.env.LOCALAPPDATA, 'VSCodeDemoPlayer', 'demos');
}

async function readBounded(file, limit = MAX_BYTES) {
    const handle = await fs.open(file, 'r');
    let failure;
    try {
        const before = await handle.stat();
        if (!before.isFile() || before.size > limit) throw new Error('Expected a file no larger than ' + (limit / 1024 / 1024) + ' MiB: ' + file);
        const buffer = Buffer.alloc(before.size + 1);
        let length = 0;
        while (length < buffer.length) {
            const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
            if (!bytesRead) break;
            length += bytesRead;
        }
        const after = await handle.stat();
        if (length !== before.size || after.size !== before.size || after.mtimeMs !== before.mtimeMs) throw new Error('Source changed during capture. Wait until the conversation is saved, then retry.');
        return buffer.subarray(0, length);
    } catch (error) { failure = error; throw error; }
    finally {
        try { await handle.close(); }
        catch (error) { throw failure ? new AggregateError([failure, error], 'Reading and closing the recording failed.') : error; }
    }
}

async function stableSnapshot(file) {
    const bytes = await readBounded(file);
    if (!bytes.equals(await readBounded(file))) throw new Error('Source changed during capture. Retry after it has finished saving.');
    const snapshot = parseSnapshot(bytes);
    if (!Array.isArray(snapshot?.requests)) throw new Error('Expected a native VS Code JSONL transcript with saved requests.');
    return { snapshot, sha256: hash(bytes) };
}

function parseSnapshot(bytes) {
    const records = bytes.toString('utf8').replace(/^\uFEFF/, '').split(/\r?\n/).filter(line => line.trim()).map(line => JSON.parse(line));
    if (records[0]?.type === 'session.start') {
        if (records.length > 100000) throw new Error('SDK recording exceeds the 100,000-event limit.');
        return sdkSnapshot(records);
    }
    return records.reduce(applyTranscriptRecord, undefined);
}

async function inspectTranscript(file) {
    const { snapshot, sha256 } = await stableSnapshot(file);
    if (snapshot.requests.length > 10000) throw new Error('Transcript exceeds the 10,000-turn inspection limit.');
    const turns = snapshot.requests.map((request, index) => {
        let error;
        try { validateEditorRecording(extractRecording(file, snapshot, index)); }
        catch (failure) { error = failure.message; }
        const prompt = request?.message?.text ?? '';
        const response = (Array.isArray(request?.response) ? request.response : []).map(part => {
            const kind = kindOf(part);
            if (INTERNAL_PARTS.has(kind)) return '';
            if (kind === 'markdown') return typeof part === 'string' ? part : part.value;
            if (kind === 'thinking') return '[Thinking]\n' + (Array.isArray(part.value) ? part.value.join('\n') : part.value ?? '');
            if (kind === 'toolInvocationSerialized') return '[Recorded tool: ' + part.toolId + ']\n' + (part.pastTenseMessage?.value ?? part.pastTenseMessage ?? part.invocationMessage?.value ?? part.invocationMessage ?? '');
            if (kind === 'inlineReference' && !error) return '[Saved reference: ' + inlineReferenceLabel(part) + ']';
            if (kind === 'textEditGroup' && !error) return savedEditText(part);
            if (kind === 'recordedSdkEvent') return '[Recorded SDK events - read-only]\n' + JSON.stringify(part.events, null, 2);
            return '[Saved ' + kind + ']\n' + JSON.stringify(part, null, 2);
        }).filter(Boolean).join('\n\n');
        const archivedEdits = !error && request.response.some(part => kindOf(part) === 'textEditGroup');
        const archivedEvents = !error && request.response.some(part => kindOf(part) === 'recordedSdkEvent');
        return {
            index, prompt, content: 'PROMPT\n' + prompt + '\n\nRESPONSE\n' + response,
            details: JSON.stringify(request, null, 2), error,
            status: error ? 'unavailable' : archivedEdits ? 'archived-edits' : archivedEvents ? 'archived-events' : 'ready'
        };
    });
    const summary = await sessionSummary(file, snapshot);
    const sdkNotice = snapshot.sourceKind === 'copilot-sdk-jsonl' ?
        'SDK text and tool transitions are normalized for playback. Original events and attachment metadata remain in the full saved payload; external assets are not bundled.' : '';
    return { title: summary.title, sha256, turns, notice: [NOTICE, sdkNotice, summary.warning].filter(Boolean).join(' ') };
}

function validatePackage(value) {
    if (value?.format !== FORMAT || value.version !== 1 || !uuid.test(value.id) || typeof value.createdAt !== 'string' || !Number.isFinite(Date.parse(value.createdAt))) throw new Error('Unsupported or invalid demo recording package.');
    titleOf(value.title);
    if (!['vscode-native-jsonl', 'copilot-sdk-jsonl'].includes(value.source?.kind) || typeof value.source.fileName !== 'string' || !value.source.fileName || value.source.fileName.length > 260 || !/^[a-f0-9]{64}$/.test(value.source.sha256) || value.notice !== NOTICE) throw new Error('Invalid demo recording provenance or fidelity notice.');
    if (!Array.isArray(value.turns) || !value.turns.length || value.turns.length > MAX_TURNS) throw new Error('A demo must contain 1 to 100 exchanges.');
    validatePromptSummaries(value.promptSummaries, value.turns.length);
    const indices = new Set();
    for (const turn of value.turns) {
        if (!Number.isInteger(turn.sourceIndex) || turn.sourceIndex < 0 || indices.has(turn.sourceIndex) || turn.snapshot?.requests?.length !== 1) throw new Error('Invalid or duplicate recorded turn.');
        indices.add(turn.sourceIndex);
        if (contentHash(turn.snapshot) !== turn.sha256) throw new Error('Recorded content hash mismatch. The package may be damaged or modified.');
        validateEditorRecording(extractRecording('', turn.snapshot, 0));
    }
    return value;
}

async function createPackage(file, indices, title, expectedHash) {
    title = titleOf(title);
    if (!Array.isArray(indices) || !indices.length || indices.length > MAX_TURNS || indices.some(index => !Number.isInteger(index) || index < 0) || new Set(indices).size !== indices.length) throw new Error('Select 1 to 100 distinct exchange indices in playback order.');
    if (!/^[a-f0-9]{64}$/.test(expectedHash ?? '')) throw new Error('Inspect the conversation before capturing it.');
    const { snapshot, sha256 } = await stableSnapshot(file);
    if (sha256 !== expectedHash) throw new Error('The conversation changed after preview. Reload it and review the selection again.');
    const turns = indices.map(sourceIndex => {
        validateEditorRecording(extractRecording(file, snapshot, sourceIndex));
        const selected = JSON.parse(JSON.stringify({
            sessionId: snapshot.sessionId,
            responderUsername: snapshot.responderUsername,
            inputState: snapshot.inputState?.selectedModel ? { selectedModel: snapshot.inputState.selectedModel } : undefined,
            requests: [snapshot.requests[sourceIndex]]
        }));
        return { sourceIndex, sha256: contentHash(selected), snapshot: selected };
    });
    const value = validatePackage({
        format: FORMAT, version: 1, id: crypto.randomUUID(), title,
        createdAt: new Date().toISOString(),
        source: { kind: snapshot.sourceKind || 'vscode-native-jsonl', fileName: path.basename(file), sessionId: snapshot.sessionId, sha256 },
        notice: NOTICE, turns
    });
    serializeBounded(value);
    return value;
}

async function readPackage(file) {
    return validatePackage(JSON.parse((await readBounded(file)).toString('utf8').replace(/^\uFEFF/, '')));
}

async function packageRecordings(file) {
    const raw = JSON.parse((await readBounded(file)).toString('utf8'));
    const value = raw.format === FORMAT ? validatePackage(raw) : validateEntry(raw).recording;
    return value.turns.map((turn, index) => {
        const recording = validateEditorRecording(extractRecording(file, turn.snapshot, 0));
        if (value.promptSummaries?.[index]) recording.promptSummary = value.promptSummaries[index];
        return recording;
    });
}

function validatePromptSummaries(summaries, count) {
    if (summaries === undefined) return;
    if (!Array.isArray(summaries) || summaries.length !== count || summaries.some(value =>
        value !== null && (typeof value !== 'string' || !value.trim() || value.length > 200 || /[\r\n]/.test(value)))) {
        throw new Error('Supply one summary per exchange: null for the original excerpt, or 1 to 200 characters on one line.');
    }
}

async function savePromptSummaries(root, id, summaries, expected) {
    return withLock(root, async () => {
        const entry = await readEntry(root, id);
        validatePromptSummaries(summaries, entry.recording.turns.length);
        if (summaries === undefined) throw new Error('Supply the summaries to save.');
        if (JSON.stringify(entry.recording.promptSummaries ?? null) !== JSON.stringify(expected)) {
            throw new Error('Prompt summaries changed since opening this editor. Reopen it before saving.');
        }
        entry.recording.promptSummaries = summaries;
        await atomicEntry(root, entry, true);
        return summarize(entry);
    });
}

function entryPath(root, id) {
    if (!uuid.test(id)) throw new Error('Invalid library entry identifier.');
    return path.join(root, id + '.demo.json');
}

async function readEntry(root, id) {
    const file = entryPath(root, id);
    if ((await fs.lstat(file)).isSymbolicLink()) throw new Error('Library entries must not be symbolic links.');
    return validateEntry(JSON.parse((await readBounded(file)).toString('utf8')), id);
}

function validateEntry(entry, id = entry?.id) {
    if (entry?.version !== 1 || !uuid.test(entry.id) || entry.id !== id) throw new Error('Invalid library entry.');
    titleOf(entry.title);
    validatePackage(entry.recording);
    return entry;
}

async function libraryIds(root) {
    let names;
    try { names = await fs.readdir(root); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
    const ids = names.filter(name => name.endsWith('.demo.json')).map(name => name.slice(0, -10));
    if (ids.length > MAX_DEMOS) throw new Error('Library exceeds the 1,000-demo limit.');
    return ids;
}

function summarize(entry) {
    const recordings = entry.recording.turns.map((turn, index) => {
        const recording = extractRecording('', turn.snapshot, 0);
        if (entry.recording.promptSummaries?.[index]) recording.promptSummary = entry.recording.promptSummaries[index];
        return recording;
    });
    const { overlay, progress } = controlView({ phase: 'ready', turnIndex: 0, recordings });
    return { id: entry.id, title: entry.title, createdAt: entry.recording.createdAt, count: entry.recording.turns.length, source: entry.recording.source.fileName, preview: entry.recording.turns[0].snapshot.requests[0].message.text, notice: entry.recording.notice, presentation: { overlay, progress } };
}

async function listDemos(root) {
    const entries = [];
    for (const id of await libraryIds(root)) entries.push(summarize(await readEntry(root, id)));
    return entries.sort((a, b) => b.createdAt.localeCompare(a.createdAt) || a.id.localeCompare(b.id));
}

async function withLock(root, operation) {
    await fs.mkdir(root, { recursive: true });
    const lockPath = path.join(root, '.library.lock');
    let lock;
    try { lock = await fs.open(lockPath, 'wx'); }
    catch (error) { if (error.code === 'EEXIST') throw new Error('The demo library is busy. If a previous process crashed, inspect and remove its .library.lock before retrying.'); throw error; }
    let failure;
    try { return await operation(); }
    catch (error) { failure = error; throw error; }
    finally {
        try { await lock.close(); await fs.unlink(lockPath); }
        catch (error) { throw failure ? new AggregateError([failure, error], 'Library operation and lock cleanup failed.') : error; }
    }
}

async function atomicEntry(root, entry, replacing = false) {
    const destination = entryPath(root, entry.id);
    const temporary = destination + '.' + crypto.randomUUID() + '.tmp';
    let failure;
    try {
        await fs.writeFile(temporary, serializeBounded(entry), { flag: 'wx', mode: 0o600 });
        if (!replacing) {
            try { await fs.access(destination); }
            catch (error) { if (error.code !== 'ENOENT') throw error; await fs.rename(temporary, destination); return; }
            throw new Error('Library entry already exists.');
        }
        await fs.rename(temporary, destination);
    } catch (error) { failure = error; throw error; }
    finally {
        try { await fs.rm(temporary, { force: true }); }
        catch (error) { throw failure ? new AggregateError([failure, error], 'Writing the demo and cleaning its temporary file failed.') : error; }
    }
}

async function addPackage(root, recording) {
    validatePackage(recording);
    return withLock(root, async () => {
        const ids = await libraryIds(root);
        if (ids.length >= MAX_DEMOS) throw new Error('Library is full (1,000 demos).');
        for (const id of ids) if ((await readEntry(root, id)).recording.id === recording.id) throw new Error('This recording is already in the demo library.');
        const entry = { version: 1, id: crypto.randomUUID(), title: recording.title, recording };
        await atomicEntry(root, entry);
        return summarize(entry);
    });
}

async function renameDemo(root, id, title) {
    title = titleOf(title);
    return withLock(root, async () => {
        const entry = await readEntry(root, id);
        entry.title = title;
        await atomicEntry(root, entry, true);
        return summarize(entry);
    });
}

async function deleteDemo(root, id) {
    return withLock(root, async () => {
        await readEntry(root, id);
        await fs.unlink(entryPath(root, id));
        return { deleted: id };
    });
}

async function exportDemo(root, id, file) {
    const entry = await readEntry(root, id);
    const content = serializeBounded({ ...entry.recording, title: entry.title }, 2);
    await fs.writeFile(file, content, { flag: 'wx', mode: 0o600 });
    return { file };
}

async function sessionIndex(directory) {
    const database = path.join(directory, 'state.vscdb');
    try { await fs.access(database); }
    catch (error) {
        if (error.code === 'ENOENT') return { entries: {} };
        return { entries: {}, warning: 'VS Code chat titles could not be read: ' + error.message };
    }
    let db;
    try {
        const { DatabaseSync } = require('node:sqlite');
        db = new DatabaseSync(database, { readOnly: true });
        const row = db.prepare('SELECT CASE WHEN length(CAST(value AS BLOB)) <= 8388608 THEN value ELSE NULL END AS value FROM ItemTable WHERE key = ?').get('chat.ChatSessionStore.index');
        if (!row) return { entries: {} };
        if (row.value === null) throw new Error('Saved session index exceeds the 8 MiB metadata limit.');
        const index = JSON.parse(row.value);
        if (!index.entries || typeof index.entries !== 'object' || Array.isArray(index.entries)) throw new Error('Invalid saved session index.');
        return { entries: index.entries };
    } catch (error) {
        return { entries: {}, warning: 'VS Code chat titles could not be read: ' + error.message };
    } finally { if (db) db.close(); }
}

async function sessionSummary(file, snapshot, index) {
    index ??= await sessionIndex(path.dirname(path.dirname(file)));
    const entry = index.entries[path.basename(file, '.jsonl')];
    if (!snapshot && typeof entry?.title === 'string' && entry.title.trim()) {
        return { title: entry.title, preview: 'Load to review the saved conversation.', warning: index.warning };
    }
    snapshot ??= (await stableSnapshot(file)).snapshot;
    const prompt = snapshot.requests.find(request => typeof request?.message?.text === 'string' && request.message.text.trim())?.message.text;
    return {
        title: [entry?.title, snapshot.customTitle, prompt?.slice(0, 100)].find(value => typeof value === 'string' && value.trim())?.trim() || 'Untitled conversation',
        preview: prompt?.slice(0, 200) || 'No saved opening prompt.',
        warning: index.warning
    };
}

function folderPath(value) {
    if (typeof value !== 'string' || !value.trim()) throw new Error('Select a project folder before discovering conversations.');
    const local = value.startsWith('file:') ? fileURLToPath(value) : value;
    return path.resolve(local).replace(/[\\/]+$/, '').toLowerCase();
}

async function discoverSessions(storageRoot, folder) {
    const selectedFolder = folderPath(folder);
    if (!(await fs.stat(folder)).isDirectory()) throw new Error('Select an existing project directory.');
    if (!storageRoot) {
        if (!process.env.APPDATA) throw new Error('APPDATA is not set. Select a transcript file manually.');
        storageRoot = path.join(process.env.APPDATA, 'Code', 'User', 'workspaceStorage');
    }
    const sessions = [];
    let workspaces;
    try { workspaces = await fs.readdir(storageRoot, { withFileTypes: true }); }
    catch (error) { if (error.code === 'ENOENT') return { sessions, notice: 'No standard VS Code workspace storage found. Browse to a native transcript instead.' }; throw error; }
    if (workspaces.length > 5000) throw new Error('Workspace discovery exceeds its 5,000-folder limit. Browse to a transcript instead.');
    for (const workspace of workspaces) {
        if (!workspace.isDirectory() || !/^[a-f0-9]{32}$/.test(workspace.name)) continue;
        const directory = path.join(storageRoot, workspace.name);
        let project;
        try {
            const metadata = JSON.parse((await readBounded(path.join(directory, 'workspace.json'))).toString('utf8'));
            if (!metadata.folder || folderPath(metadata.folder) !== selectedFolder) continue;
            project = folder;
        } catch (error) { if (error.code !== 'ENOENT') throw new Error('Cannot read workspace metadata at ' + directory + ': ' + error.message); }
        if (!project) continue;
        let files;
        try { files = await fs.readdir(path.join(directory, 'chatSessions'), { withFileTypes: true }); }
        catch (error) { if (error.code === 'ENOENT') continue; throw error; }
        for (const file of files) {
            if (!file.isFile() || !file.name.endsWith('.jsonl')) continue;
            const source = path.join(directory, 'chatSessions', file.name);
            const stat = await fs.stat(source);
            sessions.push({ file: source, project, modified: stat.mtime.toISOString(), session: file.name });
            if (sessions.length > 10000) throw new Error('Session discovery exceeds its 10,000-file limit. Browse to a transcript instead.');
        }
    }
    sessions.sort((a, b) => b.modified.localeCompare(a.modified));
    const recent = sessions.slice(0, 200);
    const indices = new Map();
    for (const session of recent) {
        const directory = path.dirname(path.dirname(session.file));
        if (!indices.has(directory)) indices.set(directory, await sessionIndex(directory));
        try { Object.assign(session, await sessionSummary(session.file, undefined, indices.get(directory))); }
        catch (error) {
            session.title = 'Unreadable conversation (' + session.modified.slice(0, 10) + ')';
            session.preview = 'Preview unavailable: ' + error.message;
        }
    }
    const warnings = [...new Set(recent.map(session => session.warning).filter(Boolean))];
    return { sessions: recent, notice: [
        recent.length ? 'Up to 200 recent conversations for the selected folder only. Names use the VS Code session index, with final saved titles/opening prompts as fallback.' : 'No saved conversations found for this folder in standard VS Code workspace storage.',
        'Other profiles and multi-root workspaces can be opened with Browse transcript.',
        ...warnings
    ].join(' ') };
}

module.exports = { FORMAT, NOTICE, MAX_BYTES, defaultLibraryRoot, inspectTranscript, createPackage, validatePackage, readPackage, packageRecordings, readEntry, listDemos, addPackage, renameDemo, deleteDemo, exportDemo, discoverSessions, readBounded, parseSnapshot, sessionIndex, validatePromptSummaries, savePromptSummaries };
