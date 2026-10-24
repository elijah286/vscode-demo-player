const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const vscode = require('vscode');
const { chromium } = require('playwright');
const library = require('../demo-library');
const { activateSummaryAuthoring, recordedOutput, generateSummary } = require('../prompt-summary-authoring');
const { reviewSummaries } = require('../prompt-summary-review');

async function reviewFrame(page) {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
        for (const frame of page.frames()) {
            if (frame.isDetached()) continue;
            try {
                if (await frame.locator('#exchanges').count()) return frame;
            } catch (error) {
                if (page.isClosed() || !/detached|Target page, context or browser has been closed/.test(error.message)) throw error;
            }
        }
        await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error('The automatic summary comparison webview did not open.');
}

async function run() {
    const file = process.env.HISTORY_REPLAY_TEST_SUMMARY_ENTRY;
    const progress = stage => fs.appendFile(path.join(path.dirname(file), 'summary-ui-progress.log'), new Date().toISOString() + ' ' + stage + '\n');
    await progress('runner started');
    const before = await fs.readFile(file);
    const entry = JSON.parse(before.toString('utf8'));
    const prompts = entry.recording.turns.map(turn => turn.snapshot.requests[0].message.text)
        .filter((prompt, index) => !entry.recording.promptSummaries?.[index] && prompt.replace(/\s+/g, ' ').trim().length > 300);
    const outputs = entry.recording.turns.map(turn => {
        const output = recordedOutput(turn.snapshot.requests[0]);
        return output.text + '\n\n' + output.notice;
    });
    assert.equal(prompts.length, 4, 'The native regression fixture must contain four unsummarized overlong prompts');
    const extension = vscode.extensions.getExtension('local.historical-transcript-replay');
    const api = await extension.activate();
    assert.equal(typeof api.run, 'function', 'The real extension activates in authoring-only mode');
    assert.equal(api.state, undefined, 'The playback backend is not started');
    const browser = await chromium.connectOverCDP('http://127.0.0.1:' + process.env.HISTORY_REPLAY_CDP_PORT);
    try {
        const page = browser.contexts()[0].pages().find(page => page.url().includes('workbench'));
        assert.ok(page, 'Isolated authoring workbench is available');
        const setup = page.getByText('Prompt summaries: AI provider setup required', { exact: true });
        await setup.waitFor({ state: 'visible', timeout: 15000 });
        assert.equal(await page.getByRole('button', { name: 'Generate summaries', exact: true }).count(), 0, 'No content consent before provider readiness');
        assert.ok(await page.getByRole('button', { name: 'Find providers', exact: true }).isVisible(), 'Setup is an actionable modal, not a hidden notification');
        await page.getByRole('button', { name: 'Retry', exact: true }).click();
        await setup.waitFor({ state: 'visible', timeout: 15000 });
        await page.screenshot({ path: path.join(path.dirname(file), 'summary-provider-missing.png') });
        await progress('provider setup and retry verified');
        assert.deepEqual(await fs.readFile(file), before, 'Missing provider cannot change saved summaries or payloads');
        await page.getByRole('button', { name: 'Find providers', exact: true }).click();
        await api.ready;
        assert.ok(await page.getByText('Prompt summaries: Retry / set up AI', { exact: true }).isVisible(), 'Persistent status action remains available during setup');
        const runAgain = api.run();
        await setup.waitFor({ state: 'visible', timeout: 15000 });
        await page.getByRole('button', { name: 'Cancel', exact: true }).click();
        await runAgain;
        assert.deepEqual(await fs.readFile(file), before, 'Canceling setup preserves the entry');
        await api.ready;
        await progress('manual setup cancellation verified');
        const secondRoot = path.join(path.dirname(file), 'second-library');
        const second = await library.addPackage(secondRoot, { ...entry.recording, title: 'Synthetic later selection' });
        const secondFile = path.join(secondRoot, second.id + '.demo.json');
        const secondBefore = await fs.readFile(secondFile);
        assert.ok(!process.env.HISTORY_REPLAY_SUMMARY_INBOX, 'Authoring activation must not depend on inherited process environment');
        const inbox = path.join(path.dirname(vscode.workspace.workspaceFolders[0].uri.fsPath), 'requests');
        const { spawn } = require('node:child_process');
        const profile = path.dirname(inbox);
        const env = { ...process.env };
        delete env.ELECTRON_RUN_AS_NODE;
        env.VSCODE_DEMO_PLAYER_SUMMARY_ROOT = profile;
        const quote = value => "'" + value.replace(/'/g, "''") + "'";
        const launch = '. ' + quote(path.join(__dirname, '..', '..', 'DemoDialogs.ps1')) + '; ' +
            '$script:LibraryRoot = ' + quote(secondRoot) + '; ' +
            'function Invoke-DemoLibrary { param($Request, $Owner) Get-Content -Raw -LiteralPath ' + quote(secondFile) + ' | ConvertFrom-Json }; ' +
            'function Resolve-PlayerVSCode { param($CodePath) ' + quote(process.execPath) + ' }; ' +
            'Start-DemoSummaryAuthoring ' + quote(second.id) + " $null 'output'";
        await progress('starting repeated production launch');
        await new Promise((resolve, reject) => {
            const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "$ErrorActionPreference = 'Stop'; " + launch], {
                env, stdio: ['ignore', 'ignore', 'pipe']
            });
            let output = '';
            child.stderr.on('data', data => { output += data; });
            child.once('error', reject);
            child.once('exit', code => code === 0 ? resolve() : reject(new Error('Repeated authoring launch failed: ' + code + ' ' + output)));
        });
        await progress('repeated production launch exited');
        await page.getByText('Response summaries: AI provider setup required', { exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        await page.getByRole('button', { name: 'Cancel', exact: true }).click();
        const deadline = Date.now() + 5000;
        while (JSON.parse(await fs.readFile(path.join(inbox, 'last.json'), 'utf8')).file !== secondFile && Date.now() < deadline) {
            await new Promise(resolve => setTimeout(resolve, 50));
        }
        assert.deepEqual(JSON.parse(await fs.readFile(path.join(inbox, 'last.json'), 'utf8')), { file: secondFile, scope: 'output' }, 'A repeated response-only launch targets the later selection and retains its scope');
        assert.deepEqual(await fs.readFile(secondFile), secondBefore);
        assert.equal(browser.contexts()[0].pages().filter(candidate => candidate.url().includes('workbench')).length, 1, 'Repeated launch reuses one dedicated authoring workspace');
        await progress('repeated output selection verified');
        let requests = 0;
        const sourceCalls = new Map();
        const overlong = length => 'I checked ' + 'x'.repeat(length - 11) + '.';
        const syntheticModel = {
            name: 'Synthetic summary model', vendor: 'test', id: 'synthetic', maxInputTokens: 10000,
            countTokens: async () => 100,
            sendRequest: async messages => {
                const text = messages[0].content.map(part => part.value).join('');
                assert.ok([...entry.recording.turns.map(turn => turn.snapshot.requests[0].message.text), ...outputs].some(source => text.endsWith(JSON.stringify(source))), 'Only consented input or filtered recorded output is sent');
                if (outputs.some(source => text.endsWith(JSON.stringify(source)))) {
                    assert.match(text, /Do not assume the user request succeeded/);
                }
                requests++;
                const sources = [...prompts, ...outputs];
                const sourceIndex = sources.findIndex(source => text.endsWith(JSON.stringify(source)));
                const count = (sourceCalls.get(sourceIndex) ?? 0) + 1;
                sourceCalls.set(sourceIndex, count);
                const draft = count === 1 && [0, 2].includes(sourceIndex) ? overlong(sourceIndex === 0 ? 601 : 1201) : 'Synthetic draft ' + (sourceIndex + 1) + '.';
                return { text: (async function* () { yield draft; })() };
            }
        };
        // Only the provider and model picker are synthetic; use real VS Code consent, progress and webview APIs.
        const authoring = activateSummaryAuthoring({ subscriptions: [] }, {
            CancellationTokenSource: vscode.CancellationTokenSource,
            LanguageModelChatMessage: vscode.LanguageModelChatMessage,
            ProgressLocation: vscode.ProgressLocation,
            StatusBarAlignment: vscode.StatusBarAlignment,
            ViewColumn: vscode.ViewColumn,
            workspace: vscode.workspace,
            commands: { registerCommand: () => ({ dispose() {} }) },
            lm: { selectChatModels: async () => [syntheticModel] },
            window: {
                createStatusBarItem: vscode.window.createStatusBarItem,
                showTextDocument: vscode.window.showTextDocument,
                showWarningMessage: vscode.window.showWarningMessage,
                showErrorMessage: (message, ...args) => { console.error(message); return vscode.window.showErrorMessage(message, ...args); },
                showInformationMessage: vscode.window.showInformationMessage,
                withProgress: vscode.window.withProgress,
                createWebviewPanel: vscode.window.createWebviewPanel,
                showQuickPick: async models => models[0]
            }
        }, file);
        const generated = authoring.run();
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        assert.equal(await page.locator('.quick-input-list:visible').count(), 0, 'No per-prompt selection is required');
        assert.ok(vscode.workspace.textDocuments.some(document => prompts.every(prompt => document.getText().includes(prompt))), 'Full originals are available before batch consent');
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).click();
        const frame = await reviewFrame(page);
        const original = frame.getByLabel('Recorded source for this summary kind (read-only)');
        const summary = frame.getByLabel('Overlay summary (one line, up to 1200 characters)');
        const save = frame.getByRole('button', { name: 'Save reviewed summaries for playback', exact: true });
        assert.equal(await original.inputValue(), prompts[0], 'Full original is visible automatically after generation');
        assert.equal(await original.getAttribute('readonly'), '', 'Original cannot be edited');
        assert.equal(await summary.inputValue(), 'Synthetic draft 1.', 'The overlong draft is automatically rewritten before review');
        assert.equal(await frame.locator('#error').textContent(), '');
        assert.ok(await frame.getByRole('button', { name: 'Approve & next', exact: true }).isEnabled());
        assert.ok(await save.isDisabled(), 'Pending drafts cannot be saved');
        await frame.getByRole('button', { name: 'Approve all remaining', exact: true }).click();
        assert.match(await frame.locator('#status').textContent(), /9\/9 reviewed.*0 pending/);
        assert.ok(await save.isEnabled(), 'All automatically fitted drafts save without manual repairs');
        await summary.fill('Invalid\nmultiline');
        assert.ok(await frame.getByRole('button', { name: 'Approve & next', exact: true }).isDisabled());
        await frame.getByRole('button', { name: 'Approve all remaining', exact: true }).click();
        assert.match(await frame.locator('#error').textContent(), /one line/);
        await summary.fill('W'.repeat(300));
        await frame.getByRole('button', { name: 'Approve & next', exact: true }).click();
        assert.equal(await original.inputValue(), prompts[1], 'Individual approval advances to the next original');
        await frame.getByRole('button', { name: 'Delete summary & next', exact: true }).click();
        assert.equal(await original.inputValue(), prompts[2]);
        assert.equal(await summary.inputValue(), 'Synthetic draft 3.', '1201-character draft was rewritten before review');
        assert.equal(await frame.locator('#error').textContent(), '');
        await summary.fill('Synthetic draft 3.');
        await frame.getByRole('button', { name: 'Previous', exact: true }).click();
        assert.equal(await original.inputValue(), prompts[1], 'Deleting only a summary leaves its full original in the list');
        assert.equal(await summary.inputValue(), '');
        await summary.fill('Restored draft');
        assert.match(await frame.locator('#count').textContent(), /pending/, 'Editing a deleted summary requires fresh approval');
        await frame.getByRole('button', { name: 'Delete summary & next', exact: true }).click();
        await frame.getByRole('button', { name: 'Approve all remaining', exact: true }).click();
        assert.ok(await save.isEnabled());
        await frame.locator('#exchanges').selectOption({ index: 0 });
        await summary.fill('Reviewed '.repeat(33).trim());
        assert.ok(await save.isDisabled(), 'Editing an approved summary revokes approval');
        await summary.fill('W'.repeat(300));
        await frame.getByRole('button', { name: 'Approve & next', exact: true }).click();
        await frame.locator('#exchanges').selectOption({ index: 3 });
        assert.equal(await original.inputValue(), prompts[3], 'HTML-like original content is inert and preserved');
        await frame.locator('#exchanges').selectOption({ index: 4 });
        assert.match(await frame.locator('#heading').textContent(), /output/, 'Review explicitly distinguishes output from input');
        assert.equal(await original.inputValue(), outputs[0], 'Output summary uses the recorded answer, not its user request');
        await summary.fill('Reviewed recorded result');
        await frame.getByRole('button', { name: 'Approve & next', exact: true }).click();
        assert.equal(await original.inputValue(), outputs[1]);
        await frame.getByRole('button', { name: 'Delete summary & next', exact: true }).click();
        assert.ok(await save.isEnabled());
        await page.screenshot({ path: path.join(path.dirname(file), 'summary-review.png') });
        await save.click();
        await generated;
        const after = await library.readEntry(path.dirname(file), entry.id);
        assert.deepEqual(after.recording.promptSummaries, ['W'.repeat(300), null, 'Synthetic draft 3.', 'Synthetic draft 4.', null]);
        assert.deepEqual(after.recording.outputSummaries, ['Reviewed recorded result', null, 'Synthetic draft 7.', 'Synthetic draft 8.', 'Synthetic draft 9.']);
        assert.deepEqual(after.recording.turns, entry.recording.turns, 'All original prompts, replies and payload hashes are unchanged');
        assert.deepEqual(after.recording.source, entry.recording.source);
        const playback = await library.packageRecordings(file);
        assert.equal(playback[0].promptSummary, 'W'.repeat(300), 'Playback reads the full reviewed summary without the old 200-character cut');
        assert.equal(playback[0].request.message.text, prompts[0], 'Playback still types the original prompt');
        assert.equal(playback[1].request.message.text, prompts[1], 'Deleting a summary does not delete playback');
        assert.equal(playback[1].promptSummary.length, 300, 'Deleted summary uses the bounded original excerpt');
        assert.equal(playback[0].outputSummary, 'Reviewed recorded result');
        assert.equal(playback[1].outputSummary, null, 'Deleting an output summary never invents a fallback result');
        assert.equal(requests, 11, 'Nine generation requests plus exactly two automatic length rewrites');
        const saved = await fs.readFile(file);
        const canceled = authoring.run();
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).click();
        const canceledFrame = await reviewFrame(page);
        assert.equal(await canceledFrame.locator('#summary').inputValue(), 'Synthetic draft 2.');
        await canceledFrame.getByRole('button', { name: 'Cancel', exact: true }).click();
        await canceled;
        assert.deepEqual(await fs.readFile(file), saved, 'Canceling automatic review preserves the saved library byte-for-byte');
        const responseGenerated = authoring.run(undefined, 'output');
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        assert.ok(await page.getByText(/paired user question context/).isVisible(), 'Response-only consent explicitly includes the paired question as context');
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).click();
        const responseFrame = await reviewFrame(page);
        assert.equal(await responseFrame.locator('#exchanges option').count(), 1, 'Only the single missing output is generated, not the deleted input summary');
        assert.match(await responseFrame.locator('#heading').textContent(), /output/);
        assert.equal(await responseFrame.getByLabel('Recorded source for this summary kind (read-only)').inputValue(), outputs[1]);
        await responseFrame.getByLabel('Overlay summary (one line, up to 1200 characters)').fill('Explicitly reviewed response summary');
        await responseFrame.getByRole('button', { name: 'Approve all remaining', exact: true }).click();
        await responseFrame.getByRole('button', { name: 'Save reviewed summaries for playback', exact: true }).click();
        await responseGenerated;
        const responseSaved = await library.readEntry(path.dirname(file), entry.id);
        assert.deepEqual(responseSaved.recording.promptSummaries, after.recording.promptSummaries, 'Explicit response generation leaves input summaries exactly unchanged');
        assert.equal(responseSaved.recording.outputSummaries[1], 'Explicitly reviewed response summary');
        assert.deepEqual(responseSaved.recording.turns, entry.recording.turns, 'Explicit response generation preserves all original answers and prompts');
        const missingInputs = responseSaved.recording.turns.length - responseSaved.recording.promptSummaries.filter(Boolean).length;
        const promptsGenerated = authoring.run(undefined, 'input');
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        assert.ok(await page.getByText(/Only input summaries are generated by this action/).isVisible());
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).click();
        const inputFrame = await reviewFrame(page);
        assert.equal(await inputFrame.locator('#exchanges option').count(), missingInputs, 'Prompt-only mode includes every missing input, even the short prompt');
        await inputFrame.getByRole('button', { name: 'Approve all remaining', exact: true }).click();
        await inputFrame.getByRole('button', { name: 'Save reviewed summaries for playback', exact: true }).click();
        await promptsGenerated;
        const promptsSaved = await library.readEntry(path.dirname(file), entry.id);
        assert.equal(promptsSaved.recording.promptSummaries.filter(Boolean).length, entry.recording.turns.length);
        assert.deepEqual(promptsSaved.recording.outputSummaries, responseSaved.recording.outputSummaries);
        assert.deepEqual(promptsSaved.recording.turns, entry.recording.turns);
        const legacyBefore = await fs.readFile(file);
        const legacySource = 'No, the action failed. Should I use blue or green?';
        let repairRequests = 0;
        const legacy = reviewSummaries(vscode, [
            { exchange: 1, kind: 'input', prompt: 'Yes.', summary: 'Yes.' },
            { exchange: 1, kind: 'output', prompt: legacySource, summary: overlong(1457) }
        ], undefined, async draft => {
            const consent = await vscode.window.showWarningMessage('Shorten the shown unsaved draft and source with AI? Up to 4 billed requests.', { modal: true }, 'Shorten with AI');
            if (consent !== 'Shorten with AI') return undefined;
            return generateSummary(vscode, {
                maxInputTokens: 10000, countTokens: async () => 1,
                sendRequest: async messages => {
                    repairRequests++;
                    const prompt = messages[0].content.map(part => part.value).join('');
                    assert.match(prompt, /1457 characters/);
                    assert.ok(prompt.endsWith(JSON.stringify(legacySource)));
                    return { text: (async function* () { yield legacySource; })() };
                }
            }, draft.prompt, undefined, draft.kind, { rewrite: draft.summary });
        });
        const legacyFrame = await reviewFrame(page);
        await legacyFrame.getByRole('button', { name: 'Approve all remaining', exact: true }).click();
        assert.ok(await legacyFrame.locator('#save').isDisabled());
        assert.equal(await legacyFrame.locator('#summary').inputValue(), overlong(1457));
        await legacyFrame.getByRole('button', { name: 'Automatically shorten AI summaries', exact: true }).click();
        await page.getByRole('button', { name: 'Shorten with AI', exact: true }).click();
        await legacyFrame.locator('#summary').evaluate((element, text) => new Promise(resolve => {
            const interval = setInterval(() => { if (element.value === text) { clearInterval(interval); resolve(); } }, 20);
        }), legacySource);
        assert.match(await legacyFrame.locator('#status').textContent(), /1\/2 reviewed.*1 pending/);
        assert.equal(repairRequests, 1);
        await legacyFrame.getByRole('button', { name: 'Approve all remaining', exact: true }).click();
        assert.ok(await legacyFrame.locator('#save').isEnabled());
        await legacyFrame.locator('#save').click();
        const repaired = await legacy;
        assert.deepEqual(repaired.map(draft => draft.summary), ['Yes.', legacySource]);
        assert.deepEqual(await fs.readFile(file), legacyBefore, 'Legacy review does not mutate saved data itself');
        console.log('NATIVE AUTOMATIC FIT PASSED: 601/1201 automatic generation rewrites, approve-all enables Save without typing; explicit legacy1457 repair keeps other approvals and source question/choices; no paid requests.');
        console.log('NATIVE CONTROLLER PROMPT SCOPE PASSED: short and long missing inputs, prompt-only consent/review/save, unchanged outputs/originals.');
        console.log('NATIVE EXPLICIT RESPONSE GENERATION PASSED: real response-only launch inbox, provider setup, scoped consent, output-only review/edit/approve/save, input-summary preservation and original-answer fidelity; synthetic model only.');
        console.log('NATIVE SUMMARY AUTHORING PASSED: real isolated activation, consent, missing-provider guidance, automatic comparison webview, full read-only originals, editable 300-char summaries, invalid-input gating, individual approval/advance, deletion/restoration, list navigation, approve-all preserving deletions, edit revokes approval, save/playback fidelity, cancel byte preservation, inert HTML-like data. Synthetic provider only; no external AI requests.');
    } finally { await browser.close(); }
}

module.exports = { run };
