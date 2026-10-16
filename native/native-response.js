const { recordedReference, savedEditMarkdown } = require('./saved-parts');
const { sdkEventMarkdown } = require('./sdk-transcript');

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
    if (event.kind === 'textEditGroup') return new vscode.ChatResponseMarkdownPart(markdown(vscode, savedEditMarkdown(part)));
    if (event.kind === 'recordedSdkEvent') return new vscode.ChatResponseMarkdownPart(markdown(vscode, sdkEventMarkdown(part)));
    if (event.kind === 'inlineReference') {
        const reference = recordedReference(part);
        let uri;
        if (reference.uri.kind === 'components') uri = vscode.Uri.from(reference.uri.value);
        else if (reference.uri.kind === 'file') uri = vscode.Uri.file(reference.uri.value);
        else uri = vscode.Uri.parse(reference.uri.value, true);
        const target = reference.range ? new vscode.Location(uri, new vscode.Range(...reference.range)) : uri;
        return new vscode.ChatResponseAnchorPart(target, reference.title);
    }
    if (['questionCarousel', 'confirmation', 'progressTaskSerialized', 'workspaceEdit'].includes(event.kind)) {
        const content = markdown(vscode, '');
        content.appendCodeblock(JSON.stringify(part, null, 2), 'json');
        return new vscode.ChatResponseMarkdownPart(content);
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
