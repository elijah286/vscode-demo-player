const readline = require('node:readline');
const { execute } = require('./library-cli');

const MAX_REQUEST = 1024 * 1024;

async function serve(input = process.stdin, output = process.stdout) {
    const lines = readline.createInterface({ input, crlfDelay: Infinity });
    for await (const line of lines) {
        let id = null;
        try {
            if (Buffer.byteLength(line, 'utf8') > MAX_REQUEST) throw new Error('Library command exceeds 1 MiB.');
            const packet = JSON.parse(line);
            if (!Number.isSafeInteger(packet.id) || packet.id < 1 || !packet.request || typeof packet.request !== 'object' || Array.isArray(packet.request)) {
                throw new Error('Invalid library request envelope.');
            }
            id = packet.id;
            const request = packet.request;
            if (request.command === 'history') throw new Error('Use the streaming history channel for discovery.');
            if (process.env.VIBEREPLAY_LIBRARY_ROOT && request.root !== process.env.VIBEREPLAY_LIBRARY_ROOT) {
                throw new Error('The library request does not belong to this worker.');
            }
            const result = await execute(request);
            output.write(JSON.stringify({ version: 1, id, ok: true, result }) + '\n');
        } catch (error) {
            const message = error instanceof AggregateError ? error.message + ': ' + error.errors.map(failure => failure.message).join('; ') : error.message;
            output.write(JSON.stringify({ version: 1, id, ok: false, error: message }) + '\n');
        }
    }
}

if (require.main === module) serve().catch(error => {
    process.stderr.write(error.stack + '\n');
    process.exitCode = 1;
});

module.exports = { serve };
