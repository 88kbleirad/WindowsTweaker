using System.Text.Json;
using WindowsTweaker.Gui.Core.Protocol;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// Pure protocol tests: framing and parsing, with no backend involved. These describe the
/// contract the reader must hold even when the peer misbehaves.
/// </summary>
public sealed class BridgeProtocolTests
{
    [Fact]
    public void ParsesAResultFrame()
    {
        var frame = BridgeFrame.TryParse("""{"type":"result","id":"r1","ok":true,"data":{"pong":true},"meta":null}""");

        Assert.NotNull(frame);
        Assert.Equal(ProtocolConstants.FrameType.Result, frame!.Type);
        Assert.Equal("r1", frame.Id);
        Assert.True(frame.Ok);
        Assert.True(frame.IsTerminal);
        Assert.True(frame.Data.GetProperty("pong").GetBoolean());
    }

    [Fact]
    public void ParsesAnErrorFrame()
    {
        var frame = BridgeFrame.TryParse("""{"type":"error","id":"r7","code":"UnknownOperation","message":"nope"}""");

        Assert.NotNull(frame);
        Assert.Equal(ProtocolConstants.FrameType.Error, frame!.Type);
        Assert.Equal("UnknownOperation", frame.Code);
        Assert.Equal("nope", frame.Message);
        Assert.True(frame.IsTerminal);
    }

    [Fact]
    public void ParsesProgressAndHelloFrames()
    {
        var progress = BridgeFrame.TryParse("""{"type":"progress","id":"r2","phase":"applying","text":"x","item":"A","done":1,"total":3}""");
        Assert.NotNull(progress);
        // Progress frames are self-describing: their fields sit beside `type` at the root.
        Assert.Equal("applying", progress!.Root.GetProperty("phase").GetString());
        Assert.Equal("r2", progress.Id);
        Assert.False(progress.IsTerminal);

        var hello = BridgeFrame.TryParse("""{"type":"hello","protocol":1,"ops":["ping"]}""");
        Assert.NotNull(hello);
        Assert.True(hello!.IsHello);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not json")]
    [InlineData("[1,2,3]")]
    [InlineData("""{"id":"r1"}""")]
    [InlineData("""{"type":""}""")]
    public void RejectsUnusableLines(string line)
    {
        Assert.Null(BridgeFrame.TryParse(line));
    }

    [Fact]
    public void PayloadSurvivesTheDocumentBeingDisposed()
    {
        // TryParse clones the payload, so the caller can hold it after parsing returns.
        var frame = BridgeFrame.TryParse("""{"type":"result","id":"r1","data":{"deep":{"value":42}}}""");

        Assert.NotNull(frame);
        Assert.Equal(42, frame!.Data.GetProperty("deep").GetProperty("value").GetInt32());
    }

    [Fact]
    public void DoesNotThrowOnAValueItDoesNotUnderstand()
    {
        var frame = BridgeFrame.TryParse("""{"type":"notice","kind":"bye","data":{"n":null},"extra":[1,2]}""");

        Assert.NotNull(frame);
        Assert.Equal(JsonValueKind.Object, frame!.Data.ValueKind);
    }
}
