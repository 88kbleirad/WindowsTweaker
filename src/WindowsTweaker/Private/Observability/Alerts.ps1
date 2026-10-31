# WindowsTweaker - local alert rules (declarative, allowlisted).
#
# A rule is data: a metric id from the allowlist, an operator, a threshold, a sustained
# hold duration, an optional hysteresis recovery threshold, a severity and a localized
# explanation. Evaluation is read-only and never touches system state.
#
# States: normal -> pending (condition held for the duration) -> firing; firing returns
# to resolved when the recovery condition is met (hysteresis), or to normal when the
# condition clears without having fired. Missing data never resolves an alert: the
# explicit missing behavior applies instead. Acknowledge and mute are separate flags kept
# per rule/instance; they never resolve anything and never apply changes.

$Script:WtAlertOperators = @('gt', 'ge', 'lt', 'le')
$Script:WtAlertSeverities = @('low', 'medium', 'high')
$Script:WtAlertStates = @('normal', 'pending', 'firing', 'resolved', 'unknown')

<#
.SYNOPSIS
    Creates the default alert rule set (data).
#>
function Get-WtDefaultAlertRules
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ()

    return @(
        [pscustomobject]@{
            id = 'system-disk-low'
            metric = 'host.disk.system.freeBytes'
            operator = 'lt'
            threshold = 5GB
            durationSeconds = 30
            hysteresis = 10GB
            severity = 'high'
            explanationKey = 'Mon.Alert.Rule.LowDisk'
        }
        [pscustomobject]@{
            id = 'collector-stale'
            metric = 'host.collector.ageSeconds'
            operator = 'gt'
            threshold = 30
            durationSeconds = 15
            hysteresis = 10
            severity = 'medium'
            explanationKey = 'Mon.Alert.Rule.Stale'
        }
        [pscustomobject]@{
            id = 'ops-verification-failed'
            metric = 'ops.verification.failed'
            operator = 'gt'
            threshold = 0
            durationSeconds = 10
            hysteresis = 0
            severity = 'medium'
            explanationKey = 'Mon.Alert.Rule.Verify'
        }
        [pscustomobject]@{
            id = 'ops-interrupted'
            metric = 'ops.interrupted'
            operator = 'gt'
            threshold = 0
            durationSeconds = 10
            hysteresis = 0
            severity = 'medium'
            explanationKey = 'Mon.Alert.Rule.Interrupted'
        }
        [pscustomobject]@{
            id = 'ops-drift'
            metric = 'ops.drift'
            operator = 'gt'
            threshold = 0
            durationSeconds = 10
            hysteresis = 0
            severity = 'low'
            explanationKey = 'Mon.Alert.Rule.Drift'
        }
    )
}

<#
.SYNOPSIS
    Evaluates all rules against the current metric view and the alert state.
.DESCRIPTION
    The evaluator is pure: it takes the latest sample per metric (or $null), the current
    per-rule state, and the current time; it returns new states. Sustained holds use the
    time the condition first became true and the hold duration; a condition that drops
    before the hold returns to normal. Firing returns to resolved only when the recovery
    threshold (hysteresis) is met, never when data disappears.
#>
function Invoke-WtAlertEvaluation
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Rules,
        [Parameter(Mandatory = $true)][hashtable]$LatestByMetric,
        [Parameter(Mandatory = $false)][hashtable]$State = $null,
        [Parameter(Mandatory = $false)][long]$NowMs = 0
    )

    if (-not $NowMs) { $NowMs = [int64]([datetime]::UtcNow.ToUniversalTime() - [datetime]::new(1970,1,1,0,0,0,[datetimekind]::Utc)).TotalMilliseconds }
    if (-not $State) { $State = @{} }

    $Results = [System.Collections.Generic.List[object]]::new()

    foreach ($Rule in $Rules)
    {
        $Id = [string]$Rule.id
        if (-not $State.ContainsKey($Id))
        {
            $State[$Id] = @{
                state = 'normal'
                sinceMs = 0
                firstConditionMs = 0
                ack = $false
                muted = $false
            }
        }
        $Current = $State[$Id]

        $Sample = $LatestByMetric[[string]$Rule.metric]
        $Value = $null
        if ($Sample -and ([string]$Sample.quality -eq 'valid') -and $null -ne $Sample.value)
        {
            $Value = [double]$Sample.value
        }

        $Condition = $false
        if ($null -ne $Value)
        {
            switch ([string]$Rule.operator)
            {
                'gt' { $Condition = $Value -gt [double]$Rule.threshold }
                'ge' { $Condition = $Value -ge [double]$Rule.threshold }
                'lt' { $Condition = $Value -lt [double]$Rule.threshold }
                'le' { $Condition = $Value -le [double]$Rule.threshold }
            }
        }

        $HoldMs = [long]([double]$Rule.durationSeconds * 1000)
        $Recovery = [double]$Rule.hysteresis

        switch ([string]$Current.state)
        {
            'normal'
            {
                if ($Condition)
                {
                    if (-not $Current.firstConditionMs) { $Current.firstConditionMs = $NowMs }
                    if (($NowMs - $Current.firstConditionMs) -ge $HoldMs)
                    {
                        $Current.state = 'firing'
                        $Current.sinceMs = $NowMs
                    }
                    else
                    {
                        $Current.state = 'pending'
                        $Current.sinceMs = $NowMs
                    }
                }
                else
                {
                    $Current.firstConditionMs = 0
                }
            }
            'pending'
            {
                if ($Condition)
                {
                    if (($NowMs - $Current.firstConditionMs) -ge $HoldMs)
                    {
                        $Current.state = 'firing'
                        $Current.sinceMs = $NowMs
                    }
                }
                else
                {
                    $Current.state = 'normal'
                    $Current.firstConditionMs = 0
                }
            }
            'firing'
            {
                # Recovery only via hysteresis; missing data never resolves.
                if ($null -ne $Value)
                {
                    $Recovered = switch ([string]$Rule.operator)
                    {
                        'gt' { $Value -le $Recovery }
                        'ge' { $Value -lt $Recovery }
                        'lt' { $Value -ge $Recovery }
                        'le' { $Value -gt $Recovery }
                    }
                    if ($Recovered)
                    {
                        $Current.state = 'resolved'
                        $Current.sinceMs = $NowMs
                        $Current.firstConditionMs = 0
                    }
                }
            }
            'resolved'
            {
                if ($Condition)
                {
                    # Re-enter through pending, not instantly firing.
                    $Current.state = 'pending'
                    $Current.firstConditionMs = $NowMs
                    $Current.sinceMs = $NowMs
                }
                elseif ($null -ne $Value)
                {
                    $Current.state = 'normal'
                }
            }
        }

        $Results.Add([pscustomobject]@{
            PSTypeName = 'WindowsTweaker.Alert'
            id = $Id
            metric = [string]$Rule.metric
            operator = [string]$Rule.operator
            threshold = [double]$Rule.threshold
            hysteresis = [double]$Rule.hysteresis
            durationSeconds = [int]$Rule.durationSeconds
            severity = [string]$Rule.severity
            explanationKey = [string]$Rule.explanationKey
            state = [string]$Current.state
            sinceMs = $Current.sinceMs
            ack = [bool]$Current.ack
            muted = [bool]$Current.muted
            value = $Value
            missing = ($null -eq $Value)
        })
    }

    return @($Results.ToArray())
}

<#
.SYNOPSIS
    Summarizes the active (firing + pending) alert count.
#>
function Get-WtActiveAlertCount
{
    [CmdletBinding()]
    [OutputType([int])]
    param ([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Alerts)

    return @($Alerts | Where-Object { $_.state -in 'pending', 'firing' -and -not $_.muted }).Count
}
