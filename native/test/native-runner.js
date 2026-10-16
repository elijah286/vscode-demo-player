const assert = require('node:assert/strict');
const vscode = require('vscode');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const { chromium } = require('playwright');
const { readRecording, kindOf } = require('../replay');
const { inlineReferenceLabel, savedEditMarkdown } = require('../saved-parts');
const { controlView } = require('../control-server');

async function run() {
    const extension = vscode.extensions.getExtension('local.historical-transcript-replay');
    assert.ok(extension, 'Development extension is present');
    const api = await extension.activate();
    for (const [name, available] of Object.entries(api.capabilities)) {
        assert.equal(available, true, name + ' is available in the native extension host');
    }
    let deadline;
    const source = process.env.HISTORY_REPLAY_TEST_SOURCE;
    const requestIndex = Number(process.env.HISTORY_REPLAY_TEST_REQUEST ?? '0');
    assert.ok(source, 'A local native test transcript was explicitly selected');
    assert.ok(Number.isInteger(requestIndex) && requestIndex >= 0, 'A valid source turn was selected');
    const recording = await readRecording(source, requestIndex);
    await api.prepare(source, requestIndex, 2);
    if (process.env.HISTORY_REPLAY_BACKEND_PROBE === '1') {
        const host = await api.startBackendProbe();
        const controller = new AbortController();
        try {
            await new Promise((resolve, reject) => {
                const deadline = setTimeout(() => reject(new Error('Native backend connection did not initialize within 15 seconds. Observed methods: ' + host.observedMethods.join(', '))), 15000);
                const check = setInterval(() => {
                    if (host.observedMethods.includes('listSessions')) { clearTimeout(deadline); clearInterval(check); resolve(); }
                }, 50);
                controller.signal.addEventListener('abort', () => { clearTimeout(deadline); clearInterval(check); }, { once: true });
            });
            console.log('NATIVE CENTRAL BACKEND CONNECTED', JSON.stringify({ methods: host.observedMethods }));
            const resource = host.sessions[0].resource;
            const id = resource.slice(resource.lastIndexOf('/') + 1);
            await vscode.commands.executeCommand('vscode.open', vscode.Uri.parse('agent-host-session://historical-replay/' + id));
            await new Promise((resolve, reject) => {
                const deadline = setTimeout(() => reject(new Error('Native middle pane did not subscribe to recorded chat. Channels: ' + host.observedSubscriptions.join(', '))), 10000);
                const check = setInterval(() => {
                    if (host.observedSubscriptions.includes(host.chatResource)) { clearTimeout(deadline); clearInterval(check); resolve(); }
                }, 50);
                controller.signal.addEventListener('abort', () => { clearTimeout(deadline); clearInterval(check); }, { once: true });
            });
            console.log('NATIVE CENTRAL RECORDED CHAT OPENED', JSON.stringify({ session: resource, chat: host.chatResource, subscriptions: host.observedSubscriptions }));
        } finally { controller.abort(); }
        return;
    }
    const browser = await chromium.connectOverCDP('http://127.0.0.1:' + process.env.HISTORY_REPLAY_CDP_PORT);
    const pages = browser.contexts()[0].pages();
    console.log('NATIVE WINDOW TARGETS', JSON.stringify(pages.map(page => page.url())));
    const page = pages.find(page => process.env.HISTORY_REPLAY_AGENTS === '1' ? page.url().includes('/sessions/') : page.url().includes('workbench'));
    assert.ok(page, 'Real VS Code workbench page is available');
    if (process.env.HISTORY_REPLAY_AGENTS === '1') {
        console.log('NATIVE AGENTS WINDOW', JSON.stringify({ url: page.url(), title: await page.title(), bodyClass: await page.locator('body').getAttribute('class') }));
    }
    const screenshots = fs.mkdtempSync(path.join(os.tmpdir(), 'native-replay-visual-'));
    console.log('NATIVE TEST SCREENSHOTS', screenshots);
    if (process.env.HISTORY_REPLAY_AGENTS === '1') {
        const commands = await vscode.commands.getCommands(true);
        console.log('NATIVE AGENTS COMMANDS', JSON.stringify(commands.filter(command => /^(sessions|agentSessions)\./.test(command) && /open|new|create|reveal|show/i.test(command))));
        await page.screenshot({ path: path.join(screenshots, 'native-agents-initial.png') });
        await page.getByText('Sign in to use Agents', { exact: true }).waitFor({ state: 'hidden', timeout: 15000 });
        await page.getByText(/^Signing in(?:\.{3}|\u2026)$/, { exact: true }).waitFor({ state: 'hidden', timeout: 15000 });
        assert.equal(await page.getByText('Sign in to use Agents', { exact: true }).isVisible(), false, 'Agents must be signed in and unobstructed before replay');
    }
    try {
        await Promise.race([
            api.playNext({
                afterTyping: async () => {
                    if (process.env.HISTORY_REPLAY_AGENTS === '1') {
                        assert.equal(await page.getByText('Sign in to use Agents', { exact: true }).isVisible(), false);
                        assert.equal(await page.getByText(/^Signing in(?:\.{3}|\u2026)$/).isVisible(), false);
                        console.log('NATIVE AGENTS LAYOUT CONTROLS', JSON.stringify(await page.getByRole('button').evaluateAll(buttons => buttons.map(button => ({ label: button.getAttribute('aria-label'), title: button.getAttribute('title') })).filter(button => /maximi|expand|editor area|side.?bar|panel/i.test((button.label ?? '') + ' ' + (button.title ?? ''))))));
                    }
                    const promptInput = page.locator('.interactive-input-part .view-lines').filter({ hasText: recording.request.message.text });
                    if (process.env.HISTORY_REPLAY_AGENTS === '1') {
                        const editorInputs = page.locator('.part.editor .interactive-input-part .view-lines').filter({ hasText: recording.request.message.text });
                        assert.equal(await editorInputs.count(), 0, 'Agents replay must not type in the right-hand editor');
                    }
                    await promptInput.first().waitFor({ state: 'visible', timeout: 5000 });
                    await page.screenshot({ path: path.join(screenshots, 'native-prompt.png') });
                }
            }),
            new Promise((resolve, reject) => {
                void resolve;
                deadline = setTimeout(() => reject(new Error('Native replay exceeded 25 seconds')), 25000);
            })
        ]);
    } finally {
        clearTimeout(deadline);
    }
    assert.equal(api.state.typed.at(-1), recording.request.message.text);
    assert.equal(api.state.typed.length, Array.from(recording.request.message.text).length, 'One native input update per character');
    assert.equal(api.state.phase, 'review');
    assert.equal(controlView(api.state).action, 'play');
    assert.equal(api.state.turnIndex, 1);
    const expected = recording.request.response.filter(part => kindOf(part) === 'markdown').map(part => typeof part === 'string' ? part : part.value).join('');
    const actual = api.state.emitted.filter(part => part.kind === 'markdown').map(part => part.value).join('');
    assert.equal(actual, expected, 'Original assistant text replayed verbatim');
    const references = recording.request.response.filter(part => kindOf(part) === 'inlineReference');
    assert.deepEqual(api.state.emitted.filter(part => part.kind === 'inlineReference'), references, 'Saved reference payloads are preserved');
    for (const reference of references) {
        await page.locator('.interactive-response').filter({ hasText: inlineReferenceLabel(reference) }).last().waitFor({ state: 'visible', timeout: 5000 });
    }
    const edits = recording.request.response.filter(part => kindOf(part) === 'textEditGroup');
    assert.deepEqual(api.state.emitted.filter(part => part.kind === 'textEditGroup'), edits, 'Saved code edit payloads are preserved');
    for (const edit of edits) {
        await page.locator('.interactive-response strong').filter({ hasText: 'Recorded code edit - not applied' }).last().waitFor({ state: 'visible', timeout: 5000 });
        assert.ok(api.state.history[1].response.some(part => part.value?.value === savedEditMarkdown(edit)), 'Retained history uses the same read-only edit renderer');
    }
    if (edits.length) assert.equal(await page.locator('.interactive-response a[href^="command:example.run"]').count(), 0, 'Recorded replacement text never becomes a command link');
    const typingTime = api.state.metrics.typingUpdates.at(-1) - api.state.metrics.typingUpdates[0];
    const responseTime = api.state.metrics.responseFinished - api.state.metrics.promptFinished;
    assert.ok(Math.abs(typingTime - 2000) < 400, 'Prompt entry follows the two-second timeline: ' + typingTime);
    assert.ok(Math.abs(responseTime - 5000) < 400, 'Response follows the five-second timeline: ' + responseTime);
    await page.locator('.interactive-response .rendered-markdown:visible').last().waitFor({ state: 'visible', timeout: 5000 });
    await page.screenshot({ path: path.join(screenshots, 'native-response.png') });
    console.log('NATIVE ORIGINAL REPLAY PASSED', JSON.stringify({ prompt: recording.request.message.text, parts: api.state.emitted.length, typingUpdates: api.state.typed.length, typingMs: typingTime, responseMs: responseTime, fingerprint: recording.fingerprint }));
    assert.equal(api.state.phase, 'review', 'Reviewing the visible answer does not advance the script');
    const nextRecording = await readRecording(source, requestIndex + 1);
    try {
        await Promise.race([
            api.playNext({
                afterTyping: async () => {
                    await page.locator('.interactive-input-part .view-lines').filter({ hasText: nextRecording.request.message.text }).first().waitFor({ state: 'visible', timeout: 5000 });
                    await page.locator('.interactive-response .rendered-markdown:visible').first().waitFor({ state: 'visible', timeout: 5000 });
                    await page.screenshot({ path: path.join(screenshots, 'native-next-prompt.png') });
                }
            }),
            new Promise((resolve, reject) => {
                void resolve;
                deadline = setTimeout(() => reject(new Error('Second native turn exceeded 25 seconds')), 25000);
            })
        ]);
    } finally { clearTimeout(deadline); }
    const secondText = api.state.emitted.filter(part => part.kind === 'markdown').map(part => part.value).join('');
    assert.equal(secondText, nextRecording.request.response.filter(part => kindOf(part) === 'markdown').map(part => typeof part === 'string' ? part : part.value).join(''));
    assert.equal(api.state.phase, 'complete');
    assert.equal(api.state.turnIndex, 2);
    assert.equal(api.state.history.length, 4);
    if (edits.length) {
        await page.locator('.interactive-response').filter({ hasText: 'Recorded code edit - not applied' }).first().waitFor({ state: 'visible', timeout: 5000 });
    }
    assert.equal(controlView(api.state).enabled, false);
    const secondTyping = api.state.metrics.typingUpdates.at(-1) - api.state.metrics.typingUpdates[0];
    const secondResponse = api.state.metrics.responseFinished - api.state.metrics.promptFinished;
    assert.ok(Math.abs(secondTyping - 2000) < 400, 'Second prompt timing: ' + secondTyping);
    assert.ok(Math.abs(secondResponse - 5000) < 400, 'Second response timing: ' + secondResponse);
    await page.screenshot({ path: path.join(screenshots, 'native-two-turns.png') });
    await browser.close();
    console.log('NATIVE TWO-TURN REVIEW PASSED', JSON.stringify({ turns: api.state.turnIndex, typingMs: secondTyping, responseMs: secondResponse, fingerprint: nextRecording.fingerprint }));
}

module.exports = { run };