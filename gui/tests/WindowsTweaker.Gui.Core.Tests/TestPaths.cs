using WindowsTweaker.Gui.Core.Bridge;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// Locates the repository root and decides whether the live backend tests can run here.
/// </summary>
/// <remarks>
/// The suite is honest about the host it runs on: when no PowerShell host exists the live
/// tests are skipped with an explicit reason instead of passing vacuously. The skip is
/// reported by the test runner, so a green run never implies a backend was exercised when
/// one was not.
/// </remarks>
public static class TestPaths
{
    static TestPaths()
    {
        // Runs after the field initializers above, so the backend's data root is already
        // allocated and every child process picks it up.
        ConfigureBackendEnvironment();
    }

    /// <summary>The repository root (the directory holding <c>src/WindowsTweaker</c>).</summary>
    public static string RepositoryRoot { get; } = FindRoot();

    /// <summary>A writable directory for the backend's state and logs, isolated per run.</summary>
    public static string DataRoot { get; } = CreateDataRoot();

    /// <summary>The PowerShell host to drive, or null when none was found.</summary>
    public static PowerShellHost? Host { get; } = PowerShellLocator.Discover().FirstOrDefault();

    /// <summary>True when the live backend tests can run.</summary>
    public static bool CanRunLive => Host is not null && File.Exists(Path.Combine(RepositoryRoot, "src", "WindowsTweaker", "Bridge", "wt-bridge.ps1"));

    /// <summary>
    /// Points the backend's state store and logs at this run's temporary directory. It is
    /// set once, before any session starts, and inherited by every backend child process.
    /// </summary>
    public static void ConfigureBackendEnvironment()
    {
        Environment.SetEnvironmentVariable("WT_DATA_ROOT", DataRoot);
        Environment.SetEnvironmentVariable("WT_STATE_PATH", Path.Combine(DataRoot, "state.json"));
        Environment.SetEnvironmentVariable("WT_LOG_DIRECTORY", Path.Combine(DataRoot, "logs"));
        Environment.SetEnvironmentVariable("WT_LANG", "en");
    }

    private static string FindRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "src", "WindowsTweaker")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException("The repository root (holding src/WindowsTweaker) was not found.");
    }

    private static string CreateDataRoot()
    {
        var root = Path.Combine(Path.GetTempPath(), "wt-gui-core-tests", Guid.NewGuid().ToString("n"));
        Directory.CreateDirectory(root);
        return root;
    }
}
