const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const vscode = require('vscode');
const { chromium } = require('playwright');

async function run() {
    const file = process.env.HISTORY_REPLAY_SUMMARY_ENTRY;
    const before = await fs.readFile(file);
    const entry = JSON.parse(before.toString('utf8'));
    const prompts = entry.recording.turns.map(turn => turn.snapshot.requests[0].message.text)
        .filter((prompt, index) => !entry.recording.promptSummaries?.[index] && prompt.replace(/\s+/g, ' ').trim().length > 200);
    assert.ok(prompts.length > 1, 'The native regression fixture must contain multiple unsummarized overlong prompts');
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
        console.log('NATIVE SUMMARY AUTHORING PASSED: real authoring-only activation, all long-prompt preview without exchange picker, one batch consent, missing-provider guidance, repeat command, cancellation, unchanged synthetic library. No AI request sent.');
    } finally { await browser.close(); }
}

module.exports = { run };
