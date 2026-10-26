const library = require('./demo-library');

async function main() {
    process.stdin.setEncoding('utf8');
    let input = '';
    for await (const chunk of process.stdin) {
        input += chunk;
        if (input.length > 1024 * 1024) throw new Error('Library command exceeds 1 MiB.');
    }
    const request = JSON.parse(input.replace(/^\uFEFF/, ''));
    return execute(request);
}

async function execute(request) {
    const root = request.root || library.defaultLibraryRoot();
    switch (request.command) {
        case 'list': return library.listDemos(root);
        case 'discover': return library.discoverSessions(request.storageRoot, request.folder);
        case 'history': {
            const result = await require('./history-catalog').discoverHistory(request,
                event => { if (request.progress) process.stdout.write(JSON.stringify({ progress: event }) + '\n'); });
            return request.progress ? { ...result, sessions: undefined, count: result.sessions.length } : result;
        }
        case 'inspect': return library.inspectTranscript(request.file);
        case 'capture': return library.addPackage(root, await library.createPackage(request.file, request.indices, request.title, request.sha256));
        case 'import': return library.addPackage(root, await library.readPackage(request.file));
        case 'rename': return library.renameDemo(root, request.id, request.title);
        case 'summaries': return library.savePromptSummaries(root, request.id, request.summaries, request.expected, request.kind, request.expectedLanguages);
        case 'summaryDraftIssues': return require('./prompt-summary-authoring').summaryDraftIssues(request.drafts, request.english ?? true);
        case 'summaryBatch': {
            if (request.recoveredItems !== undefined) {
                if (!Array.isArray(request.recoveredItems) ||
                    request.recoveredItems.some(item => !Number.isSafeInteger(item) || item < 0 ||
                        !Array.isArray(request.summaries?.promptSummaries) || !Array.isArray(request.summaries?.outputSummaries) ||
                        item >= 2 * request.summaries.promptSummaries.length)) throw new Error('Invalid recovered summary save request.');
                const drafts = request.recoveredItems.map(item => ({ item, summary:
                    (item % 2 ? request.summaries.outputSummaries : request.summaries.promptSummaries)[Math.floor(item / 2)] ?? '' }));
                const issues = require('./prompt-summary-authoring').summaryDraftIssues(drafts, !request.language || request.language === 'en');
                const failure = issues.find(draft => draft.issue);
                if (failure) throw new Error('Recovered exchange ' + (Math.floor(failure.item / 2) + 1) + ': ' + failure.issue);
            }
            return library.saveSummaryBatch(root, request.id, request.summaries, request.expected, request.language ?? undefined);
        }
        case 'summaryLanguage': return library.selectSummaryLanguage(root, request.id, request.language, request.expected);
        case 'summarySources': {
            const entry = await library.readEntry(root, request.id);
            return entry.recording.turns.map(turn => {
                const output = require('./prompt-summary-authoring').recordedOutput(turn.snapshot.requests[0]);
                return output.text + '\n\n' + output.notice;
            });
        }
        case 'delete': return library.deleteDemo(root, request.id);
        case 'export': return library.exportDemo(root, request.id, request.file);
        case 'read': return library.readEntry(root, request.id);
        case 'metadata': return library.entryMetadata(root, request.id);
        default: throw new Error('Unknown demo library command.');
    }
}

if (require.main === module) main().then(
    result => process.stdout.write(JSON.stringify({ ok: true, result })),
    error => {
        const message = error instanceof AggregateError ? error.message + ': ' + error.errors.map(failure => failure.message).join('; ') : error.message;
        process.stdout.write(JSON.stringify({ ok: false, error: message }));
        process.exitCode = 1;
    }
);

module.exports = { execute };
