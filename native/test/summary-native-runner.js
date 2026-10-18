const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const vscode = require('vscode');
const { chromium } = require('playwright');
const library = require('../demo-library');
const { activateSummaryAuthoring } = require('../prompt-summary-authoring');

async function reviewFrame(page) {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
        for (const frame of page.frames()) {
            if (await frame.locator('#exchanges').count()) return frame;
        }
        await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error('The automatic summary comparison webview did not open.');
}

async function run() {
    const file = process.env.HISTORY_REPLAY_SUMMARY_ENTRY;
    const before = await fs.readFile(file);
    const entry = JSON.parse(before.toString('utf8'));
    const prompts = entry.recording.turns.map(turn => turn.snapshot.requests[0].message.text)
        .filter((prompt, index) => !entry.recording.promptSummaries?.[index] && prompt.replace(/\s+/g, ' ').trim().length > 300);
    assert.equal(prompts.length, 4, 'The native regression fixture must contain four unsummarized overlong prompts');
    const extension = vscode.extensions.getExtension('local.historical-transcript-replay');
    const api = await extension.activate();
    assert.equal(typeof api.run, 'function', 'The real extension activates in authoring-only mode');
    assert.equal(api.state, undefined, 'The playback backend is not started');
    const browser = await chromium.connectOverCDP('http://127.0.0.1:' + process.env.HISTORY_REPLAY_CDP_PORT);
    try {
        const page = browser.contexts()[0].pages().find(page => page.url().includes('workbench'));
        assert.ok(page, 'Isolated authoring workbench is available');
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        assert.equal(await page.locator('.quick-input-list:visible').count(), 0, 'No per-prompt selection is required');
        assert.ok(vscode.workspace.textDocuments.some(document => prompts.every(prompt => document.getText().includes(prompt))), 'All eligible original prompts are available before one batch consent');
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).click();
        await page.getByText(/Prompt summary: No VS Code AI model is available/).first().waitFor({ state: 'visible', timeout: 15000 });
        assert.deepEqual(await fs.readFile(file), before, 'Missing provider cannot change saved summaries or payloads');
        const runAgain = vscode.commands.executeCommand('historyReplay.summarizePrompt');
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        await vscode.commands.executeCommand('notifications.clearAll');
        await runAgain;
        assert.deepEqual(await fs.readFile(file), before, 'Canceling another batch consent preserves the entry');
        let requests = 0;
        const syntheticModel = {
            name: 'Synthetic summary model', vendor: 'test', id: 'synthetic', maxInputTokens: 10000,
            countTokens: async () => 100,
            sendRequest: async messages => {
                const text = messages[0].content.map(part => part.value).join('');
                assert.ok(prompts.some(prompt => text.endsWith(JSON.stringify(prompt))), 'Only original prompts are sent');
                requests++;
                return { text: (async function* () { yield 'Synthetic draft ' + requests; })() };
            }
        };
        // Only the provider and model picker are synthetic; use real VS Code consent, progress and webview APIs.
        const authoring = activateSummaryAuthoring({ subscriptions: [] }, {
            CancellationTokenSource: vscode.CancellationTokenSource,
            LanguageModelChatMessage: vscode.LanguageModelChatMessage,
            ProgressLocation: vscode.ProgressLocation,
            ViewColumn: vscode.ViewColumn,
            workspace: vscode.workspace,
            commands: { registerCommand: () => ({ dispose() {} }) },
            lm: { selectChatModels: async () => [syntheticModel] },
            window: {
                showTextDocument: vscode.window.showTextDocument,
                showWarningMessage: vscode.window.showWarningMessage,
                showErrorMessage: message => { console.error(message); return vscode.window.showErrorMessage(message); },
                showInformationMessage: vscode.window.showInformationMessage,
                withProgress: vscode.window.withProgress,
                createWebviewPanel: vscode.window.createWebviewPanel,
                showQuickPick: async models => models[0]
            }
        }, file);
        const generated = authoring.run();
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).click();
        const frame = await reviewFrame(page);
        const original = frame.getByLabel('Original prompt (read-only)');
        const summary = frame.getByLabel('Overlay summary (one line, up to 300 characters)');
        const save = frame.getByRole('button', { name: 'Save reviewed summaries for playback', exact: true });
        assert.equal(await original.inputValue(), prompts[0], 'Full original is visible automatically after generation');
        assert.equal(await original.getAttribute('readonly'), '', 'Original cannot be edited');
        assert.equal(await summary.inputValue(), 'Synthetic draft 1');
        assert.ok(await save.isDisabled(), 'Pending drafts cannot be saved');
        await summary.fill('Invalid\nmultiline');
        assert.ok(await frame.getByRole('button', { name: 'Approve & next', exact: true }).isDisabled());
        await frame.getByRole('button', { name: 'Approve all remaining', exact: true }).click();
        assert.match(await frame.locator('#error').textContent(), /invalid summary/);
        await summary.fill('W'.repeat(300));
        await frame.getByRole('button', { name: 'Approve & next', exact: true }).click();
        assert.equal(await original.inputValue(), prompts[1], 'Individual approval advances to the next original');
        await frame.getByRole('button', { name: 'Delete summary & next', exact: true }).click();
        assert.equal(await original.inputValue(), prompts[2]);
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
        assert.ok(await save.isEnabled());
        await page.screenshot({ path: path.join(path.dirname(file), 'summary-review.png') });
        await save.click();
        await generated;
        const after = await library.readEntry(path.dirname(file), entry.id);
        assert.deepEqual(after.recording.promptSummaries, ['W'.repeat(300), null, 'Synthetic draft 3', 'Synthetic draft 4', null]);
        assert.deepEqual(after.recording.turns, entry.recording.turns, 'All original prompts, replies and payload hashes are unchanged');
        assert.deepEqual(after.recording.source, entry.recording.source);
        const playback = await library.packageRecordings(file);
        assert.equal(playback[0].promptSummary, 'W'.repeat(300), 'Playback reads the full reviewed summary without the old 200-character cut');
        assert.equal(playback[0].request.message.text, prompts[0], 'Playback still types the original prompt');
        assert.equal(playback[1].request.message.text, prompts[1], 'Deleting a summary does not delete playback');
        assert.equal(playback[1].promptSummary.length, 300, 'Deleted summary uses the bounded original excerpt');
        assert.equal(requests, 4, 'One synthetic provider request per long prompt');
        const saved = await fs.readFile(file);
        const canceled = authoring.run();
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        await page.getByRole('button', { name: 'Generate summaries', exact: true }).click();
        const canceledFrame = await reviewFrame(page);
        await canceledFrame.getByRole('button', { name: 'Cancel', exact: true }).click();
        await canceled;
        assert.deepEqual(await fs.readFile(file), saved, 'Canceling automatic review preserves the saved library byte-for-byte');
        console.log('NATIVE SUMMARY AUTHORING PASSED: real isolated activation, consent, missing-provider guidance, automatic comparison webview, full read-only originals, editable 300-char summaries, invalid-input gating, individual approval/advance, deletion/restoration, list navigation, approve-all preserving deletions, edit revokes approval, save/playback fidelity, cancel byte preservation, inert HTML-like data. Synthetic provider only; no external AI requests.');
    } finally { await browser.close(); }
}

module.exports = { run };
