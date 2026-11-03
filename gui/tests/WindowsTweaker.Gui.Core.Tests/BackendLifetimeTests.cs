using System.Diagnostics;
using System.Text.Json;
using WindowsTweaker.Gui.Core.Bridge;
using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.Protocol;
using WindowsTweaker.Gui.Core.ViewModels;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// The backend-lifetime regressions: what happens when the process dies, when a session is
/// replaced, and how a reconnect must behave. These run against the real bridge host, so a
/// change on either side of the contract fails here instead of only in the GUI.
/// </summary>
[Collection("bridge")]
public sealed class BackendLifetimeTests
{
    private static readonly TimeSpan Origin = TimeSpan.FromSeconds(30);

    /// <summary>The frontend's mutating operations: none of them may run during a reconnect.</summary>
    private static readonly string[] MutatingOperations =
    {
        "apply.batch",
        "rollback",
        "session.restore",
        "slmgr.request",
        "exttool.activate",
        "exttool.download",
        "exttool.remove",
        "restart.invoke",
        "restorepoint.create",
    };

    /// <summary>True while the operating system still has a live process with this id.</summary>
    private static bool IsAlive(int processId)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            return !process.HasExited;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>
    /// Ends the backend process the runner owns, the way an unexpected process death looks
    /// to the app. The process is identified by the id the runner itself reports, and it is
    /// only killed when it is still a PowerShell host, so a recycled id can never be aimed
    /// at an unrelated process (a Windows system process would take the machine down).
    /// </summary>
    /// <remarks>
    /// The operating-system exit code is deliberately not read here: a <see cref="Process"/>
    /// object created for an id it did not start cannot report one on every platform. What
    /// the app observed is asserted instead (<see cref="ShellViewModel.ConnectionExitCode"/>),
    /// which is the behaviour under test.
    /// </remarks>
    private static void KillBackend(int processId)
    {
        using var process = Process.GetProcessById(processId);
        var name = process.ProcessName;
        Assert.True(
            name.Equals("powershell", StringComparison.OrdinalIgnoreCase)
                || name.Equals("pwsh", StringComparison.OrdinalIgnoreCase),
            $"refusing to kill process {processId}: '{name}' is not a PowerShell host");
        process.Kill();
        process.WaitForExit(15000);
    }

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline && !condition())
        {
            await Task.Delay(100);
        }
    }

    [SkippableFact]
    public async Task BackendExitAfterAHandshakeIsDetectedAndDisablesCommands()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        var exits = new List<int>();
        var stateChanges = new List<ConnectionState>();
        shell.Runner.Exited += (_, code) => exits.Add(code);
        shell.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ShellViewModel.Connection))
            {
                stateChanges.Add(shell.Connection);
            }
        };

        await LiveShell.ConnectAsync(shell);
        await shell.NavigateAsync(Workspace.Overview);
        Assert.Equal(ConnectionState.Ready, shell.Connection);
        Assert.True(shell.IsConnected);
        Assert.True(shell.Review.CanApply is false); // nothing staged yet
        Assert.True(shell.Overview.TweakCount > 0);

        var backend = shell.Runner.BackendProcessId;
        Assert.NotNull(backend);
        KillBackend(backend!.Value);
        await WaitUntilAsync(() => !shell.IsConnected, TimeSpan.FromSeconds(15));

        // The exit is reflected immediately: the badge state is Disconnected, the last exit
        // code is known, and commands that need the backend are disabled.
        Assert.False(shell.IsConnected);
        Assert.Equal(ConnectionState.Disconnected, shell.Connection);
        Assert.Single(exits);
        Assert.Equal(exits[0], shell.ConnectionExitCode);
        Assert.NotEqual(0, exits[0]);
        Assert.Contains(ConnectionState.Disconnected, stateChanges);
        Assert.True(shell.IsDisconnected);
        Assert.True(shell.RecoveryVisible);
        Assert.True(shell.CanReconnect);

        Assert.False(shell.Review.CanApply);
        Assert.False(shell.Review.CanPreview);
        Assert.False(shell.History.CanRestore);
        Assert.False(shell.Licensing.CanActivate);

        // The next call never throws and reports the disconnect, not a timeout.
        var outcome = await shell.Runner.RunAsync("env.status", Projections.Environment, timeout: Origin);
        Assert.False(outcome.Ok);
        Assert.Equal(ProtocolConstants.ErrorCode.BackendDown, outcome.Code);
        Assert.False(IsAlive(backend.Value));
    }

    [SkippableFact]
    public async Task RetryMakesExactlyOneNewConnectionAndReloadsReadOnlyData()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        var operations = new List<string>();
        shell.Runner.Activity += (_, activity) => operations.Add(activity.Operation);

        await LiveShell.ConnectAsync(shell);
        await shell.NavigateAsync(Workspace.Overview);
        var firstBackend = shell.Runner.BackendProcessId;
        Assert.NotNull(firstBackend);
        Assert.True(IsAlive(firstBackend!.Value));

        // Seed a staged review selection: a reconnect must keep it. The tweak is chosen by
        // the engine's own eligibility rule (not "the first row"), because staging a tweak
        // the engine refuses is exactly what the eligibility check now prevents. A host
        // where the engine offers nothing applicable (this suite also runs on Linux, where
        // the Windows tweaks are unsupported) asserts the refusal instead, so the check is
        // covered either way.
        await shell.NavigateAsync(Workspace.Tweaks);
        Assert.True(shell.Tweaks.States.Count > 0);
        var tweak = shell.Tweaks.States.FirstOrDefault(row => row.CanRun && row.StateNames.Count > 0);
        if (tweak is not null)
        {
            shell.Tweaks.Selected = tweak;
            shell.Tweaks.TargetState = tweak.StateNames.First();
            Assert.Null(shell.Tweaks.StageSelection());
        }
        else
        {
            var refused = shell.Tweaks.States.First();
            shell.Tweaks.Selected = refused;
            shell.Tweaks.TargetState = refused.StateNames.FirstOrDefault() ?? string.Empty;
            var refusal = shell.Tweaks.StageSelection();
            Assert.False(string.IsNullOrWhiteSpace(refusal), "an ineligible tweak must be refused with a reason");
            Assert.False(shell.Tweaks.CanStage);
        }

        var staged = shell.Review.Changes.ToList();
        Assert.Equal(shell.Tweaks.States.Any(row => row.CanRun && row.StateNames.Count > 0) ? 1 : 0, staged.Count);

        var generationBefore = shell.Runner.Generation;
        operations.Clear();
        KillBackend(firstBackend.Value);
        await WaitUntilAsync(() => !shell.IsConnected, TimeSpan.FromSeconds(15));
        Assert.True(shell.Overview.IsStale, "data read from the dead session must be marked stale");

        var failure = await shell.ReconnectAsync();

        Assert.Null(failure);
        Assert.Equal(ConnectionState.Ready, shell.Connection);
        Assert.True(shell.Runner.Generation > generationBefore);

        // Exactly one backend: the new one, never the old one plus a new one.
        var secondBackend = shell.Runner.BackendProcessId;
        Assert.NotNull(secondBackend);
        Assert.NotEqual(firstBackend.Value, secondBackend!.Value);
        Assert.False(IsAlive(firstBackend.Value), "the replaced backend must not outlive the reconnect");

        Assert.True(shell.Overview.TweakCount > 0);        // catalog loaded before the kill
        Assert.True(shell.Tweaks.States.Count > 0);

        // The visible workspace was reloaded from the new session, so its stale marker is
        // cleared; a workspace that was loaded earlier and not revisited keeps its rows but
        // is marked stale until the user goes back to it.
        Assert.False(shell.Tweaks.IsStale);
        Assert.True(shell.Overview.IsStale);
        Assert.Equal(staged.Select(c => c.Change.Id), shell.Review.Changes.Select(c => c.Change.Id)); // selection kept
        Assert.DoesNotContain(shell.Review.Changes, change => change.Change.Id == "never-staged");

        // Revisiting it reloads the data and clears the marker.
        await shell.NavigateAsync(Workspace.Overview);
        Assert.False(shell.Overview.IsStale);
        Assert.True(shell.Overview.TweakCount > 0);
        Assert.False(shell.HasStaleData);

        // A reconnect reloads read-only data and never replays a mutation.
        Assert.DoesNotContain(operations, op => MutatingOperations.Contains(op, StringComparer.Ordinal));
        Assert.Contains("strings.get", operations);
    }

    [SkippableFact]
    public async Task LateAnswerFromAReplacedConnectionIsRejected()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        var runner = new BridgeRunner();
        Assert.Null(await runner.ConnectAsync(TestPaths.RepositoryRoot));
        var firstBackend = runner.BackendProcessId;
        Assert.NotNull(firstBackend);

        // Start a slow read on the current connection.
        var slow = runner.RunAsync("state.get", Projections.TweakStates, timeout: TimeSpan.FromMinutes(5));
        var generation = runner.Generation;

        // Barrier instead of a timing sleep: the request must be registered and written to
        // the pipe before the session is replaced. ActiveRequestId is set synchronously by
        // RunAsync once SendAsync has handed the request to the session.
        await WaitUntilAsync(() => runner.ActiveRequestId.Length > 0, TimeSpan.FromSeconds(10));
        Assert.Equal(generation, runner.Generation);

        // Replace the session. The old request belongs to the past from here on.
        await runner.StopAsync(allowKill: false, reason: "test replace");
        Assert.True(runner.Generation > generation);
        Assert.Null(await runner.ConnectAsync(TestPaths.RepositoryRoot));
        var secondBackend = runner.BackendProcessId;
        Assert.NotNull(secondBackend);
        Assert.NotEqual(firstBackend!.Value, secondBackend!.Value);

        // Whatever happened to the old request - a late answer, or the old process exiting
        // while it was still pending - it belongs to a replaced connection. The outcome
        // must be StaleConnection, never a current-session error. The error precedence is:
        // an old-generation result never affects the new session, and a current-session
        // exit is still reported as such (covered by BackendExitAfterAHandshake...).
        var outcome = await slow;
        Assert.False(outcome.Ok);
        Assert.Equal(ProtocolConstants.ErrorCode.StaleConnection, outcome.Code);

        // And the new connection still works.
        var fresh = await runner.RunAsync("env.status", Projections.Environment, timeout: Origin);
        Assert.True(fresh.Ok);
        await runner.DisposeAsync();
        await WaitUntilAsync(() => !IsAlive(secondBackend.Value), TimeSpan.FromSeconds(10));
        Assert.False(IsAlive(secondBackend.Value));
    }

    [SkippableFact]
    public async Task ConnectIsIdempotentAndNeverDuplicatesTheProcess()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        await LiveShell.ConnectAsync(shell);
        var hello = shell.Runner.Hello;
        var backend = shell.Runner.BackendProcessId;
        Assert.NotNull(backend);

        // Connecting again while connected is a no-op, not a second session.
        await LiveShell.ConnectAsync(shell);
        Assert.Equal(backend, shell.Runner.BackendProcessId);
        Assert.Same(hello, shell.Runner.Hello);

        await shell.DisposeAsync();
        await WaitUntilAsync(() => !IsAlive(backend!.Value), TimeSpan.FromSeconds(10));
        Assert.False(IsAlive(backend.Value));
    }

    [SkippableFact]
    public async Task FailedElevationHandoffRestoresASessionInsteadOfLeavingTheWindowDead()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        await LiveShell.ConnectAsync(shell);
        await shell.NavigateAsync(Workspace.Overview);
        var beforeHandoff = shell.Runner.BackendProcessId;
        Assert.NotNull(beforeHandoff);

        // The handoff cannot start (the user declined the UAC prompt, or it failed to
        // appear). Forcing it through the seam is what makes this deterministic on every
        // host: no test may raise a real UAC prompt.
        shell.StartElevated = (_, _) => throw new System.ComponentModel.Win32Exception(1223);

        var failure = await shell.RelaunchElevatedAsync();
        Assert.NotNull(failure);
        Assert.Equal(shell.Strings["Gui.Error.ElevationDeclined"], failure);

        await WaitUntilAsync(() => shell.IsConnected, TimeSpan.FromSeconds(15));
        Assert.Equal(ConnectionState.Ready, shell.Connection);

        // The window the user keeps working in is connected again, and the stopped session
        // was not left behind.
        var afterHandoff = shell.Runner.BackendProcessId;
        Assert.NotNull(afterHandoff);
        Assert.True(IsAlive(afterHandoff!.Value));
        Assert.False(IsAlive(beforeHandoff!.Value));
        Assert.True(shell.Overview.TweakCount > 0);
        Assert.False(shell.RecoveryVisible);
    }

    [SkippableFact]
    public async Task EveryAvailablePowerShellHostRunsTheWholeStartupContract()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        // On Windows this covers Windows PowerShell 5.1 (powershell.exe) as well as
        // PowerShell 7; on Linux only pwsh exists. Running the whole sequence per host is
        // what proves the 5.1 claim instead of asserting it.
        //
        // WT_TEST_HOST_PATH restricts the loop to one executable, so each host can be
        // exercised on its own while triaging a failure (the assertion and the sequence are
        // identical either way). Unset - the CI case - every discovered host runs.
        var hosts = PowerShellLocator.Discover();
        var only = Environment.GetEnvironmentVariable("WT_TEST_HOST_PATH");
        if (!string.IsNullOrWhiteSpace(only))
        {
            var full = Path.GetFullPath(only);
            hosts = hosts.Where(host => string.Equals(host.Path, full, StringComparison.OrdinalIgnoreCase)).ToList();
        }

        Assert.NotEmpty(hosts);

        var verified = new List<string>();
        foreach (var host in hosts)
        {
            // Every stage is labelled with the exact executable, version, edition, bitness
            // and the stage name, so a failure names the host that failed instead of
            // leaving the reader to guess which of the discovered hosts it was.
            var identity = $"{host.Path} | {host.Version} ({host.Edition})";
            string? stage = null;
            try
            {
                stage = "start";
                await using var session = await BridgeSession.StartAsync(
                    TestPaths.RepositoryRoot,
                    hostPath: host.Path,
                    handshakeTimeout: TimeSpan.FromSeconds(90));

                stage = "handshake";
                Assert.Equal(ProtocolConstants.Version, session.Hello.Protocol);

                stage = "strings.get";
                var strings = await session.SendAsync("strings.get", timeout: TimeSpan.FromSeconds(120));
                var (languages, active, tables) = Projections.Strings(strings);
                Assert.Contains("en", languages);
                Assert.Contains("vi", languages);
                Assert.Contains(active, languages);
                Assert.True(tables["en"].Count > 1000, $"{host.Label}: the English table looks truncated");

                stage = "catalog.list";
                var catalog = await session.SendAsync("catalog.list", timeout: TimeSpan.FromSeconds(120));
                var (categories, tweaks) = Projections.Catalog(catalog);
                Assert.Equal(10, categories.Count);
                Assert.True(tweaks.Count >= 100, $"{host.Label}: expected the whole catalog, got {tweaks.Count}");

                stage = "env.status";
                var environment = await session.SendAsync("env.status", timeout: TimeSpan.FromSeconds(120));
                var (status, runtime) = Projections.Environment(environment);
                Assert.False(string.IsNullOrEmpty(status.PowerShellVersion));
                Assert.NotNull(runtime);

                stage = "shutdown";
                Assert.Equal(ShutdownOutcome.Clean, await session.ShutdownAsync(allowKill: false));
                verified.Add($"{host.Label} [{host.Path}]");
            }
            catch (Exception exception)
            {
                // The host and the stage are part of the failure, together with the stderr
                // tail the host itself wrote (PSHOME, module path, command availability).
                throw new Xunit.Sdk.XunitException(
                    $"host {identity} failed at stage '{stage}': {exception.GetType().Name}: {exception.Message}");
            }
        }

        Assert.NotEmpty(verified);
    }

    [SkippableFact]
    public async Task LanguageSelectionRoundTripsAndTheSelectorShowsIt()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        await LiveShell.ConnectAsync(shell);

        // The selector's items are the engine's languages with display names - never the raw
        // codes as the only text - and the active one is selected, so it can never be blank.
        Assert.Equal(2, shell.AvailableLanguages.Count);
        Assert.Contains(shell.AvailableLanguages, option => option.Code == "en" && option.DisplayName == "English");
        Assert.Contains(shell.AvailableLanguages, option => option.Code == "vi" && option.DisplayName == "Tiếng Việt");
        Assert.NotNull(shell.SelectedLanguage);
        Assert.Equal(shell.Strings.Active, shell.SelectedLanguage!.Code);

        var target = shell.AvailableLanguages.First(option => option.Code != shell.Strings.Active);
        await shell.SetLanguageAsync(target.Code);

        Assert.Equal(target.Code, shell.Strings.Active);
        Assert.Equal(target.Code, shell.SelectedLanguage!.Code);
        Assert.False(string.IsNullOrWhiteSpace(shell.ConnectionLabel));
        Assert.Equal(target.Code, (await shell.Runner.RunAsync("strings.get", Projections.Strings, timeout: Origin)).Value.Active);
    }

    [SkippableFact]
    public async Task FailedLoadNeverRendersAsAnEmptyListAndCommandsAreDisabledWhenDisconnected()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        await LiveShell.ConnectAsync(shell);

        // A healthy load: rows are there and no empty message is shown.
        await shell.NavigateAsync(Workspace.Tweaks);
        Assert.Equal(LoadState.Ready, shell.Tweaks.State);
        Assert.NotEmpty(shell.Tweaks.States);
        Assert.False(shell.Tweaks.ShowFilteredEmpty);
        Assert.False(shell.Tweaks.ShowCatalogEmpty);

        // A filter that matches nothing: the filtered-empty message, and only that.
        shell.Tweaks.Search = "zzz-no-such-tweak-zzz";
        Assert.True(shell.Tweaks.ShowFilteredEmpty);
        Assert.False(shell.Tweaks.ShowCatalogEmpty);
        Assert.False(shell.Tweaks.IsFailed);
        Assert.False(shell.Tweaks.IsLoading);
        shell.Tweaks.Search = string.Empty;

        // A failed load: the failure state, never an "empty filter" message next to it.
        var backend = shell.Runner.BackendProcessId;
        Assert.NotNull(backend);
        KillBackend(backend!.Value);
        await WaitUntilAsync(() => !shell.IsConnected, TimeSpan.FromSeconds(15));
        await shell.Tweaks.RetryAsync();

        Assert.Equal(LoadState.Failed, shell.Tweaks.State);
        Assert.True(shell.Tweaks.IsFailed);
        Assert.True(shell.Tweaks.HasError);
        Assert.False(shell.Tweaks.ShowFilteredEmpty);
        Assert.False(shell.Tweaks.ShowCatalogEmpty);

        // The message comes from the engine's tables (localized), while the code and the raw
        // engine text are kept separately for the technical detail section.
        Assert.Equal(shell.Strings["Gui.BackendDown"], shell.Tweaks.ErrorText);
        Assert.StartsWith("BackendDown", shell.Tweaks.ErrorDetail, StringComparison.Ordinal);
        Assert.NotEqual(shell.Tweaks.ErrorText, shell.Tweaks.ErrorDetail);

        // The connection state, not the request, decides eligibility.
        Assert.False(shell.Review.CanApply);
        Assert.False(shell.Review.CanPreview);
        Assert.False(shell.History.CanRestore);
        Assert.False(shell.Licensing.CanActivate);
        Assert.False(shell.Licensing.CanDownload);
        Assert.True(shell.RecoveryVisible);
    }
}
