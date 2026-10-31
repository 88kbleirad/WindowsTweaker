# WindowsTweaker - registry provider.
#
# Layering (deliberate, keeps the code testable):
#   *-Raw          : thin wrappers over the PowerShell registry provider. These are the
#                    only functions that talk to the registry; tests replace them.
#   Get-WtRegistryState / Set-WtRegistryValue / Remove-WtRegistryValue /
#   Remove-WtRegistryKey : capture the previous state, honour -WhatIf, verify the write
#                   and report a per-operation status.
#
# Nothing here invents a default value on rollback: the previous value, its kind and
# even whether the value/key existed at all are stored before the change.

$Script:WtRegistryKinds = @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')

<#
.SYNOPSIS
    True when the registry provider is usable in this session.
#>
function Test-WtRegistryAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if (-not $IsWindows)
    {
        return $false
    }

    return [bool](Get-PSDrive -Name HKLM -ErrorAction Ignore)
}

<#
.SYNOPSIS
    Normalises a registry value name.
.DESCRIPTION
    '(default)' - the name the PowerShell registry provider uses for the unnamed
    value of a key - is mapped to the empty string, which is how the .NET registry API
    and the provider's read path represent it. Without this, a tweak that writes the
    unnamed value would verify as "not written" and capture the wrong previous state.
#>
function Resolve-WtRegistryValueName
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrEmpty($Name) -or $Name -ieq '(default)')
    {
        return ''
    }

    return $Name
}

<#
.SYNOPSIS
    Opens a registry key with the .NET API (Windows only).
.DESCRIPTION
    Used for the unnamed value, which the PowerShell provider handles inconsistently.
    Returns $null when the registry hive is unavailable.
#>
function Get-WtRegistryDotNetKey
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Writable
    )

    if (-not $IsWindows)
    {
        return $null
    }

    if ($Path -notmatch '^(HKLM|HKCU|HKCR|HKU|HKCC):\(.*)$')
    {
        return $null
    }

    $Hive = $Matches[1]
    $SubKey = $Matches[2]

    $Base = switch ($Hive)
    {
        'HKLM' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKCU' { [Microsoft.Win32.Registry]::CurrentUser }
        'HKCR' { [Microsoft.Win32.Registry]::ClassesRoot }
        'HKU' { [Microsoft.Win32.Registry]::Users }
        'HKCC' { [Microsoft.Win32.Registry]::CurrentConfig }
    }

    try
    {
        if ($Writable)
        {
            return $Base.CreateSubKey($SubKey, $true)
        }

        return $Base.OpenSubKey($SubKey, $false)
    }
    catch
    {
        return $null
    }
}

<#
.SYNOPSIS
    Raw key existence test.
#>
function Test-WtRegistryKeyRaw
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    return [bool](Test-Path -LiteralPath $Path -ErrorAction Ignore)
}

<#
.SYNOPSIS
    Raw read of a registry value (existence plus kind).
.DESCRIPTION
    Returns key existence, value existence, the value kind (when the provider
    exposes it) and the value data.
#>
function Get-WtRegistryValueStateRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Name
    )

    $Name = Resolve-WtRegistryValueName -Name $Name

    $Result = @{
        KeyExists   = $false
        ValueExists = $false
        Kind        = $null
        KindInferred = $false
        Value       = $null
    }

    if (-not (Test-Path -LiteralPath $Path -ErrorAction Ignore))
    {
        return $Result
    }

    $Result.KeyExists = $true

    try
    {
        $Key = Get-Item -LiteralPath $Path -ErrorAction Stop
    }
    catch
    {
        return $Result
    }

    $Names = @($Key.GetValueNames())
    if ($Names -notcontains $Name)
    {
        return $Result
    }

    $Result.ValueExists = $true
    $Result.Value = $Key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')

    try
    {
        $KindId = [int]$Key.GetValueKind($Name)
        $KindName = Resolve-WtRegistryKind -Kind $KindId
        if ($KindName)
        {
            $Result.Kind = $KindName
        }
    }
    catch
    {
        # Provider cannot report the kind: infer it from the .NET type of the data.
        $Result.KindInferred = $true
    }

    if (-not $Result.Kind)
    {
        $Result.KindInferred = $true
        $Result.Kind = switch ($Result.Value)
        {
            { $_ -is [byte[]] } { 'Binary' }
            { $_ -is [string[]] } { 'MultiString' }
            { $_ -is [int] } { 'DWord' }
            { $_ -is [uint32] } { 'DWord' }
            { $_ -is [long] } { 'QWord' }
            { $_ -is [uint64] } { 'QWord' }
            { $_ -is [string] } { 'String' }
            default { 'String' }
        }
        if ($null -eq $Result.Value)
        {
            $Result.Kind = 'String'
        }
    }

    return $Result
}

function New-WtRegistryKeyRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Path)

    New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
}

function Set-WtRegistryValueRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory = $false)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $Name = Resolve-WtRegistryValueName -Name $Name

    if (-not (Test-Path -LiteralPath $Path -ErrorAction Ignore))
    {
        New-WtRegistryKeyRaw -Path $Path
    }

    if ($Name -ne '')
    {
        New-ItemProperty -Path $Path -Name $Name -PropertyType $Kind -Value $Value -Force -ErrorAction Stop | Out-Null
        return
    }

    # Unnamed value: write it through the .NET API, which is unambiguous here.
    $Key = Get-WtRegistryDotNetKey -Path $Path -Writable
    if (-not $Key)
    {
        throw "The unnamed registry value of '$Path' cannot be written: the .NET registry API is unavailable."
    }

    try
    {
        $DotNetKind = switch ($Kind)
        {
            'String' { [Microsoft.Win32.RegistryValueKind]::String }
            'ExpandString' { [Microsoft.Win32.RegistryValueKind]::ExpandString }
            'Binary' { [Microsoft.Win32.RegistryValueKind]::Binary }
            'DWord' { [Microsoft.Win32.RegistryValueKind]::DWord }
            'MultiString' { [Microsoft.Win32.RegistryValueKind]::MultiString }
            'QWord' { [Microsoft.Win32.RegistryValueKind]::QWord }
        }

        $Key.SetValue('', $Value, $DotNetKind)
    }
    finally
    {
        $Key.Dispose()
    }
}

function Remove-WtRegistryPropertyRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Name
    )

    $Name = Resolve-WtRegistryValueName -Name $Name

    if ($Name -ne '')
    {
        Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction SilentlyContinue
        return
    }

    $Key = Get-WtRegistryDotNetKey -Path $Path -Writable
    if (-not $Key)
    {
        return
    }

    try
    {
        $Key.DeleteValue('', $false)
    }
    finally
    {
        $Key.Dispose()
    }
}

<#
.SYNOPSIS
    Raw inspection of a registry key's contents.
.DESCRIPTION
    Returns whether the key exists and how many values/subkeys it holds. Used before
    deleting a key this tool created, so the deletion never removes data that arrived
    afterwards.
#>
function Get-WtRegistryKeyContentRaw
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Path)

    $Result = @{ Exists = $false; Values = 0; SubKeys = 0; Inspected = $false }

    if (-not (Test-WtRegistryKeyRaw -Path $Path))
    {
        return $Result
    }

    $Result.Exists = $true

    try
    {
        $Key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $Result.Values = @($Key.GetValueNames()).Count
        $Result.SubKeys = @($Key.GetSubKeyNames()).Count
        $Result.Inspected = $true
    }
    catch
    {
        Write-WtLog -Level Warning -Message "Could not inspect registry key '$Path': $($_.Exception.Message)" -NoConsole
    }

    return $Result
}

<#
.SYNOPSIS
    Lists the subkey names of a registry key, or an empty list when it cannot be read.
.DESCRIPTION
    Read-only enumeration, used by the sanity scan to look at per-interface or per-task keys.
    An empty list means "no subkeys or not readable"; the caller decides which of the two it
    needs by asking Test-WtRegistryKeyRaw as well, because an unreadable key is not an empty one.
#>
function Get-WtRegistrySubKeyNamesRaw
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-WtRegistryAvailable)) { return @() }
    if (-not (Test-WtRegistryKeyRaw -Path $Path)) { return @() }

    try
    {
        $Key = Get-Item -LiteralPath $Path -ErrorAction Stop
        return @($Key.GetSubKeyNames())
    }
    catch
    {
        Write-WtLog -Level Warning -Message "Could not enumerate subkeys of '$Path': $($_.Exception.Message)" -NoConsole
        return @()
    }
}

function Remove-WtRegistryKeyRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Recurse
    )

    if ($Recurse)
    {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    else
    {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Raw snapshot of a registry key subtree (values and child keys).
.DESCRIPTION
    Used before a recursive key deletion so the deletion can be undone. Depth and
    entry counts are bounded: if a subtree is too large to capture, the caller is
    told (Truncated = $true) instead of silently producing a partial rollback.
#>
function Get-WtRegistryKeySnapshotRaw
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][int]$Depth = 3,
        [Parameter(Mandatory = $false)][int]$MaxKeys = 256
    )

    $Snapshot = [ordered]@{
        Path      = $Path
        Existed   = $false
        Values    = @()
        SubKeys   = @()
        Truncated = $false
    }

    if (-not (Test-WtRegistryKeyRaw -Path $Path))
    {
        return $Snapshot
    }

    $Snapshot.Existed = $true
    $Queue = [System.Collections.Generic.Queue[object]]::new()
    $Queue.Enqueue([pscustomobject]@{ Path = $Path; Level = 0 })
    $Visited = 0

    while ($Queue.Count -gt 0)
    {
        $Current = $Queue.Dequeue()
        $Visited++

        if ($Visited -gt $MaxKeys)
        {
            $Snapshot.Truncated = $true
            break
        }

        try
        {
            $Key = Get-Item -LiteralPath $Current.Path -ErrorAction Stop
        }
        catch
        {
            continue
        }

        $Values = @()
        foreach ($ValueName in @($Key.GetValueNames()))
        {
            $State = Get-WtRegistryValueStateRaw -Path $Current.Path -Name $ValueName
            $Values += [pscustomobject]@{
                Name  = $ValueName
                Kind  = $State.Kind
                Value = ConvertTo-WtPersistableValue -Value $State.Value
            }
        }

        $Snapshot.SubKeys += [pscustomobject]@{
            Path   = $Current.Path
            Level  = $Current.Level
            Values = $Values
        }

        if ($Current.Level -lt $Depth)
        {
            foreach ($Child in @($Key.GetSubKeyNames()))
            {
                $Queue.Enqueue([pscustomobject]@{
                    Path  = Join-Path $Current.Path $Child
                    Level = $Current.Level + 1
                })
            }
        }
        elseif (@($Key.GetSubKeyNames()).Count -gt 0)
        {
            $Snapshot.Truncated = $true
        }
    }

    return $Snapshot
}

<#
.SYNOPSIS
    Read-only registry state, used for detection and state capture.
#>
function Get-WtRegistryState
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Name
    )

    if (-not (Test-WtRegistryAvailable))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.RegistryState'
            Path       = $Path
            Name       = $Name
            Available  = $false
            KeyExists  = $false
            ValueExists = $false
            Kind       = $null
            Value      = $null
        }
    }

    $Raw = Get-WtRegistryValueStateRaw -Path $Path -Name $Name

    return [pscustomobject]@{
        PSTypeName  = 'WindowsTweaker.RegistryState'
        Path        = $Path
        Name        = $Name
        Available   = $true
        KeyExists   = $Raw.KeyExists
        ValueExists = $Raw.ValueExists
        Kind        = $Raw.Kind
        Value       = $Raw.Value
        KindInferred = $Raw.KindInferred
    }
}

<#
.SYNOPSIS
    Compares two registry values for equality, tolerating int/uint width differences.
#>
function Test-WtValueEqual
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Left,
        [Parameter(Mandatory = $false)][object]$Right
    )

    if ($null -eq $Left -and $null -eq $Right)
    {
        return $true
    }

    if ($null -eq $Left -or $null -eq $Right)
    {
        return $false
    }

    if ($Left -is [byte[]] -or $Right -is [byte[]])
    {
        return ([System.Convert]::ToBase64String([byte[]]$Left) -eq [System.Convert]::ToBase64String([byte[]]$Right))
    }

    $LeftIsEnumerable = $Left -is [System.Collections.IEnumerable] -and $Left -isnot [string]
    $RightIsEnumerable = $Right -is [System.Collections.IEnumerable] -and $Right -isnot [string]

    if ($LeftIsEnumerable -or $RightIsEnumerable)
    {
        $LeftItems = @($Left)
        $RightItems = @($Right)
        if ($LeftItems.Count -ne $RightItems.Count)
        {
            return $false
        }
        for ($i = 0; $i -lt $LeftItems.Count; $i++)
        {
            if (-not (Test-WtValueEqual -Left $LeftItems[$i] -Right $RightItems[$i]))
            {
                return $false
            }
        }
        return $true
    }

    try
    {
        return ([System.Convert]::ToInt64($Left) -eq [System.Convert]::ToInt64($Right))
    }
    catch
    {
        return ([string]$Left -eq [string]$Right)
    }
}

<#
.SYNOPSIS
    Captures the pre-change registry state into the active history entry.
#>
function Register-WtRegistryCapture
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$State
    )

    $Context = Get-WtOperationContext
    if ($null -eq $Context.HistoryEntry)
    {
        return
    }

    Add-WtStateRecord -HistoryEntry $Context.HistoryEntry -Record @{
        resource     = 'Registry'
        path         = $Path
        name         = $Name
        keyExisted   = [bool]$State.KeyExists
        valueExisted = [bool]$State.ValueExists
        kind         = $State.Kind
        value        = ConvertTo-WtPersistableValue -Value $State.Value
        kindInferred = [bool]$State.KindInferred
    }
}

<#
.SYNOPSIS
    Creates a registry key (state captured, WhatIf aware).
#>
function New-WtRegistryKey
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-WtRegistryAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation 'NewRegistryKey' -Target $Path -Message 'Registry provider is not available on this platform.'
    }

    if (Test-WtRegistryKeyRaw -Path $Path)
    {
        return New-WtOperationResult -Status 'unchanged' -Operation 'NewRegistryKey' -Target $Path -Message "Registry key already exists: $Path"
    }

    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Path, 'create registry key'))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation 'NewRegistryKey' -Target $Path -Message "Registry key creation not performed: $Path"
    }

    # The key was created by this operation; record it so rollback can remove it again
    # (only if nothing else moved in afterwards).
    $HistoryEntry = (Get-WtOperationContext).HistoryEntry
    if ($null -ne $HistoryEntry)
    {
        Add-WtStateRecord -HistoryEntry $HistoryEntry -Record @{
            resource = 'RegistryKey'
            path     = $Path
            existed  = $false
            recurse  = $false
            snapshot = $null
            truncated = $false
        }
    }

    New-WtRegistryKeyRaw -Path $Path
    return New-WtOperationResult -Status 'succeeded' -Operation 'NewRegistryKey' -Target $Path -Message "Created registry key: $Path"
}

<#
.SYNOPSIS
    Writes a registry value: captures the previous state, honours -WhatIf, verifies.
.PARAMETER Path
    Registry path, e.g. HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced
.PARAMETER Name
    Value name.
.PARAMETER Value
    Value data.
.PARAMETER Kind
    String, ExpandString, Binary, DWord, MultiString or QWord.
.PARAMETER Literal
    Do not expand REG_EXPAND_SZ; kept for callers that must preserve %VARS%.
#>
function Set-WtRegistryValue
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Name,
        [Parameter(Mandatory = $false)][object]$Value,
        [Parameter(Mandatory = $true)]
        [ValidateSet('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')]
        [string]$Kind
    )

    $Target = "$Path\$Name"
    $Operation = 'SetRegistry'

    if (-not (Test-WtRegistryAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message 'Registry provider is not available on this platform.'
    }

    $Name = Resolve-WtRegistryValueName -Name $Name
    $Target = "$Path\$Name"

    $Previous = Get-WtRegistryValueStateRaw -Path $Path -Name $Name

    if ($Previous.ValueExists -and (Test-WtValueEqual -Left $Previous.Value -Right $Value) -and ($Previous.Kind -eq $Kind -or $Previous.KindInferred))
    {
        return New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target $Target -Message "Already set: $Target = $Value"
    }

    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Target, "set registry value ($Kind)"))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Target -Message "Would set $Target = $Value"
    }

    Register-WtRegistryCapture -Path $Path -Name $Name -State $Previous

    try
    {
        Set-WtRegistryValueRaw -Path $Path -Name $Name -Value $Value -Kind $Kind
    }
    catch
    {
        Write-WtLog -Level Error -Message "Failed to write $Target" -Operation $Operation -Status 'failed' -Exception $_.Exception
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $_.Exception.Message -ErrorRecord $_
    }

    $Verify = Get-WtRegistryValueStateRaw -Path $Path -Name $Name
    if (-not $Verify.ValueExists -or -not (Test-WtValueEqual -Left $Verify.Value -Right $Value))
    {
        $Message = "Verification failed for $Target (expected '$Value', found '$($Verify.Value)')"
        Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $Message
    }

    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $Target -Message "Set $Target = $Value"
}

<#
.SYNOPSIS
    Removes a registry value (state captured, WhatIf aware, verified).
#>
function Remove-WtRegistryValue
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Name
    )

    $Target = "$Path\$Name"
    $Operation = 'RemoveRegistryValue'

    if (-not (Test-WtRegistryAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Target -Message 'Registry provider is not available on this platform.'
    }

    $Previous = Get-WtRegistryValueStateRaw -Path $Path -Name $Name
    if (-not $Previous.ValueExists)
    {
        return New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target $Target -Message "Value not present: $Target"
    }

    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Target, 'remove registry value'))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Target -Message "Would remove $Target"
    }

    Register-WtRegistryCapture -Path $Path -Name $Name -State $Previous

    Remove-WtRegistryPropertyRaw -Path $Path -Name $Name

    $Verify = Get-WtRegistryValueStateRaw -Path $Path -Name $Name
    if ($Verify.ValueExists)
    {
        $Message = "Verification failed: $Target still exists"
        Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Target -Message $Message
    }

    return New-WtOperationResult -Status 'succeeded' -Operation $Operation -Target $Target -Message "Removed $Target"
}

<#
.SYNOPSIS
    Removes a registry key (optionally recursive) with subtree capture for rollback.
.DESCRIPTION
    Recursive deletion is destructive, so the whole subtree (bounded depth) is
    captured first. When the subtree is too large to capture, the operation is
    reported as partial rollback instead of pretending to be fully reversible.
#>
function Remove-WtRegistryKey
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Recurse,
        [Parameter(Mandatory = $false)][int]$Depth = 3
    )

    $Operation = 'RemoveRegistryKey'

    if (-not (Test-WtRegistryAvailable))
    {
        return New-WtOperationResult -Status 'unsupported' -Operation $Operation -Target $Path -Message 'Registry provider is not available on this platform.'
    }

    if (-not (Test-WtRegistryKeyRaw -Path $Path))
    {
        return New-WtOperationResult -Status 'unchanged' -Operation $Operation -Target $Path -Message "Registry key not present: $Path"
    }

    # One confirmation per tweak: Invoke-WtTweak/Undo-WtTweak confirm once, and the
    # providers must not prompt again while that apply/rollback is in progress.
    if ((Get-WtOperationContext).SuppressConfirm) { $ConfirmPreference = 'None' }

    if (-not $PSCmdlet.ShouldProcess($Path, 'remove registry key'))
    {
        return New-WtOperationResult -Status (Get-WtShouldProcessStatus) -Operation $Operation -Target $Path -Message "Would remove registry key $Path"
    }

    $Snapshot = if ($Recurse)
    {
        Get-WtRegistryKeySnapshotRaw -Path $Path -Depth $Depth
    }
    else
    {
        Get-WtRegistryKeySnapshotRaw -Path $Path -Depth 0
    }

    $HistoryEntry = (Get-WtOperationContext).HistoryEntry
    if ($null -ne $HistoryEntry)
    {
        Add-WtStateRecord -HistoryEntry $HistoryEntry -Record @{
            resource  = 'RegistryKey'
            path      = $Path
            existed   = $true
            recurse   = [bool]$Recurse
            snapshot  = $Snapshot
            truncated = [bool]$Snapshot.Truncated
        }
    }

    Remove-WtRegistryKeyRaw -Path $Path -Recurse:$Recurse

    if (Test-WtRegistryKeyRaw -Path $Path)
    {
        $Message = "Verification failed: registry key still exists ($Path)"
        Write-WtLog -Level Error -Message $Message -Operation $Operation -Status 'failed'
        return New-WtOperationResult -Status 'failed' -Operation $Operation -Target $Path -Message $Message
    }

    $Status = if ($Snapshot.Truncated) { 'succeeded' } else { 'succeeded' }
    $Message = if ($Snapshot.Truncated)
    {
        "Removed $Path (subtree too large for a complete rollback capture)"
    }
    else
    {
        "Removed registry key $Path"
    }

    return New-WtOperationResult -Status $Status -Operation $Operation -Target $Path -Message $Message -PartialRollback:$Snapshot.Truncated
}
