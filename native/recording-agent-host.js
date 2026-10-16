const crypto = require('node:crypto');
const { WebSocketServer } = require('ws');
const { completedQuestions, archivedEdit } = require('./saved-parts');

class RecordingAgentHost {
    constructor(recordings = []) {
        this.sequence = 0;
        this.observedMethods = [];
        this.observedSubscriptions = [];
        this.states = new Map();
        this.sessions = [];
        this.clients = new Set();
        this.artifacts = new Map();
        this.root = {
            agents: [{
                provider: 'historical-replay',
                displayName: recordings[0]?.responderName || 'Recorded conversation',
                description: '',
                models: []
            }],
            activeSessions: 0,
            terminals: []
        };
        this.states.set('ahp-root://', this.root);
        if (recordings.length) {
            const models = new Map();
            for (const recording of recordings) {
                const model = recording.model ?? (typeof recording.request.modelId === 'string' ? { id: recording.request.modelId, name: recording.request.modelId } : undefined);
                if (model && !models.has(model.id)) models.set(model.id, { id: model.id, name: model.name, provider: 'historical-replay', _meta: { historicalReplay: true } });
            }
            this.root.agents[0].models = [...models.values()];
            const id = crypto.randomUUID();
            const resource = 'historical-replay:/' + id;
            const chatResource = 'ahp-chat:/' + id;
            const timestamp = new Date(recordings[0].request.timestamp ?? Date.now()).toISOString();
            const title = recordings[0].request.message.text.slice(0, 65);
            const chat = { resource: chatResource, title, status: 1, modifiedAt: timestamp, interactivity: 'full', turns: [] };
            if (recordings[0].request.modelId) chat.config = { values: { model: { id: recordings[0].request.modelId } } };
            const summary = { resource, provider: 'historical-replay', title, status: 1, createdAt: timestamp, modifiedAt: timestamp, defaultChat: chatResource };
            this.states.set(resource, { provider: summary.provider, title, status: 1, lifecycle: 'ready', activeClients: [], chats: [{ resource: chatResource, title, status: 1, modifiedAt: timestamp, interactivity: 'full' }], defaultChat: chatResource });
            this.states.set(chatResource, chat);
            this.sessions.push(summary);
            this.root.activeSessions = 1;
            this.recordings = recordings;
            this.sessionResource = resource;
            this.chatResource = chatResource;
        }
    }

    snapshot(resource) {
        if (!this.states.has(resource)) throw Object.assign(new Error('Recorded channel not found.'), { code: -32008 });
        return { resource, state: this.states.get(resource), fromSeq: this.sequence };
    }

    handle(message) {
        if (message?.jsonrpc !== '2.0' || !Object.hasOwn(message, 'id') || typeof message.method !== 'string') {
            return { jsonrpc: '2.0', id: message?.id ?? null, error: { code: -32600, message: 'Invalid request.' } };
        }
        try {
            this.observedMethods.push(message.method);
            let result;
            const params = message.params ?? {};
            if (message.method === 'initialize') {
                if (params.channel !== 'ahp-root://' || !Array.isArray(params.protocolVersions) || !params.protocolVersions.length || params.protocolVersions.some(version => typeof version !== 'string')) {
                    throw Object.assign(new Error('Expected native root channel and protocol versions.'), { code: -32602 });
                }
                result = {
                    protocolVersion: params.protocolVersions[0],
                    serverSeq: this.sequence,
                    serverInfo: { name: 'historical-replay', version: '0.0.1' },
                    snapshots: [...new Set(['ahp-root://', ...(params.initialSubscriptions ?? [])])].map(resource => this.snapshot(resource))
                };
            } else if (message.method === 'subscribe') {
                this.observedSubscriptions.push(params.channel);
                result = { snapshot: this.snapshot(params.channel) };
            } else if (message.method === 'listSessions') {
                result = { items: this.sessions };
            } else if (message.method === 'unsubscribe') {
                result = {};
            } else if (message.method === 'resourceRead' && this.artifacts.has(params.uri)) {
                const text = this.artifacts.get(params.uri);
                result = { data: params.encoding === 'base64' ? Buffer.from(text).toString('base64') : text, encoding: params.encoding === 'base64' ? 'base64' : 'utf-8', contentType: 'application/json' };
            } else {
                throw Object.assign(new Error('This recorded-session host does not execute requests: ' + message.method), { code: -32601 });
            }
            return { jsonrpc: '2.0', id: message.id, result };
        } catch (error) {
            return { jsonrpc: '2.0', id: message.id, error: { code: error.code ?? -32603, message: error.message } };
        }
    }

    publish(channel, action) {
        const envelope = { channel, action, serverSeq: ++this.sequence };
        const message = JSON.stringify({ jsonrpc: '2.0', method: 'action', params: envelope });
        for (const socket of this.clients) if (socket.readyState === 1) socket.send(message);
        return envelope;
    }

    draft(text, modelId = this.recordings?.[0]?.request.modelId) {
        const chat = this.states.get(this.chatResource);
        chat.draft = { text, origin: { kind: 'user' } };
        if (modelId) chat.draft.model = { id: modelId };
        return this.publish(this.chatResource, { type: 'chat/draftChanged', draft: chat.draft });
    }

    beginTurn(request) {
        const chat = this.states.get(this.chatResource);
        const turnId = request.requestId ?? crypto.randomUUID();
        const startedAt = new Date().toISOString();
        const message = { text: request.message.text, origin: { kind: 'user' }, _meta: { originalResponseParts: request.response } };
        if (request.modelId) message.model = { id: request.modelId };
        chat.draft = undefined;
        chat.activeTurn = { id: turnId, message, responseParts: [], startedAt };
        this.publish(this.chatResource, { type: 'chat/draftChanged' });
        return this.publish(this.chatResource, { type: 'chat/turnStarted', turnId, startedAt, message });
    }

    appendPart(part) {
        const chat = this.states.get(this.chatResource);
        chat.activeTurn.responseParts.push(part);
        return this.publish(this.chatResource, { type: 'chat/responsePart', turnId: chat.activeTurn.id, part });
    }

    appendSavedPart(part) {
        if (part.kind === 'questionCarousel') return this.appendPart(completedQuestions(part));
        if (['textEditGroup', 'inlineReference', 'confirmation', 'progressTaskSerialized', 'workspaceEdit', 'recordedSdkEvent'].includes(part.kind)) {
            const artifact = archivedEdit(part);
            this.artifacts.set(artifact.uri, artifact.content);
            return this.appendPart(artifact.part);
        }
        throw new Error('Unsupported saved display part: ' + part.kind);
    }

    appendDelta(partId, content) {
        const chat = this.states.get(this.chatResource);
        const part = chat.activeTurn.responseParts.find(part => part.id === partId);
        if (!part) return this.appendPart({ kind: 'markdown', id: partId, content });
        part.content += content;
        return this.publish(this.chatResource, { type: 'chat/delta', turnId: chat.activeTurn.id, partId, content });
    }

    completeTool(toolCallId, result) {
        const chat = this.states.get(this.chatResource);
        const part = chat.activeTurn.responseParts.find(part => part.kind === 'toolCall' && part.toolCall.toolCallId === toolCallId);
        if (part) part.toolCall = { ...part.toolCall, ...result, status: 'completed' };
        return this.publish(this.chatResource, { type: 'chat/toolCallComplete', turnId: chat.activeTurn.id, toolCallId, result });
    }

    finishTurn(duration = 5000) {
        const chat = this.states.get(this.chatResource);
        const turn = { ...chat.activeTurn, duration, state: 'complete' };
        chat.turns.push(turn);
        chat.activeTurn = undefined;
        return this.publish(this.chatResource, { type: 'chat/turnComplete', turnId: turn.id, duration });
    }

    async start() {
        const token = crypto.randomBytes(32).toString('hex');
        const expected = Buffer.from(token);
        const server = new WebSocketServer({
            host: '127.0.0.1',
            port: 0,
            maxPayload: 1024 * 1024,
            verifyClient: info => {
                const supplied = Buffer.from(new URL(info.req.url, 'http://127.0.0.1').searchParams.get('tkn') ?? '');
                return supplied.length === expected.length && crypto.timingSafeEqual(supplied, expected);
            }
        });
        await new Promise((resolve, reject) => {
            server.once('listening', resolve);
            server.once('error', reject);
        });
        server.on('connection', socket => {
            this.clients.add(socket);
            socket.once('close', () => this.clients.delete(socket));
            socket.on('message', data => {
                let request;
                try { request = JSON.parse(data.toString()); }
                catch {
                    socket.send(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Invalid JSON.' } }));
                    return;
                }
                if (!Object.hasOwn(request, 'id')) return;
                socket.send(JSON.stringify(this.handle(request)));
            });
        });
        return {
            address: 'ws://127.0.0.1:' + server.address().port,
            connectionToken: token,
            close: async () => {
                for (const socket of server.clients) socket.terminate();
                await new Promise(resolve => server.close(resolve));
            }
        };
    }
}

module.exports = { RecordingAgentHost };