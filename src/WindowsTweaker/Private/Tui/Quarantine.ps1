# WindowsTweaker - terminal workflow for the journaled quarantine.
#
# Scan (read-only), review candidates with evidence, move selected ones into quarantine
# (same-volume only), inspect the manifest, restore, and permanently delete with explicit
# confirmation. Everything in this surface goes through the public quarantine API and the
# state store, so the durability rules (persist-before-move, revalidation, no silent
# overwrite, expiry = review only) are the same everywhere.

<#
.SYNOPSIS
    Shows the quarantine summary lines.
#>
function Get-WtTuiQuarantineSummaryLines
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    $Summary = Get-WtQuarantineSummary
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add((Get-WtString -Key 'Quar.Summary.Total' -Arguments @($Summary.Total)))
    $Lines.Add((Get-WtString -Key 'Quar.Summary.States' -Arguments @($Summary.Planned, $Summary.Moved, $Summary.Restored, $Summary.Deleted, $Summary.Unresolved, $Summary.Failed)))
    $Lines.Add((Get-WtString -Key 'Quar.Summary.Bytes' -Arguments @($Summary.MovedBytes, $Summary.FreedBytes)))
    if ($Summary.ExpiredReview -gt 0)
    {
        $Lines.Add((Get-WtString -Key 'Quar.Summary.Expired' -Arguments @($Summary.ExpiredReview)))
    }
    $Lines.Add((Get-WtString -Key 'Quar.Summary.Location' -Arguments @($Summary.Location)))
    return $Lines.ToArray()
}

<#
.SYNOPSIS
    Scans a directory and lets the user review candidates with evidence.
.DESCRIPTION
    Candidates are listed with their verdict and evidence; nothing is selected by default.
    The user picks with Space, and only the picked set is moved.
#>
function Show-WtTuiQuarantineScan
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Root = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Quar.Scan.Title') `
        -Label (Get-WtString -Key 'Quar.Scan.RootLabel') `
        -Lines @((Get-WtString -Key 'Quar.Scan.Hint')) -Validate {
            param ($Text)

            if ([string]::IsNullOrWhiteSpace($Text)) { return (Get-WtString -Key 'Tui.Path.Required') }
            $Trimmed = $Text.Trim()
            if (-not [System.IO.Path]::IsPathRooted($Trimmed)) { return (Get-WtString -Key 'Tui.Path.NotAbsolute') }
            if (-not (Test-Path -LiteralPath $Trimmed -PathType Container)) { return (Get-WtString -Key 'Worker.Reason.RootMissing' -Arguments @($Trimmed)) }
            return ''
        }

    if (-not $Root)
    {
        return
    }

    try
    {
        $Scan = Get-WtQuarantineCandidates -Root $Root
    }
    catch
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Quar.Title') -Lines @($_.Exception.Message) -Tone 'Error'
        return
    }

    $Items = [System.Collections.Generic.List[object]]::new()
    foreach ($Candidate in $Scan.Candidates)
    {
        $Verdict = Get-WtString -Key "Quar.Verdict.$($Candidate.Verdict)"
        $EvidenceText = (@($Candidate.Evidence | Where-Object { $_.Sign -eq 'Contradicting' } | Select-Object -First 2 | ForEach-Object { $_.Text }) -join ' | ')
        if (-not $EvidenceText)
        {
            $EvidenceText = (@($Candidate.Evidence | Where-Object { $_.Sign -eq 'Supporting' } | Select-Object -First 2 | ForEach-Object { $_.Text }) -join ' | ')
        }

        $Items.Add(@{
            Label    = [System.IO.Path]::GetFileName($Candidate.Path)
            Right    = "$Verdict | $($Candidate.SizeBytes) B"
            Payload  = $Candidate
            Filter   = "$($Candidate.Path) $Verdict $EvidenceText"
            Disabled = $false
            Checked  = $false
        })
    }

    $Lines = @(
        (Get-WtString -Key 'Quar.Scan.Root' -Arguments @($Root)),
        (Get-WtString -Key 'Quar.Scan.Spacer')
    )
    foreach ($Probe in $Scan.ProbesMissing)
    {
        $Lines += (Get-WtString -Key 'Quar.Scan.ProbeMissing' -Arguments @($Probe))
    }
    $Lines += (Get-WtString -Key 'Quar.Scan.ReviewHint')

    $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Quar.Scan.Title') `
        -Lines $Lines -Items $Items.ToArray() -Multi -Searchable -DetailsHeight 4

    if ($null -eq $Result)
    {
        return
    }

    $Selected = @($Result.Selected)
    if ($Selected.Count -eq 0)
    {
        return
    }

    $ConfirmLines = @(
        (Get-WtString -Key 'Quar.Confirm.Move' -Arguments @($Selected.Count, $Root)),
        (Get-WtString -Key 'Quar.Confirm.SameVolume'),
        (Get-WtString -Key 'Quar.Confirm.NotFreed')
    )

    if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Quar.Confirm.Title') -Lines $ConfirmLines -Tone 'Warning')
    {
        $Apply = Add-WtQuarantineEntries -Candidates $Selected -Root $Root -Confirm:$false
        $Message = if ($Apply.Moved -gt 0)
        {
            Get-WtString -Key 'Quar.Result.Moved' -Arguments @($Apply.Moved)
        }
        else
        {
            Get-WtString -Key 'Quar.Result.NotMoved' -Arguments @($Apply.Failed)
        }
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Quar.Title') -Lines @($Message) -Tone $(if ($Apply.Failed -gt 0) { 'Warning' } else { 'Success' })
    }
}

<#
.SYNOPSIS
    Shows the manifest and offers restore / permanent delete.
#>
function Show-WtTuiQuarantineManifest
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    while ($true)
    {
        $Manifest = Get-WtQuarantineManifest
        $Records = @($Manifest.Records)

        $Items = [System.Collections.Generic.List[object]]::new()
        foreach ($Record in $Records)
        {
            $StageText = Get-WtString -Key "Quar.Stage.$($Record.stage)"
            $SizeText = if ($Record.movedBytes) { "$($Record.movedBytes) B" } else { '-' }
            $Items.Add(@{
                Label    = [System.IO.Path]::GetFileName([string]$Record.sourcePath)
                Right    = "$StageText | $SizeText"
                Payload  = $Record
                Filter   = "$($Record.sourcePath) $StageText $($Record.outcome)"
                Disabled = $false
                Checked  = $false
            })
        }

        $Lines = Get-WtTuiQuarantineSummaryLines
        $Lines += (Get-WtString -Key 'Quar.Manifest.Hint')

        $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Quar.Manifest.Title') `
            -Lines $Lines -Items $Items -Multi -Searchable -EmptyText (Get-WtString -Key 'Quar.Manifest.Empty')

        if ($null -eq $Result)
        {
            return
        }

        $Selected = @($Result.Selected)
        if ($Selected.Count -eq 0)
        {
            return
        }

        # Decide the action: restore (default) or delete.
        $Action = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Quar.Manifest.ActionTitle') `
            -Lines @((Get-WtString -Key 'Quar.Manifest.ActionHint' -Arguments @($Selected.Count))) -Items @(
                @{ Label = (Get-WtString -Key 'Quar.Action.Restore'); Payload = 'restore'; Filter = 'restore'; Disabled = $false; Checked = $false }
                @{ Label = (Get-WtString -Key 'Quar.Action.Delete'); Payload = 'delete'; Filter = 'delete'; Disabled = $false; Checked = $false }
            ) -EmptyText (Get-WtString -Key 'Tui.NoItems')

        if ($null -eq $Action -or $null -eq $Action.Value)
        {
            continue
        }

        $Ids = @($Selected | Where-Object { $_.id } | ForEach-Object { [string]$_.id })

        if ($Action.Value -eq 'restore')
        {
            if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Quar.Restore.Title') `
                    -Lines @((Get-WtString -Key 'Quar.Restore.Confirm' -Arguments @($Ids.Count))) -Tone 'Warning')
            {
                $Result = Restore-WtQuarantineEntries -Id $Ids -Confirm:$false
                $Text = Get-WtString -Key 'Quar.Restore.Result' -Arguments @($Result.Restored, $Result.Unresolved)
                Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Quar.Title') -Lines @($Text) -Tone $(if ($Result.Unresolved -gt 0) { 'Warning' } else { 'Success' })
            }
        }
        elseif (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Quar.Delete.Title') `
                -Lines @(
                    (Get-WtString -Key 'Quar.Delete.Confirm' -Arguments @($Ids.Count)),
                    (Get-WtString -Key 'Quar.Delete.Irreversible')) -Tone 'Error')
        {
            $Result = Remove-WtQuarantineEntries -Id $Ids -Delete -Confirm:$false
            $Text = Get-WtString -Key 'Quar.Delete.Result' -Arguments @($Result.Removed, $Result.Failed)
            Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Quar.Title') -Lines @($Text) -Tone $(if ($Result.Failed -gt 0) { 'Warning' } else { 'Success' })
        }
    }
}

<#
.SYNOPSIS
    Opens the quarantine workflow: scan, manifest, restore or delete.
#>
function Show-WtTuiQuarantine
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    while ($true)
    {
        $Lines = Get-WtTuiQuarantineSummaryLines
        $Lines += (Get-WtString -Key 'Quar.Hint')

        $Items = @(
            @{ Label = (Get-WtString -Key 'Quar.Action.Scan'); Payload = 'scan'; Filter = 'scan'; Disabled = $false; Checked = $false }
            @{ Label = (Get-WtString -Key 'Quar.Action.Manifest'); Payload = 'manifest'; Filter = 'manifest'; Disabled = $false; Checked = $false }
        )

        $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Quar.Title') `
            -Lines $Lines -Items $Items -Searchable -EmptyText (Get-WtString -Key 'Tui.NoItems')

        if ($null -eq $Result -or $null -eq $Result.Value)
        {
            return
        }

        if ($Result.Value -eq 'scan')
        {
            Show-WtTuiQuarantineScan -State $State
        }
        else
        {
            Show-WtTuiQuarantineManifest -State $State
        }
    }
}
