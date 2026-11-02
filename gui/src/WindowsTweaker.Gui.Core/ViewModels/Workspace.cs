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
    private string _statusText = string.Empty;
    private string _errorText = string.Empty;

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

    /// <summary>Loads (or reloads) this workspace's data. Implemented by each workspace.</summary>
    protected abstract Task LoadAsync();

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
        ErrorText = string.Empty;
        if (statusWhileRunning is not null)
        {
            StatusText = statusWhileRunning;
        }

        try
        {
            var outcome = await Shell.Runner.RunAsync(op, project, args, timeout).ConfigureAwait(true);
            if (!outcome.Ok)
            {
                ErrorText = outcome.Message;
                StatusText = outcome.Message;
                return false;
            }

            apply(outcome.Value!);
            return true;
        }
        finally
        {
            Busy = false;
        }
    }
}

/// <summary>The overview workspace: environment, catalog size, and anything outstanding.</summary>
public sealed class OverviewViewModel : WorkspaceViewModel
{
    private int _tweakCount;
    private int _categoryCount;
    private int _interruptedCount;
    private int _reviewedCount;

    public OverviewViewModel(ShellViewModel shell)
        : base(shell)
    {
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

    /// <summary>"113 tweaks | 10 categories" (single line, localized).</summary>
    public string CatalogSummary => $"{TweakCount} {Strings["Gui.Overview.Tweaks"]} | {CategoryCount} {Strings["Gui.Column.Category"]}";

    /// <inheritdoc />
    protected override async Task LoadAsync()
    {
        await RunAsync(
            "catalog.list",
            Projections.Catalog,
            catalog =>
            {
                TweakCount = catalog.Tweaks.Count;
                CategoryCount = catalog.Categories.Count;
                Raise(nameof(CatalogSummary));
            }).ConfigureAwait(true);

        await RunAsync(
            "history.interrupted",
            Projections.Interrupted,
            rows => InterruptedCount = rows.Count).ConfigureAwait(true);

        ReviewedCount = Shell.Review.Changes.Count;
        Shell.Review.Changes.CollectionChanged += (_, _) => ReviewedCount = Shell.Review.Changes.Count;
        Loaded = true;
    }
}
