const fs = require('node:fs/promises');

async function main() {
    let input = '';
    for await (const chunk of process.stdin) input += chunk;
    const command = JSON.parse(input);
    if (process.env.UPDATER_UI_SCENARIO === 'CheckFailure') throw new Error('Synthetic offline failure');
    if (command.command === 'check') {
        const latestVersion = process.env.UPDATER_UI_LATEST_VERSION;
        if (!/^\d+\.\d+\.\d+$/.test(latestVersion ?? '')) throw new Error('The updater UI fixture requires an explicit latest version');
        return { currentVersion: command.currentVersion, latestVersion, updateAvailable: true, installedIsNewer: false };
    }
    if (command.command !== 'download') throw new Error('Unknown synthetic update operation');
    await fs.mkdir(command.directory, { recursive: true });
    await fs.writeFile(require('node:path').join(command.directory, 'partial-test-download'), 'synthetic');
    await new Promise(resolve => setTimeout(resolve, 30000));
    throw new Error('Synthetic slow download should have been canceled');
}

main().then(
    result => process.stdout.write(JSON.stringify({ ok: true, result })),
    error => { process.stdout.write(JSON.stringify({ ok: false, error: error.message })); process.exitCode = 1; }
);
