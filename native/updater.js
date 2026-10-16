const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');

const REPOSITORY = 'https://github.com/elijah286/vscode-demo-player';
const RELEASE_API = 'https://api.github.com/repos/elijah286/vscode-demo-player/releases/latest';
const INSTALLER = 'VSCodeDemoPlayer-Setup.exe';
const MAX_INSTALLER_BYTES = 128 * 1024 * 1024;
const ALLOWED_HOSTS = new Set(['api.github.com', 'github.com', 'release-assets.githubusercontent.com', 'objects.githubusercontent.com']);

function versionParts(value) {
    if (typeof value !== 'string' || !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(value)) throw new Error('Expected a stable three-part application version.');
    const parts = value.split('.').map(Number);
    if (!parts.every(Number.isSafeInteger)) throw new Error('Application version exceeds the supported range.');
    return parts;
}

function compareVersions(left, right) {
    const a = versionParts(left);
    const b = versionParts(right);
    for (let index = 0; index < 3; index++) {
        if (a[index] !== b[index]) return a[index] > b[index] ? 1 : -1;
    }
    return 0;
}

function trustedURL(value) {
    const url = new URL(value);
    if (url.protocol !== 'https:' || url.username || url.password || url.port || !ALLOWED_HOSTS.has(url.hostname)) throw new Error('Refusing an untrusted update URL.');
    return url;
}

async function request(url, { fetchImpl = fetch, timeoutMs = 15000 } = {}) {
    const signal = AbortSignal.timeout(timeoutMs);
    for (let redirects = 0; redirects <= 5; redirects++) {
        const response = await fetchImpl(trustedURL(url), {
            redirect: 'manual', signal,
            headers: { 'User-Agent': 'VSCodeDemoPlayer-Updater', Accept: 'application/vnd.github+json' }
        });
        if ([301, 302, 303, 307, 308].includes(response.status)) {
            const location = response.headers.get('location');
            if (response.body) await response.body.cancel();
            if (!location) throw new Error('GitHub returned an update redirect without a destination.');
            url = new URL(location, url).href;
            continue;
        }
        if (!response.ok) {
            if (response.body) await response.body.cancel();
            if ([403, 429].includes(response.status)) throw new Error('GitHub denied or rate-limited the update request. Try again later.');
            throw new Error('GitHub update request failed (HTTP ' + response.status + ').');
        }
        return response;
    }
    throw new Error('Too many redirects while downloading an update.');
}

async function readLimited(response, maximum) {
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
        size += chunk.length;
        if (size > maximum) throw new Error('Update metadata exceeds the size limit.');
        chunks.push(chunk);
    }
    return Buffer.concat(chunks, size).toString('utf8');
}

function validateRelease(release) {
    if (!release || release.draft !== false || release.prerelease !== false || typeof release.tag_name !== 'string' || !release.tag_name.startsWith('v')) throw new Error('GitHub did not return a stable published release.');
    const version = release.tag_name.slice(1);
    versionParts(version);
    if (release.html_url !== REPOSITORY + '/releases/tag/' + release.tag_name || !Array.isArray(release.assets)) throw new Error('The update release does not belong to this application.');
    const asset = (name, maximum) => {
        const matches = release.assets.filter(item => item.name === name);
        const item = matches[0];
        if (matches.length !== 1 || item.state !== 'uploaded' || !Number.isSafeInteger(item.size) || item.size < 1 || item.size > maximum ||
            item.browser_download_url !== REPOSITORY + '/releases/download/' + release.tag_name + '/' + name) throw new Error('Missing, invalid, or oversized release asset: ' + name);
        return item;
    };
    const installer = asset(INSTALLER, MAX_INSTALLER_BYTES);
    const checksums = asset('SHA256SUMS.txt', 65536);
    if (typeof installer.digest !== 'string' || !/^sha256:[a-f0-9]{64}$/.test(installer.digest)) throw new Error('The installer has no valid GitHub SHA-256 digest.');
    return { version, installer, checksums, releaseURL: release.html_url };
}

async function latestRelease(options) {
    const response = await request(RELEASE_API, options);
    return validateRelease(JSON.parse(await readLimited(response, 1024 * 1024)));
}

async function checkForUpdates(currentVersion, options) {
    versionParts(currentVersion);
    const release = await latestRelease(options);
    const comparison = compareVersions(release.version, currentVersion);
    return {
        currentVersion, latestVersion: release.version, updateAvailable: comparison > 0,
        installedIsNewer: comparison < 0, releaseURL: release.releaseURL
    };
}

async function downloadUpdate(currentVersion, expectedVersion, directory, options) {
    versionParts(currentVersion);
    versionParts(expectedVersion);
    const release = await latestRelease(options);
    if (release.version !== expectedVersion) throw new Error('The latest release changed. Check for updates again before installing.');
    if (compareVersions(release.version, currentVersion) <= 0) throw new Error('Refusing to install the same or an older application version.');
    const sums = await readLimited(await request(release.checksums.browser_download_url, options), 65536);
    const match = /^([a-f0-9]{64}) {2}VSCodeDemoPlayer-Setup\.exe\s*$/i.exec(sums);
    if (!match || match[1].toLowerCase() !== release.installer.digest.slice(7)) throw new Error('The published checksum and GitHub installer digest do not match.');
    await fs.mkdir(directory);
    const installerPath = path.join(directory, INSTALLER);
    try {
        const response = await request(release.installer.browser_download_url, { ...options, timeoutMs: options?.timeoutMs ?? 120000 });
        const file = await fs.open(installerPath, 'wx');
        const hash = crypto.createHash('sha256');
        let size = 0;
        try {
            for await (const chunk of response.body) {
                size += chunk.length;
                if (size > release.installer.size) throw new Error('The downloaded installer exceeds its published size.');
                hash.update(chunk);
                await file.writeFile(chunk);
            }
        } finally { await file.close(); }
        const digest = hash.digest('hex');
        if (size !== release.installer.size || digest !== match[1].toLowerCase()) throw new Error('Installer integrity verification failed. The update will not be installed.');
        return { version: release.version, installerPath, directory, sha256: digest };
    } catch (error) {
        try { await fs.rm(directory, { recursive: true, force: true }); }
        catch (cleanup) { throw new AggregateError([error, cleanup], 'The download failed and its temporary files could not be removed.'); }
        throw error;
    }
}

async function main() {
    let input = '';
    for await (const chunk of process.stdin) {
        input += chunk;
        if (input.length > 65536) throw new Error('Update command exceeds 64 KiB.');
    }
    const command = JSON.parse(input);
    if (command.command === 'check') return checkForUpdates(command.currentVersion);
    if (command.command !== 'download') throw new Error('Unknown update command.');
    if (!process.env.LOCALAPPDATA) throw new Error('LOCALAPPDATA is required for update downloads.');
    const root = path.join(process.env.LOCALAPPDATA, 'VSCodeDemoPlayer', 'updates');
    const directory = path.resolve(command.directory);
    if (path.dirname(directory).toLowerCase() !== root.toLowerCase() || !/^pending-[a-f0-9]{32}$/.test(path.basename(directory))) throw new Error('The update download directory is not an owned pending-update directory.');
    await fs.mkdir(root, { recursive: true });
    return downloadUpdate(command.currentVersion, command.version, directory);
}

if (require.main === module) main().then(
    result => process.stdout.write(JSON.stringify({ ok: true, result })),
    error => {
        process.stdout.write(JSON.stringify({ ok: false, error: error.message }));
        process.exitCode = 1;
    }
);

module.exports = { compareVersions, validateRelease, checkForUpdates, downloadUpdate, trustedURL, request, MAX_INSTALLER_BYTES };
