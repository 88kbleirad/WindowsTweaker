# WindowsTweaker - privacy profile metadata and activity views (all read-only).
#
# The privacy profile is descriptive metadata about selected tweaks: whether the value is
# a user preference or policy-shaped, whether Windows Settings remains editable for it,
# the supported editions/builds and the diagnostics/troubleshooting consequence (a stable
# capability id from the capability-loss declarations). It is data, not a promise: writing
# a policy is never claimed to stop telemetry, and "security updates only" or permanent AI
# removal are never claimed.
#
# Activity views are an *optional, read-only* layer. They only report what a documented,
# platform-supported source can provide. On this codebase, the Windows privacy activity
# history is not exposed through a stable public API, so every view reports itself as
# Unavailable with the reason, and no fabricated log is ever presented as an exhaustive
# surveillance record.

$Script:WtPrivacyViews = @(
    @{ Id = 'camera'; Names = @{ en = 'Camera'; vi = 'Camera' }; Provider = 'None'; Source = 'Windows privacy settings history (no public API)'; Limitations = 'Last-access times are not exposed through a documented API; this view stays unavailable until a reliable provider exists.' }
    @{ Id = 'microphone'; Names = @{ en = 'Microphone'; vi = 'Microphone' }; Provider = 'None'; Source = 'Windows privacy settings history (no public API)'; Limitations = 'Same as camera: no stable provider exists, so no data is invented.' }
    @{ Id = 'location'; Names = @{ en = 'Location'; vi = 'Vị trí' }; Provider = 'None'; Source = 'No documented public history source'; Limitations = 'Recent location access is not available through a stable API here.' }
    @{ Id = 'screenCapture'; Names = @{ en = 'Screen capture'; vi = 'Chụp màn hình' }; Provider = 'None'; Source = 'No reliable provider'; Limitations = 'Screen-capture activity is not enumerable through a stable API; nothing is claimed.' }
)

$Script:WtPrivacyViewIds = @('camera', 'microphone', 'location', 'screenCapture')

<#
.SYNOPSIS
    Returns the privacy profile metadata for catalog tweaks (read-only, data only).
#>
function Get-WtPrivacyProfile
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $false)][string]$Id = '')

    $Path = Join-Path $Script:WtDataDirectory 'Privacy\privacy-metadata.json'
    $Entries = @()
    if (Test-Path -LiteralPath $Path)
    {
        try
        {
            $Document = ConvertFrom-WtJson -Text (Read-WtTextFile -Path $Path) -Depth 8
            $Entries = @($Document.entries)
        }
        catch
        {
            Write-WtLog -Level Warning -Message "The privacy metadata could not be read: $Path ($($_.Exception.Message))" -NoConsole
            $Entries = @()
        }
    }
    else
    {
        Write-WtLog -Level Warning -Message "The privacy metadata file is missing: $Path" -NoConsole
    }

    if ($Id)
    {
        $Entries = @($Entries | Where-Object { $_.tweakId -eq $Id })
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.PrivacyProfile'
        Entries = @($Entries)
    }
}

<#
.SYNOPSIS
    Returns the privacy activity views with their availability.
.DESCRIPTION
    Read-only. Every view reports its data source, observed time range (none when no
    provider exists), access limitations and coverage. Views without a provider are
    Unavailable with the reason; none of them pretend to be exhaustive logs.
#>
function Get-WtPrivacyActivityView
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $false)][string]$View = '')

    $Views = @($Script:WtPrivacyViews)
    if ($View)
    {
        $Views = @($Views | Where-Object { $_.Id -eq $View })
    }

    $Rows = @($Views | ForEach-Object {
            [pscustomobject]@{
                PSTypeName = 'WindowsTweaker.PrivacyActivityView'
                View       = $_.Id
                Name       = (Get-WtText -Value $_.Names)
                Provider   = $_.Provider
                Status     = 'Unavailable'
                Reason     = $_.Limitations
                Source     = $_.Source
                ObservedFrom = $null
                ObservedTo   = $null
                Coverage   = 'None'
            }
        })

    return $Rows
}
