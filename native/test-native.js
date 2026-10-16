const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');
const net = require('node:net');
const { runTests } = require('@vscode/test-electron');

async function main() {
    const source = process.env.HISTORY_REPLAY_TEST_SOURCE;
    const requestIndex = Number(process.env.HISTORY_REPLAY_TEST_REQUEST ?? '0');
    if (!source || !fs.statSync(source).isFile()) throw new Error('Set HISTORY_REPLAY_TEST_SOURCE to a local transcript containing two complete supported turns.');
    if (!Number.isInteger(requestIndex) || requestIndex < 0) throw new Error('HISTORY_REPLAY_TEST_REQUEST must be a nonnegative integer.');
    const profile = process.env.HISTORY_REPLAY_TEST_PROFILE ?? fs.mkdtempSync(path.join(os.tmpdir(), 'native-replay-test-'));
    const port = await new Promise((resolve, reject) => {
        const server = net.createServer();
        server.once('error', reject);
        server.listen(0, '127.0.0.1', () => {
            const port = server.address().port;
            server.close(() => resolve(port));
        });
    });
    console.log('NATIVE TEST PROFILE', profile);
    await runTests({
        vscodeExecutablePath: path.join(process.env.LOCALAPPDATA, 'Programs', 'Microsoft VS Code', 'Code.exe'),
        extensionDevelopmentPath: __dirname,
        extensionTestsPath: path.join(__dirname, 'test', 'native-runner.js'),
        extensionTestsEnv: {
            HISTORY_REPLAY_CDP_PORT: String(port),
            HISTORY_REPLAY_TEST_SOURCE: path.resolve(source),
            HISTORY_REPLAY_TEST_REQUEST: String(requestIndex),
            ...(process.env.HISTORY_REPLAY_BACKEND_PROBE === '1' ? { HISTORY_REPLAY_BACKEND_PROBE: '1' } : {})
        },
        launchArgs: [
            '--new-window',
            ...(process.env.HISTORY_REPLAY_AGENTS === '1' ? ['--agents'] : []),
            '--remote-debugging-port=' + port,
            '--user-data-dir', profile,
            '--extensions-dir', path.join(profile, 'extensions'),
            '--enable-proposed-api=local.historical-transcript-replay',
            ...(process.env.HISTORY_REPLAY_AGENTS === '1' ? [] : [
                '--disable-extensions',
                '--disable-extension=github.copilot-chat',
                '--disable-extension=github.copilot'
            ]),
            '--disable-workspace-trust',
            '--skip-welcome',
            '--skip-release-notes',
            '--disable-telemetry'
        ]
    });
}

main().catch(error => {
    console.error(error);
    process.exitCode = 1;
});