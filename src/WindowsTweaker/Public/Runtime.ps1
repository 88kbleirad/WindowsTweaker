# WindowsTweaker - public runtime surface.
#
# The entry point and any scriptable caller need one read-only answer to "what can this
# runtime do, and what do I tell the user if it is not the validated one?". The profile and
# the capability table live in Private/Compatibility.ps1, which is not exported; this is the
# single command that exposes them, so the module's public surface grows by one command
# instead of by every helper.
#
# Nothing here changes state: no registry read, no file write, no process started.

<#
.SYNOPSIS
    Reports the PowerShell runtime this session is running on and what it supports.
.DESCRIPTION
    Read-only snapshot used by the entry point, the diagnostics report and scripts:
      Profile         - version, edition, platform, architecture, tier, validated range;
      Capabilities    - every capability with whether it is available and why;
      Notice          - the bilingual start-up notice for a runtime outside the validated
                        range, or '' when the runtime is validated;
      Report          - the human-readable runtime report (same text on every runtime);
      HandoffCommand  - the exact command that runs the entry point on the validated runtime.
.PARAMETER EntryPoint
    Entry point used in the handoff command. Defaults to the WindowsTweaker.ps1 next to the
    module (the repository root or the unpacked release root).
.PARAMETER Refresh
    Probe the runtime again instead of using the cached profile.
.EXAMPLE
    Get-WtRuntimeInfo
.EXAMPLE
    (Get-WtRuntimeInfo).Capabilities | Where-Object { -not $_.Supported }
.OUTPUTS
    WindowsTweaker.RuntimeInfo
#>
function Get-WtRuntimeInfo
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param
    (
        [Parameter(Mandatory = $false)][string]$EntryPoint,
        [Parameter(Mandatory = $false)][switch]$Refresh
    )

    if (-not $EntryPoint)
    {
        $EntryPoint = Join-Path $Script:WtProjectRoot 'WindowsTweaker.ps1'
    }

    $RuntimeProfile = Get-WtRuntimeProfile -Refresh:$Refresh
    $Capabilities = @(Get-WtRuntimeCapabilityList)

    $Notice = ''
    if ($RuntimeProfile.Tier -ne 'Supported')
    {
        # The notice is the same bilingual block the interface prints at start-up.
        $Notice = Get-WtRuntimeStartupNotice -RuntimeProfile $RuntimeProfile -EntryPoint $EntryPoint
    }

    return [pscustomobject]@{
        PSTypeName      = 'WindowsTweaker.RuntimeInfo'
        Profile         = $RuntimeProfile
        Capabilities    = $Capabilities
        Unsupported     = @($Capabilities | Where-Object { -not $_.Supported })
        Notice          = $Notice
        Report          = (Get-WtRuntimeReportText -EntryPoint $EntryPoint)
        HandoffCommand  = (Get-WtRuntimeHandoffCommand -EntryPoint $EntryPoint)
        Validated       = ($RuntimeProfile.Tier -eq 'Supported')
    }
}