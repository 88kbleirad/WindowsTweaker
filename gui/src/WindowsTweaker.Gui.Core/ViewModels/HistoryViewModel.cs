using System.Collections.ObjectModel;
using System.Globalization;
using WindowsTweaker.Gui.Core.Model;

namespace WindowsTweaker.Gui.Core.ViewModels;

/// <summary>
/// The history and recovery workspace: what was applied, what was interrupted, and how to
/// restore it.
/// </summary>
/// <remarks>
/// History is read from the journal, never from anything this window remembers, so a run
/// that ended in another session is visible here. Restoring is a mutating operation under
/// the shell's accounting, and the engine's own external-change check still applies: this
/// view never restores over a value something else changed without the engine saying so.
/// </remarks>
public sealed class HistoryViewModel : WorkspaceViewModel
{
    private bool _showOperations;
    private HistoryDisplayRow? _selectedRow;
    private OperationDisplayRow? _selectedOperation;
    private InterruptedDisplayRow? _selectedInterrupted;

    public HistoryViewModel(ShellViewModel shell)
        : base(shell)
    {
        // Command eligibility depends on the connection and the shell's busy flag.
        Shell.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ShellViewModel.Connection) or nameof(ShellViewModel.Busy))
            {
                Raise(nameof(CanRestore));
            }
        };
    }

    /// <summary>Completed (and failed) history rows, newest first.</summary>
    public ObservableCollection<HistoryDisplayRow> Rows { get; } = new();

    /// <summary>Journal operation rows, newest first.</summary>
    public ObservableCollection<OperationDisplayRow> Operations { get; } = new();

    /// <summary>Operations that started and never finished.</summary>
    public ObservableCollection<InterruptedDisplayRow> Interrupted { get; } = new();

    /// <summary>Target comparison for the selected interrupted operation.</summary>
    public ObservableCollection<InterruptedTarget> InterruptedTargets { get; } = new();

    /// <summary>When set, the journal view is shown instead of the history view.</summary>
    public bool ShowOperations
    {
        get => _showOperations;
        set => Set(ref _showOperations, value);
    }

    /// <summary>Selected history row.</summary>
    public HistoryDisplayRow? SelectedRow
    {
        get => _selectedRow;
        set
        {
            if (Set(ref _selectedRow, value))
            {
                Raise(nameof(CanRestore));
                Raise(nameof(HasSelection));
                Raise(nameof(SelectedSummary));
                Raise(nameof(SelectedRaw));
            }
        }
    }

    /// <summary>Selected journal operation row.</summary>
    public OperationDisplayRow? SelectedOperation
    {
        get => _selectedOperation;
        set
        {
            if (Set(ref _selectedOperation, value))
            {
                Raise(nameof(CanRestore));
                Raise(nameof(HasSelection));
                Raise(nameof(SelectedSummary));
                Raise(nameof(SelectedRaw));
            }
        }
    }

    /// <summary>Selected interrupted operation.</summary>
    public InterruptedDisplayRow? SelectedInterrupted
    {
        get => _selectedInterrupted;
        set
        {
            if (Set(ref _selectedInterrupted, value))
            {
                Raise(nameof(CanRestore));
                Raise(nameof(HasSelection));
                Raise(nameof(SelectedSummary));
                Raise(nameof(SelectedRaw));
                _ = LoadInterruptedTargetsAsync();
            }
        }
    }

    /// <summary>True when any row is selected (drives the "select a row" hint).</summary>
    public bool HasSelection =>
        SelectedRow is not null || SelectedOperation is not null || SelectedInterrupted is not null;

    /// <summary>True when the selection can be restored.</summary>
    public bool CanRestore =>
        Shell.IsConnected && !Shell.Busy &&
        (SelectedRow is { Source: { RolledBack: false, Irreversible: false } } ||
         SelectedInterrupted is { Source: { CanRestore: true } });

    /// <summary>Short description of the selection.</summary>
    public string SelectedSummary
    {
        get
        {
            var lines = new List<string>();
            if (SelectedRow is { } row)
            {
                lines.Add($"{Strings["Gui.Column.Time"]}: {row.Time}");
                lines.Add($"{Strings["Gui.Column.Tweak"]}: {row.TweakId}");
                lines.Add($"{Strings["Gui.Column.State"]}: {row.State}");
                lines.Add($"{Strings["Gui.Column.Result"]}: {row.OutcomeText}");
                if (!string.Equals(row.Outcome, row.OutcomeText, StringComparison.Ordinal))
                {
                    // The engine's own wording for the code is kept when it differs from the
                    // shared result label: the label is a summary, never a replacement.
                    lines.Add($"{Strings["Gui.Column.Outcome"]}: {row.Outcome}");
                }

                if (row.Detail.Length > 0)
                {
                    lines.Add($"{Strings["Gui.Column.Detail"]}: {row.Detail}");
                }

                return string.Join(Environment.NewLine, lines);
            }

            if (SelectedOperation is { } operation)
            {
                lines.Add($"{Strings["Gui.Column.Time"]}: {operation.Time}");
                lines.Add($"{Strings["Gui.Column.Tweak"]}: {operation.TweakId}");
                lines.Add($"{Strings["Gui.Column.Operation"]}: {operation.Source.OperationId}");
                lines.Add($"{Strings["Gui.Column.State"]}: {operation.Stage}");
                lines.Add($"{Strings["Gui.Column.Outcome"]}: {operation.Outcome}");
                lines.Add($"{Strings["Gui.Column.Source"]}: {operation.Origin}");
                if (operation.Detail.Length > 0)
                {
                    lines.Add($"{Strings["Gui.Column.Detail"]}: {operation.Detail}");
                }

                return string.Join(Environment.NewLine, lines);
            }

            if (SelectedInterrupted is { } interrupted)
            {
                lines.Add($"{Strings["Gui.Column.Time"]}: {interrupted.Time}");
                lines.Add($"{Strings["Gui.Column.Tweak"]}: {interrupted.TweakId}");
                lines.Add($"{Strings["Gui.Column.State"]}: {interrupted.Stage}");
                if (interrupted.Detail.Length > 0)
                {
                    lines.Add($"{Strings["Gui.Column.Detail"]}: {interrupted.Detail}");
                }

                foreach (var target in interrupted.Source.Targets)
                {
                    if (!string.IsNullOrEmpty(target.Label))
                    {
                        lines.Add($"{Strings["Gui.Column.Target"]}: {target.Label}");
                    }

                    lines.Add($"{Strings["Gui.Column.Value"]}: {target.Intended} -> {target.Live}");
                }

                return string.Join(Environment.NewLine, lines);
            }

            return string.Empty;
        }
    }

    /// <summary>Raw technical text of the selection (the source row, for copying).</summary>
    public string SelectedRaw
    {
        get
        {
            if (SelectedRow is { } row)
            {
                return row.Source.ToString();
            }

            if (SelectedOperation is { } operation)
            {
                return operation.Source.ToString();
            }

            if (SelectedInterrupted is { } interrupted)
            {
                return interrupted.Source.ToString();
            }

            return string.Empty;
        }
    }

    /// <inheritdoc />
    protected override async Task LoadAsync()
    {
        var ok = await RunAsync(
            "history.list",
            Projections.History,
            rows =>
            {
                Rows.Clear();
                foreach (var row in rows)
                {
                    Rows.Add(FromHistory(row));
                }
            },
            new Dictionary<string, object?>(StringComparer.Ordinal) { ["limit"] = 200 }).ConfigureAwait(true);

        if (!ok)
        {
            Loaded = true;
            return;
        }

        ok = await RunAsync(
            "journal.operation",
            Projections.Operations,
            rows =>
            {
                Operations.Clear();
                foreach (var row in rows)
                {
                    Operations.Add(FromOperation(row));
                }
            },
            new Dictionary<string, object?>(StringComparer.Ordinal) { ["limit"] = 200 }).ConfigureAwait(true);

        if (!ok)
        {
            Loaded = true;
            return;
        }

        ok = await RunAsync(
            "history.interrupted",
            Projections.Interrupted,
            rows =>
            {
                Interrupted.Clear();
                foreach (var row in rows)
                {
                    Interrupted.Add(FromInterrupted(row));
                }
            }).ConfigureAwait(true);

        if (ok)
        {
            MarkLoaded(Rows.Count + Operations.Count + Interrupted.Count);
        }

        Loaded = true;
    }

    private async Task LoadInterruptedTargetsAsync()
    {
        InterruptedTargets.Clear();
        if (_selectedInterrupted is null)
        {
            return;
        }

        foreach (var target in _selectedInterrupted.Source.Targets)
        {
            InterruptedTargets.Add(target);
        }

        // The backend reads the live value of every target with `-Targets`; that path is
        // used so the comparison is the engine's, not this view's.
        await RunAsync(
            "history.interrupted",
            Projections.Interrupted,
            rows =>
            {
                var match = rows.FirstOrDefault(r => r.OperationId == _selectedInterrupted.Source.OperationId);
                if (match is null)
                {
                    return;
                }

                InterruptedTargets.Clear();
                foreach (var target in match.Targets)
                {
                    InterruptedTargets.Add(target);
                }
            },
            new Dictionary<string, object?>(StringComparer.Ordinal) { ["targets"] = true },
            TimeSpan.FromMinutes(2)).ConfigureAwait(true);
    }

    /// <summary>
    /// Restores the newest captured change of the selected tweak (or the selected
    /// interrupted operation). Runs through Undo-WtTweak, so the journal, the read-back
    /// verification and the external-change check all apply.
    /// </summary>
    public async Task RestoreAsync(bool force = false)
    {
        var id = SelectedRow?.TweakId ?? SelectedInterrupted?.TweakId;
        var historyId = SelectedRow?.Source.OperationId ?? SelectedInterrupted?.Source.OperationId ?? string.Empty;
        if (string.IsNullOrEmpty(historyId))
        {
            StatusText = Strings["Gui.Error.NoSelection"];
            return;
        }

        if (!Shell.IsConnected)
        {
            StatusText = Shell.ConnectionError;
            return;
        }

        ErrorText = string.Empty;
        await Shell.RunMutatingAsync(async () =>
        {
            var args = new Dictionary<string, object?>(StringComparer.Ordinal) { ["historyId"] = historyId };
            if (!string.IsNullOrEmpty(id))
            {
                args["id"] = id;
            }

            var outcome = await Shell.Runner.RunAsync("rollback", Projections.Undo, args, TimeSpan.FromMinutes(30)).ConfigureAwait(true);
            if (!outcome.Ok || outcome.Value is null)
            {
                ErrorText = outcome.Message;
                StatusText = outcome.Message;
                return false;
            }

            var undo = outcome.Value!;
            StatusText = string.Join("; ", new[] { $"{undo.TweakId}: {undo.Status}" }.Concat(undo.Messages.Where(m => !string.IsNullOrEmpty(m))));
            if (undo.ReviewRequired && !force)
            {
                ErrorText = Strings["Msg.ExternalChange"];
            }

            return true;
        }).ConfigureAwait(true);

        await ReloadAsync().ConfigureAwait(true);
    }

    /// <summary>Exports the journal to a file, through the engine (same writer as the CLI).</summary>
    public async Task ExportAsync(string path)
    {
        var args = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["entries"] = Array.Empty<object>(),
            ["path"] = path,
            ["name"] = Path.GetFileNameWithoutExtension(path),
        };

        var outcome = await Shell.Runner.RunAsync(
            "preset.export",
            element => element.ValueKind == System.Text.Json.JsonValueKind.String ? element.GetString() ?? path : path,
            args,
            TimeSpan.FromSeconds(60)).ConfigureAwait(true);

        StatusText = outcome.Ok ? outcome.Value ?? path : outcome.Message;
    }

    /// <summary>Formats an ISO-8601 UTC timestamp as a local date/time; raw on parse failure.</summary>
    private static string FormatTime(string timestamp)
    {
        if (DateTimeOffset.TryParse(timestamp, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed))
        {
            return parsed.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
        }

        return timestamp;
    }

    /// <summary>Renders an engine outcome/stage code through the engine's own vocabulary.</summary>
    private string LocalizeOp(string code)
    {
        var text = Strings.Get("Op." + code);
        return text.StartsWith("[", StringComparison.Ordinal) ? code : text;
    }

    /// <summary>Renders a tweak state code only when the engine has a State.* label for it.</summary>
    private string LocalizeState(string code)
    {
        var text = Strings.Get("State." + code);
        return text.StartsWith("[", StringComparison.Ordinal) ? code : text;
    }

    private HistoryDisplayRow FromHistory(HistoryRow row)
    {
        var (outcomeText, outcomeTone) = OutcomeOf(row.Outcome);
        return new HistoryDisplayRow(
            FormatTime(row.Timestamp),
            row.TweakId,
            LocalizeState(row.State),
            LocalizeOp(row.Outcome),
            outcomeText,
            outcomeTone,
            string.Join("; ", row.Messages.Where(m => !string.IsNullOrEmpty(m))),
            row);
    }

    /// <summary>Maps one engine outcome code to the label and tone the result column shows.</summary>
    /// <remarks>
    /// The tone comes from the code the engine recorded, never from localized text, so the
    /// colour of a row is the same in every language. A code this build does not know keeps
    /// the engine's own label and claims no tone, rather than being folded into one.
    /// </remarks>
    private (string Text, string Tone) OutcomeOf(string code)
    {
        var (key, tone) = code switch
        {
            "succeeded" => ("Gui.Outcome.Success", "success"),
            "failed" => ("Gui.Outcome.Failure", "failure"),

            // An operation that never finished ('pending'), was abandoned, still needs a
            // review, or left its journal incomplete: none of these is a clean success.
            "pending" or "abandoned" or "review-required" or "partial" => ("Gui.Outcome.Interrupted", "interrupted"),

            // Recorded without a change being made.
            "skipped" or "unsupported" or "unchanged" => ("Gui.Outcome.Unchanged", "muted"),
            _ => (string.Empty, "muted"),
        };

        if (key.Length == 0)
        {
            return (LocalizeOp(code), tone);
        }

        var text = Strings[key];
        return (text.StartsWith("[", StringComparison.Ordinal) ? LocalizeOp(code) : text, tone);
    }

    private OperationDisplayRow FromOperation(OperationRow row) => new(
        FormatTime(row.Timestamp),
        row.TweakId,
        LocalizeOp(row.Stage),
        LocalizeOp(row.Outcome),
        row.Origin,
        string.Join("; ", row.Messages.Where(m => !string.IsNullOrEmpty(m))),
        row);

    private InterruptedDisplayRow FromInterrupted(InterruptedOperation operation) => new(
        FormatTime(operation.Timestamp),
        operation.TweakId,
        LocalizeOp(operation.Stage),
        operation.CanRestore ? Strings["Common.Yes"] : Strings["Common.No"],
        string.Join("; ", operation.Targets.Select(t => t.Label).Where(l => !string.IsNullOrEmpty(l))),
        operation);
}

/// <summary>One history row as the panel renders it (localized, local time).</summary>
/// <remarks>
/// The configuration state and the operation outcome are two independent values on a row: a
/// tweak can be disabled while its last operation succeeded, and neither is derived from the
/// other. <see cref="OutcomeTone"/> is one of <c>success</c>, <c>failure</c>, <c>interrupted</c>
/// or <c>muted</c>, computed from the engine's outcome code; <see cref="OutcomeText"/> is that
/// outcome's shared label while <see cref="Outcome"/> keeps the engine's own wording.
/// </remarks>
public sealed record HistoryDisplayRow(
    string Time,
    string TweakId,
    string State,
    string Outcome,
    string OutcomeText,
    string OutcomeTone,
    string Detail,
    HistoryRow Source);

/// <summary>One journal operation row as the panel renders it.</summary>
public sealed record OperationDisplayRow(string Time, string TweakId, string Stage, string Outcome, string Origin, string Detail, OperationRow Source);

/// <summary>One interrupted operation as the panel renders it.</summary>
public sealed record InterruptedDisplayRow(string Time, string TweakId, string Stage, string CanRestoreLabel, string Detail, InterruptedOperation Source);

/// <summary>The diagnostics workspace: read-only reporting and monitoring.</summary>
/// <remarks>
/// Everything here is read-only by construction. The only actions that touch a file are
/// the explicit exports, and they are performed by the engine, not by this view.
/// </remarks>
public sealed class DiagnosticsViewModel : WorkspaceViewModel
{
    private readonly SectionState _report = new();
    private readonly SectionState _scan = new();
    private readonly SectionState _monitor = new();
    private readonly SectionState _devices = new();
    private readonly SectionState _power = new();
    private readonly SectionState _privacy = new();
    private readonly SectionState _quarantine = new();
    private readonly SectionState _setup = new();
    private RuntimeStatus? _runtime;
    private string _scanPath = string.Empty;
    private string _technicalDetailsText = string.Empty;
    private bool _technicalDetailsVisible;
    private bool _technicalCopied;
    private bool _logCopied;
    private readonly ObservableCollection<string> _diagnostics = new();

    public DiagnosticsViewModel(ShellViewModel shell)
        : base(shell)
    {
        // The environment/protocol facts are owned by the shell; rebuild the readable list
        // when the shell refreshes them so the panel is never stale.
        Shell.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ShellViewModel.Environment)
                or nameof(ShellViewModel.Runtime)
                or nameof(ShellViewModel.EngineVersion)
                or nameof(ShellViewModel.BackendSummary))
            {
                RebuildEnvironmentFacts();
            }
        };

        // The summary, the dump and the action labels are text from the tables: a language
        // switch re-reads them instead of leaving the previous language on screen.
        Shell.Strings.LanguageChanged += (_, _) => RaiseLocalizedText();

        RebuildEnvironmentFacts();
    }

    /// <summary>Runtime profile and capability table (read-only).</summary>
    public RuntimeStatus? Runtime
    {
        get => _runtime;
        private set => Set(ref _runtime, value);
    }

    // ---- summary ----

    /// <summary>Operating system, build and culture, as one short line.</summary>
    public string SummaryOs => $"{Strings["Gui.Overview.Os"]}: {Shell.EnvironmentSummary}";

    /// <summary>PowerShell host, required version and language mode, as one short line.</summary>
    public string SummaryPowerShell => $"{Strings["Gui.Overview.PowerShell"]}: {Shell.RuntimeSummary}";

    /// <summary>Privilege level of the backend session, as one short line.</summary>
    public string SummaryPrivilege => $"{Strings["Gui.Overview.Privilege"]}: {Shell.PrivilegeLabel}";

    /// <summary>Engine (module) version, as one short line.</summary>
    public string SummaryEngine =>
        $"{Strings["Gui.Overview.Engine"]}: {(string.IsNullOrEmpty(Shell.EngineVersion) ? Strings["Gui.Overview.NotLoaded"] : Shell.EngineVersion)}";

    /// <summary>
    /// The backend connection state, as one short line. It reports the live connection, not
    /// the last successful one: a disconnected backend must never read as connected.
    /// </summary>
    public string SummaryBackend =>
        $"{Strings["Gui.Header.Backend"]}: {(Shell.IsConnected ? Strings["Gui.Connected"] : Shell.ConnectionLabel)}";

    /// <summary>
    /// True while the long technical property dump is expanded. The compact summary above
    /// stays on the surface; the dump is the complete, copyable detail behind this flag.
    /// </summary>
    public bool TechnicalDetailsVisible
    {
        get => _technicalDetailsVisible;
        set
        {
            if (Set(ref _technicalDetailsVisible, value))
            {
                // A copy confirmation belongs to the click that produced it: re-opening the
                // dump starts from "Copy" again.
                _technicalCopied = false;
                Raise(nameof(TechnicalDetailsCopyText));
            }
        }
    }

    /// <summary>
    /// The complete environment and protocol property dump as one text block. It is a text
    /// property rather than a rendering of the list so a long journal or log path can be
    /// selected and copied whole.
    /// </summary>
    public string TechnicalDetailsText
    {
        get => _technicalDetailsText;
        private set => Set(ref _technicalDetailsText, value);
    }

    /// <summary>Label of the copy action: Copy, or Copied immediately after a copy.</summary>
    public string TechnicalDetailsCopyText => _technicalCopied
        ? Strings["Gui.Diagnostics.Copied"]
        : Strings["Gui.Diagnostics.Copy"];

    /// <summary>Records that the view copied <see cref="TechnicalDetailsText"/> to the clipboard.</summary>
    public void MarkTechnicalDetailsCopied()
    {
        _technicalCopied = true;
        Raise(nameof(TechnicalDetailsCopyText));
    }

    /// <summary>Label of the directory-scan action.</summary>
    public string ScanActionText => Strings["Gui.Diagnostics.ScanDirectory"];

    /// <summary>Label of the report (re)generation action.</summary>
    public string ReportActionText => Strings["Gui.Action.RefreshReport"];

    // ---- report ----

    /// <summary>The report section's state.</summary>
    public LoadState ReportState => _report.State;

    /// <summary>Localized status line for the report section.</summary>
    public string ReportStatusText => StatusTextFor(_report);

    /// <summary>Semantic tone of <see cref="ReportStatusText"/> (idle/loading/success/unsupported/error).</summary>
    public string ReportStatusTone => ToneFor(_report);

    /// <summary>True when the report's summarized content should be shown.</summary>
    public bool ReportSummaryVisible => SummaryVisibleFor(_report);

    /// <summary>The generated diagnostics report, readable.</summary>
    public string ReportSummary => SummarizeText(_report);

    /// <summary>The generated diagnostics report, exact JSON.</summary>
    public string ReportRaw => _report.Raw;

    /// <summary>The generated diagnostics report, as JSON text (kept for existing bindings).</summary>
    public string ReportText
    {
        get => _report.Raw;
        private set => _report.Raw = value;
    }

    // ---- scan ----

    /// <summary>The scan section's state.</summary>
    public LoadState ScanState => _scan.State;

    /// <summary>Localized status line for the scan section.</summary>
    public string ScanStatusText => StatusTextFor(_scan);

    /// <summary>Semantic tone of <see cref="ScanStatusText"/> (idle/loading/success/unsupported/error).</summary>
    public string ScanStatusTone => ToneFor(_scan);

    /// <summary>True when the scan's summarized content should be shown.</summary>
    public bool ScanSummaryVisible => SummaryVisibleFor(_scan);

    /// <summary>The directory scan result, readable.</summary>
    public string ScanSummary => SummarizeText(_scan);

    /// <summary>The directory scan result, exact JSON.</summary>
    public string ScanRaw => _scan.Raw;

    /// <summary>The directory scan result (kept for existing bindings).</summary>
    public string ScanResult
    {
        get => _scan.Raw;
        private set => _scan.Raw = value;
    }

    /// <summary>Directory to scan.</summary>
    public string ScanPath
    {
        get => _scanPath;
        set => Set(ref _scanPath, value);
    }

    // ---- monitor ----

    /// <summary>The monitor section's state.</summary>
    public LoadState MonitorState => _monitor.State;

    /// <summary>Localized status line for the monitor section.</summary>
    public string MonitorStatusText => StatusTextFor(_monitor);

    /// <summary>Semantic tone of <see cref="MonitorStatusText"/> (idle/loading/success/unsupported/error).</summary>
    public string MonitorStatusTone => ToneFor(_monitor);

    /// <summary>True when the monitor's summarized content should be shown.</summary>
    public bool MonitorSummaryVisible => SummaryVisibleFor(_monitor);

    /// <summary>The monitoring cycle result, readable.</summary>
    public string MonitorSummary => SummarizeText(_monitor);

    /// <summary>The monitoring cycle result, exact JSON.</summary>
    public string MonitorRaw => _monitor.Raw;

    /// <summary>The monitoring cycle result (kept for existing bindings).</summary>
    public string MonitorResult
    {
        get => _monitor.Raw;
        private set => _monitor.Raw = value;
    }

    // ---- devices ----

    /// <summary>The devices section's state.</summary>
    public LoadState DeviceState => _devices.State;

    /// <summary>Localized status line for the devices section.</summary>
    public string DeviceStatusText => StatusTextFor(_devices);

    /// <summary>Semantic tone of <see cref="DeviceStatusText"/> (idle/loading/success/unsupported/error).</summary>
    public string DeviceStatusTone => ToneFor(_devices);

    /// <summary>True when the device inventory's summarized content should be shown.</summary>
    public bool DeviceSummaryVisible => SummaryVisibleFor(_devices);

    /// <summary>The device inventory summary, readable.</summary>
    public string DeviceSummary => SummarizeText(_devices);

    /// <summary>The device inventory summary, exact JSON.</summary>
    public string DeviceRaw => _devices.Raw;

    /// <summary>The device inventory summary (kept for existing bindings).</summary>
    public string DeviceResult
    {
        get => _devices.Raw;
        private set => _devices.Raw = value;
    }

    // ---- power ----

    /// <summary>The power section's state.</summary>
    public LoadState PowerState => _power.State;

    /// <summary>Localized status line for the power section.</summary>
    public string PowerStatusText => StatusTextFor(_power);

    /// <summary>Semantic tone of <see cref="PowerStatusText"/> (idle/loading/success/unsupported/error).</summary>
    public string PowerStatusTone => ToneFor(_power);

    /// <summary>True when the power section's summarized content should be shown.</summary>
    public bool PowerSummaryVisible => SummaryVisibleFor(_power);

    /// <summary>The power settings summary, readable.</summary>
    public string PowerSummary => SummarizeText(_power);

    /// <summary>The power settings summary, exact JSON.</summary>
    public string PowerRaw => _power.Raw;

    /// <summary>The power settings summary (kept for existing bindings).</summary>
    public string PowerResult
    {
        get => _power.Raw;
        private set => _power.Raw = value;
    }

    // ---- privacy ----

    /// <summary>The privacy section's state.</summary>
    public LoadState PrivacyState => _privacy.State;

    /// <summary>Localized status line for the privacy section.</summary>
    public string PrivacyStatusText => StatusTextFor(_privacy);

    /// <summary>Semantic tone of <see cref="PrivacyStatusText"/> (idle/loading/success/unsupported/error).</summary>
    public string PrivacyStatusTone => ToneFor(_privacy);

    /// <summary>True when the privacy section's summarized content should be shown.</summary>
    public bool PrivacySummaryVisible => SummaryVisibleFor(_privacy);

    /// <summary>The privacy activity summary, readable.</summary>
    public string PrivacySummary => SummarizeText(_privacy);

    /// <summary>The privacy activity summary, exact JSON.</summary>
    public string PrivacyRaw => _privacy.Raw;

    /// <summary>The privacy activity summary (kept for existing bindings).</summary>
    public string PrivacyResult
    {
        get => _privacy.Raw;
        private set => _privacy.Raw = value;
    }

    // ---- quarantine ----

    /// <summary>The quarantine section's state.</summary>
    public LoadState QuarantineState => _quarantine.State;

    /// <summary>Localized status line for the quarantine section.</summary>
    public string QuarantineStatusText => StatusTextFor(_quarantine);

    /// <summary>Semantic tone of <see cref="QuarantineStatusText"/> (idle/loading/success/unsupported/error).</summary>
    public string QuarantineStatusTone => ToneFor(_quarantine);

    /// <summary>True when the quarantine section's summarized content should be shown.</summary>
    public bool QuarantineSummaryVisible => SummaryVisibleFor(_quarantine);

    /// <summary>The quarantine summary, readable.</summary>
    public string QuarantineSummary => SummarizeText(_quarantine);

    /// <summary>The quarantine summary, exact JSON.</summary>
    public string QuarantineRaw => _quarantine.Raw;

    /// <summary>The quarantine summary (kept for existing bindings).</summary>
    public string QuarantineResult
    {
        get => _quarantine.Raw;
        private set => _quarantine.Raw = value;
    }

    // ---- setup ----

    /// <summary>The setup section's state.</summary>
    public LoadState SetupState => _setup.State;

    /// <summary>Localized status line for the setup section.</summary>
    public string SetupStatusText => StatusTextFor(_setup);

    /// <summary>Semantic tone of <see cref="SetupStatusText"/> (idle/loading/success/unsupported/error).</summary>
    public string SetupStatusTone => ToneFor(_setup);

    /// <summary>True when the setup section's summarized content should be shown.</summary>
    public bool SetupSummaryVisible => SummaryVisibleFor(_setup);

    /// <summary>The setup plans summary, readable.</summary>
    public string SetupSummary => SummarizeText(_setup);

    /// <summary>The setup plans summary, exact JSON.</summary>
    public string SetupRaw => _setup.Raw;

    /// <summary>The setup plans summary (kept for existing bindings).</summary>
    public string SetupResult
    {
        get => _setup.Raw;
        private set => _setup.Raw = value;
    }

    /// <summary>The environment/protocol block, as localized "label: value" lines.</summary>
    public ObservableCollection<string> EnvironmentFacts { get; } = new();

    /// <summary>Bounded tail of backend diagnostics (never unbounded, never on the UI thread).</summary>
    public ObservableCollection<string> Diagnostics => _diagnostics;

    /// <summary>Localized count of the recorded backend activity lines.</summary>
    public string CountText => Strings.Get("Gui.Diagnostics.Lines", _diagnostics.Count);

    /// <summary>
    /// The whole log as one selectable block, for the read-only copyable log viewport.
    /// Rebuilt lazily from the bounded collection each time a line arrives; the cap is
    /// 200 lines, so rebuilding stays cheap.
    /// </summary>
    public string DiagnosticsText => string.Join(Environment.NewLine, _diagnostics);

    /// <summary>Label of the log copy action: Copy, or Copied immediately after a copy.</summary>
    public string LogCopyText => _logCopied
        ? Strings["Gui.Diagnostics.Copied"]
        : Strings["Gui.Diagnostics.Copy"];

    /// <summary>Records that the view copied <see cref="DiagnosticsText"/> to the clipboard.</summary>
    public void MarkLogCopied()
    {
        _logCopied = true;
        Raise(nameof(LogCopyText));
    }

    /// <summary>Appends one diagnostic line, keeping the tail bounded.</summary>
    public void AddDiagnostic(string message)
    {
        Shell.Dispatch(() =>
        {
            _diagnostics.Add(message);
            while (_diagnostics.Count > 200)
            {
                _diagnostics.RemoveAt(0);
            }

            Raise(nameof(CountText));
            Raise(nameof(DiagnosticsText));
        });
    }

    /// <summary>Appends one backend activity line to the tail (technical text).</summary>
    public void AddActivity(BackendActivity activity)
    {
        var code = activity.Ok ? "ok" : (string.IsNullOrEmpty(activity.Code) ? activity.Message : activity.Code);
        AddDiagnostic($"{activity.Operation} {activity.RequestId} {activity.ElapsedMs} ms -> {code}");
    }

    /// <inheritdoc />
    protected override async Task LoadAsync()
    {
        Runtime = Shell.Runtime;

        BeginSection(_report, Strings["Gui.Diagnostics.Report"]);
        var ok = await RunAsync(
            "diagnostics.report",
            element => element.GetRawText(),
            text => SucceedSection(_report, text),
            timeout: TimeSpan.FromMinutes(3),
            statusWhileRunning: Strings["Gui.Diagnostics.Report"]).ConfigureAwait(true);

        if (!ok)
        {
            FailSection(_report, ErrorText);
        }

        RaiseSection("Report");
        if (ok)
        {
            MarkLoaded(1);
        }

        Loaded = true;
    }

    /// <summary>Runs the diagnostics report (read-only).</summary>
    public async Task ReportAsync()
    {
        BeginSection(_report, Strings["Gui.Diagnostics.Report"]);
        var ok = await RunAsync(
            "diagnostics.report",
            element => element.GetRawText(),
            text => SucceedSection(_report, text),
            timeout: TimeSpan.FromMinutes(3),
            statusWhileRunning: Strings["Gui.Diagnostics.Report"]).ConfigureAwait(true);

        if (!ok)
        {
            FailSection(_report, ErrorText);
        }

        RaiseSection("Report");
    }

    /// <summary>Runs the read-only directory scan.</summary>
    public async Task ScanAsync()
    {
        if (string.IsNullOrWhiteSpace(_scanPath))
        {
            ErrorText = Strings["Worker.Reason.RootInvalid"];
            FailSection(_scan, ErrorText);
            RaiseSection("Scan");
            return;
        }

        BeginSection(_scan, Strings.Get("Disk.Scanning", _scanPath));
        var ok = await RunAsync(
            "scan.directory",
            element => element.GetRawText(),
            text => SucceedSection(_scan, text),
            new Dictionary<string, object?>(StringComparer.Ordinal) { ["path"] = _scanPath },
            TimeSpan.FromMinutes(10),
            statusWhileRunning: Strings.Get("Disk.Scanning", _scanPath)).ConfigureAwait(true);

        if (!ok)
        {
            FailSection(_scan, ErrorText);
        }

        RaiseSection("Scan");
    }

    /// <summary>Runs one read-only monitoring cycle.</summary>
    public async Task MonitorAsync()
    {
        BeginSection(_monitor, Strings["Gui.Diagnostics.Monitor"]);
        var ok = await RunAsync(
            "monitor.cycle",
            element => element.GetRawText(),
            text => SucceedSection(_monitor, text),
            timeout: TimeSpan.FromMinutes(10),
            statusWhileRunning: Strings["Gui.Diagnostics.Monitor"]).ConfigureAwait(true);

        if (!ok)
        {
            FailSection(_monitor, ErrorText);
        }

        RaiseSection("Monitor");
    }

    /// <summary>Reads the device inventory.</summary>
    public async Task DevicesAsync()
    {
        BeginSection(_devices, Strings["Gui.Diagnostics.Devices"]);
        var ok = await RunAsync(
            "inventory.devices",
            element => element.GetRawText(),
            text => SucceedSection(_devices, text),
            timeout: TimeSpan.FromMinutes(3)).ConfigureAwait(true);

        if (!ok)
        {
            FailSection(_devices, ErrorText);
        }

        RaiseSection("Devices");
    }

    /// <summary>Reads the power settings.</summary>
    public async Task PowerAsync()
    {
        BeginSection(_power, Strings["Gui.Diagnostics.Power"]);
        var ok = await RunAsync(
            "power.settings",
            element => element.GetRawText(),
            text => SucceedSection(_power, text),
            timeout: TimeSpan.FromMinutes(3)).ConfigureAwait(true);

        if (!ok)
        {
            FailSection(_power, ErrorText);
        }

        RaiseSection("Power");
    }

    /// <summary>Reads the privacy activity view.</summary>
    public async Task PrivacyAsync()
    {
        BeginSection(_privacy, Strings["Gui.Diagnostics.Privacy"]);
        var ok = await RunAsync(
            "privacy.activity",
            element => element.GetRawText(),
            text => SucceedSection(_privacy, text),
            timeout: TimeSpan.FromMinutes(3)).ConfigureAwait(true);

        if (!ok)
        {
            FailSection(_privacy, ErrorText);
        }

        RaiseSection("Privacy");
    }

    /// <summary>Reads the quarantine summary.</summary>
    public async Task QuarantineAsync()
    {
        BeginSection(_quarantine, Strings["Gui.Diagnostics.Quarantine"]);
        var ok = await RunAsync(
            "quarantine.summary",
            element => element.GetRawText(),
            text => SucceedSection(_quarantine, text),
            timeout: TimeSpan.FromMinutes(3)).ConfigureAwait(true);

        if (!ok)
        {
            FailSection(_quarantine, ErrorText);
        }

        RaiseSection("Quarantine");
    }

    /// <summary>Lists setup plans.</summary>
    public async Task SetupAsync()
    {
        BeginSection(_setup, Strings["Gui.Diagnostics.SetupPlans"]);
        var ok = await RunAsync(
            "setup.list",
            element => element.GetRawText(),
            text => SucceedSection(_setup, text),
            timeout: TimeSpan.FromMinutes(3)).ConfigureAwait(true);

        if (!ok)
        {
            FailSection(_setup, ErrorText);
        }

        RaiseSection("Setup");
    }

    // ---- section plumbing ----

    /// <summary>Marks a section as loading and clears its previous result.</summary>
    private static void BeginSection(SectionState section, string status)
    {
        section.State = LoadState.Loading;
        section.StatusText = status;
        section.Raw = string.Empty;
    }

    /// <summary>Records a successful section result.</summary>
    private static void SucceedSection(SectionState section, string raw)
    {
        section.Raw = raw ?? string.Empty;
        section.State = LoadState.Ready;
        section.StatusText = string.Empty;
    }

    /// <summary>Records a section failure; never leaves the panel blank.</summary>
    private static void FailSection(SectionState section, string localized)
    {
        section.State = LoadState.Failed;
        section.StatusText = localized ?? string.Empty;
    }

    /// <summary>Re-publishes the bound properties of one section.</summary>
    private void RaiseSection(string prefix)
    {
        Raise(prefix + "State");
        Raise(prefix + "StatusText");
        Raise(prefix + "StatusTone");
        Raise(prefix + "SummaryVisible");
        Raise(prefix + "Summary");
        Raise(prefix + "Raw");
    }

    /// <summary>
    /// The logical state of a section as a stable semantic name the view maps to a colour:
    /// idle (nothing requested), loading, success, or failed. It is never localized, and
    /// it is kept separate from <see cref="StatusTextFor"/> so the label text and the
    /// colour can never contradict each other.
    /// </summary>
    private static string ToneFor(SectionState section) => section.State switch
    {
        LoadState.Idle => "idle",
        LoadState.Loading => "loading",
        LoadState.Failed => "error",
        LoadState.Ready when !HasContent(section) => "unsupported",
        _ => "success",
    };

    /// <summary>
    /// True when a section has a successful result with real content to summarize. A
    /// successful-but-empty answer is described by the status line alone ("not available
    /// on this host"), so the summary never duplicates it.
    /// </summary>
    private static bool SummaryVisibleFor(SectionState section) =>
        section.State == LoadState.Ready && HasContent(section);

    /// <summary>True when a section's stored raw result has real content.</summary>
    private static bool HasContent(SectionState section)
    {
        var raw = section.Raw;
        return !string.IsNullOrWhiteSpace(raw) && raw is not "{}" and not "[]";
    }

    /// <summary>
    /// Re-reads every text this workspace renders from the tables, so a language switch
    /// reaches the summary, the dump, the section statuses and the action labels.
    /// </summary>
    private void RaiseLocalizedText()
    {
        RebuildEnvironmentFacts();
        foreach (var prefix in SectionPrefixes)
        {
            RaiseSection(prefix);
        }

        Raise(nameof(TechnicalDetailsCopyText));
        Raise(nameof(LogCopyText));
        Raise(nameof(ScanActionText));
        Raise(nameof(ReportActionText));
        Raise(nameof(CountText));
    }

    private static readonly string[] SectionPrefixes =
    {
        "Report", "Scan", "Monitor", "Devices", "Power", "Privacy", "Quarantine", "Setup",
    };

    /// <summary>The localized status line a section's state renders.</summary>
    private string StatusTextFor(SectionState section) => section.State switch
    {
        LoadState.Idle => Strings["Gui.Overview.NotLoaded"],
        LoadState.Loading => Strings["Gui.Overview.Loading"],
        LoadState.Failed => string.IsNullOrEmpty(section.StatusText) ? Strings["Gui.Connection.Failed"] : section.StatusText,
        // A successful-but-empty answer and a state never reached are both "not available on
        // this host": the summary is hidden for them, so the status line is the only text.
        LoadState.Ready when !HasContent(section) => Strings["Gui.Diagnostics.Unavailable"],
        _ => Strings["Gui.Ready"],
    };

    /// <summary>The readable form of a section's stored JSON (unavailable when empty).</summary>
    private string SummarizeText(SectionState section)
    {
        var raw = section.Raw;
        if (string.IsNullOrWhiteSpace(raw) || raw is "{}" or "[]")
        {
            return Strings["Gui.Diagnostics.Unavailable"];
        }

        return Summarize(raw);
    }

    private void RebuildEnvironmentFacts()
    {
        EnvironmentFacts.Clear();
        var facts = new List<string>
        {
            $"{Strings["Gui.Overview.Os"]}: {Shell.EnvironmentSummary}",
            $"{Strings["Gui.Overview.PowerShell"]}: {Shell.RuntimeSummary}",
            $"{Strings["Gui.Overview.Privilege"]}: {Shell.PrivilegeLabel}",
            $"{Strings["Gui.Overview.Engine"]}: {(string.IsNullOrEmpty(Shell.EngineVersion) ? Strings["Gui.Overview.NotLoaded"] : Shell.EngineVersion)}",
            $"{Strings["Gui.Restart"]}: {Shell.PendingRebootSummary}",
            $"{Strings["Gui.Header.Backend"]}: {Shell.BackendSummary}",
        };

        var pathLines = Shell.PathSummary.Split(new[] { Environment.NewLine }, StringSplitOptions.RemoveEmptyEntries);
        if (pathLines.Length >= 2)
        {
            facts.Add($"{Strings["Gui.Diagnostics.StatePath"]}: {pathLines[0]}");
            facts.Add($"{Strings["Gui.Diagnostics.LogPath"]}: {pathLines[1]}");
        }
        else if (pathLines.Length == 1)
        {
            facts.Add($"{Strings["Gui.Diagnostics.StatePath"]}: {pathLines[0]}");
        }

        foreach (var fact in facts)
        {
            EnvironmentFacts.Add(fact);
        }

        // The dump is those facts as one copyable block. It is the long detail behind the
        // compact summary: every property the shell reports, including the store and log
        // paths, which must stay selectable in full.
        TechnicalDetailsText = string.Join(Environment.NewLine, facts);

        RaiseSummary();
    }

    /// <summary>Re-publishes the compact summary lines.</summary>
    private void RaiseSummary()
    {
        Raise(nameof(SummaryOs));
        Raise(nameof(SummaryPowerShell));
        Raise(nameof(SummaryPrivilege));
        Raise(nameof(SummaryEngine));
        Raise(nameof(SummaryBackend));
    }

    /// <summary>Turns a JSON object into up to ~12 "label: value" lines.</summary>
    private static string Summarize(string json)
    {
        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object)
            {
                return json;
            }

            var lines = new List<string>();
            AppendSummary(root, string.Empty, lines);
            return string.Join(Environment.NewLine, lines);
        }
        catch (System.Text.Json.JsonException)
        {
            return json;
        }
    }

    private static void AppendSummary(System.Text.Json.JsonElement element, string prefix, List<string> lines)
    {
        if (lines.Count >= SummaryLineCap)
        {
            return;
        }

        switch (element.ValueKind)
        {
            case System.Text.Json.JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    if (lines.Count >= SummaryLineCap)
                    {
                        return;
                    }

                    var path = prefix.Length == 0 ? property.Name : $"{prefix}.{property.Name}";
                    AppendSummary(property.Value, path, lines);
                }

                break;

            case System.Text.Json.JsonValueKind.Array:
                lines.Add($"{prefix}: {element.GetArrayLength()} item(s)");
                break;

            case System.Text.Json.JsonValueKind.String:
                lines.Add($"{prefix}: {element.GetString()}");
                break;

            case System.Text.Json.JsonValueKind.Number:
                lines.Add($"{prefix}: {element.GetRawText()}");
                break;

            case System.Text.Json.JsonValueKind.True:
            case System.Text.Json.JsonValueKind.False:
                lines.Add($"{prefix}: {element.GetRawText()}");
                break;

            default:
                lines.Add($"{prefix}: {element.GetRawText()}");
                break;
        }
    }

    private const int SummaryLineCap = 12;

    /// <summary>The mutable state of one diagnostics section.</summary>
    private sealed class SectionState
    {
        public LoadState State { get; set; } = LoadState.Idle;

        public string StatusText { get; set; } = string.Empty;

        public string Raw { get; set; } = string.Empty;
    }
}

/// <summary>The licensing workspace: read-only status plus the explicit external tool.</summary>
/// <remarks>
/// The external tool is kept separate from reversible tweaks, exactly as the terminal
/// interface keeps it: activating writes no journal record, so nothing here can be rolled
/// back, and this view says that before the action rather than after it.
/// </remarks>
public sealed class LicensingViewModel : WorkspaceViewModel
{
    private string _editionText = string.Empty;
    private ActivationMethod? _selectedMethod;
    private ExternalToolStatus? _toolStatus;
    private string _lastOutcome = string.Empty;
    private string _licensingRaw = string.Empty;
    private bool _activationFailed;

    public LicensingViewModel(ShellViewModel shell)
        : base(shell)
    {
        StatusText = Strings["Gui.Overview.NotLoaded"];

        // Command eligibility depends on the connection and the shell's busy flag.
        Shell.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ShellViewModel.Connection) or nameof(ShellViewModel.Busy))
            {
                Raise(nameof(CanRunCommand));
                Raise(nameof(CanActivate));
                Raise(nameof(CanDownload));
                Raise(nameof(CanRemove));
                Raise(nameof(CanRequestSlmgr));
            }
        };

        // Every label below is text from the tables: a language switch re-reads them.
        Shell.Strings.LanguageChanged += (_, _) => RaiseLocalizedText();
    }

    /// <summary>Activation methods offered by the pinned external tool.</summary>
    public ObservableCollection<ActivationMethod> Methods { get; } = new();

    /// <summary>Windows licensing status, as the engine reports it (localized lines).</summary>
    public string LicensingStatus => SummarizeLicensing(_licensingRaw);

    /// <summary>The raw licensing diagnostics document (for the expandable section).</summary>
    public string LicensingRaw => _licensingRaw;

    // ---- three independent facts ----
    //
    // The panel keeps three facts apart, and each one comes from exactly one source:
    //
    //   Windows licensing state     - the read-only licensing read (the badge below);
    //   external-tool readiness     - exttool.status (ToolStatus/ToolStatusText);
    //   advertised duration         - the selected method's own table row (MethodDurationText).
    //
    // Nothing merges them: choosing a "Permanent" method changes the advertised duration and
    // nothing else. Only the licensing read can say Windows is activated.

    /// <summary>Label of the Windows licensing state the badge shows.</summary>
    public string LicenseStateTitle => Strings["Gui.Licensing.State"];

    /// <summary>
    /// The Windows licensing state, as the prominent value. It is derived from the licensing
    /// read alone: an activation attempt's exit code never sets it, and selecting a method
    /// never suggests a duration Windows has not reported.
    /// </summary>
    public string LicenseBadgeText => LicenseVerdict().Text;

    /// <summary>
    /// The badge's tone: <c>ok</c> only for the activated state Windows reported, <c>error</c>
    /// only after an activation attempt actually failed, and <c>warn</c> for everything that is
    /// not confirmed - an unreadable or unverified read, and a confirmed unactivated state.
    /// </summary>
    public string LicenseBadgeTone => LicenseVerdict().Tone;

    /// <summary>Label of the external tool's own section (readiness, never licensing).</summary>
    public string ToolSectionTitle => Strings["Gui.Licensing.ToolSection"];

    /// <summary>Label of the selected method's advertised duration.</summary>
    public string MethodDurationTitle => Strings["Gui.Licensing.MethodDuration"];

    /// <summary>
    /// The selected method's advertised duration, in the engine's own words. It is what the
    /// method claims, not a licence Windows has reported; it is shown beside the method and
    /// never inside the licensing badge.
    /// </summary>
    public string MethodDurationText => _selectedMethod is null
        ? Strings["Gui.Licensing.NoMethod"]
        : MethodDurationModel;

    /// <summary>Installed edition.</summary>
    public string EditionText
    {
        get => _editionText;
        private set => Set(ref _editionText, value);
    }

    /// <summary>Selected activation method (never chosen by the tool itself).</summary>
    public ActivationMethod? SelectedMethod
    {
        get => _selectedMethod;
        set
        {
            if (Set(ref _selectedMethod, value))
            {
                Raise(nameof(MethodDetail));
                Raise(nameof(MethodDurationText));
                Raise(nameof(CanActivate));
            }
        }
    }

    /// <summary>The external tool's readiness.</summary>
    public ExternalToolStatus? ToolStatus
    {
        get => _toolStatus;
        private set
        {
            if (Set(ref _toolStatus, value))
            {
                Raise(nameof(CanActivate));
                Raise(nameof(ToolStatusText));
            }
        }
    }

    /// <summary>The external tool's status, as a localized label plus the reported value.</summary>
    public string ToolStatusText => _toolStatus is { } tool
        ? $"{Strings["Gui.Licensing.Tool"]}: {tool.Status}{(string.IsNullOrEmpty(tool.Path) ? string.Empty : $" ({tool.Path})")}"
        : Strings["Gui.Overview.NotLoaded"];

    /// <summary>Outcome of the last explicit action (the engine's own text).</summary>
    public string LastOutcome
    {
        get => _lastOutcome;
        set => Set(ref _lastOutcome, value);
    }

    /// <summary>Duration model and documented switches of the selected method.</summary>
    public string MethodDetail => _selectedMethod is null
        ? Strings["Gui.Licensing.NoMethod"]
        : string.Join(
            Environment.NewLine,
            new[]
            {
                $"{_selectedMethod.Id}: {_selectedMethod.Switch}",
                _selectedMethod.ExtraSwitches.Count > 0 ? string.Join(" ", _selectedMethod.ExtraSwitches) : string.Empty,
                Strings.Get("Gui.Licensing.Duration", MethodDurationModel),
            }.Where(line => !string.IsNullOrEmpty(line)));

    /// <summary>The selected method's duration model in the engine's own words (raw when unknown).</summary>
    private string MethodDurationModel => _selectedMethod is null
        ? string.Empty
        : Localize("Act.DurationModel." + _selectedMethod.DurationModel, _selectedMethod.DurationModel);

    /// <summary>True when the shell can run a command right now.</summary>
    public bool CanRunCommand => Shell.IsConnected && !Shell.Busy;

    /// <summary>True when the verified tool copy exists and a method is selected.</summary>
    public bool CanActivate => CanRunCommand && _selectedMethod is not null && _toolStatus?.Ready == true;

    /// <summary>True when the tool can be downloaded.</summary>
    public bool CanDownload => CanRunCommand;

    /// <summary>True when the tool copy can be removed.</summary>
    public bool CanRemove => CanRunCommand;

    /// <summary>True when the installed licence can be requested.</summary>
    public bool CanRequestSlmgr => CanRunCommand;

    /// <inheritdoc />
    protected override async Task LoadAsync()
    {
        StatusText = Strings["Gui.Overview.Loading"];

        if (!await RefreshLicensingAsync().ConfigureAwait(true))
        {
            Loaded = true;
            return;
        }

        var ok = await RunAsync(
            "exttool.methods",
            Projections.ExternalToolMethods,
            value =>
            {
                Methods.Clear();
                foreach (var method in value.Methods)
                {
                    Methods.Add(method);
                }

                EditionText = value.Edition;
                SelectedMethod = value.Methods.FirstOrDefault(m => m.Id == value.Selected) ?? Methods.FirstOrDefault();
            },
            timeout: TimeSpan.FromMinutes(2)).ConfigureAwait(true);

        if (!ok)
        {
            Loaded = true;
            return;
        }

        ok = await RunAsync(
            "exttool.status",
            Projections.ExternalToolStatus,
            status => ToolStatus = status,
            timeout: TimeSpan.FromMinutes(2)).ConfigureAwait(true);

        if (!ok)
        {
            Loaded = true;
            return;
        }

        MarkLoaded(Methods.Count);
        StatusText = Strings["Gui.Ready"];
        Loaded = true;
    }

    /// <summary>
    /// Re-reads the Windows licensing state with the engine's read-only diagnostics query and
    /// re-derives the badge from what it says.
    /// </summary>
    /// <remarks>
    /// This is the verification step after an activation attempt, and the same read the panel
    /// loads with. It is the only thing that can put the badge into the activated state: a
    /// tool exit code, a method's advertised duration and the external tool's readiness are
    /// all separate facts and none of them is evidence about the licence.
    /// </remarks>
    private async Task<bool> RefreshLicensingAsync()
    {
        var ok = await RunAsync(
            "licensing.diagnostics",
            element => element.GetRawText(),
            raw =>
            {
                _licensingRaw = raw ?? string.Empty;
                RaiseLicensing();
            },
            timeout: TimeSpan.FromMinutes(2)).ConfigureAwait(true);

        if (ok)
        {
            // The read settles the section: without this the panel would stay "loading" on a
            // section that already has its answer.
            MarkLoaded(Methods.Count);
            StatusText = Strings["Gui.Ready"];
        }

        return ok;
    }

    /// <summary>The licensing read's own verdict on Windows, and the badge it renders as.</summary>
    /// <remarks>
    /// The verdict is read from the engine's status code, never from a localized line, and the
    /// labels fall back to the engine's raw status token rather than to invented text.
    /// </remarks>
    private (string Text, string Tone) LicenseVerdict()
    {
        var (readable, activated, status) = ReadLicense();

        if (activated)
        {
            return (Localize("Gui.Licensing.Activated", status), "ok");
        }

        if (_activationFailed)
        {
            // An actual operation error: the only path to the error tone. It outranks a "not
            // activated" reading because it is what the user has to act on, and it never
            // outranks a verified activation, which is evidence the operation did not produce.
            return (Localize("Gui.Licensing.OperationError", status), "error");
        }

        return readable
            ? (Localize("Gui.Licensing.NotActivated", status), "warn")
            : (Localize("Gui.Licensing.Awaiting", status), "warn");
    }

    /// <summary>
    /// Reads what the licensing document says about Windows itself: whether it could be read
    /// at all, whether it reports the activated state, and the raw status token (used only as
    /// a fallback label when a table lacks a key).
    /// </summary>
    private (bool Readable, bool Activated, string Status) ReadLicense()
    {
        if (string.IsNullOrWhiteSpace(_licensingRaw))
        {
            return (false, false, string.Empty);
        }

        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(_licensingRaw);
            var root = document.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object ||
                !root.TryGetProperty("Inventory", out var inventory) ||
                inventory.ValueKind != System.Text.Json.JsonValueKind.Object ||
                (inventory.TryGetProperty("Unreadable", out var unreadable) && unreadable.ValueKind == System.Text.Json.JsonValueKind.True) ||
                !inventory.TryGetProperty("Active", out var active) ||
                active.ValueKind != System.Text.Json.JsonValueKind.Object)
            {
                return (false, false, string.Empty);
            }

            var status = JString(active, "LicenseStatus");
            var raw = active.TryGetProperty("LicenseStatusRaw", out var code) && code.ValueKind == System.Text.Json.JsonValueKind.Number
                ? code.GetInt32()
                : -1;

            // Code 1 is the activation state; the string is checked too because an older
            // backend may not carry the raw code.
            return (true, raw == 1 || string.Equals(status, "Licensed", StringComparison.Ordinal), status);
        }
        catch (System.Text.Json.JsonException)
        {
            return (false, false, string.Empty);
        }
    }

    /// <summary>Re-publishes everything the licensing read derives.</summary>
    private void RaiseLicensing()
    {
        Raise(nameof(LicensingRaw));
        Raise(nameof(LicensingStatus));
        RaiseBadge();
    }

    /// <summary>Re-publishes the badge alone (its verdict also depends on the last attempt).</summary>
    private void RaiseBadge()
    {
        Raise(nameof(LicenseBadgeText));
        Raise(nameof(LicenseBadgeTone));
    }

    /// <summary>Re-reads every label this workspace renders from the tables.</summary>
    private void RaiseLocalizedText()
    {
        RaiseLicensing();
        Raise(nameof(ToolStatusText));
        Raise(nameof(MethodDetail));
        Raise(nameof(MethodDurationText));
        Raise(nameof(LicenseStateTitle));
        Raise(nameof(ToolSectionTitle));
        Raise(nameof(MethodDurationTitle));
    }

    /// <summary>
    /// Looks a key up in the served tables, falling back to the engine's own token when the
    /// table does not carry it. The fallback is never invented text: it is what the engine sent.
    /// </summary>
    private string Localize(string key, string fallback)
    {
        var text = Strings[key];
        return text.StartsWith("[", StringComparison.Ordinal) && fallback.Length > 0 ? fallback : text;
    }

    /// <summary>Renders the active licensing record as localized label/value lines.</summary>
    private string SummarizeLicensing(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return Strings["Gui.Licensing.Unavailable"];
        }

        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(raw);
            var root = document.RootElement;
            if (root.ValueKind != System.Text.Json.JsonValueKind.Object ||
                !root.TryGetProperty("Inventory", out var inventory) ||
                inventory.ValueKind != System.Text.Json.JsonValueKind.Object ||
                !inventory.TryGetProperty("Active", out var active) ||
                active.ValueKind != System.Text.Json.JsonValueKind.Object)
            {
                return Strings["Gui.Licensing.Unavailable"];
            }

            var lines = new List<string>();

            var product = JString(active, "ProductName");
            if (product.Length > 0)
            {
                lines.Add($"{Strings["Gui.Licensing.Product"]}: {product}");
            }

            var status = JString(active, "LicenseStatus");
            if (status.Length > 0)
            {
                lines.Add($"{Strings["Gui.Status"]}: {status}");
            }

            var channel = JString(active, "LicenseChannel");
            if (channel.Length > 0)
            {
                lines.Add($"{Strings["Gui.Licensing.Channel"]}: {channel}");
            }

            if (active.TryGetProperty("GraceRemaining", out var grace) && grace.ValueKind == System.Text.Json.JsonValueKind.Number)
            {
                lines.Add($"{Strings["Gui.Licensing.Grace"]}: {grace.GetInt32().ToString(CultureInfo.InvariantCulture)}");
            }
            else
            {
                lines.Add($"{Strings["Gui.Licensing.Grace"]}: {Strings["Common.None"]}");
            }

            return lines.Count > 0 ? string.Join(Environment.NewLine, lines) : Strings["Gui.Licensing.Unavailable"];
        }
        catch (System.Text.Json.JsonException)
        {
            return Strings["Gui.Licensing.Unavailable"];
        }
    }

    private static string JString(System.Text.Json.JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == System.Text.Json.JsonValueKind.String
            ? value.GetString() ?? string.Empty
            : string.Empty;

    /// <summary>
    /// Refuses a command at the command layer when the shell cannot run it. Returns true
    /// when the command must stop without touching the backend.
    /// </summary>
    private bool RefuseIfNotEligible()
    {
        if (CanRunCommand)
        {
            return false;
        }

        StatusText = Shell.IsConnected ? Strings["Gui.Error.Busy"] : Shell.ConnectionError;
        LastOutcome = StatusText;
        return true;
    }

    /// <summary>Selects the activation method (persisted by the engine, refused if unknown).</summary>
    public async Task SetMethodAsync(string methodId)
    {
        if (RefuseIfNotEligible())
        {
            return;
        }

        var outcome = await Shell.Runner.RunAsync(
            "exttool.setmethod",
            element => element.ValueKind == System.Text.Json.JsonValueKind.True,
            new Dictionary<string, object?>(StringComparer.Ordinal) { ["method"] = methodId },
            TimeSpan.FromSeconds(30)).ConfigureAwait(true);

        LastOutcome = outcome.Ok && outcome.Value ? methodId : outcome.Message;
    }

    /// <summary>Downloads and verifies the pinned external tool (explicit action).</summary>
    public async Task DownloadToolAsync(bool latest = false)
    {
        if (RefuseIfNotEligible())
        {
            return;
        }

        ErrorText = string.Empty;
        await Shell.RunMutatingAsync(async () =>
        {
            var outcome = await Shell.Runner.RunAsync(
                "exttool.download",
                element => element.GetRawText(),
                new Dictionary<string, object?>(StringComparer.Ordinal) { ["latest"] = latest },
                TimeSpan.FromMinutes(10)).ConfigureAwait(true);

            LastOutcome = (outcome.Ok ? outcome.Value : outcome.Message) ?? outcome.Message;
            if (!outcome.Ok)
            {
                ErrorText = outcome.Message;
            }

            return true;
        }).ConfigureAwait(true);

        await RunAsync("exttool.status", Projections.ExternalToolStatus, status => ToolStatus = status, timeout: TimeSpan.FromMinutes(2)).ConfigureAwait(true);
    }

    /// <summary>Removes the downloaded tool copy (files only; no licensing state changes).</summary>
    public async Task RemoveToolAsync()
    {
        if (RefuseIfNotEligible())
        {
            return;
        }

        await Shell.RunMutatingAsync(async () =>
        {
            var outcome = await Shell.Runner.RunAsync("exttool.remove", element => element.GetRawText(), timeout: TimeSpan.FromMinutes(2)).ConfigureAwait(true);
            LastOutcome = (outcome.Ok ? outcome.Value : outcome.Message) ?? outcome.Message;
            return true;
        }).ConfigureAwait(true);

        await RunAsync("exttool.status", Projections.ExternalToolStatus, status => ToolStatus = status, timeout: TimeSpan.FromMinutes(2)).ConfigureAwait(true);
    }

    /// <summary>
    /// Runs the selected activation method. The engine re-resolves the method id through
    /// its closed table, so an id this view invented could never reach a command line.
    /// </summary>
    public async Task ActivateAsync()
    {
        if (RefuseIfNotEligible())
        {
            return;
        }

        if (_selectedMethod is null)
        {
            StatusText = Strings["Gui.Licensing.NoMethod"];
            LastOutcome = StatusText;
            return;
        }

        // One attempt, one verdict: the previous attempt's error no longer describes this one.
        _activationFailed = false;
        RaiseBadge();

        await Shell.RunMutatingAsync(async () =>
        {
            var outcome = await Shell.Runner.RunAsync(
                "exttool.activate",
                element => element.GetRawText(),
                new Dictionary<string, object?>(StringComparer.Ordinal) { ["method"] = _selectedMethod.Id },
                TimeSpan.FromMinutes(40)).ConfigureAwait(true);

            LastOutcome = (outcome.Ok ? outcome.Value : outcome.Message) ?? outcome.Message;
            if (!outcome.Ok)
            {
                ErrorText = outcome.Message;
                _activationFailed = true;
            }

            return true;
        }).ConfigureAwait(true);

        // The result of the run is not the licensing state: the read-only diagnostics query
        // decides, and the badge follows it.
        StatusText = Strings["Gui.Licensing.Checking"];
        await RefreshLicensingAsync().ConfigureAwait(true);

        // A verification read that failed leaves the badge on the attempt's own verdict rather
        // than on the one from before the run.
        RaiseBadge();
    }

    /// <summary>Requests activation with the installed licence (slmgr /ato). Privileged.</summary>
    public async Task RequestSlmgrAsync()
    {
        if (RefuseIfNotEligible())
        {
            return;
        }

        // One attempt, one verdict: the previous attempt's error no longer describes this one.
        _activationFailed = false;
        RaiseBadge();

        await Shell.RunMutatingAsync(async () =>
        {
            var outcome = await Shell.Runner.RunAsync("slmgr.request", element => element.GetRawText(), timeout: TimeSpan.FromMinutes(10)).ConfigureAwait(true);
            LastOutcome = (outcome.Ok ? outcome.Value : outcome.Message) ?? outcome.Message;
            if (!outcome.Ok)
            {
                ErrorText = outcome.Code == "RequiresElevation" ? Strings["Gui.Error.RequiresElevation"] : outcome.Message;
                _activationFailed = true;
            }

            return true;
        }).ConfigureAwait(true);

        // The accepted request is not the licensing state: the read-only diagnostics query
        // decides, and the badge follows it.
        StatusText = Strings["Gui.Licensing.Checking"];
        await RefreshLicensingAsync().ConfigureAwait(true);

        // A verification read that failed leaves the badge on the attempt's own verdict rather
        // than on the one from before the request.
        RaiseBadge();
    }
}
