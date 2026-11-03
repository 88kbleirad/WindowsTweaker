using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using WindowsTweaker.Gui.Core.Bridge;
using WindowsTweaker.Gui.Core.Model;

namespace WindowsTweaker.Gui.Core.ViewModels;

/// <summary>
/// The window's whole state: the backend session, the workspaces, the header, the status
/// bars and the closing rules.
/// </summary>
/// <remarks>
/// The shell owns two behaviours the individual views must not re-implement:
/// <list type="bullet">
/// <item><b>staying responsive</b>: it subscribes to progress on the reader task and moves
/// each update to the UI thread through <see cref="Dispatch"/>, so a view never blocks on
/// the backend;</item>
/// <item><b>safe closing</b>: <see cref="TryCloseAsync"/> refuses to abandon a mutating
/// operation, and only ever stops the backend at a boundary.</item>
/// </list>
/// </remarks>
public sealed class ShellViewModel : ObservableObject, IAsyncDisposable
{
    private readonly string _repositoryRoot;
    private Workspace _current = Workspace.Overview;
    private EnvironmentStatus? _environment;
    private RuntimeStatus? _runtime;
    private string _statusText = string.Empty;
    private string _progressText = string.Empty;
    private string _backendSummary = string.Empty;
    private string _initializationError = string.Empty;
    private string _engineVersion = string.Empty;
    private InitializationState _initialization = InitializationState.Loading;
    private bool _busy;
    private bool _connected;
    private bool _reduceMotion;
    private string _activeRequestId = string.Empty;
    private int _activeMutating;

    public ShellViewModel(string repositoryRoot, Action<Action>? dispatch = null)
    {
        _repositoryRoot = repositoryRoot;
        Dispatch = dispatch ?? (action => action());

        Strings = new LocalizationService();
        Runner = new BridgeRunner();

        Overview = new OverviewViewModel(this);
        Tweaks = new TweaksViewModel(this);
        Review = new ReviewViewModel(this);
        History = new HistoryViewModel(this);
        Diagnostics = new DiagnosticsViewModel(this);
        Licensing = new LicensingViewModel(this);

        Runner.Progress += OnProgress;
        Runner.Exited += OnBackendExited;
        Runner.Diagnostic += (_, message) => Diagnostics.AddDiagnostic(message);
    }

    /// <summary>Marshals an action onto the UI thread (the app supplies the dispatcher).</summary>
    public Action<Action> Dispatch { get; set; }

    /// <summary>Localized text, served by the engine.</summary>
    public LocalizationService Strings { get; }

    /// <summary>The backend facade.</summary>
    public BridgeRunner Runner { get; }

    /// <summary>Workspaces, one per navigation entry.</summary>
    public OverviewViewModel Overview { get; }

    public TweaksViewModel Tweaks { get; }

    public ReviewViewModel Review { get; }

    public HistoryViewModel History { get; }

    public DiagnosticsViewModel Diagnostics { get; }

    public LicensingViewModel Licensing { get; }

    /// <summary>Currently selected workspace.</summary>
    public Workspace Current
    {
        get => _current;
        private set
        {
            if (Set(ref _current, value))
            {
                Raise(nameof(CurrentTitle));
            }
        }
    }

    /// <summary>Localized title of the current workspace.</summary>
    public string CurrentTitle => Strings.Get(NavKey(Current));

    /// <summary>Environment snapshot, once connected.</summary>
    public EnvironmentStatus? Environment
    {
        get => _environment;
        private set
        {
            if (Set(ref _environment, value))
            {
                Raise(nameof(HeaderEnvironment));
            }
        }
    }

    /// <summary>Runtime profile, once connected.</summary>
    public RuntimeStatus? Runtime
    {
        get => _runtime;
        private set
        {
            if (Set(ref _runtime, value))
            {
                Raise(nameof(HeaderEnvironment));
            }
        }
    }

    /// <summary>Compact one-line environment summary for the header.</summary>
    public string HeaderEnvironment
    {
        get
        {
            if (Environment is null)
            {
                return Strings["Gui.Starting"];
            }

            var elevated = Environment.IsAdmin ? "admin" : "standard";
            var os = string.IsNullOrEmpty(Environment.OsVersionKey) || Environment.OsVersionKey == "Unknown"
                ? Environment.Architecture
                : $"{Environment.OsVersionKey} {Environment.OsBuild}";
            return $"PS {Environment.PowerShellVersion} | {os} | {elevated}";
        }
    }

    /// <summary>Compact one-line backend summary (host, edition, protocol).</summary>
    public string BackendSummary
    {
        get => _backendSummary;
        private set => Set(ref _backendSummary, value);
    }

    /// <summary>True while a request is in flight.</summary>
    public bool Busy
    {
        get => _busy;
        private set => Set(ref _busy, value);
    }

    /// <summary>True once the backend handshake has completed.</summary>
    public bool IsConnected
    {
        get => _connected;
        private set
        {
            if (Set(ref _connected, value))
            {
                Raise(nameof(IsElevated));
            }
        }
    }

    /// <summary>True when the backend session is elevated (drives the elevation banner).</summary>
    public bool IsElevated => Environment?.IsAdmin ?? false;

    /// <summary>
    /// True when the app host itself runs elevated. When the backend is elevated but the
    /// app host is not, the backend can only be a child of an elevated relaunch; the
    /// banner distinguishes the two so a user can tell whose elevation they granted.
    /// </summary>
    public bool IsProcessElevated => ProcessElevation.IsElevated();

    /// <summary>
    /// Relaunches the application elevated (a child that receives a UAC prompt) and
    /// exits this copy. The backend is shut down cleanly first - never killed under a
    /// mutation. The elevated child discovers the engine from the same root and restarts
    /// the same session; the archived environment settings are carried over.
    /// </summary>
    /// <returns>An error message when the relaunch could not be started; null on success.</returns>
    public async Task<string?> RelaunchElevatedAsync()
    {
        if (HasMutatingOperation)
        {
            return Strings["Gui.Error.BusyMutating"];
        }

        var repositoryRoot = _repositoryRoot;
        var language = Strings.Active;

        var outcome = await Runner.ShutdownAsync(allowKill: false).ConfigureAwait(true);
        if (outcome != ShutdownOutcome.Clean && outcome != ShutdownOutcome.AlreadyStopped)
        {
            return Strings["Gui.Error.BackendStopFailed"];
        }

        try
        {
            ProcessElevation.StartElevated(repositoryRoot, language);
        }
        catch (Win32Exception)
        {
            // The user declined the UAC prompt (ERROR_CANCELLED) or it failed to appear.
            // Nothing ran, and the current session is still usable, so the app stays.
            return Strings["Gui.Error.ElevationDeclined"];
        }
        catch (Exception exception)
        {
            return $"{Strings["Gui.Error.ElevationFailed"]}: {exception.Message}";
        }

        IsConnected = false;
        return null;
    }

    /// <summary>Status line text.</summary>
    public string StatusText
    {
        get => _statusText;
        set => Set(ref _statusText, value);
    }

    /// <summary>Where the startup sequence is (drives the window's visible states).</summary>
    public InitializationState Initialization
    {
        get => _initialization;
        private set
        {
            if (Set(ref _initialization, value))
            {
                Raise(nameof(InitializationFailed));
                Raise(nameof(InitializationBusy));
            }
        }
    }

    /// <summary>The reason startup failed, or empty.</summary>
    public string InitializationError
    {
        get => _initializationError;
        private set => Set(ref _initializationError, value);
    }

    /// <summary>True when startup failed and the user must be offered a retry.</summary>
    public bool InitializationFailed => Initialization == InitializationState.Failed;

    /// <summary>True while the startup sequence is still running.</summary>
    public bool InitializationBusy => Initialization == InitializationState.Loading;

    /// <summary>Engine module version reported by the handshake (never invented).</summary>
    public string EngineVersion
    {
        get => _engineVersion;
        private set => Set(ref _engineVersion, value);
    }

    /// <summary>Progress line text (bounded updates: it is written, not appended to).</summary>
    public string ProgressText
    {
        get => _progressText;
        private set => Set(ref _progressText, value);
    }

    /// <summary>True when the user asked for reduced animation.</summary>
    public bool ReduceMotion
    {
        get => _reduceMotion;
        set => Set(ref _reduceMotion, value);
    }

    /// <summary>
    /// True while a mutating request is in flight. The window's closing logic reads this:
    /// closing during a mutation must offer a choice instead of abandoning it.
    /// </summary>
    public bool HasMutatingOperation => Volatile.Read(ref _activeMutating) > 0;

    /// <summary>Runs a mutating operation under the shell's in-flight accounting.</summary>
    public async Task<T> RunMutatingAsync<T>(Func<Task<T>> operation)
    {
        Interlocked.Increment(ref _activeMutating);
        Busy = true;
        try
        {
            return await operation().ConfigureAwait(true);
        }
        finally
        {
            Interlocked.Decrement(ref _activeMutating);
            Busy = HasMutatingOperation || AnyWorkspaceBusy();
            ProgressText = string.Empty;
        }
    }

    /// <summary>Runs a read-only operation under the shell's in-flight accounting.</summary>
    public async Task<T> RunReadAsync<T>(Func<Task<T>> operation)
    {
        Busy = true;
        try
        {
            return await operation().ConfigureAwait(true);
        }
        finally
        {
            Busy = HasMutatingOperation || AnyWorkspaceBusy();
        }
    }

    private bool AnyWorkspaceBusy() =>
        Overview.Busy || Tweaks.Busy || Review.Busy || History.Busy || Diagnostics.Busy || Licensing.Busy;

    /// <summary>
    /// Connects the backend: starts the session, reads the handshake, then loads the
    /// string tables and the environment. Returns null on success, else the reason.
    /// </summary>
    /// <remarks>
    /// Never throws: a failure at any stage (including a fault inside a notification
    /// handler) is recorded, reflected in <see cref="Initialization"/>, and returned so
    /// the window can show a visible error state with a retry instead of silently keeping
    /// the pre-load placeholders.
    /// </remarks>
    public async Task<string?> ConnectAsync()
    {
        Initialization = InitializationState.Loading;
        InitializationError = string.Empty;
        StatusText = Strings["Gui.Starting"];
        Diagnostics.AddDiagnostic("startup: connecting");

        try
        {
            var failure = await Runner.ConnectAsync(_repositoryRoot).ConfigureAwait(true);
            if (failure is not null)
            {
                return Fail(failure);
            }

            var hello = Runner.Hello!;
            IsConnected = true;
            BackendSummary = $"{hello.Edition} {hello.PowerShellVersion} | protocol {hello.Protocol} | {hello.Platform}/{hello.Architecture}";
            EngineVersion = hello.ModalVersion;
            Diagnostics.AddDiagnostic($"startup: handshake ok (protocol {hello.Protocol}, {hello.Edition} {hello.PowerShellVersion})");

            // Text first: every other view renders through it.
            var strings = await Runner.RunAsync("strings.get", Projections.Strings, timeout: TimeSpan.FromSeconds(60)).ConfigureAwait(true);
            if (strings.Ok)
            {
                var (languages, active, tables) = strings.Value;
                Strings.Load(languages, active, tables);
                Diagnostics.AddDiagnostic($"startup: strings loaded ({languages.Count} language(s), {tables.Count} table(s))");
                if (!Strings.IsLoaded)
                {
                    Strings.LoadFailed(Strings["Gui.Error.LocalizationFailed"]);
                }
            }
            else
            {
                Strings.LoadFailed($"{strings.Code}: {strings.Message}");
                Diagnostics.AddDiagnostic($"startup: strings.get failed ({strings.Code}) {strings.Message}");
            }

            var environment = await Runner.RunAsync("env.status", Projections.Environment, timeout: TimeSpan.FromSeconds(60)).ConfigureAwait(true);
            if (environment.Ok)
            {
                Environment = environment.Value.Environment;
                Runtime = environment.Value.Runtime;
                Diagnostics.AddDiagnostic("startup: environment loaded");
            }
            else
            {
                Diagnostics.AddDiagnostic($"startup: env.status failed ({environment.Code}) {environment.Message}");
            }

            if (!Strings.IsLoaded)
            {
                return Fail(Strings["Gui.Error.LocalizationFailed"]);
            }

            StatusText = Environment is null ? Strings["Gui.Ready"] : HeaderEnvironment;
            Initialization = InitializationState.Ready;
            Diagnostics.AddDiagnostic("startup: ready");
            return null;
        }
        catch (Exception exception)
        {
            Diagnostics.AddDiagnostic($"startup: unhandled {exception.GetType().Name}: {exception.Message}");
            return Fail($"{Strings["Gui.Error.InitFailed"]}: {exception.Message}");
        }
    }

    /// <summary>Reconnects after a failure (the visible Retry action).</summary>
    public Task<string?> RetryConnectAsync()
    {
        Runner.Reset();
        IsConnected = false;
        return ConnectAsync();
    }

    private string Fail(string message)
    {
        IsConnected = false;
        InitializationError = message;
        Initialization = InitializationState.Failed;
        StatusText = message;
        return message;
    }

    /// <summary>Navigates to a workspace, loading it on first visit.</summary>
    public async Task NavigateAsync(Workspace workspace)
    {
        Current = workspace;
        Raise(nameof(CurrentTitle));

        var target = workspace switch
        {
            Workspace.Overview => (WorkspaceViewModel)Overview,
            Workspace.Tweaks => Tweaks,
            Workspace.Review => Review,
            Workspace.History => History,
            Workspace.Diagnostics => Diagnostics,
            Workspace.Licensing => Licensing,
            _ => Overview,
        };

        await RunReadAsync(async () => { await target.EnsureLoadedAsync().ConfigureAwait(true); return true; }).ConfigureAwait(true);
    }

    /// <summary>Switches the interface language in this client and in the engine.</summary>
    public async Task SetLanguageAsync(string language)
    {
        var outcome = await Runner.RunAsync(
            "language.set",
            element => element.ValueKind == System.Text.Json.JsonValueKind.String ? element.GetString() ?? language : language,
            new Dictionary<string, object?>(StringComparer.Ordinal) { ["language"] = language },
            TimeSpan.FromSeconds(30)).ConfigureAwait(true);

        if (!outcome.Ok)
        {
            StatusText = outcome.Message;
            return;
        }

        Strings.SetActive(language);
        Raise(nameof(CurrentTitle));
        StatusText = HeaderEnvironment;
    }

    /// <summary>
    /// Prepares to close the window. Returns <c>true</c> when it is safe to close now;
    /// <c>false</c> when a mutating operation is still running (the caller must ask the
    /// user which of the offered choices they want).
    /// </summary>
    public async Task<bool> TryCloseAsync()
    {
        if (HasMutatingOperation)
        {
            return false;
        }

        await Runner.ShutdownAsync(allowKill: true).ConfigureAwait(true);
        IsConnected = false;
        return true;
    }

    /// <summary>
    /// Asks the running operation to stop, then waits for it to reach a safe boundary and
    /// closes. Never kills a mutation: the backend unwinds through its own path.
    /// </summary>
    public async Task<bool> CancelAndCloseAsync()
    {
        var requestId = Volatile.Read(ref _activeRequestId);
        if (!string.IsNullOrEmpty(requestId))
        {
            await Runner.CancelAsync(requestId).ConfigureAwait(true);
        }

        // The backend refuses to exit while a task is running, so a short grace is given
        // and the outcome is reported rather than assumed.
        await Runner.ShutdownAsync(allowKill: false).ConfigureAwait(true);
        IsConnected = false;
        return true;
    }

    /// <summary>Waits for the running operation to finish, then closes.</summary>
    public async Task WaitAndCloseAsync()
    {
        var deadline = DateTime.UtcNow.AddMinutes(10);
        while (HasMutatingOperation && DateTime.UtcNow < deadline)
        {
            await Task.Delay(200).ConfigureAwait(true);
        }

        await Runner.ShutdownAsync(allowKill: !HasMutatingOperation).ConfigureAwait(true);
        IsConnected = false;
    }

    /// <summary>Records the request id of the newest operation (used by cancel).</summary>
    public void TrackRequest(string requestId) => Volatile.Write(ref _activeRequestId, requestId);

    private void OnProgress(object? sender, WindowsTweaker.Gui.Core.Protocol.BridgeProgress progress)
    {
        Dispatch(() =>
        {
            var text = progress.Total is > 0 && progress.Done is not null
                ? $"{Strings.Get("Gui.Busy.Item", progress.Done, progress.Total)} - {progress.Item ?? progress.Text}"
                : progress.Text;

            // Bounded: the line is replaced, never appended to, and an empty update is
            // ignored so a chatty backend cannot force a repaint per byte.
            if (!string.IsNullOrEmpty(text) && text != ProgressText)
            {
                ProgressText = text;
            }
        });
    }

    private void OnBackendExited(object? sender, int exitCode)
    {
        Dispatch(() =>
        {
            IsConnected = false;
            StatusText = Strings.Get("Gui.Error.BackendExited", exitCode);
            Diagnostics.AddDiagnostic($"backend exited with code {exitCode}");
        });
    }

    /// <summary>The resource key of a workspace's navigation label.</summary>
    public static string NavKey(Workspace workspace) => workspace switch
    {
        Workspace.Overview => "Gui.Nav.Overview",
        Workspace.Tweaks => "Gui.Nav.Tweaks",
        Workspace.Review => "Gui.Nav.Review",
        Workspace.History => "Gui.Nav.History",
        Workspace.Diagnostics => "Gui.Nav.Diagnostics",
        Workspace.Licensing => "Gui.Nav.Licensing",
        _ => "Gui.Nav.Overview",
    };

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        await Runner.DisposeAsync().ConfigureAwait(false);
    }
}

/// <summary>Observable list helper used by the workspaces.</summary>
public sealed class ObservableList<T> : ObservableCollection<T>
{
}
