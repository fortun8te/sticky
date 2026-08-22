using System.Text.Json.Serialization;

namespace StickyWin;

public enum TransferKind
{
    Files,
    Clipboard,
    Text
}

public sealed record StickyFileMeta(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("mime")] string? Mime,
    [property: JsonPropertyName("previewData")] byte[]? PreviewData = null,
    [property: JsonPropertyName("sha256")] string? Sha256 = null);

public sealed record SenderInfo(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name);

public sealed record TransferRequest(
    [property: JsonPropertyName("session")] string Session,
    [property: JsonPropertyName("sender")] SenderInfo Sender,
    [property: JsonPropertyName("files")] StickyFileMeta[] Files,
    [property: JsonPropertyName("text")] string? Text,
    [property: JsonPropertyName("kind")] TransferKind Kind);

public sealed record PrepareResponse(
    [property: JsonPropertyName("session")] string Session,
    [property: JsonPropertyName("tokens")] Dictionary<string, string> Tokens);

public sealed record CompleteResponse(
    [property: JsonPropertyName("received")] string[] Received);

public enum NotchStateKind
{
    Idle,
    Hover,
    Armed,
    Sending,
    Receiving,
    Success,
    Failure,
    Expanded
}

public sealed record NotchState(
    NotchStateKind Kind,
    double Progress = 0,
    int FileCount = 0,
    string? FileName = null,
    string? Message = null);

public sealed record TransferProgress(double Progress, string? FileName)
{
    public int Percent => Math.Clamp((int)Math.Round(Progress * 100), 0, 100);
}
