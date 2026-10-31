# WindowsTweaker - public quarantine API (read-only scan, planned moves, restore, explicit
# delete). All of it builds on the private quarantine module and the existing state store.

<#
.SYNOPSIS
    Scans a directory for leftover candidates, with evidence, read-only.
.DESCRIPTION
    Nothing is selected, moved or deleted here. Each candidate carries its evidence, a
    verdict (Orphaned, InUse, Uncertain, Unknown) and its logical size at scan time.
    Probes that could not run (processes or services on a machine without the needed
    cmdlets) are reported, never assumed.
.PARAMETER Root
    Directory to scan (its direct children are the candidates).
.PARAMETER RecentDays
    How recent a modification counts as "recent activity" (default 14).
.EXAMPLE
    Get-WtQuarantineCandidates -Root $env:LOCALAPPDATA
#>
function Get-WtQuarantineCandidates
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][int]$RecentDays = 14
    )

    return (Get-WtQuarantineScanInternal -Root $Root -RecentDays $RecentDays)
}

<#
.SYNOPSIS
    Returns the durable quarantine manifest from the state store.
#>
function Get-WtQuarantineManifest
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ()

    $Manifest = Read-WtQuarantineManifest
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.QuarantineManifest'
        Records    = @($Manifest.Records)
        Meta       = $Manifest.Meta
    }
}

<#
.SYNOPSIS
    Moves explicitly selected candidates into quarantine.
.DESCRIPTION
    The recovery intent is persisted before anything moves (stage 'planned'), every source
    is revalidated against its stored fingerprint and the approved root immediately before
    the move, and only same-volume moves run; cross-volume cases are skipped with the
    reason. This is not a deletion: moved bytes are reported separately from freed bytes.
.PARAMETER Candidates
    Candidate objects from Get-WtQuarantineCandidates.
.PARAMETER Root
    The root the candidates were scanned from (boundary for the moves).
.PARAMETER WhatIf
    Show what would move without moving anything.
#>
function Add-WtQuarantineEntries
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Candidates,
        [Parameter(Mandatory = $true)][string]$Root
    )

    if (-not $WhatIfPreference -and -not $PSCmdlet.ShouldProcess("$($Candidates.Count) candidate(s)", 'quarantine (move into quarantine storage)'))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.QuarantineResult'
            Records    = @()
            Moved      = 0
            Failed     = 0
            Skipped    = 0
            FreedBytes = 0
        }
    }

    $Result = Invoke-WtQuarantineInternal -Candidates $Candidates -Root $Root -DryRun:$WhatIfPreference
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.QuarantineResult'
        Records    = @($Result.Records)
        Moved      = $Result.Moved
        Failed     = $Result.Failed
        Skipped    = $Result.Skipped
        FreedBytes = 0
    }
}

<#
.SYNOPSIS
    Restores quarantined candidates to their original paths.
.DESCRIPTION
    Refuses to overwrite an existing destination unless -Overwrite is given explicitly.
    Missing or changed quarantined content keeps the record unresolved for retry.
.PARAMETER Id
    Manifest record ids to restore.
#>
function Restore-WtQuarantineEntries
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][string[]]$Id,
        [Parameter(Mandatory = $false)][switch]$Overwrite
    )

    if ($PSCmdlet.ShouldProcess("$($Id.Count) record(s)", 'restore from quarantine'))
    {
        $Result = Restore-WtQuarantineInternal -Ids $Id -Overwrite:$Overwrite
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.QuarantineRestoreResult'
            Records    = @($Result.Records)
            Restored   = $Result.Restored
            Failed     = $Result.Failed
            Unresolved = $Result.Unresolved
        }
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.QuarantineRestoreResult'
        Records    = @()
        Restored   = 0
        Failed     = 0
        Unresolved = 0
    }
}

<#
.SYNOPSIS
    Permanently deletes quarantined content (explicit, confirmed).
.DESCRIPTION
    The only operation that frees the quarantined bytes. It never runs at startup; expired
    records are only flagged for review, never deleted.
.PARAMETER Id
    Manifest record ids to delete.
.PARAMETER Delete
    Must be passed explicitly; this is a destructive, irreversible confirmation.
#>
function Remove-WtQuarantineEntries
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][string[]]$Id,
        [Parameter(Mandatory = $true)][switch]$Delete
    )

    if ($Delete -and $PSCmdlet.ShouldProcess("$($Id.Count) record(s)", 'permanently delete quarantined content'))
    {
        $Result = Remove-WtQuarantineInternal -Ids $Id -Delete
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.QuarantineDeleteResult'
            Records    = @($Result.Records)
            Removed    = $Result.Removed
            Failed     = $Result.Failed
        }
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.QuarantineDeleteResult'
        Records    = @()
        Removed    = 0
        Failed     = 0
    }
}

<#
.SYNOPSIS
    Summary of the quarantine manifest (counts and bytes, reported separately).
#>
function Get-WtQuarantineSummary
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ()

    $Manifest = Read-WtQuarantineManifest
    $Records = @($Manifest.Records)

    $Moved = @($Records | Where-Object { $_.stage -in 'moved', 'verified', 'restored', 'deleted' })
    $MovedBytes = [long](($Moved | Measure-Object -Property movedBytes -Sum).Sum)

    $Expired = @($Records | Where-Object {
            $_.movedAt -and ([datetime]$_.movedAt) -lt (Get-Date).ToUniversalTime().AddDays(-90)
        })

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.QuarantineSummary'
        Total      = $Records.Count
        Planned    = @($Records | Where-Object { $_.stage -eq 'planned' }).Count
        Moved      = @($Records | Where-Object { $_.stage -in 'moved', 'verified' }).Count
        Restored   = @($Records | Where-Object { $_.stage -eq 'restored' }).Count
        Deleted    = @($Records | Where-Object { $_.stage -eq 'deleted' }).Count
        Unresolved = @($Records | Where-Object { $_.stage -eq 'unresolved' }).Count
        Failed     = @($Records | Where-Object { $_.stage -eq 'failed' }).Count
        ExpiredReview = $Expired.Count
        MovedBytes = $MovedBytes
        FreedBytes = 0
        Location   = (Get-WtQuarantineLocation).Storage
    }
}
