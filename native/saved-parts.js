const crypto = require('node:crypto');
const path = require('node:path');

const INTERNAL_PARTS = new Set(['mcpServersStarting', 'undoStop', 'codeblockUri']);

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
    const reference = part.inlineReference;
    const uri = reference?.uri ?? reference?.location?.uri ?? reference;
    if (!uri || typeof uri.scheme !== 'string' || typeof uri.path !== 'string') {
        throw new Error('Saved inline reference is missing its URI.');
    }
    return part.name || reference.name || path.win32.basename(uri.path) || uri.path;
}

module.exports = { INTERNAL_PARTS, completedQuestions, archivedEdit, inlineReferenceLabel, validateSavedEditGroup, savedEditText, savedEditMarkdown };