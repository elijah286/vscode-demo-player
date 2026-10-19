const path = require('node:path');
const os = require('node:os');
const fs = require('node:fs');
const net = require('node:net');
const { runTests } = require('@vscode/test-electron');

async function runSummaryUI(options, profile) {
    const { spawn } = require('node:child_process');
    const driver = path.join(profile, 'summary-ui-driver');
    const resultFile = path.join(profile, 'summary-ui-result.json');
    fs.mkdirSync(driver, { recursive: true });
    const manifest = { ...require('./package.json'), main: './driver.js' };
    fs.writeFileSync(path.join(driver, 'package.json'), JSON.stringify(manifest));
    fs.writeFileSync(path.join(driver, 'driver.js'),
        'const vscode = require("vscode");\n' +
        'exports.activate = context => {\n' +
        ' const api = require(' + JSON.stringify(path.join(options.extensionDevelopmentPath, 'native-extension.js')) + ').activate(context);\n' +
        ' const fs = require("node:fs"); const marker = ' + JSON.stringify(path.join(driver, 'started')) + ';\n' +
        ' if (fs.existsSync(marker)) return api; fs.writeFileSync(marker, "started");\n' +
        ' setTimeout(async () => {\n' +
        '  let result;\n' +
        '  try { await require(' + JSON.stringify(options.extensionTestsPath) + ').run(); result = { passed: true }; }\n' +
        '  catch (error) { console.error(error); result = { passed: false, error: error.stack }; }\n' +
        '  require("node:fs").writeFileSync(' + JSON.stringify(resultFile) + ', JSON.stringify(result));\n' +
        '  await vscode.commands.executeCommand("workbench.action.quit");\n' +
        ' }, 0);\n' +
        ' return api;\n' +
        '};\n');
    const env = { ...process.env, ...options.extensionTestsEnv, HISTORY_REPLAY_TEST_DRIVER: driver };
    delete env.ELECTRON_RUN_AS_NODE;
    // Normal development mode is intentional: extensionTestsPath suppresses VS Code modal dialogs.
    const child = spawn(options.vscodeExecutablePath, [
        '--extensionDevelopmentPath=' + driver, ...options.launchArgs
    ], { env, stdio: 'inherit' });
    let timer;
    try {
        await new Promise((resolve, reject) => {
            child.once('error', reject);
            child.once('exit', code => code === 0 ? resolve() : reject(new Error('Summary UI window exited with code ' + code)));
            timer = setTimeout(() => { child.kill(); reject(new Error('Summary UI acceptance exceeded 120 seconds')); }, 120000);
        });
        const result = JSON.parse(fs.readFileSync(resultFile, 'utf8'));
        if (!result.passed) throw new Error(result.error);
    } finally { clearTimeout(timer); }
}

async function main() {
    const summaryTest = process.argv.includes('--summaries');
    const artifacts = process.argv.includes('--artifacts');
    const profile = process.env.HISTORY_REPLAY_TEST_PROFILE ?? fs.mkdtempSync(path.join(os.tmpdir(), 'native-replay-test-'));
    let source = artifacts ? path.join(profile, 'synthetic-artifacts.jsonl') : process.env.HISTORY_REPLAY_TEST_SOURCE;
    let summaryEntry = process.env.HISTORY_REPLAY_TEST_SUMMARY_ENTRY;
    if (summaryTest && !summaryEntry) {
        fs.mkdirSync(profile, { recursive: true });
        fs.mkdirSync(path.join(profile, 'User'), { recursive: true });
        fs.writeFileSync(path.join(profile, 'User', 'settings.json'), JSON.stringify({
            'window.dialogStyle': 'custom', 'telemetry.telemetryLevel': 'off'
        }));
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
    if (summaryTest) {
        fs.mkdirSync(path.join(profile, 'requests'), { recursive: true });
        fs.mkdirSync(path.join(profile, 'workspace'), { recursive: true });
        fs.writeFileSync(path.join(profile, 'requests', '100-abc.json'), JSON.stringify({ file: path.resolve(summaryEntry) }));
    }
    const options = {
        vscodeExecutablePath: path.join(process.env.LOCALAPPDATA, 'Programs', 'Microsoft VS Code', 'Code.exe'),
        extensionDevelopmentPath: process.env.HISTORY_REPLAY_TEST_EXTENSION
            ? path.resolve(process.env.HISTORY_REPLAY_TEST_EXTENSION) : __dirname,
        extensionTestsPath: path.join(__dirname, 'test', summaryTest ? 'summary-native-runner.js' : process.argv.includes('--references') ? 'reference-native-runner.js' : 'native-runner.js'),
        extensionTestsEnv: {
            HISTORY_REPLAY_CDP_PORT: String(port),
            HISTORY_REPLAY_TEST_SOURCE: path.resolve(source),
            HISTORY_REPLAY_TEST_REQUEST: String(requestIndex),
            HISTORY_REPLAY_TEST_SUMMARY_ENTRY: summaryTest ? path.resolve(summaryEntry) : '',
            HISTORY_REPLAY_SUMMARY_ENTRY: '',
            HISTORY_REPLAY_SUMMARY_INBOX: summaryTest ? path.join(profile, 'requests') : '',
            ...(artifacts ? { HISTORY_REPLAY_TEST_ARTIFACTS: '1' } : {}),
            ...(process.env.HISTORY_REPLAY_BACKEND_PROBE === '1' ? { HISTORY_REPLAY_BACKEND_PROBE: '1' } : {})
        },
        launchArgs: [
            '--new-window',
            ...(summaryTest ? [path.join(profile, 'workspace')] : []),
            ...(process.env.HISTORY_REPLAY_AGENTS === '1' ? ['--agents'] : []),
            '--remote-debugging-port=' + port,
            '--user-data-dir', profile,
            '--shared-data-dir', path.join(profile, 'shared-data'),
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
    };
    if (summaryTest) await runSummaryUI(options, profile);
    else await runTests(options);
}

main().catch(error => {
    console.error(error);
    process.exitCode = 1;
});