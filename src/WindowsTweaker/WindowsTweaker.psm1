# WindowsTweaker root module.
#
# Loading order is explicit and deterministic:
#   1. Private\*.ps1            (shared helpers)
#   2. Private\Worker\*.ps1     (optional background worker client and its PowerShell fallback)
#   3. Private\Providers\*.ps1  (registry, services, tasks, DNS, Appx, Defender, installers)
#   3. Private\Tui\*.ps1        (terminal interface: theme, screen, input, dialogs, worker,
#                                workflows, main loop)
#   4. Public\*.ps1             (exported API)
#   5. Tweaks\**\*.ps1          (tweak definitions: metadata only)
#   6. Gui\*.ps1                (optional WPF front end, loaded on demand)
#
# Importing this module must not change any system setting. Tweak definition files
# only register metadata; detection and mutation happen when the caller asks for
# them. tests/Loading.Tests.ps1 asserts that importing the module writes no state
# and invokes no provider mutation.

$Script:WtExportModuleRoot = $PSScriptRoot

$PrivateRoot = Join-Path $PSScriptRoot 'Private'
$PublicRoot = Join-Path $PSScriptRoot 'Public'
$TweaksRoot = Join-Path $PSScriptRoot 'Tweaks'

<#
.SYNOPSIS
    Proves that a script file parses.
.DESCRIPTION
    A file that fails to parse must break the import loudly. Without this check
    PowerShell reports the parse error as a non-terminating error and silently loads
    the module without that file's definitions, which is exactly how the previous
    revision ended up with undefined helpers.
#>
function Assert-WtScriptParses
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Path)

    $Errors = $null
    $Tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$Errors)

    if ($Errors -and $Errors.Count -gt 0)
    {
        $Details = ($Errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
        throw "WindowsTweaker failed to load '$([System.IO.Path]::GetFileName($Path))': $Details"
    }
}

$LoadOrder = @(
    @(Get-ChildItem -Path $PrivateRoot -Filter '*.ps1' -File | Sort-Object -Property Name)
    @(Get-ChildItem -Path (Join-Path $PrivateRoot 'Worker') -Filter '*.ps1' -File | Sort-Object -Property Name)
    @(Get-ChildItem -Path (Join-Path $PrivateRoot 'Observability') -Filter '*.ps1' -File | Sort-Object -Property Name)
    @(Get-ChildItem -Path (Join-Path $PrivateRoot 'Catalog') -Filter '*.ps1' -File | Sort-Object -Property Name)
    @(Get-ChildItem -Path (Join-Path $PrivateRoot 'Insight') -Filter '*.ps1' -File | Sort-Object -Property Name)
    @(Get-ChildItem -Path (Join-Path $PrivateRoot 'Providers') -Filter '*.ps1' -File | Sort-Object -Property Name)
    @(Get-ChildItem -Path (Join-Path $PrivateRoot 'Tui') -Filter '*.ps1' -File | Sort-Object -Property Name)
    @(Get-ChildItem -Path $PublicRoot -Filter '*.ps1' -File | Sort-Object -Property Name)
    @(Get-ChildItem -Path $TweaksRoot -Filter '*.ps1' -File -Recurse | Sort-Object -Property FullName)
    @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Gui') -Filter '*.ps1' -File | Sort-Object -Property Name)
)

# Catalog support files load with the rest, but nothing is registered until
# Initialize-WtCatalog runs (below), after every definition is available.

# Validate everything up front so a syntax error can never be silently skipped.
foreach ($File in $LoadOrder)
{
    Assert-WtScriptParses -Path $File.FullName
}

# Dot-source in module scope (a definition made inside a helper function would only
# live in that function's scope).
foreach ($File in $LoadOrder)
{
    . $File.FullName
}

# Declarative catalog. Loaded after the PowerShell tweak definitions, so a document that
# collides with a built-in id is reported instead of silently replacing it. Loading only
# registers metadata: no detection, no preview and no mutation happens here.
$Script:WtCatalogLoad = $null

function Initialize-WtCatalog
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][switch]$Force)

    if ($Script:WtCatalogLoad -and -not $Force)
    {
        return $Script:WtCatalogLoad
    }

    $Directory = Join-Path $Script:WtDataDirectory 'Catalog'
    $Result = Import-WtCatalogDirectory -Path $Directory -Source 'BuiltIn'

    # Registered packs are loaded after the built-ins, so their namespaced ids can never
    # collide with a built-in one.
    $PackLoad = Import-WtTweakPackRegistry

    # The migration registry is loaded last: a migration may point at a tweak a pack
    # provides. Reading it never changes Windows and never rewrites a stored id.
    $MigrationLoad = Import-WtMigrationRegistry

    # Sanity rules are data too, and they describe read-only probes only.
    $RuleLoad = Import-WtSanityRuleRegistry

    $Script:WtCatalogLoad = @{
        Directory  = $Directory
        Registered = @($Result.Registered)
        Errors     = @($Result.Errors)
        Overlaps   = @($Result.Overlaps)
        Packs      = $PackLoad
        Migrations = $MigrationLoad
        Rules      = $RuleLoad
    }

    foreach ($Problem in @($Result.Errors))
    {
        Write-WtLog -Level Error -Message "Catalog: $Problem" -Operation 'Catalog' -Status 'failed'
    }

    # A built-in document is part of the module: if it does not load, tweaks are missing and
    # nothing else can be trusted, so this fails instead of quietly continuing with fewer.
    if (@($Result.Errors).Count -gt 0)
    {
        throw "The built-in catalog could not be loaded: $(@($Result.Errors) -join ' ')"
    }

    # Same for the shipped rules - unless the registry was pointed elsewhere on purpose, in
    # which case the scan reports the problems instead of breaking the module.
    if (@($RuleLoad.Errors).Count -gt 0)
    {
        if (-not $env:WT_RULES_PATH)
        {
            throw "The built-in sanity rules could not be loaded: $(@($RuleLoad.Errors) -join ' ')"
        }

        foreach ($Problem in @($RuleLoad.Errors))
        {
            Write-WtLog -Level Error -Message "Sanity rules: $Problem" -Operation 'Rules' -Status 'failed'
        }
    }

    return $Script:WtCatalogLoad
}

# Explicit public surface: everything else stays private to the module.
$PublicFunctions = @(
    # environment, runtime and catalog queries
    'Get-WtRuntimeInfo'
    'Get-WtEnvironment'
    'Get-WtTweak'
    'Get-WtCategory'
    'Get-WtNetworkAdapter'
    'Get-WtWindowsFeature'
    'Get-WtWindowsCapability'
    'Test-WtPrerequisite'
    'Get-WtTweakState'

    # changes
    'Invoke-WtTweak'
    'Undo-WtTweak'
    'New-WtRestorePoint'

    # sanity scan, recommendations, state dimensions and choice groups
    'Get-WtSanityRule'
    'Get-WtSanityScan'
    'Get-WtRecommendationObjective'
    'Get-WtRecommendation'
    'Get-WtPendingRestart'
    'Get-WtTweakDimensions'
    'Get-WtChoiceGroup'

    # declarative catalog, packs, planning and migrations
    'Test-WtCatalogFile'
    'Get-WtTweakDefinition'
    'Get-WtTweakDefinitionView'
    'Get-WtDependencyPlan'
    'Get-WtTweakMigration'
    'Get-WtTweakPack'
    'Import-WtTweakPack'
    'Enable-WtTweakPack'
    'Disable-WtTweakPack'
    'Remove-WtTweakPack'
    'Get-WtCapabilityLoss'

    # presets
    'Get-WtPreset'
    'Import-WtPreset'
    'Export-WtPreset'

    # read-only device inventory
    'Get-WtDeviceInventory'

    # monitoring workspace (collector run with loop)
    'Invoke-WtMonitorCycle'
    'Get-WtDashboardList'
    'Get-WtDashboard'
    'Import-WtDashboard'
    'Export-WtDashboard'
    'Get-WtMonitorDefaults'
    'Measure-WtMonitorCycle'
    'Enable-WtMetricRecording'
    'Disable-WtMetricRecording'
    'Get-WtMetricRecording'
    'Get-WtStoredMetricRange'

    # privacy profile and activity views (read-only)
    'Get-WtPrivacySummary'
    'Get-WtPowerSettings'
    'Get-WtSrumHistory'
    'Get-WtPrivacyActivity'

    # checkpointed setup workflows
    'Get-WtSetupPlan'
    'New-WtSetupPlan'
    'Export-WtSetupPlan'
    'Import-WtSetupPlan'
    'Get-WtSetupPlanPreview'
    'Start-WtSetupPlan'
    'Resume-WtSetupPlan'
    'Remove-WtSetupPlanResume'

    # journaled quarantine
    'Get-WtQuarantineCandidates'
    'Get-WtQuarantineManifest'
    'Add-WtQuarantineEntries'
    'Restore-WtQuarantineEntries'
    'Remove-WtQuarantineEntries'
    'Get-WtQuarantineSummary'

    # change verification and recovery
    'Get-WtChangePreview'
    'Get-WtChangeConflict'
    'Get-WtDrift'
    'Get-WtOperation'
    'Get-WtSession'
    'Close-WtSession'
    'Get-WtInterruptedOperation'
    'Get-WtRestorePlan'
    'Export-WtHistory'
    'Undo-WtSession'
    # optional restart after a completed batch
    'Test-WtRestartRequest'
    'Invoke-WtBatchRestart'
    # read-only licensing & activation diagnostics
    'Get-WtLicensingDiagnostics'
    'Get-WtLicensingHealth'
    'Export-WtLicensingDiagnostics'
    'Request-WtLicensingActivation'
    'Export-WtDiagnostics'
    'Measure-WtNetworkDiagnostics'
    'Compare-WtMeasurements'

    # optional background worker
    'Invoke-WtDirectoryScan'
    'Get-WtDirectoryChildren'
    'Get-WtWorkerStatus'
    'Set-WtWorkerBackend'
    'Measure-WtWorkerOverhead'
    'Get-WtWorkerBackendSummary'

    # session data
    'Get-WtHistory'
    'Get-WtLogPath'
    'Get-WtStatePath'
    'Export-WtReport'

    # localization
    'Get-WtLanguage'
    'Set-WtLanguage'
    'Get-WtString'

    # user interfaces
    'Start-WtTui'
    'Start-WtGui'
)

Initialize-WtCatalog | Out-Null

Export-ModuleMember -Function $PublicFunctions
