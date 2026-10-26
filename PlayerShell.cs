using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace VibeReplay {
    public sealed class ControllerWindow : Window {
        private readonly StackPanel body = new StackPanel();
        private readonly StackPanel tools = new StackPanel();
        private readonly ScrollViewer scroll;
        private readonly Button miniPlay = new Button();
        private readonly Button miniNext = new Button();
        private readonly Button miniStop = new Button();
        private readonly StackPanel miniControls = new StackPanel { Orientation = Orientation.Horizontal };
        private readonly Expander presentation;
        private readonly Expander preparation;
        private bool mini;
        private bool recording;
        private double expandedLeft;
        private double expandedTop;
        private bool hiddenForCapture;
        private readonly ContextMenu trayMenu;
        private readonly System.Windows.Forms.NotifyIcon tray;
        private static readonly Brush Ink = Brush("#DEEAE4");
        private static readonly Brush Muted = Brush("#9EB3A8");
        private static readonly Brush Mint = Brush("#A0E6C4");

        public ControllerWindow() {
            NameScope.SetNameScope(this, new NameScope());
            Title = "VibeReplay - Demo Player";
            Width = 280;
            SizeToContent = SizeToContent.Height;
            ResizeMode = ResizeMode.NoResize;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            FontFamily = new FontFamily("Segoe UI");
            FontSize = 11;
            Foreground = Ink;
            Topmost = true;
            ShowActivated = false;
            WindowStartupLocation = WindowStartupLocation.Manual;
            Resources.Add(typeof(Button), ButtonStyle());
            Resources.Add(typeof(CheckBox), CheckStyle());
            var chrome = new Border {
                Background = Brush("#1F2D2D"), BorderBrush = Brush("#40554D"),
                BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(13),
                SnapsToDevicePixels = true, ClipToBounds = true
            };
            Content = chrome;
            var root = new StackPanel();
            chrome.Child = root;
            var header = new Grid { Height = 46, Margin = new Thickness(11, 0, 7, 0) };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var title = new TextBlock { Text = "\u25B6\u25B6  VibeReplay.", FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Foreground = Mint };
            header.Children.Add(title);
            header.MouseLeftButtonDown += (sender, args) => {
                if (args.OriginalSource is TextBlock || args.OriginalSource == header) DragMove();
            };
            var headerButtons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(headerButtons, 1);
            header.Children.Add(headerButtons);
            miniControls.Visibility = Visibility.Collapsed;
            headerButtons.Children.Add(miniControls);
            MiniButton(miniPlay, "\u25B6", "PlayPause", "Play or pause");
            MiniButton(miniNext, "\u25B7", "NextStep", "Next exchange");
            MiniButton(miniStop, "\u25A1", "Stop", "Stop playback");
            var shrink = new Button { Content = "\u2014", Width = 23, Height = 25, ToolTip = "Collapse or expand controller" };
            Register("CompactMode", shrink);
            shrink.Click += (sender, args) => SetMini(!mini);
            headerButtons.Children.Add(shrink);
            var menuButton = new Button { Content = "\u22EF", Width = 23, Height = 25, ToolTip = "Window and recording controls" };
            Register("WindowActions", menuButton);
            trayMenu = new ContextMenu();
            var pin = new MenuItem { Header = "Always on top", IsCheckable = true, IsChecked = true };
            pin.Click += (sender, args) => Topmost = pin.IsChecked;
            trayMenu.Items.Add(pin);
            var hide = new MenuItem { Header = "Hide controller for recording" };
            hide.Click += (sender, args) => HideForCapture();
            trayMenu.Items.Add(hide);
            var restore = new MenuItem { Header = "Restore controller" };
            restore.Click += (sender, args) => RestoreFromCapture();
            trayMenu.Items.Add(restore);
            var exit = new MenuItem { Header = "Exit VibeReplay" };
            exit.Click += (sender, args) => Close();
            trayMenu.Items.Add(exit);
            menuButton.Click += (sender, args) => { trayMenu.PlacementTarget = menuButton; trayMenu.IsOpen = true; };
            headerButtons.Children.Add(menuButton);
            root.Children.Add(header);
            scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
            root.Children.Add(scroll);
            var main = new StackPanel { Margin = new Thickness(14, 0, 14, 3) };
            body.Children.Add(main);
            var choose = Button("ChooseDemo", "Find an interaction...", "Choose a saved demo or capture a conversation");
            choose.HorizontalContentAlignment = HorizontalAlignment.Left;
            choose.Padding = new Thickness(0, 4, 0, 8);
            choose.FontWeight = FontWeights.SemiBold;
            choose.MaxWidth = 250;
            main.Children.Add(choose);
            var status = Register("Status", new TextBlock { Text = "Find an interaction to replay", Foreground = Muted, FontSize = 10, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 1, 0, 5) });
            main.Children.Add(status);
            var transport = new Grid();
            transport.ColumnDefinitions.Add(new ColumnDefinition());
            transport.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(37) });
            transport.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(37) });
            var play = Button("PlayPause", "", "Open");
            play.IsEnabled = false;
            play.Background = Mint;
            play.Foreground = Brush("#18392A");
            play.FontWeight = FontWeights.SemiBold;
            play.Height = 34;
            play.Margin = new Thickness(0, 0, 6, 0);
            var playContent = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
            playContent.Children.Add(Register("PlayIcon", new TextBlock { Text = "\uE8A7", FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center }));
            playContent.Children.Add(Register("PrimaryLabel", new TextBlock { Text = "Open", Margin = new Thickness(7, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center }));
            play.Content = playContent;
            transport.Children.Add(play);
            var next = Button("NextStep", "\u25B7", "Next Step");
            next.Height = 34;
            next.IsEnabled = false;
            next.Margin = new Thickness(0, 0, 5, 0);
            Grid.SetColumn(next, 1);
            transport.Children.Add(next);
            var stop = Button("Stop", "\u25A1", "Stop playback");
            stop.Height = 34;
            Grid.SetColumn(stop, 2);
            transport.Children.Add(stop);
            Register("ExitLabel", new TextBlock { Text = "Exit", Visibility = Visibility.Collapsed });
            main.Children.Add(transport);
            main.Children.Add(Register("PlaybackProgress", new ProgressBar { Minimum = 0, Maximum = 100, Height = 2, Foreground = Mint, Background = Brush("#2A3C36"), Margin = new Thickness(0, 12, 0, 0) }));
            main.Children.Add(Register("RunEstimate", new TextBlock { Text = "Select an interaction", FontSize = 9, Foreground = Muted, Margin = new Thickness(0, 5, 0, 0), TextWrapping = TextWrapping.Wrap }));
            tools.Margin = new Thickness(10, 0, 10, 4);
            body.Children.Add(tools);
            presentation = new Expander { Header = "Presentation", Foreground = Muted, FontSize = 10 };
            Register("PresentationOptions", presentation);
            var presentationBody = new StackPanel { Margin = new Thickness(4, 9, 4, 6) };
            presentationBody.Children.Add(Check("AutoContinue", "Auto continue", true));
            presentationBody.Children.Add(Check("ShowPrompt", "Show prompt summary", false));
            presentationBody.Children.Add(Check("ShowElapsed", "Show recorded working time", false));
            presentationBody.Children.Add(Check("ShowOutput", "Show input and output summaries", false));
            var frame = new DockPanel { Margin = new Thickness(0, 5, 0, 9) };
            var color = Button("FrameColor", "", "Overlay frame color: #F5B82E");
            color.Width = 38;
            color.Content = Register("FrameColorSwatch", new Border { Width = 25, Height = 14, CornerRadius = new CornerRadius(2), Background = Brush("#F5B82E") });
            DockPanel.SetDock(color, Dock.Right);
            frame.Children.Add(color);
            frame.Children.Add(new TextBlock { Text = "Overlay frame", VerticalAlignment = VerticalAlignment.Center });
            presentationBody.Children.Add(frame);
            var mode = Register("WindowMode", new ComboBox { Margin = new Thickness(0, 0, 0, 8), ToolTip = "Agents mode is experimental and retains its existing sign-in and compatibility requirements." });
            mode.Items.Add(new ComboBoxItem { Tag = "Editor", Content = "VS Code" });
            mode.Items.Add(new ComboBoxItem { Tag = "Agents", Content = "Agents (experimental)" });
            presentationBody.Children.Add(mode);
            presentationBody.Children.Add(Register("SpeedLabel", new TextBlock { Text = "Speed: user 2.0s / reply 5.0s", FontSize = 10 }));
            presentationBody.Children.Add(Register("PlaybackSpeed", new Slider { Minimum = 0, Maximum = 100, TickFrequency = 1, IsSnapToTickEnabled = true, Margin = new Thickness(0, 7, 0, 7) }));
            presentationBody.Children.Add(new TextBlock { Text = "Summary language", FontSize = 10, Margin = new Thickness(0, 4, 0, 4) });
            var summaryLanguage = Register("SummaryLanguage", new ComboBox { DisplayMemberPath = "label", SelectedValuePath = "value", IsEnabled = false });
            AutomationProperties.SetAutomationId(summaryLanguage, "SummaryDisplayLanguage");
            presentationBody.Children.Add(summaryLanguage);
            presentation.Content = presentationBody;
            tools.Children.Add(presentation);
            preparation = new Expander { Header = "Prepare & settings", Foreground = Muted, FontSize = 10, Margin = new Thickness(0, 5, 0, 0) };
            Register("PreparationOptions", preparation);
            var prepareBody = new StackPanel { Margin = new Thickness(4, 9, 4, 0) };
            prepareBody.Children.Add(Button("SelectExchanges", "Select exchanges...", "Edit included exchanges and summaries"));
            prepareBody.Children.Add(Button("GeneratePromptSummaries", "Generate AI prompt summaries (0/0)", "Generate only missing input summaries, with consent and review"));
            prepareBody.Children.Add(Button("GenerateOutputSummaries", "Generate AI output summaries (0/0)", "Generate only missing output summaries, with consent and review"));
            prepareBody.Children.Add(Button("TranslateSummaries", "Translate summaries...", "Translate saved summaries with consent and review"));
            prepareBody.Children.Add(Button("AISettings", "Settings", "OpenAI model and protected key settings"));
            prepareBody.Children.Add(Button("CheckUpdates", "Check for updates", "Check for an in-product update"));
            prepareBody.Children.Add(Register("UpdateNotice", new TextBlock { Foreground = Muted, FontSize = 10, TextWrapping = TextWrapping.Wrap }));
            preparation.Content = prepareBody;
            tools.Children.Add(preparation);
            var activity = new StackPanel { Margin = new Thickness(14, 0, 14, 10), Visibility = Visibility.Collapsed };
            Register("OperationPanel", activity);
            activity.Children.Add(Register("LibraryActivity", new TextBlock { Foreground = Muted, FontSize = 10, TextWrapping = TextWrapping.Wrap }));
            activity.Children.Add(new ProgressBar { Height = 2, IsIndeterminate = true, Foreground = Mint, Margin = new Thickness(0, 6, 0, 6) });
            activity.Children.Add(Button("CancelLibraryOperation", "Cancel operation", "Request cancellation; success is not assumed"));
            body.Children.Add(activity);
            play.Click += (sender, args) => { presentation.IsExpanded = false; preparation.IsExpanded = false; };
            BindMini(miniPlay, play);
            var miniIcon = new TextBlock { FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 11 };
            miniIcon.SetBinding(TextBlock.TextProperty, new System.Windows.Data.Binding("Text") { Source = FindName("PlayIcon") });
            miniPlay.Content = miniIcon;
            BindMini(miniNext, next);
            BindMini(miniStop, stop);
            tray = new System.Windows.Forms.NotifyIcon {
                Text = "VibeReplay - restore controller",
                Icon = System.Drawing.SystemIcons.Application, Visible = false
            };
            tray.DoubleClick += (sender, args) => Dispatcher.BeginInvoke(new Action(RestoreFromCapture));
            var trayActions = new System.Windows.Forms.ContextMenuStrip();
            trayActions.Items.Add("Restore VibeReplay", null, (sender, args) => Dispatcher.BeginInvoke(new Action(RestoreFromCapture)));
            trayActions.Items.Add("Exit VibeReplay", null, (sender, args) => Dispatcher.BeginInvoke(new Action(Close)));
            tray.ContextMenuStrip = trayActions;
            Closed += (sender, args) => { tray.Dispose(); trayActions.Dispose(); };
            SizeChanged += (sender, args) => ConstrainToScreen();
            Loaded += (sender, args) => ConstrainToScreen();
        }

        public void SetMini(bool value) {
            mini = value;
            body.Visibility = mini ? Visibility.Collapsed : Visibility.Visible;
            miniControls.Visibility = mini ? Visibility.Visible : Visibility.Collapsed;
            ((Button)FindName("CompactMode")).ToolTip = mini ? "Expand controller" : "Collapse to mini controller";
            if (mini) { presentation.IsExpanded = false; preparation.IsExpanded = false; }
        }

        public void SetRecording(bool value) {
            if (recording == value) return;
            recording = value;
            if (value) { presentation.IsExpanded = false; preparation.IsExpanded = false; }
        }

        public void HideForCapture() {
            if (hiddenForCapture) return;
            expandedLeft = Left; expandedTop = Top;
            hiddenForCapture = true;
            tray.Visible = true;
            Hide();
            tray.ShowBalloonTip(2500, "VibeReplay is hidden", "Double-click the notification-area icon to restore the controller. Playback continues.", System.Windows.Forms.ToolTipIcon.Info);
        }

        public void RestoreFromCapture() {
            if (!hiddenForCapture) return;
            hiddenForCapture = false;
            Left = expandedLeft; Top = expandedTop;
            Show(); Activate();
            tray.Visible = false;
        }

        private void ConstrainToScreen() {
            if (!IsLoaded || !IsVisible) return;
            var screen = System.Windows.Forms.Screen.FromHandle(new System.Windows.Interop.WindowInteropHelper(this).Handle).WorkingArea;
            var source = PresentationSource.FromVisual(this);
            if (source == null || source.CompositionTarget == null) return;
            var transform = source.CompositionTarget.TransformFromDevice;
            var topLeft = transform.Transform(new Point(screen.Left, screen.Top));
            var bottomRight = transform.Transform(new Point(screen.Right, screen.Bottom));
            MaxHeight = Math.Max(100, bottomRight.Y - topLeft.Y - 16);
            scroll.MaxHeight = Math.Max(50, MaxHeight - 48);
            Left = Math.Max(topLeft.X + 8, Math.Min(Left, bottomRight.X - ActualWidth - 8));
            Top = Math.Max(topLeft.Y + 8, Math.Min(Top, bottomRight.Y - ActualHeight - 8));
        }

        private void MiniButton(Button button, string text, string target, string label) {
            button.Content = text; button.Width = 22; button.Height = 25; button.Padding = new Thickness(0); button.ToolTip = label;
            AutomationProperties.SetAutomationId(button, "Mini" + target);
            AutomationProperties.SetName(button, label);
            miniControls.Children.Add(button);
        }

        private static void BindMini(Button button, Button target) {
            button.SetBinding(IsEnabledProperty, new System.Windows.Data.Binding("IsEnabled") { Source = target });
            button.Click += (sender, args) => target.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        }

        private T Register<T>(string name, T control) where T : FrameworkElement {
            control.Name = name;
            RegisterName(name, control);
            AutomationProperties.SetAutomationId(control, name);
            return control;
        }

        private Button Button(string name, string content, string label) {
            var button = Register(name, new Button { Content = content, ToolTip = label, Margin = new Thickness(0, 2, 0, 2), MinHeight = 27, Padding = new Thickness(8, 5, 8, 5) });
            if (content.Length > 1) {
                button.SetBinding(AutomationProperties.NameProperty, new System.Windows.Data.Binding("Content") { Source = button });
            } else {
                AutomationProperties.SetName(button, label);
            }
            return button;
        }

        private CheckBox Check(string name, string content, bool enabled) {
            return Register(name, new CheckBox { Content = content, IsEnabled = enabled, Margin = new Thickness(0, 4, 0, 6), VerticalContentAlignment = VerticalAlignment.Center });
        }

        private static Brush Brush(string value) {
            var brush = (SolidColorBrush)new BrushConverter().ConvertFromString(value);
            brush.Freeze();
            return brush;
        }

        private static Style ButtonStyle() {
            var style = new Style(typeof(Button));
            style.Setters.Add(new Setter(BackgroundProperty, Brush("#2A3C36")));
            style.Setters.Add(new Setter(ForegroundProperty, Ink));
            style.Setters.Add(new Setter(BorderBrushProperty, Brush("#40554D")));
            style.Setters.Add(new Setter(BorderThicknessProperty, new Thickness(1)));
            style.Setters.Add(new Setter(CursorProperty, Cursors.Hand));
            style.Setters.Add(new Setter(FontSizeProperty, 10.0));
            var template = new ControlTemplate(typeof(Button));
            var border = new FrameworkElementFactory(typeof(Border));
            border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
            border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(BackgroundProperty));
            border.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(BorderBrushProperty));
            border.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(BorderThicknessProperty));
            var content = new FrameworkElementFactory(typeof(ContentPresenter));
            content.SetValue(ContentPresenter.HorizontalAlignmentProperty, new TemplateBindingExtension(HorizontalContentAlignmentProperty));
            content.SetValue(ContentPresenter.VerticalAlignmentProperty, VerticalAlignment.Center);
            content.SetValue(ContentPresenter.MarginProperty, new TemplateBindingExtension(PaddingProperty));
            border.AppendChild(content); template.VisualTree = border;
            style.Setters.Add(new Setter(TemplateProperty, template));
            style.Setters.Add(new Setter(HorizontalContentAlignmentProperty, HorizontalAlignment.Center));
            var disabled = new Trigger { Property = IsEnabledProperty, Value = false };
            disabled.Setters.Add(new Setter(OpacityProperty, 0.38));
            style.Triggers.Add(disabled);
            var hover = new Trigger { Property = IsMouseOverProperty, Value = true };
            hover.Setters.Add(new Setter(OpacityProperty, 0.8));
            style.Triggers.Add(hover);
            return style;
        }

        private static Style CheckStyle() {
            var style = new Style(typeof(CheckBox));
            style.Setters.Add(new Setter(ForegroundProperty, Ink));
            style.Setters.Add(new Setter(FontSizeProperty, 10.0));
            return style;
        }
    }

    public sealed class LibraryConnection : IDisposable {
        private readonly Process process;
        private readonly SemaphoreSlim gate = new SemaphoreSlim(1, 1);
        private readonly Task<string> errors;
        private bool disposed;
        private long sequence;

        public LibraryConnection(string node, string script, string root) {
            var start = new ProcessStartInfo {
                FileName = node, Arguments = "\"" + script + "\"",
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            start.EnvironmentVariables["VIBEREPLAY_LIBRARY_ROOT"] = root;
            process = Process.Start(start);
            if (process == null) throw new InvalidOperationException("The VibeReplay library worker could not start.");
            errors = process.StandardError.ReadToEndAsync();
        }

        public string Request(string json, CancellationToken cancellation) {
                gate.Wait(cancellation);
                try {
                    if (disposed || process.HasExited) throw new InvalidOperationException("The VibeReplay library worker is unavailable. Refresh before retrying; no success was confirmed.");
                    long requestId = Interlocked.Increment(ref sequence);
                    string envelope = "{\"id\":" + requestId + ",\"request\":" + json + "}";
                    var bytes = new UTF8Encoding(false).GetBytes(envelope + "\n");
                    var write = process.StandardInput.BaseStream.WriteAsync(bytes, 0, bytes.Length, cancellation);
                    Await(write, cancellation);
                    Await(process.StandardInput.BaseStream.FlushAsync(cancellation), cancellation);
                    var read = process.StandardOutput.ReadLineAsync();
                    Await(read, cancellation);
                    if (read.Result == null) throw new InvalidOperationException("The VibeReplay library worker exited without a response. No success was confirmed. " + (errors.IsCompleted ? errors.Result : ""));
                    var packet = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 1024 }.DeserializeObject(read.Result) as Dictionary<string, object>;
                    if (packet == null || !packet.ContainsKey("version") || Convert.ToInt32(packet["version"]) != 1 ||
                        !packet.ContainsKey("id") || Convert.ToInt64(packet["id"]) != requestId ||
                        !packet.ContainsKey("ok") || !(packet["ok"] is bool)) {
                        throw new InvalidDataException("The library worker returned a mismatched protocol response. No success was confirmed.");
                    }
                    return read.Result;
                } catch (OperationCanceledException) {
                    Abort();
                    throw new OperationCanceledException("Library operation cancelled. No success was confirmed. Refresh before retrying.");
                } catch {
                    Abort();
                    throw;
                } finally { gate.Release(); }
        }

        private static void Await(Task task, CancellationToken token) {
            if (!task.IsCompleted) {
                int ready = WaitHandle.WaitAny(new[] { ((IAsyncResult)task).AsyncWaitHandle, token.WaitHandle });
                if (ready == 1) token.ThrowIfCancellationRequested();
            }
            task.GetAwaiter().GetResult();
        }

        private void Abort() {
            disposed = true;
            if (!process.HasExited) process.Kill();
            if (!process.WaitForExit(2000)) throw new IOException("The VibeReplay library worker did not exit after cancellation.");
        }

        public bool IsAlive { get { return !disposed && !process.HasExited; } }
        public int ProcessId { get { return process.Id; } }
        public void Dispose() {
            gate.Wait();
            try {
                if (!disposed) Abort();
                process.Dispose();
            } finally { gate.Release(); }
        }
    }

    public static class LibraryConnections {
        private static readonly object Sync = new object();
        private static LibraryConnection connection;
        private static string identity;
        public static LibraryConnection Get(string node, string script, string root) {
            string next = node + "|" + script + "|" + root;
            lock (Sync) {
                if (connection != null && (identity != next || !connection.IsAlive)) { connection.Dispose(); connection = null; }
                if (connection == null) { connection = new LibraryConnection(node, script, root); identity = next; }
                return connection;
            }
        }
        public static void Close() {
            lock (Sync) {
                if (connection != null) { connection.Dispose(); connection = null; }
            }
        }
    }
}
