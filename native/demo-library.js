const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { applyTranscriptRecord, extractRecording, validateEditorRecording } = require('./replay');

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

async function readBounded(file) {
    const handle = await fs.open(file, 'r');
    let failure;
    try {
        const before = await handle.stat();
        if (!before.isFile() || before.size > MAX_BYTES) throw new Error('Expected a file no larger than 100 MiB: ' + file);
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
    let snapshot;
    for (const line of bytes.toString('utf8').replace(/^\uFEFF/, '').split(/\r?\n/)) {
        if (line.trim()) snapshot = applyTranscriptRecord(snapshot, JSON.parse(line));
    }
    if (!Array.isArray(snapshot?.requests)) throw new Error('Expected a native VS Code JSONL transcript with saved requests.');
    return { snapshot, sha256: hash(bytes) };
}

async function inspectTranscript(file) {
    const { snapshot, sha256 } = await stableSnapshot(file);
    if (snapshot.requests.length > 10000) throw new Error('Transcript exceeds the 10,000-turn inspection limit.');
    const turns = snapshot.requests.map((request, index) => {
        let error;
        try { validateEditorRecording(extractRecording(file, snapshot, index)); }
        catch (failure) { error = failure.message; }
        return { index, prompt: request?.message?.text ?? '', details: JSON.stringify(request, null, 2), error };
    });
    return { title: snapshot.customTitle || path.basename(file), sha256, turns, notice: NOTICE };
}

function validatePackage(value) {
    if (value?.format !== FORMAT || value.version !== 1 || !uuid.test(value.id) || typeof value.createdAt !== 'string' || !Number.isFinite(Date.parse(value.createdAt))) throw new Error('Unsupported or invalid demo recording package.');
    titleOf(value.title);
    if (value.source?.kind !== 'vscode-native-jsonl' || typeof value.source.fileName !== 'string' || !value.source.fileName || value.source.fileName.length > 260 || !/^[a-f0-9]{64}$/.test(value.source.sha256) || value.notice !== NOTICE) throw new Error('Invalid demo recording provenance or fidelity notice.');
    if (!Array.isArray(value.turns) || !value.turns.length || value.turns.length > MAX_TURNS) throw new Error('A demo must contain 1 to 100 exchanges.');
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
        source: { kind: 'vscode-native-jsonl', fileName: path.basename(file), sessionId: snapshot.sessionId, sha256 },
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
    return value.turns.map(turn => validateEditorRecording(extractRecording(file, turn.snapshot, 0)));
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
    return { id: entry.id, title: entry.title, createdAt: entry.recording.createdAt, count: entry.recording.turns.length, source: entry.recording.source.fileName, preview: entry.recording.turns[0].snapshot.requests[0].message.text, notice: entry.recording.notice };
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

async function sessionSummary(file) {
    const handle = await fs.open(file, 'r');
    try {
        const buffer = Buffer.alloc(1024 * 1024);
        const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
        const prefix = buffer.subarray(0, bytesRead).toString('utf8').replace(/^\uFEFF/, '');
        const newline = prefix.indexOf('\n');
        if (newline < 0 && (await handle.stat()).size > bytesRead) {
            return { title: path.basename(file), preview: 'Preview unavailable: initial snapshot exceeds the 1 MiB discovery preview limit. Load to inspect.' };
        }
        const record = JSON.parse(newline < 0 ? prefix : prefix.slice(0, newline));
        if (record.kind !== 0 || !Array.isArray(record.v?.requests)) return { title: path.basename(file), preview: 'Preview unavailable: no initial snapshot. Load to inspect.' };
        const prompt = record.v.requests.find(request => typeof request?.message?.text === 'string')?.message.text;
        return { title: record.v.customTitle || prompt?.slice(0, 100) || path.basename(file), preview: prompt?.slice(0, 200) || 'No prompt in the initial snapshot. Load to inspect.' };
    } finally { await handle.close(); }
}

async function discoverSessions(storageRoot) {
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
        let project = workspace.name;
        try {
            const metadata = JSON.parse((await readBounded(path.join(directory, 'workspace.json'))).toString('utf8'));
            project = metadata.folder || metadata.workspace || project;
        } catch (error) { if (error.code !== 'ENOENT') throw new Error('Cannot read workspace metadata at ' + directory + ': ' + error.message); }
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
    for (const session of recent) {
        try { Object.assign(session, await sessionSummary(session.file)); }
        catch (error) { session.title = session.session; session.preview = 'Preview unavailable: ' + error.message; }
    }
    return { sessions: recent, notice: 'Up to 200 recent sessions. Titles/opening prompts use the initial snapshot; Load reconstructs the final saved conversation. Other profiles can be opened with Browse.' };
}

module.exports = { FORMAT, NOTICE, MAX_BYTES, defaultLibraryRoot, inspectTranscript, createPackage, validatePackage, readPackage, packageRecordings, readEntry, listDemos, addPackage, renameDemo, deleteDemo, exportDemo, discoverSessions };
