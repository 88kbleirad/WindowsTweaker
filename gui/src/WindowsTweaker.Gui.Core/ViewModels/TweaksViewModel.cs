using System.Collections.ObjectModel;
using System.Text.Json;
using WindowsTweaker.Gui.Core.Model;

namespace WindowsTweaker.Gui.Core.ViewModels;

/// <summary>
/// How a tweak's current value reads. Derived from the engine's stable state token and
/// never from the text it is displayed with, so a translated value can never change what
/// the interface thinks the tweak is.
/// </summary>
public enum TweakValueKind
{
    /// <summary>The engine reports the tweak as on.</summary>
    Enabled,

    /// <summary>The engine reports the tweak as off.</summary>
    Disabled,

    /// <summary>Nothing is configured, so the product's own default applies.</summary>
    Default,

    /// <summary>The tweak cannot run on this host; the row carries the reason.</summary>
    Unsupported,

    /// <summary>The engine could not read the value.</summary>
    Unknown,

    /// <summary>A product name or a tweak-specific token, shown exactly as it was reported.</summary>
    Other,
}

/// <summary>Localized text for the engine's stable tweak tokens.</summary>
/// <remarks>
/// The five semantic states come from the window's own table. Anything else is a product
/// name or a tweak-specific token, which the terminal interface already names in
/// <c>Tui.State.*</c>; a token with no entry there is shown unchanged, because a product
/// name must never be translated and an unknown token must never be replaced by a guess.
/// </remarks>
internal static class TweakText
{
    /// <summary>The kind behind a stable engine token.</summary>
    public static TweakValueKind Kind(string? token)
    {
        var value = (token ?? string.Empty).Trim();
        if (value.Length == 0)
        {
            // A state the engine could not read is unknown; it is not "off".
            return TweakValueKind.Unknown;
        }

        if (value.Equals("Enabled", StringComparison.OrdinalIgnoreCase))
        {
            return TweakValueKind.Enabled;
        }

        if (value.Equals("Disabled", StringComparison.OrdinalIgnoreCase))
        {
            return TweakValueKind.Disabled;
        }

        if (value.Equals("Default", StringComparison.OrdinalIgnoreCase))
        {
            return TweakValueKind.Default;
        }

        if (value.Equals("Unsupported", StringComparison.OrdinalIgnoreCase))
        {
            return TweakValueKind.Unsupported;
        }

        if (value.Equals("Unknown", StringComparison.OrdinalIgnoreCase))
        {
            return TweakValueKind.Unknown;
        }

        return TweakValueKind.Other;
    }

    /// <summary>The text a value is shown with.</summary>
    public static string Value(LocalizationService strings, string? token)
    {
        var kind = Kind(token);
        if (kind != TweakValueKind.Other)
        {
            return strings[KindKey(kind)];
        }

        var name = (token ?? string.Empty).Trim();
        return Lookup(strings, $"Tui.State.{name}", name);
    }

    /// <summary>The brush key the view maps to a colour for a value of this kind.</summary>
    public static string Tone(TweakValueKind kind) => kind switch
    {
        // On: the tweak is doing something here.
        TweakValueKind.Enabled => "ok",

        // Nothing could be read: the interface says so in the warning colour instead of
        // presenting a silent "unknown" as a plain, unremarkable value.
        TweakValueKind.Unknown => "warn",

        // It cannot run on this host; the reason is shown next to it as secondary text.
        TweakValueKind.Unsupported => "subtext",

        // Off, nothing configured, and any product name or tweak-specific token: neutral.
        _ => "muted",
    };

    /// <summary>The text a privilege token is shown with.</summary>
    public static string Privilege(LocalizationService strings, string? token)
    {
        var value = (token ?? string.Empty).Trim();
        return value.Length == 0 ? string.Empty : Lookup(strings, $"Tui.Privilege.{value}", value);
    }

    /// <summary>
    /// Looks a key up and falls back to the token when the tables carry no entry: the
    /// service renders a missing key in brackets, which is the only signal that the
    /// interface has no wording for this token.
    /// </summary>
    public static string Lookup(LocalizationService strings, string key, string fallback)
    {
        var text = strings[key];
        return text == $"[{key}]" ? fallback : text;
    }

    private static string KindKey(TweakValueKind kind) => kind switch
    {
        TweakValueKind.Enabled => "Gui.State.Enabled",
        TweakValueKind.Disabled => "Gui.State.Disabled",
        TweakValueKind.Default => "Gui.State.Default",
        TweakValueKind.Unsupported => "Gui.State.Unsupported",
        _ => "Gui.State.Unknown",
    };
}

/// <summary>
/// One catalog row as the window renders it: the localized name kept apart from the value,
/// the technical id still there for disambiguation, and the engine's own token left
/// untouched on <see cref="State"/> so no operation ever depends on presentation text.
/// </summary>
public sealed record TweakRow(
    TweakState Row,
    string Name,
    string SecondaryText,
    string ValueText,
    TweakValueKind ValueKind,
    string ValueTone)
{
    /// <summary>Lifecycles the engine no longer applies: only a restore remains possible.</summary>
    private static readonly string[] RetiredLifecycles = { "Unsupported", "Restore-only", "Deprecated" };

    /// <summary>Builds the presentation row from the engine's flat row.</summary>
    public static TweakRow Create(TweakState row, LocalizationService strings)
    {
        var kind = TweakText.Kind(row.State);
        return new TweakRow(row, row.Name, row.Id, TweakText.Value(strings, row.State), kind, TweakText.Tone(kind));
    }

    /// <summary>The raw engine token for the current value. Operations use this, never <see cref="ValueText"/>.</summary>
    public string State => Row.State;

    /// <summary>The stable tweak id.</summary>
    public string Id => Row.Id;

    /// <summary>The category the engine reports.</summary>
    public string Category => Row.Category;

    /// <summary>What the tweak does, localized by the engine.</summary>
    public string Description => Row.Description;

    /// <summary>What the user notices when it runs, localized by the engine.</summary>
    public string Impact => Row.Impact;

    /// <summary>The engine's own note on the value it read.</summary>
    public string Details => Row.Details;

    /// <summary>The impact level the engine assigns.</summary>
    public string Risk => Row.Risk;

    /// <summary>The scope the change touches.</summary>
    public string Scope => Row.Scope;

    /// <summary>The privilege the engine requires.</summary>
    public string Privilege => Row.Privilege;

    /// <summary>Whether a restart is needed for the change to take effect.</summary>
    public string Restart => Row.Restart;

    /// <summary>How far the change can be undone.</summary>
    public string Rollback => Row.Rollback;

    /// <summary>The state the tweak returns to when nothing is configured.</summary>
    public string DefaultState => Row.DefaultState;

    /// <summary>The states this tweak accepts as a target.</summary>
    public IReadOnlyList<string> StateNames => Row.StateNames;

    /// <summary>The engine's requirement tokens (privilege, OS, build, cmdlet, module).</summary>
    public IReadOnlyList<string> Requires => Row.Requires;

    /// <summary>True when the change is not fully reversible.</summary>
    public bool Irreversible => Row.Irreversible;

    /// <summary>True when the change removes data.</summary>
    public bool DataDeletion => Row.DataDeletion;

    /// <summary>True when the change lowers the protection the host had.</summary>
    public bool ReducesProtection => Row.ReducesProtection;

    /// <summary>True when the engine's prerequisites are met on this host.</summary>
    public bool Supported => Row.Supported;

    /// <summary>The engine's explanation for an unmet prerequisite.</summary>
    public string UnsupportedReason => Row.UnsupportedReason;

    /// <summary>The engine's lifecycle token for the tweak.</summary>
    public string Lifecycle => Row.Lifecycle;

    /// <summary>True when a policy holds the setting.</summary>
    public bool Managed => Row.Managed;

    /// <summary>The policies holding the setting.</summary>
    public IReadOnlyList<string> ManagedBy => Row.ManagedBy;

    /// <summary>The engine's verification note for the value it read.</summary>
    public string Note => Row.Note;

    /// <summary>True when the lifecycle still lets the engine apply this tweak.</summary>
    public bool LifecycleAllowsApply =>
        !RetiredLifecycles.Contains(Lifecycle, StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// True when this host can run the tweak. The engine's apply rule is the supported flag
    /// together with a lifecycle that has not been retired.
    /// </summary>
    public bool CanRun => Supported && LifecycleAllowsApply;

    /// <summary>The engine's reason, split into the failures it joined with ';'.</summary>
    public IReadOnlyList<string> FailureReasons => UnsupportedReason
        .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .Where(segment => segment.Length > 0)
        .ToArray();

    /// <summary>
    /// True when an unmet privilege requirement is among the failures. Elevating the
    /// backend session or relaunching can satisfy it, so the interface offers it as a
    /// recoverable action rather than as a dead end. The engine builds that sentence with
    /// an argument it leaves empty, so the segment ends at its colon.
    /// </summary>
    public bool RequiresElevation => !Supported && FailureReasons.Any(IsPrivilegeFailure);

    /// <summary>
    /// True when the operating system is among the failures. The engine embeds the
    /// requirement's own argument in that message, which is what separates it from a
    /// privilege failure: nothing the user does here can satisfy it.
    /// </summary>
    public bool OsIncompatible => !Supported && FailureReasons.Any(MatchesOsFamilyFailure);

    /// <summary>True for the privilege failure shape: a sentence that ends at its colon.</summary>
    internal static bool IsPrivilegeFailure(string segment) => segment.EndsWith(':');

    private bool MatchesOsFamilyFailure(string segment)
    {
        foreach (var requirement in Requires)
        {
            var separator = requirement.IndexOf(':');
            if (separator <= 0)
            {
                continue;
            }

            var kind = requirement[..separator];
            var argument = requirement[(separator + 1)..].Trim();
            if (argument.Length == 0)
            {
                continue;
            }

            if (kind.Equals("OS", StringComparison.OrdinalIgnoreCase)
                && segment.Contains(argument, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            // The engine's operating-system message carries "build >= N" as its argument.
            if (kind.Equals("Build", StringComparison.OrdinalIgnoreCase)
                && segment.Contains($"build >= {argument}", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}

/// <summary>The catalog workspace: search, filter, select, inspect and stage changes.</summary>
/// <remarks>
/// Selecting a row stages nothing. The reviewed list is the only place a change can wait,
/// and applying it is an explicit action in the review workspace - the same separation the
/// terminal interface keeps between browsing and its pending set.
/// </remarks>
public sealed class TweaksViewModel : WorkspaceViewModel
{
    private readonly List<TweakRow> _all = new();
    private string _search = string.Empty;
    private string _category = string.Empty;
    private bool _onlySupported;
    private TweakRow? _selected;
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
    public ObservableCollection<TweakRow> States { get; } = new();

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
    public TweakRow? Selected
    {
        get => _selected;
        set
        {
            if (Set(ref _selected, value))
            {
                TargetState = value?.StateNames.FirstOrDefault() ?? string.Empty;
                Raise(nameof(HasSelection));
                Raise(nameof(DetailsTitle));
                Raise(nameof(DetailDescription));
                Raise(nameof(DetailImpact));
                Raise(nameof(DetailCompatibility));
                Raise(nameof(DetailPrivileges));
                Raise(nameof(DetailTargetValue));
                Raise(nameof(RequiresElevation));
                Raise(nameof(OsIncompatible));
                Raise(nameof(DetailsBody));
                Raise(nameof(CanStage));
                Raise(nameof(StageBlockedReason));
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
                Raise(nameof(CanStage));
                Raise(nameof(StageBlockedReason));
                Raise(nameof(DetailTargetValue));
            }
        }
    }

    /// <summary>True when a row is selected.</summary>
    public bool HasSelection => _selected is not null;

    /// <summary>
    /// True when the selection can be staged for review, judged by the rules the engine
    /// itself applies: supported on this host, a lifecycle that still allows an apply, and
    /// a target state the tweak declares.
    /// </summary>
    public bool CanStage => _selected is not null && StageRefusal(_selected, _targetState) is null;

    /// <summary>The reason the selection cannot be staged, or empty when it can.</summary>
    public string StageBlockedReason =>
        _selected is null ? string.Empty : StageRefusal(_selected, _targetState) ?? string.Empty;

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

    /// <summary>The tweak's description, labelled by <c>Gui.Tweaks.DetailDescription</c>.</summary>
    public string DetailDescription => _selected?.Description ?? string.Empty;

    /// <summary>What the user notices when the tweak runs, labelled by <c>Gui.Tweaks.DetailImpact</c>.</summary>
    public string DetailImpact => _selected?.Impact ?? string.Empty;

    /// <summary>
    /// Why this host cannot run the tweak, labelled by <c>Gui.Tweaks.DetailCompatibility</c>.
    /// Empty when the prerequisites are met: there is nothing to report about compatibility
    /// that the rest of the pane does not already say.
    /// </summary>
    /// <remarks>
    /// The engine joins every unmet requirement with ';'. A privilege requirement carries
    /// no argument, so its sentence ends at a bare colon ("... required for: ;"); that
    /// fragment is replaced here with the plain sentence the interface already has, so the
    /// window never shows a colon with nothing after it.
    /// </remarks>
    public string DetailCompatibility
    {
        get
        {
            if (_selected is null || _selected.Supported)
            {
                return string.Empty;
            }

            return CompatibilityReason(_selected);
        }
    }

    /// <summary>The privilege the tweak needs, labelled by <c>Gui.Tweaks.DetailPrivileges</c>.</summary>
    public string DetailPrivileges =>
        _selected is null ? string.Empty : TweakText.Privilege(Strings, _selected.Privilege);

    /// <summary>
    /// The state currently chosen as the target, shown with its own words and never
    /// translated away (labelled by <c>Gui.Tweaks.DetailTarget</c>). Empty when the tweak
    /// has no target chosen.
    /// </summary>
    public string DetailTargetValue =>
        string.IsNullOrWhiteSpace(_targetState) ? string.Empty : TweakText.Value(Strings, _targetState);

    /// <summary>
    /// True when the tweak is unusable here only for want of an elevated session, which
    /// relaunching can satisfy: the view shows <c>Gui.Tweaks.RequiresAdmin</c> for it.
    /// </summary>
    public bool RequiresElevation => _selected?.RequiresElevation == true;

    /// <summary>
    /// True when the tweak is unusable here because of the operating system, which nothing
    /// on this machine can satisfy: the view shows <c>Gui.Tweaks.IncompatibleOs</c> for it.
    /// </summary>
    public bool OsIncompatible => _selected?.OsIncompatible == true;

    /// <summary>
    /// The remaining facts the terminal interface also shows - the value read, its note,
    /// the risk, the scope, the restart and rollback behaviour, and the warnings that
    /// change how the change itself is treated.
    /// </summary>
    public string DetailsBody
    {
        get
        {
            if (_selected is null)
            {
                return string.Empty;
            }

            var row = _selected;
            var parts = new List<string>
            {
                $"{Strings["Gui.Tweaks.ColumnValue"]}: {row.ValueText}" +
                    (string.IsNullOrEmpty(row.Details) ? string.Empty : $" ({row.Details})"),
                $"{Strings["Gui.Column.Risk"]}: {row.Risk} | {Strings["Gui.Column.Scope"]}: {row.Scope}",
                $"{Strings["Gui.Restart"]}: {row.Restart} | {Strings["Gui.RollbackSupport"]}: {row.Rollback}",
            };

            if (row.Managed)
            {
                parts.Add(Strings.Get("Error.ManagedByPolicy", string.Join(", ", row.ManagedBy)));
            }

            if (row.Irreversible)
            {
                parts.Add(Strings["Gui.IrreversibleWarning"]);
            }

            if (!string.IsNullOrEmpty(row.Note))
            {
                parts.Add(row.Note);
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
                _all.AddRange(rows
                    .Select(r => TweakRow.Create(r, Strings))
                    .OrderBy(r => r.Category, StringComparer.Ordinal)
                    .ThenBy(r => r.Id, StringComparer.Ordinal));

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
            filtered = filtered.Where(r => r.CanRun);
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

    /// <summary>
    /// Stages the selection into the review workspace. Applies nothing.
    /// </summary>
    /// <remarks>
    /// The eligibility rules are evaluated again here, not only in <see cref="CanStage"/>:
    /// a disabled button is not a guard, and a row read before the host changed must not be
    /// staged on the strength of a stale decision.
    /// </remarks>
    public string? StageSelection()
    {
        var refusal = StageRefusal(_selected, _targetState);
        if (refusal is not null)
        {
            return refusal;
        }

        return Shell.Review.Add(new ReviewedChange(_selected!.Id, _targetState, _selected.Name, _selected.State));
    }

    /// <summary>The loaded row with this id, or null when the catalog no longer carries it.</summary>
    internal TweakRow? FindRow(string id) => _all.FirstOrDefault(row => row.Id == id);

    /// <summary>
    /// The engine's own eligibility rules for a change, evaluated on one row and target:
    /// a host that meets the prerequisites, a lifecycle that still allows an apply, and a
    /// target state the tweak declares. Returns null when the change may be staged, or the
    /// reason it may not.
    /// </summary>
    internal string? StageRefusal(TweakRow? row, string targetState)
    {
        if (row is null)
        {
            return Strings["Gui.Error.NoSelection"];
        }

        if (!row.Supported)
        {
            // The engine's reason, with the privilege sentence repaired.
            return CompatibilityReason(row);
        }

        if (!row.LifecycleAllowsApply)
        {
            var key = $"Tweak.Lifecycle.{row.Lifecycle}";
            return TweakText.Lookup(Strings, key, row.Lifecycle);
        }

        if (string.IsNullOrWhiteSpace(targetState))
        {
            return Strings.Get("Error.StateRequired", row.Id);
        }

        if (row.StateNames.Count > 0
            && !row.StateNames.Contains(targetState, StringComparer.OrdinalIgnoreCase))
        {
            return Strings.Get("Error.InvalidState", targetState, row.Id, string.Join(", ", row.StateNames));
        }

        return null;
    }

    /// <summary>The engine's reason for one unsupported row, with the privilege fix applied.</summary>
    private string CompatibilityReason(TweakRow row)
    {
        var segments = row.FailureReasons
            .Select(segment => TweakRow.IsPrivilegeFailure(segment) ? Strings["Gui.Tweaks.RequiresAdmin"] : segment)
            .ToList();

        var reason = string.Join("; ", segments);
        return reason.Length == 0 ? Strings["Gui.State.Unsupported"] : reason;
    }
}

/// <summary>
/// One staged change as the review list renders it: the identity, and the value the row
/// holds now next to the value the change asks for, each in the window's own words.
/// </summary>
/// <remarks>
/// The raw tokens stay on <see cref="CurrentState"/> and <see cref="State"/>; the preview,
/// the apply and the engine always use those, never the text the columns show.
/// </remarks>
public sealed record ReviewChangeRow(
    ReviewedChange Change,
    string DisplayName,
    string SecondaryText,
    string CurrentValueText,
    string RequestedValueText)
{
    /// <summary>Builds the presentation row from the staged change.</summary>
    public static ReviewChangeRow Create(ReviewedChange change, LocalizationService strings)
    {
        ArgumentNullException.ThrowIfNull(change);
        return new ReviewChangeRow(
            change,
            change.DisplayName,
            change.Id,
            TweakText.Value(strings, change.CurrentState),
            TweakText.Value(strings, change.State));
    }

    /// <summary>The stable tweak id.</summary>
    public string Id => Change.Id;

    /// <summary>The raw requested state token. The engine is given this, never <see cref="RequestedValueText"/>.</summary>
    public string State => Change.State;

    /// <summary>The raw state the tweak held when it was staged.</summary>
    public string CurrentState => Change.CurrentState;

    /// <summary>Stable identity of a staged row (id + target state).</summary>
    public string Key => Change.Key;
}

/// <summary>The review workspace: the reviewed list, the preview, and the apply.</summary>
public sealed class ReviewViewModel : WorkspaceViewModel
{
    private bool _dryRun;
    private string _previewText = string.Empty;
    private bool _previewLoaded;
    private ReviewChangeRow? _selectedChange;

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
    public ObservableCollection<ReviewChangeRow> Changes { get; } = new();

    /// <summary>The outcome rows of the last apply/preview.</summary>
    public ObservableCollection<ApplyResult> Results { get; } = new();

    /// <summary>The row selected in the reviewed list (drives removal eligibility).</summary>
    public ReviewChangeRow? SelectedChange
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

    /// <summary>
    /// True when nothing is staged. The list, the preview and the actions all fall back to
    /// the empty state together, so an empty review can never show a stale preview.
    /// </summary>
    public bool IsEmptyState => !HasChanges;

    /// <summary>The empty state's message (shown instead of the list).</summary>
    public string EmptyStateMessage => Strings["Gui.Review.EmptyMessage"];

    /// <summary>The one action the empty state offers: pick a tweak and stage it.</summary>
    public string EmptyStateAction => Strings["Gui.Review.EmptyAction"];

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
        Raise(nameof(IsEmptyState));
        Raise(nameof(EmptyStateMessage));
        Raise(nameof(EmptyStateAction));
    }

    /// <summary>
    /// Adds one staged change. Returns a reason when it was refused.
    /// </summary>
    /// <remarks>
    /// The staging rules are checked here as well as in the catalog's own command: the row
    /// the change was built from may have been read before the host changed, and the
    /// engine's prerequisites are the authority, not the button that was pressed.
    /// </remarks>
    public string? Add(ReviewedChange change)
    {
        ArgumentNullException.ThrowIfNull(change);

        var row = Shell.Tweaks.FindRow(change.Id);
        if (row is null)
        {
            return Strings.Get("Error.TweakNotFound", change.Id);
        }

        var refusal = Shell.Tweaks.StageRefusal(row, change.State);
        if (refusal is not null)
        {
            return refusal;
        }

        var existing = Changes.FirstOrDefault(c => c.Id == change.Id);
        if (existing is not null)
        {
            Changes.Remove(existing);
        }

        Changes.Add(ReviewChangeRow.Create(change, Strings));
        PreviewLoaded = false;
        Results.Clear();
        StatusText = Strings.Get("Gui.Review.Confirm", Changes.Count);
        return null;
    }

    /// <summary>Removes the selected reviewed change.</summary>
    public void Remove(ReviewChangeRow change)
    {
        ArgumentNullException.ThrowIfNull(change);

        Changes.Remove(change);
        if (ReferenceEquals(_selectedChange, change))
        {
            SelectedChange = null;
        }

        PreviewLoaded = false;
        if (!HasChanges)
        {
            // Nothing staged means no preview: the text of a list that no longer exists
            // must not stay on screen.
            PreviewText = string.Empty;
        }
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
            // Nothing staged: the empty state carries the message, and the preview area
            // holds nothing at all.
            PreviewText = string.Empty;
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
