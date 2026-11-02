using System.ComponentModel;
using System.Diagnostics;

namespace WindowsTweaker.Gui.Core.Bridge;

/// <summary>
/// The explicit elevation boundary of the frontend.
/// </summary>
/// <remarks>
/// The app opens and browses as a standard user (see app.manifest, asInvoker). Operations
/// the engine marks privileged need an elevated backend session, which is started by
/// relaunching the application itself with <c>Verb = RunAs</c> - the UAC prompt is the
/// OS's, and the relaunched copy is the same executable, so the engine root and the
/// language are carried over and the handshake proves the new session.
///
/// The relaunch is a *handoff*, not an in-place elevation: the current copy shuts its
/// backend down cleanly first (never killing a mutation), then starts the elevated child
/// and exits. Requests are never serialized to disk or smuggled through command-line
/// arguments; the operation the user asked for is re-issued in the new session from the
/// same view model state, which is the only identity it needs. The elevated child is a
/// fresh bridge session validated by the same handshake as any other.
/// </remarks>
public static class ProcessElevation
{
    /// <summary>True when this process is running with an administrator token.</summary>
    public static bool IsElevated()
    {
        if (!OperatingSystem.IsWindows())
        {
            // Outside Windows there is nothing to elevate; the engine reports its own
            // answer and the UI shows that.
            return false;
        }

        try
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            var principal = new System.Security.Principal.WindowsPrincipal(identity);
            return principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Starts an elevated copy of the current process. Throws <see cref="Win32Exception"/>
    /// when the UAC prompt is declined or cannot be shown (nothing is started then).
    /// </summary>
    public static void StartElevated(string repositoryRoot, string language)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new Win32Exception(1223); // ERROR_CANCELLED: no elevation surface here.
        }

        var self = Environment.ProcessPath
            ?? throw new Win32Exception("The application executable could not be resolved.");

        var startInfo = new ProcessStartInfo
        {
            FileName = self,
            UseShellExecute = true,
            Verb = "RunAs",
            WorkingDirectory = repositoryRoot,
        };

        startInfo.ArgumentList.Add("--elevated");
        startInfo.ArgumentList.Add("--engine");
        startInfo.ArgumentList.Add(repositoryRoot);
        if (!string.IsNullOrEmpty(language))
        {
            startInfo.ArgumentList.Add("--language");
            startInfo.ArgumentList.Add(language);
        }

        using var process = Process.Start(startInfo)
            ?? throw new Win32Exception("The elevated process could not be started.");
        // The child outlives this copy by design; nothing is awaited here.
    }
}
