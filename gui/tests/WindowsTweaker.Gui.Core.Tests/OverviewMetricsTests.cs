using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.Protocol;
using WindowsTweaker.Gui.Core.ViewModels;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// The overview dashboard's sampling contract, exercised against the real backend.
/// </summary>
/// <remarks>
/// The dashboard is the only place that polls the backend on a timer, so what it is allowed
/// to do is a contract worth testing: one request per sample, one operation
/// (<c>metrics.snapshot</c>), no workspace reload, and nothing running once the user leaves
/// the workspace. The assertions never wait on a fixed sleep alone - they wait for an
/// observed effect, then state what must be true of it.
/// </remarks>
[Collection("bridge")]
public sealed class OverviewMetricsTests
{
    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline && !condition())
        {
            await Task.Delay(50);
        }
    }

    [SkippableFact]
    public async Task OverviewSamplesLocalMetricsWithoutReloadingAnything()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        var operations = new List<string>();
        shell.Runner.Activity += (_, activity) => operations.Add(activity.Operation);

        await LiveShell.ConnectAsync(shell);

        // Sampling is gated on the overview being the visible workspace: leaving it stops
        // the loop, returning to it starts one. (The overview is the default workspace, so
        // it may already be sampling right after connecting - that is the gate working.)
        await shell.NavigateAsync(Workspace.Tweaks);
        await WaitUntilAsync(() => !shell.Overview.MetricsSampling, TimeSpan.FromSeconds(10));
        Assert.False(shell.Overview.MetricsSampling);
        Assert.True(shell.Overview.MetricsPaused);

        await shell.NavigateAsync(Workspace.Overview);
        await WaitUntilAsync(() => shell.Overview.MetricsSampling, TimeSpan.FromSeconds(10));
        Assert.True(shell.Overview.MetricsSampling);

        // Wait for two observed samples rather than guessing at a delay.
        operations.Clear();
        await WaitUntilAsync(
            () => operations.Count(op => op == "metrics.snapshot") >= 2,
            TimeSpan.FromSeconds(20));
        var sampled = operations.Count(op => op == "metrics.snapshot");
        Assert.True(sampled >= 2, $"expected at least two samples, saw {sampled}");

        // A sample is a snapshot and nothing else: no catalog reload, no state scan, no
        // second process. This is what keeps the dashboard from re-running the workspace.
        Assert.DoesNotContain(operations, op => op is not "metrics.snapshot");
        Assert.NotNull(shell.Runner.BackendProcessId);
        Assert.True(shell.Overview.TweakCount > 0, "the catalog panel must survive sampling");

        // A missing measurement is never rendered as a zero.
        if (shell.Overview.CpuQuality != MetricQuality.Valid)
        {
            Assert.DoesNotContain("0", shell.Overview.CpuValueText);
        }

        if (shell.Overview.RamBarVisible)
        {
            Assert.InRange(shell.Overview.RamUsedPercent, 0d, 100d);
        }

        // The trend is bounded and only ever holds measured points.
        Assert.True(
            shell.Overview.CpuTrend.Count <= 60,
            $"the trend must stay bounded, saw {shell.Overview.CpuTrend.Count} points");
        Assert.DoesNotContain(shell.Overview.CpuTrend, value => double.IsNaN(value) || value < 0 || value > 100);

        // Leaving the workspace stops the loop, and no further sample is issued.
        await shell.NavigateAsync(Workspace.Tweaks);
        await WaitUntilAsync(() => !shell.Overview.MetricsSampling, TimeSpan.FromSeconds(10));
        Assert.False(shell.Overview.MetricsSampling);
        Assert.True(shell.Overview.MetricsPaused);

        operations.Clear();
        await WaitUntilAsync(() => operations.Count > 0, TimeSpan.FromMilliseconds(1500));
        Assert.DoesNotContain("metrics.snapshot", operations);
    }

    [SkippableFact]
    public async Task SamplingStopsWhenTheConnectionIsLost()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        await LiveShell.ConnectAsync(shell);
        await shell.NavigateAsync(Workspace.Overview);
        await WaitUntilAsync(() => shell.Overview.MetricsSampling, TimeSpan.FromSeconds(10));
        Assert.True(shell.Overview.MetricsSampling);

        var backend = shell.Runner.BackendProcessId;
        Assert.NotNull(backend);
        using (var process = System.Diagnostics.Process.GetProcessById(backend!.Value))
        {
            var name = process.ProcessName;
            Assert.True(
                name.Equals("powershell", StringComparison.OrdinalIgnoreCase)
                    || name.Equals("pwsh", StringComparison.OrdinalIgnoreCase),
                $"refusing to kill process {backend.Value}: '{name}' is not a PowerShell host");
            process.Kill();
            process.WaitForExit(15000);
        }

        // The loop must notice the dead session and stop instead of polling a corpse.
        await WaitUntilAsync(() => !shell.Overview.MetricsSampling, TimeSpan.FromSeconds(20));
        Assert.False(shell.Overview.MetricsSampling);
        Assert.False(shell.IsConnected);
    }
}
