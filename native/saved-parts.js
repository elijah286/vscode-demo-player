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
    if (part.kind === 'textEditGroup') validateSavedEditGroup(part);
    const content = JSON.stringify(part, null, 2);
    const digest = crypto.createHash('sha256').update(content).digest('hex');
    const fileName = path.win32.basename(part.uri?.fsPath ?? part.uri?.path ?? part.inlineReference?.location?.uri?.fsPath ?? part.kind);
    const uri = 'recorded-artifact:/' + digest + '/' + encodeURIComponent(fileName) + '.json';
    return { part: { kind: 'contentRef', uri, contentType: 'application/json', sizeHint: Buffer.byteLength(content) }, uri, content };
}

function validateSavedEditGroup(part) {
    if (part?.kind !== 'textEditGroup') throw new Error('Expected a saved text edit group.');
    if (part.done !== true) throw new Error('Recorded code edit is incomplete: its completion flag is missing or false.');
    const uri = part.uri;
    if (!(typeof uri?.fsPath === 'string' && uri.fsPath.trim()) &&
        !(typeof uri?.scheme === 'string' && uri.scheme.trim() && typeof uri.path === 'string' && uri.path.trim())) {
        throw new Error('Recorded code edit is missing its target URI.');
    }
    if (!Array.isArray(part.edits)) throw new Error('Recorded code edit is missing its saved edit batches.');
    for (const [batchIndex, batch] of part.edits.entries()) {
        if (!Array.isArray(batch)) throw new Error('Recorded code edit batch ' + (batchIndex + 1) + ' is not an array.');
        for (const [editIndex, edit] of batch.entries()) {
            const label = 'Recorded code edit batch ' + (batchIndex + 1) + ', replacement ' + (editIndex + 1);
            if (typeof edit?.text !== 'string') throw new Error(label + ' is missing its replacement text.');
            const range = edit.range;
            const fields = ['startLineNumber', 'startColumn', 'endLineNumber', 'endColumn'];
            if (!range || fields.some(field => !Number.isSafeInteger(range[field]) || range[field] < 1) ||
                range.endLineNumber < range.startLineNumber ||
                (range.endLineNumber === range.startLineNumber && range.endColumn < range.startColumn)) {
                throw new Error(label + ' has a missing or invalid saved range.');
            }
        }
    }
    return part;
}

function savedEditText(part) {
    validateSavedEditGroup(part);
    const target = typeof part.uri.fsPath === 'string' && part.uri.fsPath.trim()
        ? part.uri.fsPath : part.uri.scheme + ':' + part.uri.path;
    const sections = [
        'Recorded code edit - not applied',
        'Target: ' + target,
        'Saved replacement text and ranges only; this is not a reconstructed before/after diff.',
        'No target files are read or changed. Ranges are 1-based with an exclusive end.'
    ];
    for (const [batchIndex, batch] of part.edits.entries()) {
        if (!batch.length) sections.push('Batch ' + (batchIndex + 1) + ': no replacements recorded.');
        for (const [editIndex, edit] of batch.entries()) {
            const range = edit.range;
            sections.push(
                'Batch ' + (batchIndex + 1) + ', replacement ' + (editIndex + 1) +
                ' | range ' + range.startLineNumber + ':' + range.startColumn + ' - ' + range.endLineNumber + ':' + range.endColumn,
                'Replacement text:\n' + (edit.text.length ? edit.text : '[Empty replacement text]')
            );
        }
    }
    if (!part.edits.length) sections.push('No replacement batches recorded.');
    return sections.join('\n\n');
}

function savedEditMarkdown(part) {
    const text = savedEditText(part);
    let length = 3;
    for (const match of text.matchAll(/`+/g)) length = Math.max(length, match[0].length + 1);
    const fence = '`'.repeat(length);
    return '\n\n**Recorded code edit - not applied**\n\n' +
        'Saved replacements only. No files are read or changed; this is not a before/after diff.\n\n' +
        fence + 'text\n' + text + '\n' + fence + '\n\n';
}

function inlineReferenceLabel(part) {
    const reference = recordedReference(part);
    const target = reference.uri.kind === 'components' ? reference.uri.value.path : reference.uri.value;
    return reference.title || path.win32.basename(target) || target;
}

module.exports = { INTERNAL_PARTS, recordedReference, completedQuestions, archivedEdit, inlineReferenceLabel, validateSavedEditGroup, savedEditText, savedEditMarkdown };
