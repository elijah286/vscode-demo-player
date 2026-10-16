const fs = require('node:fs');
const readline = require('node:readline');
const crypto = require('node:crypto');
const path = require('node:path');
const { INTERNAL_PARTS, completedQuestions, inlineReferenceLabel, validateSavedEditGroup } = require('./saved-parts');

function kindOf(part) {
    if (typeof part === 'string') return 'markdown';
    if (!part || typeof part !== 'object') return '(invalid saved response part)';
    if (!part.kind && typeof part.value === 'string') return 'markdown';
    return typeof part.kind === 'string' && part.kind ? part.kind : '(missing saved response kind)';
}

const PROMPT_DURATION = 2000;
const RESPONSE_DURATION = 5000;

function recordedModel(request, snapshot) {
    const id = request.modelId;
    if (typeof id !== 'string' || !id.trim()) return undefined;
    const selected = snapshot.inputState?.selectedModel;
    const name = selected?.identifier === id && typeof selected.metadata?.name === 'string' && selected.metadata.name.trim()
        ? selected.metadata.name
        : id;
    return { id, name };
}

function applyTranscriptRecord(snapshot, record) {
    if (record.kind === 0) return record.v;
    if (!snapshot || !Array.isArray(record.k) || record.k.some(key => ['__proto__', 'prototype', 'constructor'].includes(key))) throw new Error('Invalid native transcript update path.');
    let target = snapshot;
    const path = record.kind === 2 ? record.k : record.k.slice(0, -1);
    for (const key of path) {
        if (target === null || typeof target !== 'object' || !Object.hasOwn(target, key)) throw new Error('Native transcript update targets a missing object.');
        target = target[key];
    }
    if (record.kind === 2) {
        if (!Array.isArray(target) || (record.v !== undefined && !Array.isArray(record.v))) throw new Error('Invalid native transcript array update.');
        if (record.i !== undefined) {
            if (!Number.isInteger(record.i) || record.i < 0 || record.i > target.length) throw new Error('Invalid native transcript array index.');
            target.length = record.i;
        }
        if (record.v) target.push(...record.v);
    } else if (record.kind === 1 || record.kind === 3) {
        if (!record.k.length || target === null || typeof target !== 'object') throw new Error('Invalid native transcript field update.');
        target[record.k.at(-1)] = record.kind === 3 ? undefined : record.v;
    } else throw new Error('Unsupported native transcript update kind: ' + record.kind);
    return snapshot;
}

async function readSnapshot(file) {
    const stream = fs.createReadStream(file, { encoding: 'utf8' });
    const lines = readline.createInterface({ input: stream, crlfDelay: Infinity });
    let snapshot;
    try {
        for await (const line of lines) {
            if (line.trim()) snapshot = applyTranscriptRecord(snapshot, JSON.parse(line));
        }
    } finally {
        lines.close();
        stream.destroy();
    }
    if (!Array.isArray(snapshot?.requests)) throw new Error('Expected a native JSONL snapshot.');
    return snapshot;
}

async function readRecordings(file, requestIndex, requestCount = 1) {
    if (!Number.isInteger(requestIndex) || requestIndex < 0) throw new Error('Request index must be a nonnegative integer.');
    if (!Number.isInteger(requestCount) || requestCount < 1 || requestCount > 100) throw new Error('Request count must be between 1 and 100.');
    const snapshot = await readSnapshot(file);
    return Array.from({ length: requestCount }, (_, offset) => extractRecording(file, snapshot, requestIndex + offset));
}

function validateEditorRecording(recording) {
    const supported = new Set(['markdown', 'thinking', 'toolInvocationSerialized', 'inlineReference', 'textEditGroup', ...INTERNAL_PARTS]);
    const unsupported = [...new Set(recording.request.response.map(kindOf).filter(kind => !supported.has(kind)))];
    if (unsupported.length) throw new Error('Editor playback cannot render these saved parts: ' + unsupported.join(', ') + '. No content was discarded.');
    if (!recording.request.message.text.trim()) throw new Error('Editor playback requires a nonempty recorded prompt.');
    for (const part of recording.request.response) {
        const kind = kindOf(part);
        if (kind === 'inlineReference') inlineReferenceLabel(part);
        if (kind === 'textEditGroup') validateSavedEditGroup(part);
        if (kind === 'markdown' && typeof (typeof part === 'string' ? part : part.value) !== 'string') throw new Error('Invalid recorded Markdown.');
        if (kind === 'toolInvocationSerialized' && (!part.isComplete || typeof part.toolId !== 'string' || typeof part.toolCallId !== 'string')) {
            throw new Error('Recorded tool activity is incomplete or missing tool identifiers.');
        }
    }
    return recording;
}

async function readPlaylist(file) {
    const manifest = JSON.parse(await fs.promises.readFile(file, 'utf8'));
    if (manifest.version !== 1 || !/^[a-f0-9]{32}$/.test(manifest.workspaceStorageId) || !Array.isArray(manifest.segments) || !manifest.segments.length || manifest.segments.length > 100) {
        throw new Error('Invalid replay playlist manifest.');
    }
    const root = path.join(process.env.APPDATA, 'Code', 'User', 'workspaceStorage', manifest.workspaceStorageId, 'chatSessions');
    const recordings = [];
    for (const segment of manifest.segments) {
        if (!/^[a-f0-9-]{36}$/.test(segment.sessionId)) throw new Error('Invalid playlist source session ID.');
        const source = path.join(root, segment.sessionId + '.jsonl');
        const selected = await readRecordings(source, segment.requestIndex, segment.requestCount);
        recordings.push(...selected);
    }
    if (manifest.expectedTurns !== undefined && recordings.length !== manifest.expectedTurns) throw new Error('Playlist turn count does not match its expected source range.');
    return recordings;
}

function extractRecording(file, snapshot, requestIndex) {
    const request = snapshot.requests[requestIndex];
    if (!request?.result || typeof request.message?.text !== 'string' || !Array.isArray(request.response)) {
        throw new Error('The selected request is absent or incomplete in the saved transcript.');
    }
    const supported = new Set(['markdown', 'thinking', 'toolInvocationSerialized', 'questionCarousel', 'textEditGroup', 'inlineReference', 'confirmation', 'progressTaskSerialized', 'workspaceEdit', ...INTERNAL_PARTS]);
    const unsupported = [...new Set(request.response.map(kindOf).filter(kind => !supported.has(kind)))];
    if (unsupported.length) throw new Error('Native streaming is not implemented for: ' + unsupported.join(', '));
    for (const part of request.response) {
        if (kindOf(part) === 'questionCarousel') completedQuestions(part);
        if (kindOf(part) === 'textEditGroup') validateSavedEditGroup(part);
    }
    const fingerprint = crypto.createHash('sha256').update(JSON.stringify(request)).digest('hex');
    return {
        file,
        requestIndex,
        sessionId: snapshot.sessionId,
        title: snapshot.customTitle,
        responderName: request.agent?.fullName || snapshot.responderUsername,
        request,
        model: recordedModel(request, snapshot),
        fingerprint,
        snapshotScope: 'complete native JSONL transcript',
        metadataParts: request.response.filter(part => INTERNAL_PARTS.has(kindOf(part))).length,
        internalParts: request.response.filter(part => INTERNAL_PARTS.has(kindOf(part))),
        requiresSavedPartsRenderer: request.response.some(part => kindOf(part) === 'questionCarousel')
    };
}

async function readRecording(file, requestIndex) {
    return (await readRecordings(file, requestIndex))[0];
}

function* promptTimeline(prompt) {
    const characters = Array.from(prompt);
    let text = '';
    for (const [index, character] of characters.entries()) {
        text += character;
        yield { text, at: characters.length > 1 ? index * PROMPT_DURATION / (characters.length - 1) : 0 };
    }
}

function responseTimeline(response) {
    const events = [];
    for (const part of response) {
        const kind = kindOf(part);
        if (INTERNAL_PARTS.has(kind)) continue;
        if (kind === 'markdown') {
            const characters = Array.from(typeof part === 'string' ? part : part.value);
            if (!characters.length) events.push({ kind, part, value: '' });
            for (let offset = 0; offset < characters.length; offset += 24) {
                events.push({ kind, part, value: characters.slice(offset, offset + 24).join('') });
            }
        } else if (kind === 'toolInvocationSerialized') {
            events.push({ kind: 'toolPending', part }, { kind: 'toolComplete', part });
        } else {
            events.push({ kind, part });
        }
    }
    return events.map((event, index) => ({ ...event, at: index * RESPONSE_DURATION / Math.max(1, events.length - 1) }));
}

class PlaybackClock {
    constructor(speed = 4) {
        this.speed = 1;
        this.paused = false;
        this.stopped = false;
        this.steps = 0;
        this.listeners = new Set();
        this.elapsed = 0;
        this.markedAt = performance.now();
        this.setSpeed(speed);
    }

    wake() {
        for (const listener of [...this.listeners]) listener();
    }

    now() {
        const time = performance.now();
        if (!this.paused && !this.stopped) this.elapsed += (time - this.markedAt) * this.speed;
        this.markedAt = time;
        return this.elapsed;
    }

    setPaused(paused) {
        this.now();
        this.paused = paused;
        this.wake();
    }

    setSpeed(speed) {
        if (!Number.isFinite(speed) || speed < 0.25 || speed > 32) throw new Error('Speed must be between 0.25 and 32.');
        this.now();
        this.speed = speed;
        this.wake();
    }

    step() {
        this.steps++;
        this.wake();
    }

    stop() {
        this.now();
        this.stopped = true;
        this.wake();
    }

    async waitUntil(deadline) {
        if (this.stopped) throw new Error('Replay stopped.');
        await this.wait(Math.max(0, deadline - this.now()));
    }

    async wait(milliseconds) {
        let remaining = milliseconds;
        while (remaining > 0 || this.paused) {
            if (this.stopped) throw new Error('Replay stopped.');
            if (this.steps > 0) { this.steps--; return; }
            const duration = this.paused ? 100 : Math.min(50, remaining / this.speed);
            const start = Date.now();
            await new Promise(resolve => {
                let timer;
                const finish = () => {
                    clearTimeout(timer);
                    this.listeners.delete(finish);
                    resolve();
                };
                this.listeners.add(finish);
                timer = setTimeout(finish, duration);
            });
            if (!this.paused) remaining -= (Date.now() - start) * this.speed;
        }
        if (this.stopped) throw new Error('Replay stopped.');
    }
}

module.exports = { readRecording, readRecordings, readPlaylist, readSnapshot, applyTranscriptRecord, extractRecording, validateEditorRecording, recordedModel, kindOf, PlaybackClock, promptTimeline, responseTimeline, PROMPT_DURATION, RESPONSE_DURATION };