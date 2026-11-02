using System.Collections.ObjectModel;
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
    private HistoryRow? _selectedRow;
    private InterruptedOperation? _selectedInterrupted;

    public HistoryViewModel(ShellViewModel shell)
        : base(shell)
    {
    }

    /// <summary>Completed (and failed) history rows, newest first.</summary>
    public ObservableCollection<HistoryRow> Rows { get; } = new();

    /// <summary>Journal operation rows, newest first.</summary>
    public ObservableCollection<OperationRow> Operations { get; } = new();

    /// <summary>Operations that started and never finished.</summary>
    public ObservableCollection<InterruptedOperation> Interrupted { get; } = new();

    /// <summary>Target comparison for the selected interrupted operation.</summary>
    public ObservableCollection<InterruptedTarget> InterruptedTargets { get; } = new();

    /// <summary>When set, the journal view is shown instead of the history view.</summary>
    public bool ShowOperations
    {
        get => _showOperations;
        set => Set(ref _showOperations, value);
    }

    /// <summary>Selected history row.</summary>
    public HistoryRow? SelectedRow
    {
        get => _selectedRow;
        set
        {
            if (Set(ref _selectedRow, value))
            {
                Raise(nameof(CanRestore));
                Raise(nameof(SelectedSummary));
            }
        }
    }

    /// <summary>Selected interrupted operation.</summary>
    public InterruptedOperation? SelectedInterrupted
    {
        get => _selectedInterrupted;
        set
        {
            if (Set(ref _selectedInterrupted, value))
            {
                Raise(nameof(CanRestore));
                Raise(nameof(SelectedSummary));
                _ = LoadInterruptedTargetsAsync();
            }
        }
    }

    /// <summary>True when the selection can be restored.</summary>
    public bool CanRestore =>
        _selectedRow is { RolledBack: false, Irreversible: false } ||
        _selectedInterrupted is { CanRestore: true };

    /// <summary>Short description of the selection.</summary>
    public string SelectedSummary
    {
        get
        {
            if (_selectedRow is not null)
            {
                return $"{_selectedRow.TweakId} -> {_selectedRow.State} ({_selectedRow.Outcome})";
            }

            if (_selectedInterrupted is not null)
            {
                return $"{_selectedInterrupted.TweakId} - {_selectedInterrupted.Stage}";
            }

            return string.Empty;
        }
    }

    /// <inheritdoc />
    protected override async Task LoadAsync()
    {
        await RunAsync("history.list", Projections.History, rows =>
        {
            Rows.Clear();
            foreach (var row in rows)
            {
                Rows.Add(row);
            }
        }, new Dictionary<string, object?>(StringComparer.Ordinal) { ["limit"] = 200 }).ConfigureAwait(true);

        await RunAsync("journal.operation", Projections.Operations, rows =>
        {
            Operations.Clear();
            foreach (var row in rows)
            {
                Operations.Add(row);
            }
        }, new Dictionary<string, object?>(StringComparer.Ordinal) { ["limit"] = 200 }).ConfigureAwait(true);

        await RunAsync("history.interrupted", Projections.Interrupted, rows =>
        {
            Interrupted.Clear();
            foreach (var row in rows)
            {
                Interrupted.Add(row);
            }
        }).ConfigureAwait(true);

        Loaded = true;
    }

    private async Task LoadInterruptedTargetsAsync()
    {
        InterruptedTargets.Clear();
        if (_selectedInterrupted is null)
        {
            return;
        }

        foreach (var target in _selectedInterrupted.Targets)
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
                var match = rows.FirstOrDefault(r => r.OperationId == _selectedInterrupted.OperationId);
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
        var id = _selectedRow?.TweakId ?? _selectedInterrupted?.TweakId;
        var historyId = _selectedRow?.OperationId ?? _selectedInterrupted?.OperationId ?? string.Empty;
        if (string.IsNullOrEmpty(historyId))
        {
            StatusText = Strings["Gui.Error.NoSelection"];
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
}

/// <summary>The diagnostics workspace: read-only reporting and monitoring.</summary>
/// <remarks>
/// Everything here is read-only by construction. The only actions that touch a file are
/// the explicit exports, and they are performed by the engine, not by this view.
/// </remarks>
public sealed class DiagnosticsViewModel : WorkspaceViewModel
{
    private RuntimeStatus? _runtime;
    private string _reportText = string.Empty;
    private string _scanPath = string.Empty;
    private string _scanResult = string.Empty;
    private string _monitorResult = string.Empty;
    private string _deviceResult = string.Empty;
    private string _powerResult = string.Empty;
    private string _privacyResult = string.Empty;
    private string _quarantineResult = string.Empty;
    private string _setupResult = string.Empty;
    private readonly ObservableCollection<string> _diagnostics = new();

    public DiagnosticsViewModel(ShellViewModel shell)
        : base(shell)
    {
    }

    /// <summary>Runtime profile and capability table (read-only).</summary>
    public RuntimeStatus? Runtime
    {
        get => _runtime;
        private set => Set(ref _runtime, value);
    }

    /// <summary>The generated diagnostics report, as JSON text.</summary>
    public string ReportText
    {
        get => _reportText;
        private set => Set(ref _reportText, value);
    }

    /// <summary>Directory to scan.</summary>
    public string ScanPath
    {
        get => _scanPath;
        set => Set(ref _scanPath, value);
    }

    /// <summary>Directory scan result.</summary>
    public string ScanResult
    {
        get => _scanResult;
        private set => Set(ref _scanResult, value);
    }

    /// <summary>Monitoring cycle result.</summary>
    public string MonitorResult
    {
        get => _monitorResult;
        private set => Set(ref _monitorResult, value);
    }

    /// <summary>Device inventory summary.</summary>
    public string DeviceResult
    {
        get => _deviceResult;
        private set => Set(ref _deviceResult, value);
    }

    /// <summary>Power settings summary.</summary>
    public string PowerResult
    {
        get => _powerResult;
        private set => Set(ref _powerResult, value);
    }

    /// <summary>Privacy activity summary.</summary>
    public string PrivacyResult
    {
        get => _privacyResult;
        private set => Set(ref _privacyResult, value);
    }

    /// <summary>Quarantine summary.</summary>
    public string QuarantineResult
    {
        get => _quarantineResult;
        private set => Set(ref _quarantineResult, value);
    }

    /// <summary>Setup plan summary.</summary>
    public string SetupResult
    {
        get => _setupResult;
        private set => Set(ref _setupResult, value);
    }

    /// <summary>Bounded tail of backend diagnostics (never unbounded, never on the UI thread).</summary>
    public ObservableCollection<string> Diagnostics => _diagnostics;

    /// <summary>"diagnostics: N" (bounded tail count).</summary>
    public string CountText => $"diagnostics: {_diagnostics.Count}";

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
        });
    }

    /// <inheritdoc />
    protected override async Task LoadAsync()
    {
        Runtime = Shell.Runtime;

        await RunAsync(
            "diagnostics.report",
            element => element.GetRawText(),
            text => ReportText = text,
            timeout: TimeSpan.FromMinutes(3),
            statusWhileRunning: Strings["Gui.Diagnostics.Report"]).ConfigureAwait(true);

        Loaded = true;
    }

    /// <summary>Runs the read-only directory scan.</summary>
    public async Task ScanAsync()
    {
        if (string.IsNullOrWhiteSpace(_scanPath))
        {
            ErrorText = Strings["Worker.Reason.RootInvalid"];
            return;
        }

        await RunAsync(
            "scan.directory",
            element => element.GetRawText(),
            text => ScanResult = text,
            new Dictionary<string, object?>(StringComparer.Ordinal) { ["path"] = _scanPath },
            TimeSpan.FromMinutes(10),
            statusWhileRunning: Strings.Get("Disk.Scanning", _scanPath)).ConfigureAwait(true);
    }

    /// <summary>Runs one read-only monitoring cycle.</summary>
    public Task MonitorAsync() => RunAsync(
        "monitor.cycle",
        element => element.GetRawText(),
        text => MonitorResult = text,
        timeout: TimeSpan.FromMinutes(10),
        statusWhileRunning: Strings["Gui.Diagnostics.Monitor"]);

    /// <summary>Reads the device inventory.</summary>
    public Task DevicesAsync() => RunAsync(
        "inventory.devices",
        element => element.GetRawText(),
        text => DeviceResult = ReportAvailability(element: text),
        timeout: TimeSpan.FromMinutes(3));

    /// <summary>Reads the power settings.</summary>
    public Task PowerAsync() => RunAsync(
        "power.settings",
        element => element.GetRawText(),
        text => PowerResult = ReportAvailability(element: text),
        timeout: TimeSpan.FromMinutes(3));

    /// <summary>Reads the privacy activity view.</summary>
    public Task PrivacyAsync() => RunAsync(
        "privacy.activity",
        element => element.GetRawText(),
        text => PrivacyResult = ReportAvailability(element: text),
        timeout: TimeSpan.FromMinutes(3));

    /// <summary>Reads the quarantine summary.</summary>
    public Task QuarantineAsync() => RunAsync(
        "quarantine.summary",
        element => element.GetRawText(),
        text => QuarantineResult = text,
        timeout: TimeSpan.FromMinutes(3));

    /// <summary>Lists setup plans.</summary>
    public Task SetupAsync() => RunAsync(
        "setup.list",
        element => element.GetRawText(),
        text => SetupResult = text,
        timeout: TimeSpan.FromMinutes(3));

    /// <summary>When the host cannot answer (not Windows), says so instead of showing `{}`.</summary>
    private string ReportAvailability(string element) =>
        element is "{}" or "[]" or "" ? Strings["Gui.Diagnostics.Unavailable"] : element;
}

/// <summary>The licensing workspace: read-only status plus the explicit external tool.</summary>
/// <remarks>
/// The external tool is kept separate from reversible tweaks, exactly as the terminal
/// interface keeps it: activating writes no journal record, so nothing here can be rolled
/// back, and this view says that before the action rather than after it.
/// </remarks>
public sealed class LicensingViewModel : WorkspaceViewModel
{
    private string _statusText = string.Empty;
    private string _editionText = string.Empty;
    private ActivationMethod? _selectedMethod;
    private ExternalToolStatus? _toolStatus;
    private string _lastOutcome = string.Empty;

    public LicensingViewModel(ShellViewModel shell)
        : base(shell)
    {
    }

    /// <summary>Activation methods offered by the pinned external tool.</summary>
    public ObservableCollection<ActivationMethod> Methods { get; } = new();

    /// <summary>Windows licensing status, as the engine reports it.</summary>
    public string LicensingStatus
    {
        get => _statusText;
        private set => Set(ref _statusText, value);
    }

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
            }
        }
    }

    /// <summary>Outcome of the last explicit action.</summary>
    public string LastOutcome
    {
        get => _lastOutcome;
        private set => Set(ref _lastOutcome, value);
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
                Strings.Get("Gui.Licensing.Duration", _selectedMethod.DurationModel),
            }.Where(line => !string.IsNullOrEmpty(line)));

    /// <summary>True when the verified tool copy exists and a method is selected.</summary>
    public bool CanActivate => _selectedMethod is not null && _toolStatus?.Ready == true;

    /// <inheritdoc />
    protected override async Task LoadAsync()
    {
        var licensing = await Shell.Runner.RunAsync("licensing.diagnostics", e => e.GetRawText(), timeout: TimeSpan.FromMinutes(2)).ConfigureAwait(true);
        LicensingStatus = licensing.Ok ? SummarizeLicensing(licensing.Value ?? string.Empty) : licensing.Message;

        await RunAsync(
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

        await RunAsync("exttool.status", Projections.ExternalToolStatus, status => ToolStatus = status, timeout: TimeSpan.FromMinutes(2)).ConfigureAwait(true);

        Loaded = true;
    }

    private static string SummarizeLicensing(string raw)
    {
        // The diagnostics object is a large nested document; the view shows a compact form
        // rather than re-implementing the engine's own rendering.
        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(raw);
            var root = document.RootElement;
            var active = root.TryGetProperty("Active", out var activeElement) ? activeElement : default;
            if (active.ValueKind == System.Text.Json.JsonValueKind.Object)
            {
                var name = active.TryGetProperty("Name", out var nameElement) ? nameElement.ToString() : string.Empty;
                var status = active.TryGetProperty("Status", out var statusElement) ? statusElement.ToString() : string.Empty;
                var code = active.TryGetProperty("StatusCode", out var codeElement) ? codeElement.ToString() : string.Empty;
                return $"{name} | {status} ({code})";
            }
        }
        catch (System.Text.Json.JsonException)
        {
            // Fall through to the raw text.
        }

        return raw.Length > 400 ? raw[..400] : raw;
    }

    /// <summary>Selects the activation method (persisted by the engine, refused if unknown).</summary>
    public async Task SetMethodAsync(string methodId)
    {
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
        if (_selectedMethod is null)
        {
            ErrorText = Strings["Gui.Licensing.NoMethod"];
            return;
        }

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
            }

            return true;
        }).ConfigureAwait(true);

        await RunAsync("licensing.diagnostics", e => e.GetRawText(), raw => LicensingStatus = SummarizeLicensing(raw ?? string.Empty), timeout: TimeSpan.FromMinutes(2)).ConfigureAwait(true);
    }

    /// <summary>Requests activation with the installed licence (slmgr /ato). Privileged.</summary>
    public async Task RequestSlmgrAsync()
    {
        await Shell.RunMutatingAsync(async () =>
        {
            var outcome = await Shell.Runner.RunAsync("slmgr.request", element => element.GetRawText(), timeout: TimeSpan.FromMinutes(10)).ConfigureAwait(true);
            LastOutcome = (outcome.Ok ? outcome.Value : outcome.Message) ?? outcome.Message;
            if (!outcome.Ok)
            {
                ErrorText = outcome.Code == "RequiresElevation" ? Strings["Gui.Error.RequiresElevation"] : outcome.Message;
            }

            return true;
        }).ConfigureAwait(true);
    }
}
