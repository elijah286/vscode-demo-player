const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { fileURLToPath } = require('node:url');
const { DatabaseSync } = require('node:sqlite');
const { readBounded, parseSnapshot, sessionIndex } = require('./demo-library');
const { extractRecording, validateEditorRecording, kindOf } = require('./replay');

const FILE_LIMIT = 8 * 1024 * 1024;
const SCAN_LIMIT = 256 * 1024 * 1024;
const ENTRY_LIMIT = 10000;
const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;

function localPath(value) {
    if (typeof value !== 'string' || !value.trim()) return null;
    return value.startsWith('file:') ? fileURLToPath(value) : value;
}

function instant(value) {
    if (value === null || value === undefined || value === '') return null;
    const time = typeof value === 'number' ? value : Date.parse(value);
    if (!Number.isFinite(time) || !Number.isFinite(new Date(time).getTime())) return null;
    const iso = new Date(time).toISOString();
    return /^\d{4}-/.test(iso) && !iso.startsWith('0000-') ? iso : null;
}

function projectName(value) {
    return value ? path.win32.basename(value.replace(/[\\/]+$/, '')) || value : 'No workspace';
}

async function discoverHistory(options = {}, progress = () => {}) {
    const appData = options.appData ?? process.env.APPDATA;
    const home = options.home ?? os.homedir();
    if (!appData) throw new Error('APPDATA is not set. Add an explicit history location.');
    if (options.locations !== undefined && (!Array.isArray(options.locations) || options.locations.length > 20 || options.locations.some(value => typeof value !== 'string' || !path.isAbsolute(value)))) {
        throw new Error('Supply at most 20 absolute additional history directories.');
    }
    const sdkRoot = path.join(home, '.copilot', 'session-state');
    const sources = [];
    const candidates = new Map();
    const warnings = [];
    let warningCount = 0;
    let bytes = 0;
    let truncated = false;
    function warn(message) {
        warningCount++;
        if (warnings.length < 100) warnings.push(message);
        progress({ phase: 'warning', message });
    }
    async function directories(root) {
        try {
            const entries = await fs.readdir(root, { withFileTypes: true });
            if (entries.length > ENTRY_LIMIT) {
                truncated = true;
                warn('History directory exceeds the 10,000-entry limit; only the first entries are considered: ' + root);
                return entries.slice(0, ENTRY_LIMIT);
            }
            return entries;
        } catch (error) {
            if (error.code === 'ENOENT') return [];
            warn(root + ': ' + error.message);
            return [];
        }
    }
    function add(row) {
        const key = path.resolve(row.file).toLowerCase();
        if (candidates.has(key)) return;
        if (candidates.size >= ENTRY_LIMIT) { truncated = true; return; }
        candidates.set(key, row);
    }
    async function transcripts(directory, projectPath, source, index = { entries: {} }) {
        if (index.warning) warn(directory + ': ' + index.warning);
        for (const entry of await directories(directory)) {
            if (!entry.isFile() || !/\.(jsonl|json)$/i.test(entry.name) || entry.name === 'index.json') continue;
            add({
                file: path.join(directory, entry.name), projectPath, source, index: index.entries[path.basename(entry.name, path.extname(entry.name))],
                missing: entry.name.endsWith('.json') ? 'Legacy JSON snapshot is discoverable but not a supported JSONL playback source.' : undefined
            });
        }
    }
    async function workspaces(root, source) {
        for (const entry of await directories(root)) {
            if (!entry.isDirectory()) continue;
            const directory = path.join(root, entry.name);
            let projectPath = null;
            try {
                const metadataFile = path.join(directory, 'workspace.json');
                const metadata = JSON.parse((await readBounded(metadataFile, 1024 * 1024)).toString('utf8'));
                projectPath = localPath(metadata.folder || metadata.workspace);
            } catch (error) {
                if (error.code !== 'ENOENT') warn(directory + ': ' + error.message);
            }
            await transcripts(path.join(directory, 'chatSessions'), projectPath, source, await sessionIndex(directory));
        }
    }
    async function agentSessions(root, source) {
        for (const entry of await directories(root)) {
            if (!entry.isDirectory() || !uuid.test(entry.name)) continue;
            const file = path.join(root, entry.name, 'session.db');
            let db;
            try {
                db = new DatabaseSync(file, { readOnly: true });
                const metadata = Object.create(null);
                const rows = db.prepare("SELECT key, CASE WHEN length(CAST(value AS BLOB)) <= 1048576 THEN value ELSE NULL END AS value FROM session_metadata WHERE key IN ('customTitle', 'copilot.workingDirectory', 'defaultChatProviderData') LIMIT 4").all();
                if (rows.length > 3 || new Set(rows.map(row => row.key)).size !== rows.length) throw new Error('Agent metadata contains duplicate keys.');
                for (const row of rows) {
                    if (row.value === null) throw new Error('Agent metadata exceeds the 1 MiB per-value limit.');
                    let value = row.value;
                    try { value = JSON.parse(value); } catch { /* Metadata values may be unquoted strings. */ }
                    metadata[row.key] = value;
                }
                const id = metadata.defaultChatProviderData?.sdkSessionId;
                add({
                    file: typeof id === 'string' && uuid.test(id) ? path.join(sdkRoot, id, 'events.jsonl') : file,
                    projectPath: localPath(metadata['copilot.workingDirectory']), source,
                    index: { title: typeof metadata.customTitle === 'string' ? metadata.customTitle : undefined },
                    missing: !(typeof id === 'string' && uuid.test(id)) ? 'Agent database has no supported SDK recording link; local-only agent turns are not supported.' : undefined
                });
            } catch (error) {
                warn(file + ': ' + error.message);
                add({ file, projectPath: null, source, missing: 'Unreadable agent database: ' + error.message });
            } finally { if (db) db.close(); }
        }
    }
    async function sdkSessions(root, source) {
        for (const entry of await directories(root)) {
            if (entry.isDirectory() && uuid.test(entry.name)) add({ file: path.join(root, entry.name, 'events.jsonl'), projectPath: null, source });
        }
    }
    for (const product of ['Code', 'Code - Insiders']) {
        const root = path.join(appData, product);
        sources.push({ kind: 'workspaces', root: path.join(root, 'User', 'workspaceStorage'), label: product + ' chat' });
        sources.push({ kind: 'transcripts', root: path.join(root, 'User', 'globalStorage', 'emptyWindowChatSessions'), label: product + ' empty-window chat' });
        sources.push({ kind: 'agents', root: path.join(root, 'agentSessionData'), label: product + ' agent' });
        for (const profile of await directories(path.join(root, 'User', 'profiles'))) {
            if (!profile.isDirectory()) continue;
            const base = path.join(root, 'User', 'profiles', profile.name);
            sources.push({ kind: 'workspaces', root: path.join(base, 'workspaceStorage'), label: product + ' profile ' + profile.name });
            sources.push({ kind: 'transcripts', root: path.join(base, 'globalStorage', 'emptyWindowChatSessions'), label: product + ' profile ' + profile.name });
        }
    }
    sources.push({ kind: 'sdk', root: sdkRoot, label: 'Copilot SDK / CLI' });
    for (const root of options.locations || []) {
        if (!(await fs.stat(root)).isDirectory()) throw new Error('Additional history location is not a directory: ' + root);
        const name = path.basename(root).toLowerCase();
        if (name === 'workspacestorage') sources.push({ kind: 'workspaces', root, label: 'Added VS Code storage' });
        else if (name === 'agentsessiondata') sources.push({ kind: 'agents', root, label: 'Added agent storage' });
        else if (name === 'session-state') sources.push({ kind: 'sdk', root, label: 'Added SDK storage' });
        else {
            sources.push({ kind: 'transcripts', root, label: 'Added transcripts' });
            sources.push({ kind: 'workspaces', root: path.join(root, 'workspaceStorage'), label: 'Added profile storage' });
            sources.push({ kind: 'transcripts', root: path.join(root, 'globalStorage', 'emptyWindowChatSessions'), label: 'Added profile chat' });
            sources.push({ kind: 'workspaces', root: path.join(root, 'User', 'workspaceStorage'), label: 'Added VS Code profile' });
            sources.push({ kind: 'transcripts', root: path.join(root, 'User', 'globalStorage', 'emptyWindowChatSessions'), label: 'Added empty-window chat' });
            sources.push({ kind: 'agents', root: path.join(root, 'agentSessionData'), label: 'Added agent storage' });
        }
    }
    for (const source of sources) {
        progress({ phase: 'source', message: 'Finding conversations: ' + source.label, found: candidates.size });
        if (source.kind === 'workspaces') await workspaces(source.root, source.label);
        else if (source.kind === 'agents') await agentSessions(source.root, source.label);
        else if (source.kind === 'sdk') await sdkSessions(source.root, source.label);
        else await transcripts(source.root, null, source.label);
    }
    const sessions = [];
    for (const candidate of candidates.values()) {
        const indexedTitle = typeof candidate.index?.title === 'string' && candidate.index.title.trim() ? candidate.index.title : null;
        const row = {
            file: candidate.file, title: indexedTitle || 'Untitled conversation',
            projectPath: candidate.projectPath, project: projectName(candidate.projectPath),
            agent: null, started: null, lastActivity: null, durationSeconds: null, promptCount: null,
            source: candidate.source, status: 'Load to inspect', detail: '', loadable: !candidate.missing
        };
        progress({ phase: 'metadata', message: 'Indexing ' + (sessions.length + 1) + ' of ' + candidates.size, found: candidates.size });
        try {
            if (candidate.missing) throw new Error(candidate.missing);
            const stat = await fs.stat(row.file);
            row.savedAt = stat.mtime.toISOString();
            row.started = instant(candidate.index?.timing?.created);
            row.lastActivity = instant(candidate.index?.timing?.lastRequestEnded ?? candidate.index?.lastMessageDate);
            if (stat.size > FILE_LIMIT || bytes + stat.size > SCAN_LIMIT) {
                row.detail = 'Metadata not indexed: 8 MiB per-file / 256 MiB per-refresh limit. Load this recording to inspect it.';
            } else {
                bytes += stat.size;
                const snapshot = parseSnapshot(await readBounded(row.file, stat.size));
                if (!Array.isArray(snapshot?.requests)) throw new Error('No saved requests in this recording.');
                const requests = snapshot.requests;
                if (requests.length > 10000) throw new Error('Transcript exceeds the 10,000-turn inspection limit.');
                row.projectPath ??= localPath(snapshot.projectPath);
                row.project = projectName(row.projectPath);
                if ([candidate.index?.title, snapshot.customTitle].some(value => value !== undefined && value !== null && typeof value !== 'string')) warn(row.file + ': Invalid saved title metadata; using an available text title or opening prompt.');
                row.title = [indexedTitle, snapshot.customTitle, requests.find(request => typeof request?.message?.text === 'string')?.message.text.slice(0, 100)].find(value => typeof value === 'string' && value.trim()) || row.title;
                row.promptCount = requests.length;
                row.agent = [...new Set(requests.map(request => request?.agent?.fullName || request?.agent?.name || snapshot.responderUsername).filter(value => typeof value === 'string' && value.trim()))].join(', ') || null;
                const times = requests.flatMap(request => [instant(request?.timestamp), instant(request?.lastActivity), instant(request?.modelState?.completedAt)]).filter(Boolean).sort();
                row.started ??= instant(snapshot.creationDate) || times[0] || null;
                row.lastActivity = [row.lastActivity, ...times].filter(Boolean).sort().at(-1) || null;
                const failures = [];
                for (let index = 0; index < requests.length; index++) {
                    try { validateEditorRecording(extractRecording(row.file, snapshot, index)); }
                    catch (error) { failures.push(error.message); }
                }
                const archived = requests.some(request => Array.isArray(request?.response) && request.response.some(part => ['textEditGroup', 'recordedSdkEvent', 'confirmation', 'workspaceEdit', 'questionCarousel', 'progressTaskSerialized'].includes(kindOf(part))));
                row.status = !requests.length ? 'Empty' : failures.length === requests.length ? 'Incomplete / unsupported' : failures.length ? 'Partial' : archived ? 'Read-only parts' : 'Ready';
                row.detail = failures.length ? failures.length + ' of ' + requests.length + ' exchanges unavailable. ' + failures[0] :
                    snapshot.sourceKind === 'copilot-sdk-jsonl' ? 'SDK text and tool transitions are normalized. Original events and attachments metadata are retained in the full saved payload; external assets are not bundled.' : 'Load to review the complete saved conversation.';
            }
        } catch (error) {
            row.status = 'Unavailable'; row.detail = error.message; row.loadable = false;
            warn(row.file + ': ' + error.message);
        }
        if (row.started && row.lastActivity && row.lastActivity >= row.started) row.durationSeconds = (Date.parse(row.lastActivity) - Date.parse(row.started)) / 1000;
        else if (row.started && row.lastActivity) row.detail += ' Recorded end precedes start; duration is unavailable.';
        sessions.push(row);
        progress({ phase: 'entry', session: row });
    }
    sessions.sort((a, b) => (b.lastActivity || '').localeCompare(a.lastActivity || '') || a.title.localeCompare(b.title));
    if (truncated) warn('History discovery reached its 10,000-entry/recording limit. Some sources were not indexed. Narrow the added history locations.');
    return {
        sessions, warnings, warningCount, truncated,
        notice: sessions.length + ' conversations found. Search and filters do not rescan disk. Duration is first-to-last recorded activity, not working time.' +
            (warningCount ? ' ' + warningCount + ' source warnings; see discovery details.' : '') +
            (sessions.some(row => row.promptCount === null && row.loadable) ? ' Some large recordings require Load to inspect metadata.' : '')
    };
}

module.exports = { discoverHistory, FILE_LIMIT, SCAN_LIMIT, ENTRY_LIMIT };
