using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using H.NotifyIcon;
using Microsoft.Win32;

namespace StickyWin;

public partial class App : Application
{
    /// Every "we can't see your Mac" message says the same three things, because
    /// on a home network the answer is almost always the third one.
    internal const string NoDeviceMessage =
        "Sticky can't see your Mac on this network yet.\n\n" +
        "• Open Sticky on the Mac and leave it running.\n" +
        "• Put both computers on the same Wi-Fi.\n" +
        "• In Windows Settings → Network, make sure this network is set to Private. " +
        "On a Public network Windows blocks the discovery messages the two apps use to find each other.";

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
    private PairingWindow? _pairingWindow;
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

        // Before anything draws: the single accent every surface tints with is the
        // user's own Windows accent, exactly as the Mac takes NSColor.controlAccentColor.
        StickyTheme.ApplyAccentTokens(Resources, StickyTheme.SystemAccent());
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

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

        // Arms the pairing gate in its CLOSED position. TransferService only
        // refuses /api/v1/pair guesses once it has been told a pairing window
        // exists at all; previously that happened the first time the tray menu
        // opened, so a user who never opened the menu ran with the endpoint
        // permanently answering. Saying "closed" up front is strictly tighter —
        // PairingWindow is now the only thing that opens it.
        _transfer.EndPairingWindow();

        _discovery.PeersChanged += () => Dispatcher.BeginInvoke(() => RefreshPeerPresentation());

        SetupTray();
        SetupDropWidget();

        if (_settings.SendToShortcut) TryWriteSendToShortcut();

        _pipeStop = new CancellationTokenSource();
        _ = ListenForForwardedArgsAsync(_pipeStop.Token);

        // Launched by Send To or the Explorer context menu with a file list.
        if (e.Args.Length > 0) _ = SendPathsFromShellAsync(e.Args);

        ShowFirstRunIfNeeded();
    }

    /// First run is the only moment Sticky opens a window on its own. Everything
    /// the owner needs to pair — this PC's name, this PC's code, the Mac's name
    /// once it appears, and a field for the Mac's code — is in that one window,
    /// so pairing is never a thing you have to go looking for in a menu.
    private void ShowFirstRunIfNeeded()
    {
        if (_settings.FirstRunDone) return;
        _settings = _settings with { FirstRunDone = true };
        _settings.Save();

        // ApplicationIdle so the tray icon and the drop widget are already on
        // screen behind the window — the point of first run is to show the user
        // where Sticky lives, not to appear over an empty desktop.
        Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() =>
        {
            _tray?.ShowNotification("Sticky is running", "Look for the Sticky tab at the bottom of your screen, and its icon near the clock.");
            OpenPairingWindow();
        }));
    }

    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category is not (UserPreferenceCategory.General or UserPreferenceCategory.Color or UserPreferenceCategory.VisualStyle)) return;
        Dispatcher.BeginInvoke(() =>
        {
            StickyTheme.ApplyAccentTokens(Resources, StickyTheme.SystemAccent());
            _dropWidget?.ReadAccent();
        });
    }

    private void SetupTray()
    {
        ContextMenu menu = new();

        // The menu opens with a sentence, not a setting: what Sticky can see right
        // now. "Ready · Michael's MacBook Pro" is the only reassurance the app
        // ever needs to give, and "Found … — not paired yet" is the one piece of
        // bad news that has an obvious next click directly under it.
        MenuItem status = new() { Header = $"Sticky — {StatusLine()}", IsEnabled = false };
        MenuItem pair = new() { Header = "Pair with your Mac…", FontWeight = FontWeights.SemiBold };
        pair.Click += (_, _) => OpenPairingWindow();
        MenuItem send = new() { Header = "Send files…" };
        send.Click += (_, _) => ChooseAndSendFiles();
        MenuItem sendFolder = new() { Header = "Send a folder…" };
        sendFolder.Click += (_, _) => ChooseAndSendFolder();
        MenuItem clipboard = new() { Header = "Private clipboard…" };
        clipboard.Click += (_, _) => OpenClipboardWindow();
        MenuItem received = new() { Header = "Open received files" };
        received.Click += (_, _) => OpenReceiveFolder();
        MenuItem dropWidget = new() { Header = "Show the drop tab", IsCheckable = true, IsChecked = _settings.DropWidget };
        dropWidget.Click += (_, _) => SetDropWidgetVisible(dropWidget.IsChecked == true);
        MenuItem sendTo = new() { Header = "Add Sticky to the Send To menu", IsCheckable = true, IsChecked = _settings.SendToShortcut };
        sendTo.Click += (_, _) => SetSendToShortcut(sendTo.IsChecked == true);
        MenuItem forget = new() { Header = "Forget paired devices…" };
        forget.Click += (_, _) => ForgetPairedDevices();
        MenuItem quit = new() { Header = "Quit Sticky" };
        quit.Click += (_, _) => Shutdown();

        menu.Items.Add(status);
        menu.Items.Add(pair);
        menu.Items.Add(new Separator());
        menu.Items.Add(send);
        menu.Items.Add(sendFolder);
        menu.Items.Add(clipboard);
        menu.Items.Add(received);
        menu.Items.Add(new Separator());
        menu.Items.Add(dropWidget);
        menu.Items.Add(sendTo);
        menu.Items.Add(new Separator());
        menu.Items.Add(forget);
        menu.Items.Add(quit);

        menu.Opened += (_, _) =>
        {
            status.Header = $"Sticky — {StatusLine()}";
            // Already paired? Then this is housekeeping, not a first step, and it
            // should stop shouting.
            bool paired = IsDefaultPeerPaired();
            pair.Header = paired ? "Pairing code and devices…" : "Pair with your Mac…";
            pair.FontWeight = paired ? FontWeights.Normal : FontWeights.SemiBold;
            dropWidget.IsChecked = _settings.DropWidget;
            sendTo.IsChecked = ShellShortcut.PointsAt(SendToLinkPath, Environment.ProcessPath);
        };

        _tray = new TaskbarIcon
        {
            ToolTipText = $"Sticky — {StatusLine()}",
            IconSource = StickyTheme.BuildTrayIcon(),
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
        _dropWidget.PairRequested += OpenPairingWindow;
        _dropWidget.DismissRequested += () => SetDropWidgetVisible(false);
        if (_settings.DropWidget) _dropWidget.Reveal();
        RefreshPeerPresentation();
    }

    private void SetDropWidgetVisible(bool visible)
    {
        _settings = _settings with { DropWidget = visible };
        _settings.Save();
        if (_dropWidget is null) return;
        if (visible)
        {
            _dropWidget.Reveal();
            RefreshPeerPresentation();
        }
        else
        {
            _dropWidget.Dismiss();
        }
    }

    // MARK: What Sticky can see, said once and reused everywhere

    private StickyDevice? DefaultPeer() => _transfer?.DefaultTarget();

    private bool IsDefaultPeerPaired()
    {
        StickyDevice? peer = DefaultPeer();
        return peer is not null && _pairing?.IsPeerPaired(peer.Id) == true;
    }

    private string PeerName() => DefaultPeer()?.Name ?? "your Mac";

    private string StatusLine()
    {
        StickyDevice? peer = DefaultPeer();
        if (peer is null) return "looking for your Mac…";
        return _pairing?.IsPeerPaired(peer.Id) == true
            ? $"ready · {peer.Name}"
            : $"found {peer.Name} — not paired yet";
    }

    /// One place decides what the idle pill and the tray tooltip say, so they can
    /// never disagree about whether the Mac is there.
    private void RefreshPeerPresentation()
    {
        SetTrayTooltip(null);
        if (_dropWidget is null) return;

        StickyDevice? peer = DefaultPeer();
        if (peer is null)
        {
            _dropWidget.ShowIdle("Looking for your Mac…", DropWidgetAction.Pair);
            _dropWidget.DropDetail = "Sticky is still looking for your Mac";
            return;
        }
        if (_pairing?.IsPeerPaired(peer.Id) != true)
        {
            _dropWidget.ShowIdle($"Pair with {peer.Name} first", DropWidgetAction.Pair);
            _dropWidget.DropDetail = $"Pair with {peer.Name} before sending";
            return;
        }
        _dropWidget.ShowIdle($"Ready · {peer.Name}", DropWidgetAction.OpenFolder);
        _dropWidget.DropDetail = $"to {peer.Name}";
    }

    private void SetTrayTooltip(string? detail)
    {
        if (_tray is null) return;
        // The tray tooltip is capped at 127 characters by the shell.
        string text = detail is null ? $"Sticky — {StatusLine()}" : $"Sticky — {detail}";
        _tray.ToolTipText = text.Length <= 127 ? text : text[..127];
    }

    private void ShowTransferState(NotchState state)
    {
        int percent = Math.Clamp((int)Math.Round(state.Progress * 100), 0, 100);
        string? name = state.FileName is { Length: > 0 } path ? Path.GetFileName(path) : null;
        if (string.IsNullOrEmpty(name)) name = state.FileCount > 1 ? $"{state.FileCount} files" : null;

        switch (state.Kind)
        {
            case NotchStateKind.Sending:
                SetTrayTooltip($"sending {percent}% — {name ?? "files"}");
                _dropWidget?.ShowProgress(name ?? "Sending", $"To {PeerName()} · {percent}%", state.Progress, outgoing: true);
                break;
            case NotchStateKind.Receiving:
                SetTrayTooltip($"receiving {percent}% — {name ?? "files"}");
                _dropWidget?.ShowProgress(name ?? "Receiving", $"From {_lastIncomingSender} · {percent}%", state.Progress, outgoing: false);
                break;
            case NotchStateKind.Success:
                SetTrayTooltip(null);
                _dropWidget?.ShowResult("Done", state.Message ?? name ?? "Transfer complete", success: true);
                break;
            case NotchStateKind.Failure:
                SetTrayTooltip(null);
                // The transfer service already words its failures for a person;
                // it never reaches here with a raw exception string.
                _dropWidget?.ShowResult("Transfer stopped", state.Message ?? "Sticky lost the connection to your Mac.", success: false);
                break;
            default:
                RefreshPeerPresentation();
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
        _dropWidget?.ShowResult(
            count == 1 ? "1 file arrived" : $"{count} files arrived",
            $"From {sender} · in Downloads\\Sticky",
            success: true);
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
            MessageBox.Show(
                $"Sticky couldn't open {ReceiveFolder}.\n\n{ex.Message}",
                "Couldn't open the received files folder", MessageBoxButton.OK, MessageBoxImage.Warning);
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
            MessageBox.Show(
                $"Sticky couldn't remove its Send To shortcut.\n\n{ex.Message}\n\nYou can delete it yourself: press Windows+R, type shell:sendto, and delete Sticky.",
                "Couldn't remove the Send To shortcut", MessageBoxButton.OK, MessageBoxImage.Warning);
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
            _dropWidget?.ShowResult("No Mac found", "Sticky can't see your Mac on this network", success: false);
            MessageBox.Show(NoDeviceMessage, "Sticky can't see your Mac", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (_pairing?.IsPeerPaired(peer.Id) != true)
        {
            _dropWidget?.ShowResult("Not paired yet", $"Pair with {peer.Name} first", success: false);
            OfferPairing(peer);
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

    /// The peer every send needs: present, and pinned. Returning null is never
    /// silent — the user is told which of the two is missing and offered the one
    /// click that fixes it.
    private StickyDevice? RequireReadyPeer()
    {
        StickyDevice? peer = DefaultPeer();
        if (peer is null)
        {
            MessageBox.Show(NoDeviceMessage, "Sticky can't see your Mac", MessageBoxButton.OK, MessageBoxImage.Information);
            return null;
        }
        if (_pairing?.IsPeerPaired(peer.Id) != true)
        {
            OfferPairing(peer);
            return null;
        }
        return peer;
    }

    private void OfferPairing(StickyDevice peer)
    {
        MessageBoxResult answer = MessageBox.Show(
            $"Sticky found {peer.Name}, but this PC and that Mac haven't been paired yet. " +
            "Pairing is a one-time six-digit code, and nothing can be sent until it's done.\n\nPair them now?",
            "Pair before sending", MessageBoxButton.OKCancel, MessageBoxImage.Information);
        if (answer == MessageBoxResult.OK) OpenPairingWindow();
    }

    // MARK: Menu actions

    private void ChooseAndSendFiles()
    {
        if (RequireReadyPeer() is not { } peer) return;
        Microsoft.Win32.OpenFileDialog dialog = new() { Title = $"Send to {peer.Name}", Multiselect = true };
        if (dialog.ShowDialog() == true) _ = SendFilesAsync(dialog.FileNames, peer);
    }

    private void ChooseAndSendFolder()
    {
        if (RequireReadyPeer() is not { } peer) return;
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
            if (RequireReadyPeer() is not { } peer) return;
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
                _tray?.ShowNotification("Sticky", $"Clipboard item sent to {peer.Name}");
            }
            catch (Exception ex)
            {
                MessageBox.Show(ExplainSendError(ex), "Sticky couldn’t send that clip", MessageBoxButton.OK, MessageBoxImage.Warning);
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
            // The transfer service never publishes a Success state for an
            // outgoing send — without this the pill sat at 100% for ever and the
            // user had no way to tell a finished send from a stalled one.
            _dropWidget?.ShowResult("Sent", $"{DescribeSelection(paths)} → {peer.Name}", success: true);
            _tray?.ShowNotification("Sticky", $"Sent to {peer.Name}");
        }
        catch (Exception ex)
        {
            string explanation = ExplainSendError(ex);
            _dropWidget?.ShowResult("Couldn’t send", FirstLine(explanation), success: false);
            MessageBox.Show(explanation, "Sticky couldn’t send that", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static string DescribeSelection(IReadOnlyList<string> paths)
    {
        if (paths.Count != 1) return $"{paths.Count} items";
        string name = Path.GetFileName(paths[0].TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        return string.IsNullOrEmpty(name) ? "1 item" : name;
    }

    /// The pill has one line to work with; the message box has the whole story.
    private static string FirstLine(string message)
    {
        int stop = message.IndexOfAny(['\n', '\r']);
        string line = stop < 0 ? message : message[..stop];
        return line.Length <= 64 ? line : line[..63] + "…";
    }

    // MARK: Saying what went wrong, and what to do about it
    //
    // Plan §4.2 on the Mac: a failure names a specific reason, never "Something
    // went wrong." The Windows half owes the same, and owes one more thing —
    // every message below ends with the action that fixes it.

    /// Retries are wrapped in an InvalidOperationException whose message reads
    /// "upload x failed after retries", which tells a person nothing. The cause
    /// underneath is the interesting one.
    private static Exception Unwrap(Exception error) =>
        error is InvalidOperationException { InnerException: { } inner } ? inner : error;

    internal static string ExplainPairError(Exception error) => Unwrap(error) switch
    {
        ArgumentException =>
            "Enter all six digits of the code your Mac is showing.",
        UnauthorizedAccessException =>
            "Your Mac didn't accept that code.\n\nCodes change every few minutes — read the current one off the Mac and type it again. " +
            "After five wrong tries Sticky pauses pairing for a while, so check the digits before pressing Pair.",
        SecurityException =>
            "Sticky couldn't confirm that computer is really your Mac, so it stopped rather than trust it.\n\n" +
            "Make sure you're on your own network, that nobody else nearby is running Sticky, and try again. " +
            "If you reinstalled Sticky on the Mac, choose Forget paired devices here first.",
        SocketException or IOException or TimeoutException =>
            "Your Mac didn't answer.\n\nCheck that Sticky is open on it, that both computers are awake, and that they're on the same Wi-Fi.",
        _ =>
            $"Pairing didn't finish.\n\n{Unwrap(error).Message}\n\nTry again, and if it keeps failing restart Sticky on both computers."
    };

    internal static string ExplainSendError(Exception error) => Unwrap(error) switch
    {
        UnauthorizedAccessException =>
            "This PC and your Mac aren't paired yet, so your Mac refused the files.\n\n" +
            "Open Pair with your Mac from the Sticky icon near the clock and enter the six-digit code.",
        SecurityException =>
            "Your Mac's identity has changed since you paired with it, so Sticky stopped the transfer.\n\n" +
            "If you reinstalled Sticky on the Mac, choose Forget paired devices here and pair again. If you didn't, do not send anything until you know why.",
        SocketException or IOException or TimeoutException =>
            "Sticky lost the connection to your Mac part-way through.\n\n" +
            "Check both computers are awake and still on the same Wi-Fi, then send again. Nothing partial is left on the Mac.",
        OperationCanceledException =>
            "The transfer was stopped before it finished. Nothing partial is left on your Mac.",
        _ =>
            $"The transfer didn't finish.\n\n{Unwrap(error).Message}"
    };

    // MARK: Pairing

    private void OpenPairingWindow()
    {
        if (_transfer is not { } transfer || _discovery is not { } discovery || _pairing is not { } pairing) return;

        if (_pairingWindow is not null)
        {
            if (_pairingWindow.WindowState == WindowState.Minimized) _pairingWindow.WindowState = WindowState.Normal;
            _pairingWindow.Activate();
            return;
        }

        PairingWindow window = new(transfer, discovery, pairing);
        window.PairingChanged += () => Dispatcher.BeginInvoke(() => RefreshPeerPresentation());
        window.Closed += (_, _) => _pairingWindow = null;
        _pairingWindow = window;
        window.Show();
        window.Activate();
    }

    private void ForgetPairedDevices()
    {
        if (_transfer is null) return;
        if (MessageBox.Show(
                "Forget every paired device?\n\nSticky will refuse to send or receive until you pair again with a fresh six-digit code.",
                "Forget paired devices", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        _transfer.UnpairAll();
        _transfer.EndPairingWindow();
        _tray?.ShowNotification("Sticky", "Paired devices forgotten — pair again before sending");
        RefreshPeerPresentation();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        _pipeStop?.Cancel();
        _pipeStop?.Dispose();
        _pairingWindow?.Close();
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

// MARK: - The token reader
//
/// The Windows counterpart to DS in DesignSystem.swift: nothing in this file
/// carries a colour, a radius or a duration of its own, it asks here, and here
/// asks App.xaml. The two things App.xaml cannot express — WPF easing functions
/// and the accent read out of the OS — live here as well.
internal static class StickyTheme
{
    /// Only used when SystemParameters.WindowGlassColor gives nothing usable —
    /// a fresh Windows install with no accent chosen, or a remote session.
    private static readonly Color FallbackAccent = Color.FromRgb(0x4C, 0xA6, 0xFF);

    /// The pill is a near-black surface. An accent darker than this disappears on
    /// it, and plenty of people pick a very dark accent, so a too-dark one is
    /// lifted rather than used as chosen. Relative luminance, 0…1.
    private const double MinimumAccentLuminance = 0.30;

    // Motion. Asymmetric on purpose, mirroring DS.Motion: opening overshoots a
    // little, closing does not bounce at all.
    internal static readonly IEasingFunction OpenEase = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.26 };
    internal static readonly IEasingFunction CloseEase = new CubicEase { EasingMode = EasingMode.EaseIn };
    internal static readonly IEasingFunction TintEase = new QuadraticEase { EasingMode = EasingMode.EaseOut };
    internal static readonly IEasingFunction SettleEase = new CubicEase { EasingMode = EasingMode.EaseOut };
    internal static readonly IEasingFunction PopEase = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.42 };

    /// "Show animations in Windows" — Settings → Accessibility → Visual effects.
    /// When it is off, every animation in Sticky becomes an assignment. Geometry,
    /// wording and timing of the STATE do not change, only the transition, which
    /// is the same contract Reduce Motion gets on the Mac.
    internal static bool Animates => SystemParameters.ClientAreaAnimation;

    internal static SolidColorBrush FindBrush(string key) => (SolidColorBrush)Application.Current.FindResource(key);
    internal static Color FindColor(string key) => (Color)Application.Current.FindResource(key);
    internal static CornerRadius FindRadius(string key) => (CornerRadius)Application.Current.FindResource(key);
    internal static Duration FindDuration(string key) => (Duration)Application.Current.FindResource(key);
    internal static TimeSpan FindDwell(string key)
    {
        Duration duration = FindDuration(key);
        return duration.HasTimeSpan ? duration.TimeSpan : TimeSpan.FromSeconds(2);
    }

    internal static Style FindStyle(string key) => (Style)Application.Current.FindResource(key);

    internal static Color SystemAccent()
    {
        try
        {
            Color glass = SystemParameters.WindowGlassColor;
            if (glass.R + glass.G + glass.B == 0) return FallbackAccent;
            return Readable(Color.FromRgb(glass.R, glass.G, glass.B));
        }
        catch (Exception)
        {
            return FallbackAccent;
        }
    }

    private static Color Readable(Color color)
    {
        double luminance = (0.2126 * color.R + 0.7152 * color.G + 0.0722 * color.B) / 255.0;
        if (luminance >= MinimumAccentLuminance) return color;
        if (luminance <= 0.001) return FallbackAccent;
        double lift = Math.Min(MinimumAccentLuminance / luminance, 5.0);
        return Color.FromRgb(Lift(color.R, lift), Lift(color.G, lift), Lift(color.B, lift));
    }

    private static byte Lift(byte channel, double factor) => (byte)Math.Clamp(channel * factor, 0.0, 255.0);

    internal static Color Blend(Color baseColor, Color tint, double amount) => Color.FromArgb(
        baseColor.A,
        (byte)Math.Clamp(baseColor.R + (tint.R - baseColor.R) * amount, 0.0, 255.0),
        (byte)Math.Clamp(baseColor.G + (tint.G - baseColor.G) * amount, 0.0, 255.0),
        (byte)Math.Clamp(baseColor.B + (tint.B - baseColor.B) * amount, 0.0, 255.0));

    /// Rewrites every accent-derived key in App.xaml. Called before the first
    /// window is built and again whenever the user changes their accent, so the
    /// literals in App.xaml are never what actually ships on screen.
    internal static void ApplyAccentTokens(ResourceDictionary resources, Color accent)
    {
        Color surface = (Color)resources["Sticky.Color.Surface"];

        resources["Sticky.Color.Accent"] = accent;
        resources["Sticky.Brush.Accent"] = new SolidColorBrush(accent);

        // A tint, not a fill: 16% of the accent washed into the surface is enough
        // to read as "this is armed" without turning the pill into a coloured
        // rectangle.
        resources["Sticky.Color.SurfaceDrag"] = Blend(surface, accent, 0.16);
        resources["Sticky.Color.EdgeDrag"] = Color.FromArgb(0xE6, accent.R, accent.G, accent.B);
        resources["Sticky.Color.EdgeBusy"] = Color.FromArgb(0x66, accent.R, accent.G, accent.B);
    }

    /// A tray icon Sticky can be found by. The shell draws tray icons small and
    /// monochrome, so this is one white glyph on nothing — no rounded square,
    /// which at 16 px would be a grey smudge on a dark taskbar.
    internal static ImageSource BuildTrayIcon()
    {
        try
        {
            const double side = 32;
            DrawingVisual visual = new();
            using (DrawingContext context = visual.RenderOpen())
            {
                // A transparent hit rectangle so the glyph is measured against a
                // known box rather than against nothing.
                context.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, side, side));
                FormattedText glyph = new(
                    DropWidgetWindow.IdleGlyph,
                    CultureInfo.InvariantCulture,
                    FlowDirection.LeftToRight,
                    new Typeface(new FontFamily("Segoe UI Symbol, Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal),
                    26,
                    Brushes.White,
                    1.0);
                context.DrawText(glyph, new Point((side - glyph.Width) / 2, (side - glyph.Height) / 2));
            }

            RenderTargetBitmap bitmap = new((int)side, (int)side, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            bitmap.Freeze();
            return bitmap;
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Tray icon: {ex.Message}");
            return Imaging.CreateBitmapSourceFromHIcon(
                System.Drawing.SystemIcons.Application.Handle,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
        }
    }

    // MARK: Animation, with the OS setting honoured in one place

    internal static void AnimateDouble(IAnimatable target, DependencyProperty property, double to, Duration duration, IEasingFunction? easing)
    {
        if (!Animates)
        {
            Assign(target, property, to);
            return;
        }
        DoubleAnimation animation = new(to, duration) { EasingFunction = easing, FillBehavior = FillBehavior.HoldEnd };
        target.BeginAnimation(property, animation);
    }

    internal static void AnimateDouble(IAnimatable target, DependencyProperty property, double from, double to, Duration duration, IEasingFunction? easing)
    {
        if (!Animates)
        {
            Assign(target, property, to);
            return;
        }
        DoubleAnimation animation = new(from, to, duration) { EasingFunction = easing, FillBehavior = FillBehavior.HoldEnd };
        target.BeginAnimation(property, animation);
    }

    internal static void AnimateColor(SolidColorBrush brush, Color to, Duration duration, IEasingFunction? easing)
    {
        if (!Animates)
        {
            brush.BeginAnimation(SolidColorBrush.ColorProperty, null);
            brush.Color = to;
            return;
        }
        ColorAnimation animation = new(to, duration) { EasingFunction = easing, FillBehavior = FillBehavior.HoldEnd };
        brush.BeginAnimation(SolidColorBrush.ColorProperty, animation);
    }

    /// A resolution should settle, not snap: a short bright beat, then a long
    /// easing back to rest. One key-framed animation rather than a flash plus a
    /// timer, so an interrupting state change simply replaces it.
    internal static void SettleColor(SolidColorBrush brush, Color beat, Color rest, Duration duration, double beatAt)
    {
        if (!Animates)
        {
            brush.BeginAnimation(SolidColorBrush.ColorProperty, null);
            brush.Color = rest;
            return;
        }
        ColorAnimationUsingKeyFrames settle = new() { Duration = duration, FillBehavior = FillBehavior.HoldEnd };
        settle.KeyFrames.Add(new EasingColorKeyFrame(beat, KeyTime.FromPercent(beatAt), TintEase));
        settle.KeyFrames.Add(new EasingColorKeyFrame(rest, KeyTime.FromPercent(1.0), SettleEase));
        brush.BeginAnimation(SolidColorBrush.ColorProperty, settle);
    }

    private static void Assign(IAnimatable target, DependencyProperty property, double value)
    {
        target.BeginAnimation(property, null);
        ((DependencyObject)target).SetValue(property, value);
    }
}

// MARK: - The drop widget

/// What the trailing control on the pill does when it is clicked. There is only
/// ever one control and it is only ever the next useful thing: pair, or open the
/// folder the files landed in.
internal enum DropWidgetAction
{
    Pair,
    OpenFolder
}

/// Plan §6 and §15.5: a small always-on-top borderless HWND with AllowDrop, sat
/// bottom-centre above the taskbar. You cannot drop files onto a Windows tray
/// icon — the notification area is a bitmap strip owned by explorer.exe, not an
/// HWND that can register a drop target — so this window is the Windows analogue
/// of the notch and the primary send gesture.
///
/// Permanently visible rather than appears-on-drag: catching a drag before the
/// drop needs a low-level mouse hook, which is complexity and antivirus
/// suspicion for a discoverability gain a small permanent tab already buys.
///
/// It speaks the notch's compact-pill vocabulary (NotchView.swift): a glyph tile,
/// two lines of micro-copy — what this is, and what it is doing — and one small
/// trailing control. Every state is that same shape, so the pill never relayouts
/// as it moves from idle to armed to sending to done.
internal sealed class DropWidgetWindow : Window
{
    private const int GwlExStyle = -20;
    private const int WsExNoActivate = 0x08000000;
    private const int WsExToolWindow = 0x00000080;

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static extern int GetWindowLong(IntPtr window, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static extern int SetWindowLong(IntPtr window, int index, int value);

    // MARK: Metrics
    //
    // Colours, radii and durations are tokens; these are the pill's proportions,
    // which have no counterpart on the Mac because the notch takes its size from
    // the hardware.

    private const double FrameWidth = 272;
    private const double FrameHeight = 74;
    /// Room around the pill inside the window for the shadow and for the pill to
    /// grow into when a drag arms it. The window is bigger than the pill; the
    /// difference is transparent and, because Background is null, clicks in it
    /// fall through to whatever is behind.
    private const double ShadowMargin = 16;
    private const double GapAboveTaskbar = 10;
    private const double DragScale = 1.035;
    private const double DragLift = -3;
    private const double RevealScale = 0.94;
    private const double RevealDrop = 14;
    private const double DismissScale = 0.97;
    private const double DismissDrop = 8;

    // Glyphs, kept to characters Segoe UI itself carries.
    internal const string IdleGlyph = "⇧";
    private const string DragGlyph = "↓";
    private const string SendGlyph = "↑";
    private const string ReceiveGlyph = "↓";
    private const string SuccessGlyph = "✓";
    private const string FailureGlyph = "!";

    private readonly Border _frame;
    private readonly SolidColorBrush _frameFill;
    private readonly SolidColorBrush _frameEdge;
    private readonly ScaleTransform _frameScale = new(1, 1);
    private readonly TranslateTransform _frameLift = new(0, 0);

    private readonly Border _glyphTile;
    private readonly ScaleTransform _glyphScale = new(1, 1);
    private readonly TextBlock _glyph;
    private readonly SolidColorBrush _accent;

    private readonly TextBlock _title;
    private readonly TextBlock _detail;
    private readonly Grid _progressRow;
    private readonly Border _progressFill;

    private readonly Border _action;
    private readonly TextBlock _actionLabel;

    private readonly SolidColorBrush _tileBrush;
    private readonly SolidColorBrush _tileStrongBrush;
    private readonly SolidColorBrush _onAccentBrush;
    private readonly SolidColorBrush _warmBrush;
    private readonly SolidColorBrush _textPrimaryBrush;
    private readonly SolidColorBrush _textSecondaryBrush;

    private Color _surfaceIdle;
    private Color _surfaceDrag;
    private Color _surfaceResolved;
    private Color _edgeIdle;
    private Color _edgeDrag;
    private Color _edgeBusy;
    private Color _edgeResolved;

    private readonly Duration _openDuration;
    private readonly Duration _closeDuration;
    private readonly Duration _tintDuration;
    private readonly Duration _progressDuration;
    private readonly Duration _settleDuration;
    private readonly Duration _popDuration;
    private readonly TimeSpan _dwellSuccess;
    private readonly TimeSpan _dwellFailure;

    /// Returns the pill to idle after a result has had its dwell.
    private readonly DispatcherTimer _dwell;
    /// A jittery hand must not flicker the pill in and out of the armed state, so
    /// leaving is on a short grace like the Mac's dragOutGrace. WPF also raises
    /// DragLeave when the pointer crosses between the pill's own children, which
    /// without this would strobe the whole state.
    private readonly DispatcherTimer _dragOut;

    private string _idleDetail = "Looking for your Mac…";
    private DropWidgetAction _idleAction = DropWidgetAction.Pair;
    private double _progress;
    private double _trackWidth;
    private bool _armed;
    private bool _dismissing;

    public event Action<string[]>? FilesDropped;
    public event Action? DismissRequested;
    public event Action? OpenFolderRequested;
    public event Action? PairRequested;

    /// The second line shown while a drag is over the pill — "to Michael's Mac",
    /// or why it cannot go anywhere yet. Owned by App, which is the only thing
    /// that knows about peers.
    public string DropDetail { get; set; } = "";

    public DropWidgetWindow()
    {
        _openDuration = StickyTheme.FindDuration("Sticky.Duration.Open");
        _closeDuration = StickyTheme.FindDuration("Sticky.Duration.Close");
        _tintDuration = StickyTheme.FindDuration("Sticky.Duration.Tint");
        _progressDuration = StickyTheme.FindDuration("Sticky.Duration.Progress");
        _settleDuration = StickyTheme.FindDuration("Sticky.Duration.Settle");
        _popDuration = StickyTheme.FindDuration("Sticky.Duration.Pop");
        _dwellSuccess = StickyTheme.FindDwell("Sticky.Duration.DwellSuccess");
        _dwellFailure = StickyTheme.FindDwell("Sticky.Duration.DwellFailure");

        _tileBrush = StickyTheme.FindBrush("Sticky.Brush.Tile");
        _tileStrongBrush = StickyTheme.FindBrush("Sticky.Brush.TileStrong");
        _onAccentBrush = StickyTheme.FindBrush("Sticky.Brush.OnAccent");
        _warmBrush = StickyTheme.FindBrush("Sticky.Brush.Warm");
        _textPrimaryBrush = StickyTheme.FindBrush("Sticky.Brush.TextPrimary");
        _textSecondaryBrush = StickyTheme.FindBrush("Sticky.Brush.TextSecondary");

        // Its own instances, not the shared resource brushes: these get animated,
        // and animating a brush that other windows are painting with would drag
        // them along.
        _accent = new SolidColorBrush(StickyTheme.FindColor("Sticky.Color.Accent"));
        _surfaceIdle = StickyTheme.FindColor("Sticky.Color.Surface");
        _surfaceResolved = StickyTheme.FindColor("Sticky.Color.SurfaceResolved");
        _edgeIdle = StickyTheme.FindColor("Sticky.Color.Edge");
        _edgeResolved = StickyTheme.FindColor("Sticky.Color.EdgeResolved");
        _surfaceDrag = StickyTheme.FindColor("Sticky.Color.SurfaceDrag");
        _edgeDrag = StickyTheme.FindColor("Sticky.Color.EdgeDrag");
        _edgeBusy = StickyTheme.FindColor("Sticky.Color.EdgeBusy");

        _frameFill = new SolidColorBrush(_surfaceIdle);
        _frameEdge = new SolidColorBrush(_edgeIdle);

        Title = "Sticky";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        // Deliberately null and not Transparent. A Transparent brush is still hit
        // testable, which would make the ring of empty space around the pill
        // swallow clicks meant for the desktop or the taskbar underneath.
        Background = null;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        AllowDrop = true;
        Focusable = false;
        Width = FrameWidth + ShadowMargin * 2;
        Height = FrameHeight + ShadowMargin * 2;

        _glyph = new TextBlock
        {
            Text = IdleGlyph,
            FontFamily = new FontFamily("Segoe UI Symbol, Segoe UI"),
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            Foreground = _accent,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        _glyphTile = new Border
        {
            Width = 34,
            Height = 34,
            // Concentric: the pill's radius less its padding, never eyeballed.
            CornerRadius = StickyTheme.FindRadius("Sticky.Radius.Tile"),
            Background = _tileBrush,
            Child = _glyph,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 11, 0),
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = _glyphScale
        };

        _title = new TextBlock
        {
            Text = "Drop files to send",
            Foreground = _textPrimaryBrush,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        _detail = new TextBlock
        {
            Text = _idleDetail,
            Foreground = StickyTheme.FindBrush("Sticky.Brush.TextTertiary"),
            FontSize = 12.5,
            Margin = new Thickness(0, 1, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis
        };

        CornerRadius trackRadius = StickyTheme.FindRadius("Sticky.Radius.Track");
        Border track = new()
        {
            Height = 3,
            CornerRadius = trackRadius,
            Background = StickyTheme.FindBrush("Sticky.Brush.Track")
        };
        _progressFill = new Border
        {
            Height = 3,
            Width = 0,
            CornerRadius = trackRadius,
            Background = _accent,
            HorizontalAlignment = HorizontalAlignment.Left
        };
        _progressRow = new Grid
        {
            Height = 3,
            Margin = new Thickness(0, 7, 0, 0),
            // The row always occupies its space, even when there is no transfer.
            // Collapsing it would make the pill's two lines jump every time a send
            // starts and finishes.
            Opacity = 0
        };
        _progressRow.Children.Add(track);
        _progressRow.Children.Add(_progressFill);
        _progressRow.SizeChanged += (_, e) =>
        {
            _trackWidth = e.NewSize.Width;
            ApplyProgressWidth(instant: true);
        };

        StackPanel column = new() { VerticalAlignment = VerticalAlignment.Center };
        column.Children.Add(_title);
        column.Children.Add(_detail);
        column.Children.Add(_progressRow);

        _actionLabel = new TextBlock
        {
            Text = "Pair",
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = _onAccentBrush,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        _action = new Border
        {
            MinWidth = 24,
            Height = 24,
            CornerRadius = StickyTheme.FindRadius("Sticky.Radius.Action"),
            Background = _accent,
            Padding = new Thickness(10, 0, 10, 0),
            Margin = new Thickness(10, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Cursor = Cursors.Hand,
            Child = _actionLabel
        };
        _action.MouseLeftButtonUp += (_, _) => InvokeAction();

        Grid row = new();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_glyphTile, 0);
        Grid.SetColumn(column, 1);
        Grid.SetColumn(_action, 2);
        row.Children.Add(_glyphTile);
        row.Children.Add(column);
        row.Children.Add(_action);

        TransformGroup frameTransform = new();
        frameTransform.Children.Add(_frameScale);
        frameTransform.Children.Add(_frameLift);

        _frame = new Border
        {
            Width = FrameWidth,
            Height = FrameHeight,
            Background = _frameFill,
            BorderBrush = _frameEdge,
            BorderThickness = new Thickness(1),
            CornerRadius = StickyTheme.FindRadius("Sticky.Radius.Pill"),
            Padding = new Thickness(12, 10, 12, 10),
            AllowDrop = true,
            Child = row,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = frameTransform,
            ToolTip = "Drag files here to send them to your Mac",
            Effect = new DropShadowEffect
            {
                BlurRadius = 20,
                ShadowDepth = 5,
                Direction = 270,
                Opacity = 0.5,
                Color = Colors.Black
            }
        };

        Grid root = new();
        root.Children.Add(_frame);
        Content = root;

        System.Windows.Controls.ContextMenu menu = new();
        MenuItem pair = new() { Header = "Pair with your Mac…" };
        pair.Click += (_, _) => PairRequested?.Invoke();
        MenuItem open = new() { Header = "Open received files" };
        open.Click += (_, _) => OpenFolderRequested?.Invoke();
        MenuItem hide = new() { Header = "Hide this tab" };
        hide.Click += (_, _) => DismissRequested?.Invoke();
        menu.Items.Add(pair);
        menu.Items.Add(open);
        menu.Items.Add(new Separator());
        menu.Items.Add(hide);
        ContextMenu = menu;

        _dwell = new DispatcherTimer();
        _dwell.Tick += (_, _) =>
        {
            _dwell.Stop();
            ApplyIdle(_closeDuration);
        };

        _dragOut = new DispatcherTimer { Interval = StickyTheme.FindDwell("Sticky.Duration.DragGrace") };
        _dragOut.Tick += (_, _) =>
        {
            _dragOut.Stop();
            Arm(false);
        };

        SourceInitialized += OnSourceInitialized;
        DragOver += OnDragOver;
        DragLeave += OnDragLeave;
        Drop += OnDrop;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;

        ApplyIdle(_tintDuration);
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
    /// bottom edge less a hair of breathing room — measured to the pill, not to
    /// the window, which is larger by the transparent shadow margin.
    public void Reposition()
    {
        Rect work = SystemParameters.WorkArea;
        Left = work.Left + Math.Max(0, (work.Width - Width) / 2);
        Top = work.Bottom - GapAboveTaskbar - Height + ShadowMargin;
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(() => Reposition());

    /// Re-reads the accent after the user changes it in Windows Settings.
    public void ReadAccent()
    {
        _accent.Color = StickyTheme.FindColor("Sticky.Color.Accent");
        _surfaceDrag = StickyTheme.FindColor("Sticky.Color.SurfaceDrag");
        _edgeDrag = StickyTheme.FindColor("Sticky.Color.EdgeDrag");
        _edgeBusy = StickyTheme.FindColor("Sticky.Color.EdgeBusy");
    }

    // MARK: Appearing and dismissing

    /// Springy on the way in, per DS.Motion: it comes up from below the taskbar
    /// edge with a small overshoot, so the eye is told where it lives.
    public void Reveal()
    {
        _dismissing = false;
        if (!IsVisible)
        {
            Opacity = StickyTheme.Animates ? 0 : 1;
            Show();
        }
        Reposition();

        if (!StickyTheme.Animates)
        {
            BeginAnimation(OpacityProperty, null);
            Opacity = 1;
            _frameScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            _frameScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            _frameLift.BeginAnimation(TranslateTransform.YProperty, null);
            _frameScale.ScaleX = 1;
            _frameScale.ScaleY = 1;
            _frameLift.Y = 0;
            return;
        }

        StickyTheme.AnimateDouble(this, OpacityProperty, 0, 1, _tintDuration, StickyTheme.TintEase);
        StickyTheme.AnimateDouble(_frameScale, ScaleTransform.ScaleXProperty, RevealScale, 1, _openDuration, StickyTheme.OpenEase);
        StickyTheme.AnimateDouble(_frameScale, ScaleTransform.ScaleYProperty, RevealScale, 1, _openDuration, StickyTheme.OpenEase);
        StickyTheme.AnimateDouble(_frameLift, TranslateTransform.YProperty, RevealDrop, 0, _openDuration, StickyTheme.OpenEase);
    }

    /// Smooth on the way out, and shorter. No bounce: a pill that wobbles shut
    /// reads as indecision (DS.Motion, plan §4.3).
    public void Dismiss()
    {
        if (!IsVisible) return;
        if (!StickyTheme.Animates)
        {
            Hide();
            return;
        }

        _dismissing = true;
        DoubleAnimation fade = new(1, 0, _closeDuration) { EasingFunction = StickyTheme.CloseEase, FillBehavior = FillBehavior.HoldEnd };
        fade.Completed += (_, _) =>
        {
            if (!_dismissing) return;
            _dismissing = false;
            BeginAnimation(OpacityProperty, null);
            Opacity = 1;
            Hide();
        };
        BeginAnimation(OpacityProperty, fade);
        StickyTheme.AnimateDouble(_frameScale, ScaleTransform.ScaleXProperty, DismissScale, _closeDuration, StickyTheme.CloseEase);
        StickyTheme.AnimateDouble(_frameScale, ScaleTransform.ScaleYProperty, DismissScale, _closeDuration, StickyTheme.CloseEase);
        StickyTheme.AnimateDouble(_frameLift, TranslateTransform.YProperty, DismissDrop, _closeDuration, StickyTheme.CloseEase);
    }

    // MARK: Drag and drop

    private void OnDragOver(object sender, DragEventArgs e)
    {
        bool acceptable = e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effects = acceptable ? DragDropEffects.Copy : DragDropEffects.None;
        _dragOut.Stop();
        Arm(acceptable);
        e.Handled = true;
    }

    private void OnDragLeave(object sender, DragEventArgs e)
    {
        _dragOut.Stop();
        _dragOut.Start();
        e.Handled = true;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        _dragOut.Stop();
        // Disarm first so the lift and the growth ease back out; ShowProgress then
        // overwrites the copy in the same dispatch, so the idle line ApplyIdle
        // writes on the way past is never drawn.
        Arm(false);
        e.Handled = true;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths || paths.Length == 0) return;
        ShowProgress(
            paths.Length == 1 ? Path.GetFileName(paths[0].TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)) : $"{paths.Length} items",
            "Preparing…",
            0,
            outgoing: true);
        FilesDropped?.Invoke(paths);
    }

    /// The state that has to visibly WANT the file: the pill lifts, grows a
    /// little, and washes toward the accent — grown with the springy open easing
    /// so it reaches for the cursor, released with the smooth close easing so
    /// letting go is undramatic.
    private void Arm(bool armed)
    {
        if (_armed == armed) return;
        _armed = armed;

        if (armed)
        {
            _dwell.Stop();
            _glyph.Text = DragGlyph;
            _glyph.Foreground = _accent;
            _title.Text = "Release to send";
            _detail.Text = string.IsNullOrEmpty(DropDetail) ? "to your Mac" : DropDetail;
            FadeProgress(0);
            Tint(_surfaceDrag, _edgeDrag, _tintDuration);
            StickyTheme.AnimateDouble(_frameScale, ScaleTransform.ScaleXProperty, DragScale, _tintDuration, StickyTheme.OpenEase);
            StickyTheme.AnimateDouble(_frameScale, ScaleTransform.ScaleYProperty, DragScale, _tintDuration, StickyTheme.OpenEase);
            StickyTheme.AnimateDouble(_frameLift, TranslateTransform.YProperty, DragLift, _tintDuration, StickyTheme.OpenEase);
            return;
        }

        StickyTheme.AnimateDouble(_frameScale, ScaleTransform.ScaleXProperty, 1, _closeDuration, StickyTheme.CloseEase);
        StickyTheme.AnimateDouble(_frameScale, ScaleTransform.ScaleYProperty, 1, _closeDuration, StickyTheme.CloseEase);
        StickyTheme.AnimateDouble(_frameLift, TranslateTransform.YProperty, 0, _closeDuration, StickyTheme.CloseEase);
        if (!_dwell.IsEnabled) ApplyIdle(_closeDuration);
    }

    // MARK: States

    public void ShowIdle(string detail, DropWidgetAction action)
    {
        _idleDetail = detail;
        _idleAction = action;
        // A result is still on screen, or a drag is in flight: let it finish. The
        // new idle copy is remembered and used when it does.
        if (_dwell.IsEnabled || _armed) return;
        ApplyIdle(_tintDuration);
    }

    private void ApplyIdle(Duration tint)
    {
        _glyph.Text = IdleGlyph;
        _glyph.Foreground = _accent;
        _title.Text = "Drop files to send";
        _detail.Text = _idleDetail;
        _progress = 0;
        FadeProgress(0);
        SetAction(
            _idleAction == DropWidgetAction.Pair ? "Pair" : "Open",
            _idleAction == DropWidgetAction.Pair ? _accent : _tileStrongBrush,
            _idleAction == DropWidgetAction.Pair ? _onAccentBrush : _textSecondaryBrush,
            _idleAction == DropWidgetAction.Pair
                ? "Pair this PC with your Mac — needed once, before anything can be sent"
                : "Open the folder your files arrive in",
            clickable: true);
        Tint(_surfaceIdle, _edgeIdle, tint);
    }

    public void ShowProgress(string title, string detail, double progress, bool outgoing)
    {
        _dwell.Stop();
        _dragOut.Stop();
        // No-op when the drop already disarmed it; matters when a transfer starts
        // while a drag happens to be over the pill, which would otherwise leave it
        // stuck at its armed size.
        Arm(false);
        _glyph.Text = outgoing ? SendGlyph : ReceiveGlyph;
        _glyph.Foreground = _accent;
        _title.Text = string.IsNullOrWhiteSpace(title) ? (outgoing ? "Sending" : "Receiving") : title;
        _detail.Text = detail;
        _progress = Math.Clamp(progress, 0, 1);
        FadeProgress(1);
        ApplyProgressWidth(instant: false);
        // The percentage takes the trailing slot while a transfer is live: it is
        // the only thing worth reading there, and it means the two copy lines can
        // stay about WHAT is moving rather than how far along it is.
        SetAction($"{(int)Math.Round(_progress * 100)}%", _tileStrongBrush, _textSecondaryBrush, null, clickable: false);
        Tint(_surfaceIdle, _edgeBusy, _tintDuration);
    }

    public void ShowResult(string title, string detail, bool success)
    {
        _dragOut.Stop();
        Arm(false);
        _dwell.Stop();
        _glyph.Text = success ? SuccessGlyph : FailureGlyph;
        // The warm ramp is ambient light only, and a completed transfer is the one
        // moment the Windows half earns it. Failure keeps the accent: a second hue
        // for "bad" is exactly the drift DS was written to stop.
        _glyph.Foreground = success ? _warmBrush : _accent;
        _title.Text = title;
        _detail.Text = detail;

        if (success)
        {
            _progress = 1;
            ApplyProgressWidth(instant: false);
        }
        FadeProgress(0);
        SetAction(
            _idleAction == DropWidgetAction.Pair ? "Pair" : "Open",
            _idleAction == DropWidgetAction.Pair ? _accent : _tileStrongBrush,
            _idleAction == DropWidgetAction.Pair ? _onAccentBrush : _textSecondaryBrush,
            null,
            clickable: true);

        PopGlyph();
        // A beat of colour, then a long ease back to the resting surface, so the
        // result fades out of the pill instead of being switched off.
        StickyTheme.SettleColor(_frameFill, success ? _surfaceResolved : _surfaceIdle, _surfaceIdle, _settleDuration, 0.16);
        StickyTheme.SettleColor(_frameEdge, success ? _edgeResolved : _edgeDrag, _edgeIdle, _settleDuration, 0.16);

        _dwell.Stop();
        _dwell.Interval = success ? _dwellSuccess : _dwellFailure;
        _dwell.Start();
    }

    // MARK: Pieces

    private void SetAction(string label, Brush background, Brush foreground, string? tip, bool clickable)
    {
        _actionLabel.Text = label;
        _actionLabel.Foreground = foreground;
        _action.Background = background;
        _action.ToolTip = tip;
        _action.IsHitTestVisible = clickable;
        _action.Cursor = clickable ? Cursors.Hand : Cursors.Arrow;
    }

    private void InvokeAction()
    {
        if (_idleAction == DropWidgetAction.Pair) PairRequested?.Invoke();
        else OpenFolderRequested?.Invoke();
    }

    private void FadeProgress(double opacity) =>
        StickyTheme.AnimateDouble(_progressRow, OpacityProperty, opacity, _tintDuration, StickyTheme.TintEase);

    private void ApplyProgressWidth(bool instant)
    {
        if (_trackWidth <= 0) return;
        double target = Math.Clamp(_trackWidth * _progress, 0, _trackWidth);
        if (instant)
        {
            _progressFill.BeginAnimation(WidthProperty, null);
            _progressFill.Width = target;
            return;
        }
        StickyTheme.AnimateDouble(_progressFill, WidthProperty, target, _progressDuration, StickyTheme.TintEase);
    }

    private void Tint(Color fill, Color edge, Duration duration)
    {
        StickyTheme.AnimateColor(_frameFill, fill, duration, StickyTheme.TintEase);
        StickyTheme.AnimateColor(_frameEdge, edge, duration, StickyTheme.TintEase);
    }

    /// The glyph tile is the only thing that moves when a transfer resolves —
    /// small, once, and never on a loop.
    private void PopGlyph()
    {
        if (!StickyTheme.Animates)
        {
            _glyphScale.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            _glyphScale.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            _glyphScale.ScaleX = 1;
            _glyphScale.ScaleY = 1;
            return;
        }
        DoubleAnimation pop = new(0.72, 1, _popDuration) { EasingFunction = StickyTheme.PopEase, FillBehavior = FillBehavior.HoldEnd };
        _glyphScale.BeginAnimation(ScaleTransform.ScaleXProperty, pop);
        _glyphScale.BeginAnimation(ScaleTransform.ScaleYProperty, pop);
    }

    protected override void OnClosed(EventArgs e)
    {
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        _dwell.Stop();
        _dragOut.Stop();
        base.OnClosed(e);
    }
}

// MARK: - Pairing

/// The one window Sticky opens by itself, and the answer to the app's worst
/// usability problem: until now the six-digit code was a DISABLED tray menu
/// item, so the single thing standing between a new user and a working product
/// was hidden behind a right-click and could not even be copied.
///
/// Everything pairing needs is on one surface: this PC's name (so you know which
/// device to pick on the Mac), this PC's live code, the Mac's name the moment
/// discovery sees it, and a field for the Mac's code. Both directions work, and
/// the window says which one you are in the middle of.
internal sealed class PairingWindow : Window
{
    private readonly TransferService _transfer;
    private readonly DiscoveryService _discovery;
    private readonly PairingService _pairing;
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(1) };

    private readonly TextBlock _thisDevice;
    private readonly TextBlock _code;
    private readonly TextBlock _codeLife;
    private readonly TextBlock _peerLine;
    private readonly TextBlock _status;
    private readonly TextBox _entry;
    private readonly Button _pairButton;

    private readonly SolidColorBrush _textPrimary;
    private readonly SolidColorBrush _textSecondary;
    private readonly SolidColorBrush _textTertiary;
    private readonly SolidColorBrush _accent;
    private readonly SolidColorBrush _warm;

    private string _shownPin = "";
    private DateTimeOffset _codeArmedUntil = DateTimeOffset.MinValue;
    private bool _busy;
    private bool _announcedPaired;

    /// Raised whenever this window changes what "paired" means, in either
    /// direction, so the tray and the pill can restate themselves.
    public event Action? PairingChanged;

    public PairingWindow(TransferService transfer, DiscoveryService discovery, PairingService pairing)
    {
        _transfer = transfer;
        _discovery = discovery;
        _pairing = pairing;

        _textPrimary = StickyTheme.FindBrush("Sticky.Brush.TextPrimary");
        _textSecondary = StickyTheme.FindBrush("Sticky.Brush.TextSecondary");
        _textTertiary = StickyTheme.FindBrush("Sticky.Brush.TextTertiary");
        _accent = StickyTheme.FindBrush("Sticky.Brush.Accent");
        _warm = StickyTheme.FindBrush("Sticky.Brush.Warm");

        Title = "Sticky — Pair with your Mac";
        Width = 480;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = StickyTheme.FindBrush("Sticky.Brush.PanelBackground");
        FontFamily = new FontFamily("Segoe UI");

        CornerRadius panelRadius = StickyTheme.FindRadius("Sticky.Radius.Panel");
        SolidColorBrush panelSurface = StickyTheme.FindBrush("Sticky.Brush.PanelSurface");

        StackPanel page = new() { Margin = new Thickness(26, 22, 26, 22) };

        page.Children.Add(Text("Pair this PC with your Mac", 20, FontWeights.SemiBold, _textPrimary, new Thickness(0, 0, 0, 4)));
        page.Children.Add(Text(
            "One six-digit code, once. Until it's done, neither computer will accept files from the other.",
            13, FontWeights.Normal, _textSecondary, new Thickness(0, 0, 0, 18)));

        // Step one — the code this PC is showing.
        StackPanel step1 = new();
        step1.Children.Add(Text("STEP 1 — On your Mac, enter this code", 11.5, FontWeights.SemiBold, _textTertiary, new Thickness(0, 0, 0, 10)));
        _thisDevice = Text($"This PC is called “{_discovery.Self.Name}”", 13, FontWeights.Normal, _textSecondary, new Thickness(0, 0, 0, 10));
        step1.Children.Add(_thisDevice);
        _code = new TextBlock
        {
            Text = "— — — — — —",
            FontFamily = new FontFamily("Consolas, Segoe UI"),
            FontSize = 40,
            FontWeight = FontWeights.Bold,
            Foreground = _warm,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 2, 0, 6)
        };
        step1.Children.Add(_code);
        _codeLife = Text(
            "Open Sticky on the Mac, choose Pair, and type these six digits.",
            12.5, FontWeights.Normal, _textTertiary, new Thickness(0, 0, 0, 0));
        _codeLife.TextAlignment = TextAlignment.Center;
        step1.Children.Add(_codeLife);
        page.Children.Add(Card(step1, panelSurface, panelRadius, new Thickness(0, 0, 0, 14)));

        // Step two — the other direction, for when the Mac is the one showing a code.
        StackPanel step2 = new();
        step2.Children.Add(Text("STEP 2 — Or type the code your Mac is showing", 11.5, FontWeights.SemiBold, _textTertiary, new Thickness(0, 0, 0, 10)));
        _peerLine = Text("Looking for your Mac…", 13, FontWeights.Normal, _textSecondary, new Thickness(0, 0, 0, 10));
        step2.Children.Add(_peerLine);

        _entry = new TextBox
        {
            Style = StickyTheme.FindStyle("Sticky.Style.CodeField"),
            MaxLength = 6
        };
        _entry.PreviewTextInput += (_, e) => e.Handled = e.Text.Any(character => !char.IsAsciiDigit(character));
        _entry.TextChanged += (_, _) => _pairButton.IsEnabled = !_busy && !_announcedPaired && Digits(_entry.Text).Length == 6;

        _pairButton = new Button
        {
            Style = StickyTheme.FindStyle("Sticky.Style.PrimaryButton"),
            Content = "Pair",
            IsDefault = true,
            IsEnabled = false,
            Margin = new Thickness(10, 0, 0, 0),
            MinWidth = 96
        };
        _pairButton.Click += OnPairClicked;

        Grid entryRow = new() { Margin = new Thickness(0, 0, 0, 0) };
        entryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        entryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_entry, 0);
        Grid.SetColumn(_pairButton, 1);
        entryRow.Children.Add(_entry);
        entryRow.Children.Add(_pairButton);
        step2.Children.Add(entryRow);
        page.Children.Add(Card(step2, panelSurface, panelRadius, new Thickness(0, 0, 0, 14)));

        _status = Text(
            "You only need one of the two steps — whichever computer is easier to type on.",
            12.5, FontWeights.Normal, _textTertiary, new Thickness(2, 0, 2, 16));
        _status.TextWrapping = TextWrapping.Wrap;
        page.Children.Add(_status);

        StackPanel buttons = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        Button newCode = new()
        {
            Style = StickyTheme.FindStyle("Sticky.Style.Button"),
            Content = "New code",
            Margin = new Thickness(0, 0, 8, 0),
            MinWidth = 96,
            ToolTip = "Show a fresh code and reopen the five-minute pairing window"
        };
        newCode.Click += (_, _) => ArmCode();
        Button done = new()
        {
            Style = StickyTheme.FindStyle("Sticky.Style.Button"),
            Content = "Close",
            IsCancel = true,
            MinWidth = 96
        };
        done.Click += (_, _) => Close();
        buttons.Children.Add(newCode);
        buttons.Children.Add(done);
        page.Children.Add(buttons);

        Content = page;

        // The pairing endpoint only entertains guesses while this window is open,
        // which is the whole point of BeginPairingWindow. It is armed once here
        // and re-armed only when the user asks for a new code — re-arming on a
        // timer would reset the wrong-guess lockout every tick.
        ArmCode();

        _poll.Tick += (_, _) => Refresh();
        _poll.Start();
        Loaded += (_, _) => _entry.Focus();
        Closed += OnWindowClosed;
    }

    private void OnWindowClosed(object? sender, EventArgs e)
    {
        _poll.Stop();
        // Closing the window closes the pairing window on the wire too.
        _transfer.EndPairingWindow();
        PairingChanged?.Invoke();
    }

    private void ArmCode()
    {
        _transfer.BeginPairingWindow();
        _codeArmedUntil = DateTimeOffset.UtcNow.AddMinutes(5);
        _shownPin = "";
        Refresh();
    }

    private void Refresh()
    {
        string pin = _transfer.CurrentPin;
        if (pin != _shownPin)
        {
            _shownPin = pin;
            _code.Text = Spaced(pin);
        }

        TimeSpan remaining = _codeArmedUntil - DateTimeOffset.UtcNow;
        if (remaining <= TimeSpan.Zero)
        {
            _code.Foreground = _textTertiary;
            _codeLife.Text = "This code has expired. Click New code to show a fresh one.";
        }
        else
        {
            _code.Foreground = _warm;
            _codeLife.Text = $"Open Sticky on the Mac, choose Pair, and type these six digits — good for {(int)remaining.TotalMinutes}:{remaining.Seconds:D2}.";
        }

        StickyDevice? peer = _transfer.DefaultTarget();
        if (peer is null)
        {
            _peerLine.Text = "Looking for your Mac…";
            _peerLine.Foreground = _textTertiary;
            // Never speak over an attempt in flight, or over the paired message.
            if (_busy || _announcedPaired) return;
            _pairButton.IsEnabled = false;
            SetStatus(
                "Sticky can't see your Mac yet. Open Sticky on it, and make sure this network is set to Private in Windows Settings — on a Public network Windows blocks the messages the two apps use to find each other.",
                null);
            return;
        }

        _peerLine.Text = $"Found “{peer.Name}”";
        _peerLine.Foreground = _textSecondary;

        // Covers the other direction too: when the Mac types this PC's code,
        // nothing calls back into the UI, so the paired state is noticed here.
        if (_pairing.IsPeerPaired(peer.Id))
        {
            if (!_announcedPaired)
            {
                _announcedPaired = true;
                SetStatus(PairedMessage(peer.Name), true);
                PairingChanged?.Invoke();
            }
            _entry.IsEnabled = false;
            _pairButton.IsEnabled = false;
            return;
        }

        if (_busy) return;
        _announcedPaired = false;
        _entry.IsEnabled = true;
        _pairButton.IsEnabled = Digits(_entry.Text).Length == 6;
    }

    private static string PairedMessage(string peerName) =>
        $"Paired with {peerName}. You can close this window — drag files onto the Sticky tab at the bottom of the screen, " +
        "or right-click a file in Explorer and choose Send To → Sticky.";

    private async void OnPairClicked(object sender, RoutedEventArgs e)
    {
        if (_busy) return;

        string code = Digits(_entry.Text);
        if (code.Length != 6)
        {
            SetStatus("Type all six digits of the code your Mac is showing.", false);
            return;
        }
        if (_transfer.DefaultTarget() is not { } peer)
        {
            SetStatus("Sticky can't see your Mac right now, so there's nothing to pair with yet.", false);
            return;
        }

        _busy = true;
        _pairButton.IsEnabled = false;
        _entry.IsEnabled = false;
        SetStatus($"Pairing with {peer.Name}…", null);
        try
        {
            await _transfer.PairAsync(peer, code);
            _announcedPaired = true;
            SetStatus(PairedMessage(peer.Name), true);
            _entry.Clear();
            PairingChanged?.Invoke();
        }
        catch (Exception ex)
        {
            // Never a bare exception: what happened, and what to do about it.
            SetStatus(App.ExplainPairError(ex).Replace("\n\n", " "), false);
            _entry.SelectAll();
            _entry.Focus();
        }
        finally
        {
            _busy = false;
            _entry.IsEnabled = !_announcedPaired;
            _pairButton.IsEnabled = !_announcedPaired && Digits(_entry.Text).Length == 6;
        }
    }

    private void SetStatus(string message, bool? good)
    {
        _status.Text = message;
        _status.Foreground = good switch
        {
            true => _warm,
            false => _accent,
            null => _textTertiary
        };
    }

    private static string Digits(string? value) =>
        value is null ? "" : new string(value.Where(char.IsAsciiDigit).ToArray());

    /// Six digits are read aloud off one screen and typed into another, so they
    /// are spaced in threes. Nobody misreads 418 502; plenty of people misread 418502.
    private static string Spaced(string pin) =>
        pin.Length == 6 ? $"{pin[..3]} {pin[3..]}" : pin;

    private static TextBlock Text(string content, double size, FontWeight weight, Brush foreground, Thickness margin) => new()
    {
        Text = content,
        FontSize = size,
        FontWeight = weight,
        Foreground = foreground,
        Margin = margin,
        TextWrapping = TextWrapping.Wrap
    };

    private static Border Card(UIElement content, Brush background, CornerRadius radius, Thickness margin) => new()
    {
        Background = background,
        CornerRadius = radius,
        Padding = new Thickness(18, 16, 18, 16),
        Margin = margin,
        Child = content
    };
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

    /// False exactly once, on the very first launch, which is when Sticky opens
    /// the pairing window by itself. It is written before the window appears, so
    /// a crash during first run cannot make the app nag every launch afterwards.
    [JsonPropertyName("firstRunDone")]
    public bool FirstRunDone { get; init; }

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
