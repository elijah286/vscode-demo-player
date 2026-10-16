const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { compareVersions, validateRelease, checkForUpdates, downloadUpdate, trustedURL, request, MAX_INSTALLER_BYTES } = require('../updater');

const repo = 'https://github.com/elijah286/vscode-demo-player';
const bytes = Buffer.from('synthetic installer bytes - never executable');
const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');
const digest = sha256(bytes);
const sums = digest + '  VSCodeDemoPlayer-Setup.exe\n';
function release(version = '0.2.0') {
    return {
        tag_name: 'v' + version, draft: false, prerelease: false, html_url: repo + '/releases/tag/v' + version,
        assets: [
            { name: 'VSCodeDemoPlayer-Setup.exe', state: 'uploaded', size: bytes.length, digest: 'sha256:' + digest, browser_download_url: repo + '/releases/download/v' + version + '/VSCodeDemoPlayer-Setup.exe' },
            { name: 'SHA256SUMS.txt', state: 'uploaded', size: Buffer.byteLength(sums), browser_download_url: repo + '/releases/download/v' + version + '/SHA256SUMS.txt' }
        ]
    };
}
function server({ metadata = release(), installer = bytes, checksum = sums } = {}) {
    return {
        fetchImpl: async (url, options) => {
            assert.equal(options.redirect, 'manual');
            assert.ok(options.signal);
            const body = url.hostname === 'api.github.com' ? JSON.stringify(metadata) : url.pathname.endsWith('.txt') ? checksum : installer;
            return new Response(body);
        }
    };
}
async function destination(context) {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'player-update-test-'));
    context.after(() => fs.rm(root, { recursive: true, force: true }));
    return path.join(root, 'pending');
}

test('versions are compared numerically, never lexicographically', () => {
    assert.equal(compareVersions('0.10.0', '0.9.9'), 1);
    assert.equal(compareVersions('2.0.0', '1.999.999'), 1);
    assert.equal(compareVersions('0.2.0', '0.2.0'), 0);
    assert.equal(compareVersions('0.1.9', '0.2.0'), -1);
    for (const value of ['', 'v0.2.0', '0.2', '0.2.0-beta', '00.2.0', '-1.0.0', '9007199254740992.0.0', null]) {
        assert.throws(() => compareVersions(value, '0.2.0'), /version|range/);
    }
});

test('only stable, complete releases from this repository are accepted', () => {
    assert.equal(validateRelease(release()).version, '0.2.0');
    for (const change of [
        item => { item.draft = true; },
        item => { item.prerelease = true; },
        item => { item.tag_name = 'v0.2.0-beta'; },
        item => { item.html_url = 'https://github.com/other/repo/releases/tag/v0.2.0'; },
        item => { item.assets.pop(); },
        item => { item.assets.push(item.assets[0]); },
        item => { item.assets[0].state = 'new'; },
        item => { item.assets[0].size = 0; },
        item => { item.assets[0].digest = null; },
        item => { item.assets[0].browser_download_url = 'https://example.org/installer.exe'; }
    ]) {
        const item = release();
        change(item);
        assert.throws(() => validateRelease(item));
    }
    const item = release();
    item.assets[0].size = MAX_INSTALLER_BYTES;
    assert.doesNotThrow(() => validateRelease(item));
    item.assets[0].size++;
    assert.throws(() => validateRelease(item), /oversized/);
});

test('update checks show current/latest versions and never offer downgrades', async () => {
    assert.deepEqual(await checkForUpdates('0.1.0', server()), {
        currentVersion: '0.1.0', latestVersion: '0.2.0', updateAvailable: true, installedIsNewer: false,
        releaseURL: repo + '/releases/tag/v0.2.0'
    });
    assert.equal((await checkForUpdates('0.2.0', server())).updateAvailable, false);
    const newer = await checkForUpdates('0.3.0', server());
    assert.equal(newer.updateAvailable, false);
    assert.equal(newer.installedIsNewer, true);
});

test('network, rate-limit, malformed and oversized metadata failures are explicit', async () => {
    await assert.rejects(checkForUpdates('0.1.0', { fetchImpl: async () => { throw new Error('Offline'); } }), /Offline/);
    await assert.rejects(checkForUpdates('0.1.0', { fetchImpl: async () => { throw new Error('Request timeout'); } }), /timeout/);
    for (const status of [403, 429, 404, 500]) {
        await assert.rejects(checkForUpdates('0.1.0', { fetchImpl: async () => new Response('failure', { status }) }), /denied|HTTP/);
    }
    await assert.rejects(checkForUpdates('0.1.0', { fetchImpl: async () => new Response('not JSON') }), SyntaxError);
    await assert.rejects(checkForUpdates('0.1.0', { fetchImpl: async () => new Response('x'.repeat(1024 * 1024 + 1)) }), /size limit/);
});

test('update URLs and redirects reject insecure or unrelated destinations', async () => {
    for (const url of ['http://github.com/a', 'https://github.com.evil.test/a', 'https://user:password@github.com/a', 'https://github.com:444/a', 'https://example.org/a']) {
        assert.throws(() => trustedURL(url), /untrusted/);
    }
    assert.equal(trustedURL('https://release-assets.githubusercontent.com/example').protocol, 'https:');
    await assert.rejects(request(repo, { fetchImpl: async () => new Response('', { status: 302, headers: { location: 'https://example.org/a' } }) }), /untrusted/);
    await assert.rejects(request(repo, { fetchImpl: async () => new Response('', { status: 302, headers: { location: repo } }) }), /Too many redirects/);
});

test('a verified update is downloaded without executing any installer', async context => {
    const directory = await destination(context);
    const result = await downloadUpdate('0.1.0', '0.2.0', directory, server());
    assert.equal(result.sha256, digest);
    assert.equal(result.version, '0.2.0');
    assert.deepEqual(await fs.readFile(result.installerPath), bytes);
    assert.deepEqual(await fs.readdir(directory), ['VSCodeDemoPlayer-Setup.exe']);
});

test('release changes, same versions and downgrades are refused before download', async context => {
    const directory = await destination(context);
    await assert.rejects(downloadUpdate('0.1.0', '0.1.9', directory, server()), /release changed/);
    await assert.rejects(downloadUpdate('0.2.0', '0.2.0', directory, server()), /same or an older/);
    await assert.rejects(downloadUpdate('0.3.0', '0.2.0', directory, server()), /same or an older/);
    await assert.rejects(fs.stat(directory), { code: 'ENOENT' });
});

test('mismatched published checksums and duplicate checksum lines cannot install', async context => {
    const directory = await destination(context);
    for (const checksum of ['0'.repeat(64) + '  VSCodeDemoPlayer-Setup.exe\n', sums + sums, 'not a checksum']) {
        await assert.rejects(downloadUpdate('0.1.0', '0.2.0', directory, server({ checksum })), /do not match/);
    }
    await assert.rejects(fs.stat(directory), { code: 'ENOENT' });
});

test('corrupt, truncated and oversized downloads fail and remove temporary files', async context => {
    const directory = await destination(context);
    for (const installer of [Buffer.alloc(bytes.length, 1), bytes.subarray(1), Buffer.concat([bytes, Buffer.from('x')])]) {
        await assert.rejects(downloadUpdate('0.1.0', '0.2.0', directory, server({ installer })), /integrity|published size/);
        await assert.rejects(fs.stat(directory), { code: 'ENOENT' });
    }
});

test('download failure preserves existing files and never reuses a directory', async context => {
    const directory = await destination(context);
    await fs.mkdir(directory);
    await fs.writeFile(path.join(directory, 'keep.txt'), 'existing');
    await assert.rejects(downloadUpdate('0.1.0', '0.2.0', directory, server()), { code: 'EEXIST' });
    assert.equal(await fs.readFile(path.join(directory, 'keep.txt'), 'utf8'), 'existing');
});

test('interrupted installer streams report failure and remove partial downloads', async context => {
    const directory = await destination(context);
    const ordinary = server();
    const options = {
        fetchImpl: async (url, init) => {
            if (!url.pathname.endsWith('.exe')) return ordinary.fetchImpl(url, init);
            let read = false;
            return new Response(new ReadableStream({
                pull(controller) {
                    if (!read) { controller.enqueue(bytes.subarray(0, 5)); read = true; }
                    else controller.error(new Error('Download connection lost'));
                }
            }));
        }
    };
    await assert.rejects(downloadUpdate('0.1.0', '0.2.0', directory, options), /connection lost/);
    await assert.rejects(fs.stat(directory), { code: 'ENOENT' });
});

test('CLI rejects invalid commands and download directories with nonzero exit codes', () => {
    for (const input of [{ command: 'unknown' }, { command: 'download', directory: os.tmpdir() }]) {
        const child = spawnSync(process.execPath, [path.join(__dirname, '..', 'updater.js')], { input: JSON.stringify(input), encoding: 'utf8', timeout: 5000 });
        assert.equal(child.status, 1);
        assert.equal(JSON.parse(child.stdout).ok, false);
    }
});
