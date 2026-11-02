namespace WindowsTweaker.WinUI;

/// <summary>
/// Locates the engine (PowerShell module + bridge host) at runtime.
/// </summary>
/// <remarks>
/// The engine is packaged inside the app's <c>engine</c> folder. During a repository
/// working copy run (unpackaged Debug build) the source tree is preferred, so a rebuilt
/// bridge is exercised without a re-publish; inside an installed package only the
/// packaged copy exists. The locator never scans arbitrary paths: it checks exactly the
/// two known locations.
/// </remarks>
public static class EngineLocator
{
    /// <summary>Non-throwing form of <see cref="ResolveRepositoryRoot"/>.</summary>
    public static bool TryResolveRepositoryRoot(out string? repositoryRoot)
    {
        try
        {
            repositoryRoot = ResolveRepositoryRoot();
            return true;
        }
        catch (InvalidOperationException)
        {
            repositoryRoot = null;
            return false;
        }
    }

    /// <summary>The directory whose <c>src/WindowsTweaker</c> child holds the module.</summary>
    public static string ResolveRepositoryRoot()
    {
        // The elevated relaunch passes the engine root explicitly; the child must use the
        // same tree, never re-derive it (the packaged layout check still applies below).
        if (!string.IsNullOrWhiteSpace(App.ArgumentEngineRoot))
        {
            var explicitRoot = Path.GetFullPath(App.ArgumentEngineRoot);
            if (File.Exists(Path.Combine(explicitRoot, "src", "WindowsTweaker", "WindowsTweaker.psd1")))
            {
                return explicitRoot;
            }
        }

        var packaged = Path.Combine(AppContext.BaseDirectory, "engine");
        if (File.Exists(Path.Combine(packaged, "WindowsTweaker.psd1"))
            && File.Exists(Path.Combine(packaged, "Bridge", "wt-bridge.ps1")))
        {
            // The packaged layout keeps the psd1 and the bridge script at the engine root,
            // so the "repository root" used by the bridge client is the engine root
            // itself. BridgeSession accepts both layouts: a repository working copy
            // (`src/WindowsTweaker/…`) and this packaged one (`engine/…`).
            return packaged;
        }

        var source = FindRepositoryRootFromCodeBase();
        if (source is not null)
        {
            return source;
        }

        throw new InvalidOperationException("The WindowsTweaker engine was not found next to the application.");
    }

    private static string? FindRepositoryRootFromCodeBase()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var manifest = Path.Combine(directory.FullName, "src", "WindowsTweaker", "WindowsTweaker.psd1");
            var bridge = Path.Combine(directory.FullName, "src", "WindowsTweaker", "Bridge", "wt-bridge.ps1");
            if (File.Exists(manifest) && File.Exists(bridge))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        return null;
    }
}
