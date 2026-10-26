const test = require('node:test');
const assert = require('node:assert/strict');
const { reviewSummaries } = require('../prompt-summary-review');

test('slow fit validation remains cancellable through review closure without saving or posting to a closed panel', async context => {
    let receive;
    let dispose;
    let validationSignal;
    const errors = [];
    const panel = {
        dispose() { dispose(); },
        onDidDispose(callback) { dispose = callback; return { dispose() {} }; },
        webview: {
            onDidReceiveMessage(callback) { receive = callback; return { dispose() {} }; },
            postMessage(message) { errors.push(message); }
        }
    };
    context.mock.timers.enable({ apis: ['setTimeout'] });
    const result = reviewSummaries({
        ViewColumn: { Active: 1 }, window: { createWebviewPanel: () => panel }
    }, [{ exchange: 1, kind: 'input', summary: 'Complete draft.' }], async (_reviewed, signal) => {
        validationSignal = signal;
        await new Promise((resolve, reject) => {
            signal.addEventListener('abort', () => reject(signal.reason), { once: true });
        });
    });
    const saving = receive({ command: 'save', drafts: [{ exchange: 1, kind: 'input', summary: 'Complete draft.', status: 'approved' }] });
    context.mock.timers.tick(120000);
    assert.equal(validationSignal.aborted, false);
    panel.dispose();
    await saving;
    assert.equal(validationSignal.aborted, true);
    assert.equal(await result, undefined);
    assert.deepEqual(errors, []);
});

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

test('legacy review repair changes only unchanged generated overflows and saves only after explicit approval', async () => {
        const { generateSummary } = require('../prompt-summary-authoring');
        let receive;
        let disposed;
        const messages = [];
        const panel = {
            dispose() { disposed(); },
            onDidDispose(callback) { disposed = callback; return { dispose() {} }; },
            webview: {
                onDidReceiveMessage(callback) { receive = callback; return { dispose() {} }; },
                postMessage(message) { messages.push(message); }
            }
        };
        const source = 'No, the action failed. Should I use blue or green?';
        const original = 'I checked ' + 'x'.repeat(1446) + '.';
        let requests = 0;
        const drafts = [
            { exchange: 1, kind: 'input', prompt: 'Yes.', summary: 'Yes.' },
            { exchange: 1, kind: 'output', prompt: source, summary: original },
            { exchange: 2, kind: 'output', prompt: source, summary: original }
        ];
        const result = reviewSummaries({
            ViewColumn: { Active: 1 }, window: { createWebviewPanel: () => panel }
        }, drafts, undefined, async draft => generateSummary({
            LanguageModelChatMessage: { User: content => ({ content }) }
        }, {
            maxInputTokens: 10000, countTokens: async () => 1,
            sendRequest: async messages => {
                requests++;
                assert.match(messages[0].content, /1457 characters/);
                assert.ok(messages[0].content.endsWith(JSON.stringify(source)));
                return { text: (async function* () { yield source; })() };
            }
        }, draft.prompt, undefined, draft.kind, { rewrite: draft.summary }));
        await receive({ command: 'repair', drafts: [
            { summary: 'Yes.', status: 'approved' }, { summary: original, status: 'pending' },
            { summary: 'Human edited longer text.', status: 'approved' }
        ] });
        assert.equal(requests, 1);
        assert.deepEqual(messages, [{ command: 'repaired', changes: [{ index: 1, summary: source }] }]);
        await receive({ command: 'save', drafts: [
            { exchange: 1, kind: 'input', summary: 'Yes.', status: 'approved' },
            { exchange: 1, kind: 'output', summary: source, status: 'approved' },
            { exchange: 2, kind: 'output', summary: 'Human edited longer text.', status: 'approved' }
        ] });
        assert.equal((await result)[1].summary, source);
    });

    test('failed or canceled legacy repair leaves original drafts intact and rejects saving invalid results', async () => {
        for (const failure of [new Error('Canceled correction.'), 'x'.repeat(601)]) {
            let receive;
            let disposed;
            const messages = [];
            const original = 'I checked ' + 'x'.repeat(1446) + '.';
            const drafts = [{ exchange: 1, kind: 'output', summary: original }];
            const panel = {
                dispose() { disposed(); },
                onDidDispose(callback) { disposed = callback; return { dispose() {} }; },
                webview: { onDidReceiveMessage(callback) { receive = callback; return { dispose() {} }; }, postMessage(message) { messages.push(message); } }
            };
            const result = reviewSummaries({ ViewColumn: { Active: 1 }, window: { createWebviewPanel: () => panel } },
                drafts, undefined, async () => { if (failure instanceof Error) throw failure; return failure; });
            await receive({ command: 'repair', drafts: [{ summary: original, status: 'pending' }] });
            assert.equal(drafts[0].summary, original);
            assert.equal(messages[0].command, 'error');
            await receive({ command: 'cancel' });
            assert.equal(await result, undefined);
        }
    });
