const library = require('./demo-library');

async function main() {
    let input = '';
    for await (const chunk of process.stdin) {
        input += chunk;
        if (input.length > 1024 * 1024) throw new Error('Library command exceeds 1 MiB.');
    }
    const request = JSON.parse(input);
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
        case 'summaries': return library.savePromptSummaries(root, request.id, request.summaries, request.expected);
        case 'delete': return library.deleteDemo(root, request.id);
        case 'export': return library.exportDemo(root, request.id, request.file);
        case 'read': return library.readEntry(root, request.id);
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
