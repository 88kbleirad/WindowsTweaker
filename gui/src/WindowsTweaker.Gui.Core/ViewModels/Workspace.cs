using WindowsTweaker.Gui.Core.Model;

namespace WindowsTweaker.Gui.Core.ViewModels;

/// <summary>The workspaces the window can show.</summary>
public enum Workspace
{
    Overview,
    Tweaks,
    Review,
    History,
    Diagnostics,
    Licensing,
}

/// <summary>Where the backend connection is, as the window renders it.</summary>
public enum ConnectionState
{
    /// <summary>A session is being started (process launch + handshake).</summary>
    Connecting,

    /// <summary>A live session answered its handshake.</summary>
    Ready,

    /// <summary>No session is running: stopped by the app, or the process ended.</summary>
    Disconnected,

    /// <summary>The connection attempt failed; the reason is in <c>ConnectionError</c>.</summary>
    Failed,
}

/// <summary>Where the backend startup sequence is.</summary>
public enum InitializationState
{
    /// <summary>Connecting / reading the handshake / loading text and environment.</summary>
    Loading,

    /// <summary>Handshake, text and environment all loaded.</summary>
    Ready,

    /// <summary>A stage failed; the window must show the reason and offer a retry.</summary>
    Failed,
}

/// <summary>
/// How a workspace's data stands. The four states are kept apart on purpose: a failed
/// request must never be presented as "empty", and a request in flight must never be
/// presented as a result.
/// </summary>
public enum LoadState
{
    /// <summary>Nothing requested yet.</summary>
    Idle,

    /// <summary>A request is in flight.</summary>
    Loading,

    /// <summary>Data arrived.</summary>
    Ready,

    /// <summary>The backend answered successfully, but with nothing in it.</summary>
    Empty,

    /// <summary>The request failed; <see cref="WorkspaceViewModel.ErrorText"/> says why.</summary>
    Failed,
}

/// <summary>
/// Shared behaviour for a workspace: it loads on demand, reports a busy flag, and keeps
/// its last error so the status bar can show it.
/// </summary>
/// <remarks>
/// The state is deliberately separated into four slots that are never merged:
/// <see cref="ReviewedChanges"/> (pending), <see cref="Busy"/> (running), the per-workspace
/// results, and the journal-backed history. A pending selection must never look like a
/// completed change, and a running operation must never look like a result.
/// </remarks>
public abstract class WorkspaceViewModel : ObservableObject
{
    private bool _loaded;
    private bool _busy;
    private bool _stale;
    private string _statusText = string.Empty;
    private string _errorText = string.Empty;
    private string _errorDetail = string.Empty;
    private LoadState _state = LoadState.Idle;

    /// <summary>Protected access to the backend.</summary>
    protected WorkspaceViewModel(ShellViewModel shell)
    {
        Shell = shell;
    }

    /// <summary>The owning shell (session, strings, dispatch).</summary>
    protected ShellViewModel Shell { get; }

    /// <summary>Localized text.</summary>
    protected LocalizationService Strings => Shell.Strings;

    /// <summary>True once <see cref="LoadAsync"/> has run.</summary>
    public bool Loaded
    {
        get => _loaded;
        protected set => Set(ref _loaded, value);
    }

    /// <summary>
    /// Where this workspace's data stands. A failure is never reported as "empty", and a
    /// request in flight is never reported as a result.
    /// </summary>
    public LoadState State
    {
        get => _state;
        private set
        {
            if (Set(ref _state, value))
            {
                Raise(nameof(IsLoading));
                Raise(nameof(IsReady));
                Raise(nameof(IsEmpty));
                Raise(nameof(IsFailed));
                OnStateChanged();
            }
        }
    }

    /// <summary>Raised for a derived workspace to re-publish the properties the state drives.</summary>
    protected virtual void OnStateChanged()
    {
    }

    /// <summary>True while a request for this workspace is in flight.</summary>
    public bool IsLoading => State == LoadState.Loading;

    /// <summary>True when data arrived.</summary>
    public bool IsReady => State == LoadState.Ready;

    /// <summary>True when the backend answered successfully with nothing in it.</summary>
    public bool IsEmpty => State == LoadState.Empty;

    /// <summary>True when the last request failed (see <see cref="ErrorText"/>).</summary>
    public bool IsFailed => State == LoadState.Failed;

    /// <summary>True while this workspace has a request in flight.</summary>
    public bool Busy
    {
        get => _busy;
        protected set => Set(ref _busy, value);
    }

    /// <summary>One line describing what is happening.</summary>
    public string StatusText
    {
        get => _statusText;
        protected set => Set(ref _statusText, value);
    }

    /// <summary>The last failure, or empty.</summary>
    public string ErrorText
    {
        get => _errorText;
        protected set
        {
            if (Set(ref _errorText, value))
            {
                Raise(nameof(HasError));
            }
        }
    }

    /// <summary>True when <see cref="ErrorText"/> carries something.</summary>
    public bool HasError => !string.IsNullOrEmpty(_errorText);

    /// <summary>The raw technical detail behind the last failure (expandable in the UI).</summary>
    public string ErrorDetail
    {
        get => _errorDetail;
        protected set => Set(ref _errorDetail, value);
    }

    /// <summary>
    /// True when this workspace shows data read from a connection that is no longer the
    /// live one. The data stays visible, but the UI says so instead of passing it off as
    /// current; reloading clears it.
    /// </summary>
    public bool IsStale
    {
        get => _stale;
        private set
        {
            if (Set(ref _stale, value))
            {
                Raise(nameof(StaleMessage));
            }
        }
    }

    /// <summary>Localized explanation of <see cref="IsStale"/>.</summary>
    public string StaleMessage => Strings["Gui.Data.Stale"];

    /// <summary>
    /// Marks the loaded data as belonging to a past connection and makes the next visit
    /// reload it. Staged selections live in the shell's review list, which is untouched.
    /// </summary>
    public void MarkStale()
    {
        if (!Loaded)
        {
            return;
        }

        IsStale = true;
        Loaded = false;
        State = LoadState.Idle;
    }

    /// <summary>Loads the workspace if it has not been loaded yet.</summary>
    public async Task EnsureLoadedAsync()
    {
        if (Loaded)
        {
            return;
        }

        await LoadAsync().ConfigureAwait(true);
    }

    /// <summary>Reloads the workspace unconditionally.</summary>
    public async Task ReloadAsync()
    {
        await LoadAsync().ConfigureAwait(true);
    }

    /// <summary>Retry after a failure (the visible Retry action).</summary>
    public Task RetryAsync()
    {
        ErrorText = string.Empty;
        ErrorDetail = string.Empty;
        return ReloadAsync();
    }

    /// <summary>Loads (or reloads) this workspace's data. Implemented by each workspace.</summary>
    protected abstract Task LoadAsync();

    /// <summary>Records that a successful load produced (or did not produce) rows.</summary>
    protected void MarkLoaded(int itemCount)
    {
        State = itemCount > 0 ? LoadState.Ready : LoadState.Empty;
        IsStale = false;
        ErrorDetail = string.Empty;
    }

    /// <summary>Runs a projection call and records its outcome. Returns true on success.</summary>
    protected async Task<bool> RunAsync<T>(
        string op,
        Func<System.Text.Json.JsonElement, T> project,
        Action<T> apply,
        IReadOnlyDictionary<string, object?>? args = null,
        TimeSpan? timeout = null,
        string? statusWhileRunning = null)
    {
        Busy = true;
        State = LoadState.Loading;
        ErrorText = string.Empty;
        ErrorDetail = string.Empty;
        if (statusWhileRunning is not null)
        {
            StatusText = statusWhileRunning;
        }

        try
        {
            var outcome = await Shell.Runner.RunAsync(op, project, args, timeout).ConfigureAwait(true);
            if (!outcome.Ok)
            {
                Fail(outcome.Code, outcome.Message);
                return false;
            }

            apply(outcome.Value!);
            return true;
        }
        catch (Exception exception)
        {
            // A handler fault must not take the window down; it becomes a visible failure
            // with a retry, exactly like a backend error.
            Fail("HandlerFailure", exception.Message);
            return false;
        }
        finally
        {
            Busy = false;
        }
    }

    /// <summary>
    /// Records a failure with a localized message and the raw detail kept separately, so
    /// the panel shows words the user can read and the expandable section keeps the exact
    /// technical answer.
    /// </summary>
    protected void Fail(string code, string detail)
    {
        ErrorDetail = string.IsNullOrWhiteSpace(detail) ? code : $"{code}: {detail}";
        ErrorText = Shell.DescribeFailure(code, detail);
        StatusText = ErrorText;
        State = LoadState.Failed;
    }
}

/// <summary>The overview workspace: environment, catalog size, and anything outstanding.</summary>
public sealed class OverviewViewModel : WorkspaceViewModel
{
    private int _tweakCount;
    private int _categoryCount;
    private int _interruptedCount;
    private int _reviewedCount;
    private bool _reviewSubscribed;

    public OverviewViewModel(ShellViewModel shell)
        : base(shell)
    {
        // The overview renders facts the shell owns; re-read them when the shell updates
        // them, so the panel is never stale after the environment arrives.
        Shell.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ShellViewModel.Environment)
                or nameof(ShellViewModel.EngineVersion)
                or nameof(ShellViewModel.BackendSummary))
            {
                RaiseEnvironment();
            }
        };

        RaiseEnvironment();
    }

    /// <summary>Number of tweaks in the catalog.</summary>
    public int TweakCount
    {
        get => _tweakCount;
        private set => Set(ref _tweakCount, value);
    }

    /// <summary>Number of categories.</summary>
    public int CategoryCount
    {
        get => _categoryCount;
        private set => Set(ref _categoryCount, value);
    }

    /// <summary>Operations that started and never finished (read-only count).</summary>
    public int InterruptedCount
    {
        get => _interruptedCount;
        private set => Set(ref _interruptedCount, value);
    }

    /// <summary>Changes waiting in the review list.</summary>
    public int ReviewedCount
    {
        get => _reviewedCount;
        private set => Set(ref _reviewedCount, value);
    }

    /// <summary>
    /// The catalog size, or the state that stands in for it. A failed or not-yet-run load
    /// never renders as counts, and a stale count is only shown for data that really was
    /// read (the panel marks it stale next to it).
    /// </summary>
    public string CatalogSummary => State switch
    {
        LoadState.Ready => Strings.Get("Gui.Overview.CatalogCount", TweakCount, CategoryCount),
        LoadState.Empty => Strings["Gui.Overview.Empty"],
        LoadState.Loading => Strings["Gui.Overview.Loading"],
        LoadState.Failed => Strings["Gui.Overview.NotLoaded"],
        _ when IsStale && (TweakCount > 0 || CategoryCount > 0) =>
            Strings.Get("Gui.Overview.CatalogCount", TweakCount, CategoryCount),
        _ => Strings["Gui.Overview.NotLoaded"],
    };

    /// <summary>True when <see cref="CatalogSummary"/> describes the catalog (not a state).</summary>
    public bool HasCatalogCounts => State == LoadState.Ready || (IsStale && TweakCount > 0);

    /// <summary>OS generation and build, from the engine's environment snapshot.</summary>
    public string OsText => Shell.Environment is { } environment
        ? $"{(string.IsNullOrEmpty(environment.OsVersionKey) ? environment.OsName : environment.OsVersionKey)} {environment.OsBuild}".Trim()
        : Strings["Gui.Overview.NotLoaded"];

    /// <summary>PowerShell host version reported by the engine.</summary>
    public string PowerShellText => Shell.Environment is { } environment && !string.IsNullOrEmpty(environment.PowerShellVersion)
        ? environment.PowerShellVersion
        : Strings["Gui.Overview.NotLoaded"];

    /// <summary>Privilege level reported by the engine.</summary>
    public string PrivilegeText => Shell.Environment is { } environment
        ? (environment.IsAdmin ? Strings["Gui.Overview.Admin"] : Strings["Gui.Overview.Standard"])
        : Strings["Gui.Overview.NotLoaded"];

    /// <summary>Engine (module) version reported by the handshake.</summary>
    public string EngineText => string.IsNullOrEmpty(Shell.EngineVersion)
        ? Strings["Gui.Overview.NotLoaded"]
        : Shell.EngineVersion;

    /// <summary>True when the environment snapshot is available.</summary>
    public bool HasEnvironment => Shell.Environment is not null;

    /// <inheritdoc />
    protected override async Task LoadAsync()
    {
        var catalog = await RunAsync(
            "catalog.list",
            Projections.Catalog,
            value =>
            {
                TweakCount = value.Tweaks.Count;
                CategoryCount = value.Categories.Count;
                Raise(nameof(CatalogSummary));
            }).ConfigureAwait(true);

        if (catalog)
        {
            await RunAsync(
                "history.interrupted",
                Projections.Interrupted,
                rows => InterruptedCount = rows.Count).ConfigureAwait(true);

            MarkLoaded(TweakCount);
        }

        // The pending count tracks the review list for the life of the shell. The
        // subscription is added once, not once per load, so repeated refreshes/retries do not
        // pile up handlers. It cannot happen in the constructor: the shell builds this
        // workspace before its review workspace exists.
        if (!_reviewSubscribed)
        {
            Shell.Review.Changes.CollectionChanged += (_, _) => ReviewedCount = Shell.Review.Changes.Count;
            _reviewSubscribed = true;
        }

        ReviewedCount = Shell.Review.Changes.Count;
        Loaded = true;
        RaiseEnvironment();
    }

    /// <summary>Re-publishes the properties the load state drives.</summary>
    protected override void OnStateChanged()
    {
        Raise(nameof(CatalogSummary));
        Raise(nameof(HasCatalogCounts));
    }

    private void RaiseEnvironment()
    {
        Raise(nameof(OsText));
        Raise(nameof(PowerShellText));
        Raise(nameof(PrivilegeText));
        Raise(nameof(EngineText));
        Raise(nameof(HasEnvironment));
        Raise(nameof(CatalogSummary));
    }
}
