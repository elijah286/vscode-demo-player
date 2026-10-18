const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');
const net = require('node:net');
const { runTests } = require('@vscode/test-electron');

async function main() {
    const summaryTest = process.argv.includes('--summaries');
    const artifacts = process.argv.includes('--artifacts');
    const profile = process.env.HISTORY_REPLAY_TEST_PROFILE ?? fs.mkdtempSync(path.join(os.tmpdir(), 'native-replay-test-'));
    let source = artifacts ? path.join(profile, 'synthetic-artifacts.jsonl') : process.env.HISTORY_REPLAY_TEST_SOURCE;
    let summaryEntry = process.env.HISTORY_REPLAY_TEST_SUMMARY_ENTRY;
    if (summaryTest && !summaryEntry) {
        fs.mkdirSync(profile, { recursive: true });
        source = path.join(profile, 'synthetic-summary-source.jsonl');
        fs.writeFileSync(source, JSON.stringify({ kind: 0, v: { requests: [
            { result: {}, message: { text: 'First synthetic long prompt. '.repeat(12) }, response: [{ value: 'Original synthetic answer.' }] },
            { result: {}, message: { text: 'Second synthetic long prompt. '.repeat(12) }, response: [{ value: 'Second original answer.' }] },
            { result: {}, message: { text: 'Third synthetic long prompt. '.repeat(12) }, response: [{ value: 'Third original answer.' }] },
            { result: {}, message: { text: 'Fourth synthetic long prompt. </script><script>throw new Error("Recorded data must not run")</script> '.repeat(5) }, response: [{ value: 'Fourth original answer.' }] },
            { result: {}, message: { text: 'Short prompt' }, response: [{ value: 'Short answer.' }] }
        ] } }) + '\n');
        const library = require('./demo-library');
        const inspection = await library.inspectTranscript(source);
        const root = path.join(profile, 'synthetic-library');
        const added = await library.addPackage(root, await library.createPackage(source, [0, 1, 2, 3, 4], 'Synthetic batch summaries', inspection.sha256));
        summaryEntry = path.join(root, added.id + '.demo.json');
    }
    if (artifacts) {
        fs.mkdirSync(profile, { recursive: true });
        const payload = Array.from({ length: 2000 }, (_, index) => '<Item Name="Synthetic saved payload ' + index + '"/>').join('\n') +
            '\n```text\n[run](command:never.run)\n```';
        const response = [
            { value: 'I will update the synthetic project.\n\n```xml\n<Item Name="Intentional assistant example"/>\n```\n' },
            { kind: 'textEditGroup', done: true, uri: { fsPath: 'C:\\Synthetic\\NeverCreated\\project.xml' }, edits: [[{ text: payload, range: { startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1 } }]] },
            { kind: 'recordedSdkEvent', events: [{ type: 'tool.execution_complete', data: { toolCallId: 'synthetic', success: true, result: { content: payload } } }] },
            ...['confirmation', 'progressTaskSerialized', 'workspaceEdit'].map(kind => ({ kind, payload })),
            { value: '\nThe recorded project update is ready for review.' }
        ];
        fs.writeFileSync(source, JSON.stringify({ kind: 0, v: { sessionId: 'synthetic-artifacts', requests: [
            { result: {}, message: { text: 'Show the saved project update.' }, response },
            { result: {}, message: { text: 'Summarize the result.' }, response: [{ value: 'The original assistant reply is unchanged. Saved activity remains available on demand.' }] }
        ] } }) + '\n');
    }
    const requestIndex = Number(process.env.HISTORY_REPLAY_TEST_REQUEST ?? '0');
    if (!source || !fs.statSync(source).isFile()) throw new Error('Set HISTORY_REPLAY_TEST_SOURCE to a local transcript containing two complete supported turns.');
    if (!Number.isInteger(requestIndex) || requestIndex < 0) throw new Error('HISTORY_REPLAY_TEST_REQUEST must be a nonnegative integer.');
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
        extensionDevelopmentPath: process.env.HISTORY_REPLAY_TEST_EXTENSION
            ? path.resolve(process.env.HISTORY_REPLAY_TEST_EXTENSION) : __dirname,
        extensionTestsPath: path.join(__dirname, 'test', summaryTest ? 'summary-native-runner.js' : process.argv.includes('--references') ? 'reference-native-runner.js' : 'native-runner.js'),
        extensionTestsEnv: {
            HISTORY_REPLAY_CDP_PORT: String(port),
            HISTORY_REPLAY_TEST_SOURCE: path.resolve(source),
            HISTORY_REPLAY_TEST_REQUEST: String(requestIndex),
            HISTORY_REPLAY_SUMMARY_ENTRY: summaryTest ? path.resolve(summaryEntry) : '',
            ...(artifacts ? { HISTORY_REPLAY_TEST_ARTIFACTS: '1' } : {}),
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