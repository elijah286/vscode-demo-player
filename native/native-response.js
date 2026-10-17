const { randomUUID } = require('node:crypto');
const { recordedReference, savedEditText } = require('./saved-parts');

function markdown(vscode, value) {
    const result = new vscode.MarkdownString(typeof value === 'string' ? value : value?.value ?? '');
    result.isTrusted = false;
    result.supportHtml = false;
    return result;
}

function nativeResponsePart(vscode, event) {
    const part = event.part;
    if (event.kind === 'markdown') return new vscode.ChatResponseMarkdownPart(markdown(vscode, event.value));
    if (event.kind === 'thinking') return new vscode.ChatResponseThinkingProgressPart(part.value, part.id);
    const activityLabels = {
        textEditGroup: 'Recorded code edit - not applied',
        recordedSdkEvent: 'Recorded SDK events - read-only, never executed',
        questionCarousel: 'Recorded questions and answers - read-only',
        confirmation: 'Recorded confirmation - read-only',
        progressTaskSerialized: 'Recorded task progress - read-only',
        workspaceEdit: 'Recorded workspace edit - not applied'
    };
    if (Object.hasOwn(activityLabels, event.kind)) {
        let output;
        if (event.kind === 'textEditGroup') output = savedEditText(part);
        else if (event.kind === 'recordedSdkEvent') {
            if (!Array.isArray(part.events)) throw new Error('Recorded SDK event archive must contain an event array.');
            output = JSON.stringify(part.events, null, 2);
        } else output = JSON.stringify(part, null, 2);
        const result = new vscode.ChatToolInvocationPart('historyReplay.' + event.kind, 'recorded-display-' + randomUUID());
        result.invocationMessage = activityLabels[event.kind];
        result.pastTenseMessage = activityLabels[event.kind];
        result.isConfirmed = true;
        result.isComplete = true;
        result.toolSpecificData = {
            input: 'Read-only recorded activity. No tools are executed and no files are read or changed.',
            output
        };
        return result;
    }
    if (event.kind === 'inlineReference') {
        const reference = recordedReference(part);
        let uri;
        if (reference.uri.kind === 'components') uri = vscode.Uri.from(reference.uri.value);
        else if (reference.uri.kind === 'file') uri = vscode.Uri.file(reference.uri.value);
        else uri = vscode.Uri.parse(reference.uri.value, true);
        const target = reference.range ? new vscode.Location(uri, new vscode.Range(...reference.range)) : uri;
        return new vscode.ChatResponseAnchorPart(target, reference.title);
    }
    if (!['toolPending', 'toolComplete'].includes(event.kind)) throw new Error('Editor playback has no renderer for saved part: ' + event.kind);
    const result = new vscode.ChatToolInvocationPart(part.toolId, part.toolCallId);
    result.invocationMessage = markdown(vscode, part.invocationMessage);
    result.isConfirmed = true;
    result.isComplete = event.kind === 'toolPending' ? false : part.isComplete;
    if (event.kind === 'toolComplete') {
        result.enablePartialUpdate = true;
        result.pastTenseMessage = part.pastTenseMessage ? markdown(vscode, part.pastTenseMessage) : undefined;
        result.isError = part.isError;
        result.presentation = part.presentation;
        result.toolSpecificData = part.toolSpecificData;
    }
    return result;
}

module.exports = { nativeResponsePart };
