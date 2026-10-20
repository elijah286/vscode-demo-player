const assert = require('node:assert/strict');
const { generateSummary, summaryWorkspaceInbox } = require('../prompt-summary-authoring');

async function run(vscode) {
    assert.ok(summaryWorkspaceInbox(vscode), 'Authoring must activate from its own workspace, not inherited launch environment');
    const extension = vscode.extensions.getExtension('local.historical-transcript-replay');
    const api = await extension.activate();
    assert.equal(typeof api.run, 'function');
    assert.equal(api.state, undefined, 'Live authoring must not start playback');
    await api.ready;
    const models = await vscode.lm.selectChatModels();
    assert.ok(models.length, 'The existing editor profile must provide an actual AI model');
    const model = models.find(candidate => candidate.vendor === 'copilot') || models[0];
    const cancellation = new vscode.CancellationTokenSource();
    const timer = setTimeout(() => cancellation.cancel(), 90000);
    try {
        const input = await generateSummary(vscode, model, 'Synthetic user request: List three colors.', cancellation.token, 'input');
        const output = await generateSummary(vscode, model, 'Synthetic recorded assistant reply: Red, green, and blue.', cancellation.token, 'output');
        assert.ok(input.length && input.length <= 300);
        assert.ok(output.length && output.length <= 300);
        console.log('LIVE SUMMARY ACCEPTANCE PASSED: existing-profile provider discovery and two user-authorized synthetic input/output requests; no user recordings or saved summaries accessed.');
    } finally {
        clearTimeout(timer);
        cancellation.dispose();
    }
}

module.exports = { run };
