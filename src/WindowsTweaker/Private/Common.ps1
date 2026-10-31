# WindowsTweaker - shared helpers.
# No code in this file may touch system state; these are path/format utilities only.

$Script:WtModuleRoot = $PSScriptRoot | Split-Path -Parent   # src/WindowsTweaker
$Script:WtProjectRoot = $Script:WtModuleRoot | Split-Path -Parent | Split-Path -Parent
$Script:WtDataDirectory = Join-Path $Script:WtModuleRoot 'Data'

<#
.SYNOPSIS
    Root directory for user-writable WindowsTweaker data (state store, logs).
.DESCRIPTION
    Order of precedence:
      1. $env:WT_DATA_ROOT            (used by tests and portable installs)
      2. %LOCALAPPDATA%\WindowsTweaker on Windows
      3. ~/.local/state/WindowsTweaker elsewhere
    The directory is only created when something is actually written to it.
#>
function Get-WtDataRoot
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($env:WT_DATA_ROOT)
    {
        return [System.IO.Path]::GetFullPath($env:WT_DATA_ROOT)
    }

    if ($IsWindows)
    {
        $Base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
    }
    else
    {
        $Base = if ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path $HOME '.local/state' }
    }

    return (Join-Path $Base 'WindowsTweaker')
}

function Get-WtStatePath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($env:WT_STATE_PATH)
    {
        return [System.IO.Path]::GetFullPath($env:WT_STATE_PATH)
    }

    return (Join-Path (Get-WtDataRoot) 'state.json')
}

<#
.SYNOPSIS
    Path of the user settings file (interface preferences).
.DESCRIPTION
    Kept separate from the rollback state store: the state store is captured machine
    state with exact restore data, while this file only remembers presentation choices
    (currently the icon display mode). $env:WT_SETTINGS_PATH overrides the location, the
    same way WT_STATE_PATH does, which is what keeps tests out of the real profile.
#>
function Get-WtSettingsPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($env:WT_SETTINGS_PATH)
    {
        return [System.IO.Path]::GetFullPath($env:WT_SETTINGS_PATH)
    }

    return (Join-Path (Get-WtDataRoot) 'settings.json')
}

function Get-WtLogDirectory
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($env:WT_LOG_DIRECTORY)
    {
        return [System.IO.Path]::GetFullPath($env:WT_LOG_DIRECTORY)
    }

    return (Join-Path (Get-WtDataRoot) 'logs')
}

<#
.SYNOPSIS
    Creates a directory if it does not exist (idempotent, never throws for existing paths).
#>
function New-WtDirectory
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path))
    {
        # Own data/log directories are created even in -WhatIf mode, otherwise a dry
        # run could not be logged.
        New-Item -ItemType Directory -Path $Path -Force -WhatIf:$false -Confirm:$false | Out-Null
    }
}

<#
.SYNOPSIS
    Picks the value matching the active language out of a localizable descriptor.
.DESCRIPTION
    Accepts either a hashtable keyed by language code (e.g. @{ en = 'x'; vi = 'y' })
    or a plain string. Falls back to 'en', then to the first available value.
#>
function Get-WtText
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false, Position = 1)]
        [object]$Value,

        [Parameter(Mandatory = $false)]
        [string]$Language
    )

    if ($null -eq $Value)
    {
        return ''
    }

    if ($Value -is [string])
    {
        return $Value
    }

    if ($Value -is [hashtable] -or $Value -is [System.Collections.IDictionary])
    {
        if (-not $Language)
        {
            $Language = Get-WtLanguage
        }

        foreach ($Candidate in @($Language, 'en'))
        {
            if ($Candidate -and $Value.Contains($Candidate) -and $null -ne $Value[$Candidate])
            {
                return [string]$Value[$Candidate]
            }
        }

        $First = $Value.Values | Where-Object { $null -ne $_ } | Select-Object -First 1
        return [string]$First
    }

    return [string]$Value
}

<#
.SYNOPSIS
    Normalises the many spellings of registry value kinds into the two accepted forms.
.DESCRIPTION
    The internal model uses either the PowerShell provider names (String, DWord, QWord,
    MultiString, Binary, ExpandString) or their native ids. Anything unknown resolves to
    $null so callers can report an explicit failure instead of silently guessing.
#>
function Resolve-WtRegistryKind
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$Kind)

    if ($null -eq $Kind)
    {
        return $null
    }

    $Text = ([string]$Kind).Trim()

    if ([string]::IsNullOrWhiteSpace($Text))
    {
        return $null
    }

    # Native ids, as produced by the .NET registry API.
    switch ($Text)
    {
        { $_ -in '0', 'None' } { return $null }
        { $_ -in '1', 'String', 'REG_SZ', 'Sz' } { return 'String' }
        { $_ -in '2', 'ExpandString', 'REG_EXPAND_SZ', 'ExpandSz' } { return 'ExpandString' }
        { $_ -in '3', 'Binary', 'REG_BINARY' } { return 'Binary' }
        { $_ -in '4', 'DWord', 'REG_DWORD' } { return 'DWord' }
        { $_ -in '5', 'MultiString', 'REG_MULTI_SZ' } { return 'MultiString' }
        { $_ -in '7', 'QWord', 'REG_QWORD' } { return 'QWord' }
        { $_ -in '11', 'Unknown', 'REG_NONE' } { return $null }
    }

    return $null
}

<#
.SYNOPSIS
    Converts an arbitrary provider value into a string safe for JSON persistence.
#>
function ConvertTo-WtPersistableValue
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][object]$Value)

    if ($null -eq $Value)
    {
        return $null
    }

    if ($Value -is [byte[]])
    {
        return [pscustomobject]@{ __bytes = [System.Convert]::ToBase64String($Value) }
    }

    if ($Value -is [System.Array])
    {
        return [pscustomobject]@{ __array = @($Value | ForEach-Object { ConvertTo-WtPersistableValue -Value $_ }) }
    }

    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [int16] -or $Value -is [double])
    {
        return $Value
    }

    return [string]$Value
}

<#
.SYNOPSIS
    Reverses ConvertTo-WtPersistableValue.
#>
function ConvertFrom-WtPersistableValue
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][object]$Value)

    if ($null -eq $Value)
    {
        return $null
    }

    if ($Value -is [System.Management.Automation.PSCustomObject])
    {
        if ($Value.PSObject.Properties.Name -contains '__bytes')
        {
            return , [System.Convert]::FromBase64String([string]$Value.__bytes)
        }
        if ($Value.PSObject.Properties.Name -contains '__array')
        {
            return , @($Value.__array | ForEach-Object { ConvertFrom-WtPersistableValue -Value $_ })
        }
    }

    return $Value
}

<#
.SYNOPSIS
    Returns the SID of the current account, or $null when it cannot be resolved.
.DESCRIPTION
    Read-only and guarded: on a system where Windows security principals are unavailable
    (for example PowerShell on another platform) this returns $null so the caller can report
    the change as unsupported instead of failing. Nothing is written and no principal is
    looked up on the network.
#>
function Get-WtCurrentUserSid
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    try
    {
        $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($Identity -and $Identity.User)
        {
            return [string]$Identity.User.Value
        }
    }
    catch
    {
        return $null
    }

    return $null
}
