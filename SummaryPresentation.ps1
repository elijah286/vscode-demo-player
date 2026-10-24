param([switch]$ValidateStdin)

if ($ValidateStdin) {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
}
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
if (-not ('ReplayMessageFactory' -as [type])) {
    Add-Type -ReferencedAssemblies PresentationFramework,PresentationCore,WindowsBase,System.Xaml -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Media;
public static class ReplayMessageFactory {
    private static Brush Frozen(byte red, byte green, byte blue) {
        var brush = new SolidColorBrush(Color.FromRgb(red, green, blue));
        brush.Freeze();
        return brush;
    }
    private static readonly Brush Blue = Frozen(21, 87, 165);
    private static readonly Brush Neutral = Frozen(233, 237, 242);
    private static readonly Brush Dark = Frozen(32, 32, 32);
    public static Border Create(int index, bool input, string summary) {
        string name = index == 0 ? "First" : index == 1 ? "Second" : "Message" + index;
        Brush foreground = input ? Brushes.White : Dark;
        var label = new TextBlock { Text = input ? "You" : "AI", FontSize = 12, FontWeight = FontWeights.Bold, Foreground = foreground };
        var text = new TextBlock { Text = summary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0,4,0,0), Foreground = foreground };
        AutomationProperties.SetAutomationId(label, name + "Label");
        AutomationProperties.SetAutomationId(text, name + "Text");
        var stack = new StackPanel();
        stack.Children.Add(label);
        stack.Children.Add(text);
        if (!input) {
            var arrow = new TextBlock { Text = "\u2193", Foreground = Brushes.DimGray };
            AutomationProperties.SetAutomationId(arrow, "ConversationArrow" + index);
            AutomationProperties.SetName(arrow, "Input followed by output");
            stack.Children.Add(arrow);
        }
        return new Border { Child = stack, Padding = new Thickness(12,8,12,8), CornerRadius = new CornerRadius(10),
            Margin = new Thickness(0,4,0,4), HorizontalAlignment = input ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            ToolTip = "Saved summary shown in full. If its wording is clipped, edit it against the original in Select exchanges, or delete that summary and explicitly generate it again. Playback never regenerates summaries.",
            Background = input ? Blue : Neutral };
    }
    public static double PairHeight(string input, string output, double width) {
        var panel = new StackPanel();
        System.Windows.Documents.TextElement.SetFontFamily(panel, new FontFamily("Segoe UI"));
        double fontSize = width < 400 ? 14 : width < 640 ? 16 : 18;
        foreach (var bubble in new[] { Create(0, true, input), Create(1, false, output) }) {
            ((TextBlock)((StackPanel)bubble.Child).Children[1]).FontSize = fontSize;
            panel.Children.Add(bubble);
        }
        panel.Measure(new Size(Math.Max(1, width - 58), double.PositiveInfinity));
        var timer = new StackPanel();
        System.Windows.Documents.TextElement.SetFontFamily(timer, new FontFamily("Segoe UI"));
        timer.Children.Add(new TextBlock { Text = "Working time (HH:MM:SS)", FontSize = 11 });
        timer.Children.Add(new TextBlock { Text = "00:00:00", FontFamily = new FontFamily("Consolas"), FontSize = 30, Margin = new Thickness(0,6,0,0) });
        timer.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        return Math.Ceiling(32 + timer.DesiredSize.Height + 12 + panel.DesiredSize.Height);
    }
}
'@
}

function Get-DemoSummaryLayout([string]$InputText, [string]$OutputText, [double]$Width = 820,
    [double]$MaxWidth = ([Windows.SystemParameters]::WorkArea.Width - 32),
    [double]$MaxHeight = ([Windows.SystemParameters]::WorkArea.Height - 32)) {
    if ($MaxWidth -lt 280 -or $MaxHeight -lt 180) { throw 'The display work area is too small for summary playback.' }
    if ([string]::IsNullOrWhiteSpace($InputText)) { $InputText = 'Input summary unavailable.' }
    if ([string]::IsNullOrWhiteSpace($OutputText)) { $OutputText = 'Output summary missing. Generate or edit summaries before playback.' }
    $measuredWidth = [Math]::Min($MaxWidth, [Math]::Max(280, $Width))
    do {
        $height = [ReplayMessageFactory]::PairHeight($InputText, $OutputText, $measuredWidth)
        if ($height -le $MaxHeight) {
            return [pscustomobject]@{ Fits = $true; Width = $measuredWidth; Height = [Math]::Max(180, $height) }
        }

        if ($measuredWidth -ge $MaxWidth) { break }
        $measuredWidth = [Math]::Min($MaxWidth, $measuredWidth + 64)
    } while ($true)
    return [pscustomobject]@{ Fits = $false; Width = $measuredWidth; Height = $height }
}

function Get-DemoPlaybackInput($Recording, [int]$Index, [switch]$SourceOnly) {
    if (-not $SourceOnly -and $null -ne $Recording.promptSummaries -and $Recording.promptSummaries[$Index]) { return [string]$Recording.promptSummaries[$Index] }
    $text = ([string]$Recording.turns[$Index].snapshot.requests[0].message.text -replace '\s+', ' ').Trim()
    if ($text.Length -gt 300) { return $text.Substring(0, 297) + '...' }
    return $text
}

function Get-DemoSummaryWorkArea([Windows.Window]$Window) {
    if ($null -ne $Window) {
        $source = [Windows.PresentationSource]::FromVisual($Window)
        if ($null -ne $source -and $null -ne $source.CompositionTarget) {
            $screen = [Windows.Forms.Screen]::FromHandle([Windows.Interop.WindowInteropHelper]::new($Window).Handle).WorkingArea
            $transform = $source.CompositionTarget.TransformFromDevice
            $topLeft = $transform.Transform([Windows.Point]::new($screen.Left, $screen.Top))
            $bottomRight = $transform.Transform([Windows.Point]::new($screen.Right, $screen.Bottom))
            return [Windows.Rect]::new($topLeft, $bottomRight)
        }
    }
    return [Windows.SystemParameters]::WorkArea
}

function Assert-DemoSummaryPairs($Recording, [double]$Width, [double]$MaxWidth, [double]$MaxHeight) {
    for ($index = 0; $index -lt $Recording.turns.Count; $index++) {
        if ($null -ne $Recording.playbackIncluded -and -not $Recording.playbackIncluded[$index]) { continue }
        $outputText = if ($null -ne $Recording.outputSummaries) { [string]$Recording.outputSummaries[$index] } else { '' }
        $fit = Get-DemoSummaryLayout (Get-DemoPlaybackInput $Recording $index) $outputText $Width $MaxWidth $MaxHeight
        if (-not $fit.Fits) { throw "Exchange $($index + 1): shorten the prompt/reply summaries in Review / edit summaries. They cannot fit together on this screen without scrolling. No text was truncated." }
    }
}

if ($ValidateStdin) {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    $pairs = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd())
    foreach ($pair in $pairs) {
        $fit = Get-DemoSummaryLayout ([string]$pair.input) ([string]$pair.output)
        if (-not $fit.Fits) {
            throw "Exchange $($pair.exchange): shorten the prompt/reply summaries; the rendered pair cannot fit together on this screen without scrolling. No summaries were saved."
        }
    }
}
