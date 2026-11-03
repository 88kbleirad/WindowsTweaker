using System.Collections.ObjectModel;
using System.Globalization;
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

/// <summary>
/// One point of a time-series chart. <see cref="Value"/> is null when the reading for
/// that instant is absent; a chart must skip such points, never draw them as zero.
/// </summary>
/// <param name="Time">When the sample was taken, in local time.</param>
/// <param name="Value">The measured 0..100 percentage, or null when nothing was measured.</param>
public sealed record DataPoint(DateTimeOffset Time, double? Value);

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
    /// <summary>One sample per second: fast enough to look live, cheap enough to leave running.</summary>
    private static readonly TimeSpan MetricsInterval = TimeSpan.FromSeconds(1);

    /// <summary>
    /// The bridge call's own limit. A sample that cannot answer in fifteen seconds is a
    /// failure with a reason, not a hang that would hold the loop.
    /// </summary>
    private static readonly TimeSpan MetricsTimeout = TimeSpan.FromSeconds(15);

    /// <summary>One minute of history at one sample per second.</summary>
    private const int CpuTrendCapacity = 60;

    /// <summary>
    /// Serializes the loop's bookkeeping. The fields below are only ever swapped here, so
    /// starting and stopping from the UI cannot race the loop's own exit.
    /// </summary>
    private readonly object _metricsGate = new();

    /// <summary>
    /// Held across one bridge call. Two samples can therefore never overlap, however slow the
    /// engine is; the loop uses the waiting form so a slow sample delays the next tick instead
    /// of dropping it.
    /// </summary>
    private readonly SemaphoreSlim _metricsSampleGate = new(1, 1);

    private MetricsSnapshot? _metrics;
    private DateTimeOffset? _metricsUpdatedAt;
    private CancellationTokenSource? _metricsCancellation;

    /// <summary>
    /// Bumped on every start and stop. The loop that owns the number it was started with is
    /// the only one allowed to clear the state on its way out, so a stopped-then-restarted
    /// loop can neither hide the new one's flags nor clear its cancellation source.
    /// </summary>
    private volatile int _metricsGeneration;

    private int _metricsRunning;

    /// <summary>
    /// Whether the overview is the visible workspace, as the shell reports it. It starts as
    /// true because the shell's initial workspace is the overview: until the shell reports
    /// visibility on its first navigation, sampling follows the current workspace and the
    /// connection, which is exactly the same rule.
    /// </summary>
    private bool _metricsVisible = true;

    private LoadState _metricsState = LoadState.Idle;
    private string _metricsErrorText = string.Empty;
    private string _metricsErrorDetail = string.Empty;

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
            else if (e.PropertyName is nameof(ShellViewModel.Current)
                or nameof(ShellViewModel.IsConnected))
            {
                // Sampling follows the workspace that is on screen and the live connection:
                // navigating away - or losing the backend - stops it, arriving at a connected
                // overview starts it. The view may also drive it directly.
                SyncMetricsSampling();
            }
        };

        // The metric text is localized too: a language switch must re-read every label from
        // the tables, so the values are re-raised rather than re-sampled.
        Shell.Strings.LanguageChanged += (_, _) =>
        {
            RaiseMetrics();
            Raise(nameof(InterruptedNoteText));
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
        private set
        {
            if (Set(ref _interruptedCount, value))
            {
                Raise(nameof(InterruptedVisible));
                Raise(nameof(InterruptedNoteText));
            }
        }
    }

    /// <summary>
    /// True when an operation started and never finished: the window shows a warning strip,
    /// because an unfinished change is a fact the user has to act on, not a statistic.
    /// </summary>
    public bool InterruptedVisible => InterruptedCount > 0;

    /// <summary>
    /// The localized description of the action that takes the user to those operations. It is
    /// only text: navigating is the shell's decision, so this workspace never navigates.
    /// </summary>
    public string InterruptedNoteText => Strings["Gui.Overview.InterruptedAction"];

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

    // ---- live metrics ---------------------------------------------------------
    //
    // Every value below is computed from the last sample, so a null measurement is rendered as
    // the localized "not measured" text and never as a zero, and nothing here touches the
    // workspace's own load state (a metric hiccup must not empty the catalog panel).

    /// <summary>
    /// The CPU percentages of the last minute, oldest first, one value per second. The instance
    /// is created once and mutated in place (a chart bound to it sees the appends), and it is
    /// capped at <see cref="CpuTrendCapacity"/> samples so a window left open all day cannot
    /// grow it.
    /// </summary>
    public ObservableCollection<double> CpuTrend { get; } = new();

    /// <summary>True when the trend holds enough points to draw (two or more).</summary>
    public bool CpuTrendVisible => CpuTrend.Count >= 2;

    /// <summary>
    /// The CPU chart's points, oldest first, one per second, each stamped with the local
    /// sample time. It replaces <see cref="CpuTrend"/> as the chart's source; the raw
    /// trend stays for back-compatibility. A point whose reading is absent is never
    /// added, so a chart never draws a fabricated zero.
    /// </summary>
    public ObservableCollection<DataPoint> CpuHistory { get; } = new();

    /// <summary>
    /// The RAM chart's points, oldest first, one per second, measured as used percentage.
    /// See <see cref="CpuHistory"/> for the gap rule.
    /// </summary>
    public ObservableCollection<DataPoint> RamHistory { get; } = new();

    /// <summary>
    /// True when the CPU chart holds two or more fresh points. A collection with fewer
    /// points (or points older than the sample window) is not drawn.
    /// </summary>
    public bool CpuChartVisible => CountFresh(CpuHistory) >= 2;

    /// <summary>True when the RAM chart holds two or more fresh points.</summary>
    public bool RamChartVisible => CountFresh(RamHistory) >= 2;

    /// <summary>
    /// True when the four gauge cards show measurements from the live connection. It is
    /// false before the first sample, while a sample is in flight, and after a sampling
    /// failure - the cards then keep their last values, and the view marks them stale
    /// with <see cref="StaleNote"/>.
    /// </summary>
    public bool QuadFresh => _metrics is not null && MetricsState == LoadState.Ready;

    /// <summary>Localized note that the gauges show stale data.</summary>
    public string StaleNote => Strings["Gui.Data.Stale"];

    /// <summary>True only while the sampling loop is running for this workspace.</summary>
    public bool MetricsSampling => Volatile.Read(ref _metricsRunning) == 1;

    /// <summary>True whenever sampling is not running (not started, stopped, or paused).</summary>
    public bool MetricsPaused => !MetricsSampling;

    /// <summary>The measured CPU percentage, or null when that card was not measured.</summary>
    public double? CpuPercent => _metrics?.Cpu.Percent;

    /// <summary>How far the CPU number can be trusted (the engine's own word).</summary>
    public MetricQuality CpuQuality => _metrics?.Cpu.Quality ?? MetricQuality.Unavailable;

    /// <summary>The engine's note for the CPU card (why it is missing, when it is).</summary>
    public string CpuNote => _metrics?.Cpu.Note ?? string.Empty;

    /// <summary>The CPU value as a whole percentage ("42%"), or the localized "not measured" text.</summary>
    public string CpuValueText => PercentText(CpuPercent);

    /// <summary>
    /// The CPU card's detail line: the caption of the drawn trend while there is one, otherwise
    /// the engine's note (which is where the reason for a missing measurement is written).
    /// </summary>
    public string CpuDetailText => CpuTrendVisible ? Strings["Gui.Metrics.Trend"] : CpuNote;

    /// <summary>Total physical memory in bytes, or null when it was not measured.</summary>
    public double? RamTotalBytes => _metrics?.Memory.TotalBytes;

    /// <summary>Used physical memory in bytes, or null when it was not measured.</summary>
    public double? RamUsedBytes => _metrics?.Memory.UsedBytes;

    /// <summary>Used memory as "12.3 / 16.0 GiB", or the localized "not measured" text.</summary>
    public string RamValueText => RamTotalBytes is { } total && RamUsedBytes is { } used
        ? $"{Gib(used)} / {Gib(total)} GiB"
        : Strings["Gui.Metrics.Unavailable"];

    /// <summary>Used memory as a whole percentage, or empty when it was not measured.</summary>
    public string RamPercentText => RamBarVisible
        ? Strings.Get("Gui.Metrics.Percent", Percent(RamUsedPercent))
        : string.Empty;

    /// <summary>
    /// Used memory as a percentage for the bar (0..100). It is 0 only because nothing was
    /// measured - <see cref="RamBarVisible"/> is what the view must bind, so a missing
    /// measurement is never drawn as an empty bar.
    /// </summary>
    public double RamUsedPercent => RamTotalBytes is { } total && RamUsedBytes is { } used && total > 0
        ? Math.Clamp(used / total * 100d, 0d, 100d)
        : 0d;

    /// <summary>True only when both memory numbers were measured.</summary>
    public bool RamBarVisible => RamTotalBytes is { } total && RamUsedBytes is not null && total > 0;

    /// <summary>How far the memory numbers can be trusted.</summary>
    public MetricQuality RamQuality => _metrics?.Memory.Quality ?? MetricQuality.Unavailable;

    /// <summary>The engine's note for the memory card.</summary>
    public string RamNote => _metrics?.Memory.Note ?? string.Empty;

    /// <summary>The system drive's letter as the engine reports it ("C:\"), or empty.</summary>
    public string DiskDriveText => _metrics?.Disk.Drive ?? string.Empty;

    /// <summary>The system drive's total size in bytes, or null when it was not measured.</summary>
    public double? DiskTotalBytes => _metrics?.Disk.TotalBytes;

    /// <summary>Free space in bytes, or null when it was not measured.</summary>
    public double? DiskFreeBytes => _metrics?.Disk.FreeBytes;

    /// <summary>Used space in bytes: the difference of two measurements, or null when either is missing.</summary>
    public double? DiskUsedBytes => DiskTotalBytes is { } total && DiskFreeBytes is { } free ? Math.Max(0d, total - free) : null;

    /// <summary>Used space as "45.2 / 99.5 GiB", or the localized "not measured" text.</summary>
    public string DiskValueText => DiskTotalBytes is { } total && DiskUsedBytes is { } used
        ? $"{Gib(used)} / {Gib(total)} GiB"
        : Strings["Gui.Metrics.Unavailable"];

    /// <summary>Free space as "Free 45.2 GiB", or empty when it was not measured.</summary>
    public string DiskFreeText => DiskFreeBytes is { } free
        ? Strings.Get("Gui.Metrics.Free", $"{Gib(free)} GiB")
        : string.Empty;

    /// <summary>Used space as a percentage for the bar (0..100); see <see cref="RamUsedPercent"/>.</summary>
    public double DiskUsedPercent => DiskTotalBytes is { } total && DiskUsedBytes is { } used && total > 0
        ? Math.Clamp(used / total * 100d, 0d, 100d)
        : 0d;

    /// <summary>True only when both drive numbers were measured.</summary>
    public bool DiskBarVisible => DiskTotalBytes is { } total && DiskFreeBytes is not null && total > 0;

    /// <summary>How far the drive numbers can be trusted.</summary>
    public MetricQuality DiskQuality => _metrics?.Disk.Quality ?? MetricQuality.Unavailable;

    /// <summary>The engine's note for the drive card.</summary>
    public string DiskNote => _metrics?.Disk.Note ?? string.Empty;

    /// <summary>The adapter the engine reported, or the localized "adapter not reported" text.</summary>
    public string GpuAdapterText => _metrics?.Gpu.Name is { Length: > 0 } name
        ? name
        : Strings["Gui.Metrics.AdapterUnknown"];

    /// <summary>The measured GPU utilization, or null when it was not measured.</summary>
    public double? GpuUtilizationPercent => _metrics?.Gpu.UtilizationPercent;

    /// <summary>The GPU utilization as a whole percentage, or the localized "not measured" text.</summary>
    public string GpuUtilizationText => PercentText(GpuUtilizationPercent);

    /// <summary>True only when a utilization was measured (a VM reports the adapter without one).</summary>
    public bool GpuUtilizationVisible => GpuUtilizationPercent is not null;

    /// <summary>How far the GPU numbers can be trusted.</summary>
    public MetricQuality GpuQuality => _metrics?.Gpu.Quality ?? MetricQuality.Unavailable;

    /// <summary>The engine's note for the GPU card.</summary>
    public string GpuNote => _metrics?.Gpu.Note ?? string.Empty;

    /// <summary>Where the metrics section stands: idle, first sample in flight, ready, or failed.</summary>
    public LoadState MetricsState
    {
        get => _metricsState;
        private set => Set(ref _metricsState, value);
    }

    /// <summary>
    /// The last sampling failure, in words (never the raw code). It is cleared by the next
    /// successful sample, because the cards then show live numbers again.
    /// </summary>
    public string MetricsErrorText
    {
        get => _metricsErrorText;
        private set => Set(ref _metricsErrorText, value);
    }

    /// <summary>The raw code and message behind <see cref="MetricsErrorText"/>, for the expander.</summary>
    public string MetricsErrorDetail
    {
        get => _metricsErrorDetail;
        private set => Set(ref _metricsErrorDetail, value);
    }

    /// <summary>
    /// "Updated 14:03:21" for the newest sample, in local time. Empty until something has been
    /// measured, so the card never claims a time it does not have.
    /// </summary>
    public string MetricsUpdatedText => _metricsUpdatedAt is { } updated
        ? Strings.Get("Gui.Metrics.LastUpdated", updated.ToLocalTime().ToString("T", CultureInfo.CurrentCulture))
        : string.Empty;

    /// <summary>
    /// Told by the shell, on every navigation, whether the overview is the visible workspace.
    /// Sampling runs only while it is - and only with a ready backend - so navigating away
    /// stops the loop instead of polling the backend behind another panel.
    /// </summary>
    public void SetMetricsVisible(bool visible)
    {
        _metricsVisible = visible;
        if (visible)
        {
            StartMetricsSampling();
        }
        else
        {
            StopMetricsSampling();
        }
    }

    /// <summary>
    /// Starts the sampling loop: one sample per second, only while the overview is on screen and
    /// the backend is ready. Calling it twice starts one loop, and calling it while the backend
    /// is not ready starts nothing.
    /// </summary>
    public void StartMetricsSampling()
    {
        if (!Shell.IsConnected || Shell.Current != Workspace.Overview)
        {
            return;
        }

        CancellationTokenSource cancellation;
        int generation;
        lock (_metricsGate)
        {
            if (_metricsCancellation is not null)
            {
                // Exactly one loop: a second start is the same loop, not another one.
                return;
            }

            cancellation = new CancellationTokenSource();
            _metricsCancellation = cancellation;
            generation = ++_metricsGeneration;
        }

        if (Interlocked.Exchange(ref _metricsRunning, 1) == 0)
        {
            Raise(nameof(MetricsSampling));
            Raise(nameof(MetricsPaused));
        }

        if (_metrics is null && MetricsState == LoadState.Idle)
        {
            // Nothing has been measured yet: say so, rather than showing a blank card.
            MetricsState = LoadState.Loading;
        }

        _ = RunMetricsLoopAsync(cancellation, generation);
    }

    /// <summary>
    /// Stops the loop and cancels the sample in flight. It is safe to call at any time, from any
    /// state, and it is what the view calls when the overview leaves the screen or the window
    /// closes; the values already measured stay on screen.
    /// </summary>
    public void StopMetricsSampling()
    {
        CancellationTokenSource? cancellation;
        lock (_metricsGate)
        {
            cancellation = _metricsCancellation;
            _metricsCancellation = null;
            _metricsGeneration++;
        }

        if (cancellation is not null)
        {
            try
            {
                cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // The loop finished on its own and released the source before this call.
            }
        }

        if (Interlocked.Exchange(ref _metricsRunning, 0) == 1)
        {
            Raise(nameof(MetricsSampling));
            Raise(nameof(MetricsPaused));
        }

        if (_metrics is null && MetricsState == LoadState.Loading)
        {
            // Stopped before the first sample arrived: back to "nothing requested" instead of
            // leaving the cards claiming they are being measured.
            MetricsState = LoadState.Idle;
        }
    }

    /// <summary>Starts or stops sampling to match what is on screen and whether the backend is live.</summary>
    private void SyncMetricsSampling()
    {
        if (_metricsVisible && Shell.IsConnected && Shell.Current == Workspace.Overview)
        {
            StartMetricsSampling();
        }
        else
        {
            StopMetricsSampling();
        }
    }

    /// <summary>
    /// The sampling loop. It exits quietly on cancellation (stopping, navigating away) and when
    /// the connection is no longer ready (the backend exited); one failed sample is reported on
    /// the cards and the loop carries on, because a transient failure is not a dead backend.
    /// </summary>
    private async Task RunMetricsLoopAsync(CancellationTokenSource cancellation, int generation)
    {
        var token = cancellation.Token;
        try
        {
            while (!token.IsCancellationRequested)
            {
                if (!Shell.IsConnected)
                {
                    break;
                }

                await SampleMetricsAsync(token).ConfigureAwait(false);

                if (token.IsCancellationRequested)
                {
                    break;
                }

                await Task.Delay(MetricsInterval, token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // Stopping is how this loop is meant to end, not a failure.
        }
        catch (ObjectDisposedException)
        {
            // The shell closed under a running sample; nothing left to report it to.
        }
        finally
        {
            lock (_metricsGate)
            {
                if (_metricsGeneration == generation)
                {
                    _metricsCancellation = null;
                }
            }

            cancellation.Dispose();

            // Only the loop that is still current may report the stop: a restarted loop owns
            // the flag by then, and a stale loop must not clear it.
            if (_metricsGeneration == generation && Interlocked.Exchange(ref _metricsRunning, 0) == 1)
            {
                Shell.Dispatch(() =>
                {
                    Raise(nameof(MetricsSampling));
                    Raise(nameof(MetricsPaused));
                });
            }
        }
    }

    /// <summary>
    /// Takes one sample. Nothing else is ever called: this is a read-only snapshot of the local
    /// machine, not a workspace reload and not a process launch.
    /// </summary>
    private async Task SampleMetricsAsync(CancellationToken token)
    {
        try
        {
            await _metricsSampleGate.WaitAsync(token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        try
        {
            var outcome = await Shell.Runner.RunAsync(
                "metrics.snapshot",
                Projections.MetricsSnapshot,
                timeout: MetricsTimeout,
                cancellationToken: token).ConfigureAwait(false);

            if (token.IsCancellationRequested)
            {
                // Stopped while the answer was on its way: the reading belongs to a loop that
                // is gone, so it is dropped instead of being applied.
                return;
            }

            if (outcome.Ok && outcome.Value is { } snapshot)
            {
                Shell.Dispatch(() => ApplyMetrics(snapshot));
            }
            else
            {
                var code = outcome.Code;
                var message = outcome.Message;
                Shell.Dispatch(() => ApplyMetricsFailure(code, message));
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        finally
        {
            _metricsSampleGate.Release();
        }
    }

    /// <summary>Publishes one successful sample: values, timestamp, the bounded trend, and the labels.</summary>
    private void ApplyMetrics(MetricsSnapshot snapshot)
    {
        _metrics = snapshot;
        _metricsUpdatedAt = Timestamp(snapshot.TimestampMs);
        MetricsErrorText = string.Empty;
        MetricsErrorDetail = string.Empty;
        MetricsState = LoadState.Ready;

        var stamp = _metricsUpdatedAt ?? DateTimeOffset.Now;

        if (snapshot.Cpu.Percent is { } percent)
        {
            // Only a measured value enters the trend: a gap must not be drawn as a zero.
            CpuTrend.Add(Math.Clamp(percent, 0d, 100d));
            while (CpuTrend.Count > CpuTrendCapacity)
            {
                CpuTrend.RemoveAt(0);
            }

            CpuHistory.Add(new DataPoint(stamp, Math.Clamp(percent, 0d, 100d)));
            while (CpuHistory.Count > CpuTrendCapacity)
            {
                CpuHistory.RemoveAt(0);
            }
        }

        if (snapshot.Memory.TotalBytes is { } total && snapshot.Memory.UsedBytes is { } used && total > 0)
        {
            RamHistory.Add(new DataPoint(stamp, Math.Clamp(used / total * 100d, 0d, 100d)));
            while (RamHistory.Count > CpuTrendCapacity)
            {
                RamHistory.RemoveAt(0);
            }
        }

        RaiseMetrics();
    }

    /// <summary>Publishes one failed sample. The cards keep their last values and say what happened.</summary>
    private void ApplyMetricsFailure(string code, string message)
    {
        MetricsErrorDetail = string.IsNullOrWhiteSpace(message) ? code : $"{code}: {message}";
        MetricsErrorText = Shell.DescribeFailure(code, message);
        MetricsState = LoadState.Failed;
        Raise(nameof(QuadFresh));
    }

    /// <summary>Re-publishes every property this dashboard computes, after a sample or a language switch.</summary>
    private void RaiseMetrics()
    {
        Raise(nameof(CpuPercent));
        Raise(nameof(CpuQuality));
        Raise(nameof(CpuNote));
        Raise(nameof(CpuValueText));
        Raise(nameof(CpuDetailText));
        Raise(nameof(CpuTrendVisible));
        Raise(nameof(CpuChartVisible));
        Raise(nameof(RamChartVisible));
        Raise(nameof(QuadFresh));
        Raise(nameof(StaleNote));
        Raise(nameof(RamTotalBytes));
        Raise(nameof(RamUsedBytes));
        Raise(nameof(RamValueText));
        Raise(nameof(RamPercentText));
        Raise(nameof(RamUsedPercent));
        Raise(nameof(RamBarVisible));
        Raise(nameof(RamQuality));
        Raise(nameof(RamNote));
        Raise(nameof(DiskDriveText));
        Raise(nameof(DiskTotalBytes));
        Raise(nameof(DiskFreeBytes));
        Raise(nameof(DiskUsedBytes));
        Raise(nameof(DiskValueText));
        Raise(nameof(DiskFreeText));
        Raise(nameof(DiskUsedPercent));
        Raise(nameof(DiskBarVisible));
        Raise(nameof(DiskQuality));
        Raise(nameof(DiskNote));
        Raise(nameof(GpuAdapterText));
        Raise(nameof(GpuUtilizationPercent));
        Raise(nameof(GpuUtilizationText));
        Raise(nameof(GpuUtilizationVisible));
        Raise(nameof(GpuQuality));
        Raise(nameof(GpuNote));
        Raise(nameof(MetricsUpdatedText));
        Raise(nameof(MetricsState));
    }

    /// <summary>
    /// Counts the history points that are fresh enough to draw: within the bounded sample
    /// window (60 s at one sample per second), so a collection with one fresh point and a
    /// tail that stopped an hour ago never draws a chart.
    /// </summary>
    private static int CountFresh(ObservableCollection<DataPoint> history)
    {
        var cutoff = DateTimeOffset.Now - TimeSpan.FromSeconds(CpuTrendCapacity + 5);
        var fresh = 0;
        foreach (var point in history)
        {
            if (point.Time >= cutoff)
            {
                fresh++;
            }
        }

        return fresh;
    }

    /// <summary>A whole percentage ("42%"), or the localized text for "nothing was measured".</summary>
    private string PercentText(double? percent) => percent is { } value
        ? Strings.Get("Gui.Metrics.Percent", Percent(value))
        : Strings["Gui.Metrics.Unavailable"];

    /// <summary>Rounds to a whole percentage, invariantly; the number never carries a culture.</summary>
    private static string Percent(double value) =>
        ((int)Math.Round(Math.Clamp(value, 0d, 100d), MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);

    /// <summary>Bytes as GiB with one decimal, invariantly ("12.3"). The unit is added by the caller.</summary>
    private static string Gib(double bytes) =>
        (bytes / 1024d / 1024d / 1024d).ToString("0.0", CultureInfo.InvariantCulture);

    /// <summary>
    /// The engine's sample clock in local time. A document without a usable stamp is stamped on
    /// arrival, so the "updated" line is never empty after a successful sample and never shows
    /// the epoch.
    /// </summary>
    private static DateTimeOffset Timestamp(long timestampMs) => timestampMs is > 0 and < 4_102_444_800_000
        ? DateTimeOffset.FromUnixTimeMilliseconds(timestampMs)
        : DateTimeOffset.Now;

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
