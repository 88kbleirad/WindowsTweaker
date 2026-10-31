# WindowsTweaker - canonical configuration targets.
#
# Every configuration target this tool can read or write gets one canonical identity, so
# two tweaks (or a tweak and a preset) that touch the same setting can be compared without
# string guessing: 'reg:HKCU:\SOFTWARE\X\ENABLED', 'svc:DIAGTRACK', 'task:\MICROSOFT\...',
# 'dns:7', 'defender:PUAPROTECTION', 'appx:MICROSOFT.WINDOWS.PHOTOS'.
#
# The identity is normalised for comparison (registry paths, value names, service names,
# task paths, package names and Defender preference names are case-insensitive on Windows).
# The original spelling travels beside it as a label, because an identity is meant to be
# compared, not read.
#
# Nothing in this file writes: the readers delegate to the provider read functions and
# report one of four value states explicitly - Absent, Unreadable, Empty or Zero - because
# collapsing them would make a preview lie ("no value" is not "a value of 0", and "cannot
# be read" is not "not set").

$Script:WtTargetIdentityClasses = @(
    'Registry',        # reg:<path>\<name>
    'RegistryKey',     # regkey:<path>
    'Service',         # svc:<name>
    'ScheduledTask',   # task:<path>\<name>
    'FirewallGroup',   # fw:<group>
    'DnsServer',       # dns:<interface index or guid>
    'AdapterPower',    # adapter:<interface index>
    'MpPreference',    # defender:<name>
    'AppxPackage'      # appx:<package name>
)

<#
.SYNOPSIS
    Normalises one identity component for comparison.
.DESCRIPTION
    Windows treats registry paths, value names, service names, task paths, firewall group
    names, package names and Defender preference names case-insensitively, so the identity
    upper-cases them. Whitespace is trimmed because trailing spaces in a label are never
    meaningful for comparison.
#>
function ConvertTo-WtTargetIdentityPart
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value))
    {
        return ''
    }

    return $Value.Trim().ToUpperInvariant()
}

<#
.SYNOPSIS
    Builds the canonical identity of one target.
.PARAMETER Class
    Registry, RegistryKey, Service, ScheduledTask, FirewallGroup, DnsServer, AdapterPower,
    MpPreference or AppxPackage.
#>
function New-WtTargetIdentity
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('Registry', 'RegistryKey', 'Service', 'ScheduledTask', 'FirewallGroup', 'DnsServer', 'AdapterPower', 'MpPreference', 'AppxPackage')][string]$Class,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Path = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Name = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Group = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Interface = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Package = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Preference = ''
    )

    switch ($Class)
    {
        'Registry'
        {
            $ValueName = if ([string]::IsNullOrEmpty($Name)) { '(DEFAULT)' } else { ConvertTo-WtTargetIdentityPart -Value $Name }
            return "reg:$(ConvertTo-WtTargetIdentityPart -Value $Path)\$ValueName"
        }
        'RegistryKey' { return "regkey:$(ConvertTo-WtTargetIdentityPart -Value $Path)" }
        'Service' { return "svc:$(ConvertTo-WtTargetIdentityPart -Value $Name)" }
        'ScheduledTask'
        {
            $TaskPath = (ConvertTo-WtTargetIdentityPart -Value $Path).TrimEnd('\')
            return "task:$TaskPath\$(ConvertTo-WtTargetIdentityPart -Value $Name)"
        }
        'FirewallGroup' { return "fw:$(ConvertTo-WtTargetIdentityPart -Value $Group)" }
        'DnsServer' { return "dns:$(ConvertTo-WtTargetIdentityPart -Value $Interface)" }
        'AdapterPower' { return "adapter:$(ConvertTo-WtTargetIdentityPart -Value $Interface)" }
        'MpPreference' { return "defender:$(ConvertTo-WtTargetIdentityPart -Value $Preference)" }
        'AppxPackage' { return "appx:$(ConvertTo-WtTargetIdentityPart -Value $Package)" }
    }

    return ''
}

<#
.SYNOPSIS
    Splits a canonical identity back into its class and parts.
.DESCRIPTION
    Used by the reader dispatcher and by the display formatter. An identity that does not
    parse yields Class 'Unknown' rather than throwing: an unknown target is still worth
    reporting in a preview.
#>
function Get-WtTargetIdentityParts
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Identity)

    $Result = @{
        Class      = 'Unknown'
        Path       = ''
        Name       = ''
        Group      = ''
        Interface  = ''
        Package    = ''
        Preference = ''
        Identity   = $Identity
    }

    if ([string]::IsNullOrEmpty($Identity))
    {
        return $Result
    }

    $Separator = $Identity.IndexOf(':')
    if ($Separator -lt 1)
    {
        return $Result
    }

    $Prefix = $Identity.Substring(0, $Separator).ToLowerInvariant()
    $Tail = $Identity.Substring($Separator + 1)

    switch ($Prefix)
    {
        'reg'
        {
            $Result.Class = 'Registry'
            $Split = $Tail.LastIndexOf('\')
            if ($Split -ge 0)
            {
                $Result.Path = $Tail.Substring(0, $Split)
                $Result.Name = $Tail.Substring($Split + 1)
            }
            else
            {
                $Result.Path = $Tail
            }
        }
        'regkey' { $Result.Class = 'RegistryKey'; $Result.Path = $Tail }
        'svc' { $Result.Class = 'Service'; $Result.Name = $Tail }
        'task'
        {
            $Result.Class = 'ScheduledTask'
            $Split = $Tail.LastIndexOf('\')
            if ($Split -ge 0)
            {
                $Result.Path = $Tail.Substring(0, $Split)
                $Result.Name = $Tail.Substring($Split + 1)
            }
            else
            {
                $Result.Name = $Tail
            }
        }
        'fw' { $Result.Class = 'FirewallGroup'; $Result.Group = $Tail }
        'dns' { $Result.Class = 'DnsServer'; $Result.Interface = $Tail }
        'adapter' { $Result.Class = 'AdapterPower'; $Result.Interface = $Tail }
        'defender' { $Result.Class = 'MpPreference'; $Result.Preference = $Tail }
        'appx' { $Result.Class = 'AppxPackage'; $Result.Package = $Tail }
    }

    return $Result
}

<#
.SYNOPSIS
    Returns the identity of a captured state record.
.DESCRIPTION
    The captured record is the authoritative description of what a change actually touched,
    so it is the source of truth for the journal and for drift comparison.
#>
function Get-WtRecordIdentity
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Record)

    switch ([string]$Record.resource)
    {
        'Registry' { return (New-WtTargetIdentity -Class 'Registry' -Path ([string]$Record.path) -Name ([string]$Record.name)) }
        'RegistryKey' { return (New-WtTargetIdentity -Class 'RegistryKey' -Path ([string]$Record.path)) }
        'Service' { return (New-WtTargetIdentity -Class 'Service' -Name ([string]$Record.name)) }
        'ScheduledTask' { return (New-WtTargetIdentity -Class 'ScheduledTask' -Path ([string]$Record.path) -Name ([string]$Record.name)) }
        'FirewallGroup' { return (New-WtTargetIdentity -Class 'FirewallGroup' -Group ([string]$Record.group)) }
        'DnsServer' { return (New-WtTargetIdentity -Class 'DnsServer' -Interface ([string]$Record.interfaceIndex)) }
        'AdapterPower' { return (New-WtTargetIdentity -Class 'AdapterPower' -Interface ([string]$Record.interfaceIndex)) }
        'MpPreference' { return (New-WtTargetIdentity -Class 'MpPreference' -Preference ([string]$Record.name)) }
        'AppxPackage' { return (New-WtTargetIdentity -Class 'AppxPackage' -Package ([string]$Record.name)) }
    }

    return ''
}

<#
.SYNOPSIS
    Returns the identity of an intended operation descriptor.
.DESCRIPTION
    Declarative tweaks describe their writes as operation lists, so a preview can name the
    targets before anything runs. A descriptor whose kind has no identity mapping yields ''
    and the caller falls back to the captured records or to the reported target label.
#>
function Get-WtOperationIdentity
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][hashtable]$Operation)

    switch ([string]$Operation.Kind)
    {
        'RegistrySet' { return (New-WtTargetIdentity -Class 'Registry' -Path ([string]$Operation.Path) -Name ([string]$Operation.Name)) }
        'RegistryRemove' { return (New-WtTargetIdentity -Class 'Registry' -Path ([string]$Operation.Path) -Name ([string]$Operation.Name)) }
        'RegistryKeyCreate' { return (New-WtTargetIdentity -Class 'RegistryKey' -Path ([string]$Operation.Path)) }
        'RegistryKeyRemove' { return (New-WtTargetIdentity -Class 'RegistryKey' -Path ([string]$Operation.Path)) }
        'Service' { return (New-WtTargetIdentity -Class 'Service' -Name ([string]$Operation.Name)) }
        'ScheduledTask' { return (New-WtTargetIdentity -Class 'ScheduledTask' -Path ([string]$Operation.Path) -Name ([string]$Operation.Name)) }
        'FirewallGroup' { return (New-WtTargetIdentity -Class 'FirewallGroup' -Group ([string]$Operation.Group)) }
    }

    return ''
}

<#
.SYNOPSIS
    Returns a readable label for an identity (the original spelling is preferred).
#>
function Format-WtTargetIdentity
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Identity,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Label = ''
    )

    if ($Label)
    {
        return $Label
    }

    $Parts = Get-WtTargetIdentityParts -Identity $Identity
    switch ($Parts.Class)
    {
        'Registry'
        {
            $Name = if ($Parts.Name -eq '(DEFAULT)') { '' } else { $Parts.Name }
            return "$($Parts.Path)\$Name".TrimEnd('\')
        }
        'RegistryKey' { return $Parts.Path }
        'Service' { return $Parts.Name }
        'ScheduledTask' { return "$($Parts.Path)\$($Parts.Name)" }
        'FirewallGroup' { return $Parts.Group }
        'DnsServer' { return "interface $($Parts.Interface)" }
        'AdapterPower' { return "interface $($Parts.Interface)" }
        'MpPreference' { return $Parts.Preference }
        'AppxPackage' { return $Parts.Package }
    }

    return $Identity
}

<#
.SYNOPSIS
    Reports whether two identities refer to the same target or to overlapping ones.
.DESCRIPTION
    Same identity is an exact overlap. A registry key also overlaps every value inside it
    (a recursive key removal deletes the values underneath), and a key overlaps its own
    subkeys, which is what makes "tweak A clears a policy key, tweak B writes a value in
    it" a conflict worth explaining instead of a race to be discovered later.
#>
function Test-WtTargetOverlap
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Right
    )

    if ([string]::IsNullOrEmpty($Left) -or [string]::IsNullOrEmpty($Right))
    {
        return $false
    }

    if ($Left -eq $Right)
    {
        return $true
    }

    $LeftParts = Get-WtTargetIdentityParts -Identity $Left
    $RightParts = Get-WtTargetIdentityParts -Identity $Right

    foreach ($Pair in @(@($LeftParts, $RightParts), @($RightParts, $LeftParts)))
    {
        $Key = $Pair[0]
        $Other = $Pair[1]

        if ($Key.Class -eq 'RegistryKey')
        {
            # A value lives *in* a key, so its path equals the key path; a subkey (or a value
            # in a subkey) has the key path as a prefix.
            if ($Other.Class -in 'Registry', 'RegistryKey' -and $Other.Path -eq $Key.Path)
            {
                return $true
            }

            if ($Other.Class -in 'Registry', 'RegistryKey' -and $Other.Path.StartsWith("$($Key.Path)\", [System.StringComparison]::Ordinal))
            {
                return $true
            }
        }
    }

    return $false
}

<#
.SYNOPSIS
    Classifies one value: absent, unreadable, empty, zero or a concrete value.
.DESCRIPTION
    The distinction is deliberate and never collapsed:
      Absent     - the key or the value does not exist
      Unreadable - the platform or the account cannot read it (no cmdlet, denied)
      Empty      - it exists and holds nothing (empty string, empty list)
      Zero       - it exists and holds numeric zero or a boolean false
      Value      - anything else, with its kind
#>
function Get-WtTargetValueKind
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$Value)

    if ($null -eq $Value)
    {
        return 'Empty'
    }

    if ($Value -is [string])
    {
        return $(if ($Value.Length -eq 0) { 'Empty' } else { 'Value' })
    }

    if ($Value -is [bool])
    {
        return $(if ($Value) { 'Value' } else { 'Zero' })
    }

    if ($Value -is [System.Collections.IEnumerable])
    {
        return $(if (@($Value).Count -eq 0) { 'Empty' } else { 'Value' })
    }

    if ($Value -is [ValueType])
    {
        $Number = 0.0
        if ([double]::TryParse([string]$Value, [ref]$Number) -and $Number -eq 0)
        {
            return 'Zero'
        }
    }

    return 'Value'
}

<#
.SYNOPSIS
    Renders one value for display without losing what it is.
.DESCRIPTION
    Invariant culture, no padding, and each container shape spelled out, so a preview shows
    `(absent)`, `(unreadable)`, `""` and `0` as four different things.
#>
function ConvertTo-WtTargetDisplayValue
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Value,
        [Parameter(Mandatory = $false)][string]$ValueKind = ''
    )

    if ($ValueKind -eq 'Absent') { return '(absent)' }
    if ($ValueKind -eq 'Unreadable') { return '(unreadable)' }
    if ($ValueKind -eq 'Empty') { return '(empty)' }

    if ($null -eq $Value) { return '(empty)' }

    if ($Value -is [bool]) { return $(if ($Value) { 'True' } else { 'False' }) }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [byte[]]) { return ("0x" + (($Value | ForEach-Object { $_.ToString('x2', [System.Globalization.CultureInfo]::InvariantCulture) }) -join '')) }

    if ($Value -is [System.Collections.IEnumerable])
    {
        return (@($Value) | ForEach-Object { [string]$_ }) -join '; '
    }

    return [string]$Value
}

<#
.SYNOPSIS
    Reads the current state of one target, read-only.
.DESCRIPTION
    Dispatches to the provider reader that exists for the target class. A class without a
    reader reports `Unreadable` with the reason, which is the honest answer: the interface
    then shows "cannot verify" instead of pretending a target matches.
#>
function Get-WtTargetState
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Identity)

    $Parts = Get-WtTargetIdentityParts -Identity $Identity
    $Result = @{
        Identity   = $Identity
        Class      = $Parts.Class
        Available  = $false
        Exists     = $false
        ValueKind  = 'Unreadable'
        Value      = $null
        Kind       = ''
        Reader     = ''
        Reason     = ''
        Label      = (Format-WtTargetIdentity -Identity $Identity)
    }

    switch ($Parts.Class)
    {
        'Registry'
        {
            $Result.Reader = 'Get-WtRegistryState'
            $Name = if ($Parts.Name -eq '(DEFAULT)') { '' } else { $Parts.Name }
            $State = Get-WtRegistryState -Path $Parts.Path -Name $Name

            if (-not $State.Available)
            {
                $Result.Reason = 'Registry provider is not available on this platform.'
                break
            }

            $Result.Available = $true
            $Result.Exists = [bool]($State.KeyExists -and $State.ValueExists)

            if (-not $State.KeyExists -or -not $State.ValueExists)
            {
                $Result.ValueKind = 'Absent'
                $Result.Reason = $(if (-not $State.KeyExists) { 'The key does not exist.' } else { 'The value is not set.' })
                break
            }

            $Result.ValueKind = Get-WtTargetValueKind -Value $State.Value
            $Result.Value = $State.Value
            $Result.Kind = [string]$State.Kind
        }

        'RegistryKey'
        {
            $Result.Reader = 'Test-WtRegistryKeyRaw'
            if (-not (Test-WtRegistryAvailable))
            {
                $Result.Reason = 'Registry provider is not available on this platform.'
                break
            }

            $Content = Get-WtRegistryKeyContentRaw -Path $Parts.Path
            $Result.Available = $true
            $Result.Exists = [bool]$Content.Exists
            if (-not $Content.Exists)
            {
                $Result.ValueKind = 'Absent'
                $Result.Reason = 'The key does not exist.'
                break
            }

            $Members = @()
            if ($Content.Values -gt 0) { $Members += "$($Content.Values) value(s)" }
            if ($Content.SubKeys -gt 0) { $Members += "$($Content.SubKeys) subkey(s)" }
            $Result.ValueKind = $(if ($Members.Count -eq 0) { 'Empty' } else { 'Value' })
            $Result.Value = ($Members -join ', ')
        }

        'MpPreference'
        {
            $Result.Reader = 'Get-WtMpPreferenceState'
            $State = Get-WtMpPreferenceState -Name $Parts.Preference
            if (-not $State.Available)
            {
                $Result.Reason = 'Defender preferences are not readable on this platform.'
                break
            }

            $Result.Available = $true
            $Result.Exists = $true
            $Result.ValueKind = Get-WtTargetValueKind -Value $State.Value
            $Result.Value = $State.Value
        }

        'DnsServer'
        {
            $Result.Reader = 'Get-WtDnsState'
            $Index = 0
            if (-not [int]::TryParse($Parts.Interface, [ref]$Index))
            {
                $Result.Reason = 'The interface index in this identity is not numeric.'
                break
            }

            $State = Get-WtDnsState -InterfaceIndex $Index
            if (-not $State.Available)
            {
                $Result.Reason = 'The DnsClient module is not available on this platform.'
                break
            }

            $Result.Available = $true
            $Result.Exists = $true
            $Addresses = @($State.ServerAddresses)
            $Result.ValueKind = $(if ($State.Automatic) { 'Empty' } else { 'Value' })
            $Result.Value = $(if ($State.Automatic) { 'automatic' } else { $Addresses -join ', ' })
        }

        default
        {
            $Result.Reason = "No read-back reader is implemented for '$($Parts.Class)' targets on this platform."
        }
    }

    return $Result
}

<#
.SYNOPSIS
    Compares two values of the same target for verification (kind-aware, order-insensitive
    for lists).
#>
function Test-WtTargetValueMatch
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Left,
        [Parameter(Mandatory = $false)][object]$Right
    )

    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }

    if ($Left -is [bool] -or $Right -is [bool])
    {
        return ([string]([bool]$Left) -eq [string]([bool]$Right))
    }

    if ($Left -is [System.Collections.IEnumerable] -and $Left -isnot [string])
    {
        $LeftItems = @($Left | ForEach-Object { ConvertTo-WtTargetDisplayValue -Value $_ })
        $RightItems = @($Right | ForEach-Object { ConvertTo-WtTargetDisplayValue -Value $_ })
        return (@(Compare-Object -ReferenceObject $LeftItems -DifferenceObject $RightItems -SyncWindow 0).Count -eq 0)
    }

    return ((ConvertTo-WtTargetDisplayValue -Value $Left) -eq (ConvertTo-WtTargetDisplayValue -Value $Right))
}
