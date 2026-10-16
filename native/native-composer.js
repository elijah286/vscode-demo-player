const { chromium } = require('playwright');

class NativeComposer {
    async connect(port) {
        if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Native composer requires the isolated window debugging port.');
        this.browser = await chromium.connectOverCDP('http://127.0.0.1:' + port, { timeout: 10000 });
        this.page = this.browser.contexts()[0].pages().find(page => page.url().includes('/sessions/'));
        if (!this.page) throw new Error('The native Agents window is not available.');
    }

    async focus() {
        const editor = this.page.locator('.chat-view-chat .interactive-input-part .monaco-editor:visible').first();
        await editor.waitFor({ state: 'visible', timeout: 5000 });
        if (await editor.evaluate(element => !!element.closest('.part.editor'))) throw new Error('Refusing to type into the right-hand editor.');
        await this.page.bringToFront();
        await editor.scrollIntoViewIfNeeded();
        await editor.click();
        await this.page.keyboard.press('Control+A');
        await this.page.keyboard.press('Backspace');
    }

    async typePrompt(prompt, duration, clock) {
        const control = 'nativeReplayTypingControl';
        await this.page.evaluate(key => { globalThis[key] = { paused: false, stopped: false }; }, control);
        let syncing = false;
        const timer = setInterval(async () => {
            if (syncing) return;
            syncing = true;
            try { await this.page.evaluate(({ key, paused, stopped }) => { globalThis[key] = { paused, stopped }; }, { key: control, paused: clock.paused, stopped: clock.stopped }); }
            catch { clock.stop(); }
            finally { syncing = false; }
        }, 40);
        try {
            return await this.page.evaluate(async ({ prompt, duration, key }) => {
                const element = document.activeElement;
                const context = element?.editContext;
                if (!context || typeof TextUpdateEvent !== 'function') throw new Error('Native Agents input context unavailable.');
                const characters = Array.from(prompt.replace(/\r\n/g, '\n'));
                const started = performance.now();
                let previous = started;
                let elapsed = 0;
                let count = 0;
                const frames = [];
                while (count < characters.length) {
                    await new Promise(resolve => requestAnimationFrame(resolve));
                    const now = performance.now();
                    const state = globalThis[key];
                    if (state.stopped) throw new Error('Replay stopped.');
                    if (!state.paused) elapsed += now - previous;
                    previous = now;
                    if (state.paused) continue;
                    const target = Math.min(characters.length, 1 + Math.floor(elapsed * Math.max(1, characters.length - 1) / duration));
                    while (count < target) {
                        const text = characters[count++];
                        const start = context.selectionStart;
                        const end = context.selectionEnd;
                        context.dispatchEvent(new TextUpdateEvent('textupdate', { updateRangeStart: start, updateRangeEnd: end, text, selectionStart: start + text.length, selectionEnd: start + text.length, compositionStart: 0, compositionEnd: 0 }));
                    }
                    frames.push({ elapsed, characters: count });
                }
                await new Promise(resolve => requestAnimationFrame(resolve));
                return { frames, duration: performance.now() - started, characters: count };
            }, { prompt, duration, key: control });
        } finally {
            clearInterval(timer);
            await this.page.evaluate(key => { delete globalThis[key]; }, control).catch(() => {});
        }
    }

    async clear() {
        await this.page.keyboard.press('Control+A');
        await this.page.keyboard.press('Backspace');
    }

    async close() {
        if (this.browser) await this.browser.close();
    }
}

module.exports = { NativeComposer };