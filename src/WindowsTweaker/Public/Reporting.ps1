# WindowsTweaker - session state queries, reporting and restore points (public API).

<#
.SYNOPSIS
    Returns the recorded change history (newest first).
.PARAMETER TweakId
    Filter by tweak.
.PARAMETER Limit
    Maximum entries to return.
.PARAMETER Raw
    Return the raw history entries, including the captured records.
#>
function Get-WtHistory
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][int]$Limit = 50,
        [Parameter(Mandatory = $false)][switch]$Raw,
        [Parameter(Mandatory = $false)][switch]$IncludeDryRun
    )

    $Entries = Get-WtHistoryEntry -TweakId $TweakId -Limit $Limit -IncludeDryRun:$IncludeDryRun

    if ($Raw)
    {
        return $Entries
    }

    foreach ($Entry in $Entries)
    {
        [pscustomobject]@{
            PSTypeName    = 'WindowsTweaker.HistoryEntry'
            HistoryId     = $Entry.historyId
            TweakId       = $Entry.tweakId
            State         = $Entry.state
            Outcome       = $Entry.outcome
            Timestamp     = $Entry.timestamp
            RolledBack    = [bool]$Entry.rolledBack
            RolledBackAt  = $Entry.rolledBackAt
            RecordCount   = @($Entry.records).Count
            Irreversible  = (@($Entry.records | Where-Object { $_.irreversible -eq $true }).Count -gt 0)
            Messages      = @($Entry.messages)
        }
    }
}

<#
.SYNOPSIS
    Creates a System Restore point (optional, never implicit).
.DESCRIPTION
    Supplementary to the per-change state capture; it is not a substitute for it.
    Requires elevation and System Protection to be enabled; both failure modes are
    reported rather than thrown.
#>
function New-WtRestorePoint
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $false)][string]$Description = 'WindowsTweaker')

    $Operation = 'RestorePoint'

    if (-not $IsWindows)
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Message 'Restore points are only available on Windows.'
    }

    if (-not $PSCmdlet.ShouldProcess($Description, 'create a System Restore point'))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Message "Would create a restore point: $Description"
    }

    $Command = Get-Command -Name Checkpoint-Computer -ErrorAction Ignore
    if (-not $Command)
    {
        $Message = Get-WtString -Key 'RestorePoint.Unavailable'
        Write-WtLog -Level Warning -Message $Message -Operation $Operation -Status 'unsupported'
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Message $Message
    }

    try
    {
        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    }
    catch
    {
        $Message = Get-WtString -Key 'RestorePoint.Unavailable'
        Write-WtLog -Level Warning -Message $Message -Operation $Operation -Status 'failed' -Exception $_.Exception
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Message $Message -ErrorRecord $_
    }

    $Final = Get-WtString -Key 'RestorePoint.Created' -Arguments @($Description)
    Write-WtLog -Message $Final -Operation $Operation -Status 'succeeded'
    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Message $Final
}

<#
.SYNOPSIS
    Exports the environment, catalog and history as a JSON or Markdown report.
.PARAMETER Path
    Destination file. Defaults to <data root>\reports\WindowsTweaker-report-<timestamp>.json
.PARAMETER Format
    Json or Markdown.
#>
function Export-WtReport
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][string]$Path,
        [Parameter(Mandatory = $false)][ValidateSet('Json', 'Markdown')][string]$Format = 'Json'
    )

    $Environment = Get-WtEnvironment
    $States = @(Get-WtTweakState)

    $Report = [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        tool        = 'WindowsTweaker'
        environment = $Environment
        language    = Get-WtLanguage
        history     = @(Get-WtHistory -Limit 200)
        tweaks      = @($States | Select-Object Id, Category, Name, State, Supported, UnsupportedReason, Managed, ManagedBy, Risk, Restart, Rollback, Irreversible, DataDeletion, Requires)
    }

    if (-not $Path)
    {
        $Directory = Join-Path (Get-WtDataRoot) 'reports'
        New-WtDirectory -Path $Directory
        $Extension = if ($Format -eq 'Json') { 'json' } else { 'md' }
        $Path = Join-Path $Directory ('WindowsTweaker-report-{0}.{1}' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $Extension)
    }

    if ($Format -eq 'Json')
    {
        ($Report | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $Path -Encoding utf8NoBOM -Force
    }
    else
    {
        $Lines = [System.Collections.Generic.List[string]]::new()
        $Lines.Add('# WindowsTweaker report')
        $Lines.Add('')
        $Lines.Add("- Generated: $($Report.generatedAt)")
        $Lines.Add("- PowerShell: $($Environment.PowerShell) (required: $($Environment.RequiredPowerShell))")
        $Lines.Add("- OS: $($Environment.OSName) build $($Environment.OSBuild).$($Environment.OSUBR) ($($Environment.OSVersionKey))")
        $Lines.Add("- Elevated: $($Environment.IsAdmin)")
        $Lines.Add("- Language: $($Report.language)")
        $Lines.Add('')
        $Lines.Add('| Tweak | Category | State | Supported | Rollback | Managed |')
        $Lines.Add('|---|---|---|---|---|---|')
        foreach ($Tweak in $Report.tweaks)
        {
            $Lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $Tweak.Id, $Tweak.Category, $Tweak.State, $Tweak.Supported, $Tweak.Rollback, $Tweak.Managed))
        }
        $Lines.Add('')
        $Lines.Add('## History')
        $Lines.Add('')
        foreach ($Entry in $Report.history)
        {
            $Lines.Add(('- {0} {1} {2} -> {3}{4}' -f $Entry.Timestamp, $Entry.TweakId, $Entry.State, $Entry.Outcome, $(if ($Entry.RolledBack) { ' (rolled back)' } else { '' })))
        }

        $Lines | Set-Content -LiteralPath $Path -Encoding utf8NoBOM -Force
    }

    return $Path
}
