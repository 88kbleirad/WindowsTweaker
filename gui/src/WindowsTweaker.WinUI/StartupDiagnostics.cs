using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace WindowsTweaker.WinUI;

/// <summary>
/// Best-effort startup diagnostics for the WinUI frontend.
/// </summary>
/// <remarks>
/// The frontend crash observed in the field lands as a WER Event 1000 with faulting module
/// <c>Microsoft.UI.Xaml.dll</c> and code <c>0xc000027b</c> (a stowed exception). That code
/// wraps the real failure, so this type records the startup stage and the full managed
/// exception chain to <c>&lt;data root&gt;\logs\startup-*.log</c> (same root the engine
/// uses: <c>WT_LOG_DIRECTORY</c>, then <c>%LOCALAPPDATA%\WindowsTweaker</c> on Windows,
/// else <c>~/.local/state/WindowsTweaker</c>).
///
/// Everything here is best-effort and never throws: a logging failure must not change the
/// app's behaviour. The app registers the global handlers as early as possible (App ctor,
/// before <c>InitializeComponent</c>) and never marks a fatal exception handled merely to
/// keep running.
/// </remarks>
public static class StartupDiagnostics
{
    private static readonly object Sync = new();
    private static string? _logPath;
    private static bool _logFailed;

    /// <summary>The log file path (resolved lazily; never throws).</summary>
    public static string LogPath
    {
        get
        {
            lock (Sync)
            {
                return _logPath ??= ResolveLogPath();
            }
        }
    }

    /// <summary>Records that a startup stage was reached.</summary>
    public static void Stage(string stage) => Write("stage", stage, null);

    /// <summary>Records an informational line (environment, chosen paths, ...).</summary>
    public static void Info(string message) => Write("info", message, null);

    /// <summary>Records a failure with the complete exception chain.</summary>
    public static void Error(string context, Exception exception) => Write("error", context, exception);

    /// <summary>Writes a compact snapshot of the process environment at startup.</summary>
    public static void LogEnvironment()
    {
        try
        {
            var os = RuntimeInformation.OSDescription;
            var arch = RuntimeInformation.ProcessArchitecture.ToString();
            var commandLine = Environment.CommandLine;
            var baseDirectory = AppContext.BaseDirectory;
            var version = Environment.Version.ToString();
            var processId = Environment.ProcessId;

            Info($"os={os} arch={arch} runtime=net {version} pid={processId} baseDir={baseDirectory}");
            Info($"commandLine={commandLine}");

            var uiXamlAssembly = typeof(Microsoft.UI.Xaml.Application).Assembly.Location;
            if (!string.IsNullOrEmpty(uiXamlAssembly))
            {
                var fileVersion = FileVersionInfo.GetVersionInfo(uiXamlAssembly);
                Info($"Microsoft.UI.Xaml.dll file={uiXamlAssembly} version={fileVersion.FileVersion}");
            }
            else
            {
                Info("Microsoft.UI.Xaml.dll assembly location unresolved");
            }
        }
        catch (Exception exception)
        {
            Error("environment snapshot failed", exception);
        }
    }

    /// <summary>
    /// Registers the process-wide handlers (AppDomain, TaskScheduler). Called from the
    /// static ctor so they exist before any instance code runs.
    /// </summary>
    public static void RegisterExceptionHandlers()
    {
        try
        {
            AppDomain.CurrentDomain.UnhandledException += (_, e) =>
                Error("AppDomain.UnhandledException", e.ExceptionObject as Exception ?? new Exception(e.ExceptionObject?.ToString()));

            TaskScheduler.UnobservedTaskException += (_, e) =>
            {
                Error("TaskScheduler.UnobservedTaskException", e.Exception);
                e.SetObserved();
            };
        }
        catch (Exception exception)
        {
            Error("registering process exception handlers failed", exception);
        }
    }

    /// <summary>
    /// Subscribes to the XAML application's <c>UnhandledException</c>. Must be called on
    /// the live app instance (after <c>Application</c> construction), before the window is
    /// created. The exception is never marked handled: a fatal startup error must stay
    /// fatal so WER/dump tools and the Event Log still record the crash.
    /// </summary>
    public static void RegisterXamlExceptionHandler(Microsoft.UI.Xaml.Application application)
    {
        try
        {
            application.UnhandledException += (_, e) =>
            {
                var ex = e.Exception ?? new Exception(e.Message);
                Error($"application unhandled exception (XAML dispatch; Handled={e.Handled})", ex);
            };
        }
        catch (Exception exception)
        {
            Error("registering XAML exception handler failed", exception);
        }
    }

    private static void Write(string kind, string message, Exception? exception)
    {
        var line = BuildLine(kind, message, exception);
        lock (Sync)
        {
            if (_logFailed)
            {
                return;
            }

            try
            {
                var path = LogPath;
                var directory = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                File.AppendAllText(path, line);
            }
            catch (Exception)
            {
                // Best effort only: never propagate a logging failure into app startup.
                _logFailed = true;
            }
        }
    }

    private static string BuildLine(string kind, string message, Exception? exception)
    {
        var builder = new StringBuilder();
        var timestamp = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
        var threadId = Environment.CurrentManagedThreadId;
        builder.Append(timestamp).Append(" [").Append(kind).Append(']')
            .Append(" [tid=").Append(threadId).Append("] ")
            .AppendLine(message);

        for (var current = exception; current is not null; current = current.InnerException)
        {
            builder.Append("    ").Append(current.GetType().FullName)
                .Append(": ").AppendLine(current.Message);
            builder.Append("    HResult: 0x").AppendLine(current.HResult.ToString("X8", CultureInfo.InvariantCulture));
            if (!string.IsNullOrEmpty(current.StackTrace))
            {
                foreach (var stackLine in current.StackTrace.Split('\n'))
                {
                    builder.Append("      ").AppendLine(stackLine.TrimEnd('\r'));
                }
            }

            if (current is AggregateException aggregate)
            {
                var index = 0;
                foreach (var inner in aggregate.InnerExceptions)
                {
                    builder.Append("    --- aggregate inner ").Append(index).AppendLine(" ---");
                    AppendExceptionChain(builder, inner, 2);
                    index++;
                }
            }
        }

        return builder.ToString();
    }

    private static void AppendExceptionChain(StringBuilder builder, Exception exception, int depth)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            builder.Append(new string(' ', depth * 2)).Append(current.GetType().FullName)
                .Append(": ").AppendLine(current.Message);
            builder.Append(new string(' ', depth * 2))
                .Append("HResult: 0x").AppendLine(current.HResult.ToString("X8", CultureInfo.InvariantCulture));
            if (!string.IsNullOrEmpty(current.StackTrace))
            {
                foreach (var stackLine in current.StackTrace.Split('\n'))
                {
                    builder.Append(new string(' ', depth * 2 + 2)).AppendLine(stackLine.TrimEnd('\r'));
                }
            }
        }
    }

    private static string ResolveLogPath()
    {
        try
        {
            var root = Environment.GetEnvironmentVariable("WT_LOG_DIRECTORY");
            if (string.IsNullOrWhiteSpace(root))
            {
                if (OperatingSystem.IsWindows())
                {
                    var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
                    root = string.IsNullOrWhiteSpace(localAppData)
                        ? Environment.GetEnvironmentVariable("TEMP") ?? AppContext.BaseDirectory
                        : Path.Combine(localAppData, "WindowsTweaker");
                }
                else
                {
                    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                    root = Path.Combine(home, ".local", "state", "WindowsTweaker");
                }
            }

            var directory = Path.Combine(root, "logs");
            Directory.CreateDirectory(directory);
            var fileName = $"startup-{DateTime.UtcNow:yyyyMMdd-HHmmss}.log";
            return Path.Combine(directory, fileName);
        }
        catch (Exception)
        {
            // Last resort: next to the executable. Only used when the data-root path cannot
            // even be computed.
            return Path.Combine(AppContext.BaseDirectory, "startup.log");
        }
    }
}
