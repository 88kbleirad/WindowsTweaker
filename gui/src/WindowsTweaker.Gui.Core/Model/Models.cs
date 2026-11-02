namespace WindowsTweaker.Gui.Core.Model;

/// <summary>Environment snapshot (Get-WtEnvironment), reduced to what the header shows.</summary>
public sealed record EnvironmentStatus(
    string PowerShellVersion,
    string RequiredPowerShell,
    bool IsWindows,
    bool IsAdmin,
    string OsName,
    string OsBuild,
    string OsVersionKey,
    string Architecture,
    string LanguageMode,
    string Culture,
    string Language,
    string LogPath,
    string StatePath,
    bool? PendingReboot,
    string PendingRebootLabel,
    IReadOnlyDictionary<string, bool> Capabilities);

/// <summary>Runtime info (Get-WtRuntimeInfo), reduced to the profile and the notice.</summary>
public sealed record RuntimeStatus(
    string Edition,
    string Version,
    string Platform,
    string Architecture,
    string Tier,
    bool IsWindows,
    bool Validated,
    string Notice,
    IReadOnlyList<RuntimeCapability> Capabilities);

/// <summary>One runtime capability with its reason.</summary>
public sealed record RuntimeCapability(string Name, bool Supported, string Reason);

/// <summary>One catalog row (Get-WtTweakDefinitionView).</summary>
public sealed record CatalogTweak(
    string Id,
    string Category,
    string DisplayName,
    string Lifecycle,
    string Scope,
    string Privilege,
    string Risk,
    string Restart,
    string Rollback,
    IReadOnlyList<string> States,
    string DefaultState,
    string Source,
    string PackId,
    string Support,
    IReadOnlyList<string> Tags);

/// <summary>One tweak state row (Get-WtTweakState), flattened.</summary>
public sealed record TweakState(
    string Id,
    string Category,
    string Name,
    string Description,
    string Impact,
    string Risk,
    string Scope,
    string Privilege,
    string Restart,
    string Rollback,
    bool Irreversible,
    bool DataDeletion,
    bool ReducesProtection,
    IReadOnlyList<string> StateNames,
    string DefaultState,
    IReadOnlyList<string> Requires,
    string State,
    string Details,
    bool Supported,
    string UnsupportedReason,
    string Lifecycle,
    bool Managed,
    IReadOnlyList<string> ManagedBy,
    string Note)
{
    /// <summary>True when this tweak can run on this host right now.</summary>
    public bool CanApply => Supported;
}

/// <summary>One target row of a change preview.</summary>
public sealed record PreviewTarget(
    string Identity,
    string Label,
    string TargetClass,
    string Operation,
    string CurrentDisplay,
    string CurrentKind,
    string CurrentReason,
    string IntendedDisplay,
    string IntendedType,
    string Rollback,
    bool Irreversible,
    bool BaselinePreserved);

/// <summary>The read-only preview of a tweak's operations.</summary>
public sealed record ChangePreview(
    string TweakId,
    string State,
    bool Supported,
    string SupportReason,
    string Scope,
    string Privilege,
    string Restart,
    bool Irreversible,
    string Lifecycle,
    bool? Complete,
    string DetectedState,
    string Fingerprint,
    string ReviewedUtc,
    string RecoveryRollback,
    IReadOnlyList<string> Messages,
    IReadOnlyList<PreviewTarget> Targets);

/// <summary>One requested change in the review list.</summary>
public sealed record ReviewedChange(string Id, string State, string DisplayName, string CurrentState)
{
    /// <summary>Stable identity of a reviewed row (id + target state).</summary>
    public string Key => $"{Id}\u0000{State}";
}

/// <summary>The outcome of one applied (or previewed) change.</summary>
public sealed record ApplyResult(
    string RequestedId,
    string RequestedState,
    string TweakId,
    string Status,
    string Outcome,
    IReadOnlyList<string> Messages,
    bool Verified,
    int VerifiedCount,
    int Mismatched,
    bool Compensated,
    bool JournalPersisted,
    bool JournalStopBatch,
    string JournalUncertainStage)
{
    /// <summary>True when the engine calls this a success.</summary>
    public bool Succeeded => Status is "succeeded" or "unchanged";

    /// <summary>True when the batch must stop after this row.</summary>
    public bool StopBatch => JournalStopBatch;

    /// <summary>A compact verification marker for table rendering.</summary>
    public string VerifiedMark => Verified ? "✓" : "";
}

/// <summary>The result of a batch apply.</summary>
public sealed record BatchResult(IReadOnlyList<ApplyResult> Results, bool Cancelled);

/// <summary>One history row.</summary>
public sealed record HistoryRow(
    string OperationId,
    string TweakId,
    string State,
    string Outcome,
    string Timestamp,
    bool RolledBack,
    string? RolledBackAt,
    int RecordCount,
    bool Irreversible,
    IReadOnlyList<string> Messages);

/// <summary>One journal operation row.</summary>
public sealed record OperationRow(
    string OperationId,
    string SessionId,
    int Sequence,
    string Origin,
    string Stage,
    string TweakId,
    string State,
    string Timestamp,
    string UpdatedUtc,
    bool DryRun,
    string Outcome,
    bool RolledBack,
    int TargetCount,
    IReadOnlyList<string> Messages,
    bool Verified,
    int Mismatched,
    int Unverifiable,
    bool Compensated);

/// <summary>One interrupted operation.</summary>
public sealed record InterruptedOperation(
    string OperationId,
    string SessionId,
    string TweakId,
    string State,
    string Stage,
    string Timestamp,
    bool CanRestore,
    IReadOnlyList<InterruptedTarget> Targets);

/// <summary>One target of an interrupted operation, with its live value.</summary>
public sealed record InterruptedTarget(string Identity, string Label, string Intended, string Live, string Classification);

/// <summary>The undo result.</summary>
public sealed record UndoResult(
    string Status,
    string TweakId,
    string HistoryId,
    IReadOnlyList<string> Messages,
    bool ReviewRequired,
    IReadOnlyList<string> ExternalChanges,
    bool JournalPersisted,
    bool JournalStopBatch);

/// <summary>One preset and its entries.</summary>
public sealed record PresetInfo(string Name, string Description, string Source, string Path, int EntryCount);

/// <summary>A licensing method offered by the external tool.</summary>
public sealed record ActivationMethod(
    string Id,
    string Switch,
    IReadOnlyList<string> ExtraSwitches,
    string DurationModel,
    string EditionScope,
    string Internet,
    int MinBuild,
    string Evidence);

/// <summary>The external tool's readiness.</summary>
public sealed record ExternalToolStatus(string Status, string Code, string Reason, bool Ready, bool Installed, string Path);

/// <summary>Monitoring defaults.</summary>
public sealed record MonitorDefaults(int FastSeconds, int SlowSeconds, int QueueCap, int ProviderTimeoutMs);

/// <summary>One dashboard identifier.</summary>
public sealed record DashboardInfo(string Id);

/// <summary>A restart decision (Test-WtRestartRequest).</summary>
public sealed record RestartDecision(bool Allowed, string Reason, bool Available, string Mechanism);
