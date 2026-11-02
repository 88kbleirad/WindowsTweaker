using System.Text.Json;

namespace WindowsTweaker.Gui.Core.Protocol;

/// <summary>One decoded protocol frame.</summary>
/// <remarks>
/// The payload is kept as a <see cref="JsonElement"/> rather than being bound to a DTO
/// here: the envelope is small and stable, while the payload shapes are many. The
/// projection layer (<c>Model/Projections.cs</c>) turns an element into a typed model, and
/// the view models never see raw JSON.
/// </remarks>
public sealed class BridgeFrame
{
    private BridgeFrame(string type, string? id, bool? ok, JsonElement root, JsonElement data, JsonElement meta, string? code, string? message)
    {
        Type = type;
        Id = id;
        Ok = ok;
        Root = root;
        Data = data;
        Meta = meta;
        Code = code;
        Message = message;
    }

    /// <summary>One of <see cref="ProtocolConstants.FrameType"/>.</summary>
    public string Type { get; }

    /// <summary>
    /// The whole frame object. It matters because the two self-describing frames carry
    /// their fields at the top level rather than under <c>data</c>: <c>hello</c> (protocol,
    /// engine, ops, limits) and <c>error</c> (code, message). Request answers use
    /// <see cref="Data"/>.
    /// </summary>
    public JsonElement Root { get; }

    /// <summary>Request id this frame answers, when the frame is request-scoped.</summary>
    public string? Id { get; }

    /// <summary>Present on <c>result</c> frames.</summary>
    public bool? Ok { get; }

    /// <summary>Present on <c>result</c> frames (any shape).</summary>
    public JsonElement Data { get; }

    /// <summary>Present on <c>result</c> frames (usually null).</summary>
    public JsonElement Meta { get; }

    /// <summary>Present on <c>error</c> frames.</summary>
    public string? Code { get; }

    /// <summary>Present on <c>error</c> frames and <c>hello</c>/<c>notice</c> text.</summary>
    public string? Message { get; }

    /// <summary>True when the frame is a <c>hello</c> handshake.</summary>
    public bool IsHello => Type == ProtocolConstants.FrameType.Hello;

    /// <summary>True when the frame is a terminal answer to a request.</summary>
    public bool IsTerminal => Type is ProtocolConstants.FrameType.Result or ProtocolConstants.FrameType.Error;

    /// <summary>
    /// Parses one line. Returns null when the line is not a usable frame - the caller
    /// reports that instead of throwing, because a malformed line must never take the
    /// session down.
    /// </summary>
    public static BridgeFrame? TryParse(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            var type = root.TryGetProperty("type", out var typeElement) && typeElement.ValueKind == JsonValueKind.String
                ? typeElement.GetString() ?? string.Empty
                : string.Empty;
            if (type.Length == 0)
            {
                return null;
            }

            string? id = root.TryGetProperty("id", out var idElement) && idElement.ValueKind == JsonValueKind.String
                ? idElement.GetString()
                : null;

            bool? ok = root.TryGetProperty("ok", out var okElement) && okElement.ValueKind is JsonValueKind.True or JsonValueKind.False
                ? okElement.GetBoolean()
                : null;

            string? code = root.TryGetProperty("code", out var codeElement) && codeElement.ValueKind == JsonValueKind.String
                ? codeElement.GetString()
                : null;

            string? message = root.TryGetProperty("message", out var msgElement) && msgElement.ValueKind == JsonValueKind.String
                ? msgElement.GetString()
                : null;

            // Clone so the elements stay valid after the document is disposed.
            var clonedRoot = root.Clone();
            var data = root.TryGetProperty("data", out var dataElement) ? dataElement.Clone() : default;
            var meta = root.TryGetProperty("meta", out var metaElement) ? metaElement.Clone() : default;

            return new BridgeFrame(type, id, ok, clonedRoot, data, meta, code, message);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>A progress frame's decoded fields (only the ones the UI renders).</summary>
public sealed record BridgeProgress(string Id, string Phase, string Text, string? Item, int? Done, int? Total);

/// <summary>A backend lifecycle notice.</summary>
public sealed record BridgeNotice(string Kind);
