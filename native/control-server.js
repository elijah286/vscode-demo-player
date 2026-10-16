const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');

function playbackView(state) {
    if (state.phase === 'ready') return { phase: 'ready', label: 'Ready', action: 'play', button: 'Play', enabled: true };
    if (state.phase === 'review') return { phase: 'review', label: 'Paused', action: 'play', button: 'Play', enabled: true };
    if (state.phase === 'typing' || state.phase === 'response') {
        return {
            phase: state.phase,
            label: state.clock?.paused ? 'Paused' : 'Playing',
            action: state.clock?.paused ? 'resume' : 'pause',
            button: state.clock?.paused ? 'Resume' : 'Pause',
            enabled: true
        };
    }
    if (state.phase === 'complete') return { phase: 'complete', label: 'Finished', button: 'Finished', enabled: false };
    if (state.phase === 'error') return { phase: 'error', label: 'Replay error', button: 'Unavailable', enabled: false };
    if (state.phase === 'stopping' || state.phase === 'stopped') return { phase: state.phase, label: 'Stopping', button: 'Unavailable', enabled: false };
    return { phase: state.phase, label: 'Preparing', button: 'Play', enabled: false };
}

function controlView(state) {
    const view = playbackView(state);
    const total = state.recordings?.length ?? 0;
    if (!total) return view;
    const current = ['ready', 'typing', 'response'].includes(state.phase)
        ? Math.min(state.turnIndex + 1, total)
        : Math.min(Math.max(state.turnIndex, 1), total);
    return { ...view, current, total, progress: current + '/' + total };
}

async function createControlServer({ controlPath, getState, play, pause, resume, stop, onError }) {
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
        if (request.method !== 'POST' || !['/play', '/pause', '/resume', '/stop'].includes(request.url)) {
            send(404, { error: 'Unknown control' });
            return;
        }
        const view = controlView(getState());
        const action = request.url.slice(1);
        if (action !== 'stop' && (stopping || !view.enabled || view.action !== action)) {
            send(409, { error: 'Control is not available in the current playback state' });
            return;
        }
        if (action === 'stop') {
            if (stopping) { send(202, { accepted: true }); return; }
            stopping = true;
        }
        const callback = { play, pause, resume, stop }[action];
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