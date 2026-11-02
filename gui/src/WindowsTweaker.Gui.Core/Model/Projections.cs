using System.Text.Json;

namespace WindowsTweaker.Gui.Core.Model;

/// <summary>
/// Turns protocol payloads into typed models.
/// </summary>
/// <remarks>
/// Every read is defensive: a field the backend does not send yields a default rather
/// than an exception, so a newer backend that adds fields (or an older one that lacks
/// them) still renders. The models are the only place JSON shape knowledge lives; no view
/// model touches a <see cref="JsonElement"/>.
/// </remarks>
public static class Projections
{
    /// <summary>Projects <c>env.status</c>.</summary>
    public static (EnvironmentStatus Environment, RuntimeStatus Runtime) Environment(JsonElement data)
    {
        var env = Field(data, "environment");
        var runtime = Field(data, "runtime");

        var capabilities = new Dictionary<string, bool>(StringComparer.Ordinal);
        var capabilityElement = Field(env, "Capabilities");
        if (capabilityElement.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in capabilityElement.EnumerateObject())
            {
                capabilities[property.Name] = property.Value.ValueKind == JsonValueKind.True;
            }
        }

        var environment = new EnvironmentStatus(
            PowerShellVersion: Text(Field(env, "PowerShell"), "Major") is { } major
                ? $"{major}.{Text(Field(env, "PowerShell"), "Minor")}.{Text(Field(env, "PowerShell"), "Patch")}"
                : string.Empty,
            RequiredPowerShell: "5.1",
            IsWindows: Bool(env, "IsWindows"),
            IsAdmin: Bool(env, "IsAdmin"),
            OsName: String(env, "OSName"),
            OsBuild: String(env, "OSBuild"),
            OsVersionKey: String(env, "OSVersionKey"),
            Architecture: String(env, "Architecture"),
            LanguageMode: String(env, "LanguageMode"),
            Culture: String(env, "Culture"),
            Language: String(env, "Language"),
            LogPath: FirstOf(StringOrArray(env, "LogPath")),
            StatePath: String(env, "StatePath"),
            PendingReboot: NullableBool(env, "PendingReboot"),
            PendingRebootLabel: String(env, "PendingRebootLabel"),
            Capabilities: capabilities);

        var capabilityList = new List<RuntimeCapability>();
        var capabilityArray = Field(runtime, "Capabilities");
        if (capabilityArray.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in capabilityArray.EnumerateArray())
            {
                capabilityList.Add(new RuntimeCapability(
                    String(item, "Name"),
                    Bool(item, "Supported"),
                    String(item, "Reason")));
            }
        }

        var profile = Field(runtime, "Profile");
        var status = new RuntimeStatus(
            Edition: String(profile, "PSEdition"),
            Version: Version3(profile),
            Platform: String(profile, "Platform"),
            Architecture: String(profile, "Architecture"),
            Tier: String(profile, "Tier"),
            IsWindows: Bool(profile, "IsWindows"),
            Validated: Bool(runtime, "Validated"),
            Notice: String(runtime, "Notice"),
            Capabilities: capabilityList);

        return (environment, status);
    }

    private static string Version3(JsonElement profile)
    {
        var version = Field(profile, "Version");
        return version.ValueKind == JsonValueKind.Object
            ? $"{Number(version, "Major")}.{Number(version, "Minor")}.{Number(version, "Patch")}"
            : string.Empty;
    }

    /// <summary>Projects <c>catalog.list</c>.</summary>
    public static (IReadOnlyList<string> Categories, IReadOnlyList<CatalogTweak> Tweaks) Catalog(JsonElement data)
    {
        var categories = new List<string>();
        var categoryArray = Field(data, "categories");
        if (categoryArray.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in categoryArray.EnumerateArray())
            {
                if (item.ValueKind == JsonValueKind.String && item.GetString() is { Length: > 0 } text)
                {
                    categories.Add(text);
                }
            }
        }

        var tweaks = new List<CatalogTweak>();
        var array = Field(data, "tweaks");
        if (array.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in array.EnumerateArray())
            {
                tweaks.Add(new CatalogTweak(
                    Id: String(item, "Id"),
                    Category: String(item, "Category"),
                    DisplayName: string.IsNullOrEmpty(String(item, "DisplayName")) ? String(item, "Id") : String(item, "DisplayName"),
                    Lifecycle: String(item, "Lifecycle"),
                    Scope: String(item, "Scope"),
                    Privilege: String(item, "Privilege"),
                    Risk: String(item, "Risk"),
                    Restart: String(item, "Restart"),
                    Rollback: String(item, "Rollback"),
                    States: StringArray(item, "States"),
                    DefaultState: String(item, "DefaultState"),
                    Source: String(item, "Source"),
                    PackId: String(item, "PackId"),
                    Support: String(item, "Support"),
                    Tags: StringArray(item, "Tags")));
            }
        }

        return (categories, tweaks);
    }

    /// <summary>Projects <c>state.get</c> / <c>state.refresh</c>.</summary>
    public static IReadOnlyList<TweakState> TweakStates(JsonElement data)
    {
        var rows = new List<TweakState>();
        if (data.ValueKind != JsonValueKind.Array)
        {
            return rows;
        }

        foreach (var item in data.EnumerateArray())
        {
            rows.Add(new TweakState(
                Id: String(item, "Id"),
                Category: String(item, "Category"),
                Name: String(item, "Name"),
                Description: String(item, "Description"),
                Impact: String(item, "Impact"),
                Risk: String(item, "Risk"),
                Scope: String(item, "Scope"),
                Privilege: String(item, "Privilege"),
                Restart: String(item, "Restart"),
                Rollback: String(item, "Rollback"),
                Irreversible: Bool(item, "Irreversible"),
                DataDeletion: Bool(item, "DataDeletion"),
                ReducesProtection: Bool(item, "ReducesProtection"),
                StateNames: StringArray(item, "StateNames"),
                DefaultState: String(item, "DefaultState"),
                Requires: StringArray(item, "Requires"),
                State: String(item, "State"),
                Details: String(item, "Details"),
                Supported: Bool(item, "Supported"),
                UnsupportedReason: String(item, "UnsupportedReason"),
                Lifecycle: String(item, "Lifecycle"),
                Managed: Bool(item, "Managed"),
                ManagedBy: StringArray(item, "ManagedBy"),
                Note: String(item, "Note")));
        }

        return rows;
    }

    /// <summary>Projects <c>preview.get</c>.</summary>
    public static ChangePreview Preview(JsonElement data)
    {
        var targets = new List<PreviewTarget>();
        var targetArray = Field(data, "Targets");
        if (targetArray.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in targetArray.EnumerateArray())
            {
                var current = Field(item, "Current");
                var intended = Field(item, "Intended");
                var recovery = Field(item, "Recovery");
                targets.Add(new PreviewTarget(
                    Identity: String(item, "Identity"),
                    Label: String(item, "Label"),
                    TargetClass: String(item, "Class"),
                    Operation: String(item, "Operation"),
                    CurrentDisplay: String(current, "Display"),
                    CurrentKind: String(current, "ValueKind"),
                    CurrentReason: String(current, "Reason"),
                    IntendedDisplay: String(intended, "Display"),
                    IntendedType: String(intended, "Type"),
                    Rollback: String(recovery, "Rollback"),
                    Irreversible: Bool(recovery, "Irreversible"),
                    BaselinePreserved: Bool(recovery, "BaselinePreserved")));
            }
        }

        var recoveryBlock = Field(data, "Recovery");
        bool? complete = Field(data, "Complete") is { ValueKind: JsonValueKind.True } ? true
            : Field(data, "Complete") is { ValueKind: JsonValueKind.False } ? false
            : null;

        return new ChangePreview(
            TweakId: String(data, "TweakId"),
            State: String(data, "State"),
            Supported: Bool(data, "Supported"),
            SupportReason: String(Field(data, "Support"), "Reason"),
            Scope: String(data, "Scope"),
            Privilege: String(data, "Privilege"),
            Restart: String(data, "Restart"),
            Irreversible: Bool(data, "Irreversible"),
            Lifecycle: String(data, "Lifecycle"),
            Complete: complete,
            DetectedState: String(data, "DetectedState"),
            Fingerprint: String(data, "Fingerprint"),
            ReviewedUtc: String(data, "ReviewedUtc"),
            RecoveryRollback: String(recoveryBlock, "Rollback"),
            Messages: StringArray(data, "Messages"),
            Targets: targets);
    }

    /// <summary>Projects <c>apply.batch</c>.</summary>
    public static BatchResult Batch(JsonElement data)
    {
        var results = new List<ApplyResult>();
        var array = Field(data, "results");
        if (array.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in array.EnumerateArray())
            {
                results.Add(new ApplyResult(
                    RequestedId: String(item, "RequestedId"),
                    RequestedState: String(item, "RequestedState"),
                    TweakId: String(item, "TweakId"),
                    Status: String(item, "Status"),
                    Outcome: String(item, "Outcome"),
                    Messages: StringArray(item, "Messages"),
                    Verified: Bool(item, "Verified"),
                    VerifiedCount: Number(item, "VerifiedCount"),
                    Mismatched: Number(item, "Mismatched"),
                    Compensated: Bool(item, "Compensated"),
                    JournalPersisted: Bool(item, "JournalPersisted"),
                    JournalStopBatch: Bool(item, "JournalStopBatch"),
                    JournalUncertainStage: String(item, "JournalUncertainStage")));
            }
        }

        return new BatchResult(results, Bool(data, "cancelled"));
    }

    /// <summary>Projects <c>history.list</c>.</summary>
    public static IReadOnlyList<HistoryRow> History(JsonElement data)
    {
        var rows = new List<HistoryRow>();
        if (data.ValueKind != JsonValueKind.Array)
        {
            return rows;
        }

        foreach (var item in data.EnumerateArray())
        {
            rows.Add(new HistoryRow(
                OperationId: String(item, "OperationId"),
                TweakId: String(item, "TweakId"),
                State: String(item, "State"),
                Outcome: String(item, "Outcome"),
                Timestamp: String(item, "Timestamp"),
                RolledBack: Bool(item, "RolledBack"),
                RolledBackAt: NullableText(item, "RolledBackAt"),
                RecordCount: Number(item, "RecordCount"),
                Irreversible: Bool(item, "Irreversible"),
                Messages: StringArray(item, "Messages")));
        }

        return rows;
    }

    /// <summary>Projects <c>journal.operation</c>.</summary>
    public static IReadOnlyList<OperationRow> Operations(JsonElement data)
    {
        var rows = new List<OperationRow>();
        if (data.ValueKind != JsonValueKind.Array)
        {
            return rows;
        }

        foreach (var item in data.EnumerateArray())
        {
            rows.Add(new OperationRow(
                OperationId: String(item, "OperationId"),
                SessionId: String(item, "SessionId"),
                Sequence: Number(item, "Sequence"),
                Origin: String(item, "Origin"),
                Stage: String(item, "Stage"),
                TweakId: String(item, "TweakId"),
                State: String(item, "State"),
                Timestamp: String(item, "Timestamp"),
                UpdatedUtc: String(item, "UpdatedUtc"),
                DryRun: Bool(item, "DryRun"),
                Outcome: String(item, "Outcome"),
                RolledBack: Bool(item, "RolledBack"),
                TargetCount: Number(item, "TargetCount"),
                Messages: StringArray(item, "Messages"),
                Verified: Bool(item, "Verified"),
                Mismatched: Number(item, "Mismatched"),
                Unverifiable: Number(item, "Unverifiable"),
                Compensated: Bool(item, "Compensated")));
        }

        return rows;
    }

    /// <summary>Projects <c>history.interrupted</c>.</summary>
    public static IReadOnlyList<InterruptedOperation> Interrupted(JsonElement data)
    {
        var rows = new List<InterruptedOperation>();
        if (data.ValueKind != JsonValueKind.Array)
        {
            return rows;
        }

        foreach (var item in data.EnumerateArray())
        {
            var targets = new List<InterruptedTarget>();
            var array = Field(item, "Targets");
            if (array.ValueKind == JsonValueKind.Array)
            {
                foreach (var target in array.EnumerateArray())
                {
                    targets.Add(new InterruptedTarget(
                        String(target, "Identity"),
                        String(target, "Label"),
                        String(target, "Intended"),
                        String(target, "Live"),
                        String(target, "Classification")));
                }
            }

            rows.Add(new InterruptedOperation(
                OperationId: String(item, "OperationId"),
                SessionId: String(item, "SessionId"),
                TweakId: String(item, "TweakId"),
                State: String(item, "State"),
                Stage: String(item, "Stage"),
                Timestamp: String(item, "Timestamp"),
                CanRestore: Bool(item, "CanRestore"),
                Targets: targets));
        }

        return rows;
    }

    /// <summary>Projects <c>rollback</c>.</summary>
    public static UndoResult Undo(JsonElement data) => new(
        Status: String(data, "Status"),
        TweakId: String(data, "TweakId"),
        HistoryId: String(data, "HistoryId"),
        Messages: StringArray(data, "Messages"),
        ReviewRequired: Bool(data, "ReviewRequired"),
        ExternalChanges: StringArray(data, "ExternalChanges"),
        JournalPersisted: Bool(data, "JournalPersisted"),
        JournalStopBatch: Bool(data, "JournalStopBatch"));

    /// <summary>Projects <c>preset.list</c> / <c>preset.load</c>.</summary>
    public static IReadOnlyList<PresetInfo> Presets(JsonElement data)
    {
        var rows = new List<PresetInfo>();
        if (data.ValueKind != JsonValueKind.Array)
        {
            return rows;
        }

        foreach (var item in data.EnumerateArray())
        {
            rows.Add(new PresetInfo(
                String(item, "Name"),
                String(item, "Description"),
                String(item, "Source"),
                String(item, "Path"),
                Field(item, "Entries") is { ValueKind: JsonValueKind.Array } entries ? entries.GetArrayLength() : 0));
        }

        return rows;
    }

    /// <summary>Projects <c>exttool.methods</c>.</summary>
    public static (IReadOnlyList<ActivationMethod> Methods, string Selected, string Edition) ExternalToolMethods(JsonElement data)
    {
        var methods = new List<ActivationMethod>();
        var array = Field(data, "methods");
        if (array.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in array.EnumerateArray())
            {
                methods.Add(new ActivationMethod(
                    Id: String(item, "Id"),
                    Switch: String(item, "Switch"),
                    ExtraSwitches: StringArray(item, "ExtraSwitches"),
                    DurationModel: String(item, "DurationModel"),
                    EditionScope: String(item, "EditionScope"),
                    Internet: String(item, "Internet"),
                    MinBuild: Number(item, "MinBuild"),
                    Evidence: String(item, "Evidence")));
            }
        }

        var selected = Field(data, "selected") is { ValueKind: JsonValueKind.Object } selectedObject
            ? String(selectedObject, "Id")
            : string.Empty;
        var edition = Field(data, "edition") is { ValueKind: JsonValueKind.Object } editionObject
            ? String(editionObject, "Name")
            : string.Empty;

        return (methods, selected, edition);
    }

    /// <summary>Projects <c>exttool.status</c>.</summary>
    public static ExternalToolStatus ExternalToolStatus(JsonElement data) => new(
        Status: String(data, "Status"),
        Code: String(data, "Code"),
        Reason: String(data, "Reason"),
        Ready: Bool(data, "Ready"),
        Installed: Bool(data, "Installed"),
        Path: String(data, "Path"));

    /// <summary>Projects <c>monitor.defaults</c>.</summary>
    public static MonitorDefaults MonitorDefaults(JsonElement data) => new(
        FastSeconds: Number(data, "FastSeconds"),
        SlowSeconds: Number(data, "SlowSeconds"),
        QueueCap: Number(data, "QueueCap"),
        ProviderTimeoutMs: Number(data, "ProviderTimeoutMs"));

    /// <summary>Projects <c>dashboard.list</c>.</summary>
    public static IReadOnlyList<DashboardInfo> Dashboards(JsonElement data)
    {
        var rows = new List<DashboardInfo>();
        if (data.ValueKind != JsonValueKind.Array)
        {
            return rows;
        }

        foreach (var item in data.EnumerateArray())
        {
            rows.Add(new DashboardInfo(String(item, "id")));
        }

        return rows;
    }

    /// <summary>Projects <c>restart.test</c>.</summary>
    public static RestartDecision Restart(JsonElement data) => new(
        Allowed: Bool(data, "Allowed"),
        Reason: String(data, "Reason"),
        Available: Bool(data, "Available"),
        Mechanism: String(data, "Mechanism"));

    /// <summary>Projects <c>strings.get</c> into per-language tables.</summary>
    public static (IReadOnlyList<string> Languages, string Active, IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Tables) Strings(JsonElement data)
    {
        var languages = StringArray(data, "languages");
        var active = String(data, "active");
        var tables = new Dictionary<string, IReadOnlyDictionary<string, string>>(StringComparer.OrdinalIgnoreCase);

        var tableElement = Field(data, "tables");
        if (tableElement.ValueKind == JsonValueKind.Object)
        {
            foreach (var language in tableElement.EnumerateObject())
            {
                var entries = new Dictionary<string, string>(StringComparer.Ordinal);
                if (language.Value.ValueKind == JsonValueKind.Object)
                {
                    foreach (var entry in language.Value.EnumerateObject())
                    {
                        entries[entry.Name] = entry.Value.ValueKind == JsonValueKind.String
                            ? entry.Value.GetString() ?? string.Empty
                            : entry.Value.ToString();
                    }
                }

                tables[language.Name] = entries;
            }
        }

        return (languages, active, tables);
    }

    // ---- element helpers ----

    private static JsonElement Field(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) ? value : default;

    private static string String(JsonElement element, string name)
    {
        var value = Field(element, name);
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString() ?? string.Empty,
            JsonValueKind.Number => value.ToString(),
            JsonValueKind.True => bool.TrueString,
            JsonValueKind.False => bool.FalseString,
            _ => string.Empty,
        };
    }

    private static string? NullableText(JsonElement element, string name)
    {
        var value = Field(element, name);
        return value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    }

    private static bool Bool(JsonElement element, string name)
    {
        var value = Field(element, name);
        return value.ValueKind == JsonValueKind.True;
    }

    private static bool? NullableBool(JsonElement element, string name)
    {
        var value = Field(element, name);
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }

    private static int Number(JsonElement element, string name)
    {
        var value = Field(element, name);
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : 0;
    }

    private static string? Text(JsonElement element, string name) =>
        Field(element, name) is { ValueKind: JsonValueKind.Number } value ? value.ToString() : null;

    private static IReadOnlyList<string> StringArray(JsonElement element, string name)
    {
        var value = Field(element, name);
        if (value.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<string>();
        }

        var list = new List<string>();
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String && item.GetString() is { Length: > 0 } text)
            {
                list.Add(text);
            }
        }

        return list;
    }

    private static IReadOnlyList<string> StringOrArray(JsonElement element, string name)
    {
        var value = Field(element, name);
        if (value.ValueKind == JsonValueKind.String)
        {
            var text = value.GetString();
            return string.IsNullOrEmpty(text) ? Array.Empty<string>() : new[] { text };
        }

        return StringArray(element, name);
    }

    private static string FirstOf(IReadOnlyList<string> values) => values.Count > 0 ? values[0] : string.Empty;
}
