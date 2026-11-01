# WindowsTweaker - TUI performance profile.
#
# The profile is presentation-only. It may change refresh cadence, output batching,
# background collection cadence, animations and detail density, and nothing else: it
# never touches power plans, security settings, services, networking, guest drivers or
# hypervisor configuration. A profile is a hint, and correctness never depends on it.
#
#   Auto          - chosen from the terminal capability and the measured render cost (a
#                   classic console without virtual terminal processing gets the
#                   low-resource behaviour; a virtual terminal gets balanced).
#   Balanced      - the default behaviour of the interface.
#   Low-resource  - for VM guests with slow console output: lower refresh cadence while
#                   idle, smaller key batches per render, cheaper detail (no row icons),
#                   and slower background collection.
#
# The user override is stored in the settings file (profile field) and can be given per
# invocation on the command line or through WT_TUI_PERF_PROFILE.

$Script:WtTuiProfiles = @('Auto', 'Balanced', 'Low-resource')

<#
.SYNOPSIS
    Returns the supported profile names, in display order.
#>
function Get-WtTuiProfiles
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return @($Script:WtTuiProfiles)
}

<#
.SYNOPSIS
    Normalises a requested profile name; an unknown value resolves to Auto.
#>
function Resolve-WtTuiProfile
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Requested = 'Auto')

    if (-not $Requested) { return 'Auto' }
    foreach ($Name in $Script:WtTuiProfiles)
    {
        if ([string]::Equals($Name, $Requested, [System.StringComparison]::OrdinalIgnoreCase))
        {
            return $Name
        }
    }
    return 'Auto'
}

<#
.SYNOPSIS
    Decides the effective profile for a TUI session.
.DESCRIPTION
    Precedence: the caller's explicit override, then the saved preference, then the
    environment, then Auto. Auto chooses from what is actually present: a terminal
    without virtual terminal processing renders through the plain console API, which is
    measurably more expensive per frame, so it defaults to Low-resource; a virtual
    terminal gets Balanced. The decision is made once at startup.
#>
function Get-WtTuiProfileEffective
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Requested = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Preference = '',
        [Parameter(Mandatory = $false)][bool]$UseVt = $false
    )

    if ($Requested) { return (Resolve-WtTuiProfile -Requested $Requested) }
    if ($Preference) { return (Resolve-WtTuiProfile -Requested $Preference) }

    $EnvProfile = [string]$env:WT_TUI_PERF_PROFILE
    if ($EnvProfile) { return (Resolve-WtTuiProfile -Requested $EnvProfile) }

    if (-not $UseVt) { return 'Low-resource' }
    return 'Balanced'
}

<#
.SYNOPSIS
    Returns the knob values for an effective profile.
.DESCRIPTION
    All values are presentation/collection hints; the safety boundaries of the journal and
    the restart rules are hard-coded elsewhere and are never influenced here.
#>
function Get-WtTuiProfileKnobs
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([Parameter(Mandatory = $false)][string]$Profile = 'Balanced')

    switch ($Profile)
    {
        'Low-resource'
        {
            return @{
                Profile         = 'Low-resource'
                FrameTimeoutMs  = 60
                MaxKeyBatch     = 6
                MaxBatchElapsedMs = 120
                MonitorCadence  = 2.0
                ShowRowIcons    = $false
                AnimateCollection = $false
            }
        }
        default
        {
            return @{
                Profile         = 'Balanced'
                FrameTimeoutMs  = 40
                MaxKeyBatch     = 32
                MaxBatchElapsedMs = 200
                MonitorCadence  = 1.0
                ShowRowIcons    = $true
                AnimateCollection = $true
            }
        }
    }
}
