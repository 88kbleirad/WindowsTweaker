<#
.SYNOPSIS
    WindowsTweaker entry point: reviewable, reversible Windows customization.

.DESCRIPTION
    Thin front end over the WindowsTweaker module. It does not implement any tweak
    itself: everything is executed by the module, so dry run, state capture,
    verification, logging and rollback behave identically from the terminal interface,
    the scriptable CLI and the optional graphical interface.

    Starting it without arguments opens the keyboard-driven terminal interface. Every
    other switch is non-interactive and prints machine-readable status.

    Supported hosts: Windows 10 22H2 / Windows 11. The interface starts on the Windows
    PowerShell 5.1 that ships with Windows and on PowerShell 7.4-7.6 (the validated stable
    range); 5.1 is a reduced-but-native runtime, and -RuntimeReport shows exactly which
    capabilities it has. Anything older than 5.1 is refused. See docs/COMPATIBILITY.md.

.PARAMETER List
    List the catalog with the current state of every tweak (read-only).

.PARAMETER Status
    Show the environment snapshot, the state store path and the log path (read-only).

.PARAMETER Id
    Apply a single tweak by id, e.g. -Id Privacy.AdvertisingId -State Disabled.

.PARAMETER State
    Target state for -Id. Defaults to the tweak's declared default state.

.PARAMETER Arguments
    Parameters for tweaks that need them, e.g.
    -Arguments @{ InterfaceIndex = @(7); ServerAddresses = @('1.1.1.1') }

.PARAMETER IncludeRestorePoint
    Create a System Restore point before the change. Supplementary, never implicit: the
    per-change state capture is what makes a rollback exact, and a restore point is an
    extra safety net that needs elevation and System Protection enabled. The terminal
    interface never creates one on its own.

.PARAMETER RestartAfterApply
    Restart the machine after the batch finishes, once, and only when every change was
    applied, verified and fully recorded in the journal. Opt-in per invocation, never
    remembered. Refused together with -WhatIf and with any switch that does not apply
    changes, and unavailable on a platform that cannot restart. Refused (with the applied
    changes kept) if anything failed, was cancelled or skipped, if verification or
    compensating restoration ran, or if the journal could not record a stage. Nothing is
    force-closed, so unsaved work can delay or prevent the restart. The countdown runs in
    this process: press Escape to cancel it.

.PARAMETER Preset
    Apply a preset: a shipped or user preset name, or the path of a preset JSON file.
    Every entry is applied through Invoke-WtTweak, so -WhatIf previews the whole preset
    without writing anything.

.PARAMETER PresetList
    List the available presets (shipped and user) with their entry counts (read-only).

.PARAMETER PresetExport
    Normalise -Preset into a preset file at this path (validated, never overwrites
    without -Force).

.PARAMETER WhatIf
    Dry run: report every operation that would run without writing, removing,
    downloading or installing anything.

.PARAMETER Language
    Interface language: en or vi (a culture name such as vi-VN is accepted). Precedence is
    this option, then the language saved from the interface (`L` or the Overview row), then
    WT_LANG, then the supported UI culture, then English. Changing it never applies a tweak.

.PARAMETER Colour
    Palette depth for the terminal interface: Auto (default), TrueColor, Ansi256,
    Ansi16 or Mono.

.PARAMETER Ascii
    Use ASCII frame characters in the terminal interface instead of box drawing. ASCII
    icons are forced as well.

.PARAMETER Icons
    Icon display mode for the terminal interface: Auto (default), Unicode, NerdFont,
    ASCII or None. Auto picks Unicode when the output encoding is UTF-8 and the readable
    ASCII tags otherwise; the mode saved with the in-interface icon picker (key I) is
    honoured while this switch is left at Auto. No font is installed or detected.

.PARAMETER Scan
    Aggregate the size of a directory tree (read-only) and print the result. The optional Go
    worker serves this capability when it is installed and protocol-compatible; otherwise the
    PowerShell implementation does, and the output always says which one ran.

.PARAMETER WorkerBackend
    Backend for background work: Auto (default), Go or PowerShell. Auto uses the Go worker
    when it is available and falls back to PowerShell with the reason; Go refuses to fall
    back, so the capability is reported unavailable instead. The setting saved in the
    interface (settings.json) is used while this parameter is left at Auto.

.PARAMETER InputDiagnostics
    Terminal interface only: append one structured log record per key press (normalised
    key plus dispatch target) to the log file. Text typed into a search box or a path
    field is masked, so the trace never records what was written; nothing is drawn on the
    screen. WT_TUI_INPUT_TRACE=1 has the same effect.

.PARAMETER Gui
    Start the graphical interface instead of the terminal interface (Windows only).

.PARAMETER Rollback
    Roll back the newest captured change of -Id (or of -HistoryId).

.PARAMETER HistoryId
    Roll back a specific captured change (see -History).

.PARAMETER History
    Show the change history (read-only).

.PARAMETER Report
    Write a JSON report of the environment, catalog and history; prints the path.

.EXAMPLE
    pwsh -File WindowsTweaker.ps1                      # terminal interface

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -List

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled -WhatIf

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -Preset privacy-hardening -WhatIf

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -Rollback

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -Id Privacy.AdvertisingId -State Disabled -IncludeRestorePoint

.PARAMETER CatalogList
    List the catalog with the declarative status of every tweak: whether it is defined in a
    document, its source, its scope, its risk, its lifecycle and the support that can be
    vouched for. Read-only.

.PARAMETER CatalogFilter
    Restrict -CatalogList: definitions, powershell, builtin, pack[:<pack id>], scope:<name>,
    risk:<name>, lifecycle:<name>, evidence:<status>, support:<status>, category:<name>,
    tag:<name>, requires:<id>, conflicts:<id>. An unrecognised filter is reported instead of
    being ignored.

.PARAMETER CatalogInspect
    Show one definition in full: states, operations, detection map, conditions, side effects,
    references and the separated evidence blocks. Read-only.

.PARAMETER CatalogValidate
    Validate a catalog or pack document and report every problem, with its document path.
    Nothing is registered, stored or executed.

.PARAMETER CatalogPlan
    Plan one or more tweak ids: the apply order, the prerequisites (separating the ones that
    are already satisfied and are therefore never rewritten), conflicts and cycles. Read-only.

.PARAMETER CatalogMigrations
    List the recorded id migrations (renames, replacements, retirements) and any preset entry
    that no longer resolves. Read-only.

.PARAMETER PackList
    List the installed packs with their version, definition count, hash and enabled state.

.PARAMETER PackInspect
    Show one installed pack, its definitions and its stored paths.

.PARAMETER PackImport
    Validate a pack document, show what it contains and store it (with -WhatIf to stop before
    storing). A pack only adds definitions; nothing on this machine is changed by importing.

.PARAMETER PackEnable
    Register the definitions of an installed pack.

.PARAMETER PackDisable
    Unregister the definitions of an installed pack. Journal entries it created stay
    restorable, because a restore replays the captured original state.

.PARAMETER PackRemove
    Remove an installed pack and unregister its definitions. Refused while changes it created
    have not been rolled back, unless -PackForce is given.

.PARAMETER PackForce
    With -PackImport: replace an installed pack with the same id. With -PackRemove: remove even
    though changes the pack created have not been rolled back (they stay restorable).

.PARAMETER PackNoEnable
    Import a pack without registering its definitions (they can be enabled later).

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -Language vi

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -CatalogList -CatalogFilter definitions, lifecycle:Experimental

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -CatalogInspect Privacy.WindowsTips

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -CatalogPlan Privacy.SearchHighlights, Privacy.BingSearch

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -CatalogValidate ./samples/example-pack.json

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -PackImport ./samples/example-pack.json -WhatIf

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -PackImport ./samples/example-pack.json -PackNoEnable

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -PackList

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -PackRemove Contoso.Hardening -PackForce

.PARAMETER SanityScan
    Run the read-only sanity scan and print what is worth reviewing. It changes nothing, repairs
    nothing and deletes nothing, and it reports Clean only when every required probe answered. A
    finding is not a fault: it comes with the documented claim it rests on, the expectation that
    claim implies, and what the claim does not cover.

.PARAMETER SanityRule
    Run only these rules. Without it every loaded rule runs.

.PARAMETER SanityExport
    Write the scan report to this path. Nothing is written unless this is given.

.PARAMETER SanityFormat
    Report format for -SanityExport: Markdown (default) or Json.

.PARAMETER Recommend
    Build a recommendation proposal for one objective: Balanced, Responsiveness, Gaming,
    PowerEfficiency or Privacy. A proposal only - nothing is applied and no selection of yours is
    discarded. Every considered item is listed with the reason it was recommended, excluded,
    unknown or blocked.

.PARAMETER RecommendManual
    Also list the items the engine keeps out of automatic selection, with the reason.

.PARAMETER RecommendPreferences
    Consider preference items (themes, animations, what the interface shows). They are never
    presented as a performance improvement, and the Gaming objective never takes them.

.PARAMETER RecommendFinding
    Sanity rule ids with an observed finding; a repair recommendation needs one.

.PARAMETER Choices
    List the settings that offer several alternatives, with the detected alternative and the
    intent of each option: writing a value this tool can restore exactly, or requesting the
    behaviour Windows uses by default.

.PARAMETER CatalogDimensions
    With -CatalogInspect: also print the configured, effective and ownership dimensions of the
    tweak, and the pending-restart evidence they were read against.

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -SanityScan

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -SanityScan -SanityRule Tcp.LegacyReceiveWindow -SanityExport ./scan.md

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -Recommend Privacy -RecommendManual

.PARAMETER RuntimeReport
    Print the runtime profile, every capability with its reason, and the command that runs
    this same entry point on the validated runtime. Read-only, identical on both runtimes.

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -Choices

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -CatalogInspect Privacy.WindowsTips -CatalogDimensions

.EXAMPLE
    pwsh -File WindowsTweaker.ps1 -RuntimeReport
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param
(
    [Parameter(Mandatory = $false)][switch]$List,
    [Parameter(Mandatory = $false)][switch]$Status,
    [Parameter(Mandatory = $false)][string]$Id,
    [Parameter(Mandatory = $false)][string]$State,
    [Parameter(Mandatory = $false)][hashtable]$Arguments,
    [Parameter(Mandatory = $false)][switch]$IncludeRestorePoint,
    [Parameter(Mandatory = $false)][switch]$RestartAfterApply,
    [Parameter(Mandatory = $false)][string]$Preset,
    [Parameter(Mandatory = $false)][switch]$PresetList,
    [Parameter(Mandatory = $false)][string]$PresetExport,
    [Parameter(Mandatory = $false)][ValidateSet('Auto', 'TrueColor', 'Ansi256', 'Ansi16', 'Mono')][string]$Colour = 'Auto',
    [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Balanced', 'Low-resource')][string]$PerfProfile = 'Auto',
    [Parameter(Mandatory = $false)][switch]$Ascii,
    [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Unicode', 'NerdFont', 'ASCII', 'None')][string]$Icons = 'Auto',
    [Parameter(Mandatory = $false)][switch]$Gui,
    [Parameter(Mandatory = $false)][switch]$History,
    [Parameter(Mandatory = $false)][switch]$Rollback,
    [Parameter(Mandatory = $false)][string]$HistoryId,
    [Parameter(Mandatory = $false)][switch]$Report,
    [Parameter(Mandatory = $false)][string]$Scan,
    [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Go', 'PowerShell')][string]$WorkerBackend = 'Auto',
    [Parameter(Mandatory = $false)][switch]$InputDiagnostics,
    [Parameter(Mandatory = $false)][object]$Language,
    # --- declarative catalog and packs ---
    [Parameter(Mandatory = $false)][switch]$CatalogList,
    [Parameter(Mandatory = $false)][string[]]$CatalogFilter,
    [Parameter(Mandatory = $false)][string]$CatalogInspect,
    [Parameter(Mandatory = $false)][string]$CatalogValidate,
    [Parameter(Mandatory = $false)][string[]]$CatalogPlan,
    [Parameter(Mandatory = $false)][switch]$CatalogMigrations,
    [Parameter(Mandatory = $false)][switch]$PackList,
    [Parameter(Mandatory = $false)][string]$PackInspect,
    [Parameter(Mandatory = $false)][string]$PackImport,
    [Parameter(Mandatory = $false)][string]$PackEnable,
    [Parameter(Mandatory = $false)][string]$PackDisable,
    [Parameter(Mandatory = $false)][string]$PackRemove,
    [Parameter(Mandatory = $false)][switch]$PackForce,
    [Parameter(Mandatory = $false)][switch]$PackNoEnable,
    # --- read-only sanity scan, recommendations and exclusive choices ---
    [Parameter(Mandatory = $false)][switch]$SanityScan,
    [Parameter(Mandatory = $false)][string[]]$SanityRule,
    [Parameter(Mandatory = $false)][string]$SanityExport,
    [Parameter(Mandatory = $false)][ValidateSet('Markdown', 'Json')][string]$SanityFormat = 'Markdown',
    [Parameter(Mandatory = $false)][string]$Recommend,
    [Parameter(Mandatory = $false)][switch]$RecommendManual,
    [Parameter(Mandatory = $false)][switch]$RecommendPreferences,
    [Parameter(Mandatory = $false)][string[]]$RecommendFinding,
    [Parameter(Mandatory = $false)][switch]$Choices,
    [Parameter(Mandatory = $false)][switch]$CatalogDimensions,
    # --- runtime compatibility ---
    [Parameter(Mandatory = $false)][switch]$RuntimeReport
)


Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$ModuleManifest = Join-Path $PSScriptRoot 'src/WindowsTweaker/WindowsTweaker.psd1'

if (-not (Test-Path -LiteralPath $ModuleManifest))
{
    throw "WindowsTweaker module not found at '$ModuleManifest'."
}

Import-Module $ModuleManifest -Force

if ($Language)
{
    Set-WtLanguage -Language $Language | Out-Null
}

# A top-level run (`pwsh -File WindowsTweaker.ps1`) ends its own process with the code the
# operation reported. When the script is dot-sourced or invoked with `&` from an existing
# session, `exit` would terminate that session - quitting the terminal interface must never
# close the shell the user is working in - so the code is handed back to the caller instead
# and mirrored in $LASTEXITCODE.
$InvokedFromSession = $MyInvocation.InvocationName -in '.', '&'

<#
.SYNOPSIS
    Ends the invocation with an exit code, or returns it when a session owns the script.
#>
function Exit-WtEntryPoint
{
    param ([Parameter(Mandatory = $false)][int]$Code = 0)

    # A clean shutdown closes the session the run opened, so Get-WtSession can tell a run that
    # finished from one that was interrupted. This is bookkeeping: it writes nothing when the
    # run recorded no operation, and a failure here must never replace the code the operation
    # reported, so the outcome is only mirrored into the log.
    try
    {
        $null = Close-WtSession
    }
    catch
    {
        Write-Warning ("The journal session could not be marked as ended: {0}" -f $_.Exception.Message)
    }

    if ($InvokedFromSession)
    {
        # Hand the code back instead of ending the caller's session. Nothing is written to
        # the pipeline, so a scripted caller sees exactly the output it asked for and reads
        # the code from $LASTEXITCODE.
        $global:LASTEXITCODE = $Code
        return
    }

    exit $Code
}

# Reports a usage error and ends the invocation with code 2. Write-Error would be a terminating
# error under this script's $ErrorActionPreference = 'Stop', which ends the run before the exit code
# is set - so the message goes to the error stream directly and the code is still the caller's.
function Write-WtEntryPointUsageError
{
    param ([Parameter(Mandatory = $true)][string]$Message)

    $Host.UI.WriteErrorLine($Message)
    Exit-WtEntryPoint -Code 2
}

# One runtime policy, shared with the bootstrap and the module. Windows PowerShell 5.1 is a
# supported starting point, not an error: it runs the same engine through the compatibility
# layer, and this notice names the validated runtime and the exact command that gets there.
# Get-WtRuntimeInfo is the exported, read-only view of the profile and the capabilities; the
# module's helpers themselves stay private.
$RuntimeInfo = Get-WtRuntimeInfo -EntryPoint $PSCommandPath
$RuntimeProfile = $RuntimeInfo.Profile
if ($RuntimeProfile.Version -lt $RuntimeProfile.MinimumVersion)
{
    foreach ($Line in @($RuntimeInfo.Notice -split "`r?`n"))
    {
        if ($Line) { $Host.UI.WriteErrorLine($Line) }
    }
    Exit-WtEntryPoint -Code 2
}
if ($RuntimeInfo.Notice)
{
    Write-Host $RuntimeInfo.Notice
}

# The whole invocation is a dry run when -WhatIf is used. Under
# Set-StrictMode -Version 3.0 a hashtable key must not be probed with dot notation,
# so the flag is carried in a plain boolean.
$DryRun = [bool]$WhatIfPreference




# A list switch may arrive as several arguments or as one comma-separated argument
# (a shell cannot build a PowerShell array), so both forms are accepted.
function Expand-WtEntryPointList
{
    param ([Parameter(Mandatory = $false)][string[]]$Value)

    $Items = @()
    foreach ($Entry in @($Value))
    {
        foreach ($Part in ([string]$Entry).Split(','))
        {
            $Trimmed = $Part.Trim()
            if ($Trimmed) { $Items += $Trimmed }
        }
    }

    return @($Items)
}

# Modifiers that only mean something together with their command. Silently ignoring them would
# start the terminal interface instead, which is exactly the kind of surprise a command line
# must not produce. -SanityFormat is deliberately absent: it carries a default value, so its
# presence cannot be distinguished from an omission.
$DanglingModifiers = @(
    @{ Modifier = '-SanityRule'; Value = $SanityRule; Owner = '-SanityScan'; Flag = [bool]$SanityScan }
    @{ Modifier = '-SanityExport'; Value = $SanityExport; Owner = '-SanityScan'; Flag = [bool]$SanityScan }
    @{ Modifier = '-RecommendManual'; Value = $RecommendManual; Owner = '-Recommend'; Flag = [bool]$Recommend }
    @{ Modifier = '-RecommendPreferences'; Value = $RecommendPreferences; Owner = '-Recommend'; Flag = [bool]$Recommend }
    @{ Modifier = '-RecommendFinding'; Value = $RecommendFinding; Owner = '-Recommend'; Flag = [bool]$Recommend }
    @{ Modifier = '-CatalogDimensions'; Value = $CatalogDimensions; Owner = '-CatalogInspect'; Flag = [bool]$CatalogInspect }
)

foreach ($Modifier in $DanglingModifiers)
{
    if ($Modifier.Flag -or -not $Modifier.Value) { continue }
    Write-WtEntryPointUsageError -Message (Get-WtString -Key 'Entry.ModifierNeedsCommand' -Arguments @($Modifier.Modifier, $Modifier.Owner))
}

# ---- restart after applying ------------------------------------------------------------------
# The request is validated before any switch runs. A restart makes sense only for the two
# switches that apply changes (-Id, -Preset); everything else is a read-only or preview
# invocation, and asking for a restart there is a usage error rather than a silent no-op.
# The rules themselves live in the module (Test-WtRestartRequest / Invoke-WtBatchRestart),
# so the command line and the interface cannot drift apart.
$RestartApplies = [bool]($Id -or $Preset)
$RestartDecision = Test-WtRestartRequest -Requested:$RestartAfterApply -Preview:$DryRun -ReadOnly:(-not $RestartApplies)

if ($RestartAfterApply -and -not $RestartDecision.Allowed)
{
    $ReasonKey = switch ($RestartDecision.Reason)
    {
        'preview' { 'Cli.Restart.Preview' }
        'readonly' { 'Cli.Restart.ReadOnly' }
        'unsupported' { 'Cli.Restart.Unsupported' }
        default { 'Cli.Restart.Preview' }
    }

    Write-WtEntryPointUsageError -Message (Get-WtString -Key 'Cli.Restart.Rejected' -Arguments @((Get-WtString -Key $ReasonKey)))
}

<#
.SYNOPSIS
    Runs the opt-in restart for a finished command-line batch and reports it in words.
.DESCRIPTION
    The decision and the countdown live in the module (Invoke-WtBatchRestart); this only
    prints what happened. The countdown needs a console that can deliver a cancellation, so
    without one no restart is requested at all - a countdown nobody can stop is worse than
    no countdown.
#>
function Write-WtEntryPointRestart
{
    param
    (
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Results = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Failures = @(),
        [Parameter(Mandatory = $false)][int]$Skipped = 0,
        [Parameter(Mandatory = $false)][string]$Requirement = ''
    )

    if (-not $RestartAfterApply) { return }

    # First the verdict, so a refused restart explains itself even on a non-interactive
    # invocation; then, only for an eligible batch, the countdown (which needs a console
    # that can deliver a cancellation, so without one nothing is requested at all).
    $Verdict = Invoke-WtBatchRestart -Results $Results -Failures $Failures -Skipped $Skipped -Requirement $Requirement -DryVerdict

    if ($Verdict.Outcome -ne 'eligible')
    {
        foreach ($Line in @($Verdict.Lines))
        {
            Write-Host ("restart: {0}" -f $Line)
        }
        Write-Host (Get-WtString -Key 'Tui.Restart.Manual')
        return
    }

    if (-not (Test-WtInteractiveConsole))
    {
        Write-Host (Get-WtString -Key 'Cli.Restart.NeedInteractive')
        Write-Host (Get-WtString -Key 'Tui.Restart.Manual')
        return
    }

    $Outcome = Invoke-WtBatchRestart -Results $Results -Failures $Failures -Skipped $Skipped -Requirement $Requirement

    switch ($Outcome.Outcome)
    {
        'requested' { Write-Host (Get-WtString -Key 'Cli.Restart.Requested') }
        'cancelled' { Write-Host (Get-WtString -Key 'Cli.Restart.Cancelled') }
        'failed' { Write-Host (Get-WtString -Key 'Cli.Restart.Failed' -Arguments @([string]$Outcome.Message)) }
        default
        {
            foreach ($Line in @($Outcome.Lines))
            {
                Write-Host ("restart: {0}" -f $Line)
            }
            Write-Host (Get-WtString -Key 'Tui.Restart.Manual')
        }
    }
}

# Applies one reviewed preset entry and reports the outcome exactly as the module does.
function Write-WtEntryPointResult
{
    param ([Parameter(Mandatory = $true)][object]$Result)

    Write-Host ("[{0}] {1} -> {2}" -f $Result.Status, $Result.TweakId, $Result.State)
    Write-Host ("      restart {0} | rollback {1} | state saved {2}" -f $Result.Restart, $Result.Rollback, $Result.CapturedState)

    foreach ($Operation in $Result.Operations)
    {
        Write-Host ("      [{0,-11}] {1}" -f $Operation.Status, $Operation.Message)
    }
    foreach ($Message in $Result.Messages)
    {
        Write-Host ("      - {0}" -f $Message)
    }
}

# Resolves -Preset to a preset object: a file path first, then a preset name.
function Resolve-WtEntryPointPreset
{
    param ([Parameter(Mandatory = $true)][string]$Reference)

    if (Test-Path -LiteralPath $Reference -PathType Leaf)
    {
        return (Import-WtPreset -Path $Reference)
    }

    $Match = @(Get-WtPreset -Name $Reference)
    if ($Match.Count -eq 0)
    {
        throw (Get-WtString -Key 'Tui.Preset.NotFound' -Arguments @($Reference))
    }

    return $Match[0]
}

switch ($true)
{
    { $List }
    {
        $States = @(Get-WtTweakState)

        Write-Host ("{0} tweaks" -f $States.Count)
        $States |
            Select-Object Id, Category, State, Supported, Risk, Restart, Rollback, Irreversible, Managed |
            Format-Table -AutoSize |
            Out-String -Width 220 |
            Write-Host

        # Show what is object, then a summary so the CLI is usable without -Format-Table.
        Write-Host ("enabled: {0} | disabled: {1} | unknown: {2} | unsupported: {3}" -f
            @($States | Where-Object { $_.State -eq 'Enabled' }).Count,
            @($States | Where-Object { $_.State -eq 'Disabled' }).Count,
            @($States | Where-Object { $_.State -eq 'Unknown' }).Count,
            @($States | Where-Object { $_.State -eq 'Unsupported' }).Count)
        Exit-WtEntryPoint -Code 0
    }
    { $Status }
    {
        Get-WtEnvironment | Format-List | Out-String -Width 220 | Write-Host
        Write-Host ("Log file  : {0}" -f (Get-WtLogPath))
        Write-Host ("State file: {0}" -f (Get-WtStatePath))
        Write-Host ("Presets   : {0}" -f ((@(Get-WtPreset).Name) -join ', '))
        Write-Host ("Worker    : {0}" -f (Get-WtWorkerBackendSummary -Requested $WorkerBackend))
        Exit-WtEntryPoint -Code 0
    }
    { $History }
    {
        $Entries = @(Get-WtHistory -Limit 50)
        if ($Entries.Count -eq 0)
        {
            Write-Host 'No recorded changes.'
            Exit-WtEntryPoint -Code 0
        }

        $Entries | Format-Table Timestamp, TweakId, State, Outcome, RolledBack, Irreversible, RecordCount -AutoSize | Out-String -Width 220 | Write-Host
        Exit-WtEntryPoint -Code 0
    }
    { $PresetList }
    {
        $Presets = @(Get-WtPreset)
        if ($Presets.Count -eq 0)
        {
            Write-Host 'No presets are available.'
            Exit-WtEntryPoint -Code 0
        }

        $Presets |
            Select-Object Name, Source, @{ Name = 'Tweaks'; Expression = { @($_.Entries).Count } }, Description, Path |
            Format-Table -AutoSize |
            Out-String -Width 240 |
            Write-Host
        Exit-WtEntryPoint -Code 0
    }
    { $Report }
    {
        $Path = Export-WtReport -Format Json
        Write-Host $Path
        Exit-WtEntryPoint -Code 0
    }
    { $Scan }
    {
        # Ctrl+C must not orphan the worker: the handler asks for cancellation, the adapter
        # sends a cancel request, and the finally block reaps the process with a bounded wait.
        $ScanCancel = @{ Requested = $false }
        $ScanHandler = [System.ConsoleCancelEventHandler] {
            param ($CancelSource, $CancelArguments)
            $CancelArguments.Cancel = $true
            $ScanCancel.Requested = $true
        }

        try { [Console]::add_CancelKeyPress($ScanHandler) } catch { Write-WtLog -Level Debug -Message 'Ctrl+C handling could not be installed for the scan.' -NoConsole }

        try
        {
            $Result = Invoke-WtDirectoryScan -Root $Scan -Backend $WorkerBackend -CancelCheck { $ScanCancel.Requested }
        }
        finally
        {
            try { [Console]::remove_CancelKeyPress($ScanHandler) } catch { Write-WtLog -Level Debug -Message 'Ctrl+C handling could not be removed after the scan.' -NoConsole }
        }

        if (-not $Result.Ok)
        {
            Write-Host ("[{0}] {1}" -f $Result.Code, $Result.Message)
            Exit-WtEntryPoint -Code 1
        }

        Write-Host ("backend    : {0}" -f $Result.Backend)
        Write-Host ("root       : {0}" -f $Result.Root)
        Write-Host ("files      : {0} in {1} directories" -f $Result.Files, $Result.Directories)
        Write-Host ("logical    : {0} bytes" -f $Result.Bytes)
        Write-Host ("allocated  : {0} bytes{1}" -f $Result.AllocatedBytes, $(if ($Result.AllocatedKnown) { '' } else { ' (logical size repeated)' }))
        Write-Host ("skipped    : {0} link(s), {1} other" -f $Result.SkippedLinks, $Result.SkippedOther)
        Write-Host ("hard links : {0} deduplicated" -f $Result.HardLinksDeduped)
        Write-Host ("partial    : {0} ({1} unreadable entries{2})" -f $Result.Partial, @($Result.Errors).Count, $(if ($Result.ErrorsTruncated) { ', list capped' } else { '' }))
        Write-Host ("elapsed    : {0} ms" -f $Result.ElapsedMS)
        foreach ($Note in @($Result.AllocatedNote, $Result.HardLinkNote))
        {
            if ($Note) { Write-Host ("note       : {0}" -f $Note) }
        }

        Exit-WtEntryPoint -Code 0
    }
    { $Rollback -or $HistoryId }
    {
        $RollbackParameters = @{}
        if ($Id) { $RollbackParameters.Id = $Id }
        if ($HistoryId) { $RollbackParameters.HistoryId = $HistoryId }

        $Result = Undo-WtTweak @RollbackParameters -WhatIf:$DryRun
        Write-Host ("Status: {0}" -f $Result.Status)
        foreach ($Message in $Result.Messages)
        {
            Write-Host ("  - {0}" -f $Message)
        }

        Exit-WtEntryPoint -Code ($(if ($Result.Status -in 'failed', 'unsupported') { 1 } else { 0 }))
    }
    { $PresetExport }
    {
        if (-not $Preset)
        {
            Write-WtEntryPointUsageError -Message 'Specify -Preset (name or file) together with -PresetExport.'
        }

        $Source = Resolve-WtEntryPointPreset -Reference $Preset
        $Written = Export-WtPreset -Entries @($Source.Entries) -Path $PresetExport -Name $Source.Name -Description $Source.Description -WhatIf:$DryRun
        Write-Host ("{0} preset entries -> {1}" -f @($Source.Entries).Count, $Written)
        if (@($Source.Skipped).Count -gt 0)
        {
            Write-Host ("excluded entries: {0}" -f @($Source.Skipped).Count)
            foreach ($Reason in $Source.Skipped)
            {
                Write-Host ("  - {0}" -f $Reason)
            }
        }

        Exit-WtEntryPoint -Code 0
    }
    { $Preset }
    {
        $Source = Resolve-WtEntryPointPreset -Reference $Preset
        Write-Host ("Preset: {0} ({1} entries, source {2})" -f $Source.Name, @($Source.Entries).Count, $Source.Source)

        foreach ($Reason in @($Source.Skipped))
        {
            Write-Host ("excluded: {0}" -f $Reason)
        }

        $Failed = 0
        $BatchResults = [System.Collections.Generic.List[object]]::new()
        $BatchFailures = [System.Collections.Generic.List[object]]::new()
        foreach ($Entry in $Source.Entries)
        {
            $ApplyParameters = @{ Id = $Entry.Id; State = $Entry.State }
            if ($Entry.Arguments) { $ApplyParameters.Arguments = $Entry.Arguments }

            try
            {
                $Result = Invoke-WtTweak @ApplyParameters -WhatIf:$DryRun
            }
            catch
            {
                Write-Host ("[failed] {0}: {1}" -f $Entry.Id, $_.Exception.Message)
                $BatchFailures.Add(@{ Message = $_.Exception.Message })
                $Failed++
                continue
            }

            $BatchResults.Add($Result)
            Write-WtEntryPointResult -Result $Result
            if ($Result.Status -in 'failed', 'unsupported')
            {
                $Failed++
            }
        }

        # The restart decision is made after the whole batch has reported, exactly like the
        # interface does, and its outcome is reported separately from the apply outcomes.
        Write-WtEntryPointRestart -Results $BatchResults.ToArray() -Failures $BatchFailures.ToArray() `
            -Requirement (Get-WtRestartRequirementInternal -Entries @($Source.Entries))

        Exit-WtEntryPoint -Code ($(if ($Failed -gt 0) { 1 } else { 0 }))
    }
    { $Id }
    {
        $ApplyParameters = @{ Id = $Id }
        if ($State) { $ApplyParameters.State = $State }
        if ($Arguments) { $ApplyParameters.Arguments = $Arguments }
        if ($IncludeRestorePoint) { $ApplyParameters.IncludeRestorePoint = $true }

        $Result = Invoke-WtTweak @ApplyParameters -WhatIf:$DryRun

        Write-Host ("Status      : {0}" -f $Result.Status)
        Write-Host ("Tweak       : {0} -> {1}" -f $Result.TweakId, $Result.State)
        Write-Host ("Restart     : {0}" -f $Result.Restart)
        Write-Host ("Rollback    : {0}" -f $Result.Rollback)
        Write-Host ("State saved : {0}" -f $Result.CapturedState)

        foreach ($Operation in $Result.Operations)
        {
            Write-Host ("  [{0,-11}] {1}" -f $Operation.Status, $Operation.Message)
        }
        foreach ($Message in $Result.Messages)
        {
            Write-Host ("  - {0}" -f $Message)
        }

        # Single-tweak apply: the same restart rules, one result. -WhatIf is already refused
        # before any switch runs.
        Write-WtEntryPointRestart -Results @($Result) -Requirement ([string]$Result.Restart)

        # Exit codes are meaningful for automation: 0 success/unchanged/dry run,
        # 1 failure or unsupported, 2 nothing to do. The code leaves through the single exit
        # helper so this path closes its session and hands the code back to a hosting session
        # exactly like every other path does.
        $StatusExitCode = switch ($Result.Status)
        {
            'succeeded' { 0 }
            'unchanged' { 0 }
            'dryrun' { 0 }
            'unsupported' { 1 }
            'failed' { 1 }
            default { 2 }
        }

        Exit-WtEntryPoint -Code $StatusExitCode
    }
    { $CatalogList }
    {
        $Rows = @(Get-WtTweakDefinitionView -Filter (Expand-WtEntryPointList -Value $CatalogFilter))
        if (@($Rows).Count -eq 0 -and @(Expand-WtEntryPointList -Value $CatalogFilter).Count -gt 0)
        {
            # Either nothing matched or a filter was not understood; the module already
            # reported the latter, and both are an empty result, so the exit code says so.
            Exit-WtEntryPoint -Code 2
        }

        $All = @(Get-WtTweakDefinitionView)
        Write-Host (Get-WtString -Key 'Cat.ListSummary' -Arguments @(
                @($Rows).Count,
                @($Rows | Where-Object { $_.Backed }).Count,
                @($All | Where-Object { $_.Backed }).Count))

        $Rows |
            Select-Object Id, Category, @{ Name = 'Name'; Expression = { Get-WtText -Value $_.Name } }, Source, PackId,
                Lifecycle, Scope, Risk, Support,
                @{ Name = 'Evidence'; Expression = { @($_.Evidence.Structural, $_.Evidence.ProviderTests, $_.Evidence.Windows) -ne '' -join '/' } },
                @{ Name = 'States'; Expression = { @($_.States) -join ',' } } |
            Format-Table -AutoSize |
            Out-String -Width 240 |
            Write-Host

        Exit-WtEntryPoint -Code 0
    }
    { $CatalogInspect }
    {
        $Definition = Get-WtTweakDefinition -Id $CatalogInspect
        $Tweak = Get-WtTweak -Id $CatalogInspect

        if (-not $Tweak)
        {
            Write-Error -Message (Get-WtString -Key 'Cat.DefinitionUnknown' -Arguments @($CatalogInspect))
            Exit-WtEntryPoint -Code 2
        }

        if (-not $Definition)
        {
            Write-Host (Get-WtString -Key 'Cat.NoDefinition')
            Write-Host ("{0}: {1}" -f $Tweak.Id, (Get-WtText -Value $Tweak.Name))
            Exit-WtEntryPoint -Code 0
        }

        $PackSuffix = if ($Definition.PackId) { Get-WtString -Key 'Cat.DefinitionPackSuffix' -Arguments @($Definition.PackId) } else { '' }
        Write-Host (Get-WtString -Key 'Cat.DefinitionHeader' -Arguments @($Definition.Id, $Definition.Revision, $Definition.Source, $PackSuffix))
        Write-Host ("  {0}" -f $Definition.DisplayName)
        Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.DefinitionStates'), (@($Definition.States.Keys) -join ', '))
        $DetectionTarget = if ([string]$Definition.Detection.Name) { "$($Definition.Detection.Path)\$($Definition.Detection.Name)" } else { [string]$Definition.Detection.Path }
        Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.DefinitionDetection'), $DetectionTarget)
        Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.DefinitionSideEffects'), $Definition.DisplaySideEffects)
        if (@($Definition.Requires).Count -gt 0) { Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.DefinitionRequires'), (@($Definition.Requires) -join ', ')) }
        if (@($Definition.Aliases).Count -gt 0) { Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.DefinitionAliases'), (@($Definition.Aliases) -join ', ')) }

        $Conditions = @($Definition.Conditions.Enforced)
        Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.DefinitionConditions'), (@($Conditions) -join ', '))
        $Unenforced = @('maxBuild', 'editions', 'architecture', 'hardware') | Where-Object {
            $Value = $Definition.Conditions[$_]
            ($Value -is [array] -and $Value.Count -gt 0) -or ($Value -isnot [array] -and $Value -and $Value -ne 'Any' -and $Value -ne 0)
        }
        if (@($Unenforced).Count -gt 0) { Write-Host ("    {0}: {1}" -f (Get-WtString -Key 'Cat.DefinitionUnenforced'), (@($Unenforced) -join ', ')) }

        Write-Host ("  {0}:" -f (Get-WtString -Key 'Cat.DefinitionEvidence'))
        Write-Host ("    " + (Get-WtString -Key 'Cat.DefinitionStructural' -Arguments @($Definition.Validation.Structural)))
        Write-Host ("    " + (Get-WtString -Key 'Cat.DefinitionProviderTests' -Arguments @($Definition.Evidence.ProviderTests)))
        $WindowsResult = if ($Definition.Evidence.WindowsIntegration) { $Definition.Evidence.WindowsIntegration.Result } else { 'Unverified' }
        $Claim = if ($Definition.Evidence.AuthorClaimed) { ' (' + (Get-WtString -Key 'Cat.DefinitionAuthorClaimed') + ')' } else { '' }
        Write-Host ("    " + (Get-WtString -Key 'Cat.DefinitionWindows' -Arguments @($WindowsResult)) + $Claim)

        if ($CatalogDimensions)
        {
            $Dimensions = Get-WtTweakDimensions -Id $Definition.Id
            Write-Host ''
            Write-Host ("{0}: {1}" -f (Get-WtString -Key 'Cat.Tui.Configured'), $Dimensions.ConfiguredLabel)
            Write-Host ("  {0}" -f $Dimensions.ConfiguredDetail)
            Write-Host ("{0}: {1} ({2})" -f (Get-WtString -Key 'Cat.Tui.Effective'), $Dimensions.EffectiveLabel, $Dimensions.EvidenceLabel)
            Write-Host ("  {0}" -f $Dimensions.EffectiveReason)
            Write-Host ("{0}: {1}" -f (Get-WtString -Key 'Cat.Tui.Ownership'), $Dimensions.OwnershipLabel)
            Write-Host ("  {0}" -f $Dimensions.OwnershipDetail)
            Write-Host ("{0}: {1}" -f (Get-WtString -Key 'Cat.Tui.PendingRestart'), $Dimensions.PendingLabel)
            foreach ($Marker in @($Dimensions.PendingRestart.Markers))
            {
                Write-Host ("  {0}: {1} - {2}" -f $Marker.Id, $Marker.MarkerLabel, $Marker.Detail)
            }
        }

        Exit-WtEntryPoint -Code 0
    }
    { $CatalogValidate }
    {
        $Validation = Test-WtCatalogFile -Path $CatalogValidate
        $State = if ($Validation.Valid) { Get-WtString -Key 'Cat.ValidationValid' } else { Get-WtString -Key 'Cat.ValidationInvalid' }
        $Hash = if ($Validation.Sha256) { $Validation.Sha256.Substring(0, [Math]::Min(12, $Validation.Sha256.Length)) } else { '' }
        Write-Host (Get-WtString -Key 'Cat.ValidationSummary' -Arguments @(
                $Validation.Path, $State, $Validation.TweakCount, $Validation.Bytes, $Hash))

        if (@($Validation.Errors).Count -eq 0)
        {
            Write-Host (Get-WtString -Key 'Cat.ValidationNone')
        }
        else
        {
            Write-Host ("{0}:" -f (Get-WtString -Key 'Cat.ValidationErrors'))
            foreach ($Problem in @($Validation.Errors)) { Write-Host ("  - {0}" -f $Problem) }
        }

        foreach ($Overlap in @($Validation.Overlaps))
        {
            Write-Host ("  {0}: {1} ({2}, {3})" -f (Get-WtString -Key 'Cat.ValidationOverlaps'), $Overlap.Label, $Overlap.Left, $Overlap.Right)
        }

        Exit-WtEntryPoint -Code ($(if ($Validation.Valid) { 0 } else { 1 }))
    }
    { $CatalogPlan }
    {
        $Plan = Get-WtDependencyPlan -Id (Expand-WtEntryPointList -Value $CatalogPlan)
        Write-Host (Get-WtString -Key 'Cat.PlanHeader' -Arguments @(@($Plan.Items).Count))

        if (@($Plan.Apply).Count -eq 0 -and @($Plan.Errors).Count -eq 0)
        {
            Write-Host (Get-WtString -Key 'Cat.PlanEmpty')
        }

        if (@($Plan.Apply).Count -gt 0)
        {
            Write-Host ("{0}:" -f (Get-WtString -Key 'Cat.PlanApplyHeader'))
            $Number = 0
            foreach ($Item in @($Plan.Items))
            {
                if ($Item.Action -ne 'Apply') { continue }
                $Number++
                $Source = if ($Item.Source -eq 'Prerequisite') { Get-WtString -Key 'Cat.PlanPrerequisite' } else { Get-WtString -Key 'Cat.PlanSelected' }
                $Note = if ($Item.ObservedState -in '', 'Unknown', 'Unsupported' -and $Item.Source -eq 'Prerequisite') { ' [' + (Get-WtString -Key 'Cat.PlanUnreadable') + ']' } else { '' }
                Write-Host ("  {0}. {1} -> {2} ({3}){4}" -f $Number, $Item.Id, $Item.State, $Source, $Note)
            }
        }

        if (@($Plan.Satisfied).Count -gt 0)
        {
            Write-Host ("{0}:" -f (Get-WtString -Key 'Cat.PlanSatisfiedHeader'))
            foreach ($Item in @($Plan.Satisfied)) { Write-Host ("  - {0}: {1}" -f $Item.Id, $Item.Reason) }
        }

        foreach ($Warning in @($Plan.Warnings)) { Write-Host ("  ! {0}" -f $Warning) }
        foreach ($Conflict in @($Plan.Conflicts)) { Write-Host ("  {0}: {1} / {2}" -f (Get-WtString -Key 'Cat.PlanConflicts'), $Conflict.Left, $Conflict.Right) }

        foreach ($Problem in @($Plan.Errors))
        {
            Write-Host ("{0}: {1}" -f (Get-WtString -Key 'Cat.PlanErrors'), $Problem)
        }

        Exit-WtEntryPoint -Code ($(if (@($Plan.Errors).Count -gt 0) { 1 } else { 0 }))
    }
    { $CatalogMigrations }
    {
        $Records = @(Get-WtTweakMigration)
        Write-Host ("{0}:" -f (Get-WtString -Key 'Cat.MigrationsHeader'))
        if ($Records.Count -eq 0)
        {
            Write-Host (Get-WtString -Key 'Cat.MigrationsNone')
        }
        else
        {
            foreach ($Record in $Records)
            {
                if ($Record.Kind -eq 'deprecate' -and -not $Record.To)
                {
                    Write-Host ("  " + (Get-WtString -Key 'Cat.MigrationRetiredRow' -Arguments @($Record.From, $Record.Reason)))
                    continue
                }

                Write-Host ("  " + (Get-WtString -Key 'Cat.MigrationRow' -Arguments @($Record.From, $Record.To, $Record.Kind, $(if ($Record.Since) { ", since $($Record.Since)" } else { '' }))))
                if ($Record.Reason) { Write-Host ("    {0}" -f $Record.Reason) }
            }
        }

        $Findings = @(Get-WtTweakMigration -Problems)
        Write-Host ("{0}:" -f (Get-WtString -Key 'Cat.MigrationProblemsHeader'))
        if ($Findings.Count -eq 0)
        {
            Write-Host (Get-WtString -Key 'Cat.MigrationNoProblems')
        }
        else
        {
            foreach ($Finding in $Findings) { Write-Host ("  - {0}: {1} ({2})" -f $Finding.Preset, $Finding.Id, $Finding.Reason) }
        }

        Exit-WtEntryPoint -Code 0
    }
    { $PackList }
    {
        $Packs = @(Get-WtTweakPack)
        Write-Host ("{0}:" -f (Get-WtString -Key 'Cat.PackListHeader'))
        if ($Packs.Count -eq 0)
        {
            Write-Host (Get-WtString -Key 'Cat.PackListEmpty')
            Exit-WtEntryPoint -Code 0
        }

        foreach ($Pack in $Packs)
        {
            $Enabled = if ($Pack.Enabled) { Get-WtString -Key 'Cat.Tui.PackEnabled' } else { Get-WtString -Key 'Cat.Tui.PackDisabled' }
            Write-Host ("  " + (Get-WtString -Key 'Cat.PackRow' -Arguments @(
                        $Pack.Id, $Pack.Version, $Pack.TweakCount, $Enabled, $Pack.Sha256.Substring(0, [Math]::Min(12, $Pack.Sha256.Length)))))
            Write-Host ("    {0}" -f $Pack.DocumentPath)
        }

        Exit-WtEntryPoint -Code 0
    }
    { $PackInspect }
    {
        $Pack = @(Get-WtTweakPack -Id $PackInspect)
        if ($Pack.Count -eq 0)
        {
            Write-Error -Message (Get-WtString -Key 'Cat.PackNotFound' -Arguments @($PackInspect))
            Exit-WtEntryPoint -Code 2
        }

        $Pack = $Pack[0]
        Write-Host ("{0} {1}" -f $Pack.Id, $Pack.Version)
        Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.PackLineAuthor'), $Pack.Author)
        Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.PackLineHash'), $Pack.Sha256)
        Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.PackLineImported'), $Pack.ImportedUtc)
        Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.PackLineSource'), $Pack.Source)
        Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.PackLineEnabled'), $(if ($Pack.Enabled) { Get-WtString -Key 'Cat.Tui.PackEnabled' } else { Get-WtString -Key 'Cat.Tui.PackDisabled' }))

        foreach ($TweakId in @($Pack.TweakIds))
        {
            $Definition = Get-WtTweakDefinition -Id $TweakId
            if (-not $Definition)
            {
                Write-Host ("  - {0} ({1})" -f $TweakId, (Get-WtString -Key 'Cat.PackTweakUnavailable'))
                continue
            }

            Write-Host ("  - {0}: {1} [{2}]" -f $TweakId, $Definition.DisplayName, $Definition.Risk)
        }

        Exit-WtEntryPoint -Code 0
    }
    { $PackImport }
    {
        # A switch on the command line is the instruction; the preview is -WhatIf, so the pack
        # functions must not ask again (a non-interactive run would fail at the prompt).
        $Result = Import-WtTweakPack -Path $PackImport -Enable:(-not $PackNoEnable) -Force:$PackForce -WhatIf:$DryRun -Confirm:$false

        if (@($Result.Errors).Count -gt 0)
        {
            foreach ($Problem in @($Result.Errors)) { Write-Error -Message $Problem }
            Exit-WtEntryPoint -Code 1
        }

        foreach ($Message in @($Result.Messages)) { Write-Host $Message }
        Exit-WtEntryPoint -Code 0
    }
    { $PackEnable }
    {
        $Result = Enable-WtTweakPack -Id $PackEnable -WhatIf:$DryRun -Confirm:$false
        if (@($Result.Errors).Count -gt 0) { foreach ($Problem in @($Result.Errors)) { Write-Error -Message $Problem }; Exit-WtEntryPoint -Code 1 }
        Write-Host (Get-WtString -Key 'Cat.PackEnabled' -Arguments @($Result.Id, @($Result.TweakIds).Count))
        Exit-WtEntryPoint -Code 0
    }
    { $PackDisable }
    {
        $Result = Disable-WtTweakPack -Id $PackDisable -WhatIf:$DryRun -Confirm:$false
        if (@($Result.Errors).Count -gt 0) { foreach ($Problem in @($Result.Errors)) { Write-Error -Message $Problem }; Exit-WtEntryPoint -Code 1 }
        Write-Host (Get-WtString -Key 'Cat.PackDisabled' -Arguments @($Result.Id, @($Result.TweakIds).Count))
        Exit-WtEntryPoint -Code 0
    }
    { $PackRemove }
    {
        $Result = Remove-WtTweakPack -Id $PackRemove -Force:$PackForce -WhatIf:$DryRun -Confirm:$false
        if (-not $Result.Removed)
        {
            foreach ($Problem in @($Result.Errors)) { Write-Error -Message $Problem }
            foreach ($Pending in @($Result.Pending)) { Write-Host ("  {0} {1}" -f $Pending.HistoryId, $Pending.TweakId) }
            Exit-WtEntryPoint -Code 1
        }

        Write-Host (Get-WtString -Key 'Cat.PackRemoved' -Arguments @($Result.Id, @($Result.Pending).Count))
        Exit-WtEntryPoint -Code 0
    }
    { $SanityScan }
    {
        $Rule = Expand-WtEntryPointList -Value $SanityRule
        # Not $Scan: that is this script's [string] parameter for the directory scan, and a
        # local of the same name would be coerced to a string.
        $ScanResult = Get-WtSanityScan -Rule $Rule -Export $SanityExport -Format $SanityFormat

        Write-Host (Get-WtString -Key 'Cat.Sanity.Title')
        Write-Host (Get-WtString -Key 'Cat.Sanity.ReadOnly')
        Write-Host $ScanResult.OutcomeLabel
        Write-Host (Get-WtString -Key 'Cat.Sanity.Summary' -Arguments @(
                $ScanResult.RuleCount,
                @($ScanResult.Rules | Where-Object { $_.Outcome -eq 'Findings' }).Count,
                @($ScanResult.Rules | Where-Object { $_.Outcome -eq 'Incomplete' }).Count,
                @($ScanResult.Rules | Where-Object { $_.Outcome -eq 'Unsupported' }).Count,
                $ScanResult.FindingCount))
        Write-Host ''

        if ($ScanResult.FindingCount -eq 0)
        {
            Write-Host (Get-WtString -Key 'Cat.Sanity.NoFindings')
        }

        foreach ($Finding in @($ScanResult.Findings))
        {
            Write-Host ("[{0}] {1} (r{2}) - {3}" -f $Finding.Severity, $Finding.RuleId, $Finding.Revision, $Finding.DisplayTitle)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.Target'), $Finding.Target)
            Write-Host ("  {0}: {1} ({2})" -f (Get-WtString -Key 'Cat.Sanity.Observed'), $Finding.Observed, $Finding.ObservedTypeLabel)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.Expected'), $Finding.DisplayExpected)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.WhyReview'), $Finding.DisplayRationale)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.EffectiveKind'), $Finding.EffectiveLabel)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.Conditions'), $Finding.ConditionsLabel)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.Remediation'), $Finding.RemediationLabel)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.Claim'), $Finding.Claim)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.Source'), $Finding.Source.Url)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.Limitations'), $Finding.DisplayLimitations)
            Write-Host ("  {0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.NextStep'), $Finding.DisplayNextStep)
            Write-Host ''
        }

        # An unknown rule id is reported rather than silently turning the scan into 'Unsupported':
        # "no rule applies" and "you asked for a rule that does not exist" are different answers.
        if (@($ScanResult.UnknownRules).Count -gt 0)
        {
            Write-Host (Get-WtString -Key 'Cat.Sanity.UnknownRules' -Arguments @((@($ScanResult.UnknownRules) -join ', ')))
        }

        Write-Host ("{0}: {1}" -f (Get-WtString -Key 'Cat.Sanity.Rules'), $ScanResult.RuleCount)

        if (@($ScanResult.Gaps).Count -gt 0)
        {
            Write-Host ("{0}:" -f (Get-WtString -Key 'Cat.Sanity.Gaps'))
            foreach ($Gap in @($ScanResult.Gaps))
            {
                Write-Host ('  ' + (Get-WtString -Key 'Cat.Sanity.Gap' -Arguments @($Gap.RuleId, $Gap.Outcome, $Gap.Reason)))
            }
        }

        Write-Host ''
        Write-Host ("{0}:" -f (Get-WtString -Key 'Cat.Sanity.PendingRestart'))
        foreach ($Marker in @($ScanResult.PendingRestart.Markers))
        {
            Write-Host ("  {0}: {1} - {2}" -f $Marker.Id, $Marker.MarkerLabel, $Marker.Detail)
        }

        if ($ScanResult.ExportedTo) { Write-Host (Get-WtString -Key 'Cat.Sanity.Exported' -Arguments @($ScanResult.ExportedTo)) }
        if ($ScanResult.ExportRefused) { Write-Host (Get-WtString -Key 'Cat.Tui.Sanity.ExportFailed' -Arguments @($ScanResult.ExportRefused)) }

        Exit-WtEntryPoint -Code ($(if ($ScanResult.Outcome -eq 'Findings') { 0 } elseif ($ScanResult.Outcome -eq 'Clean') { 0 } else { 1 }))
    }
    { $Recommend }
    {
        $Proposal = Get-WtRecommendation -Objective $Recommend -IncludeManual:$RecommendManual -IncludePreferences:$RecommendPreferences -Finding (Expand-WtEntryPointList -Value $RecommendFinding)

        Write-Host (Get-WtString -Key 'Cat.Tui.Rec.ObjectiveLine' -Arguments @($Proposal.Objective))
        Write-Host ("{0}: {1}" -f (Get-WtString -Key 'Rec.Objectives'), $Proposal.ObjectiveLabel)
        Write-Host (Get-WtString -Key 'Rec.NotApplied')
        Write-Host (Get-WtString -Key 'Cat.Tui.Rec.Summary' -Arguments @(
                $Proposal.Counts['Recommended'], $Proposal.Counts['AlreadySatisfied'], $Proposal.Counts['Excluded'],
                $Proposal.Counts['Unknown'], $Proposal.Counts['Blocked']))
        Write-Host ''

        if (@($Proposal.Recommended).Count -eq 0)
        {
            Write-Host (Get-WtString -Key 'Rec.NoneForObjective')
        }

        $DecisionLabel = @{
            'Recommended'     = (Get-WtString -Key 'Rec.Recommended')
            'AlreadySatisfied' = (Get-WtString -Key 'Rec.AlreadySatisfied')
            'Excluded'        = (Get-WtString -Key 'Rec.Excluded')
            'Unknown'         = (Get-WtString -Key 'Rec.Unknown')
            'Blocked'         = (Get-WtString -Key 'Rec.Blocked')
        }

        foreach ($Decision in 'Recommended', 'AlreadySatisfied', 'Blocked', 'Unknown', 'Excluded')
        {
            $Group = @($Proposal.Items | Where-Object { $_.Decision -eq $Decision })
            if ($Group.Count -eq 0) { continue }

            Write-Host ("{0} ({1}):" -f $DecisionLabel[$Decision], $Group.Count)
            foreach ($Item in $Group)
            {
                if ($Item.KindLabel)
                {
                    Write-Host (Get-WtString -Key 'Cat.Tui.Rec.Item' -Arguments @($Item.Decision, $Item.KindLabel, $Item.Id))
                }
                else
                {
                    Write-Host ('{0}  {1}' -f $Item.Decision, $Item.Id)
                }
                Write-Host ('    ' + $Item.Reason)
                if ($Item.Decision -eq 'Recommended' -and $Item.Rationale)
                {
                    Write-Host ('    ' + $Item.DisplayRationale)
                }

                if ($Item.Decision -in 'Recommended', 'AlreadySatisfied')
                {
                    Write-Host ('    ' + (Get-WtString -Key 'Cat.Tui.Rec.Evidence' -Arguments @($Item.EffectiveLabel, $Item.EffectiveEvidenceLabel)))
                    Write-Host ('    ' + (Get-WtString -Key 'Cat.Tui.Rec.Verification' -Arguments @($(if ($Item.VerificationLabel) { $Item.VerificationLabel } else { $Item.EffectiveEvidenceLabel }))))
                }
            }

            Write-Host ''
        }

        foreach ($Problem in @($Proposal.Errors)) { Write-Host ('  ! ' + $Problem) }

        if (-not $RecommendManual) { Write-Host (Get-WtString -Key 'Rec.ManualHint') }
        if (-not $RecommendPreferences) { Write-Host (Get-WtString -Key 'Rec.PreferenceHint') }

        Exit-WtEntryPoint -Code 0
    }
    { $Choices }
    {
        $Groups = @(Get-WtChoiceGroup)
        Write-Host (Get-WtString -Key 'Cat.Tui.Group')
        if ($Groups.Count -eq 0) { Write-Host (Get-WtString -Key 'Cat.Tui.Choices.Empty') }

        foreach ($Group in $Groups)
        {
            Write-Host ''
            Write-Host ("{0} [{1}] - {2}" -f $Group.DisplayLabel, $Group.Id, $Group.DisplayDescription)
            Write-Host ('  ' + (Get-WtString -Key 'Cat.Tui.Group.Current') + ': ' + $Group.CurrentLabel)
            foreach ($Option in @($Group.Options))
            {
                # A radio marker is the selection (nothing is pending in a one-shot inspection),
                # and the detected alternative is marked separately: live and chosen are different
                # questions.
                $Radio = if ($Option.Pending) { Get-WtString -Key 'Cat.Tui.Choices.RadioSelected' } else { Get-WtString -Key 'Cat.Tui.Choices.RadioEmpty' }
                $Mark = if ($Option.Detected) { Get-WtString -Key 'Cat.Tui.Group.Detected' } else { '' }
                Write-Host ('  ' + (Get-WtString -Key 'Cat.Tui.Choices.Option' -Arguments @("$Radio $($Option.DisplayLabel)", "$($Option.IntentLabel) $Mark").TrimEnd()))
            }
            Write-Host ('  ' + (Get-WtString -Key 'Cat.Tui.Group.ReplaceNote'))
            Write-Host ('  ' + (Get-WtString -Key 'Cat.Tui.Group.RestoreNote'))
        }

        Exit-WtEntryPoint -Code 0
    }
    { $Gui }
    {
        Start-WtGui -Language (Get-WtLanguage)
        Exit-WtEntryPoint -Code 0
    }
    { $RuntimeReport }
    {
        # Read-only: the profile, every capability and the command that runs on the
        # validated runtime. The same text on both runtimes, so it can be pasted into a
        # report from a Windows PowerShell 5.1 session.
        Write-Host $RuntimeInfo.Report
        Exit-WtEntryPoint -Code 0
    }
    default
    {
        $ExitCode = Start-WtTui -Language (Get-WtLanguage) -DryRun:$DryRun -Colour $Colour -Ascii:$Ascii -Icons $Icons -WorkerBackend $WorkerBackend -InputDiagnostics:$InputDiagnostics -Profile $PerfProfile
        Exit-WtEntryPoint -Code ([int]$ExitCode)
    }
}
