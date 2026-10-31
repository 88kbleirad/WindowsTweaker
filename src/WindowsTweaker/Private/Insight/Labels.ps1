# WindowsTweaker - labels for the insight surfaces.
#
# Every string key is named literally here rather than composed at the call site. Two reasons:
# a rendered label is a table lookup, so keeping the literals in one place makes the key set
# reviewable, and the string-table tests can then check that every key exists in English and
# Vietnamese instead of only at run time.

<#
.SYNOPSIS
    Localized label for one configured/effective/ownership dimension value.
#>
function Get-WtDimensionLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('Configured', 'Effective', 'Ownership', 'Evidence')][string]$Dimension,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if (-not $Value) { $Value = 'Unknown' }

    switch ($Dimension)
    {
        'Configured'
        {
            switch ($Value)
            {
                'Matches' { return (Get-WtString -Key 'Cat.Tui.Configured.Matches') }
                'Differs' { return (Get-WtString -Key 'Cat.Tui.Configured.Differs') }
                'Mixed' { return (Get-WtString -Key 'Cat.Tui.Configured.Mixed') }
                'Absent' { return (Get-WtString -Key 'Cat.Tui.Configured.Absent') }
                'Unreadable' { return (Get-WtString -Key 'Cat.Tui.Configured.Unreadable') }
                default { return (Get-WtString -Key 'Cat.Tui.Configured.Unsupported') }
            }
        }
        'Effective'
        {
            switch ($Value)
            {
                'Active' { return (Get-WtString -Key 'Cat.Tui.Effective.Active') }
                'Inactive' { return (Get-WtString -Key 'Cat.Tui.Effective.Inactive') }
                'PendingRestart' { return (Get-WtString -Key 'Cat.Tui.Effective.PendingRestart') }
                'PendingSignOut' { return (Get-WtString -Key 'Cat.Tui.Effective.PendingSignOut') }
                'PendingReboot' { return (Get-WtString -Key 'Cat.Tui.Effective.PendingReboot') }
                'Unsupported' { return (Get-WtString -Key 'Cat.Tui.Effective.Unsupported') }
                default { return (Get-WtString -Key 'Cat.Tui.Effective.Unknown') }
            }
        }
        'Ownership'
        {
            switch ($Value)
            {
                'Owned' { return (Get-WtString -Key 'Cat.Tui.Ownership.Owned') }
                'Conflicting' { return (Get-WtString -Key 'Cat.Tui.Ownership.Conflicting') }
                'Interrupted' { return (Get-WtString -Key 'Cat.Tui.Ownership.Interrupted') }
                default { return (Get-WtString -Key 'Cat.Tui.Ownership.Unmanaged') }
            }
        }
        default
        {
            switch ($Value)
            {
                'Observed' { return (Get-WtString -Key 'Cat.Tui.Evidence.Observed') }
                'Inferred' { return (Get-WtString -Key 'Cat.Tui.Evidence.Inferred') }
                default { return (Get-WtString -Key 'Cat.Tui.Evidence.Unknown') }
            }
        }
    }
}

<#
.SYNOPSIS
    Localized label for one pending-restart marker state.
#>
function Get-WtObservedTypeLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Type)

    if (-not $Type) { return (Get-WtString -Key 'Cat.Sanity.ObservedType.None') }
    return $Type
}

<#
.SYNOPSIS
    Localized rendering of the Windows conditions a rule declared for itself.
.DESCRIPTION
    These are the conditions the rule was written for, reported as declared: this engine enforces
    only the platform key and the minimum build, and says so instead of implying more.
#>
function Get-WtConditionsLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$Conditions)

    if (-not $Conditions) { return (Get-WtString -Key 'Cat.Sanity.Conditions.None') }

    $Systems = @($Conditions.SupportedOS)
    if ($Systems.Count -eq 0) { return (Get-WtString -Key 'Cat.Sanity.Conditions.None') }

    return (Get-WtString -Key 'Cat.Sanity.Conditions.Value' -Arguments @(($Systems -join ', '), [int]$Conditions.MinBuild))
}

<#
.SYNOPSIS
    Localized rendering of a rule's reviewed remediation link.
.DESCRIPTION
    The link is a pointer for a human, never an action: nothing here applies it. A 'Tweak' says the
    catalog holds a reviewed definition that addresses the finding, and that it still has to go
    through the normal preview, review, journal and verification path.
#>
function Get-WtRuleRemediationLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$Remediation)

    if (-not $Remediation) { return (Get-WtString -Key 'Cat.Sanity.Remediation.Unknown') }

    $Notes = Get-WtText -Value $Remediation.Notes
    switch ([string]$Remediation.Kind)
    {
        'Tweak' { return (Get-WtString -Key 'Cat.Sanity.Remediation.Tweak' -Arguments @([string]$Remediation.Tweak, $Notes)) }
        'Manual' { return (Get-WtString -Key 'Cat.Sanity.Remediation.Manual' -Arguments @($Notes)) }
        default { return (Get-WtString -Key 'Cat.Sanity.Remediation.None' -Arguments @($Notes)) }
    }
}

<#
.SYNOPSIS
    Localized label for one pending-restart marker state.
#>
function Get-WtEnvironmentPendingRestartInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][object]$Environment)

    # StrictMode 3.0 makes dot access to a key that is not there an error, and the environment is a
    # hashtable in one path and an object in another, so the field is read through one place that
    # asks for it properly. A missing field means "not probed", which the caller reports as
    # unreadable rather than as "no restart is pending".
    if (-not $Environment) { return $null }

    if ($Environment -is [System.Collections.IDictionary])
    {
        if ($Environment.Contains('PendingRebootDetail')) { return $Environment['PendingRebootDetail'] }
        return $null
    }

    if (@($Environment.PSObject.Properties.Name) -contains 'PendingRebootDetail') { return $Environment.PendingRebootDetail }
    return $null
}

<#
.SYNOPSIS
    Localized short answer for the pending-restart question.
.DESCRIPTION
    Three answers, not two: a marker that could not be read is not "no restart is pending".
#>
function Get-WtPendingRestartValueLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$Pending)

    if (-not $Pending) { return (Get-WtString -Key 'Cat.Tui.Configured.Unreadable') }
    if ([int]$Pending.Present -gt 0) { return (Get-WtString -Key 'Common.Yes') }
    if ([int]$Pending.Unreadable -gt 0) { return (Get-WtString -Key 'Cat.Tui.Configured.Unreadable') }
    return (Get-WtString -Key 'Common.No')
}

<#
.SYNOPSIS
    Localized label for one pending-restart marker state.
#>
function Get-WtMarkerLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Marker)

    switch ($Marker)
    {
        'NonEmpty' { return (Get-WtString -Key 'Cat.Tui.Marker.Present') }
        'Empty' { return (Get-WtString -Key 'Cat.Tui.Marker.Empty') }
        'Unreadable' { return (Get-WtString -Key 'Cat.Tui.Marker.Unreadable') }
        default { return (Get-WtString -Key 'Cat.Tui.Marker.Missing') }
    }
}

<#
.SYNOPSIS
    Localized label for a scan outcome.
#>
function Get-WtScanOutcomeLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][string]$Outcome)

    switch ($Outcome)
    {
        'Clean' { return (Get-WtString -Key 'Cat.Sanity.Outcome.Clean') }
        'Findings' { return (Get-WtString -Key 'Cat.Sanity.Outcome.Findings') }
        'Incomplete' { return (Get-WtString -Key 'Cat.Sanity.Outcome.Incomplete') }
        default { return (Get-WtString -Key 'Cat.Sanity.Outcome.Unsupported') }
    }
}

<#
.SYNOPSIS
    Localized explanation for one recommendation decision.
#>
function Get-WtRecommendationReasonInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Item)

    $Key = [string]$Item.ReasonKey
    $ReasonArguments = @($Item.ReasonArgs)

    switch ($Key)
    {
        'Rec.Recommended' { return (Get-WtString -Key 'Rec.Recommended' -Arguments $ReasonArguments) }
        'Rec.AlreadySatisfied' { return (Get-WtString -Key 'Rec.AlreadySatisfied' -Arguments $ReasonArguments) }
        'Rec.Excluded.NoMetadata' { return (Get-WtString -Key 'Rec.Excluded.NoMetadata' -Arguments $ReasonArguments) }
        'Rec.Excluded.Manual' { return (Get-WtString -Key 'Rec.Excluded.Manual' -Arguments $ReasonArguments) }
        'Rec.Excluded.Preference' { return (Get-WtString -Key 'Rec.Excluded.Preference' -Arguments $ReasonArguments) }
        'Rec.Excluded.Diagnostic' { return (Get-WtString -Key 'Rec.Excluded.Diagnostic' -Arguments $ReasonArguments) }
        'Rec.Excluded.Never' { return (Get-WtString -Key 'Rec.Excluded.Never' -Arguments $ReasonArguments) }
        'Rec.Excluded.Protection' { return (Get-WtString -Key 'Rec.Excluded.Protection' -Arguments $ReasonArguments) }
        'Rec.Excluded.Recovery' { return (Get-WtString -Key 'Rec.Excluded.Recovery' -Arguments $ReasonArguments) }
        'Rec.Excluded.Evidence' { return (Get-WtString -Key 'Rec.Excluded.Evidence' -Arguments $ReasonArguments) }
        'Rec.Excluded.Lifecycle' { return (Get-WtString -Key 'Rec.Excluded.Lifecycle' -Arguments $ReasonArguments) }
        'Rec.Excluded.Objective' { return (Get-WtString -Key 'Rec.Excluded.Objective' -Arguments $ReasonArguments) }
        'Rec.Excluded.Kind' { return (Get-WtString -Key 'Rec.Excluded.Kind' -Arguments $ReasonArguments) }
        'Rec.Excluded.InvalidMetadata' { return (Get-WtString -Key 'Rec.Excluded.InvalidMetadata' -Arguments $ReasonArguments) }
        'Rec.Excluded.PackClaim' { return (Get-WtString -Key 'Rec.Excluded.PackClaim' -Arguments $ReasonArguments) }
        'Rec.Excluded.RepairNeedsFinding' { return (Get-WtString -Key 'Rec.Excluded.RepairNeedsFinding' -Arguments $ReasonArguments) }
        'Rec.Excluded.Undocumented' { return (Get-WtString -Key 'Rec.Excluded.Undocumented' -Arguments $ReasonArguments) }
        'Rec.Unknown.Applicability' { return (Get-WtString -Key 'Rec.Unknown.Applicability' -Arguments $ReasonArguments) }
        'Rec.Unknown.State' { return (Get-WtString -Key 'Rec.Unknown.State' -Arguments $ReasonArguments) }
        'Rec.Unknown.Verification' { return (Get-WtString -Key 'Rec.Unknown.Verification' -Arguments $ReasonArguments) }
        'Rec.Unknown.VerificationScript' { return (Get-WtString -Key 'Rec.Unknown.VerificationScript' -Arguments $ReasonArguments) }
        'Rec.Blocked.Conflict' { return (Get-WtString -Key 'Rec.Blocked.Conflict' -Arguments $ReasonArguments) }
        'Rec.Blocked.Plan' { return (Get-WtString -Key 'Rec.Blocked.Plan' -Arguments $ReasonArguments) }
        default { return '' }
    }
}

<#
.SYNOPSIS
    Localized label for one exclusive-choice option intent.
.DESCRIPTION
    'Configured' writes a value this tool can restore exactly; 'WindowsDefault' asks Windows for
    its own behaviour, which is not the same thing as restoring the captured baseline.
#>
function Get-WtIntentLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][string]$Intent)

    if ($Intent -eq 'WindowsDefault') { return (Get-WtString -Key 'Cat.Tui.Intent.WindowsDefault') }
    return (Get-WtString -Key 'Cat.Tui.Intent.Configured')
}

<#
.SYNOPSIS
    Localized label for a choice-group current state.
.DESCRIPTION
    A group reports the option it detected, or one of the honest alternatives: a value that
    matches no option, a read that failed, or a definition that cannot run here.
#>
function Get-WtGroupStateLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Group,
        [Parameter(Mandatory = $false)][string]$Detected
    )

    if (-not $Detected) { $Detected = [string]$Group.CurrentState }
    $Detail = if (@($Group.PSObject.Properties.Name) -contains 'CurrentDetail') { [string]$Group.CurrentDetail } else { '' }

    if (-not $Group.Supported) { return (Get-WtString -Key 'Cat.Tui.Configured.Unsupported') }

    foreach ($Option in @($Group.Options))
    {
        if ($Option.Id -eq $Detected) { return (Get-WtText -Value $Option.Labels) }
    }

    # Not one of the alternatives: say which kind of "not one of them" it is. A value that is
    # absent is not a custom value, and several targets that disagree are not a custom value
    # either - each one is a different fact a reviewer has to act on differently.
    switch ($Detail)
    {
        'Mixed' { return (Get-WtString -Key 'Cat.Tui.Configured.Mixed') }
        'Absent' { return (Get-WtString -Key 'Cat.Tui.Group.Absent') }
        'Unreadable' { return (Get-WtString -Key 'Cat.Tui.Configured.Unreadable') }
        'Unsupported' { return (Get-WtString -Key 'Cat.Tui.Configured.Unsupported') }
    }

    if ($Detected -eq 'Unsupported') { return (Get-WtString -Key 'Cat.Tui.Configured.Unsupported') }
    return (Get-WtString -Key 'Cat.Tui.Group.Custom')
}

<#
.SYNOPSIS
    Localized label for a recommendation kind.
#>
function Get-WtRecommendationKindLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Kind)

    switch ($Kind)
    {
        'Optimization' { return (Get-WtString -Key 'Rec.Kind.Optimization') }
        'Preference' { return (Get-WtString -Key 'Rec.Kind.Preference') }
        'Diagnostic' { return (Get-WtString -Key 'Rec.Kind.Diagnostic') }
        'Repair' { return (Get-WtString -Key 'Rec.Kind.Repair') }
        default { return '' }
    }
}

<#
.SYNOPSIS
    Localized label for a recommendation policy.
#>
function Get-WtRecommendationPolicyLabelInternal
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Policy)

    switch ($Policy)
    {
        'Eligible' { return (Get-WtString -Key 'Rec.Policy.Eligible') }
        'Manual' { return (Get-WtString -Key 'Rec.Policy.Manual') }
        'Never' { return (Get-WtString -Key 'Rec.Policy.Never') }
        default { return '' }
    }
}
