using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using WindowsTweaker.Gui.Core.Protocol;

namespace WindowsTweaker.Gui.Core.Bridge;

/// <summary>Raised when the backend process cannot be started or dies unexpectedly.</summary>
public class BridgeException : Exception
{
    public BridgeException(string message, string? code = null, Exception? inner = null)
        : base(message, inner)
    {
        Code = code;
    }

    /// <summary>Protocol error code when the failure came from the backend, else null.</summary>
    public string? Code { get; }
}

/// <summary>A backend error reported as a protocol frame.</summary>
public sealed class BridgeOperationException : BridgeException
{
    public BridgeOperationException(string code, string message)
        : base(message, code)
    {
    }
}

/// <summary>The handshake: what the backend says it is and what it can do.</summary>
public sealed record BridgeHello(
    int Protocol,
    string Bridge,
    string ModalVersion,
    string PowerShellVersion,
    string Edition,
    string Platform,
    string Architecture,
    string Tier,
    bool IsWindows,
    bool IsAdmin,
    IReadOnlyList<string> Ops,
    IReadOnlyList<string> GuiKeys,
    int MaxFrameBytes,
    int MaxPending,
    int TaskEventCap);

/// <summary>
/// One long-lived backend session: it starts the bridge host once, frames requests and
/// responses over its stdio, and stays alive while the window is open.
/// </summary>
/// <remarks>
/// Deliberate properties, all of them requirements rather than conveniences:
/// <list type="bullet">
/// <item>no PowerShell process per click: the host is started once and reused;</item>
/// <item>no work on the caller's thread: reads run on a dedicated task and callers await
/// their own request;</item>
/// <item>bounded: every request has a deadline, and a response whose id is unknown or
/// already answered is dropped as stale instead of being mis-delivered;</item>
/// <item>a crash is detected: the process exit fails every pending request and raises
/// <see cref="Exited"/> so the UI can say what happened.</item>
/// </list>
/// </remarks>
public sealed class BridgeSession : IAsyncDisposable
{
    private readonly ConcurrentDictionary<string, PendingRequest> _pending = new(StringComparer.Ordinal);
    private readonly Process _process;
    private readonly int _processId;
    private readonly StreamWriter _stdin;
    private readonly Task _stdoutPump;
    private readonly Task _stderrPump;
    private readonly StringBuilder _stderrTail = new();
    private readonly SemaphoreSlim _stderrLock = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();
    private long _nextId;
    private string _lastRequestId = string.Empty;
    private bool _disposed;
    private int _shutdownAttempted;

    private BridgeSession(Process process, BridgeHello hello)
    {
        _process = process;
        _processId = process.Id;
        Hello = hello;
        _stdin = process.StandardInput;
        _stdoutPump = Task.Run(() => PumpStdoutAsync(_lifetime.Token));
        _stderrPump = Task.Run(() => PumpStderrAsync(_lifetime.Token));
    }

    /// <summary>The handshake the backend completed on startup.</summary>
    public BridgeHello Hello { get; }

    /// <summary>
    /// The operating-system id of the backend process this session owns. It is the
    /// identity the UI and the tests use to reason about "this session's process" -
    /// liveness, exit code and "is the previous one really gone" - without scanning for
    /// processes by name. It is captured at construction, so it stays readable after the
    /// session (and its <see cref="Process"/> handle) has been disposed.
    /// </summary>
    public int ProcessId => _processId;

    /// <summary>The id of the most recently issued request (used by the cancel action).</summary>
    public string LastRequestId => Volatile.Read(ref _lastRequestId);

    /// <summary>Raised once when the backend process exits (for any reason).</summary>
    public event EventHandler<int>? Exited;

    /// <summary>Raised for every progress frame, on the reader task.</summary>
    public event EventHandler<BridgeProgress>? Progress;

    /// <summary>Raised for every lifecycle notice frame.</summary>
    public event EventHandler<BridgeNotice>? Notice;

    /// <summary>Raised for diagnostics: parse failures, stale frames, stderr lines.</summary>
    public event EventHandler<string>? Diagnostic;

    /// <summary>The last stderr lines, for the error banner when the backend dies.</summary>
    public string StderrTail
    {
        get
        {
            _stderrLock.Wait(0);
            try
            {
                return _stderrTail.ToString();
            }
            finally
            {
                _stderrLock.Release();
            }
        }
    }

    /// <summary>True while the backend process is alive.</summary>
    public bool IsRunning => !_disposed && !_process.HasExited;

    /// <summary>
    /// Starts a backend session. Discovers a PowerShell host, launches the bridge host
    /// script, and waits for the handshake. Throws <see cref="BridgeException"/> when no
    /// host exists, the script is missing, the handshake does not arrive, or the protocol
    /// version does not match.
    /// </summary>
    public static async Task<BridgeSession> StartAsync(
        string repositoryRoot,
        string? hostPath = null,
        TimeSpan? handshakeTimeout = null,
        CancellationToken cancellationToken = default)
    {
        var host = ResolveHost(hostPath);
        var script = ResolveScript(repositoryRoot);

        var startInfo = new ProcessStartInfo(host.Path)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
            WorkingDirectory = repositoryRoot,
        };
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(script);
        startInfo.ArgumentList.Add("-ModuleManifest");
        var manifest = ResolveEngineFile(repositoryRoot, "WindowsTweaker.psd1")
            ?? throw new BridgeException($"The engine manifest was not found under: {repositoryRoot}");
        startInfo.ArgumentList.Add(manifest);

        Process process;
        try
        {
            process = Process.Start(startInfo) ?? throw new BridgeException("The backend process could not be started.");
        }
        catch (BridgeException)
        {
            throw;
        }
        catch (Exception exception)
        {
            throw new BridgeException($"The backend process could not be started ({host.Label}): {exception.Message}", inner: exception);
        }

        process.StandardInput.AutoFlush = true;

        var hello = await ReadHelloAsync(process, handshakeTimeout ?? TimeSpan.FromSeconds(60), cancellationToken).ConfigureAwait(false);

        if (hello.Protocol != ProtocolConstants.Version)
        {
            try { process.Kill(entireProcessTree: true); } catch (Exception) { /* best effort */ }
            throw new BridgeException(
                $"The backend speaks protocol {hello.Protocol}; this client needs {ProtocolConstants.Version}.",
                "ProtocolMismatch");
        }

        return new BridgeSession(process, hello);
    }

    private static PowerShellHost ResolveHost(string? hostPath)
    {
        if (!string.IsNullOrWhiteSpace(hostPath))
        {
            var probed = PowerShellLocator.Probe(hostPath, "explicit");
            return probed ?? throw new BridgeException($"The requested PowerShell host is not usable: {hostPath}");
        }

        var hosts = PowerShellLocator.Discover();
        if (hosts.Count == 0)
        {
            throw new BridgeException(
                "No PowerShell host was found. Install PowerShell 7 (validated range 7.4-7.6) or use Windows PowerShell 5.1.");
        }

        return hosts[0];
    }

    private static string ResolveScript(string repositoryRoot)
    {
        var script = ResolveEngineFile(repositoryRoot, "Bridge", "wt-bridge.ps1")
            ?? throw new BridgeException($"The bridge host script was not found under: {repositoryRoot}");

        return script;
    }

    /// <summary>
    /// Resolves an engine file in either supported layout: a repository working copy
    /// (<c>src/WindowsTweaker/…</c>) or the packaged engine folder
    /// (<c>engine/…</c>, where the module root is the engine folder itself).
    /// </summary>
    private static string? ResolveEngineFile(string repositoryRoot, params string[] relativeParts)
    {
        var source = Path.Combine(
            new[] { repositoryRoot, "src", "WindowsTweaker" }.Concat(relativeParts).ToArray());
        if (File.Exists(source))
        {
            return source;
        }

        var packaged = Path.Combine(
            new[] { repositoryRoot }.Concat(relativeParts).ToArray());
        if (File.Exists(packaged))
        {
            return packaged;
        }

        return null;
    }

    private static async Task<BridgeHello> ReadHelloAsync(Process process, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);

        while (true)
        {
            var line = await process.StandardOutput.ReadLineAsync(timeoutSource.Token).ConfigureAwait(false);
            if (line is null)
            {
                var stderr = string.Empty;
                try
                {
                    stderr = await process.StandardError.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // Diagnostics only.
                }

                throw new BridgeException($"The backend exited before its handshake. {stderr.Trim()}".TrimEnd());
            }

            var frame = BridgeFrame.TryParse(line);
            if (frame is null)
            {
                continue;
            }

            if (!frame.IsHello)
            {
                continue;
            }

            return ParseHello(frame);
        }
    }

    private static BridgeHello ParseHello(BridgeFrame frame)
    {
        // The hello frame is self-describing: its fields sit beside `type`, not under `data`.
        var payload = frame.Root;
        return new BridgeHello(
            Protocol: GetInt(payload, "protocol"),
            Bridge: GetString(payload, "bridge") ?? "wt-bridge",
            ModalVersion: GetNested(payload, "engine", "moduleVersion") ?? string.Empty,
            PowerShellVersion: GetNested(payload, "engine", "powerShell") ?? string.Empty,
            Edition: GetNested(payload, "engine", "edition") ?? string.Empty,
            Platform: GetNested(payload, "engine", "platform") ?? string.Empty,
            Architecture: GetNested(payload, "engine", "architecture") ?? string.Empty,
            Tier: GetNested(payload, "engine", "tier") ?? string.Empty,
            IsWindows: GetNestedBool(payload, "engine", "isWindows"),
            IsAdmin: GetNestedBool(payload, "engine", "isAdmin"),
            Ops: GetStringArray(payload, "ops"),
            GuiKeys: GetStringArray(payload, "guiKeys"),
            MaxFrameBytes: GetNestedInt(payload, "limits", "maxFrameBytes", ProtocolConstants.MaxFrameBytes),
            MaxPending: GetNestedInt(payload, "limits", "maxPending", 8),
            TaskEventCap: GetNestedInt(payload, "limits", "taskEventCap", 500));
    }

    /// <summary>
    /// Sends one request and waits for its terminal frame.
    /// </summary>
    /// <param name="op">Allowlisted operation name; the backend refuses anything else.</param>
    /// <param name="args">Operation arguments (never a command string).</param>
    /// <param name="timeout">Deadline; the backend enforces its own too.</param>
    public async Task<JsonElement> SendAsync(
        string op,
        IReadOnlyDictionary<string, object?>? args = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        if (_disposed)
        {
            throw new BridgeException("This backend session has been closed.", ProtocolConstants.ErrorCode.BackendDown);
        }

        if (!IsRunning)
        {
            throw new BridgeException("The backend is not running.", ProtocolConstants.ErrorCode.BackendDown);
        }

        var id = $"r{Interlocked.Increment(ref _nextId)}";
        Volatile.Write(ref _lastRequestId, id);
        var pending = new PendingRequest(id);
        _pending[id] = pending;

        var payload = new Dictionary<string, object?>(3, StringComparer.Ordinal)
        {
            ["id"] = id,
            ["op"] = op,
        };
        if (args is { Count: > 0 })
        {
            payload["args"] = args;
        }

        var line = JsonSerializer.Serialize(payload);
        try
        {
            await _stdin.WriteLineAsync(line.AsMemory(), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            _pending.TryRemove(id, out _);
            throw new BridgeException($"The request could not be sent to the backend: {exception.Message}", inner: exception);
        }

        var deadline = timeout ?? ProtocolConstants.DefaultTimeout;
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(deadline);
        try
        {
            return await pending.Completion.Task.WaitAsync(timeoutSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            _pending.TryRemove(id, out _);
            throw new BridgeException($"The backend did not answer within {deadline.TotalMilliseconds:0} ms.", ProtocolConstants.ErrorCode.Timeout);
        }
        catch (OperationCanceledException)
        {
            _pending.TryRemove(id, out _);
            throw;
        }
    }

    /// <summary>
    /// Asks the backend to cancel the work behind a request id. The backend stops at its
    /// next safe boundary; it never aborts a mutation mid-flight.
    /// </summary>
    public Task<JsonElement> CancelAsync(string targetRequestId, CancellationToken cancellationToken = default)
        => SendAsync("cancel", new Dictionary<string, object?>(StringComparer.Ordinal) { ["target"] = targetRequestId }, TimeSpan.FromSeconds(15), cancellationToken);

    /// <summary>
    /// Clean shutdown: asks the backend to quit, waits for it to finish pending work and
    /// exit. Never kills a mutating operation abruptly - if the backend does not exit in
    /// time the caller is told, and the process is only killed afterwards.
    /// </summary>
    public async Task<ShutdownOutcome> ShutdownAsync(bool allowKill, CancellationToken cancellationToken = default)
    {
        // Exactly one shutdown attempt per session: a second caller gets AlreadyStopped
        // instead of racing the first one on the same pipes.
        if (Interlocked.Exchange(ref _shutdownAttempted, 1) == 1)
        {
            return ShutdownOutcome.AlreadyStopped;
        }

        if (_disposed || _process.HasExited)
        {
            return ShutdownOutcome.AlreadyStopped;
        }

        var exited = false;
        try
        {
            // The backend answers `quit`, then drains its tasks before writing `bye`.
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(ProtocolConstants.ShutdownTimeout);
            await SendAsync("quit", null, ProtocolConstants.ShutdownTimeout, timeout.Token).ConfigureAwait(false);
            await WaitForExitAsync(ProtocolConstants.ShutdownTimeout).ConfigureAwait(false);
            exited = true;
        }
        catch (Exception exception)
        {
            Report($"Shutdown request failed: {exception.Message}");
        }

        if (!exited)
        {
            try
            {
                _stdin.Close();
            }
            catch (Exception)
            {
                // The pipe may already be gone.
            }

            exited = await WaitForExitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }

        if (!exited && allowKill)
        {
            try
            {
                _process.Kill(entireProcessTree: true);
                exited = await WaitForExitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            }
            catch (Exception exception)
            {
                Report($"The backend process could not be stopped: {exception.Message}");
            }
        }

        return exited ? ShutdownOutcome.Clean : ShutdownOutcome.NotStopped;
    }

    private async Task<bool> WaitForExitAsync(TimeSpan timeout)
    {
        try
        {
            using var timeoutSource = new CancellationTokenSource(timeout);
            await _process.WaitForExitAsync(timeoutSource.Token).ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }

    private async Task PumpStdoutAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var line = await _process.StandardOutput.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (line is null)
                {
                    break;
                }

                Dispatch(line);
            }
        }
        catch (OperationCanceledException)
        {
            // Shutdown.
        }
        catch (Exception exception)
        {
            Report($"The backend output stream ended: {exception.Message}");
        }
        finally
        {
            OnBackendGone();
        }
    }

    private void Dispatch(string line)
    {
        var frame = BridgeFrame.TryParse(line);
        if (frame is null)
        {
            Report("The backend sent a line that is not a protocol frame; it was ignored.");
            return;
        }

        switch (frame.Type)
        {
            case ProtocolConstants.FrameType.Progress:
                // Progress fields sit beside `type` (the frame is self-describing), so they
                // are read from the root, never from `data`.
                Progress?.Invoke(this, new BridgeProgress(
                    frame.Id ?? string.Empty,
                    GetString(frame.Root, "phase") ?? string.Empty,
                    GetString(frame.Root, "text") ?? string.Empty,
                    GetString(frame.Root, "item"),
                    GetIntOrNull(frame.Root, "done"),
                    GetIntOrNull(frame.Root, "total")));
                break;

            case ProtocolConstants.FrameType.Notice:
                Notice?.Invoke(this, new BridgeNotice(GetString(frame.Root, "kind") ?? string.Empty));
                break;

            case ProtocolConstants.FrameType.Result:
            case ProtocolConstants.FrameType.Error:
                CompleteRequest(frame);
                break;

            default:
                Report($"The backend sent an unknown frame type '{frame.Type}'; it was ignored.");
                break;
        }
    }

    private void CompleteRequest(BridgeFrame frame)
    {
        var id = frame.Id;
        if (string.IsNullOrEmpty(id) || !_pending.TryRemove(id, out var pending))
        {
            // A response nobody is waiting for: late after a timeout/cancel, or a duplicate.
            // Dropping it is the stale-response protection - it can never satisfy a newer
            // request that happens to reuse nothing (ids are unique), nor be mis-delivered.
            Report("A backend response arrived for a request that is no longer pending; it was dropped.");
            return;
        }

        if (frame.Type == ProtocolConstants.FrameType.Error)
        {
            pending.Completion.TrySetException(new BridgeOperationException(
                frame.Code ?? ProtocolConstants.ErrorCode.InternalError,
                frame.Message ?? "The backend reported an error."));
            return;
        }

        pending.Completion.TrySetResult(frame.Data);
    }

    private void OnBackendGone()
    {
        var exitCode = -1;
        try
        {
            if (_process.WaitForExit(2000))
            {
                exitCode = _process.ExitCode;
            }
        }
        catch (Exception)
        {
            // The exit code is best effort.
        }

        foreach (var pair in _pending.ToArray())
        {
            if (_pending.TryRemove(pair.Key, out var pending))
            {
                pending.Completion.TrySetException(new BridgeException(
                    $"The backend process ended (exit code {exitCode}) while this request was pending.",
                    "BackendExited"));
            }
        }

        Exited?.Invoke(this, exitCode);
    }

    private async Task PumpStderrAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var line = await _process.StandardError.ReadLineAsync(cancellationToken).ConfigureAwait(false);
                if (line is null)
                {
                    break;
                }

                await _stderrLock.WaitAsync(cancellationToken).ConfigureAwait(false);
                try
                {
                    _stderrTail.AppendLine(line);
                    if (_stderrTail.Length > 4096)
                    {
                        _stderrTail.Remove(0, _stderrTail.Length - 4096);
                    }
                }
                finally
                {
                    _stderrLock.Release();
                }

                Report($"backend: {line}");
            }
        }
        catch (OperationCanceledException)
        {
            // Shutdown.
        }
        catch (Exception)
        {
            // Diagnostics only.
        }
    }

    private void Report(string message) => Diagnostic?.Invoke(this, message);

    /// <inheritdoc />
    /// <remarks>
    /// The shutdown runs <em>before</em> this session is marked disposed. Marking it first
    /// made the shutdown call a no-op, so the process was never asked to quit and only went
    /// away when its stdin was closed - and a backend in the middle of a long read could
    /// outlive the window that owned it.
    /// </remarks>
    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        try
        {
            await ShutdownAsync(allowKill: true).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Disposal never throws for a session that is already gone.
        }

        _disposed = true;

        _lifetime.Cancel();
        try
        {
            await Task.WhenAll(_stdoutPump, _stderrPump).WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // The pumps end with the process.
        }

        _stdin.Dispose();
        _process.Dispose();
        _lifetime.Dispose();
        _stderrLock.Dispose();
    }

    // ---- small JSON helpers used by the projections ----

    internal static string? GetString(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    internal static int GetInt(JsonElement element, string name) => GetIntOrNull(element, name) ?? 0;

    internal static int? GetIntOrNull(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetInt32()
            : null;

    internal static string? GetNested(JsonElement element, string parent, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(parent, out var child)
            ? GetString(child, name)
            : null;

    internal static bool GetNestedBool(JsonElement element, string parent, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(parent, out var child)
            && child.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            && value.GetBoolean();

    internal static int GetNestedInt(JsonElement element, string parent, string name, int fallback) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(parent, out var child)
            ? GetIntOrNull(child, name) ?? fallback
            : fallback;

    internal static IReadOnlyList<string> GetStringArray(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<string>();
        }

        var list = new List<string>();
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                var text = item.GetString();
                if (!string.IsNullOrEmpty(text))
                {
                    list.Add(text);
                }
            }
        }

        return list;
    }

    private sealed class PendingRequest(string id)
    {
        public string Id { get; } = id;

        public TaskCompletionSource<JsonElement> Completion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
}

/// <summary>How a shutdown ended.</summary>
public enum ShutdownOutcome
{
    /// <summary>The backend finished its work and exited on its own.</summary>
    Clean,

    /// <summary>The session was not running to begin with.</summary>
    AlreadyStopped,

    /// <summary>The backend did not exit in time and was not killed (the caller must decide).</summary>
    NotStopped,
}
