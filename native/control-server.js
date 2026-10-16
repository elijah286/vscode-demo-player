const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const { RESPONSE_DURATION } = require('./replay');

function playbackView(state) {
    if (state.phase === 'ready') return { phase: 'ready', label: 'Ready', action: 'play', button: 'Play', enabled: true };
    if (state.phase === 'review') return { phase: 'review', label: 'Exchange complete', action: 'restart', button: 'Start Over', enabled: true };
    if (state.phase === 'typing' || state.phase === 'response') {
        return {
            phase: state.phase,
            label: state.clock?.paused ? 'Paused' : 'Playing',
            action: state.clock?.paused ? 'resume' : 'pause',
            button: state.clock?.paused ? 'Resume' : 'Pause',
            enabled: true
        };
    }
    if (state.phase === 'complete') return { phase: 'complete', label: 'Finished', action: 'restart', button: 'Start Over', enabled: true };
    if (state.phase === 'error') return { phase: 'error', label: 'Replay error', button: 'Unavailable', enabled: false };
    if (state.phase === 'stopping' || state.phase === 'stopped') return { phase: state.phase, label: 'Stopping', button: 'Unavailable', enabled: false };
    return { phase: state.phase, label: 'Preparing', button: 'Play', enabled: false };
}

function controlView(state) {
    const view = playbackView(state);
    const total = state.recordings?.length ?? 0;
    view.restartEnabled = total > 0 && ['review', 'complete'].includes(state.phase);
    view.nextEnabled = total > 0 && state.phase === 'review' && state.turnIndex < total;
    if (state.error) view.error = state.error;
    if (!total) return view;
    const current = ['ready', 'typing', 'response'].includes(state.phase)
        ? Math.min(state.turnIndex + 1, total)
        : Math.min(Math.max(state.turnIndex, 1), total);
    const recording = state.recordings[current - 1];
    const timestamp = value => typeof value === 'number' ? value : typeof value === 'string' ? Date.parse(value) : NaN;
    const ranges = state.recordings.map(item => ({ start: timestamp(item.request?.timestamp), end: timestamp(item.request?.modelState?.completedAt) }));
    const timed = ranges.every((range, index) => Number.isFinite(range.start) && Number.isFinite(range.end) && range.end >= range.start && (!index || range.start >= ranges[index - 1].end));
    const completedMs = ranges.slice(0, state.turnIndex).reduce((sum, range) => sum + range.end - range.start, 0);
    const range = ranges[state.turnIndex];
    const responseProgress = state.phase === 'response' && Number.isFinite(state.responseOrigin) && typeof state.clock?.now === 'function'
        ? Math.max(0, Math.min(1, (state.clock.now() - state.responseOrigin) / RESPONSE_DURATION))
        : 0;
    const elapsedMs = timed ? Math.round(completedMs + (range ? (range.end - range.start) * responseProgress : 0)) : undefined;
    const seconds = Math.floor(elapsedMs / 1000);
    return {
        ...view, current, total, progress: current + '/' + total,
        windowMode: state.windowMode,
        modeSwitchEnabled: ['ready', 'review', 'complete'].includes(state.phase),
        resumeTurn: state.turnIndex,
        selection: state.selection,
        overlay: {
            promptSummary: recording.promptSummary ?? null,
            elapsed: timed ? [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60].map(value => String(value).padStart(2, '0')).join(':') : null,
            elapsedMs: elapsedMs ?? null,
            timingMode: 'interpolated-response-time'
        }
    };
}

async function createControlServer({ controlPath, getState, play, next, restart, pause, resume, stop, onError }) {
    const token = crypto.randomBytes(32).toString('hex');
    const expected = Buffer.from('Bearer ' + token);
    let stopping = false;
    const server = http.createServer((request, response) => {
        const supplied = Buffer.from(request.headers.authorization ?? '');
        const send = (code, body) => {
            response.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
            response.end(JSON.stringify(body));
        };
        if (request.headers.origin || supplied.length !== expected.length || !crypto.timingSafeEqual(supplied, expected)) {
            send(401, { error: 'Unauthorized' });
            return;
        }
        if (request.method === 'GET' && request.url === '/state') {
            send(200, controlView(getState()));
            return;
        }
        if (request.method !== 'POST' || !['/play', '/next', '/restart', '/pause', '/resume', '/stop'].includes(request.url)) {
            send(404, { error: 'Unknown control' });
            return;
        }
        const view = controlView(getState());
        const action = request.url.slice(1);
        const callback = { play, next, restart, pause, resume, stop }[action];
        const available = action === 'next' ? view.nextEnabled : action === 'restart' ? view.restartEnabled : view.enabled && view.action === action;
        if (typeof callback !== 'function' || (action !== 'stop' && (stopping || !available))) {
            send(409, { error: 'Control is not available in the current playback state' });
            return;
        }
        if (action === 'stop') {
            if (stopping) { send(202, { accepted: true }); return; }
            stopping = true;
        }
        response.once('finish', () => {
            Promise.resolve().then(callback).catch(onError);
        });
        send(202, { accepted: true });
    });
    server.requestTimeout = 2000;
    server.headersTimeout = 2000;
    server.timeout = 2000;
    await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(0, '127.0.0.1', resolve);
    });
    const port = server.address().port;
    try {
        await fs.writeFile(controlPath, JSON.stringify({ version: 1, port, token }), { mode: 0o600, flag: 'wx' });
    } catch (error) {
        server.close();
        throw error;
    }
    return {
        port,
        token,
        async close() {
            server.closeAllConnections();
            await new Promise(resolve => server.close(resolve));
            await fs.unlink(controlPath).catch(error => { if (error.code !== 'ENOENT') throw error; });
        }
    };
}

module.exports = { controlView, createControlServer };