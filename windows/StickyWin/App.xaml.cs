using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using H.NotifyIcon;
using Microsoft.Win32;

namespace StickyWin;

public partial class App : Application
{
    private const string NoDeviceMessage =
        "Open Sticky on your other computer and make sure both devices are on the same private Wi-Fi.";

    /// One process owns the tray icon, the UDP port and the drop widget. A second
    /// launch — which is what Send To and the Explorer context menu produce — hands
    /// its file list to the running one and exits.
    private const string InstanceMutexName = @"Local\StickyWin.SingleInstance";
    private const string InstancePipeName = "StickyWin.Instance";

    private TaskbarIcon? _tray;
    private DiscoveryService? _discovery;
    private TransferService? _transfer;
    private ClipboardService? _clipboard;
    private PairingService? _pairing;
    private DropWidgetWindow? _dropWidget;
    private Window? _clipboardWindow;
    private IArrivalNotifier? _notifier;
    private StickyUiSettings _settings = new();
    private Mutex? _instanceLock;
    private CancellationTokenSource? _pipeStop;
    private string _lastIncomingSender = "your Mac";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _instanceLock = new Mutex(true, InstanceMutexName, out bool isFirstInstance);
        if (!isFirstInstance)
        {
            ForwardToRunningInstance(e.Args);
            _instanceLock.Dispose();
            _instanceLock = null;
            Shutdown();
            return;
        }

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        _settings = StickyUiSettings.Load();

        // One PairingService, shared. A second instance would load its pins from
        // disk at construction and never see anything paired during this session,
        // which is the same as having no spoof guard at all.
        _pairing = new PairingService();
        string deviceId = Environment.MachineName.ToLowerInvariant();
        _discovery = new DiscoveryService(deviceId, Environment.MachineName, _pairing);
        _transfer = new TransferService(_discovery, _pairing);
        _clipboard = new ClipboardService();

        // Local copies are retained in Sticky's private history only. A user
        // explicitly chooses when to send an item; ordinary clipboard activity
        // must never leak to a nearby device.
        _clipboard.Start();

        // Receiving is already streamed and finalized by the transfer service.
        // Calling AcceptIncomingAsync here raced the uploader and could delete a
        // freshly prepared session before its first chunk arrived.
        _transfer.IncomingOffer += (senderName, _, _) => _lastIncomingSender = senderName;
        _transfer.IncomingCompleted += count => Dispatcher.BeginInvoke(() => AnnounceArrival(count));
        _transfer.StateChanged += (_, state) => Dispatcher.BeginInvoke(() => ShowTransferState(state));
        _transfer.ClipboardReceived += (text, senderName) => Dispatcher.BeginInvoke(() =>
        {
            _clipboard?.ReceiveRemote(text, senderName);
            _tray?.ShowNotification("Sticky", $"New private clipboard item from {senderName}");
        });
        _transfer.Failed += message => System.Diagnostics.Debug.WriteLine(message);
        _transfer.Start();

        _discovery.PeersChanged += () => Dispatcher.BeginInvoke(() => RefreshDropWidgetPeer());

        SetupTray();
        SetupDropWidget();

        if (_settings.SendToShortcut) TryWriteSendToShortcut();

        _pipeStop = new CancellationTokenSource();
        _ = ListenForForwardedArgsAsync(_pipeStop.Token);

        // Launched by Send To or the Explorer context menu with a file list.
        if (e.Args.Length > 0) _ = SendPathsFromShellAsync(e.Args);
    }

    private void SetupTray()
    {
        ContextMenu menu = new();
        MenuItem code = new() { Header = $"This PC's pairing code: {_transfer?.CurrentPin ?? "------"}", IsEnabled = false };
        MenuItem send = new() { Header = "Send files…" };
        send.Click += (_, _) => ChooseAndSendFiles();
        MenuItem sendFolder = new() { Header = "Send folder…" };
        sendFolder.Click += (_, _) => ChooseAndSendFolder();
        MenuItem clipboard = new() { Header = "Clipboard…" };
        clipboard.Click += (_, _) => OpenClipboardWindow();
        MenuItem received = new() { Header = "Open received files" };
        received.Click += (_, _) => OpenReceiveFolder();
        MenuItem dropWidget = new() { Header = "Show drop target", IsCheckable = true, IsChecked = _settings.DropWidget };
        dropWidget.Click += (_, _) => SetDropWidgetVisible(dropWidget.IsChecked == true);
        MenuItem sendTo = new() { Header = "Add to the Send To menu", IsCheckable = true, IsChecked = _settings.SendToShortcut };
        sendTo.Click += (_, _) => SetSendToShortcut(sendTo.IsChecked == true);
        MenuItem pair = new() { Header = "Pair a device…" };
        pair.Click += async (_, _) => await PairDeviceAsync();
        MenuItem forget = new() { Header = "Forget paired devices…" };
        forget.Click += (_, _) => ForgetPairedDevices();
        MenuItem quit = new() { Header = "Quit Sticky" };
        quit.Click += (_, _) => Shutdown();
        menu.Items.Add(code);
        menu.Items.Add(new Separator());
        menu.Items.Add(send);
        menu.Items.Add(sendFolder);
        menu.Items.Add(clipboard);
        menu.Items.Add(received);
        menu.Items.Add(new Separator());
        menu.Items.Add(dropWidget);
        menu.Items.Add(sendTo);
        menu.Items.Add(pair);
        menu.Items.Add(forget);
        menu.Items.Add(new Separator());
        menu.Items.Add(quit);
        menu.Opened += (_, _) =>
        {
            code.Header = $"This PC's pairing code: {_transfer?.CurrentPin ?? "------"}";
            // The code is on screen from this moment, so this is the moment
            // /api/v1/pair is allowed to entertain guesses. Without this call the
            // endpoint stays open to the LAN for the life of the process.
            _transfer?.BeginPairingWindow();
            dropWidget.IsChecked = _dropWidget?.IsVisible == true;
            sendTo.IsChecked = ShellShortcut.PointsAt(SendToLinkPath, Environment.ProcessPath);
        };

        _tray = new TaskbarIcon
        {
            ToolTipText = "Sticky — Mac ↔ PC Transfer",
            IconSource = Imaging.CreateBitmapSourceFromHIcon(
                System.Drawing.SystemIcons.Application.Handle,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions()),
            ContextMenu = menu
        };
        _tray.TrayMouseDoubleClick += (_, _) => ChooseAndSendFiles();
        // The balloon is the arrival notification's "Open Folder" action until the
        // Windows App SDK toast lands — see TrayArrivalNotifier.
        _tray.TrayBalloonTipClicked += (_, _) => OpenReceiveFolder();
        _tray.Visibility = Visibility.Visible;
        _notifier = new TrayArrivalNotifier(_tray);
    }

    // MARK: The drop widget (plan F-11)

    private void SetupDropWidget()
    {
        _dropWidget = new DropWidgetWindow();
        _dropWidget.FilesDropped += paths => _ = SendPathsFromShellAsync(paths);
        _dropWidget.OpenFolderRequested += OpenReceiveFolder;
        _dropWidget.DismissRequested += () => SetDropWidgetVisible(false);
        if (_settings.DropWidget) _dropWidget.Show();
        RefreshDropWidgetPeer();
    }

    private void SetDropWidgetVisible(bool visible)
    {
        _settings = _settings with { DropWidget = visible };
        _settings.Save();
        if (_dropWidget is null) return;
        if (visible)
        {
            _dropWidget.Show();
            _dropWidget.Reposition();
            RefreshDropWidgetPeer();
        }
        else
        {
            _dropWidget.Hide();
        }
    }

    private void RefreshDropWidgetPeer()
    {
        if (_dropWidget is null) return;
        StickyDevice? peer = _transfer?.DefaultTarget();
        _dropWidget.ShowIdle(peer is null ? "Looking for your Mac…" : $"Ready — {peer.Name}");
    }

    private void ShowTransferState(NotchState state)
    {
        int percent = (int)Math.Round(state.Progress * 100);
        if (_tray != null) _tray.ToolTipText = $"{state.Kind} {percent}% — {state.FileName ?? "Sticky"}";
        if (_dropWidget is null) return;

        switch (state.Kind)
        {
            case NotchStateKind.Sending:
                _dropWidget.ShowProgress("Sending", state.FileName ?? $"{state.FileCount} files", state.Progress);
                break;
            case NotchStateKind.Receiving:
                _dropWidget.ShowProgress("Receiving", state.FileName ?? $"{state.FileCount} files", state.Progress);
                break;
            case NotchStateKind.Success:
                _dropWidget.ShowResult("Done", state.Message ?? state.FileName ?? "Transfer complete");
                break;
            case NotchStateKind.Failure:
                _dropWidget.ShowResult("Failed", state.Message ?? "Transfer failed");
                break;
            default:
                RefreshDropWidgetPeer();
                break;
        }
    }

    // MARK: Arrival notification (plan F-12)

    private void AnnounceArrival(int count)
    {
        string sender = _lastIncomingSender;
        if (_notifier?.TryShow(sender, count, ReceiveFolder) != true)
        {
            _tray?.ShowNotification("Sticky", count == 1 ? "Received 1 file" : $"Received {count} files");
        }
        _dropWidget?.ShowResult(count == 1 ? "1 file arrived" : $"{count} files arrived", $"from {sender}");
    }

    private static string ReceiveFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "Sticky");

    private static void OpenReceiveFolder()
    {
        try
        {
            Directory.CreateDirectory(ReceiveFolder);
            Process.Start(new ProcessStartInfo(ReceiveFolder) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine(ex.Message);
        }
    }

    // MARK: Send To shortcut (plan F-11)

    private static string SendToLinkPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "Sticky.lnk");

    /// Idempotent: the shortcut is only written when it is missing or aimed at a
    /// different executable, so a normal launch touches nothing on disk.
    private static void TryWriteSendToShortcut()
    {
        try
        {
            string? target = Environment.ProcessPath;
            if (string.IsNullOrEmpty(target)) return;
            if (ShellShortcut.PointsAt(SendToLinkPath, target)) return;
            ShellShortcut.Write(SendToLinkPath, target, "Send to your Mac with Sticky");
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Send To shortcut: {ex.Message}");
        }
    }

    private void SetSendToShortcut(bool wanted)
    {
        _settings = _settings with { SendToShortcut = wanted };
        _settings.Save();
        if (wanted)
        {
            TryWriteSendToShortcut();
            return;
        }

        try
        {
            if (File.Exists(SendToLinkPath)) File.Delete(SendToLinkPath);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Couldn’t remove the Send To shortcut", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    // MARK: Second-launch argument forwarding

    private static void ForwardToRunningInstance(IReadOnlyList<string> args)
    {
        if (args.Count == 0) return;
        try
        {
            using NamedPipeClientStream client = new(
                ".", InstancePipeName, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            client.Connect(4000);
            using StreamWriter writer = new(client, new UTF8Encoding(false)) { AutoFlush = true };
            foreach (string argument in args) writer.WriteLine(argument);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Forwarding to the running instance failed: {ex.Message}");
        }
    }

    private async Task ListenForForwardedArgsAsync(CancellationToken stopping)
    {
        while (!stopping.IsCancellationRequested)
        {
            try
            {
                using NamedPipeServerStream server = new(
                    InstancePipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(stopping);
                using StreamReader reader = new(server, new UTF8Encoding(false));
                string body = await reader.ReadToEndAsync(stopping);
                string[] paths = body.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
                if (paths.Length == 0) continue;
                await Dispatcher.InvokeAsync(() => { _ = SendPathsFromShellAsync(paths); });
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"Instance pipe: {ex.Message}");
            }
        }
    }

    /// The one path every shell affordance funnels through: the drop widget, the
    /// Send To shortcut and the Explorer context menu.
    private async Task SendPathsFromShellAsync(IReadOnlyList<string> paths)
    {
        string[] existing = paths
            .Where(path => !string.IsNullOrWhiteSpace(path) && (File.Exists(path) || Directory.Exists(path)))
            .ToArray();
        if (existing.Length == 0) return;

        // A cold launch from Send To has not heard an announce yet, so give
        // discovery a moment rather than reporting a device that is really there
        // as missing.
        StickyDevice? peer = await WaitForPeerAsync(TimeSpan.FromSeconds(8));
        if (peer is null)
        {
            MessageBox.Show(NoDeviceMessage, "No device nearby", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        await SendFilesAsync(existing, peer);
    }

    private async Task<StickyDevice?> WaitForPeerAsync(TimeSpan timeout)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow + timeout;
        while (true)
        {
            if (_transfer?.DefaultTarget() is { } peer) return peer;
            if (DateTimeOffset.UtcNow >= deadline) return null;
            await Task.Delay(250);
        }
    }

    // MARK: Menu actions

    private void ChooseAndSendFiles()
    {
        if (_transfer?.DefaultTarget() is not { } peer)
        {
            MessageBox.Show(NoDeviceMessage, "No device nearby", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        Microsoft.Win32.OpenFileDialog dialog = new() { Title = $"Send to {peer.Name}", Multiselect = true };
        if (dialog.ShowDialog() == true) _ = SendFilesAsync(dialog.FileNames, peer);
    }

    private void ChooseAndSendFolder()
    {
        if (_transfer?.DefaultTarget() is not { } peer)
        {
            MessageBox.Show(NoDeviceMessage, "No device nearby", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        Microsoft.Win32.OpenFolderDialog dialog = new() { Title = $"Send a folder to {peer.Name}" };
        if (dialog.ShowDialog() == true && !string.IsNullOrEmpty(dialog.FolderName)) _ = SendFilesAsync([dialog.FolderName], peer);
    }

    // MARK: The private clipboard window

    private void OpenClipboardWindow()
    {
        if (_clipboard is not { } clipboard) return;
        if (_clipboardWindow is not null)
        {
            _clipboardWindow.Activate();
            return;
        }

        Window window = new()
        {
            Title = "Sticky Clipboard", Width = 520, Height = 560,
            WindowStartupLocation = WindowStartupLocation.CenterScreen
        };
        DockPanel root = new() { Margin = new Thickness(18) };

        TextBlock explanation = new()
        {
            Text = "Sticky's clipboard is separate from the Windows clipboard. Nothing moves between them unless you ask.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 10),
            Opacity = 0.75
        };

        ListBox history = new() { DisplayMemberPath = nameof(StickyClipItem.Row), MinHeight = 220 };
        void Refresh()
        {
            object? selected = history.SelectedItem;
            history.ItemsSource = clipboard.Items.ToList();
            if (selected is StickyClipItem previous)
                history.SelectedItem = clipboard.Items.FirstOrDefault(item => item.Id == previous.Id);
        }
        Refresh();
        clipboard.Changed += Refresh;

        StackPanel inbound = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        Button take = new() { Content = "Take from Windows clipboard", Margin = new Thickness(0, 0, 8, 0) };
        take.Click += (_, _) =>
        {
            if (clipboard.TakeFromSystemClipboard() is null)
                MessageBox.Show(clipboard.LastError ?? "Nothing on the clipboard that Sticky can hold.", "Sticky Clipboard", MessageBoxButton.OK, MessageBoxImage.Information);
        };
        Button copy = new() { Content = "Copy to Windows clipboard", Margin = new Thickness(0, 0, 8, 0) };
        copy.Click += (_, _) =>
        {
            if (history.SelectedItem is not StickyClipItem item) return;
            if (!clipboard.CopyToSystemClipboard(item))
                MessageBox.Show(clipboard.LastError ?? "Windows would not accept that clip.", "Sticky Clipboard", MessageBoxButton.OK, MessageBoxImage.Warning);
        };
        Button send = new() { Content = "Send selected" };
        send.Click += async (_, _) =>
        {
            if (history.SelectedItem is not StickyClipItem item || _transfer is not { } transfer) return;
            if (transfer.DefaultTarget() is not { } peer)
            {
                MessageBox.Show(NoDeviceMessage, "No device nearby", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            if (clipboard.SendPayload(item) is not { } payload)
            {
                MessageBox.Show(clipboard.LastError ?? "That clip can no longer be sent.", "Couldn’t send", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            try
            {
                switch (payload)
                {
                    case StickyClipSendPayload.Text text:
                        await transfer.SendClipboardAsync(text.Value, peer);
                        break;
                    case StickyClipSendPayload.Files files:
                        await transfer.SendFilesAsync(files.Paths, peer);
                        break;
                }
                _tray?.ShowNotification("Sticky", "Clipboard item sent");
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Couldn’t send", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
        inbound.Children.Add(take);
        inbound.Children.Add(copy);
        inbound.Children.Add(send);

        StackPanel manage = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 10) };
        Button pin = new() { Content = "Pin / unpin", Margin = new Thickness(0, 0, 8, 0) };
        pin.Click += (_, _) => { if (history.SelectedItem is StickyClipItem item) clipboard.TogglePin(item); };
        Button delete = new() { Content = "Delete", Margin = new Thickness(0, 0, 8, 0) };
        delete.Click += (_, _) => { if (history.SelectedItem is StickyClipItem item) clipboard.Delete(item); };
        Button clear = new() { Content = "Clear history" };
        clear.Click += (_, _) =>
        {
            if (MessageBox.Show("Clear every clip, pinned ones included?", "Clear Sticky clipboard", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
                clipboard.ClearHistory();
        };
        manage.Children.Add(pin);
        manage.Children.Add(delete);
        manage.Children.Add(clear);

        TextBox input = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 70 };
        Button save = new() { Content = "Add to Sticky clipboard", Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
        save.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(input.Text)) return;
            clipboard.WriteSticky(input.Text);
            input.Clear();
        };

        DockPanel.SetDock(explanation, Dock.Top);
        DockPanel.SetDock(inbound, Dock.Bottom);
        DockPanel.SetDock(manage, Dock.Bottom);
        DockPanel.SetDock(input, Dock.Bottom);
        DockPanel.SetDock(save, Dock.Bottom);
        root.Children.Add(explanation);
        root.Children.Add(inbound);
        root.Children.Add(manage);
        root.Children.Add(save);
        root.Children.Add(input);
        root.Children.Add(history);
        window.Content = root;
        window.Closed += (_, _) =>
        {
            clipboard.Changed -= Refresh;
            _clipboardWindow = null;
        };
        _clipboardWindow = window;
        window.Show();
    }

    // MARK: Transfers

    private async Task SendFilesAsync(IReadOnlyList<string> paths, StickyDevice peer)
    {
        try
        {
            await (_transfer?.SendFilesAsync(paths, peer) ?? Task.CompletedTask);
            _tray?.ShowNotification("Sticky", "Sent");
        }
        catch (Exception ex)
        {
            _dropWidget?.ShowResult("Failed", ex.Message);
            MessageBox.Show(ex.Message, "Couldn’t send", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async Task PairDeviceAsync()
    {
        if (_transfer is not { } transfer || transfer.DefaultTarget() is not { } peer)
        {
            MessageBox.Show(NoDeviceMessage, "No device nearby", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        string? code = PromptForPairingCode(peer);
        if (code is null) return;
        try
        {
            await transfer.PairAsync(peer, code);
            _tray?.ShowNotification("Sticky", $"Paired with {peer.Name}");
            RefreshDropWidgetPeer();
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Couldn’t pair", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static string? PromptForPairingCode(StickyDevice peer)
    {
        Window dialog = new()
        {
            Title = $"Pair with {peer.Name}", Width = 370, Height = 210,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false
        };
        StackPanel panel = new() { Margin = new Thickness(24) };
        panel.Children.Add(new TextBlock { Text = "Enter the six-digit code shown in Sticky on the other computer.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 14) });
        TextBox field = new() { MaxLength = 6, FontSize = 22, HorizontalContentAlignment = HorizontalAlignment.Center };
        field.PreviewTextInput += (_, e) => e.Handled = e.Text.Any(character => !char.IsAsciiDigit(character));
        panel.Children.Add(field);
        StackPanel buttons = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        Button cancel = new() { Content = "Cancel", MinWidth = 80, IsCancel = true, Margin = new Thickness(0, 0, 8, 0) };
        Button confirm = new() { Content = "Pair", MinWidth = 80, IsDefault = true };
        cancel.Click += (_, _) => dialog.DialogResult = false;
        confirm.Click += (_, _) => dialog.DialogResult = true;
        buttons.Children.Add(cancel);
        buttons.Children.Add(confirm);
        panel.Children.Add(buttons);
        dialog.Content = panel;
        return dialog.ShowDialog() == true ? field.Text.Trim() : null;
    }

    private void ForgetPairedDevices()
    {
        if (_transfer is null) return;
        if (MessageBox.Show("Forget every paired device? You’ll need to pair again before sending.", "Forget paired devices", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        _transfer.UnpairAll();
        _transfer.EndPairingWindow();
        _tray?.ShowNotification("Sticky", "Paired devices forgotten");
        RefreshDropWidgetPeer();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _pipeStop?.Cancel();
        _pipeStop?.Dispose();
        _dropWidget?.Close();
        _tray?.Dispose();
        _clipboard?.Stop();
        _transfer?.Dispose();
        _discovery?.Dispose();
        _pairing?.Dispose();
        _instanceLock?.Dispose();
        base.OnExit(e);
    }
}

// MARK: - The drop widget

/// Plan §6 and §15.5: a small always-on-top borderless HWND with AllowDrop, sat
/// bottom-centre above the taskbar. You cannot drop files onto a Windows tray
/// icon — the notification area is a bitmap strip owned by explorer.exe, not an
/// HWND that can register a drop target — so this window is the Windows analogue
/// of the notch and the primary send gesture.
///
/// Permanently visible rather than appears-on-drag: catching a drag before the
/// drop needs a low-level mouse hook, which is complexity and antivirus
/// suspicion for a discoverability gain a small permanent tab already buys.
internal sealed class DropWidgetWindow : Window
{
    private const int GwlExStyle = -20;
    private const int WsExNoActivate = 0x08000000;
    private const int WsExToolWindow = 0x00000080;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr window, int index, int value);

    private static readonly Brush IdleFill = new SolidColorBrush(Color.FromArgb(0xF2, 0x1C, 0x1C, 0x1E));
    private static readonly Brush ArmedFill = new SolidColorBrush(Color.FromArgb(0xFA, 0x2E, 0x2A, 0x22));
    private static readonly Brush IdleEdge = new SolidColorBrush(Color.FromArgb(0x38, 0xFF, 0xFF, 0xFF));
    private static readonly Brush ArmedEdge = new SolidColorBrush(Color.FromRgb(0xFF, 0xC1, 0x66));
    private static readonly Brush Amber = new SolidColorBrush(Color.FromRgb(0xFF, 0xC1, 0x66));
    private static readonly Brush Muted = new SolidColorBrush(Color.FromRgb(0x9A, 0x9A, 0xA2));

    private readonly Border _frame;
    private readonly TextBlock _title;
    private readonly TextBlock _detail;
    private readonly ProgressBar _progress;
    private readonly DispatcherTimer _reset;

    private string _idleTitle = "Drop files to send";
    private string _idleDetail = "Looking for your Mac…";

    public event Action<string[]>? FilesDropped;
    public event Action? DismissRequested;
    public event Action? OpenFolderRequested;

    public DropWidgetWindow()
    {
        Title = "Sticky";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        AllowDrop = true;
        Focusable = false;
        Width = 224;
        Height = 68;

        _title = new TextBlock
        {
            Text = _idleTitle,
            Foreground = Brushes.White,
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            MaxWidth = 160,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        _detail = new TextBlock
        {
            Text = _idleDetail,
            Foreground = Muted,
            FontSize = 11,
            MaxWidth = 160,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        _progress = new ProgressBar
        {
            Height = 3,
            Width = 160,
            Minimum = 0,
            Maximum = 1,
            Value = 0,
            Margin = new Thickness(0, 5, 0, 0),
            BorderThickness = new Thickness(0),
            Foreground = Amber,
            Background = new SolidColorBrush(Color.FromArgb(0x30, 0xFF, 0xFF, 0xFF)),
            Visibility = Visibility.Collapsed,
            HorizontalAlignment = HorizontalAlignment.Left
        };

        StackPanel text = new();
        text.Children.Add(_title);
        text.Children.Add(_detail);
        text.Children.Add(_progress);

        StackPanel row = new() { Orientation = Orientation.Horizontal };
        row.Children.Add(new TextBlock
        {
            Text = "⇧",
            Foreground = Amber,
            FontSize = 20,
            Margin = new Thickness(0, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Center
        });
        row.Children.Add(text);

        _frame = new Border
        {
            Background = IdleFill,
            BorderBrush = IdleEdge,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(13, 8, 13, 8),
            AllowDrop = true,
            Child = row
        };
        Content = _frame;

        System.Windows.Controls.ContextMenu menu = new();
        MenuItem open = new() { Header = "Open received files" };
        open.Click += (_, _) => OpenFolderRequested?.Invoke();
        MenuItem hide = new() { Header = "Hide drop target" };
        hide.Click += (_, _) => DismissRequested?.Invoke();
        menu.Items.Add(open);
        menu.Items.Add(hide);
        ContextMenu = menu;

        _reset = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _reset.Tick += (_, _) =>
        {
            _reset.Stop();
            _title.Text = _idleTitle;
            _detail.Text = _idleDetail;
            _progress.Visibility = Visibility.Collapsed;
        };

        SourceInitialized += OnSourceInitialized;
        DragOver += OnDragOver;
        DragLeave += OnDragLeave;
        Drop += OnDrop;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
    }

    /// WS_EX_NOACTIVATE keeps the widget from ever taking focus from what the
    /// user is actually doing; WS_EX_TOOLWINDOW keeps it out of Alt-Tab. Neither
    /// affects the OLE drop target, which is registered on the HWND regardless.
    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        IntPtr handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        int style = GetWindowLong(handle, GwlExStyle);
        SetWindowLong(handle, GwlExStyle, style | WsExNoActivate | WsExToolWindow);
        Reposition();
    }

    /// WorkArea already excludes the taskbar, so "above the taskbar" is just its
    /// bottom edge less a hair of breathing room.
    public void Reposition()
    {
        Rect work = SystemParameters.WorkArea;
        Left = work.Left + Math.Max(0, (work.Width - Width) / 2);
        Top = work.Bottom - Height - 8;
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(() => Reposition());

    private void OnDragOver(object sender, DragEventArgs e)
    {
        bool acceptable = e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effects = acceptable ? DragDropEffects.Copy : DragDropEffects.None;
        Arm(acceptable);
        e.Handled = true;
    }

    private void OnDragLeave(object sender, DragEventArgs e)
    {
        Arm(false);
        e.Handled = true;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        Arm(false);
        e.Handled = true;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths || paths.Length == 0) return;
        ShowProgress("Preparing", paths.Length == 1 ? Path.GetFileName(paths[0]) : $"{paths.Length} items", 0);
        FilesDropped?.Invoke(paths);
    }

    private void Arm(bool armed)
    {
        _frame.Background = armed ? ArmedFill : IdleFill;
        _frame.BorderBrush = armed ? ArmedEdge : IdleEdge;
    }

    public void ShowIdle(string detail)
    {
        _idleDetail = detail;
        if (_reset.IsEnabled) return;
        _title.Text = _idleTitle;
        _detail.Text = detail;
        _progress.Visibility = Visibility.Collapsed;
    }

    public void ShowProgress(string title, string detail, double progress)
    {
        _reset.Stop();
        _title.Text = title;
        _detail.Text = detail;
        _progress.Value = Math.Clamp(progress, 0, 1);
        _progress.Visibility = Visibility.Visible;
    }

    public void ShowResult(string title, string detail)
    {
        _title.Text = title;
        _detail.Text = detail;
        _progress.Visibility = Visibility.Collapsed;
        _reset.Stop();
        _reset.Start();
    }

    protected override void OnClosed(EventArgs e)
    {
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        _reset.Stop();
        base.OnClosed(e);
    }
}

// MARK: - Arrival notification

internal interface IArrivalNotifier
{
    bool TryShow(string senderName, int count, string folderPath);
}

/// The tray balloon. Windows renders it as an ordinary notification and files it
/// in Action Center, and App wires TrayBalloonTipClicked to reveal the receive
/// folder — the "Open Folder" affordance without a new dependency.
///
/// TODO (owner of StickyWin.csproj): plan §6 prefers Microsoft.Windows.AppNotifications,
/// which needs a package this project does not reference:
///
///   &lt;PackageReference Include="Microsoft.WindowsAppSDK" Version="1.6.*" /&gt;
///   &lt;WindowsPackageType&gt;None&lt;/WindowsPackageType&gt;   (unpackaged app)
///   &lt;WindowsSdkPackageVersion&gt;10.0.19041.x&lt;/WindowsSdkPackageVersion&gt; if the
///   build complains about the Windows SDK projection version.
///
/// With that referenced, add a sibling class implementing this interface that
/// calls AppNotificationManager.Default.Register() once at startup (Register now
/// does the COM registration for unpackaged apps, so no AppUserModelID or
/// Start-menu shortcut dance), builds the toast with AppNotificationBuilder,
/// adds an AppNotificationButton("Open Folder") carrying the folder path as an
/// argument, and handles AppNotificationManager.Default.NotificationInvoked.
/// Prefer it in App.SetupTray and fall back to this class when Register throws —
/// notifications do not work from elevated processes, and Sticky must keep
/// running as a standard user.
internal sealed class TrayArrivalNotifier(TaskbarIcon tray) : IArrivalNotifier
{
    public bool TryShow(string senderName, int count, string folderPath)
    {
        try
        {
            string body = count == 1
                ? $"1 file from {senderName} — click to open the folder"
                : $"{count} files from {senderName} — click to open the folder";
            tray.ShowNotification("Sticky", body);
            return true;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Arrival notification: {ex.Message} ({folderPath})");
            return false;
        }
    }
}

// MARK: - Send To shortcut

/// A .lnk written through the shell's own IShellLink. No admin rights, no
/// registry writes, and the same twenty-year-old Windows UX every other app
/// uses for Send To.
internal static class ShellShortcut
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLinkCoClass
    {
    }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int maxPath, IntPtr findData, int flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int maxName);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int maxPath);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int maxArguments);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCommand);
        void SetShowCmd(int showCommand);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int iconPathLength, out int iconIndex);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, int reserved);
        void Resolve(IntPtr window, int flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    [ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFile
    {
        void GetClassID(out Guid classId);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string fileName, int mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string? fileName, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string fileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string fileName);
    }

    /// Send To passes the selected paths as arguments to the shortcut's target,
    /// so the .lnk carries no arguments of its own.
    public static void Write(string linkPath, string targetPath, string description)
    {
        string? directory = Path.GetDirectoryName(linkPath);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);

        // The RCW is left to the garbage collector: Marshal.ReleaseComObject and
        // FinalReleaseComObject throw PlatformNotSupportedException on .NET 5 and later.
        IShellLinkW link = (IShellLinkW)new ShellLinkCoClass();
        link.SetPath(targetPath);
        string? workingDirectory = Path.GetDirectoryName(targetPath);
        if (!string.IsNullOrEmpty(workingDirectory)) link.SetWorkingDirectory(workingDirectory);
        link.SetDescription(description);
        link.SetIconLocation(targetPath, 0);
        ((IPersistFile)link).Save(linkPath, true);
    }

    public static string? ReadTarget(string linkPath)
    {
        if (!File.Exists(linkPath)) return null;
        try
        {
            IShellLinkW link = (IShellLinkW)new ShellLinkCoClass();
            ((IPersistFile)link).Load(linkPath, 0);
            StringBuilder buffer = new(1024);
            link.GetPath(buffer, buffer.Capacity, IntPtr.Zero, 0);
            string path = buffer.ToString();
            return path.Length == 0 ? null : path;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static bool PointsAt(string linkPath, string? targetPath)
    {
        if (string.IsNullOrEmpty(targetPath)) return false;
        try
        {
            return string.Equals(ReadTarget(linkPath), targetPath, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return false;
        }
    }
}

// MARK: - Windows-only UI preferences

/// Which of the Windows affordances the user has switched off. Deliberately not
/// in the registry: nothing here needs to survive an uninstall, and a plain file
/// under LOCALAPPDATA is one less thing an antivirus heuristic can misread.
internal sealed record StickyUiSettings
{
    [JsonPropertyName("dropWidget")]
    public bool DropWidget { get; init; } = true;

    [JsonPropertyName("sendToShortcut")]
    public bool SendToShortcut { get; init; } = true;

    private static string StorePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sticky", "windows-ui.json");

    public static StickyUiSettings Load()
    {
        try
        {
            if (!File.Exists(StorePath)) return new StickyUiSettings();
            return JsonSerializer.Deserialize<StickyUiSettings>(File.ReadAllText(StorePath)) ?? new StickyUiSettings();
        }
        catch (Exception)
        {
            return new StickyUiSettings();
        }
    }

    public void Save()
    {
        try
        {
            string? directory = Path.GetDirectoryName(StorePath);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            File.WriteAllText(StorePath, JsonSerializer.Serialize(this));
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"UI settings: {ex.Message}");
        }
    }
}
