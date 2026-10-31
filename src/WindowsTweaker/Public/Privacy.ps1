# WindowsTweaker - public privacy profile and activity views (read-only).

<#
.SYNOPSIS
    Returns the privacy profile summary for the privacy category.
.DESCRIPTION
    One row per privacy tweak: configured state, managed/policy ownership, whether the
    Settings screen stays editable (as declared), supported editions/builds, and the
    diagnostics consequence from the capability-loss declarations. This is metadata over
    the catalog, never a claim that writing a policy stops telemetry.
#>
function Get-WtPrivacySummary
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ()

    $PrivacyProfile = Get-WtPrivacyProfile
    $Rows = [System.Collections.Generic.List[object]]::new()

    foreach ($Entry in $PrivacyProfile.Entries)
    {
        $Tweak = Get-WtTweakInternal -Id $Entry.tweakId
        if (-not $Tweak) { continue }

        $State = $null
        try { $State = Get-WtTweakState -Id $Tweak.Id }
        catch
        {
            Write-WtLog -Level Warning -Message "State query failed for $($Tweak.Id): $($_.Exception.Message)" -NoConsole
            $State = $null
        }

        $Rows.Add([pscustomobject]@{
            PSTypeName = 'WindowsTweaker.PrivacyRow'
            TweakId = $Tweak.Id
            Name = (Get-WtText -Value $Tweak.Name)
            State = if ($State) { [string]$State.State } else { 'Unknown' }
            Managed = if ($State) { [bool]$State.Managed } else { $false }
            ManagedBy = if ($State -and $State.ManagedBy) { [string]$State.ManagedBy } else { '' }
            SettingsEditable = [string]$Entry.settingsEditable
            SupportedEditions = @($Entry.supportedEditions)
            MinBuild = [int]$Entry.minBuild
            DiagnosticsConsequence = [string]$Entry.diagnosticsConsequence
        })
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.PrivacySummary'
        Rows = @($Rows.ToArray())
    }
}

<#
.SYNOPSIS
    Returns the privacy activity views (camera, microphone, location, screen capture).
.DESCRIPTION
    Read-only and optional. Views are reported with their provider status; a view without
    a reliable provider is Unavailable with the reason and never presents fabricated data.
#>
function Get-WtPrivacyActivity
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $false)][ValidateSet('camera', 'microphone', 'location', 'screenCapture')][string]$View = '')

    return @(Get-WtPrivacyActivityView -View $View)
}
