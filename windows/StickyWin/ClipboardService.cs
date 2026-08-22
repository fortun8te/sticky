using System.Windows;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace StickyWin;

public record StickyClipEntry(Guid Id, string Text, DateTimeOffset Timestamp, string? Sender)
{
    public string Preview => Text.Length <= 96 ? Text : $"{Text[..93]}…";
}

public sealed class ClipboardService : IDisposable
{
    private readonly List<StickyClipEntry> _history = [];

    public ClipboardService()
    {
    }

    public IReadOnlyList<StickyClipEntry> History => _history;
    public StickyClipEntry? StickySlot { get; private set; }

    public void Start()
    {
        // Sticky deliberately does not observe the Windows clipboard. Its
        // private portal only contains items explicitly written to Sticky or
        // received from a paired device.
    }

    public void Stop() { }

    public void ReceiveRemote(string text, string sender)
    {
        if (string.IsNullOrEmpty(text)) return;
        StickyClipEntry entry = new(Guid.NewGuid(), text, DateTimeOffset.UtcNow, sender);
        _history.Insert(0, entry);
        if (_history.Count > 100) _history.RemoveAt(_history.Count - 1);
        StickySlot = entry;
    }

    public StickyClipEntry WriteSticky(string text)
    {
        if (string.IsNullOrEmpty(text)) throw new ArgumentException("Text cannot be empty.", nameof(text));
        StickyClipEntry entry = new(Guid.NewGuid(), text, DateTimeOffset.UtcNow, null);
        _history.Insert(0, entry);
        if (_history.Count > 100) _history.RemoveAt(_history.Count - 1);
        StickySlot = entry;
        return entry;
    }

    public void Promote(StickyClipEntry entry)
    {
        StickySlot = entry;
        Clipboard.SetText(entry.Text);
    }

    public void Dispose() => Stop();
}
