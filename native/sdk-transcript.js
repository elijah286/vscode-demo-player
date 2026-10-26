function literalBlock(text) {
    let size = 3;
    for (const match of text.matchAll(/`+/g)) size = Math.max(size, match[0].length + 1);
    const fence = '`'.repeat(size);
    return '\n\n' + fence + 'text\n' + text + '\n' + fence + '\n\n';
}

function sdkEventMarkdown(part) {
    if (!Array.isArray(part.events)) throw new Error('Recorded SDK event archive must contain an event array.');
    return '\n\n**Recorded SDK events - read-only, never executed**\n\n' +
        literalBlock(JSON.stringify(part.events, null, 2));
}

function sdkCompletedAt(request) {
    if (request?.sdkCompletion !== 'complete' || request.sdkSessionStart?.type !== 'session.start' ||
        request.sdkSessionStart.data?.version !== 1 || !Array.isArray(request.sdkEvents)) return undefined;
    const end = request.sdkEvents.findLast(event => event.type === 'assistant.turn_end');
    const completedAt = Date.parse(end?.timestamp);
    return Number.isFinite(completedAt) && completedAt >= request.timestamp ? completedAt : undefined;
}

function sdkSnapshot(records) {
    const first = records[0];
    if (first?.type !== 'session.start' || first.data?.version !== 1) throw new Error('Unsupported SDK recording: expected session.start version 1.');
    if (typeof first.data.sessionId !== 'string' || !first.data.sessionId.trim()) throw new Error('Saved SDK session is missing its identifier.');
    const snapshot = {
        sessionId: first.data.sessionId, sourceKind: 'copilot-sdk-jsonl',
        creationDate: Date.parse(first.data.startTime || first.timestamp),
        responderUsername: first.data.producer,
        projectPath: first.data.context?.cwd, requests: []
    };
    let request;
    let tools = new Map();
    let ended = false;
    let finalText = false;
    let invalidTools = new Set();
    let archivedMessages = new Set();
    const prelude = [];
    function finish() {
        if (!request) return;
        const pending = [...tools.values()].some(tool => !tool.isComplete || invalidTools.has(tool.toolCallId));
        request.response = request.response.filter(part => part.kind !== 'toolInvocationSerialized' || (part.isComplete && !invalidTools.has(part.toolCallId)));
        const metadata = request.sdkEvents.filter(event => {
            if (event.type === 'user.message') return false;
            if (event.type === 'assistant.message') return archivedMessages.has(event);
            if (event.type === 'tool.execution_start') return !tools.get(event.data.toolCallId)?.isComplete || invalidTools.has(event.data.toolCallId);
            return true;
        });
        if (metadata.length) request.response.push({ kind: 'recordedSdkEvent', events: metadata });
        request.sdkCompletion = ended && finalText && !pending && !invalidTools.size && !archivedMessages.size && !request.sourceError ? 'complete' : 'partial';
        if (request.sdkCompletion === 'complete') {
            request.result = {};
            const completedAt = sdkCompletedAt(request);
            if (completedAt !== undefined) request.modelState = { completedAt };
        }
    }
    for (const event of records.slice(1)) {
        if (typeof event?.type !== 'string' || !event.data || typeof event.data !== 'object') throw new Error('Malformed saved SDK event.');
        if (event.type === 'user.message') {
            finish();
            request = {
                message: { text: event.data.content }, response: [], timestamp: Date.parse(event.timestamp),
                modelId: first.data.selectedModel, sdkSessionStart: first, sdkEvents: []
            };
            if (!snapshot.requests.length && prelude.length) request.sdkPrelude = [...prelude];
            if (typeof event.data.content !== 'string') request.sourceError = 'Saved SDK prompt is missing its text.';
            snapshot.requests.push(request);
            tools = new Map(); invalidTools = new Set(); archivedMessages = new Set(); ended = false; finalText = false;
        }
        if (!request) { prelude.push(event); continue; }
        request.sdkEvents.push(event);
        const timestamp = Date.parse(event.timestamp);
        if (Number.isFinite(timestamp)) request.lastActivity = timestamp;
        if (event.type === 'assistant.message') {
            if (typeof event.data.reasoningText === 'string' && event.data.reasoningText) request.response.push({ kind: 'thinking', value: event.data.reasoningText, id: event.id || event.data.messageId });
            else if (event.data.reasoningText !== undefined && event.data.reasoningText !== null && typeof event.data.reasoningText !== 'string') archivedMessages.add(event);
            if (typeof event.data.content === 'string' && event.data.content) request.response.push({ value: event.data.content });
            else if (event.data.content !== undefined && event.data.content !== null && typeof event.data.content !== 'string') archivedMessages.add(event);
            if (typeof event.data.model === 'string') request.modelId = event.data.model;
            if (event.data.toolRequests !== undefined && event.data.toolRequests !== null && !Array.isArray(event.data.toolRequests)) archivedMessages.add(event);
            finalText = event.data.toolRequests === undefined || event.data.toolRequests === null || (Array.isArray(event.data.toolRequests) && !event.data.toolRequests.length);
            ended = false;
        } else if (event.type === 'assistant.turn_start') ended = false;
        else if (event.type === 'assistant.turn_end') ended = true;
        else if (event.type === 'tool.execution_start') {
            const { toolCallId, toolName } = event.data;
            if (typeof toolCallId !== 'string' || !toolCallId || typeof toolName !== 'string' || !toolName || tools.has(toolCallId)) {
                invalidTools.add(toolCallId);
                continue;
            }
            const tool = { kind: 'toolInvocationSerialized', toolId: toolName, toolCallId, isComplete: false, invocationMessage: 'Recorded ' + toolName };
            tools.set(toolCallId, tool); request.response.push(tool);
        } else if (event.type === 'tool.execution_complete') {
            const tool = tools.get(event.data.toolCallId);
            if (tool && typeof event.data.success === 'boolean') {
                tool.isComplete = true; tool.isError = event.data.success === false;
                tool.pastTenseMessage = 'Recorded ' + tool.toolId + (tool.isError ? ' failed' : ' completed');
            }
        }
    }
    finish();
    return snapshot;
}

module.exports = { sdkSnapshot, sdkEventMarkdown, sdkCompletedAt };
