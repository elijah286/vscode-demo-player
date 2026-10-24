const test = require('node:test');
const assert = require('node:assert/strict');
const { reviewSummaries } = require('../prompt-summary-review');

test('a failed rendered-pair check keeps the review open and allows editing/retry', async () => {
    let receive;
    let dispose;
    let disposed = false;
    const errors = [];
    const panel = {
        dispose() { disposed = true; dispose(); },
        onDidDispose(callback) { dispose = callback; return { dispose() {} }; },
        webview: {
            onDidReceiveMessage(callback) { receive = callback; return { dispose() {} }; },
            postMessage(message) { errors.push(message); }
        }
    };
    let attempts = 0;
    const result = reviewSummaries({
        ViewColumn: { Active: 1 },
        window: { createWebviewPanel() { return panel; } }
    }, [{ exchange: 1, kind: 'input', summary: 'Original complete draft.' }], async () => {
        if (++attempts === 1) throw new Error('Exchange 1: prompt and reply cannot fit together on this screen.');
    });
    await receive({ command: 'save', drafts: [{ exchange: 1, kind: 'input', summary: 'Original complete draft.', status: 'approved' }] });
    assert.equal(disposed, false);
    assert.match(errors[0].message, /Exchange 1:.*cannot fit together/);
    await receive({ command: 'save', drafts: [{ exchange: 1, kind: 'input', summary: 'Shortened complete draft.', status: 'approved' }] });
    assert.deepEqual(await result, [{ exchange: 1, kind: 'input', summary: 'Shortened complete draft.' }]);
    assert.equal(disposed, true);
    assert.equal(attempts, 2);
});
