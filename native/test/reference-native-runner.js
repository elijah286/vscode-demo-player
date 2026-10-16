const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const vscode = require('vscode');
const { chromium } = require('playwright');
const { readRecordings, kindOf } = require('../replay');

async function run() {
    const extension = vscode.extensions.getExtension('local.historical-transcript-replay');
    const api = await extension.activate();
    const source = process.env.HISTORY_REPLAY_TEST_SOURCE;
    const expected = await readRecordings(source, 0, 2);
    const references = expected[0].request.response.filter(part => kindOf(part) === 'inlineReference');
    assert.ok(references.length, 'The regression source must include a recorded inline reference');
    await api.prepare(source, 0, 2);
    const browser = await chromium.connectOverCDP('http://127.0.0.1:' + process.env.HISTORY_REPLAY_CDP_PORT, { timeout: 10000 });
    try {
        const page = browser.contexts()[0].pages().find(page => page.url().includes('workbench'));
        assert.ok(page, 'Native VS Code workbench is present');
        for (const [index, recording] of expected.entries()) {
            let deadline;
            try {
                await Promise.race([
                    api.playNext(),
                    new Promise((resolve, reject) => { void resolve; deadline = setTimeout(() => reject(new Error('Reference replay exceeded 30 seconds.')), 30000); })
                ]);
            } finally { clearTimeout(deadline); }
            const text = recording.request.response.filter(part => kindOf(part) === 'markdown').map(part => typeof part === 'string' ? part : part.value).join('');
            assert.equal(api.state.emitted.filter(part => part.kind === 'markdown').map(part => part.value).join(''), text);
            assert.equal(api.state.typed.at(-1), recording.request.message.text);
            const emitted = api.state.emitted.filter(part => part.kind === 'inlineReference').map(part => part.original);
            assert.deepEqual(emitted, recording.request.response.filter(part => kindOf(part) === 'inlineReference'));
            const anchors = api.state.history[1].response.filter(part => part instanceof vscode.ChatResponseAnchorPart);
            assert.equal(anchors.length, references.length, 'Native history retains the actual anchors after each turn');
            const visibleAnchor = page.locator('.interactive-response .chat-inline-anchor-widget[data-href]').first();
            await visibleAnchor.waitFor({ state: 'visible', timeout: 5000 });
            if (process.env.HISTORY_REPLAY_TEST_EVIDENCE) {
                await fs.mkdir(process.env.HISTORY_REPLAY_TEST_EVIDENCE, { recursive: true });
                await page.screenshot({ path: path.join(process.env.HISTORY_REPLAY_TEST_EVIDENCE, 'reference-turn-' + (index + 1) + '.png') });
            }
            console.log('NATIVE REFERENCE TURN PASSED', JSON.stringify({ turn: index + 1, references: emitted.length, historyAnchors: anchors.length, fingerprint: recording.fingerprint, responseMs: api.state.metrics.responseFinished - api.state.metrics.promptFinished }));
        }
        assert.equal(api.state.phase, 'complete');
        assert.equal(api.state.history.length, 4);
    } finally { await browser.close(); }
}

module.exports = { run };
