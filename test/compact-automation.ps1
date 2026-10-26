function Expand-CompactControllerTools($Parent, [string]$Id) {
    if (-not $Parent -or $Parent.Current.Name -ne 'VibeReplay - Demo Player') { return }
    $section = if ($Id -in @('AutoContinue', 'ShowPrompt', 'ShowElapsed', 'ShowOutput', 'FrameColor', 'WindowMode',
            'PlaybackSpeed', 'SummaryLanguage', 'SummaryDisplayLanguage')) { 'PresentationOptions' }
        elseif ($Id -in @('SelectExchanges', 'GeneratePromptSummaries', 'GenerateOutputSummaries',
            'TranslateSummaries', 'AISettings', 'CheckUpdates', 'UpdateNotice')) { 'PreparationOptions' }
        else { return }
    $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $section)
    $expander = $Parent.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
    if ($expander) {
        $pattern = $expander.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern)
        if ($pattern.Current.ExpandCollapseState -eq 'Collapsed') { $pattern.Expand() }
    }
}
