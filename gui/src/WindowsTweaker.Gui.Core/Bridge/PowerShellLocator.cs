using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace WindowsTweaker.Gui.Core.Bridge;

/// <summary>One discovered PowerShell host executable, with what it actually reported.</summary>
public sealed record PowerShellHost(string Path, Version? Version, string Edition, string Source)
{
    /// <summary>True when this host is a PowerShell 7+ (Core) build.</summary>
    public bool IsCore => Edition.Equals("Core", StringComparison.OrdinalIgnoreCase);

    /// <summary>True when the runtime is inside the range this project validates (7.4 - 7.6).</summary>
    public bool IsValidatedCore =>
        IsCore && Version is not null && Version >= new Version(7, 4) && Version < new Version(7, 7);

    /// <summary>Human-readable identity used in the header and in diagnostics.</summary>
    public string Label => Version is null ? Path : $"PowerShell {Version} ({Edition})";
}

/// <summary>
/// Discovers the PowerShell hosts available on this machine.
/// </summary>
/// <remarks>
/// The frontend never assumes PowerShell 7 is installed, and never claims Windows
/// PowerShell 5.1 compatibility without hosting it: every candidate is probed by running
/// it and asking for its version and edition, exactly as the repository's bootstrap does.
/// Nothing is installed, and PATH is one candidate among several rather than the answer.
/// </remarks>
public static class PowerShellLocator
{
    /// <summary>Override used by tests and by portable installs.</summary>
    public const string OverrideVariable = "WT_BRIDGE_POWSH";

    private static readonly Regex VersionPattern = new(@"^\d+(\.\d+){1,3}$", RegexOptions.Compiled);

    /// <summary>Returns the candidate executables, in preference order, without probing.</summary>
    public static IReadOnlyList<(string Path, string Source)> Candidates()
    {
        var results = new List<(string, string)>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void Add(string? path, string source)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return;
            }

            string full;
            try
            {
                full = System.IO.Path.GetFullPath(path);
            }
            catch (Exception)
            {
                return;
            }

            if (File.Exists(full) && seen.Add(full))
            {
                results.Add((full, source));
            }
        }

        Add(Environment.GetEnvironmentVariable(OverrideVariable), "override");

        // PATH first, but only as one candidate: a file named pwsh is not evidence of a
        // usable version, so it is still probed.
        var pathVariable = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var directory in pathVariable.Split(System.IO.Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            Add(SafeCombine(directory, "pwsh"), "PATH");
            Add(SafeCombine(directory, "pwsh.exe"), "PATH");
            Add(SafeCombine(directory, "powershell.exe"), "PATH");
        }

        if (OperatingSystem.IsWindows())
        {
            var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            Add(SafeCombine(programFiles, "PowerShell", "7", "pwsh.exe"), "Program Files");
            Add(SafeCombine(programFiles, "PowerShell", "7-preview", "pwsh.exe"), "Program Files (preview)");
            var windowsApps = SafeCombine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Microsoft", "WindowsApps", "pwsh.exe");
            Add(windowsApps, "Store alias");
            Add(SafeCombine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"), "Windows PowerShell");
        }
        else
        {
            Add("/usr/bin/pwsh", "system");
            Add("/usr/local/bin/pwsh", "system");
            Add("/opt/microsoft/powershell/7/pwsh", "system");
            Add("/snap/bin/pwsh", "snap");
            Add("/usr/bin/powershell", "system");
        }

        return results;
    }

    /// <summary>
    /// Probes every candidate by running it. Returns the hosts that answered, ordered
    /// most-preferred first: validated Core builds, then other Core builds, then Desktop.
    /// </summary>
    public static IReadOnlyList<PowerShellHost> Discover(CancellationToken cancellationToken = default)
    {
        var hosts = new List<PowerShellHost>();
        foreach (var (path, source) in Candidates())
        {
            var host = Probe(path, source, cancellationToken);
            if (host is not null)
            {
                hosts.Add(host);
            }
        }

        return hosts
            .OrderByDescending(h => h.IsValidatedCore)
            .ThenByDescending(h => h.IsCore)
            .ThenByDescending(h => h.Version ?? new Version(0, 0))
            .ToList();
    }

    /// <summary>
    /// Probes one executable: runs it and reads the version and edition it reports.
    /// A file that cannot be started, or that answers with something unusable, is not a
    /// host - it is reported as <c>null</c> rather than being trusted by name.
    /// </summary>
    public static PowerShellHost? Probe(string path, string source, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        var startInfo = new ProcessStartInfo(path)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-Command");
        startInfo.ArgumentList.Add("$PSVersionTable.PSVersion.ToString() + '|' + $PSVersionTable.PSEdition");

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return null;
            }

            var stdout = process.StandardOutput.ReadToEnd();
            _ = process.StandardError.ReadToEnd();
            if (!process.WaitForExit(20_000))
            {
                try { process.Kill(entireProcessTree: true); } catch (Exception) { /* best effort */ }
                return null;
            }

            if (process.ExitCode != 0)
            {
                return null;
            }

            var text = stdout.Trim();
            var separator = text.IndexOf('|');
            if (separator <= 0)
            {
                return null;
            }

            var versionText = text[..separator].Trim();
            var edition = text[(separator + 1)..].Trim();
            if (!VersionPattern.IsMatch(versionText) || edition.Length == 0)
            {
                return null;
            }

            return new PowerShellHost(path, Version.Parse(versionText), edition, source);
        }
        catch (Exception)
        {
            // A candidate that cannot be started is simply not a host here.
            return null;
        }
    }

    private static string? SafeCombine(params string?[] parts)
    {
        if (parts.Any(string.IsNullOrWhiteSpace))
        {
            return null;
        }

        try
        {
            return System.IO.Path.Combine(parts!);
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    /// <summary>The architecture key of this process, for the header and diagnostics.</summary>
    public static string CurrentArchitecture =>
        RuntimeInformation.ProcessArchitecture switch
        {
            Architecture.X64 => "x64",
            Architecture.X86 => "x86",
            Architecture.Arm64 => "arm64",
            _ => RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant(),
        };
}
