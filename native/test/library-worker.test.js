const test = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const readline = require('node:readline');

test('persistent library protocol reuses one process, preserves errors and rejects foreign roots', async context => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'vibereplay-worker-'));
    const child = spawn(process.execPath, [path.join(__dirname, '..', 'library-worker.js')], {
        env: { ...process.env, VIBEREPLAY_LIBRARY_ROOT: root }, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe']
    });
    const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    let stderr = '';
    child.stderr.on('data', chunk => { stderr += chunk; });
    context.after(async () => {
        if (child.exitCode === null) {
            child.stdin.end();
            await new Promise(resolve => child.once('exit', resolve));
        }
        await fs.rm(root, { recursive: true, force: true });
    });
    const pid = child.pid;
    async function send(packet, preamble = '') {
        child.stdin.write(preamble + JSON.stringify(packet) + '\n');
        const response = await lines.next();
        assert.equal(response.done, false, stderr);
        return JSON.parse(response.value);
    }
    for (const id of [1, 2, 3]) {
        assert.deepEqual(await send({ id, request: { root, command: 'list' } }, id === 1 ? '\uFEFF' : ''), { version: 1, id, ok: true, result: [] });
        assert.equal(child.pid, pid);
        assert.equal(child.exitCode, null);
    }
    const badCommand = await send({ id: 4, request: { root, command: 'unknown' } });
    assert.equal(badCommand.ok, false);
    assert.match(badCommand.error, /Unknown demo library command/);
    const foreign = await send({ id: 5, request: { root: root + '-other', command: 'list' } });
    assert.equal(foreign.ok, false);
    assert.match(foreign.error, /does not belong/);
    const malformed = await send({ id: 0, request: {} });
    assert.equal(malformed.ok, false);
    assert.equal(malformed.id, null);
    assert.match(malformed.error, /Invalid library request/);
    const recovery = await send({ id: 6, request: { root, command: 'list' } });
    assert.equal(recovery.ok, true);
});
