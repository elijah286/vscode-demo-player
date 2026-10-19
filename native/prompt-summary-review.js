const crypto = require('node:crypto');
const { validatePromptSummaries } = require('./demo-library');
const { MAX_PROMPT_SUMMARY_LENGTH } = require('./replay');

function validateReviewedDrafts(reviewed, drafts) {
    if (!Array.isArray(reviewed) || reviewed.length !== drafts.length ||
        reviewed.some((turn, index) => turn?.exchange !== drafts[index].exchange ||
            turn.kind !== drafts[index].kind ||
            !['approved', 'deleted'].includes(turn.status) ||
            (turn.status === 'deleted' ? turn.summary !== null : typeof turn.summary !== 'string'))) {
        throw new Error('Approve or delete every summary before saving. Keep the original exchange order; original prompts cannot be deleted.');
    }
    validatePromptSummaries(reviewed.map(turn => turn.summary), drafts.length);
    return reviewed.map(turn => ({ exchange: turn.exchange, ...(turn.kind ? { kind: turn.kind } : {}), summary: turn.summary?.trim() ?? null }));
}

function summaryReviewHtml(drafts) {
    const nonce = crypto.randomBytes(16).toString('hex');
    const data = JSON.stringify(drafts).replace(/[<>&\u2028\u2029]/g, character =>
        '\\u' + character.charCodeAt(0).toString(16).padStart(4, '0'));
    return `<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}';">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Review input/output summaries</title>
<style nonce="${nonce}">
body { font-family: var(--vscode-font-family, sans-serif); color: var(--vscode-editor-foreground); background: var(--vscode-editor-background); padding: 16px; }
main { display: grid; grid-template-columns: minmax(150px, 24%) 1fr; gap: 20px; }
select { width: 100%; min-height: 260px; }
textarea, select { box-sizing: border-box; color: var(--vscode-input-foreground); background: var(--vscode-input-background); border: 1px solid var(--vscode-input-border, #888); font: inherit; padding: 8px; }
textarea { width: 100%; resize: vertical; }
#original { height: 220px; } #summary { height: 110px; }
label { display: block; margin: 12px 0 6px; font-weight: bold; }
button { margin: 8px 8px 0 0; padding: 8px 12px; border: 1px solid var(--vscode-button-border, transparent); color: var(--vscode-button-foreground); background: var(--vscode-button-background); cursor: pointer; }
button:disabled { opacity: .5; cursor: default; }
button:focus-visible, textarea:focus-visible, select:focus-visible { outline: 2px solid var(--vscode-focusBorder, #007acc); }
#error { color: var(--vscode-errorForeground, #c33); min-height: 1.5em; }
@media (max-width: 600px) { main { grid-template-columns: 1fr; } select { min-height: 100px; max-height: 140px; } }
</style></head><body>
<h1>Review input/output summaries</h1>
<p>Compare each AI draft with its recorded source. Edit, approve, or delete the summary only.
Playback keeps full originals. Deleted input summaries use excerpts; deleted outputs show an actionable missing-summary notice.</p>
<main><nav aria-label="Generated summaries"><label for="exchanges">Exchanges</label><select id="exchanges" size="10"></select></nav>
<section aria-label="Summary comparison">
<h2 id="heading"></h2>
<label for="original">Recorded source for this summary kind (read-only)</label><textarea id="original" readonly></textarea>
<label for="summary">Overlay summary (one line, up to ${MAX_PROMPT_SUMMARY_LENGTH} characters)</label>
<textarea id="summary" maxlength="${MAX_PROMPT_SUMMARY_LENGTH}" aria-describedby="count"></textarea>
<p id="count"></p>
<div><button id="previous">Previous</button><button id="next">Next</button></div>
<div><button id="approve">Approve &amp; next</button><button id="delete">Delete summary &amp; next</button><button id="all">Approve all remaining</button></div>
</section></main>
<p id="status" role="status" aria-live="polite"></p><p id="error" role="alert"></p>
<button id="save">Save reviewed summaries for playback</button><button id="cancel">Cancel</button>
<p>Nothing is saved until you save the reviewed batch. Then return to the interaction picker and choose Use selected exchanges or Use saved selection; enable Show prompt summary in the controller.</p>
<script nonce="${nonce}">
const vscode = acquireVsCodeApi();
const drafts = ${data}.map(turn => ({ ...turn, status: 'pending' }));
let index = 0;
const get = id => document.getElementById(id);
const valid = text => text.trim().length > 0 && text.length <= ${MAX_PROMPT_SUMMARY_LENGTH} && !/[\\r\\n]/.test(text);
function update() {
    const selected = get('exchanges');
    selected.replaceChildren(...drafts.map(turn => {
        const option = document.createElement('option');
        option.textContent = 'Exchange ' + turn.exchange + ' - ' + (turn.kind ?? 'input') + ' - ' + turn.status;
        return option;
    }));
    selected.selectedIndex = index;
    const pending = drafts.filter(turn => turn.status === 'pending').length;
    get('status').textContent = (drafts.length - pending) + '/' + drafts.length + ' reviewed. ' + pending + ' pending.';
    get('save').disabled = pending > 0;
    get('previous').disabled = index === 0;
    get('next').disabled = index === drafts.length - 1;
    get('approve').disabled = !valid(drafts[index].summary ?? '');
    get('count').textContent = (drafts[index].summary ?? '').length + '/${MAX_PROMPT_SUMMARY_LENGTH} characters - ' + drafts[index].status;
}
function show() {
    const turn = drafts[index];
    get('heading').textContent = 'Exchange ' + turn.exchange + ' - ' + (turn.kind ?? 'input') + ' (' + (index + 1) + '/' + drafts.length + ')';
    get('original').value = turn.prompt;
    get('summary').value = turn.summary ?? '';
    get('error').textContent = '';
    update();
}
function advance() { if (index < drafts.length - 1) index++; show(); }
get('exchanges').onchange = event => { index = event.target.selectedIndex; show(); };
get('previous').onclick = () => { index--; show(); };
get('next').onclick = () => { index++; show(); };
get('summary').oninput = event => {
    drafts[index].summary = event.target.value;
    drafts[index].status = 'pending';
    get('error').textContent = valid(event.target.value) ? '' : 'Use 1-${MAX_PROMPT_SUMMARY_LENGTH} characters on one line, or delete the summary.';
    update();
};
get('approve').onclick = () => {
    if (!valid(drafts[index].summary ?? '')) return;
    drafts[index].status = 'approved'; advance();
};
get('delete').onclick = () => { drafts[index].summary = null; drafts[index].status = 'deleted'; advance(); };
get('all').onclick = () => {
    const invalid = drafts.findIndex(turn => turn.status !== 'deleted' && !valid(turn.summary ?? ''));
    if (invalid >= 0) { index = invalid; show(); get('error').textContent = 'Edit this invalid summary or delete it before approving all.'; return; }
    drafts.forEach(turn => { if (turn.status !== 'deleted') turn.status = 'approved'; });
    update();
};
get('save').onclick = () => {
    get('save').disabled = true;
    vscode.postMessage({ command: 'save', drafts: drafts.map(({ exchange, kind, summary, status }) => ({ exchange, kind, summary, status })) });
};
get('cancel').onclick = () => vscode.postMessage({ command: 'cancel' });
window.addEventListener('message', event => { if (event.data.command === 'error') { get('error').textContent = event.data.message; update(); } });
show();
</script></body></html>`;
}

function reviewSummaries(vscode, drafts) {
    const panel = vscode.window.createWebviewPanel('demoPlayer.summaryReview', 'Review input/output summaries',
        vscode.ViewColumn.Active, { enableScripts: true, retainContextWhenHidden: true, localResourceRoots: [] });
    return new Promise(resolve => {
        const received = panel.webview.onDidReceiveMessage(message => {
            if (message?.command === 'cancel') panel.dispose();
            if (message?.command !== 'save') return;
            try {
                const reviewed = validateReviewedDrafts(message.drafts, drafts);
                resolve(reviewed);
                panel.dispose();
            } catch (error) {
                void panel.webview.postMessage({ command: 'error', message: error.message });
            }
        });
        const disposed = panel.onDidDispose(() => {
            received.dispose();
            disposed.dispose();
            resolve(undefined);
        });
        panel.webview.html = summaryReviewHtml(drafts);
    });
}

module.exports = { reviewSummaries, summaryReviewHtml, validateReviewedDrafts };
