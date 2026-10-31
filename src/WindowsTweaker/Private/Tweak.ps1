# WindowsTweaker - tweak model, catalog and operation execution engine.
#
# A tweak is a metadata record plus three separate concerns:
#   Detect  : read-only, returns the current state (never writes)
#   Apply   : performs the change through the provider functions, so -WhatIf,
#             state capture, verification and logging are automatic
#   Rollback: driven by the state store (see Rollback.ps1), not by hard-coded values
#
# Two constructors exist:
#   New-WtRegistryTweak - declarative: one operation list per state
#   New-WtScriptTweak   - escape hatch for non-registry tweaks (services, tasks,
#                         packages, downloads); still must use the providers
#
# Registering a tweak only stores metadata. Importing the module therefore cannot
# change any system setting.

$Script:WtCatalog = [ordered]@{}
$Script:WtTweakIdPattern = '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$'
$Script:WtKnownCategories = @(
    'Privacy'
    'Security'
    'System'
    'Explorer'
    'Taskbar'
    'StartMenu'
    'Apps'
    'Network'
    'Updates'
    'Personalization'
    'Maintenance'
)

<#
.SYNOPSIS
    Reads a field from a detection result.
.DESCRIPTION
    Tweak detectors may return either a hashtable or an object; this reads a field
    from both shapes so a definition cannot silently degrade to "Unknown".
#>
function Get-WtDetectionField
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][object]$Detection,
        [Parameter(Mandatory = $true)][string]$Field
    )

    if ($null -eq $Detection)
    {
        return $null
    }

    if ($Detection -is [System.Collections.IDictionary])
    {
        if ($Detection.Contains($Field))
        {
            return $Detection[$Field]
        }

        return $null
    }

    if ($Detection.PSObject.Properties.Name -contains $Field)
    {
        return $Detection.$Field
    }

    return $null
}

#region Operation kinds

<#
.SYNOPSIS
    Validates one operation descriptor.
#>
function Assert-WtOperation
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Operation,
        [Parameter(Mandatory = $false)][string]$Context = ''
    )

    if (-not $Operation.ContainsKey('Kind'))
    {
        throw "Operation is missing 'Kind'$Context."
    }

    switch ($Operation.Kind)
    {
        'RegistrySet'
        {
            foreach ($Required in 'Path', 'Name', 'Value')
            {
                if (-not $Operation.ContainsKey($Required))
                {
                    throw "RegistrySet operation is missing '$Required'$Context."
                }
            }
            if (-not $Operation.ContainsKey('Type') -or -not (Resolve-WtRegistryKind -Kind $Operation.Type))
            {
                throw "RegistrySet operation needs a valid 'Type' (String, ExpandString, Binary, DWord, MultiString, QWord)$Context."
            }
        }
        'RegistryRemove'
        {
            foreach ($Required in 'Path', 'Name')
            {
                if (-not $Operation.ContainsKey($Required))
                {
                    throw "RegistryRemove operation is missing '$Required'$Context."
                }
            }
        }
        'RegistryKeyCreate'
        {
            if (-not $Operation.ContainsKey('Path'))
            {
                throw "RegistryKeyCreate operation is missing 'Path'$Context."
            }
        }
        'RegistryKeyRemove'
        {
            if (-not $Operation.ContainsKey('Path'))
            {
                throw "RegistryKeyRemove operation is missing 'Path'$Context."
            }
        }
        'Service'
        {
            if (-not $Operation.ContainsKey('Name'))
            {
                throw "Service operation is missing 'Name'$Context."
            }
            if (-not $Operation.ContainsKey('StartupType') -and -not $Operation.ContainsKey('Status'))
            {
                throw "Service operation needs 'StartupType' and/or 'Status'$Context."
            }
        }
        'ScheduledTask'
        {
            foreach ($Required in 'Path', 'Name', 'Enabled')
            {
                if (-not $Operation.ContainsKey($Required))
                {
                    throw "ScheduledTask operation is missing '$Required'$Context."
                }
            }
        }
        'FirewallGroup'
        {
            if (-not $Operation.ContainsKey('Group'))
            {
                throw "FirewallGroup operation is missing 'Group'$Context."
            }
        }
        default
        {
            throw "Unknown operation kind '$($Operation.Kind)'$Context."
        }
    }
}

<#
.SYNOPSIS
    Executes one operation through the matching provider.
#>
function Invoke-WtOperation
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Operation,
        [Parameter(Mandatory = $false)][string]$TweakId
    )

    Assert-WtOperation -Operation $Operation -Context " (tweak: $TweakId)"

    switch ($Operation.Kind)
    {
        'RegistrySet'
        {
            Set-WtRegistryValue -Path $Operation.Path -Name $Operation.Name -Value $Operation.Value -Kind (Resolve-WtRegistryKind -Kind $Operation.Type)
        }
        'RegistryRemove'
        {
            Remove-WtRegistryValue -Path $Operation.Path -Name $Operation.Name
        }
        'RegistryKeyCreate'
        {
            New-WtRegistryKey -Path $Operation.Path
        }
        'RegistryKeyRemove'
        {
            Remove-WtRegistryKey -Path $Operation.Path -Recurse:([bool]$Operation.Recurse)
        }
        'Service'
        {
            $Parameters = @{ Name = $Operation.Name }
            if ($Operation.StartupType) { $Parameters.StartupType = $Operation.StartupType }
            if ($Operation.Status) { $Parameters.Status = $Operation.Status }
            Set-WtServiceState @Parameters
        }
        'ScheduledTask'
        {
            Set-WtScheduledTaskState -Path $Operation.Path -Name $Operation.Name -Enabled ([bool]$Operation.Enabled)
        }
        'FirewallGroup'
        {
            $Parameters = @{ Group = $Operation.Group }
            if ($Operation.ContainsKey('Enabled')) { $Parameters.Enabled = [string]$Operation.Enabled }
            if ($Operation.Action) { $Parameters.Action = $Operation.Action }
            Set-WtFirewallGroupState @Parameters
        }
    }
}

<#
.SYNOPSIS
    Runs an operation list and returns per-operation results.
#>
function Invoke-WtOperationList
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][hashtable[]]$Operations = @(),
        [Parameter(Mandatory = $false)][string]$TweakId
    )

    $Results = @()
    foreach ($Operation in $Operations)
    {
        $Results += Invoke-WtOperation -Operation $Operation -TweakId $TweakId
    }

    return $Results
}

<#
.SYNOPSIS
    Returns the registry value an operation list should be judged by, if any.
#>
function Get-WtPrimaryRegistryOperation
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][hashtable[]]$Operations = @())

    return @($Operations | Where-Object { $_.Kind -eq 'RegistrySet' } | Select-Object -First 1)
}

#endregion Operation kinds

#region Tweak constructors

<#
.SYNOPSIS
    Creates and registers a tweak.
.DESCRIPTION
    Prefer New-WtRegistryTweak / New-WtScriptTweak, which fill in Detect and Apply.
#>
function New-WtTweak
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][hashtable]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Description,
        [Parameter(Mandatory = $true)][hashtable]$Impact,
        [Parameter(Mandatory = $false)][string]$Scope = 'User',
        [Parameter(Mandatory = $false)][ValidateSet('None', 'Admin')][string]$Privilege = 'None',
        [Parameter(Mandatory = $false)][string[]]$SupportedOS = @('Windows10', 'Windows11'),
        [Parameter(Mandatory = $false)][int]$MinBuild = 0,
        [Parameter(Mandatory = $false)][string[]]$Requires = @(),
        [Parameter(Mandatory = $false)][ValidateSet('None', 'Explorer', 'SignOut', 'Reboot')][string]$Restart = 'None',
        [Parameter(Mandatory = $false)][ValidateSet('Full', 'Partial', 'None')][string]$Rollback = 'Full',
        [Parameter(Mandatory = $false)][ValidateSet('Low', 'Medium', 'High')][string]$Risk = 'Low',
        [Parameter(Mandatory = $false)][switch]$DataDeletion,
        [Parameter(Mandatory = $false)][switch]$Irreversible,
        [Parameter(Mandatory = $false)][switch]$ReducesProtection,
        [Parameter(Mandatory = $false)][ValidateSet('Available', 'Experimental', 'Unsupported', 'Deprecated', 'Restore-only')][string]$Lifecycle = 'Available',
        [Parameter(Mandatory = $false)][hashtable[]]$ManagedPolicy = @(),
        [Parameter(Mandatory = $false)][string[]]$StateNames = @(),
        [Parameter(Mandatory = $false)][string]$DefaultState,
        [Parameter(Mandatory = $false)][string[]]$Parameters = @(),
        [Parameter(Mandatory = $false)][scriptblock]$Detect,
        [Parameter(Mandatory = $false)][scriptblock]$Apply,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$CapabilityLoss = @()
    )

    if ($Id -notmatch $Script:WtTweakIdPattern)
    {
        throw "Tweak id '$Id' must look like 'Category.Setting' (letters, digits, dots, dashes)."
    }

    if ($Script:WtKnownCategories -notcontains $Category)
    {
        throw "Unknown tweak category '$Category' for '$Id'. Known: $($Script:WtKnownCategories -join ', ')"
    }

    if ($Script:WtCatalog.Contains($Id))
    {
        throw (Get-WtString -Key 'Error.DuplicateTweak' -Arguments @($Id))
    }

    if ($Irreversible)
    {
        $Rollback = 'None'
    }

    $Tweak = [pscustomobject]@{
        PSTypeName         = 'WindowsTweaker.Tweak'
        Id                 = $Id
        Category           = $Category
        Name               = $Name
        Description        = $Description
        Impact             = $Impact
        Scope              = $Scope
        Privilege          = $Privilege
        SupportedOS        = $SupportedOS
        MinBuild           = $MinBuild
        Requires           = $Requires
        Restart            = $Restart
        Rollback           = $Rollback
        Lifecycle          = $Lifecycle
        Risk               = $Risk
        DataDeletion       = [bool]$DataDeletion
        Irreversible       = [bool]$Irreversible
        ReducesProtection  = [bool]$ReducesProtection
        ManagedPolicy      = @($ManagedPolicy)
        StateNames         = @($StateNames)
        DefaultState       = $DefaultState
        Parameters         = @($Parameters)
        CapabilityLoss     = @($CapabilityLoss)
        Detect             = $Detect
        Apply              = $Apply
    }

    $Script:WtCatalog[$Id] = $Tweak
    return $Tweak
}

<#
.SYNOPSIS
    Registers a declarative registry tweak.
.PARAMETER States
    Hashtable of state name -> array of operation descriptors. Each state describes
    the complete set of operations needed to reach it (including removing policy
    values that would otherwise override the setting).
.PARAMETER Detection
    Optional explicit detection: @{ Path; Name; EnabledValues = @(); DisabledValues = @() }.
    Defaults to the first RegistrySet of the Enabled/Disabled state.
.PARAMETER ManagedPolicy
    Registry values that indicate the setting is governed by an organization policy.
#>
function New-WtRegistryTweak
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][hashtable]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Description,
        [Parameter(Mandatory = $true)][hashtable]$Impact,
        [Parameter(Mandatory = $true)][hashtable]$States,
        [Parameter(Mandatory = $false)][string]$Scope = 'User',
        [Parameter(Mandatory = $false)][ValidateSet('None', 'Admin')][string]$Privilege = 'None',
        [Parameter(Mandatory = $false)][string[]]$SupportedOS = @('Windows10', 'Windows11'),
        [Parameter(Mandatory = $false)][int]$MinBuild = 0,
        [Parameter(Mandatory = $false)][string[]]$Requires = @(),
        [Parameter(Mandatory = $false)][ValidateSet('None', 'Explorer', 'SignOut', 'Reboot')][string]$Restart = 'None',
        [Parameter(Mandatory = $false)][ValidateSet('Full', 'Partial', 'None')][string]$Rollback = 'Full',
        [Parameter(Mandatory = $false)][ValidateSet('Low', 'Medium', 'High')][string]$Risk = 'Low',
        [Parameter(Mandatory = $false)][hashtable]$Detection,
        [Parameter(Mandatory = $false)][ValidateSet('Available', 'Experimental', 'Unsupported', 'Deprecated', 'Restore-only')][string]$Lifecycle = 'Available',
        [Parameter(Mandatory = $false)][hashtable[]]$ManagedPolicy = @(),
        [Parameter(Mandatory = $false)][switch]$ReducesProtection,
        [Parameter(Mandatory = $false)][string[]]$StateNames = @(),
        [Parameter(Mandatory = $false)][string]$DefaultState = 'Enabled',
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$CapabilityLoss = @()
    )

    $StateKeys = @($States.Keys)
    if ($StateNames.Count -eq 0)
    {
        $StateNames = $StateKeys
    }
    else
    {
        $Unknown = @($StateNames | Where-Object { $StateKeys -notcontains $_ })
        $Missing = @($StateKeys | Where-Object { $StateNames -notcontains $_ })
        if ($Unknown.Count -gt 0 -or $Missing.Count -gt 0)
        {
            throw "Tweak ${Id}: -StateNames must list exactly the states defined in -States (unknown: $($Unknown -join ', '); missing: $($Missing -join ', '))."
        }
    }

    if ($StateNames -notcontains $DefaultState)
    {
        throw "Tweak ${Id}: -DefaultState '$DefaultState' is not one of the declared states ($($StateNames -join ', '))."
    }

    if ($StateNames.Count -eq 0)
    {
        throw "Tweak $Id declares no states."
    }

    foreach ($StateName in $StateNames)
    {
        $Operations = @($States[$StateName])
        if ($Operations.Count -eq 0)
        {
            throw "Tweak $Id state '$StateName' has no operations."
        }

        # Normalise to hashtables and validate eagerly: a malformed definition must
        # fail at import time, not halfway through a change.
        $Normalised = @()
        foreach ($Operation in $Operations)
        {
            $Table = @{}
            foreach ($Property in $Operation.GetEnumerator())
            {
                $Table[$Property.Key] = $Property.Value
            }
            Assert-WtOperation -Operation $Table -Context " (tweak: $Id, state: $StateName)"
            $Normalised += $Table
        }
        $States[$StateName] = $Normalised
    }

    if (-not $Detection)
    {
        $Base = Get-WtPrimaryRegistryOperation -Operations @($States[$DefaultState])
        if (-not $Base)
        {
            throw "Tweak $Id cannot auto-detect: state '$DefaultState' has no RegistrySet operation. Supply -Detection."
        }

        $Map = [ordered]@{ $DefaultState = @($Base.Value) }
        foreach ($StateName in $StateNames)
        {
            if ($StateName -eq $DefaultState)
            {
                continue
            }

            $Operation = Get-WtPrimaryRegistryOperation -Operations @($States[$StateName])
            if ($Operation)
            {
                $Map[$StateName] = @($Operation.Value)
            }
        }

        $Detection = @{
            Path = $Base.Path
            Name = $Base.Name
            Map  = $Map
        }
    }
    elseif ($Detection.ContainsKey('EnabledValues') -and -not $Detection.ContainsKey('Map'))
    {
        # Two-state shorthand is still supported.
        $Detection.Map = [ordered]@{
            ($DefaultState) = @($Detection.EnabledValues)
        }
        if ($Detection.ContainsKey('DisabledValues'))
        {
            $Alternate = @($StateNames | Where-Object { $_ -ne $DefaultState } | Select-Object -First 1)
            if ($Alternate)
            {
                $Detection.Map[$Alternate] = @($Detection.DisabledValues)
            }
        }
    }

    foreach ($Key in @($Detection.Map.Keys))
    {
        if ($StateNames -notcontains $Key)
        {
            throw "Tweak $Id detection maps unknown state '$Key'. Declared states: $($StateNames -join ', ')."
        }
    }

    $Detect = {
        param ($Tweak, $Arguments)

        if ($Arguments -and $Arguments.ContainsKey('Detection'))
        {
            $Spec = $Arguments.Detection
        }
        else
        {
            $Spec = $Tweak.Detection
        }

        $State = Get-WtRegistryState -Path $Spec.Path -Name $Spec.Name
        if (-not $State.Available)
        {
            return [pscustomobject]@{ State = 'Unsupported'; Reason = 'Registry provider unavailable.' }
        }

        if (-not $State.ValueExists)
        {
            # The value is absent: report the literal truth and let the caller decide.
            return [pscustomobject]@{ State = 'Unknown'; Reason = "Value not present: $($Spec.Path)\$($Spec.Name)" }
        }

        foreach ($Candidate in @($Spec.Map.Keys))
        {
            if (Test-WtValueEqual -Left $State.Value -Right @($Spec.Map[$Candidate]))
            {
                return [pscustomobject]@{ State = $Candidate }
            }
        }

        return [pscustomobject]@{ State = 'Unknown'; Reason = "Value '$($State.Value)' does not match any known state." }
    }

    $Apply = {
        param ($Tweak, $State, $Arguments)

        if (-not $Tweak.States.ContainsKey($State))
        {
            return New-WtOperationResult -Status 'failed' -Operation 'Apply' -Target $Tweak.Id -Message (Get-WtString -Key 'Error.InvalidState' -Arguments @($State, $Tweak.Id, ($Tweak.States.Keys -join ', ')))
        }

        return @(Invoke-WtOperationList -Operations @($Tweak.States[$State]) -TweakId $Tweak.Id)
    }

    $Tweak = New-WtTweak -Id $Id -Category $Category -Name $Name -Description $Description -Impact $Impact `
        -Scope $Scope -Privilege $Privilege -SupportedOS $SupportedOS -MinBuild $MinBuild -Requires $Requires `
        -Restart $Restart -Rollback $Rollback -Risk $Risk -ManagedPolicy $ManagedPolicy -ReducesProtection:$ReducesProtection `
        -Lifecycle $Lifecycle -StateNames $StateNames -DefaultState $DefaultState -Detect $Detect -Apply $Apply `
        -CapabilityLoss $CapabilityLoss

    $Tweak | Add-Member -NotePropertyName States -NotePropertyValue $States -Force
    $Tweak | Add-Member -NotePropertyName Detection -NotePropertyValue $Detection -Force
    return $Tweak
}

<#
.SYNOPSIS
    Registers a tweak whose behaviour is implemented with the provider functions.
.PARAMETER Detect
    Script block receiving ($Tweak, $Arguments); must return an object with a State
    property and must not write anything.
.PARAMETER Apply
    Script block receiving ($Tweak, $State, $Arguments); must perform every change
    through the provider functions and return their results.
#>
function New-WtScriptTweak
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][hashtable]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Description,
        [Parameter(Mandatory = $true)][hashtable]$Impact,
        [Parameter(Mandatory = $true)][scriptblock]$Detect,
        [Parameter(Mandatory = $true)][scriptblock]$Apply,
        [Parameter(Mandatory = $false)][string[]]$StateNames = @('Enabled', 'Disabled'),
        [Parameter(Mandatory = $false)][string]$DefaultState = 'Enabled',
        [Parameter(Mandatory = $false)][string]$Scope = 'User',
        [Parameter(Mandatory = $false)][ValidateSet('None', 'Admin')][string]$Privilege = 'None',
        [Parameter(Mandatory = $false)][string[]]$SupportedOS = @('Windows10', 'Windows11'),
        [Parameter(Mandatory = $false)][int]$MinBuild = 0,
        [Parameter(Mandatory = $false)][string[]]$Requires = @(),
        [Parameter(Mandatory = $false)][ValidateSet('None', 'Explorer', 'SignOut', 'Reboot')][string]$Restart = 'None',
        [Parameter(Mandatory = $false)][ValidateSet('Full', 'Partial', 'None')][string]$Rollback = 'Full',
        [Parameter(Mandatory = $false)][ValidateSet('Low', 'Medium', 'High')][string]$Risk = 'Low',
        [Parameter(Mandatory = $false)][switch]$DataDeletion,
        [Parameter(Mandatory = $false)][switch]$Irreversible,
        [Parameter(Mandatory = $false)][switch]$ReducesProtection,
        [Parameter(Mandatory = $false)][ValidateSet('Available', 'Experimental', 'Unsupported', 'Deprecated', 'Restore-only')][string]$Lifecycle = 'Available',
        [Parameter(Mandatory = $false)][hashtable[]]$ManagedPolicy = @(),
        [Parameter(Mandatory = $false)][string[]]$Parameters = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$CapabilityLoss = @()
    )

    return New-WtTweak -Id $Id -Category $Category -Name $Name -Description $Description -Impact $Impact `
        -Scope $Scope -Privilege $Privilege -SupportedOS $SupportedOS -MinBuild $MinBuild -Requires $Requires `
        -Restart $Restart -Rollback $Rollback -Risk $Risk -DataDeletion:$DataDeletion -Irreversible:$Irreversible -ReducesProtection:$ReducesProtection -ManagedPolicy $ManagedPolicy `
        -Lifecycle $Lifecycle -StateNames $StateNames -DefaultState $DefaultState -Parameters $Parameters -Detect $Detect -Apply $Apply `
        -CapabilityLoss $CapabilityLoss
}

<#
.SYNOPSIS
    Returns catalog tweaks matching the filter.
#>
function Get-WtTweakInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$Id,
        [Parameter(Mandatory = $false)][string]$Category,
        [Parameter(Mandatory = $false)][string]$Search
    )

    $Tweaks = @($Script:WtCatalog.Values)

    if ($Id)
    {
        $Tweaks = @($Tweaks | Where-Object { $_.Id -eq $Id })

        # A renamed id keeps working: lookup resolves through the migration registry, so a
        # preset, an entry or a command that names the old id still finds the definition.
        if ($Tweaks.Count -eq 0)
        {
            $Resolved = Resolve-WtTweakIdInternal -Id $Id
            if ($Resolved.Tweak -and $Resolved.Id -ne $Id)
            {
                $Tweaks = @($Resolved.Tweak)
            }
        }
    }

    if ($Category)
    {
        $Tweaks = @($Tweaks | Where-Object { $_.Category -eq $Category })
    }

    if ($Search)
    {
        $Tweaks = @($Tweaks | Where-Object {
            $_.Id -like "*$Search*" -or
            (Get-WtText -Value $_.Name) -like "*$Search*" -or
            (Get-WtText -Value $_.Description) -like "*$Search*"
        })
    }

    return @($Tweaks | Sort-Object -Property Category, Id)
}

<#
.SYNOPSIS
    Returns the catalog categories that currently contain tweaks.
#>
function Get-WtCategoryInternal
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return @($Script:WtCatalog.Values | Select-Object -ExpandProperty Category -Unique | Sort-Object)
}

#endregion Tweak constructors
