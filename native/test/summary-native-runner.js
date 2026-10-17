const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const vscode = require('vscode');
const { chromium } = require('playwright');

async function run() {
    const file = process.env.HISTORY_REPLAY_SUMMARY_ENTRY;
    const before = await fs.readFile(file);
    const entry = JSON.parse(before.toString('utf8'));
    const prompt = entry.recording.turns[0].snapshot.requests[0].message.text;
    const extension = vscode.extensions.getExtension('local.historical-transcript-replay');
    const api = await extension.activate();
    assert.equal(typeof api.run, 'function', 'The real extension activates in authoring-only mode');
    assert.equal(api.state, undefined, 'The playback backend is not started');
    const browser = await chromium.connectOverCDP('http://127.0.0.1:' + process.env.HISTORY_REPLAY_CDP_PORT);
    try {
        const page = browser.contexts()[0].pages().find(page => page.url().includes('workbench'));
        assert.ok(page, 'Isolated authoring workbench is available');
        await page.locator('.quick-input-list .monaco-list-row').filter({ hasText: 'Exchange 1' }).first().click();
        await page.getByRole('button', { name: 'Generate summary', exact: true }).waitFor({ state: 'visible', timeout: 15000 });
        assert.ok(vscode.workspace.textDocuments.some(document => document.getText() === prompt), 'The complete original query is available for review before consent');
        await page.getByRole('button', { name: 'Generate summary', exact: true }).click();
        await page.getByText(/Prompt summary: No VS Code AI model is available/).first().waitFor({ state: 'visible', timeout: 15000 });
        assert.deepEqual(await fs.readFile(file), before, 'Missing provider cannot change saved summaries or payloads');
        const runAgain = vscode.commands.executeCommand('historyReplay.summarizePrompt');
        await page.locator('.quick-input-list .monaco-list-row').filter({ hasText: 'Exchange 1' }).first().waitFor({ state: 'visible' });
        await page.keyboard.press('Escape');
        await runAgain;
        assert.deepEqual(await fs.readFile(file), before, 'Canceling another exchange selection preserves the entry');
        console.log('NATIVE SUMMARY AUTHORING PASSED: real authoring-only activation, complete original prompt preview, consent, missing-provider guidance, repeat command, cancellation, unchanged synthetic library. No AI request sent.');
    } finally { await browser.close(); }
}

module.exports = { run };
