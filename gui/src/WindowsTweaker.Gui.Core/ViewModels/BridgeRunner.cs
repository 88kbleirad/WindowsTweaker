using System.Text.Json;
using WindowsTweaker.Gui.Core.Bridge;
using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.Protocol;

namespace WindowsTweaker.Gui.Core.ViewModels;

/// <summary>
/// The one place the view models talk to the backend.
/// </summary>
/// <remarks>
/// It owns the session, mirrors every call through it, and keeps the two rules the UI
/// must not have to remember:
/// <list type="bullet">
/// <item>an engine error becomes a typed message instead of an exception the UI would have
/// to stringify;</item>
/// <item>a backend that has died is reported as such, once, rather than as a series of
/// timeouts.</item>
/// </list>
/// Every method returns a result object, so a view model never catches for control flow.
/// </remarks>
public sealed class BridgeRunner : IAsyncDisposable
{
    private BridgeSession? _session;
    private string? _dataRootOverride;
    private string _activeRequestId = string.Empty;

    /// <summary>The handshake, once connected.</summary>
    public BridgeHello? Hello => _session?.Hello;

    /// <summary>True while a backend session is alive.</summary>
    public bool IsConnected => _session is { IsRunning: true };

    /// <summary>
    /// The id of the request that is currently in flight, so a cancel reaches the work it
    /// is meant for instead of guessing. Empty when nothing is running.
    /// </summary>
    public string ActiveRequestId => Volatile.Read(ref _activeRequestId);

    /// <summary>Raised for progress frames (on the reader task; the caller marshals).</summary>
    public event EventHandler<BridgeProgress>? Progress;

    /// <summary>Raised when the backend process ends.</summary>
    public event EventHandler<int>? Exited;

    /// <summary>Raised for backend diagnostics (stderr, dropped frames).</summary>
    public event EventHandler<string>? Diagnostic;

    /// <summary>Sets the data root handed to the backend process's environment.</summary>
    public void UseDataRoot(string dataRoot)
    {
        _dataRootOverride = dataRoot;
    }

    /// <summary>
    /// Stops the current session without shutting it down gracefully. Used by the retry
    /// path before a fresh connection; the previous process is disposed of best-effort.
    /// </summary>
    public void Reset()
    {
        var session = Interlocked.Exchange(ref _session, null);
        if (session is not null)
        {
            _ = session.DisposeAsync();
        }
    }

    /// <summary>Starts a session if none is running. Returns null on success, else the reason.</summary>
    public async Task<string?> ConnectAsync(string repositoryRoot, CancellationToken cancellationToken = default)
    {
        if (IsConnected)
        {
            return null;
        }

        if (!string.IsNullOrWhiteSpace(_dataRootOverride))
        {
            Environment.SetEnvironmentVariable("WT_DATA_ROOT", _dataRootOverride);
            Environment.SetEnvironmentVariable("WT_STATE_PATH", Path.Combine(_dataRootOverride!, "state.json"));
            Environment.SetEnvironmentVariable("WT_LOG_DIRECTORY", Path.Combine(_dataRootOverride!, "logs"));
        }

        try
        {
            var session = await BridgeSession.StartAsync(repositoryRoot, cancellationToken: cancellationToken).ConfigureAwait(false);
            session.Progress += (sender, progress) => Progress?.Invoke(sender, progress);
            session.Exited += (sender, code) => Exited?.Invoke(sender, code);
            session.Diagnostic += (sender, message) => Diagnostic?.Invoke(sender, message);
            _session = session;
            return null;
        }
        catch (BridgeException exception)
        {
            return exception.Message;
        }
    }

    /// <summary>Runs an operation, returning a typed outcome.</summary>
    public async Task<BridgeOutcome<T>> RunAsync<T>(
        string op,
        Func<JsonElement, T> project,
        IReadOnlyDictionary<string, object?>? args = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        if (_session is null)
        {
            return BridgeOutcome<T>.Failure("The backend is not running.", "BackendDown");
        }

        try
        {
            var task = _session.SendAsync(op, args, timeout, cancellationToken);
            Volatile.Write(ref _activeRequestId, _session.LastRequestId);
            var payload = await task.ConfigureAwait(false);
            try
            {
                return BridgeOutcome<T>.Success(project(payload));
            }
            catch (Exception exception)
            {
                // A payload this projection cannot read is a failure with a reason, never
                // an exception that would abort the caller's startup sequence.
                return BridgeOutcome<T>.Failure(
                    $"The '{op}' answer could not be read: {exception.Message}",
                    "ProjectionFailed");
            }
        }
        catch (BridgeOperationException exception)
        {
            return BridgeOutcome<T>.Failure(exception.Message, exception.Code ?? "BackendError");
        }
        catch (BridgeException exception)
        {
            return BridgeOutcome<T>.Failure(exception.Message, exception.Code ?? "BackendError");
        }
        catch (OperationCanceledException)
        {
            return BridgeOutcome<T>.Failure("The request was cancelled.", "Cancelled");
        }
        finally
        {
            Volatile.Write(ref _activeRequestId, string.Empty);
        }
    }

    /// <summary>Cancels whatever request is currently in flight.</summary>
    public Task<bool> CancelActiveAsync() => CancelAsync(ActiveRequestId);

    /// <summary>Asks the backend to cancel the work behind a request id.</summary>
    public async Task<bool> CancelAsync(string targetRequestId)
    {
        if (_session is null)
        {
            return false;
        }

        try
        {
            var payload = await _session.CancelAsync(targetRequestId).ConfigureAwait(false);
            return payload.ValueKind == JsonValueKind.Object
                && payload.TryGetProperty("stopped", out var stopped)
                && stopped.ValueKind == JsonValueKind.True;
        }
        catch (BridgeException)
        {
            return false;
        }
    }

    /// <summary>
    /// Stops the session. <paramref name="allowKill"/> must only be true when the caller
    /// has established that no mutating operation is in flight.
    /// </summary>
    public async Task<ShutdownOutcome> ShutdownAsync(bool allowKill)
    {
        if (_session is null)
        {
            return ShutdownOutcome.AlreadyStopped;
        }

        var session = _session;
        _session = null;
        return await session.ShutdownAsync(allowKill).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (_session is not null)
        {
            var session = _session;
            _session = null;
            await session.DisposeAsync().ConfigureAwait(false);
        }
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
