# WindowsTweaker - service, scheduled task and firewall providers.
#
# All three capture the previous configuration before changing it, honour -WhatIf,
# verify the result and report a per-operation status. "-Raw" functions are the only
# place that talks to the OS, and are the seams used by the test suite.

$Script:WtServiceAvailableCache = $null

function Test-WtServiceAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if ($null -eq $Script:WtServiceAvailableCache)
    {
        $Script:WtServiceAvailableCache = [bool](Get-Command -Name Get-Service -ErrorAction Ignore)
    }

    return $Script:WtServiceAvailableCache
}

#region Services

function Get-WtServiceRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    return (Get-Service -Name $Name -ErrorAction Ignore | Select-Object -First 1)
}

function Set-WtServiceStartupTypeRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Automatic', 'Manual', 'Disabled', 'AutomaticDelayedStart')][string]$StartupType
    )

    Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
}

function Start-WtServiceRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    Start-Service -Name $Name -ErrorAction Stop
}

function Stop-WtServiceRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    Stop-Service -Name $Name -Force -ErrorAction Stop
}

<#
.SYNOPSIS
    Read-only service snapshot: existence, start type and running state.
#>
function Get-WtServiceSnapshot
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Test-WtServiceAvailable))
    {
        return [pscustomobject]@{
            PSTypeName  = 'WindowsTweaker.ServiceState'
            Name        = $Name
            Available   = $false
            Exists      = $false
            StartupType = $null
            Status      = $null
        }
    }

    $Service = Get-WtServiceRaw -Name $Name

    if (-not $Service)
    {
        return [pscustomobject]@{
            PSTypeName  = 'WindowsTweaker.ServiceState'
            Name        = $Name
            Available   = $true
            Exists      = $false
            StartupType = $null
            Status      = $null
        }
    }

    # StartType is exposed by ServiceController on .NET 5+; fall back to WMI otherwise.
    $StartupType = $null
    try
    {
        if ($Service.PSObject.Properties.Name -contains 'StartType')
        {
            $StartupType = [string]$Service.StartType
        }
    }
    catch
    {
        $StartupType = $null
    }

    if (-not $StartupType)
    {
        try
        {
            $StartupType = [string](Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction Stop).StartMode
        }
        catch
        {
            $StartupType = $null
        }
    }

    return [pscustomobject]@{
        PSTypeName  = 'WindowsTweaker.ServiceState'
        Name        = $Name
        Available   = $true
        Exists      = $true
        StartupType = $StartupType
        Status      = [string]$Service.Status
    }
}

<#
.SYNOPSIS
    Applies a service start type and/or running state, capturing the previous config.
.PARAMETER StartupType
    Automatic, Manual, Disabled or AutomaticDelayedStart.
.PARAMETER Status
    Running or Stopped.
#>
function Set-WtServiceState
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][ValidateSet('Automatic', 'Manual', 'Disabled', 'AutomaticDelayedStart')][string]$StartupType,
        [Parameter(Mandatory = $false)][ValidateSet('Running', 'Stopped')][string]$Status
    )

    $Operation = 'SetService'
    $Target = $Name

    if (-not (Test-WtServiceAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message 'Get-Service is not available on this platform.'
    }

    $Previous = Get-WtServiceSnapshot -Name $Name
    if (-not $Previous.Exists)
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message "Service not found: $Name"
    }

    $StartupMatches = (-not $StartupType) -or ($Previous.StartupType -eq $StartupType)
    $StatusMatches = (-not $Status) -or ($Previous.Status -eq $Status)

    if ($StartupMatches -and $StatusMatches)
    {
        return New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target $Target -Message "Service $Name already matches the requested configuration."
    }


    $Description = @()
    if ($StartupType) { $Description += "startup=$StartupType" }
    if ($Status) { $Description += "state=$Status" }

    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Target, "configure service ($($Description -join ', '))"))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Target -Message "Would configure service $Name ($($Description -join ', '))"
    }

    $Context = Get-WtOperationContext
    if ($null -ne $Context.HistoryEntry)
    {
        Add-WtStateRecord -HistoryEntry $Context.HistoryEntry -Record @{
            resource    = 'Service'
            name        = $Name
            exists      = $true
            startupType = $Previous.StartupType
            status      = $Previous.Status
        }
    }

    try
    {
        if ($StartupType)
        {
            Set-WtServiceStartupTypeRaw -Name $Name -StartupType $StartupType
        }

        if ($Status -eq 'Stopped')
        {
            Stop-WtServiceRaw -Name $Name
        }
        elseif ($Status -eq 'Running')
        {
            Start-WtServiceRaw -Name $Name
        }
    }
    catch
    {
        Write-WtLog -Level Error -Message "Failed to configure service $Name" -Operation $Operation -Status 'failed' -Exception $_.Exception
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $_.Exception.Message -ErrorRecord $_
    }

    $Verify = Get-WtServiceSnapshot -Name $Name
    $Verified = (($StartupMatches -or $Verify.StartupType -eq $StartupType) -and ($StatusMatches -or $Verify.Status -eq $Status))
    if (-not $Verified)
    {
        $Message = "Verification failed for service $Name (startup=$($Verify.StartupType), state=$($Verify.Status))"
        Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $Message
    }

    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $Target -Message "Configured service $Name ($($Description -join ', '))"
}

#endregion Services

#region Scheduled tasks

function Test-WtScheduledTaskAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool](Get-Command -Name Get-ScheduledTask -ErrorAction Ignore)
}

function Get-WtScheduledTaskRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return (Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Ignore | Select-Object -First 1)
}

function Set-WtScheduledTaskEnabledRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    if ($Enabled)
    {
        Enable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null
    }
    else
    {
        Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null
    }
}

<#
.SYNOPSIS
    Read-only scheduled task snapshot.
#>
function Get-WtScheduledTaskSnapshot
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-WtScheduledTaskAvailable))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.ScheduledTaskState'
            Path       = $Path
            Name       = $Name
            Available  = $false
            Exists     = $false
            Enabled    = $null
        }
    }

    $Task = Get-WtScheduledTaskRaw -Path $Path -Name $Name
    if (-not $Task)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.ScheduledTaskState'
            Path       = $Path
            Name       = $Name
            Available  = $true
            Exists     = $false
            Enabled    = $null
        }
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.ScheduledTaskState'
        Path       = $Path
        Name       = $Name
        Available  = $true
        Exists     = $true
        Enabled    = ([string]$Task.State -ne 'Disabled')
    }
}

<#
.SYNOPSIS
    Enables or disables a scheduled task, capturing the previous state.
#>
function Set-WtScheduledTaskState
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $Operation = 'SetScheduledTask'
    $Target = "$Path$Name"

    if (-not (Test-WtScheduledTaskAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message 'ScheduledTasks module is not available on this platform.'
    }

    $Previous = Get-WtScheduledTaskSnapshot -Path $Path -Name $Name
    if (-not $Previous.Exists)
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message "Scheduled task not found: $Target"
    }

    if ($Previous.Enabled -eq $Enabled)
    {
        return New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target $Target -Message "Scheduled task $Target already $(if ($Enabled) { 'enabled' } else { 'disabled' })."
    }


    $Action = if ($Enabled) { 'enable' } else { 'disable' }
    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Target, "$Action scheduled task"))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Target -Message "Would $Action $Target"
    }

    $Context = Get-WtOperationContext
    if ($null -ne $Context.HistoryEntry)
    {
        Add-WtStateRecord -HistoryEntry $Context.HistoryEntry -Record @{
            resource = 'ScheduledTask'
            path     = $Path
            name     = $Name
            exists   = $true
            enabled  = [bool]$Previous.Enabled
        }
    }

    try
    {
        Set-WtScheduledTaskEnabledRaw -Path $Path -Name $Name -Enabled $Enabled
    }
    catch
    {
        Write-WtLog -Level Error -Message "Failed to $Action $Target" -Operation $Operation -Status 'failed' -Exception $_.Exception
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $_.Exception.Message -ErrorRecord $_
    }

    $Verify = Get-WtScheduledTaskSnapshot -Path $Path -Name $Name
    if ($Verify.Enabled -ne $Enabled)
    {
        $Message = "Verification failed for $Target"
        Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $Message
    }

    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $Target -Message "$($Action.Substring(0,1).ToUpper())$($Action.Substring(1))d $Target"
}

#endregion Scheduled tasks

#region Firewall rules

function Test-WtFirewallAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool](Get-Command -Name Get-NetFirewallRule -ErrorAction Ignore)
}

function Get-WtFirewallRulesRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Group)

    return @(Get-NetFirewallRule -Group $Group -ErrorAction Ignore)
}

function Set-WtFirewallRuleRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Enabled,
        [Parameter(Mandatory = $false)][string]$Action,
        [Parameter(Mandatory = $false)][string]$Profile
    )

    $Parameters = @{ Name = $Name; Enabled = $Enabled }
    if ($Action)
    {
        $Parameters.Action = $Action
    }

    if ($Profile)
    {
        # -Profile of Set-NetFirewallRule is the profile the rule is assigned to
        # (there is no profile *filter*: Get-NetFirewallRule has no -Profile
        # parameter). Get-NetFirewallRule reports multi-profile rules as
        # 'Domain, Private', while the parameter expects them without spaces.
        $Parameters.Profile = ([string]$Profile -replace '\s', '')
    }

    Set-NetFirewallRule @Parameters -ErrorAction Stop
}

<#
.SYNOPSIS
    Read-only snapshot of the firewall rules belonging to a group.
#>
function Get-WtFirewallGroupSnapshot
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Group)

    if (-not (Test-WtFirewallAvailable))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.FirewallGroupState'
            Group      = $Group
            Available  = $false
            Rules      = @()
        }
    }

    $Rules = @(Get-WtFirewallRulesRaw -Group $Group | ForEach-Object {
        [pscustomobject]@{
            Name    = $_.Name
            DisplayName = $_.DisplayName
            Enabled = [string]$_.Enabled
            Action  = [string]$_.Action
            Profile = [string]$_.Profile
        }
    })

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.FirewallGroupState'
        Group      = $Group
        Available  = $true
        Rules      = $Rules
    }
}

<#
.SYNOPSIS
    Sets the enabled state (and optionally the action and profile) of every rule in a
    firewall group.
.DESCRIPTION
    Group-scoped on purpose: individual rule names change between Windows builds.

    -Profile follows the Windows semantics of Set-NetFirewallRule: it is the profile
    the rules are assigned to, not a filter (Get-NetFirewallRule offers no profile
    filter). The legacy modules/NetworkDiscovery.ps1 passed -Profile Private together
    with -Group for exactly that reason, so the parameter is passed through unchanged
    and the outcome stays the same: the named groups end up assigned to, and enabled
    or disabled on, that profile only.
#>
function Set-WtFirewallGroupState
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][ValidateSet('True', 'False')][string]$Enabled,
        [Parameter(Mandatory = $false)][ValidateSet('Allow', 'Block')][string]$Action,
        [Parameter(Mandatory = $false)][string]$Profile
    )

    $Operation = 'SetFirewallGroup'
    $Target = $Group

    if (-not (Test-WtFirewallAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message 'NetSecurity module is not available on this platform.'
    }

    $Previous = Get-WtFirewallGroupSnapshot -Group $Group
    if ($Previous.Rules.Count -eq 0)
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message "No firewall rules found for group $Group"
    }


    $Description = "enabled=$Enabled"
    if ($Action) { $Description += ", action=$Action" }
    if ($Profile) { $Description += ", profile=$Profile" }

    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Target, "configure firewall group ($Description)"))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Target -Message "Would configure firewall group $Group ($Description)"
    }

    $Context = Get-WtOperationContext
    if ($null -ne $Context.HistoryEntry)
    {
        Add-WtStateRecord -HistoryEntry $Context.HistoryEntry -Record @{
            resource = 'FirewallGroup'
            group    = $Group
            rules    = @($Previous.Rules)
        }
    }

    $Failures = @()
    foreach ($Rule in $Previous.Rules)
    {
        try
        {
            Set-WtFirewallRuleRaw -Name $Rule.Name -Enabled $Enabled -Action $Action -Profile $Profile
        }
        catch
        {
            $Failures += $Rule.Name
        }
    }

    if ($Failures.Count -gt 0)
    {
        $Message = "Firewall group ${Group}: $($Failures.Count) rule(s) could not be updated."
        Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $Message
    }

    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $Target -Message "Configured firewall group $Group ($Description)"
}

#endregion Firewall rules
