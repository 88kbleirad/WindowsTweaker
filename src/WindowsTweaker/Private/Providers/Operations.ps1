# WindowsTweaker - operation context, result objects and shared plumbing used by
# every provider.
#
# The context carries the active history entry (for pre-change state capture) and
# the dry-run flag. It is module-scoped state, set by Invoke-WtTweak / Undo-WtTweak
# and cleared in a finally block, so an interruption can never leave a stale entry
# attached to unrelated writes.

$Script:WtOperationContext = @{
    HistoryEntry    = $null
    DryRun          = $false
    Phase           = 'none'   # apply | rollback | none
    SuppressConfirm = $false   # true while a tweak apply/rollback orchestrates providers
}

<#
.SYNOPSIS
    Returns the active operation context.
#>
function Get-WtOperationContext
{
    [CmdletBinding()]
    param ()

    return $Script:WtOperationContext
}

<#
.SYNOPSIS
    Sets the active operation context.
#>
function Set-WtOperationContext
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][object]$HistoryEntry,
        [Parameter(Mandatory = $false)][bool]$DryRun = $false,
        [Parameter(Mandatory = $false)][string]$Phase = 'none',
        [Parameter(Mandatory = $false)][bool]$SuppressConfirm = $false
    )

    $Script:WtOperationContext = @{
        HistoryEntry    = $HistoryEntry
        DryRun          = $DryRun
        Phase           = $Phase
        SuppressConfirm = $SuppressConfirm
    }
}

<#
.SYNOPSIS
    Builds a structured per-operation result.
.DESCRIPTION
    Status values, used consistently across every provider:
      succeeded   - change applied and verified
      unchanged   - already in the requested state, nothing written
      skipped     - not performed (e.g. -Confirm answered No)
      dryrun      - -WhatIf / dry run: nothing was written
      unsupported - dependency or platform missing, nothing attempted
      failed      - attempted and did not work (or failed verification)
#>
function New-WtOperationResult
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet('succeeded', 'unchanged', 'skipped', 'dryrun', 'unsupported', 'failed')]
        [string]$Status,

        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $false)][string]$Target,
        [Parameter(Mandatory = $false)][string]$Message = '',
        [Parameter(Mandatory = $false)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $false)][switch]$PartialRollback,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Full', 'Partial', 'None')]
        [string]$Rollback = 'Full'
    )

    return [pscustomobject]@{
        PSTypeName      = 'WindowsTweaker.OperationResult'
        Status          = $Status
        Operation       = $Operation
        Target          = $Target
        Message         = $Message
        Error           = $ErrorRecord
        PartialRollback = [bool]$PartialRollback
        Rollback        = if ($PartialRollback) { 'Partial' } else { $Rollback }
    }
}

<#
.SYNOPSIS
    Distinguishes "-WhatIf" from "the user answered No at a -Confirm prompt".
#>
function Get-WtShouldProcessStatus
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($WhatIfPreference)
    {
        return 'dryrun'
    }

    return 'skipped'
}

<#
.SYNOPSIS
    Aggregates operation results into one overall status.
.DESCRIPTION
    Precedence reflects what the user must know:
      failed beats everything; anything actually written beats dry-run noise.
#>
function Get-WtAggregateStatus
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object[]]$Results = @())

    $Statuses = @($Results | ForEach-Object { $_.Status })

    if ($Statuses -contains 'failed') { return 'failed' }
    if ($Statuses -contains 'succeeded') { return 'succeeded' }

    # Nothing was written: "would change" outranks "nothing to do", otherwise a dry
    # run of a multi-operation tweak could look like a no-op.
    if ($Statuses -contains 'dryrun') { return 'dryrun' }
    if ($Statuses -contains 'skipped') { return 'skipped' }
    if ($Statuses -contains 'unchanged') { return 'unchanged' }
    if ($Statuses -contains 'unsupported') { return 'unsupported' }

    return 'unchanged'
}
