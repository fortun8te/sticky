using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using H.NotifyIcon;

namespace StickyWin;

public partial class App : Application
{
    private TaskbarIcon? _tray;
    private DiscoveryService? _discovery;
    private TransferService? _transfer;
    private ClipboardService? _clipboard;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        string deviceId = Environment.MachineName.ToLowerInvariant();
        _discovery = new DiscoveryService(deviceId, Environment.MachineName);
        _transfer = new TransferService(_discovery, new PairingService());
        _clipboard = new ClipboardService();

        // Local copies are retained in Sticky's private history only. A user
        // explicitly chooses when to send an item; ordinary clipboard activity
        // must never leak to a nearby device.
        _clipboard.Start();

        // Receiving is already streamed and finalized by the transfer service.
        // Calling AcceptIncomingAsync here raced the uploader and could delete a
        // freshly prepared session before its first chunk arrived.
        _transfer.IncomingCompleted += count => Dispatcher.BeginInvoke(() =>
            _tray?.ShowNotification("Sticky", count == 1 ? "Received 1 file" : $"Received {count} files"));
        _transfer.StateChanged += (_, state) => Dispatcher.BeginInvoke(() =>
        {
            int percent = (int)Math.Round(state.Progress * 100);
            if (_tray != null) _tray.ToolTipText = $"{state.Kind} {percent}% — {state.FileName ?? "Sticky"}";
        });
        _transfer.ClipboardReceived += (text, senderName) => Dispatcher.BeginInvoke(() =>
        {
            _clipboard.ReceiveRemote(text, senderName);
            _tray?.ShowNotification("Sticky", $"New private clipboard item from {senderName}");
        });
        _transfer.Failed += message => System.Diagnostics.Debug.WriteLine(message);
        _transfer.Start();

        SetupTray();
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
        menu.Items.Add(pair);
        menu.Items.Add(forget);
        menu.Items.Add(new Separator());
        menu.Items.Add(quit);
        menu.Opened += (_, _) => code.Header = $"This PC's pairing code: {_transfer?.CurrentPin ?? "------"}";

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
        _tray.Visibility = Visibility.Visible;
    }

    private void ChooseAndSendFiles()
    {
        if (_discovery?.GetBestPeer() is not { } peer)
        {
            MessageBox.Show("Open Sticky on your other computer and make sure both devices are on the same private Wi-Fi.", "No device nearby", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        Microsoft.Win32.OpenFileDialog dialog = new() { Title = $"Send to {peer.Name}", Multiselect = true };
        if (dialog.ShowDialog() == true) _ = SendFilesAsync(dialog.FileNames, peer);
    }

    private void ChooseAndSendFolder()
    {
        if (_discovery?.GetBestPeer() is not { } peer)
        {
            MessageBox.Show("Open Sticky on your other computer and make sure both devices are on the same private Wi-Fi.", "No device nearby", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        Microsoft.Win32.OpenFolderDialog dialog = new() { Title = $"Send a folder to {peer.Name}" };
        if (dialog.ShowDialog() == true && !string.IsNullOrEmpty(dialog.FolderName)) _ = SendFilesAsync([dialog.FolderName], peer);
    }

    private void OpenClipboardWindow()
    {
        if (_clipboard is null) return;
        Window window = new()
        {
            Title = "Sticky Clipboard", Width = 460, Height = 500,
            WindowStartupLocation = WindowStartupLocation.CenterScreen
        };
        DockPanel root = new() { Margin = new Thickness(18) };
        ListBox history = new() { DisplayMemberPath = nameof(StickyClipEntry.Preview), MinHeight = 220 };
        void Refresh() { history.ItemsSource = _clipboard.History.ToList(); }
        Refresh();

        StackPanel actions = new() { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 10) };
        Button copy = new() { Content = "Copy to Windows clipboard", Margin = new Thickness(0, 0, 8, 0) };
        copy.Click += (_, _) => { if (history.SelectedItem is StickyClipEntry entry) _clipboard.Promote(entry); };
        Button send = new() { Content = "Send selected" };
        send.Click += async (_, _) =>
        {
            if (history.SelectedItem is not StickyClipEntry entry || _discovery?.GetBestPeer() is not { } peer || _transfer is null) return;
            try { await _transfer.SendClipboardAsync(entry.Text, peer); _tray?.ShowNotification("Sticky", "Clipboard item sent"); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Couldn’t send", MessageBoxButton.OK, MessageBoxImage.Warning); }
        };
        actions.Children.Add(copy);
        actions.Children.Add(send);

        TextBox input = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 70 };
        Button save = new() { Content = "Add to Sticky clipboard", Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
        save.Click += (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(input.Text)) return;
            _clipboard.WriteSticky(input.Text);
            input.Clear();
            Refresh();
        };

        DockPanel.SetDock(actions, Dock.Bottom);
        DockPanel.SetDock(input, Dock.Bottom);
        DockPanel.SetDock(save, Dock.Bottom);
        root.Children.Add(actions);
        root.Children.Add(save);
        root.Children.Add(input);
        root.Children.Add(history);
        window.Content = root;
        window.Show();
    }

    private async Task SendFilesAsync(IReadOnlyList<string> paths, StickyDevice peer)
    {
        try
        {
            await (_transfer?.SendFilesAsync(paths, peer) ?? Task.CompletedTask);
            _tray?.ShowNotification("Sticky", "Sent");
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Couldn’t send", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async Task PairDeviceAsync()
    {
        if (_discovery?.GetBestPeer() is not { } peer || _transfer is null)
        {
            MessageBox.Show("Open Sticky on your other computer and make sure both devices are on the same private Wi-Fi.", "No device nearby", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        string? code = PromptForPairingCode(peer);
        if (code is null) return;
        try
        {
            await _transfer.PairAsync(peer, code);
            _tray?.ShowNotification("Sticky", $"Paired with {peer.Name}");
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
        _tray?.ShowNotification("Sticky", "Paired devices forgotten");
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _clipboard?.Stop();
        _transfer?.Dispose();
        _discovery?.Dispose();
        base.OnExit(e);
    }
}
