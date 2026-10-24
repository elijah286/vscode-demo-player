const { readEntry, includedTurnIndices } = require('./demo-library');
const { recordedOutput, summaryPrompt, QUESTION_CONTEXT_LENGTH, summaryQuestionContext, previousExchangeContext, validateGeneratedSummary, fitGeneratedSummary } = require('./prompt-summary-authoring');

const ENDPOINT = 'https://api.openai.com/v1/responses';
const DEFAULT_MODEL = 'gpt-4.1-mini';
const MODEL_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,179}$/;

class SummaryError extends Error {
    constructor(message, code = 'OPENAI_FAILED') { super(message); this.code = code; }
}

async function prepareSummaries(root, id, scope) {
    if (!['both', 'input', 'output'].includes(scope)) throw new SummaryError('Choose prompt, output, or combined summaries.');
    const entry = await readEntry(root, id);
    const candidates = [];
    const manualOutputs = [];
    const included = new Set(includedTurnIndices(entry.recording));
    const outputs = entry.recording.turns.map((turn, index) => {
        const request = turn.snapshot.requests[0];
        const output = recordedOutput(request);
        const source = output.text + '\n\n' + output.notice;
        if (included.has(index) && scope !== 'output' && !entry.recording.promptSummaries?.[index]) {
            candidates.push({ index, kind: 'input', source: request.message.text, previous: previousExchangeContext(entry.recording, index) });
        }
        if (included.has(index) && scope !== 'input' && !entry.recording.outputSummaries?.[index]) {
            if (output.text) candidates.push({ index, kind: 'output', source, question: summaryQuestionContext(request.message.text), previous: previousExchangeContext(entry.recording, index) });
            else manualOutputs.push(index + 1);
        }
        return source;
    });
    return { entry, outputs, candidates, manualOutputs };
}

async function readResponse(response) {
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
        size += chunk.length;
        if (size > 65536) throw new SummaryError('OpenAI returned an oversized response. No summaries were saved.');
        chunks.push(chunk);
    }
    try { return JSON.parse(Buffer.concat(chunks, size).toString('utf8')); }
    catch { throw new SummaryError('OpenAI returned invalid JSON. No summaries were saved.'); }
}

async function generateOpenAISummary({ apiKey, model, source, kind, partial = false, combine = false, question = '', previous = '', rewrite = '' }, { fetchImpl = fetch, timeoutMs = 90000, signal, progress } = {}) {
    const deadline = AbortSignal.timeout(timeoutMs);
    const totalSignal = signal ? AbortSignal.any([signal, deadline]) : deadline;
    const checkCancelled = () => {
        if (signal?.aborted) throw new SummaryError('Summary generation canceled. No summaries were saved.', 'OPENAI_CANCELLED');
        if (deadline.aborted) throw new SummaryError('The OpenAI request timed out. Retry explicitly. No summaries were saved.', 'OPENAI_TIMEOUT');
    };
    if (typeof rewrite !== 'string') throw new SummaryError('The length correction draft is invalid. No request was sent.');
    if (typeof apiKey !== 'string' || !/^[\x21-\x7e]{20,512}$/.test(apiKey)) {
        throw new SummaryError('Enter a valid OpenAI API key in Settings.', 'OPENAI_AUTH');
    }
    if (typeof model !== 'string' || !MODEL_PATTERN.test(model)) throw new SummaryError('Enter a valid OpenAI model ID in Settings.');
    if (typeof source !== 'string' || !source.length || (!source.trim() && !partial) || source.length > 64000 || !['input', 'output'].includes(kind) ||
        typeof partial !== 'boolean' || typeof combine !== 'boolean' || typeof question !== 'string' ||
        question.length > QUESTION_CONTEXT_LENGTH || (kind !== 'output' && question) ||
        typeof previous !== 'string' || previous.length > QUESTION_CONTEXT_LENGTH) {
        throw new SummaryError('The recorded summary source or kind is invalid. No request was sent.');
    }
    try {
        return await fitGeneratedSummary(candidate => requestOpenAISummary({ apiKey, model, source, kind, partial, combine, question, previous, rewrite: candidate },
            { fetchImpl, signal: totalSignal }), { initial: rewrite, checkCancelled, progress });
    } catch (error) {
        if (error instanceof SummaryError) throw error;
        throw new SummaryError(error.message);
    }
}

async function requestOpenAISummary({ apiKey, model, source, kind, partial, combine, question, previous, rewrite }, { fetchImpl, signal }) {
    let response;
    let body;
    try {
        response = await fetchImpl(ENDPOINT, {
            method: 'POST', redirect: 'error', signal,
            headers: { Authorization: 'Bearer ' + apiKey, 'Content-Type': 'application/json' },
            body: JSON.stringify({
                model, input: summaryPrompt(source, kind, { partial, combine, question, previous, rewrite }), max_output_tokens: 2048, store: false,
                text: { format: {
                    type: 'json_schema', name: 'demo_player_summary', strict: true,
                    schema: {
                        type: 'object', properties: { summary: { type: 'string' } },
                        required: ['summary'], additionalProperties: false
                    }
                } }
            })
        });
        if (response.status === 401) {
            await response.body?.cancel();
            throw new SummaryError('OpenAI rejected the API key. Replace it in Settings; no summaries were saved.', 'OPENAI_AUTH');
        }
        body = await readResponse(response);
    } catch (error) {
        if (error instanceof SummaryError) throw error;
        if (signal.aborted && signal.reason?.name !== 'TimeoutError') {
            throw new SummaryError('Summary generation canceled. No summaries were saved.', 'OPENAI_CANCELLED');
        }
        const code = error.cause?.code ?? error.code;
        if (['SELF_SIGNED_CERT_IN_CHAIN', 'DEPTH_ZERO_SELF_SIGNED_CERT', 'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
            'UNABLE_TO_GET_ISSUER_CERT_LOCALLY', 'CERT_HAS_EXPIRED', 'CERT_NOT_YET_VALID'].includes(code)) {
            throw new SummaryError('OpenAI HTTPS certificate validation failed. Demo Player uses the Windows trust store; ask your network administrator to check the certificate chain. TLS verification remains enabled. No summaries were saved.', 'OPENAI_TLS');
        }
        if (error.name === 'TimeoutError' || error.name === 'AbortError' || ['ETIMEDOUT', 'UND_ERR_CONNECT_TIMEOUT'].includes(code)) {
            throw new SummaryError('The OpenAI request timed out. Retry explicitly after checking your connection. No summaries were saved.', 'OPENAI_TIMEOUT');
        }
        if (['ENOTFOUND', 'EAI_AGAIN'].includes(code)) {
            throw new SummaryError('The OpenAI hostname could not be resolved. Check DNS and network settings, then retry explicitly. No summaries were saved.', 'OPENAI_DNS');
        }
        throw new SummaryError('OpenAI could not be reached because the network connection failed. Check your network or proxy settings and retry explicitly. No summaries were saved.', 'OPENAI_NETWORK');
    }
    if (!response.ok) {
        const message = response.status === 429
            ? 'OpenAI quota or rate limit reached. Check API billing and limits, then retry explicitly.'
            : response.status === 403 ? 'OpenAI denied access. Check project permissions and model access.'
                : response.status === 400 || response.status === 404 ? 'OpenAI rejected the request or model. Check the model ID and API access in Settings.'
                    : 'OpenAI failed to generate a summary (HTTP ' + response.status + '). Retry explicitly later.';
        throw new SummaryError(message + ' No summaries were saved.');
    }
    if (!body || body.status !== 'completed' || body.incomplete_details != null || !Array.isArray(body.output) ||
        body.output.some(item => item?.type === 'message' && item.status !== undefined && item.status !== 'completed')) {
        throw new SummaryError('OpenAI did not complete the summary. No summaries were saved; try another model or summarize manually.');
    }
    if (body.output.some(item => !item || typeof item !== 'object' ||
        (item.type === 'message' && !Array.isArray(item.content)))) {
        throw new SummaryError('OpenAI returned malformed output. No summaries were saved.');
    }
    const content = body.output.filter(item => item.type === 'message').flatMap(item => item.content);
    if (content.some(part => !part || typeof part !== 'object' ||
        (part.type === 'output_text' && typeof part.text !== 'string'))) {
        throw new SummaryError('OpenAI returned malformed output. No summaries were saved.');
    }
    if (content.some(part => part.type === 'refusal')) throw new SummaryError('OpenAI declined to summarize this source. No summaries were saved; summarize it manually.');
    const text = content.filter(part => part.type === 'output_text').map(part => part.text).join('');
    let structured;
    try { structured = JSON.parse(text); }
    catch { throw new SummaryError('OpenAI returned an invalid structured summary. No summaries were saved.'); }
    if (!structured || typeof structured !== 'object' || Array.isArray(structured) ||
        Object.keys(structured).length !== 1 || typeof structured.summary !== 'string') {
        throw new SummaryError('OpenAI returned an invalid structured summary. No summaries were saved.');
    }
    if (structured.summary.length > 4096) throw new SummaryError('The model returned too much text (over 4096 characters). No summary was saved.');
    const summary = structured.summary.trim();
    if (!summary) throw new SummaryError('OpenAI returned an empty summary. No summaries were saved.');
    try { validateGeneratedSummary(summary); }
    catch (error) { throw new SummaryError(error.message); }
    return summary;
}

async function main() {
    let input = '';
    process.stdin.setEncoding('utf8');
    for await (const chunk of process.stdin) {
        input += chunk;
        if (input.length > 4 * 1024 * 1024) throw new SummaryError('Summary request exceeds the size limit.');
    }
    const request = JSON.parse(input);
    if (request.command === 'prepareSummaries') return prepareSummaries(request.root, request.id, request.scope);
    if (request.command === 'generateSummary') return generateOpenAISummary(request, {
        progress: state => process.stderr.write('SUMMARY_PROGRESS ' + JSON.stringify(state) + '\n')
    });
    throw new SummaryError('Unknown OpenAI summary command.');
}

if (require.main === module) {
    main().then(result => process.stdout.write(JSON.stringify({ ok: true, result }))).catch(error => {
        process.stdout.write(JSON.stringify({
            ok: false, code: error instanceof SummaryError ? error.code : 'OPENAI_FAILED',
            error: error instanceof SummaryError ? error.message : 'Summary preparation failed. Check the saved selection and try again.'
        }));
        process.exitCode = 1;
    });
}

module.exports = { ENDPOINT, DEFAULT_MODEL, prepareSummaries, generateOpenAISummary };
