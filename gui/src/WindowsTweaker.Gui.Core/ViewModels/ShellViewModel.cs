using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using WindowsTweaker.Gui.Core.Bridge;
using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.Protocol;

namespace WindowsTweaker.Gui.Core.ViewModels;

/// <summary>One language the engine ships, with the name to show for it.</summary>
/// <param name="Code">The stable identifier ("en", "vi") used on the wire.</param>
/// <param name="DisplayName">The language's own name, from the engine's string tables.</param>
public sealed record LanguageOption(string Code, string DisplayName);

/// <summary>
/// The window's whole state: the backend session, the workspaces, the header, the status
/// bars and the closing rules.
/// </summary>
/// <remarks>
/// The shell owns the behaviours the individual views must not re-implement:
/// <list type="bullet">
/// <item><b>the connection state</b>: <see cref="Connection"/> mirrors the runner and is the
/// single source of truth the UI renders, so a backend that goes away cannot leave the
/// window claiming to be connected;</item>
/// <item><b>recovery</b>: <see cref="ReconnectAsync"/> stops whatever session exists, makes
/// exactly one new connection, reloads the read-only data and marks the previously loaded
/// data stale - it never replays a mutation;</item>
/// <item><b>staying responsive</b>: it subscribes to progress on the reader task and moves
/// each update to the UI thread through <see cref="Dispatch"/>;</item>
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
    private ConnectionState _connection = ConnectionState.Connecting;
    private string _connectionDetail = string.Empty;
    private string _connectionCode = ProtocolConstants.ErrorCode.BackendDown;
    private int _connectionExitCode;
    private LanguageOption? _selectedLanguage;
    private bool _busy;
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
        Runner.Diagnostic += (_, message) => Diagnostics.AddDiagnostic(message);
        Runner.Activity += (_, activity) => Diagnostics.AddActivity(activity);
        Runner.StateChanged += (_, change) => Dispatch(() => ApplyBackendState(change));

        // The staleness facts are aggregates, so they must be re-published whenever a
        // workspace's own flag changes (a mark, or a reload that clears it).
        foreach (var workspace in AllWorkspaces())
        {
            workspace.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName is nameof(WorkspaceViewModel.IsStale))
                {
                    Raise(nameof(HasStaleData));
                    Raise(nameof(CurrentIsStale));
                }
            };
        }

        // A language switch must re-render every label, including the ones this shell
        // composes itself (privilege, recovery, summaries, workspace paths). Raising an
        // empty property name makes every binding re-read its source; the previous build
        // instead reassigned the window's DataContext, which re-evaluated the language
        // selector's item source mid-switch and left it blank.
        Strings.LanguageChanged += (_, _) => Dispatch(() => Raise(string.Empty));
    }

    /// <summary>Marshals an action onto the UI thread (the app supplies the dispatcher).</summary>
    public Action<Action> Dispatch { get; set; }

    /// <summary>Localized text, served by the engine.</summary>
    public LocalizationService Strings { get; }

    /// <summary>
    /// Starts the elevated copy during an elevation handoff. It is the one place the
    /// elevated relaunch is performed, so a test can force the "the handoff could not be
    /// started" path (declined UAC prompt) on any host instead of only where UAC exists.
    /// </summary>
    public Action<string, string> StartElevated { get; set; } = ProcessElevation.StartElevated;

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
                Raise(nameof(CurrentIsStale));
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
                RaiseEnvironmentFacts();
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
                Raise(nameof(RuntimeSummary));
            }
        }
    }

    /// <summary>Compact one-line backend summary (host, edition, protocol) for Diagnostics.</summary>
    public string BackendSummary
    {
        get => _backendSummary;
        private set => Set(ref _backendSummary, value);
    }

    // ---- connection state -----------------------------------------------------

    /// <summary>Where the backend connection stands. The UI renders this, nothing else.</summary>
    public ConnectionState Connection
    {
        get => _connection;
        private set
        {
            if (Set(ref _connection, value))
            {
                RaiseConnectionFacts();
            }
        }
    }

    /// <summary>True only while a live backend session is connected.</summary>
    public bool IsConnected => Connection == ConnectionState.Ready;

    /// <summary>True while a connection attempt is in flight.</summary>
    public bool IsConnecting => Connection == ConnectionState.Connecting;

    /// <summary>True when no session is running (stopped, or the process ended).</summary>
    public bool IsDisconnected => Connection == ConnectionState.Disconnected;

    /// <summary>True when the last connection attempt failed.</summary>
    public bool IsConnectionFailed => Connection == ConnectionState.Failed;

    /// <summary>Short localized label for the connection state (the header pill).</summary>
    public string ConnectionLabel => Connection switch
    {
        ConnectionState.Connecting => Strings["Gui.Starting"],
        ConnectionState.Ready => Strings["Gui.Ready"],
        ConnectionState.Failed => Strings["Gui.Connection.Failed"],
        _ => Strings["Gui.Connection.Disconnected"],
    };

    /// <summary>The last failure or exit, localized, with no technical detail.</summary>
    public string ConnectionError => DescribeFailure(_connectionCode, _connectionDetail, _connectionExitCode);

    /// <summary>The raw technical detail behind the state (kept for the expandable section).</summary>
    public string ConnectionDetail => string.IsNullOrWhiteSpace(_connectionDetail)
        ? ConnectionError
        : ConnectionDetailText();

    /// <summary>True whenever the connection is not ready: the recovery affordance is shown.</summary>
    public bool RecoveryVisible => Connection != ConnectionState.Ready;

    /// <summary>
    /// The exit code of the backend process behind the current state, or 0 when no process
    /// has ended. It is part of the technical detail the Diagnostics panel shows.
    /// </summary>
    public int ConnectionExitCode => _connectionExitCode;

    /// <summary>
    /// True when the <em>visible</em> workspace is showing data read from a connection that
    /// is no longer the live one. Drives the staleness badge next to the workspace title.
    /// </summary>
    public bool CurrentIsStale => For(Current).IsStale;

    /// <summary>
    /// True when any workspace holds data read from a connection that is gone. Drives the
    /// note in the recovery strip; it is a fact about the data on screen, not about the
    /// connection, so it is never shown just because the backend is down.
    /// </summary>
    public bool HasStaleData
    {
        get
        {
            foreach (var workspace in AllWorkspaces())
            {
                if (workspace.IsStale)
                {
                    return true;
                }
            }

            return false;
        }
    }

    /// <summary>True when the recovery affordance can actually do something.</summary>
    public bool CanReconnect => !IsConnecting && !HasMutatingOperation;

    /// <summary>Localized explanation shown in the recovery banner.</summary>
    public string RecoveryMessage => Connection switch
    {
        ConnectionState.Connecting => Strings["Gui.Starting"],
        ConnectionState.Ready => string.Empty,
        ConnectionState.Failed => ConnectionError,
        _ when _connectionExitCode != 0 => Strings.Get("Gui.Error.BackendExited", _connectionExitCode),
        _ => Strings["Gui.BackendDown"],
    };

    /// <summary>One line describing the environment and the session (Diagnostics).</summary>
    public string EnvironmentSummary
    {
        get
        {
            if (Environment is not { } environment)
            {
                return Strings["Gui.Overview.NotLoaded"];
            }

            var os = string.IsNullOrEmpty(environment.OsVersionKey) || environment.OsVersionKey == "Unknown"
                ? environment.Architecture
                : $"{environment.OsVersionKey} {environment.OsBuild}";
            return $"{os} | {environment.Architecture} | {environment.Culture}";
        }
    }

    /// <summary>PowerShell host and edition line (Diagnostics).</summary>
    public string RuntimeSummary => Environment is { } environment
        ? $"{environment.PowerShellVersion} ({environment.RequiredPowerShell}) | {environment.LanguageMode}"
        : Strings["Gui.Overview.NotLoaded"];

    /// <summary>Where the backend store and logs live (Diagnostics).</summary>
    public string PathSummary => Environment is { } environment
        ? environment.StatePath + System.Environment.NewLine + environment.LogPath
        : Strings["Gui.Overview.NotLoaded"];

    /// <summary>Pending reboot state reported by the engine (Diagnostics).</summary>
    public string PendingRebootSummary => Environment is { } environment
        ? (environment.PendingReboot == true ? environment.PendingRebootLabel : Strings["Common.No"])
        : Strings["Gui.Overview.NotLoaded"];

    /// <summary>The handshake's protocol/host line (Diagnostics).</summary>
    public string ProtocolSummary => Runner.Hello is { } hello
        ? $"protocol {hello.Protocol} | {hello.Bridge} | {hello.Edition} {hello.PowerShellVersion} | {hello.Platform}/{hello.Architecture} | {hello.Tier}"
        : Strings["Gui.Overview.NotLoaded"];

    /// <summary>True when the backend session is elevated (drives the elevation badge).</summary>
    public bool IsElevated => Environment?.IsAdmin ?? false;

    /// <summary>Localized privilege label (header pill and Diagnostics).</summary>
    public string PrivilegeLabel => IsElevated ? Strings["Gui.Overview.Admin"] : Strings["Gui.Overview.Standard"];

    /// <summary>
    /// True when the app host itself runs elevated. When the backend is elevated but the
    /// app host is not, the backend can only be a child of an elevated relaunch; the badge
    /// distinguishes the two so a user can tell whose elevation they granted.
    /// </summary>
    public bool IsProcessElevated => ProcessElevation.IsElevated();

    // ---- languages ------------------------------------------------------------

    /// <summary>The languages the engine ships, with their display names.</summary>
    public ObservableCollection<LanguageOption> AvailableLanguages { get; } = new();

    /// <summary>
    /// The language the interface is rendered in. Bound two-way by the selector, so the
    /// selection survives the item source being refreshed and always shows what is active.
    /// </summary>
    public LanguageOption? SelectedLanguage
    {
        get => _selectedLanguage;
        set
        {
            if (value is null || value.Code == _selectedLanguage?.Code)
            {
                return;
            }

            _selectedLanguage = value;
            Raise();
            _ = SetLanguageAsync(value.Code);
        }
    }

    // ---- status ---------------------------------------------------------------

    /// <summary>True while a request is in flight.</summary>
    public bool Busy
    {
        get => _busy;
        private set
        {
            if (Set(ref _busy, value))
            {
                Raise(nameof(CanReconnect));
            }
        }
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
        Raise(nameof(CanReconnect));
        try
        {
            return await operation().ConfigureAwait(true);
        }
        finally
        {
            Interlocked.Decrement(ref _activeMutating);
            Busy = HasMutatingOperation || AnyWorkspaceBusy();
            ProgressText = string.Empty;
            Raise(nameof(CanReconnect));
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

    // ---- connecting -----------------------------------------------------------

    /// <summary>
    /// Connects the backend: starts the session, reads the handshake, then loads the
    /// string tables and the environment. Returns null on success, else the reason.
    /// </summary>
    /// <remarks>
    /// Never throws: a failure at any stage (including a fault inside a notification
    /// handler) is recorded, reflected in <see cref="Connection"/> and <see cref="Initialization"/>,
    /// and returned so the window can show a visible error state with a retry instead of
    /// silently keeping the pre-load placeholders.
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

            var hello = Runner.Hello;
            if (hello is null)
            {
                return Fail(Strings["Gui.Error.InitFailed"]);
            }

            BackendSummary = $"{hello.Edition} {hello.PowerShellVersion} | protocol {hello.Protocol} | {hello.Platform}/{hello.Architecture}";
            EngineVersion = hello.ModalVersion;
            Diagnostics.AddDiagnostic($"startup: handshake ok (protocol {hello.Protocol}, {hello.Edition} {hello.PowerShellVersion})");

            // Text first: every other view renders through it.
            var strings = await Runner.RunAsync("strings.get", Projections.Strings, timeout: TimeSpan.FromSeconds(60)).ConfigureAwait(true);
            if (strings.Ok)
            {
                var (languages, active, tables) = strings.Value;
                LoadLanguages(languages, active, tables);
                Diagnostics.AddDiagnostic($"startup: strings loaded ({languages.Count} language(s), {tables.Count} table(s))");
            }
            else
            {
                Strings.LoadFailed(DescribeFailure(strings.Code, strings.Message));
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

            StatusText = Strings["Gui.Ready"];
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

    /// <summary>
    /// Reconnects after a failure or a lost session: stops whatever session is left, makes
    /// exactly one new connection with a fresh handshake, reloads the read-only data, and
    /// marks the data each workspace already showed as stale so the UI cannot pass it off as
    /// current. Staged review selections are kept; no mutation is ever replayed.
    /// </summary>
    public async Task<string?> ReconnectAsync()
    {
        if (HasMutatingOperation)
        {
            return Strings["Gui.Error.BusyMutating"];
        }

        var previousGeneration = Runner.Generation;
        await Runner.StopAsync(allowKill: true, reason: "reconnect").ConfigureAwait(true);
        Diagnostics.AddDiagnostic($"connection: stopped (generation {previousGeneration} -> {Runner.Generation})");

        MarkWorkspacesStale();
        var failure = await ConnectAsync().ConfigureAwait(true);
        if (failure is not null)
        {
            return failure;
        }

        Diagnostics.AddDiagnostic($"connection: reconnected (generation {Runner.Generation})");
        await ReloadCurrentWorkspaceAsync().ConfigureAwait(true);
        return null;
    }

    /// <summary>Reloads the visible workspace's read-only data after a reconnect.</summary>
    public async Task ReloadCurrentWorkspaceAsync()
    {
        var target = For(Current);
        await RunReadAsync(async () =>
        {
            await target.ReloadAsync().ConfigureAwait(true);
            return true;
        }).ConfigureAwait(true);
    }

    /// <summary>Marks every already-loaded workspace's data as belonging to a past connection.</summary>
    public void MarkWorkspacesStale()
    {
        foreach (var workspace in AllWorkspaces())
        {
            workspace.MarkStale();
        }
    }

    private WorkspaceViewModel For(Workspace workspace) => workspace switch
    {
        Workspace.Tweaks => Tweaks,
        Workspace.Review => Review,
        Workspace.History => History,
        Workspace.Diagnostics => Diagnostics,
        Workspace.Licensing => Licensing,
        _ => Overview,
    };

    private WorkspaceViewModel[] AllWorkspaces() =>
        new WorkspaceViewModel[] { Overview, Tweaks, Review, History, Diagnostics, Licensing };

    private string Fail(string message)
    {
        InitializationError = message;
        Initialization = InitializationState.Failed;
        Connection = ConnectionState.Failed;
        _connectionCode = ProtocolConstants.ErrorCode.BackendDown;
        _connectionDetail = message;
        StatusText = message;
        return message;
    }

    // ---- connection state plumbing --------------------------------------------

    /// <summary>Mirrors the runner's session state onto the shell's connection state.</summary>
    private void ApplyBackendState(BackendStateChange change)
    {
        _connectionDetail = change.Detail;
        _connectionExitCode = change.ExitCode;

        switch (change.State)
        {
            case BackendState.Connecting:
                Connection = ConnectionState.Connecting;
                return;

            case BackendState.Ready:
                Connection = ConnectionState.Ready;
                return;

            case BackendState.Failed:
                _connectionCode = ProtocolConstants.ErrorCode.BackendDown;
                Connection = ConnectionState.Failed;
                return;

            default:
                _connectionCode = change.ExitCode != 0
                    ? ProtocolConstants.ErrorCode.BackendExited
                    : ProtocolConstants.ErrorCode.BackendDown;
                if (Connection != ConnectionState.Connecting)
                {
                    Connection = ConnectionState.Disconnected;
                }

                Diagnostics.AddDiagnostic($"backend: {change.Reason} (exit code {change.ExitCode})");
                if (IsLoadedDataAtRisk() && change.ExitCode != 0)
                {
                    // The data on screen was read from a process that has ended: it stays
                    // visible, but it is no longer current and must not be trusted blind.
                    MarkWorkspacesStale();
                }

                StatusText = RecoveryMessage;
                return;
        }
    }

    private bool IsLoadedDataAtRisk() => Overview.Loaded || Tweaks.Loaded || History.Loaded || Diagnostics.Loaded;

    /// <summary>
    /// Turns a failure code into localized text. The engine localizes its own error
    /// messages (it throws them through its string tables), so anything this client does not
    /// recognize is shown verbatim; the codes this client invents are localized here.
    /// </summary>
    public string DescribeFailure(string code, string message) => DescribeFailure(code, message, 0);

    private string DescribeFailure(string code, string message, int exitCode)
    {
        var detail = string.IsNullOrWhiteSpace(message) ? Strings["Gui.BackendDown"] : message;
        return code switch
        {
            ProtocolConstants.ErrorCode.BackendExited when exitCode != 0 =>
                $"{Strings.Get("Gui.Error.BackendExited", exitCode)} ({detail})",
            ProtocolConstants.ErrorCode.BackendDown or ProtocolConstants.ErrorCode.BackendExited =>
                Strings["Gui.BackendDown"],
            ProtocolConstants.ErrorCode.StaleConnection => Strings["Gui.Error.StaleAnswer"],
            ProtocolConstants.ErrorCode.Cancelled => Strings["Gui.Error.Cancelled"],
            ProtocolConstants.ErrorCode.Timeout => Strings["Gui.Error.BackendTimeout"],
            ProtocolConstants.ErrorCode.Busy => Strings["Gui.Error.Busy"],
            ProtocolConstants.ErrorCode.RequiresElevation => Strings["Gui.Error.RequiresElevation"],
            "ProjectionFailed" => Strings.Get("Gui.Error.BackendProtocol", detail),
            _ => detail,
        };
    }

    private string ConnectionDetailText()
    {
        var lines = new List<string>
        {
            $"code={_connectionCode}",
            $"generation={Runner.Generation}",
            $"exit={_connectionExitCode}",
            _connectionDetail,
        };

        var stderr = Runner.StderrTail;
        if (!string.IsNullOrWhiteSpace(stderr) && !stderr.Contains(_connectionDetail, StringComparison.Ordinal))
        {
            lines.Add(stderr);
        }

        return string.Join(System.Environment.NewLine, lines.Where(line => !string.IsNullOrWhiteSpace(line)).ToArray());
    }

    private void RaiseConnectionFacts()
    {
        Raise(nameof(IsConnected));
        Raise(nameof(IsConnecting));
        Raise(nameof(IsDisconnected));
        Raise(nameof(IsConnectionFailed));
        Raise(nameof(ConnectionLabel));
        Raise(nameof(ConnectionError));
        Raise(nameof(ConnectionDetail));
        Raise(nameof(RecoveryVisible));
        Raise(nameof(RecoveryMessage));
        Raise(nameof(ConnectionExitCode));
        Raise(nameof(CanReconnect));
        Raise(nameof(PrivilegeLabel));
        Raise(nameof(ConnectedCommandsEnabled));
    }

    /// <summary>True when commands that need the backend may run.</summary>
    public bool ConnectedCommandsEnabled => IsConnected;

    private void RaiseEnvironmentFacts()
    {
        Raise(nameof(IsElevated));
        Raise(nameof(PrivilegeLabel));
        Raise(nameof(EnvironmentSummary));
        Raise(nameof(RuntimeSummary));
        Raise(nameof(PathSummary));
        Raise(nameof(PendingRebootSummary));
    }

    private void LoadLanguages(
        IReadOnlyList<string> languages,
        string active,
        IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> tables)
    {
        Strings.Load(languages, active, tables);

        AvailableLanguages.Clear();
        foreach (var code in Strings.Languages)
        {
            // The name comes from the engine's tables (Tui.Language.<code>); a language
            // without a shipped name shows its stable code rather than a raw key.
            var name = Strings.Get($"Tui.Language.{code}");
            AvailableLanguages.Add(new LanguageOption(code, name.StartsWith('[') ? code : name));
        }

        SyncSelectedLanguage();
    }

    /// <summary>Points the selector at the active language without echoing a switch back.</summary>
    private void SyncSelectedLanguage()
    {
        var match = AvailableLanguages.FirstOrDefault(option => option.Code == Strings.Active);
        if (match is null)
        {
            return;
        }

        _selectedLanguage = match;
        Raise(nameof(SelectedLanguage));
    }

    // ---- workspace navigation -------------------------------------------------

    /// <summary>Navigates to a workspace, loading it on first visit (or after a reconnect).</summary>
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
            StatusText = DescribeFailure(outcome.Code, outcome.Message);
            SyncSelectedLanguage();
            return;
        }

        Strings.SetActive(language);
        SyncSelectedLanguage();
        Raise(nameof(CurrentTitle));
        StatusText = Strings["Gui.Ready"];
    }

    // ---- elevation ------------------------------------------------------------

    /// <summary>
    /// Relaunches the application elevated (a child that receives a UAC prompt) and
    /// exits this copy. The backend is shut down cleanly first - never killed under a
    /// mutation - and, when the handoff cannot be started, the session is brought back so
    /// the window the user keeps working in is connected again.
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

        var previousGeneration = Runner.Generation;
        var outcome = await Runner.StopAsync(allowKill: false, reason: "elevation handoff").ConfigureAwait(true);
        if (outcome != ShutdownOutcome.Clean && outcome != ShutdownOutcome.AlreadyStopped)
        {
            // The old session is gone either way, and the message must not claim otherwise:
            // report it and put a working session back under the window that stays open.
            var restored = await ConnectAsync().ConfigureAwait(true);
            return restored is null
                ? Strings["Gui.Error.BackendStopFailed"]
                : $"{Strings["Gui.Error.BackendStopFailed"]} {DescribeFailure(ProtocolConstants.ErrorCode.BackendDown, restored)}";
        }

        Diagnostics.AddDiagnostic($"elevation: session stopped (generation {previousGeneration} -> {Runner.Generation})");

        try
        {
            StartElevated(repositoryRoot, language);
        }
        catch (Win32Exception)
        {
            // The user declined the UAC prompt (ERROR_CANCELLED) or it failed to appear.
            // Nothing ran, so this copy must keep a working backend: the elevated child was
            // never started, and the previous session was deliberately stopped.
            var restored = await ConnectAsync().ConfigureAwait(true);
            if (restored is not null)
            {
                return $"{Strings["Gui.Error.ElevationDeclined"]} {restored}";
            }

            await ReloadCurrentWorkspaceAsync().ConfigureAwait(true);
            return Strings["Gui.Error.ElevationDeclined"];
        }
        catch (Exception exception)
        {
            var restored = await ConnectAsync().ConfigureAwait(true);
            var message = $"{Strings["Gui.Error.ElevationFailed"]}: {exception.Message}";
            return restored is null ? message : $"{message} {restored}";
        }

        Connection = ConnectionState.Disconnected;
        return null;
    }

    // ---- closing --------------------------------------------------------------

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

        await Runner.StopAsync(allowKill: true, reason: "window closed").ConfigureAwait(true);
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
        await Runner.StopAsync(allowKill: false, reason: "cancel and close").ConfigureAwait(true);
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

        await Runner.StopAsync(allowKill: !HasMutatingOperation, reason: "wait and close").ConfigureAwait(true);
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

    /// <summary>The Segoe Fluent/MDL2 glyph for a workspace, present on Windows 10 and 11.</summary>
    public static string NavGlyph(Workspace workspace) => workspace switch
    {
        Workspace.Overview => "\uE80F",   // Home
        Workspace.Tweaks => "\uE9F5",     // DeveloperTools / sliders
        Workspace.Review => "\uE8FB",     // Accept / review
        Workspace.History => "\uE81C",    // History
        Workspace.Diagnostics => "\uE9D9", // Diagnostic
        Workspace.Licensing => "\uE8D7",  // Certificate
        _ => "\uE80F",
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
