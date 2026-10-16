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
    const content = JSON.stringify(part, null, 2);
    const digest = crypto.createHash('sha256').update(content).digest('hex');
    const fileName = path.win32.basename(part.uri?.fsPath ?? part.uri?.path ?? part.inlineReference?.location?.uri?.fsPath ?? part.kind);
    const uri = 'recorded-artifact:/' + digest + '/' + encodeURIComponent(fileName) + '.json';
    return { part: { kind: 'contentRef', uri, contentType: 'application/json', sizeHint: Buffer.byteLength(content) }, uri, content };
}

module.exports = { INTERNAL_PARTS, completedQuestions, archivedEdit };