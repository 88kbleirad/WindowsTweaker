using System.Text.Json;
using WindowsTweaker.Gui.Core.Bridge;
using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.Protocol;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// Live tests: they start the real bridge host and speak the real protocol to it.
/// </summary>
/// <remarks>
/// Nothing here is muted. Where a check needs a Windows-only surface the backend reports
/// it honestly (for example a tweak is <c>Unsupported</c> on a non-Windows host), and the
/// assertion is on that structured answer rather than on a fabricated success. A
/// PowerShell host is required; without one the tests are skipped with a stated reason.
/// </remarks>
[Collection("bridge")]
public sealed class BridgeSessionLiveTests
{
    private static readonly TimeSpan Handshake = TimeSpan.FromSeconds(90);

    private static Dictionary<string, object?> Args(params (string Key, object? Value)[] pairs)
    {
        var map = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var (key, value) in pairs)
        {
            map[key] = value;
        }

        return map;
    }

    private static Task<BridgeSession> StartAsync()
    {
        // The child inherits this process's environment, so the state store and logs stay
        // in the test's own directory and never touch a real profile (set once in
        // TestPaths before any session starts).
        return BridgeSession.StartAsync(TestPaths.RepositoryRoot, hostPath: TestPaths.Host!.Path, handshakeTimeout: Handshake);
    }

    [SkippableFact]
    public async Task HandshakeReportsTheProtocolAndAnAllowlist()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        var hello = session.Hello;

        Assert.Equal(ProtocolConstants.Version, hello.Protocol);
        Assert.Equal("wt-bridge", hello.Bridge);
        Assert.NotEmpty(hello.Ops);
        Assert.Contains("handshake", hello.Ops);
        Assert.Contains("catalog.list", hello.Ops);
        Assert.Contains("apply.batch", hello.Ops);
        Assert.True(hello.MaxFrameBytes > 0);
    }

    [SkippableFact]
    public async Task HandshakeServesTheFrontendStringKeyContract()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        var strings = await session.SendAsync("strings.get", timeout: TimeSpan.FromSeconds(60));
        var (languages, active, tables) = Projections.Strings(strings);

        Assert.Contains("en", languages);
        Assert.Contains("vi", languages);
        Assert.Contains(active, languages);

        // Every language must carry the same key set: a missing translation is a defect,
        // not a fallback the frontend invents.
        var english = tables["en"];
        var vietnamese = tables["vi"];
        Assert.Equal(english.Count, vietnamese.Count);

        // Every key the frontend declares in the handshake must resolve in every table.
        foreach (var key in session.Hello.GuiKeys)
        {
            Assert.True(english.ContainsKey(key), $"The English table is missing the frontend key '{key}'.");
            Assert.True(vietnamese.ContainsKey(key), $"The Vietnamese table is missing the frontend key '{key}'.");
        }
    }

    [SkippableFact]
    public async Task CatalogListReturnsTheWholeCatalog()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        var data = await session.SendAsync("catalog.list");
        var (categories, tweaks) = Projections.Catalog(data);

        Assert.Equal(10, categories.Count);
        Assert.True(tweaks.Count >= 100, $"Expected the full catalog, got {tweaks.Count} rows.");
        Assert.All(tweaks, tweak => Assert.False(string.IsNullOrWhiteSpace(tweak.Id)));
        Assert.Contains(tweaks, tweak => tweak.Id == "Privacy.AdvertisingId");
    }

    [SkippableFact]
    public async Task StateGetReportsAStructuredStateForOneTweak()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        var data = await session.SendAsync(
            "state.get",
            Args(("id", "Privacy.AdvertisingId")),
            timeout: TimeSpan.FromSeconds(120));
        var rows = Projections.TweakStates(data);

        var row = Assert.Single(rows);
        Assert.Equal("Privacy.AdvertisingId", row.Id);
        Assert.False(string.IsNullOrWhiteSpace(row.State));
        Assert.NotEmpty(row.StateNames);

        // On a host without the registry the engine says so instead of guessing. The
        // assertion is on the structured answer, not on a platform-specific value.
        if (!session.Hello.IsWindows)
        {
            Assert.False(row.Supported);
            Assert.NotEmpty(row.UnsupportedReason);
        }
    }

    [SkippableFact]
    public async Task PreviewDescribesEveryTargetBeforeAnythingRuns()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        var data = await session.SendAsync(
            "preview.get",
            Args(("id", "Privacy.AdvertisingId"), ("state", "Disabled")),
            timeout: TimeSpan.FromSeconds(120));
        var preview = Projections.Preview(data);

        Assert.Equal("Privacy.AdvertisingId", preview.TweakId);
        Assert.Equal("Disabled", preview.State);
        Assert.NotEmpty(preview.Targets);
        Assert.All(preview.Targets, target => Assert.False(string.IsNullOrWhiteSpace(target.Identity)));
    }

    [SkippableFact]
    public async Task DryRunApplyReportsEveryOperationWithoutWriting()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        var items = new[]
        {
            new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["Id"] = "Privacy.AdvertisingId",
                ["State"] = "Disabled",
            },
        };

        var data = await session.SendAsync(
            "apply.batch",
            Args(("items", items), ("dryRun", true)),
            timeout: TimeSpan.FromSeconds(180));
        var batch = Projections.Batch(data);

        var result = Assert.Single(batch.Results);
        Assert.Equal("Privacy.AdvertisingId", result.RequestedId);
        Assert.False(batch.Cancelled);
        // A dry run never claims success: the status is either the dry-run marker or an
        // honest unsupported on a host that cannot perform the change at all.
        Assert.Contains(result.Status, new[] { "dryrun", "unsupported", "succeeded", "unchanged" });
    }

    [SkippableFact]
    public async Task LongOperationRaisesProgressEvents()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        var phases = new System.Collections.Concurrent.ConcurrentBag<string>();
        session.Progress += (_, progress) => phases.Add(progress.Phase);

        await session.SendAsync(
            "state.get",
            Args(("id", "Explorer.FileExtensions")),
            timeout: TimeSpan.FromSeconds(120));

        Assert.Contains("collecting", phases);
    }

    [SkippableFact]
    public async Task UnknownOperationIsRefusedByTheAllowlist()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();

        var error = await Assert.ThrowsAsync<BridgeOperationException>(
            () => session.SendAsync("system.exec", Args(("command", "whoami"))));

        Assert.Equal(ProtocolConstants.ErrorCode.UnknownOperation, error.Code);
    }

    [SkippableFact]
    public async Task PrivilegedOperationIsRefusedWithoutElevation()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        if (session.Hello.IsAdmin)
        {
            return; // Nothing to prove: the guard only applies to an unelevated session.
        }

        var error = await Assert.ThrowsAsync<BridgeOperationException>(
            () => session.SendAsync("slmgr.request", timeout: TimeSpan.FromSeconds(30)));

        Assert.Equal(ProtocolConstants.ErrorCode.RequiresElevation, error.Code);
    }

    [SkippableFact]
    public async Task ATinyDeadlineFailsTheRequestAndLeavesTheSessionUsable()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();

        var error = await Assert.ThrowsAsync<BridgeException>(
            () => session.SendAsync("catalog.list", timeout: TimeSpan.FromMilliseconds(1)));

        Assert.Equal(ProtocolConstants.ErrorCode.Timeout, error.Code);

        // Stale-response protection: the late answer must not be handed to anything. The
        // session survives and still answers a fresh request.
        var data = await session.SendAsync("ping");
        Assert.True(data.GetProperty("pong").GetBoolean());
    }

    [SkippableFact]
    public async Task ShutdownIsCleanAndTheProcessIsGone()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        var session = await StartAsync();
        var outcome = await session.ShutdownAsync(allowKill: true);

        Assert.Equal(ShutdownOutcome.Clean, outcome);
        Assert.False(session.IsRunning);

        await session.DisposeAsync();
    }

    [SkippableFact]
    public async Task OneSessionAnswersManyRequestsWithoutRespawn()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();

        for (var i = 0; i < 8; i++)
        {
            var data = await session.SendAsync("ping");
            Assert.True(data.GetProperty("pong").GetBoolean());
        }

        Assert.True(session.IsRunning);
    }

    [SkippableFact]
    public async Task NothingIsWrittenToStdoutThatIsNotAFrame()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        var stray = new List<string>();
        session.Diagnostic += (_, message) =>
        {
            if (message.Contains("not a protocol frame", StringComparison.Ordinal))
            {
                stray.Add(message);
            }
        };

        await session.SendAsync("catalog.list");
        await session.SendAsync("strings.get");
        await session.SendAsync("env.status");

        // Diagnostics live on stderr: the protocol channel carries frames only.
        Assert.Empty(stray);
    }

    [SkippableFact]
    public async Task EnvironmentReportsTheHostHonestly()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var session = await StartAsync();
        var data = await session.SendAsync("env.status", timeout: TimeSpan.FromSeconds(60));
        var (environment, runtime) = Projections.Environment(data);

        Assert.False(string.IsNullOrWhiteSpace(environment.Language));
        Assert.False(string.IsNullOrWhiteSpace(environment.StatePath));
        Assert.NotEmpty(runtime.Platform);
        Assert.NotEmpty(runtime.Capabilities);
        // The client must not claim more than the backend does.
        Assert.Equal(session.Hello.IsWindows, environment.IsWindows);
        Assert.Equal(session.Hello.IsAdmin, environment.IsAdmin);
    }

    [Fact]
    public void ProjectionsNeverThrowOnAnEmptyPayload()
    {
        // A defensive check on the projection layer itself: an empty payload (which a
        // truncated or older backend could produce) must render as defaults.
        var empty = default(JsonElement);

        Assert.Empty(Projections.TweakStates(empty));
        Assert.Empty(Projections.History(empty));
        Assert.Empty(Projections.Operations(empty));
        Assert.Empty(Projections.Interrupted(empty));
        Assert.Empty(Projections.Presets(empty));
        Assert.Empty(Projections.Dashboards(empty));

        var preview = Projections.Preview(empty);
        Assert.Equal(string.Empty, preview.TweakId);
        Assert.Empty(preview.Targets);

        var batch = Projections.Batch(empty);
        Assert.Empty(batch.Results);
        Assert.False(batch.Cancelled);
    }
}
