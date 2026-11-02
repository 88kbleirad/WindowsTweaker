# WindowsTweaker - shared licensing & activation state for the TUI.
#
# One authoritative, refreshed licensing snapshot is owned by the licensing workspace and
# shared with the activation settings & details screen and the footer. This module owns the
# small per-session fields that go with it:
#
#   * the current observed licensing snapshot (the machine's state, read from the provider);
#   * the latest activation operation outcome (what the last A/T run reported), which is
#     deliberately different from the machine's current state;
#   * whether an activation operation ran in this app session (the R session flag);
#   * the collection time and the stale/unreadable state, which travel with the snapshot.
#
# The four stay separate: "nothing run in this session" is never presented as "Windows is
# not activated", and a permission is never presented as a status.

<#
.SYNOPSIS
    Returns the shared licensing state stored in the workspace state, creating it on first use.
.DESCRIPTION
    Initialized with explicit nulls so every consumer sees the same shape. The objects here
    are read by the workspace when it (re)reads the provider, and never without one.
#>
function Get-WtLicensingUiState
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.LicensingUi)
    {
        $State.LicensingUi = [ordered]@{
            License = $null
            LicenseCollectionUtc = $null
            LicenseRaw = $null
            LicenseStale = $false
            LicenseContributing = $null
            OperationOutcome = ''
            OperationRanThisSession = $false
            OperationLastUtc = $null
            OperationPollRemaining = 0
            OperationPollNextUtc = $null
        }
    }

    return $State.LicensingUi
}

<#
.SYNOPSIS
    Stores the refreshed licensing snapshot and its collection time.
.DESCRIPTION
    The snapshot is the one object every view paints from. The raw status code is kept
    apart from the display status, and the collection UTC is kept apart from the "now"
    the view computes when it decides whether the snapshot is stale.
#>
function Set-WtLicensingUiSnapshot
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][AllowNull()][object]$License,
        [Parameter(Mandatory = $false)][AllowNull()][object]$RawStatus = $null
    )

    $Ui = Get-WtLicensingUiState -State $State
    $Ui.License = $License
    $Ui.LicenseCollectionUtc = if ($License -and $License.CollectedUtc) { [datetime]$License.CollectedUtc } else { $null }
    $Ui.LicenseRaw = $RawStatus
    $Ui.LicenseStale = $false
    $Ui.LicenseContributing = $null
}

<#
.SYNOPSIS
    Marks the shared snapshot as stale (a newer refresh is in flight or failed).
#>
function Set-WtLicensingUiStale
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][string]$Reason = ''
    )

    $Ui = Get-WtLicensingUiState -State $State
    $Ui.LicenseStale = $true
    $Ui.LicenseContributing = $Reason
}

<#
.SYNOPSIS
    Records the outcome of one activation operation and marks the session flag.
.DESCRIPTION
    This is the latest *operation* outcome, never the machine's current status. Renaming
    the action or selecting a different activation method does not touch it.
#>
function Set-WtLicensingUiOperation
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Outcome,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Utc = $null
    )

    $Ui = Get-WtLicensingUiState -State $State
    $Ui.OperationOutcome = $Outcome
    $Ui.OperationRanThisSession = $true
    $Ui.OperationLastUtc = if ($Utc) { [datetime]$Utc } else { [datetime]::UtcNow }
}
