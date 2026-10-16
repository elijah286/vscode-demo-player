const crypto = require('node:crypto');
const path = require('node:path');

const INTERNAL_PARTS = new Set(['mcpServersStarting', 'undoStop', 'codeblockUri']);

function recordedReference(part) {
    const reference = part.inlineReference;
    const target = reference?.location ?? reference;
    let savedUri = target?.uri ?? target;
    if (savedUri && typeof savedUri === 'object' && !(typeof savedUri.scheme === 'string' && typeof savedUri.path === 'string') && typeof savedUri.external === 'string') savedUri = savedUri.external;
    const allowedSchemes = new Set(['file', 'http', 'https', 'vscode-remote', 'untitled', 'git']);
    let uri;
    let scheme;
    if (typeof savedUri === 'string') {
        if (/^[a-z]:[\\/]/i.test(savedUri) || savedUri.startsWith('\\\\')) {
            uri = { kind: 'file', value: savedUri };
            scheme = 'file';
        } else {
            scheme = /^([a-z][a-z0-9+.-]*):/i.exec(savedUri)?.[1].toLowerCase();
            uri = { kind: 'string', value: savedUri };
        }
    } else if (typeof savedUri?.scheme === 'string' && typeof savedUri.path === 'string') {
        const components = { scheme: savedUri.scheme, path: savedUri.path };
        for (const key of ['authority', 'query', 'fragment']) {
            if (savedUri[key] !== undefined) {
                if (typeof savedUri[key] !== 'string') throw new Error('Invalid recorded reference URI component: ' + key);
                components[key] = savedUri[key];
            }
        }
        uri = { kind: 'components', value: components };
        scheme = savedUri.scheme.toLowerCase();
    } else if (typeof savedUri?.fsPath === 'string' && (/^[a-z]:[\\/]/i.test(savedUri.fsPath) || savedUri.fsPath.startsWith('\\\\') || savedUri.fsPath.startsWith('/'))) {
        uri = { kind: 'file', value: savedUri.fsPath };
        scheme = 'file';
    } else throw new Error('Recorded inline reference has no supported absolute URI or file path.');
    if (!allowedSchemes.has(scheme)) throw new Error('Recorded inline reference uses an unsupported or executable URI scheme: ' + (scheme ?? '(missing)'));
    const title = part.name ?? part.title ?? reference?.name;
    if (title !== undefined && typeof title !== 'string') throw new Error('Recorded inline reference title must be text.');
    let range;
    const savedRange = target?.range;
    if (savedRange !== undefined) {
        if (!savedRange || typeof savedRange !== 'object') throw new Error('Recorded inline reference contains an invalid source range.');
        if (Number.isInteger(savedRange.startLineNumber) && Number.isInteger(savedRange.startColumn) && Number.isInteger(savedRange.endLineNumber) && Number.isInteger(savedRange.endColumn)) {
            range = [savedRange.startLineNumber - 1, savedRange.startColumn - 1, savedRange.endLineNumber - 1, savedRange.endColumn - 1];
        } else {
            const start = Array.isArray(savedRange) ? savedRange[0] : savedRange.start;
            const end = Array.isArray(savedRange) ? savedRange[1] : savedRange.end;
            range = [start?.line, start?.character, end?.line, end?.character];
        }
        if (range.some(value => !Number.isInteger(value) || value < 0) || range[2] < range[0] || (range[2] === range[0] && range[3] < range[1])) throw new Error('Recorded inline reference contains an invalid source range.');
    }
    return { uri, range, title };
}

function completedQuestions(part) {
    if (!part.isUsed || !part.data) throw new Error('Recorded questions must have saved answers before playback.');
    const kinds = { text: 'text', singleSelect: 'single-select', multiSelect: 'multi-select' };
    const questions = part.questions.map(question => {
        if (!kinds[question.type]) throw new Error('Unsupported recorded question type: ' + question.type);
        return {
            id: question.id,
            title: question.title,
            message: question.message ?? question.title ?? '',
            kind: kinds[question.type],
            ...(question.options ? { options: question.options.map(option => ({ id: option.id, label: option.label })) } : {}),
            ...(question.allowFreeformInput === undefined ? {} : { allowFreeformInput: question.allowFreeformInput })
        };
    });
    const answers = {};
    for (const question of questions) {
        const saved = part.data[question.id];
        let value;
        if (typeof saved === 'string') value = { kind: 'text', value: saved };
        else if (Array.isArray(saved?.selectedValues)) value = { kind: 'selected-many', value: saved.selectedValues };
        else if (typeof saved?.selectedValue === 'string') value = { kind: 'selected', value: saved.selectedValue };
        else if (typeof saved?.freeformValue === 'string') value = { kind: question.kind === 'multi-select' ? 'selected-many' : 'selected', value: question.kind === 'multi-select' ? [] : '', freeformValues: [saved.freeformValue] };
        else throw new Error('Recorded answer is missing or unsupported: ' + question.id);
        if (typeof saved?.freeformValue === 'string' && !value.freeformValues) value.freeformValues = [saved.freeformValue];
        answers[question.id] = { state: 'submitted', value };
    }
    return { kind: 'inputRequest', request: { id: part.resolveId, questions, answers }, response: 'accept' };
}

function archivedEdit(part) {
    const content = JSON.stringify(part, null, 2);
    const digest = crypto.createHash('sha256').update(content).digest('hex');
    const fileName = path.win32.basename(part.uri?.fsPath ?? part.uri?.path ?? part.inlineReference?.location?.uri?.fsPath ?? part.kind);
    const uri = 'recorded-artifact:/' + digest + '/' + encodeURIComponent(fileName) + '.json';
    return { part: { kind: 'contentRef', uri, contentType: 'application/json', sizeHint: Buffer.byteLength(content) }, uri, content };
}

module.exports = { INTERNAL_PARTS, recordedReference, completedQuestions, archivedEdit };