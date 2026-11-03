using System.Collections.ObjectModel;
using System.Text.Json;
using WindowsTweaker.Gui.Core.Model;

namespace WindowsTweaker.Gui.Core.ViewModels;

/// <summary>The catalog workspace: search, filter, select, inspect and stage changes.</summary>
/// <remarks>
/// Selecting a row stages nothing. The reviewed list is the only place a change can wait,
/// and applying it is an explicit action in the review workspace - the same separation the
/// terminal interface keeps between browsing and its pending set.
/// </remarks>
public sealed class TweaksViewModel : WorkspaceViewModel
{
    private readonly List<TweakState> _all = new();
    private string _search = string.Empty;
    private string _category = string.Empty;
    private bool _onlySupported;
    private TweakState? _selected;
    private string _targetState = string.Empty;

    public TweaksViewModel(ShellViewModel shell)
        : base(shell)
    {
        States.CollectionChanged += (_, _) =>
        {
            Raise(nameof(ShowFilteredEmpty));
            Raise(nameof(ShowCatalogEmpty));
            Raise(nameof(EmptyMessage));
            Raise(nameof(RowsSummary));
        };
    }

    /// <summary>
    /// Localized row count ("N rows"), a formatted string computed in the view model.
    /// WinUI 3's binding markup extension does not support WPF-style
    /// <c>StringFormat='{0} …'</c> — the compiler parses the literal braces as a nested
    /// markup extension and fails with WMC9997 — so the format lives here instead.
    /// </summary>
    public string RowsSummary => Strings.Get("Gui.Tweaks.RowCount", States.Count);

    /// <summary>Rows currently shown (already filtered).</summary>
    public ObservableCollection<TweakState> States { get; } = new();

    /// <summary>Categories, with an empty first entry meaning "all".</summary>
    public ObservableCollection<string> Categories { get; } = new();

    /// <summary>
    /// The category combo's items: a stable "All categories" entry plus one item per real
    /// category. Bound to <see cref="Category"/> by code (the selection is the code).
    /// </summary>
    public ObservableCollection<CategoryOption> CategoryOptions { get; } = new();

    /// <summary>One category combo item.</summary>
    public sealed record CategoryOption(string Code, string Label);

    /// <summary>Search text. Filtering happens locally on data already fetched once.</summary>
    public string Search
    {
        get => _search;
        set
        {
            if (Set(ref _search, value))
            {
                ApplyFilter();
            }
        }
    }

    /// <summary>Selected category, or empty for all.</summary>
    public string Category
    {
        get => _category;
        set
        {
            if (Set(ref _category, value))
            {
                ApplyFilter();
            }
        }
    }

    /// <summary>When set, rows that cannot run on this host are hidden.</summary>
    public bool OnlySupported
    {
        get => _onlySupported;
        set
        {
            if (Set(ref _onlySupported, value))
            {
                ApplyFilter();
            }
        }
    }

    /// <summary>The selected tweak.</summary>
    public TweakState? Selected
    {
        get => _selected;
        set
        {
            if (Set(ref _selected, value))
            {
                TargetState = value?.StateNames.FirstOrDefault() ?? string.Empty;
                Raise(nameof(HasSelection));
                Raise(nameof(DetailsTitle));
                Raise(nameof(DetailsBody));
                Raise(nameof(CanAdd));
            }
        }
    }

    /// <summary>Target state chosen for the selected tweak.</summary>
    public string TargetState
    {
        get => _targetState;
        set
        {
            if (Set(ref _targetState, value))
            {
                Raise(nameof(CanAdd));
            }
        }
    }

    /// <summary>True when a row is selected.</summary>
    public bool HasSelection => _selected is not null;

    /// <summary>True when the selection can be staged for review.</summary>
    public bool CanAdd => _selected is not null && !string.IsNullOrEmpty(_targetState);

    /// <summary>True when a filter (search, category or supported-only) is narrowing the list.</summary>
    public bool HasFilter =>
        !string.IsNullOrWhiteSpace(_search) || !string.IsNullOrWhiteSpace(_category) || _onlySupported;

    /// <summary>
    /// True when the list is empty because the current filter matched nothing. Only true for
    /// data that was actually read: a failed or in-flight load has its own state and never
    /// shows this message next to an error.
    /// </summary>
    public bool ShowFilteredEmpty =>
        States.Count == 0
        && _all.Count > 0
        && HasFilter
        && State is LoadState.Ready or LoadState.Empty;

    /// <summary>True when the engine answered with a catalog that has no tweaks at all.</summary>
    public bool ShowCatalogEmpty =>
        States.Count == 0
        && _all.Count == 0
        && State is LoadState.Ready or LoadState.Empty
        && !HasFilter;

    /// <summary>
    /// The message for an empty list, matching the reason: an empty catalog and a filter
    /// that matched nothing are different facts and must not be confused.
    /// </summary>
    public string EmptyMessage => _all.Count == 0
        ? Strings["Gui.Overview.Empty"]
        : Strings["Gui.Error.EmptySearch"];

    /// <summary>Detail pane title.</summary>
    public string DetailsTitle => _selected?.Name ?? string.Empty;

    /// <summary>Detail pane body: the facts the terminal interface also shows.</summary>
    public string DetailsBody
    {
        get
        {
            if (_selected is null)
            {
                return string.Empty;
            }

            var parts = new List<string>
            {
                _selected.Description,
                string.IsNullOrEmpty(_selected.Impact) ? string.Empty : $"{Strings["State.Impact"]}: {_selected.Impact}",
                $"{Strings["Gui.Column.State"]}: {_selected.State}" +
                    (string.IsNullOrEmpty(_selected.Details) ? string.Empty : $" ({_selected.Details})"),
                $"{Strings["Gui.Column.Risk"]}: {_selected.Risk} | {Strings["Gui.Column.Scope"]}: {_selected.Scope} | {Strings["Gui.Privilege"]}: {_selected.Privilege}",
                $"{Strings["Gui.Restart"]}: {_selected.Restart} | {Strings["Gui.RollbackSupport"]}: {_selected.Rollback}",
            };

            if (!_selected.Supported && !string.IsNullOrEmpty(_selected.UnsupportedReason))
            {
                parts.Add($"{Strings["State.Supported"]}: {_selected.UnsupportedReason}");
            }

            if (_selected.Managed)
            {
                parts.Add(Strings.Get("Error.ManagedByPolicy", string.Join(", ", _selected.ManagedBy)));
            }

            if (_selected.Irreversible)
            {
                parts.Add(Strings["Gui.IrreversibleWarning"]);
            }

            if (!string.IsNullOrEmpty(_selected.Note))
            {
                parts.Add(_selected.Note);
            }

            return string.Join(Environment.NewLine, parts.Where(p => !string.IsNullOrEmpty(p)));
        }
    }

    /// <inheritdoc />
    protected override async Task LoadAsync()
    {
        var first = _all.Count == 0;
        var loaded = await RunAsync(
            "state.get",
            Projections.TweakStates,
            rows =>
            {
                _all.Clear();
                _all.AddRange(rows.OrderBy(r => r.Category, StringComparer.Ordinal).ThenBy(r => r.Id, StringComparer.Ordinal));

                if (first)
                {
                    Categories.Clear();
                    CategoryOptions.Clear();
                    CategoryOptions.Add(new CategoryOption(string.Empty, Strings["Gui.Filter.AllCategories"]));
                    foreach (var category in _all.Select(r => r.Category).Distinct().OrderBy(c => c, StringComparer.Ordinal))
                    {
                        Categories.Add(category);
                        CategoryOptions.Add(new CategoryOption(category, category));
                    }
                }
            },
            timeout: TimeSpan.FromMinutes(5),
            statusWhileRunning: Strings["Tui.Status.Refreshing"]).ConfigureAwait(true);

        ApplyFilter();
        if (loaded)
        {
            MarkLoaded(_all.Count);
        }

        Loaded = true;
    }

    /// <summary>Re-reads every state (the explicit refresh action).</summary>
    public Task RefreshAsync() => ReloadAsync();

    private void ApplyFilter()
    {
        var previous = _selected?.Id;
        var filtered = _all.AsEnumerable();

        if (!string.IsNullOrWhiteSpace(_category))
        {
            filtered = filtered.Where(r => string.Equals(r.Category, _category, StringComparison.OrdinalIgnoreCase));
        }

        if (_onlySupported)
        {
            filtered = filtered.Where(r => r.CanApply);
        }

        if (!string.IsNullOrWhiteSpace(_search))
        {
            var needle = _search.Trim();
            filtered = filtered.Where(r =>
                r.Id.Contains(needle, StringComparison.OrdinalIgnoreCase) ||
                r.Name.Contains(needle, StringComparison.OrdinalIgnoreCase) ||
                r.Category.Contains(needle, StringComparison.OrdinalIgnoreCase) ||
                r.Description.Contains(needle, StringComparison.OrdinalIgnoreCase));
        }

        var rows = filtered.ToList();
        States.Clear();
        foreach (var row in rows)
        {
            States.Add(row);
        }

        // Keep the selection if it is still visible, otherwise clear it.
        Selected = previous is null ? null : rows.FirstOrDefault(r => r.Id == previous);
        Raise(nameof(ShowFilteredEmpty));
        Raise(nameof(ShowCatalogEmpty));
        Raise(nameof(EmptyMessage));
        Raise(nameof(HasFilter));
    }

    /// <summary>Re-publishes the properties the load state drives.</summary>
    protected override void OnStateChanged()
    {
        Raise(nameof(ShowFilteredEmpty));
        Raise(nameof(ShowCatalogEmpty));
    }

    /// <summary>Stages the selection into the review workspace. Applies nothing.</summary>
    public string? StageSelection()
    {
        if (_selected is null)
        {
            return Strings["Gui.Error.NoSelection"];
        }

        if (string.IsNullOrEmpty(_targetState))
        {
            return Strings["Error.StateRequired"];
        }

        return Shell.Review.Add(new ReviewedChange(_selected.Id, _targetState, _selected.Name, _selected.State));
    }
}

/// <summary>The review workspace: the reviewed list, the preview, and the apply.</summary>
public sealed class ReviewViewModel : WorkspaceViewModel
{
    private bool _dryRun;
    private string _previewText = string.Empty;
    private bool _previewLoaded;
    private ReviewedChange? _selectedChange;

    public ReviewViewModel(ShellViewModel shell)
        : base(shell)
    {
        Results.CollectionChanged += (_, _) => { Raise(nameof(HasResults)); RaiseEligibility(); };
        Changes.CollectionChanged += (_, _) =>
        {
            Raise(nameof(HasChanges));
            Raise(nameof(HasProtectionReducing));
            RaiseEligibility();
        };
        Shell.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ShellViewModel.Connection) or nameof(ShellViewModel.Busy))
            {
                RaiseEligibility();
            }
        };
    }

    /// <summary>The reviewed (pending) changes. Never a result, never history.</summary>
    public ObservableCollection<ReviewedChange> Changes { get; } = new();

    /// <summary>The outcome rows of the last apply/preview.</summary>
    public ObservableCollection<ApplyResult> Results { get; } = new();

    /// <summary>The row selected in the reviewed list (drives removal eligibility).</summary>
    public ReviewedChange? SelectedChange
    {
        get => _selectedChange;
        set
        {
            if (Set(ref _selectedChange, value))
            {
                RaiseEligibility();
            }
        }
    }

    /// <summary>True once the last apply/preview produced outcome rows.</summary>
    public bool HasResults => Results.Count > 0;

    /// <summary>True when the reviewed list can be previewed: rows, a live backend, no other work.</summary>
    public bool CanPreview => HasChanges && CanRunBackendCommand;

    /// <summary>True when the reviewed list can be applied: rows, a live backend, no other work.</summary>
    public bool CanApply => HasChanges && CanRunBackendCommand;

    /// <summary>True when there is a reviewed row to take off the list.</summary>
    public bool CanRemove => _selectedChange is not null;

    /// <summary>True when the reviewed list has anything to clear.</summary>
    public bool CanClear => HasChanges;

    /// <summary>True when the running operation can be asked to stop.</summary>
    public bool CanCancel => Shell.Busy && Shell.IsConnected;

    /// <summary>A backend command may run: connected, and nothing else is in flight.</summary>
    private bool CanRunBackendCommand => Shell.IsConnected && !Shell.Busy;

    /// <summary>Read-only preview text for the whole reviewed list.</summary>
    public string PreviewText
    {
        get => _previewText;
        private set => Set(ref _previewText, value);
    }

    /// <summary>True once a preview has been produced for the current list.</summary>
    public bool PreviewLoaded
    {
        get => _previewLoaded;
        private set => Set(ref _previewLoaded, value);
    }

    /// <summary>When set, applying reports every operation and writes nothing.</summary>
    public bool DryRun
    {
        get => _dryRun;
        set => Set(ref _dryRun, value);
    }

    /// <summary>True when the list has anything to apply.</summary>
    public bool HasChanges => Changes.Count > 0;

    /// <summary>True when the reviewed list contains a protection-reducing entry.</summary>
    public bool HasProtectionReducing =>
        Changes.Any(change => Shell.Tweaks.States.FirstOrDefault(r => r.Id == change.Id)?.ReducesProtection == true);

    /// <inheritdoc />
    protected override Task LoadAsync()
    {
        Loaded = true;
        return Task.CompletedTask;
    }

    private void RaiseEligibility()
    {
        Raise(nameof(CanPreview));
        Raise(nameof(CanApply));
        Raise(nameof(CanRemove));
        Raise(nameof(CanClear));
        Raise(nameof(CanCancel));
    }

    /// <summary>Adds one reviewed change. Returns a reason when it was refused.</summary>
    public string? Add(ReviewedChange change)
    {
        var existing = Changes.FirstOrDefault(c => c.Id == change.Id);
        if (existing is not null)
        {
            Changes.Remove(existing);
        }

        Changes.Add(change);
        PreviewLoaded = false;
        Results.Clear();
        StatusText = Strings.Get("Gui.Review.Confirm", Changes.Count);
        return null;
    }

    /// <summary>Removes the selected reviewed change.</summary>
    public void Remove(ReviewedChange change)
    {
        Changes.Remove(change);
        if (ReferenceEquals(_selectedChange, change))
        {
            SelectedChange = null;
        }

        PreviewLoaded = false;
    }

    /// <summary>Clears the reviewed list.</summary>
    public void Clear()
    {
        Changes.Clear();
        Results.Clear();
        PreviewText = string.Empty;
        PreviewLoaded = false;
        SelectedChange = null;
    }

    /// <summary>
    /// Builds the read-only preview for every reviewed change: exactly what would run,
    /// its current value, its intended value, and the recovery limits.
    /// </summary>
    public async Task PreviewAsync()
    {
        if (!HasChanges)
        {
            PreviewText = Strings["Gui.Review.Empty"];
            PreviewLoaded = false;
            StatusText = Strings["Gui.NothingPending"];
            return;
        }

        if (!Shell.IsConnected)
        {
            StatusText = Shell.ConnectionError;
            return;
        }

        var builder = new System.Text.StringBuilder();
        var allTargets = new List<PreviewTarget>();
        var conflicts = 0;

        foreach (var change in Changes.ToList())
        {
            var outcome = await Shell.Runner.RunAsync(
                "preview.get",
                Projections.Preview,
                new Dictionary<string, object?>(StringComparer.Ordinal)
                {
                    ["id"] = change.Id,
                    ["state"] = change.State,
                },
                TimeSpan.FromMinutes(2)).ConfigureAwait(true);

            if (!outcome.Ok)
            {
                builder.AppendLine($"{change.Id}: {outcome.Message}");
                continue;
            }

            if (outcome.Value is null)
            {
                continue;
            }

            var preview = outcome.Value;
            builder.AppendLine($"{change.Id} -> {preview.State}");
            if (!preview.Supported)
            {
                builder.AppendLine($"  ! {preview.SupportReason}");
            }

            foreach (var target in preview.Targets)
            {
                allTargets.Add(target);
                var current = string.IsNullOrEmpty(target.CurrentDisplay) ? target.CurrentKind : target.CurrentDisplay;
                builder.AppendLine($"  {target.Label}: {current} -> {target.IntendedDisplay} ({target.Operation})");
            }

            builder.AppendLine($"  {Strings["Gui.RollbackSupport"]}: {preview.RecoveryRollback}");
        }

        // Conflicts across the reviewed set: two changes touching the same canonical target
        // are reported before anything runs, exactly as the engine reports them.
        var grouped = allTargets.GroupBy(t => t.Identity, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1).ToList();
        conflicts = grouped.Count;
        if (conflicts > 0)
        {
            builder.AppendLine();
            builder.AppendLine(Strings["Gui.Review.Dependency"]);
            foreach (var group in grouped)
            {
                builder.AppendLine($"  ! {group.Key} ({group.Count()})");
            }
        }

        if (DryRun)
        {
            builder.Insert(0, Strings["Gui.Review.DryRunNotice"] + Environment.NewLine);
        }

        PreviewText = builder.ToString();
        PreviewLoaded = true;
        StatusText = PreviewText.Length > 0 ? string.Empty : Strings["Gui.Review.Empty"];
    }

    /// <summary>
    /// Applies the reviewed list (or previews it when <see cref="DryRun"/> is set). The
    /// reviewed state is revalidated by the engine at apply time; the results are the
    /// engine's own statuses, never a claim this view makes.
    /// </summary>
    public async Task ApplyAsync(bool restartAfterApply = false)
    {
        if (!HasChanges)
        {
            StatusText = Strings["Gui.NothingPending"];
            return;
        }

        if (!Shell.IsConnected)
        {
            StatusText = Shell.ConnectionError;
            return;
        }

        if (Shell.HasMutatingOperation)
        {
            StatusText = Strings["Gui.Error.Busy"];
            return;
        }

        var items = Changes.ToList().Select(change => new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["Id"] = change.Id,
            ["State"] = change.State,
        }).ToList();

        Results.Clear();
        ErrorText = string.Empty;
        ErrorDetail = string.Empty;

        await Shell.RunMutatingAsync(async () =>
        {
            var outcome = await Shell.Runner.RunAsync(
                "apply.batch",
                Projections.Batch,
                new Dictionary<string, object?>(StringComparer.Ordinal)
                {
                    ["items"] = items,
                    ["dryRun"] = DryRun,
                    ["restartAfterApply"] = restartAfterApply,
                },
                TimeSpan.FromMinutes(30));

            if (!outcome.Ok)
            {
                Fail(outcome.Code, outcome.Message);
                return false;
            }

            if (outcome.Value is null)
            {
                return false;
            }

            var batch = outcome.Value;
            foreach (var result in batch.Results)
            {
                Results.Add(result);
            }

            StatusText = batch.Cancelled
                ? Strings["Tui.Busy.CancelActive"]
                : string.Join("; ", batch.Results.Select(r => $"{r.RequestedId}: {r.Status}"));

            if (!DryRun && batch.Results.Count > 0 && batch.Results.All(r => r.Succeeded))
            {
                Clear();
            }

            return true;
        }).ConfigureAwait(true);
    }

    /// <summary>
    /// Asks the backend to stop the running apply at its next safe boundary. The backend
    /// finishes the item it is on; nothing is claimed to have stopped before it has.
    /// </summary>
    public async Task CancelAsync()
    {
        if (!Shell.Busy)
        {
            StatusText = Strings["Gui.Error.NothingToCancel"];
            return;
        }

        var stopped = await Shell.Runner.CancelActiveAsync().ConfigureAwait(true);
        StatusText = stopped ? Strings["Tui.Busy.CancelHint"] : Shell.ConnectionError;
    }
}
