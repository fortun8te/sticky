using System.Collections.Specialized;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media.Imaging;

namespace StickyWin;

/// What a clip actually is. A portal that flattens a screenshot, a formatted
/// paragraph and a file selection down to <see cref="string"/> throws away the
/// thing that made each of them worth carrying, so the kind travels with it.
public enum StickyClipKind
{
    Text,
    RichText,
    Image,
    File
}

/// One clip in Sticky's own clipboard.
///
/// A snapshot taken at an explicit moment — never a live window onto whatever
/// the Windows clipboard happens to hold now.
public sealed record StickyClipItem(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("kind")] StickyClipKind Kind,
    [property: JsonPropertyName("createdAt")] DateTimeOffset CreatedAt,
    [property: JsonPropertyName("sender")] string? Sender,
    [property: JsonPropertyName("pinned")] bool Pinned,
    [property: JsonPropertyName("preview")] string Preview,
    [property: JsonPropertyName("byteSize")] long? ByteSize,
    [property: JsonPropertyName("plainText")] string? PlainText,
    [property: JsonPropertyName("rtfText")] string? RtfText,
    [property: JsonPropertyName("htmlText")] string? HtmlText,
    [property: JsonPropertyName("imageBlobName")] string? ImageBlobName,
    [property: JsonPropertyName("pixelWidth")] int? PixelWidth,
    [property: JsonPropertyName("pixelHeight")] int? PixelHeight,
    [property: JsonPropertyName("filePaths")] string[] FilePaths,
    [property: JsonPropertyName("fingerprint")] string Fingerprint)
{
    /// True when the clip's own content can travel the v1 text channel. An
    /// image's label is not its content, which is why this is not simply
    /// <c>PlainText is not null</c>.
    [JsonIgnore]
    public bool CarriesText => Kind is StickyClipKind.Text or StickyClipKind.RichText;

    [JsonIgnore]
    public string KindLabel => Kind switch
    {
        StickyClipKind.Text => "Text",
        StickyClipKind.RichText => "Formatted text",
        StickyClipKind.Image => "Image",
        _ => FilePaths.Length > 1 ? $"{FilePaths.Length} files" : "File"
    };

    /// One flat line for the history list. Built here so no view re-derives it.
    [JsonIgnore]
    public string Row => Pinned
        ? $"📌 {KindLabel} · {PreviewWithSender}"
        : $"{KindLabel} · {PreviewWithSender}";

    [JsonIgnore]
    private string PreviewWithSender => Sender is null ? Preview : $"{Preview}   ← {Sender}";

    /// The flat text row older call sites still speak. Same <see cref="Id"/>,
    /// so a legacy call resolves back to the typed clip it came from.
    [JsonIgnore]
    public StickyClipEntry LegacyEntry => new(Id, PlainText ?? Preview, CreatedAt, Sender);
}

/// The flat text row. Kept as a bridge for callers that only ever had text.
public record StickyClipEntry(Guid Id, string Text, DateTimeOffset Timestamp, string? Sender)
{
    public string Preview => Text.Length <= 96 ? Text : $"{Text[..93]}…";
}

/// What sending a clip actually consists of. The service decides the shape;
/// the app layer, which owns the peer and the failure UI, performs it.
public abstract record StickyClipSendPayload
{
    public sealed record Text(string Value) : StickyClipSendPayload;

    public sealed record Files(string[] Paths) : StickyClipSendPayload;
}

/// What actually lands on disk. Namespace-level and internal so the JSON
/// serializer can reach its constructor by reflection.
internal sealed record StickyClipStore(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("items")] StickyClipItem[] Items);

/// Sticky's private clipboard.
///
/// It lives *alongside* the Windows clipboard and never replaces it. Nothing
/// here polls, and nothing here writes to the Windows clipboard unless a person
/// asked for exactly that — <see cref="TakeFromSystemClipboard"/> in, and
/// <see cref="CopyToSystemClipboard"/> out. Both are one-shot and user-initiated.
///
/// Every member must be called on the UI thread: the WPF clipboard APIs require
/// STA, and the history drives WPF views directly. <see cref="ReceiveRemote"/>
/// is called from the network layer, so that caller marshals first.
public sealed class ClipboardService : IDisposable
{
    /// 50 clips. The list is scanned, not searched, and past ~50 rows nobody
    /// scrolls — they re-copy. It also keeps the index a small file that can be
    /// rewritten synchronously on every insert, because the heavy payload
    /// (images) lives out in blobs.
    private const int MaximumEntries = 50;

    /// Text and RTF live inline in the index, so they are what could bloat it.
    private const int MaximumInlineTextBytes = 512 * 1024;
    private const int MaximumImageBytes = 32 * 1024 * 1024;
    private const int MaximumFilePaths = 32;
    private const int StoreVersion = 1;

    /// The conventions Windows apps use to say "do not store this". A password
    /// manager marks its copy with these, and a clipboard that ignored them
    /// would be the one thing this design is against. Honoured on the explicit
    /// take path too: the user asking for a clip is not the password manager
    /// agreeing to hand one over.
    private const string ExcludeFromMonitoringFormat = "ExcludeClipboardContentFromMonitorProcessing";
    private const string ClipboardHistoryFormat = "CanIncludeInClipboardHistory";
    private const string CloudClipboardFormat = "CanUploadToCloudClipboard";

    private readonly List<StickyClipItem> _items = [];
    private readonly JsonSerializerOptions _json = new() { WriteIndented = false };

    public ClipboardService() => Load();

    /// The private clipboard itself, newest first.
    public IReadOnlyList<StickyClipItem> Items => _items;

    /// The clip the portal is currently holding — the last one taken, received
    /// or handed back out. A spotlight on the history, not a second store.
    public StickyClipItem? StickyItem { get; private set; }

    public string? LastError { get; private set; }

    public event Action? Changed;

    public IReadOnlyList<StickyClipEntry> History => _items.Select(item => item.LegacyEntry).ToList();

    public StickyClipEntry? StickySlot => StickyItem?.LegacyEntry;

    public StickyClipItem? Item(StickyClipEntry entry) => _items.FirstOrDefault(item => item.Id == entry.Id);

    /// Sticky never observes the Windows clipboard, so password managers,
    /// dictation tools and other clipboard utilities stay entirely outside its
    /// history. Kept as no-ops because the app layer still calls them.
    public void Start()
    {
    }

    public void Stop()
    {
    }

    // MARK: Explicit movement in

    /// Read the Windows clipboard once, right now, because someone asked.
    ///
    /// Captures the richest representation present rather than the plain string:
    /// an Explorer copy comes in as files, a screenshot as PNG, a Word selection
    /// as RTF/HTML *with* its plain-text fallback.
    public StickyClipItem? TakeFromSystemClipboard()
    {
        IDataObject? data;
        try
        {
            data = Clipboard.GetDataObject();
        }
        catch (Exception ex)
        {
            LastError = $"Windows would not hand over the clipboard: {ex.Message}";
            return null;
        }

        if (data is null)
        {
            LastError = "There is nothing on the Windows clipboard.";
            return null;
        }

        if (IsMarkedPrivate(data))
        {
            LastError = "That copy is marked private by the app that made it.";
            return null;
        }

        LastError = null;
        ClipCapture? capture = CaptureFrom(data);
        if (capture is null)
        {
            LastError ??= "Nothing on the clipboard that Sticky can hold.";
            return null;
        }

        // The blob has to exist before the item that references it does,
        // otherwise a crash between the two leaves a row that can never draw.
        if (capture.ImagePayload is { } payload && capture.Item.ImageBlobName is { } blobName &&
            !WriteBlob(payload, blobName))
        {
            LastError = "The image could not be saved to Sticky's clipboard.";
            return null;
        }

        StickyClipItem stored = Insert(capture.Item);
        StickyItem = stored;
        Changed?.Invoke();
        return stored;
    }

    /// A clip arriving from the paired machine. Callers on the network thread
    /// must marshal to the UI thread first.
    public void ReceiveRemote(string text, string sender)
    {
        if (string.IsNullOrEmpty(text)) return;
        StickyItem = Insert(TextItem(text, sender));
        Changed?.Invoke();
    }

    /// A local text clip written straight into the portal. Never touches the
    /// Windows clipboard.
    public StickyClipItem WriteSticky(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("Text cannot be empty.", nameof(text));
        StickyClipItem stored = Insert(TextItem(text, null));
        StickyItem = stored;
        Changed?.Invoke();
        return stored;
    }

    // MARK: Explicit movement out

    /// Hand a clip back to the Windows clipboard, restoring every flavour it was
    /// captured with. This is the only place Sticky writes to the Windows
    /// clipboard, and only ever because someone clicked.
    public bool CopyToSystemClipboard(StickyClipItem item)
    {
        DataObject data = new();
        switch (item.Kind)
        {
            case StickyClipKind.File:
            {
                StringCollection files = new();
                foreach (string path in item.FilePaths)
                {
                    if (File.Exists(path) || Directory.Exists(path)) files.Add(path);
                }
                if (files.Count == 0)
                {
                    LastError = "Those files are no longer on this PC.";
                    return false;
                }
                data.SetFileDropList(files);
                break;
            }

            case StickyClipKind.Image:
            {
                byte[]? png = ImageBytes(item);
                BitmapSource? source = png is null ? null : DecodePng(png);
                if (source is null)
                {
                    LastError = "That image is no longer in Sticky's clipboard.";
                    return false;
                }
                data.SetImage(source);
                break;
            }

            default:
            {
                if (string.IsNullOrEmpty(item.PlainText))
                {
                    LastError = "That clip has no text to hand back.";
                    return false;
                }
                // Richest first: a receiving app takes the first type it
                // recognises, so Word has to meet RTF before it meets the plain
                // fallback, while a plain text box still finds the text below.
                if (item.RtfText is { } rtf) data.SetData(DataFormats.Rtf, rtf);
                if (item.HtmlText is { } html) data.SetData(DataFormats.Html, html);
                data.SetData(DataFormats.UnicodeText, item.PlainText);
                break;
            }
        }

        if (!TrySetClipboard(data))
        {
            LastError = "Windows would not accept that clip — another app is holding the clipboard.";
            return false;
        }

        StickyItem = item;
        LastError = null;
        Changed?.Invoke();
        return true;
    }

    /// Legacy entry point. Resolves back to the typed clip so a formatted clip
    /// keeps its formatting even when the caller only had a text row.
    public void Promote(StickyClipEntry entry)
    {
        if (Item(entry) is { } item)
        {
            CopyToSystemClipboard(item);
            return;
        }

        DataObject data = new();
        data.SetData(DataFormats.UnicodeText, entry.Text);
        if (!TrySetClipboard(data)) LastError = "Windows rejected the clipboard promotion.";
    }

    /// What the app layer should actually send for this clip.
    public StickyClipSendPayload? SendPayload(StickyClipItem item)
    {
        switch (item.Kind)
        {
            case StickyClipKind.Text:
            case StickyClipKind.RichText:
                // The v1 wire format carries plain text only — the RTF and HTML
                // flavours stay on this PC until the envelope can describe them.
                if (string.IsNullOrEmpty(item.PlainText))
                {
                    LastError = "That clip has no text to send.";
                    return null;
                }
                return new StickyClipSendPayload.Text(item.PlainText);

            case StickyClipKind.Image:
            {
                string? staged = ExportForSending(item);
                return staged is null ? null : new StickyClipSendPayload.Files([staged]);
            }

            default:
            {
                string[] existing = item.FilePaths
                    .Where(path => File.Exists(path) || Directory.Exists(path))
                    .ToArray();
                if (existing.Length == 0)
                {
                    LastError = "Those files are no longer on this PC.";
                    return null;
                }
                return new StickyClipSendPayload.Files(existing);
            }
        }
    }

    // MARK: History management

    public void TogglePin(StickyClipItem item)
    {
        int index = _items.FindIndex(candidate => candidate.Id == item.Id);
        if (index < 0) return;
        StickyClipItem pinned = _items[index] with { Pinned = !_items[index].Pinned };
        _items[index] = pinned;
        if (StickyItem?.Id == pinned.Id) StickyItem = pinned;
        EvictIfNeeded();
        Persist();
        Changed?.Invoke();
    }

    public void Delete(StickyClipItem item)
    {
        _items.RemoveAll(candidate => candidate.Id == item.Id);
        if (StickyItem?.Id == item.Id) StickyItem = _items.FirstOrDefault();
        Persist();
        Changed?.Invoke();
    }

    /// Clears everything, pinned included: a "Clear" that quietly leaves rows
    /// behind is worse than one that does what it says.
    public void ClearHistory()
    {
        _items.Clear();
        StickyItem = null;
        Persist();
        Changed?.Invoke();
    }

    // MARK: Image payloads

    public byte[]? ImageBytes(StickyClipItem item)
    {
        if (item.ImageBlobName is not { } name) return null;
        try
        {
            string path = Path.Combine(BlobDirectory, name);
            if (!File.Exists(path)) return null;
            return ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// Stage an image clip as a real file so it can travel the existing file
    /// channel. Staged in the temp directory, not the blob store, because the
    /// send path may outlive the clip.
    private string? ExportForSending(StickyClipItem item)
    {
        byte[]? png = ImageBytes(item);
        if (png is null)
        {
            LastError = "That image is no longer in Sticky's clipboard.";
            return null;
        }

        try
        {
            string directory = Path.Combine(Path.GetTempPath(), "Sticky-clips");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, $"{item.Id:N}.png");
            File.WriteAllBytes(path, png);
            return path;
        }
        catch (Exception)
        {
            LastError = "The image could not be prepared for sending.";
            return null;
        }
    }

    // MARK: The "do not store" conventions

    private static bool IsMarkedPrivate(IDataObject data)
    {
        try
        {
            if (data.GetDataPresent(ExcludeFromMonitoringFormat, false)) return true;
        }
        catch (Exception)
        {
            // A data object that will not answer questions about itself is not
            // one to copy out of.
            return true;
        }

        return !AllowsFlag(data, ClipboardHistoryFormat) || !AllowsFlag(data, CloudClipboardFormat);
    }

    /// Absent means the app made no objection. Present means it did, and the
    /// DWORD says which way. Present-but-unreadable is read as "no".
    private static bool AllowsFlag(IDataObject data, string format)
    {
        object? value;
        try
        {
            if (!data.GetDataPresent(format, false)) return true;
            value = data.GetData(format, false);
        }
        catch (Exception)
        {
            return false;
        }

        return ReadDword(value) is { } flag && flag != 0;
    }

    private static uint? ReadDword(object? value)
    {
        switch (value)
        {
            case null:
                return null;
            case int number:
                return unchecked((uint)number);
            case uint number:
                return number;
            case byte[] bytes:
                return bytes.Length >= 4 ? BitConverter.ToUInt32(bytes, 0) : null;
            case MemoryStream memory:
                return ReadDword(memory.ToArray());
            case Stream stream:
                return ReadDwordFromStream(stream);
            case string text:
                return uint.TryParse(text, out uint parsed) ? parsed : null;
            default:
                return null;
        }
    }

    private static uint? ReadDwordFromStream(Stream stream)
    {
        try
        {
            if (stream.CanSeek) stream.Position = 0;
            byte[] buffer = new byte[4];
            int read = 0;
            while (read < buffer.Length)
            {
                int step = stream.Read(buffer, read, buffer.Length - read);
                if (step <= 0) break;
                read += step;
            }
            return read == buffer.Length ? BitConverter.ToUInt32(buffer, 0) : null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    // MARK: Capture

    private sealed record ClipCapture(StickyClipItem Item, byte[]? ImagePayload);

    private ClipCapture? CaptureFrom(IDataObject data)
    {
        DateTimeOffset now = DateTimeOffset.UtcNow;

        // Files first: an Explorer copy also carries an icon bitmap, and the
        // icon is not what the user copied.
        string[] paths = FileDropPaths(data);
        if (paths.Length > 0)
        {
            long total = 0;
            foreach (string path in paths)
            {
                try
                {
                    if (File.Exists(path)) total += new FileInfo(path).Length;
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
            }

            string name = paths.Length == 1 ? Path.GetFileName(paths[0]) : $"{paths.Length} files";
            if (string.IsNullOrEmpty(name)) name = "File";
            string identity = string.Join(
                '\u001f',
                paths.OrderBy(path => path, StringComparer.OrdinalIgnoreCase));

            StickyClipItem fileItem = new(
                Guid.NewGuid(), StickyClipKind.File, now, null, false,
                name, total > 0 ? total : null,
                string.Join(Environment.NewLine, paths), null, null,
                null, null, null, paths,
                Fingerprint(StickyClipKind.File, Encoding.UTF8.GetBytes(identity)));
            return new ClipCapture(fileItem, null);
        }

        (byte[] Png, int Width, int Height)? captured = PngFrom(data);
        if (captured.HasValue)
        {
            byte[] png = captured.Value.Png;
            int width = captured.Value.Width;
            int height = captured.Value.Height;
            if (png.Length > MaximumImageBytes)
            {
                LastError = "That image is too large for Sticky's clipboard.";
                return null;
            }

            Guid id = Guid.NewGuid();
            StickyClipItem imageItem = new(
                id, StickyClipKind.Image, now, null, false,
                $"Image {width} × {height}", png.Length,
                // A label, not content: nothing may mistake this for the image.
                null, null, null,
                $"{id:N}.bin", width, height, [],
                Fingerprint(StickyClipKind.Image, png));
            return new ClipCapture(imageItem, png);
        }

        string? rtf = ReadString(data, DataFormats.Rtf);
        string? html = ReadString(data, DataFormats.Html);
        string? plain = ReadString(data, DataFormats.UnicodeText) ?? ReadString(data, DataFormats.Text);

        // An RTF-only copy still needs a fallback, or pasting it into a plain
        // text field later would produce nothing.
        if (plain is null && rtf is not null) plain = PlainTextFromRtf(rtf);
        if (string.IsNullOrWhiteSpace(plain)) return null;

        if (Encoding.UTF8.GetByteCount(plain) > MaximumInlineTextBytes)
        {
            LastError = "That text is too large for Sticky's clipboard.";
            return null;
        }

        // Oversized markup is dropped rather than refused: the plain fallback is
        // still a perfectly good clip, and the index stays small.
        string? keptRtf = rtf is not null && Encoding.UTF8.GetByteCount(rtf) <= MaximumInlineTextBytes ? rtf : null;
        string? keptHtml = html is not null && Encoding.UTF8.GetByteCount(html) <= MaximumInlineTextBytes ? html : null;
        bool rich = keptRtf is not null || keptHtml is not null;

        StringBuilder identityBuilder = new(plain);
        if (keptRtf is not null) identityBuilder.Append(keptRtf);
        if (keptHtml is not null) identityBuilder.Append(keptHtml);
        byte[] identityBytes = Encoding.UTF8.GetBytes(identityBuilder.ToString());

        StickyClipKind kind = rich ? StickyClipKind.RichText : StickyClipKind.Text;
        StickyClipItem textItem = new(
            Guid.NewGuid(), kind, now, null, false,
            PreviewFor(plain), identityBytes.Length,
            plain, keptRtf, keptHtml,
            null, null, null, [],
            Fingerprint(kind, identityBytes));
        return new ClipCapture(textItem, null);
    }

    private static string[] FileDropPaths(IDataObject data)
    {
        try
        {
            if (!data.GetDataPresent(DataFormats.FileDrop, true)) return [];
            if (data.GetData(DataFormats.FileDrop, true) is not string[] paths) return [];
            return paths
                .Where(path => !string.IsNullOrWhiteSpace(path))
                .Take(MaximumFilePaths)
                .ToArray();
        }
        catch (Exception)
        {
            return [];
        }
    }

    /// Everything is normalised to PNG so the store has one image format and the
    /// Mac side has one thing to decode.
    private static (byte[] Png, int Width, int Height)? PngFrom(IDataObject data)
    {
        BitmapSource? source = null;
        try
        {
            if (data.GetDataPresent(DataFormats.Bitmap, true)) source = data.GetData(DataFormats.Bitmap, true) as BitmapSource;
        }
        catch (Exception)
        {
            source = null;
        }

        if (source is null)
        {
            try
            {
                source = Clipboard.GetImage();
            }
            catch (Exception)
            {
                return null;
            }
        }

        if (source is null) return null;

        try
        {
            PngBitmapEncoder encoder = new();
            encoder.Frames.Add(BitmapFrame.Create(source));
            using MemoryStream buffer = new();
            encoder.Save(buffer);
            return (buffer.ToArray(), source.PixelWidth, source.PixelHeight);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static BitmapSource? DecodePng(byte[] png)
    {
        try
        {
            using MemoryStream stream = new(png);
            BitmapImage image = new();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string? ReadString(IDataObject data, string format)
    {
        try
        {
            if (!data.GetDataPresent(format, true)) return null;
            object? value = data.GetData(format, true);
            return value switch
            {
                string text when text.Length > 0 => text,
                MemoryStream memory => DecodeStream(memory),
                _ => null
            };
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string? DecodeStream(MemoryStream memory)
    {
        byte[] bytes = memory.ToArray();
        if (bytes.Length == 0) return null;
        string text = Encoding.UTF8.GetString(bytes).TrimEnd('\0');
        return text.Length == 0 ? null : text;
    }

    private static string? PlainTextFromRtf(string rtf)
    {
        try
        {
            FlowDocument document = new();
            TextRange range = new(document.ContentStart, document.ContentEnd);
            using MemoryStream stream = new(Encoding.UTF8.GetBytes(rtf));
            range.Load(stream, DataFormats.Rtf);
            return range.Text;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static StickyClipItem TextItem(string text, string? sender)
    {
        byte[] payload = Encoding.UTF8.GetBytes(text);
        return new StickyClipItem(
            Guid.NewGuid(), StickyClipKind.Text, DateTimeOffset.UtcNow, sender, false,
            PreviewFor(text), payload.Length,
            text, null, null,
            null, null, null, [],
            Fingerprint(StickyClipKind.Text, payload));
    }

    /// A preview reads from the front, so it loses its tail. Newlines collapse:
    /// a row is one line high and a wrapped snippet would push the list around.
    private static string PreviewFor(string text, int limit = 90)
    {
        string flattened = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (flattened.Length == 0) return "(blank)";
        return flattened.Length <= limit ? flattened : $"{flattened[..(limit - 1)]}…";
    }

    private static string Fingerprint(StickyClipKind kind, byte[] payload)
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        hash.AppendData(Encoding.UTF8.GetBytes(kind.ToString().ToLowerInvariant()));
        hash.AppendData(payload);
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    // MARK: Insertion

    private StickyClipItem Insert(StickyClipItem candidate)
    {
        int existing = _items.FindIndex(item => item.Id == candidate.Id);
        if (existing >= 0)
        {
            _items.RemoveAt(existing);
            _items.Insert(0, candidate);
            Persist();
            return candidate;
        }

        // Same content twice is one clip that moved back to the top, not two
        // rows. A pin already on it survives — the user pinned the content.
        int duplicate = _items.FindIndex(item => string.Equals(item.Fingerprint, candidate.Fingerprint, StringComparison.Ordinal));
        if (duplicate >= 0)
        {
            StickyClipItem previous = _items[duplicate];
            StickyClipItem refreshed = candidate with
            {
                Id = previous.Id,
                Sender = candidate.Sender ?? previous.Sender,
                Pinned = previous.Pinned,
                // Keep the blob already on disk; the freshly written one is
                // unreferenced and PruneBlobs takes it.
                ImageBlobName = previous.ImageBlobName ?? candidate.ImageBlobName
            };
            _items.RemoveAt(duplicate);
            _items.Insert(0, refreshed);
            Persist();
            return refreshed;
        }

        _items.Insert(0, candidate);
        EvictIfNeeded();
        Persist();
        return candidate;
    }

    /// Evicts oldest-first and skips pinned clips. If everything is pinned the
    /// list is allowed to exceed the cap: dropping something the user explicitly
    /// held on to would be the worse failure.
    private void EvictIfNeeded()
    {
        int overflow = _items.Count - MaximumEntries;
        if (overflow <= 0) return;
        for (int index = _items.Count - 1; index >= 0 && overflow > 0; index--)
        {
            if (_items[index].Pinned) continue;
            _items.RemoveAt(index);
            overflow--;
        }
    }

    // MARK: Persistence

    private void Load()
    {
        try
        {
            if (!File.Exists(StorePath)) return;
            byte[] plain = ProtectedData.Unprotect(
                File.ReadAllBytes(StorePath), null, DataProtectionScope.CurrentUser);
            StickyClipStore? stored = JsonSerializer.Deserialize<StickyClipStore>(plain, _json);
            if (stored is null || stored.Version != StoreVersion)
            {
                Quarantine();
                return;
            }

            foreach (StickyClipItem item in stored.Items)
            {
                // A row whose blob went missing can never draw itself, so it is
                // not restored.
                if (item.ImageBlobName is { } name && !File.Exists(Path.Combine(BlobDirectory, name))) continue;
                _items.Add(item);
            }

            EvictIfNeeded();
            StickyItem = _items.FirstOrDefault();
        }
        catch (Exception ex)
        {
            LastError = $"Saved clipboard history could not be read: {ex.Message}";
            Quarantine();
        }
    }

    private void Quarantine()
    {
        _items.Clear();
        StickyItem = null;
        try
        {
            if (!File.Exists(StorePath)) return;
            string aside = Path.Combine(SupportDirectory, $"clipboard-items.corrupted-{Guid.NewGuid():N}.bin");
            File.Move(StorePath, aside, true);
        }
        catch (Exception)
        {
        }
    }

    private void Persist()
    {
        try
        {
            Directory.CreateDirectory(SupportDirectory);
            byte[] plain = JsonSerializer.SerializeToUtf8Bytes(new StickyClipStore(StoreVersion, _items.ToArray()), _json);
            // History holds whatever the user chose to carry, so it is sealed to
            // this Windows account rather than left readable on disk.
            byte[] protectedBytes = ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);
            string temporary = StorePath + ".tmp";
            File.WriteAllBytes(temporary, protectedBytes);
            File.Move(temporary, StorePath, true);
        }
        catch (Exception ex)
        {
            LastError = $"Clipboard history could not be saved: {ex.Message}";
        }

        PruneBlobs();
    }

    /// Blobs are owned by the index. Anything the index no longer names is an
    /// evicted, deleted or deduplicated image, and it goes now rather than
    /// living on as an orphaned copy of something the user deleted.
    private void PruneBlobs()
    {
        try
        {
            if (!Directory.Exists(BlobDirectory)) return;
            HashSet<string> referenced = new(StringComparer.OrdinalIgnoreCase);
            foreach (StickyClipItem item in _items)
            {
                if (item.ImageBlobName is { } name) referenced.Add(name);
            }

            foreach (string file in Directory.EnumerateFiles(BlobDirectory))
            {
                if (referenced.Contains(Path.GetFileName(file))) continue;
                try
                {
                    File.Delete(file);
                }
                catch (IOException)
                {
                }
                catch (UnauthorizedAccessException)
                {
                }
            }
        }
        catch (Exception)
        {
        }
    }

    private static bool WriteBlob(byte[] payload, string name)
    {
        try
        {
            Directory.CreateDirectory(BlobDirectory);
            byte[] protectedBytes = ProtectedData.Protect(payload, null, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(Path.Combine(BlobDirectory, name), protectedBytes);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool TrySetClipboard(DataObject data)
    {
        // The clipboard is a single global lock that any app can be holding for
        // a few milliseconds, so a first failure is not an answer.
        for (int attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                Clipboard.SetDataObject(data, true);
                return true;
            }
            catch (Exception)
            {
                Thread.Sleep(60);
            }
        }

        return false;
    }

    private static string SupportDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sticky");

    private static string StorePath => Path.Combine(SupportDirectory, "clipboard-items.bin");

    private static string BlobDirectory => Path.Combine(SupportDirectory, "clipboard-blobs");

    public void Dispose() => Stop();
}
