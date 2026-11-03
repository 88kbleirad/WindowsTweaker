using System.Diagnostics;
using System.Text.Json;
using WindowsTweaker.Gui.Core.Bridge;
using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.Protocol;

namespace WindowsTweaker.Gui.Core.ViewModels;

/// <summary>Where the backend session is.</summary>
public enum BackendState
{
    /// <summary>No session has been started in this process yet.</summary>
    NotStarted,

    /// <summary>A session is being started (process launch + handshake).</summary>
    Connecting,

    /// <summary>A session is alive and answering.</summary>
    Ready,

    /// <summary>No session: it was stopped by the app, or the process ended.</summary>
    Disconnected,

    /// <summary>The last connection attempt failed.</summary>
    Failed,
}

/// <summary>A change of <see cref="BackendState"/>, with the technical detail behind it.</summary>
/// <param name="State">The new state.</param>
/// <param name="Reason">Short machine-readable reason (for diagnostics).</param>
/// <param name="ExitCode">Process exit code when a process ended, else 0.</param>
/// <param name="Detail">Raw technical detail: engine message, stderr tail, exception text.</param>
public sealed record BackendStateChange(BackendState State, string Reason, int ExitCode, string Detail);

/// <summary>One traced request: what was asked, how long it took and how it ended.</summary>
public sealed record BackendActivity(string Operation, string RequestId, long ElapsedMs, bool Ok, string Code, string Message);

/// <summary>
/// The one place the view models talk to the backend.
/// </summary>
/// <remarks>
/// It owns the single session and is the single source of truth for whether the backend is
/// usable. The rules it keeps for the UI:
/// <list type="bullet">
/// <item>there is never more than one backend process: connecting stops whatever session
/// exists first, and a session is only ever replaced after the old one is dealt with;</item>
/// <item>a session that died is detected on the next call as well as by its exit event, so
/// the UI cannot keep showing a connection that is gone;</item>
/// <item>every request carries the connection generation that issued it, and a result that
/// arrives after the generation moved on is rejected instead of applied - the UI can never
/// be repopulated from a connection it no longer uses;</item>
/// <item>an engine error becomes a typed message (code + raw detail) instead of an exception
/// the UI would have to stringify, and every request is traced for diagnostics.</item>
/// </list>
/// Every method returns a result object, so a view model never catches for control flow.
/// </remarks>
public sealed class BridgeRunner : IAsyncDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, byte> _inFlight = new(StringComparer.Ordinal);
    private BridgeSession? _session;
    private string? _dataRootOverride;
    private string _activeRequestId = string.Empty;
    private long _generation;
    private int _disposeRequested;
    private BackendState _state = BackendState.NotStarted;
    private BackendStateChange _lastChange = new(BackendState.NotStarted, "created", 0, string.Empty);

    /// <summary>The handshake of the current session, once connected.</summary>
    public BridgeHello? Hello => _session?.Hello;

    /// <summary>
    /// The process id of the current session's backend, or null when there is none. The
    /// runner owns exactly one session, so this is the only backend process the app has.
    /// </summary>
    public int? BackendProcessId => _session?.ProcessId;

    /// <summary>True while a backend session is alive and usable.</summary>
    public bool IsConnected => _session is { IsRunning: true };

    /// <summary>
    /// The connection generation. It changes whenever the current session is replaced or
    /// dropped, which is what makes a late answer detectable as belonging to the past.
    /// </summary>
    public long Generation => Volatile.Read(ref _generation);

    /// <summary>Where the session stands.</summary>
    public BackendState State => _state;

    /// <summary>The reason behind the current state, with the raw technical detail.</summary>
    public BackendStateChange LastChange => _lastChange;

    /// <summary>The last stderr lines of the current (or most recent) session, for the error panel.</summary>
    public string StderrTail => _session?.StderrTail ?? _lastChange.Detail;

    /// <summary>The id of the request that is currently in flight, so a cancel reaches the work it
    /// is meant for instead of guessing. Empty when nothing is running.</summary>
    public string ActiveRequestId => Volatile.Read(ref _activeRequestId);

    /// <summary>
    /// Every request that is currently in flight, by id. Progress frames name the request
    /// they belong to, so the UI can attribute a progress line to a live request instead of
    /// guessing - and it can tell that a line belongs to nobody once the whole set is empty.
    /// </summary>
    public bool AnyRequestInFlight => !_inFlight.IsEmpty;

    /// <summary>True when the given request id is in flight right now.</summary>
    public bool IsRequestInFlight(string requestId) =>
        !string.IsNullOrEmpty(requestId) && _inFlight.ContainsKey(requestId);

    /// <summary>Raised when the session state changes (may be raised from a reader thread).</summary>
    public event EventHandler<BackendStateChange>? StateChanged;

    /// <summary>Raised for every request with its outcome and timing.</summary>
    public event EventHandler<BackendActivity>? Activity;

    /// <summary>Raised for progress frames (on the reader task; the caller marshals).</summary>
    public event EventHandler<BridgeProgress>? Progress;

    /// <summary>Raised when the process of the <em>current</em> session ends.</summary>
    public event EventHandler<int>? Exited;

    /// <summary>Raised for backend diagnostics (stderr, dropped frames).</summary>
    public event EventHandler<string>? Diagnostic;

    /// <summary>Sets the data root handed to the backend process's environment.</summary>
    public void UseDataRoot(string dataRoot)
    {
        _dataRootOverride = dataRoot;
    }

    /// <summary>
    /// Starts a session. Stops any existing session first, so a connect can never leave two
    /// backend processes behind. Returns null on success, else the reason.
    /// Never throws.
    /// </summary>
    public async Task<string?> ConnectAsync(string repositoryRoot, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Already running: connecting again is a no-op, not a second process.
            if (IsConnected)
            {
                return null;
            }

            // A dead or stopped session must not be left behind: it would still receive the
            // exit event and report a connection the UI does not have.
            await StopCoreAsync(allowKill: true, reason: "reconnect").ConfigureAwait(false);

            if (!string.IsNullOrWhiteSpace(_dataRootOverride))
            {
                Environment.SetEnvironmentVariable("WT_DATA_ROOT", _dataRootOverride);
                Environment.SetEnvironmentVariable("WT_STATE_PATH", Path.Combine(_dataRootOverride!, "state.json"));
                Environment.SetEnvironmentVariable("WT_LOG_DIRECTORY", Path.Combine(_dataRootOverride!, "logs"));
            }

            SetState(BackendState.Connecting, "connecting", 0, string.Empty);
            try
            {
                var session = await BridgeSession.StartAsync(repositoryRoot, cancellationToken: cancellationToken).ConfigureAwait(false);
                session.Progress += (sender, progress) => Progress?.Invoke(sender, progress);
                session.Diagnostic += (sender, message) => Diagnostic?.Invoke(sender, message);
                session.Exited += (sender, code) => OnSessionExited(session, code);
                _session = session;
                Interlocked.Increment(ref _generation);
                SetState(BackendState.Ready, "connected", 0, string.Empty);
                return null;
            }
            catch (Exception exception)
            {
                var message = exception is BridgeException ? exception.Message : $"The backend could not be started: {exception.Message}";
                var detail = exception is BridgeException { InnerException: { } inner } ? $"{message} | {inner.GetType().Name}: {inner.Message}" : message;
                SetState(BackendState.Failed, "connect-failed", 0, detail);
                return message;
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Stops the current session and leaves the runner disconnected. The connection
    /// generation moves on immediately, so nothing produced by the stopped session can be
    /// applied afterwards. Returns what the shutdown achieved.
    /// </summary>
    /// <param name="allowKill">Only true when no mutating operation is in flight.</param>
    /// <param name="reason">Why the session is being stopped (diagnostics).</param>
    public async Task<ShutdownOutcome> StopAsync(bool allowKill, string reason)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            return await StopCoreAsync(allowKill, reason).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<ShutdownOutcome> StopCoreAsync(bool allowKill, string reason)
    {
        var session = Interlocked.Exchange(ref _session, null);
        if (session is null)
        {
            if (_state is not (BackendState.Disconnected or BackendState.NotStarted))
            {
                SetState(BackendState.Disconnected, reason, 0, "no session");
            }

            return ShutdownOutcome.AlreadyStopped;
        }

        // Detach first: any request still in flight belongs to the past from here on.
        Interlocked.Increment(ref _generation);
        SetState(BackendState.Disconnected, reason, 0, session.StderrTail);

        ShutdownOutcome outcome;
        try
        {
            outcome = await session.ShutdownAsync(allowKill).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            Report($"the backend could not be stopped cleanly: {exception.Message}");
            outcome = ShutdownOutcome.NotStopped;
        }

        // Always release the session's handles: the process received its quit (or its stdin
        // is closed here), so there is nothing left for this session to own.
        await session.DisposeAsync().ConfigureAwait(false);

        if (outcome == ShutdownOutcome.NotStopped)
        {
            SetState(BackendState.Disconnected, "stop-incomplete", 0, session.StderrTail);
        }

        return outcome;
    }

    /// <summary>Runs an operation, returning a typed outcome.</summary>
    public async Task<BridgeOutcome<T>> RunAsync<T>(
        string op,
        Func<JsonElement, T> project,
        IReadOnlyDictionary<string, object?>? args = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var session = _session;
        if (session is null || !session.IsRunning)
        {
            OnSessionGone(session, "not-running");
            return BridgeOutcome<T>.Failure("The backend is not running.", ProtocolConstants.ErrorCode.BackendDown);
        }

        var generation = Volatile.Read(ref _generation);
        var watch = Stopwatch.StartNew();
        var requestId = string.Empty;

        try
        {
            var task = session.SendAsync(op, args, timeout, cancellationToken);
            requestId = session.LastRequestId;
            Volatile.Write(ref _activeRequestId, requestId);
            _inFlight[requestId] = 1;
            var payload = await task.ConfigureAwait(false);
            watch.Stop();

            // The answer belongs to a connection that is no longer current: it must not be
            // applied, even though it arrived intact.
            if (IsStale(generation))
            {
                return Stale<T>(op, requestId, watch);
            }

            try
            {
                return Trace(op, requestId, watch, BridgeOutcome<T>.Success(project(payload)));
            }
            catch (Exception exception)
            {
                // A payload this projection cannot read is a failure with a reason, never
                // an exception that would abort the caller's startup sequence.
                return Trace(
                    op,
                    requestId,
                    watch,
                    BridgeOutcome<T>.Failure(
                        $"The '{op}' answer could not be read: {exception.Message}",
                        "ProjectionFailed"));
            }
        }
        catch (BridgeOperationException exception)
        {
            if (IsStale(generation))
            {
                return Stale<T>(op, requestId, watch);
            }

            return Trace(op, string.Empty, watch, BridgeOutcome<T>.Failure(exception.Message, exception.Code ?? "BackendError"));
        }
        catch (BridgeException exception)
        {
            if (IsStale(generation))
            {
                // The request belonged to a session that has been replaced. Whatever
                // happened to the old session (a clean stop, an exit, a transport
                // failure) is a fact about the past connection, not about the one the
                // window is using now, so the answer is reported as stale and never as a
                // current-session failure.
                return Stale<T>(op, requestId, watch);
            }

            var code = exception.Code ?? ProtocolConstants.ErrorCode.BackendDown;
            if (code == ProtocolConstants.ErrorCode.BackendDown)
            {
                // The process is gone (or was already gone): the state must say so at once.
                OnSessionGone(session, "exited");
            }

            return Trace(op, string.Empty, watch, BridgeOutcome<T>.Failure(exception.Message, code));
        }
        catch (OperationCanceledException)
        {
            if (IsStale(generation))
            {
                return Stale<T>(op, requestId, watch);
            }

            return Trace(op, string.Empty, watch, BridgeOutcome<T>.Failure("The request was cancelled.", "Cancelled"));
        }
        finally
        {
            if (!string.IsNullOrEmpty(requestId))
            {
                _inFlight.TryRemove(requestId, out _);
            }

            Volatile.Write(ref _activeRequestId, string.Empty);
        }
    }

    /// <summary>True when the generation that issued the request is no longer current.</summary>
    private bool IsStale(long generation) => generation != Volatile.Read(ref _generation);

    /// <summary>The typed stale-answer failure shared by every outcome path.</summary>
    private BridgeOutcome<T> Stale<T>(string op, string requestId, Stopwatch watch) =>
        Trace(
            op,
            requestId,
            watch,
            BridgeOutcome<T>.Failure(
                "The answer arrived after the backend session was replaced and was discarded.",
                ProtocolConstants.ErrorCode.StaleConnection));

    private BridgeOutcome<T> Trace<T>(string op, string requestId, Stopwatch watch, BridgeOutcome<T> outcome)
    {
        watch.Stop();
        Activity?.Invoke(this, new BackendActivity(op, requestId, watch.ElapsedMilliseconds, outcome.Ok, outcome.Code, outcome.Message));
        return outcome;
    }

    /// <summary>Cancels whatever request is currently in flight.</summary>
    public Task<bool> CancelActiveAsync() => CancelAsync(ActiveRequestId);

    /// <summary>Asks the backend to cancel the work behind a request id.</summary>
    public async Task<bool> CancelAsync(string targetRequestId)
    {
        var session = _session;
        if (session is null || !session.IsRunning)
        {
            return false;
        }

        try
        {
            var payload = await session.CancelAsync(targetRequestId).ConfigureAwait(false);
            return payload.ValueKind == JsonValueKind.Object
                && payload.TryGetProperty("stopped", out var stopped)
                && stopped.ValueKind == JsonValueKind.True;
        }
        catch (BridgeException)
        {
            return false;
        }
    }

    /// <summary>Records that the current session is gone (exit event or a failed send).</summary>
    private void OnSessionExited(BridgeSession session, int exitCode)
    {
        var wasCurrent = ReferenceEquals(Interlocked.CompareExchange(ref _session, null, session), session);
        if (wasCurrent)
        {
            Interlocked.Increment(ref _generation);
            var detail = string.IsNullOrWhiteSpace(session.StderrTail)
                ? $"The backend process ended (exit code {exitCode})."
                : session.StderrTail;
            SetState(BackendState.Disconnected, "backend-exited", exitCode, detail);
            Exited?.Invoke(this, exitCode);
            return;
        }

        // A session the app already dropped: report it as a diagnostic, never as the state.
        Report($"a replaced backend session ended (exit code {exitCode})");
    }

    /// <summary>Marks the session disconnected when a call finds it unusable.</summary>
    private void OnSessionGone(BridgeSession? session, string reason)
    {
        if (session is null)
        {
            if (_state == BackendState.NotStarted)
            {
                SetState(BackendState.Disconnected, reason, 0, string.Empty);
            }

            return;
        }

        if (ReferenceEquals(Interlocked.CompareExchange(ref _session, null, session), session))
        {
            Interlocked.Increment(ref _generation);
            SetState(BackendState.Disconnected, reason, 0, session.StderrTail);
            Exited?.Invoke(this, -1);
        }
    }

    private void SetState(BackendState state, string reason, int exitCode, string detail)
    {
        var change = new BackendStateChange(state, reason, exitCode, detail);
        _state = state;
        _lastChange = change;
        StateChanged?.Invoke(this, change);
    }

    private void Report(string message) => Diagnostic?.Invoke(this, message);

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        // Idempotent: the window may dispose the shell after an explicit stop, and the
        // gate must not be disposed twice.
        if (Interlocked.Exchange(ref _disposeRequested, 1) == 1)
        {
            return;
        }

        await StopAsync(allowKill: true, reason: "disposing").ConfigureAwait(false);
        _gate.Dispose();
    }
}

/// <summary>A typed operation outcome: either a value or a structured reason.</summary>
public sealed class BridgeOutcome<T>
{
    private BridgeOutcome(bool ok, T? value, string message, string code)
    {
        Ok = ok;
        Value = value;
        Message = message;
        Code = code;
    }

    /// <summary>True when the operation produced a value.</summary>
    public bool Ok { get; }

    /// <summary>The value, when <see cref="Ok"/>.</summary>
    public T? Value { get; }

    /// <summary>The reason, when not <see cref="Ok"/>.</summary>
    public string Message { get; }

    /// <summary>The protocol error code, when not <see cref="Ok"/>.</summary>
    public string Code { get; }

    /// <summary>Creates a success.</summary>
    public static BridgeOutcome<T> Success(T value) => new(true, value, string.Empty, string.Empty);

    /// <summary>Creates a failure with a reason.</summary>
    public static BridgeOutcome<T> Failure(string message, string code) => new(false, default, message, code);
}
