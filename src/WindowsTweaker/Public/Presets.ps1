# WindowsTweaker - presets (public API).
#
# A preset is a reviewable list of "tweak -> requested state" entries stored as JSON. It
# is the file format behind the interface's import/export workflow and behind the shipped
# starting points in Data\Presets.
#
# Hard rules:
#   * reading a preset never changes anything - importing returns the entries, and the
#     caller decides what to do with them;
#   * an entry is only accepted when its tweak exists, the requested state is one the
#     tweak declares, and the arguments it carries are ones the tweak expects;
#   * protection-reducing entries are excluded instead of being applied silently, and
#     every exclusion is reported to the caller;
#   * writing a preset refuses to overwrite an existing file unless -Force is given.

$Script:WtPresetFormatVersion = 1

<#
.SYNOPSIS
    Returns the directory user presets are stored in.
.DESCRIPTION
    Shipped presets live in the module's Data\Presets directory; user presets live next to
    the state store so they survive an upgrade of the module.
#>
function Get-WtPresetDirectory
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][switch]$BuiltIn)

    if ($BuiltIn)
    {
        return (Join-Path $Script:WtDataDirectory 'Presets')
    }

    return (Join-Path (Get-WtDataRoot) 'presets')
}

<#
.SYNOPSIS
    Validates one preset entry against the catalog.
.DESCRIPTION
    Returns a reason when the entry cannot be used, and $null when it can.
#>
function Resolve-WtPresetEntry
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][object]$Entry)

    if ($null -eq $Entry)
    {
        return 'empty entry'
    }

    $Id = [string]$Entry.id
    if (-not $Id)
    {
        return 'entry without an id'
    }

    $Tweak = Get-WtTweakInternal -Id $Id
    if (-not $Tweak)
    {
        return (Get-WtString -Key 'Error.TweakNotFound' -Arguments @($Id))
    }

    $State = [string]$Entry.state
    $StateNames = @($Tweak.StateNames)

    if ($StateNames.Count -gt 0 -and $StateNames -notcontains $State)
    {
        return (Get-WtString -Key 'Error.InvalidState' -Arguments @($State, $Id, ($StateNames -join ', ')))
    }

    $Arguments = @{}
    if ($Entry.arguments)
    {
        if ($Entry.arguments -isnot [System.Collections.IDictionary])
        {
            return "arguments for $Id must be an object"
        }

        $Allowed = @($Tweak.Parameters)
        foreach ($Name in $Entry.arguments.Keys)
        {
            if ($Allowed -notcontains $Name)
            {
                return "argument '$Name' is not accepted by $Id (expected: $($Allowed -join ', '))"
            }
        }

        $Arguments = @{}
        foreach ($Name in $Entry.arguments.Keys)
        {
            $Arguments[[string]$Name] = $Entry.arguments[$Name]
        }
    }

    if ($Tweak.ReducesProtection)
    {
        return (Get-WtString -Key 'Tui.Preset.Protection' -Arguments @($Id))
    }

    return $null
}

<#
.SYNOPSIS
    Reads one preset file and validates it against the catalog.
.PARAMETER Path
    Preset file to read.
.DESCRIPTION
    Throws when the file cannot be read or is not a preset; entries that cannot be applied
    are reported separately instead of being dropped silently.
#>
function Read-WtPresetFile
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$BuiltIn
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        throw (Get-WtString -Key 'Tui.Preset.NotFound' -Arguments @($Path))
    }

    try
    {
        $Document = ConvertFrom-WtJson -Text (Read-WtTextFile -Path $Path)
    }
    catch
    {
        throw (Get-WtString -Key 'Tui.Preset.Invalid' -Arguments @($Path, $_.Exception.Message))
    }

    $Name = if ($Document.name) { [string]$Document.name } else { [System.IO.Path]::GetFileNameWithoutExtension($Path) }
    $Description = if ($Document.description) { [string]$Document.description } else { '' }

    $RawEntries = @()
    if ($Document.PSObject.Properties.Name -contains 'tweaks')
    {
        $RawEntries = @($Document.tweaks)
    }

    if ($RawEntries.Count -eq 0)
    {
        throw (Get-WtString -Key 'Tui.Preset.Empty' -Arguments @($Path))
    }

    $Entries = [System.Collections.Generic.List[object]]::new()
    $Skipped = [System.Collections.Generic.List[string]]::new()

    foreach ($Raw in $RawEntries)
    {
        $Reason = Resolve-WtPresetEntry -Entry $Raw
        if ($Reason)
        {
            $Skipped.Add("$([string]$Raw.id): $Reason")
            continue
        }

        $Arguments = $null
        if ($Raw.arguments)
        {
            $Arguments = @{}
            foreach ($Property in $Raw.arguments.PSObject.Properties)
            {
                $Arguments[$Property.Name] = $Property.Value
            }
        }

        $Entries.Add(@{
            Id        = [string]$Raw.id
            State     = [string]$Raw.state
            Arguments = $Arguments
        })
    }

    return [pscustomobject]@{
        PSTypeName  = 'WindowsTweaker.Preset'
        Name        = $Name
        Description = $Description
        Source      = if ($BuiltIn) { 'built-in' } else { 'file' }
        Path        = $Path
        Entries     = $Entries.ToArray()
        Skipped     = $Skipped.ToArray()
    }
}

<#
.SYNOPSIS
    Lists the presets that are available: shipped ones first, then user ones.
.PARAMETER Name
    Only return the preset with this name.
.DESCRIPTION
    Read-only. A user preset that cannot be parsed is reported with an empty entry list and
    the reason in its description instead of breaking the list.
#>
function Get-WtPreset
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $false)][string]$Name)

    $Presets = [System.Collections.Generic.List[object]]::new()

    $BuiltInDirectory = Get-WtPresetDirectory -BuiltIn
    if (Test-Path -LiteralPath $BuiltInDirectory)
    {
        foreach ($File in (Get-ChildItem -LiteralPath $BuiltInDirectory -Filter '*.json' -File | Sort-Object -Property Name))
        {
            try
            {
                $Presets.Add((Read-WtPresetFile -Path $File.FullName -BuiltIn))
            }
            catch
            {
                Write-WtLog -Level Warning -Message "Shipped preset '$($File.Name)' could not be read: $($_.Exception.Message)" -NoConsole
            }
        }
    }

    $UserDirectory = Get-WtPresetDirectory
    if (Test-Path -LiteralPath $UserDirectory)
    {
        foreach ($File in (Get-ChildItem -LiteralPath $UserDirectory -Filter '*.json' -File | Sort-Object -Property Name))
        {
            try
            {
                $Presets.Add((Read-WtPresetFile -Path $File.FullName))
            }
            catch
            {
                $Presets.Add([pscustomobject]@{
                    PSTypeName  = 'WindowsTweaker.Preset'
                    Name        = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
                    Description = $_.Exception.Message
                    Source      = 'file'
                    Path        = $File.FullName
                    Entries     = @()
                    Skipped     = @($_.Exception.Message)
                })
            }
        }
    }

    if ($Name)
    {
        return @($Presets | Where-Object { $_.Name -eq $Name })
    }

    return $Presets.ToArray()
}

<#
.SYNOPSIS
    Reads a preset file and returns the (validated) entries it contains.
.PARAMETER Path
    Preset file to import.
.DESCRIPTION
    Never applies anything: the entries come back for review. Use
    Invoke-WtTweak -Id <id> -State <state> -Arguments <...> to apply a reviewed entry.
#>
function Import-WtPreset
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $true, Position = 1)][string]$Path)

    return Read-WtPresetFile -Path $Path
}

<#
.SYNOPSIS
    Writes entries to a preset file.
.PARAMETER Entries
    Entries to write: objects or hashtables with id, state and (optional) arguments.
.PARAMETER Path
    Destination file.
.PARAMETER Name
    Preset name stored in the file. Defaults to the file name without extension.
.PARAMETER Force
    Overwrite an existing file.
.DESCRIPTION
    Every entry is validated first, so a preset can never describe a state that the catalog
    does not declare.
#>
function Export-WtPreset
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][string]$Name,
        [Parameter(Mandatory = $false)][string]$Description = '',
        [Parameter(Mandatory = $false)][switch]$Force
    )

    if (@($Entries).Count -eq 0)
    {
        throw (Get-WtString -Key 'Tui.Preset.Empty' -Arguments @($Path))
    }

    $Normalised = [System.Collections.Generic.List[object]]::new()
    foreach ($Entry in $Entries)
    {
        $Raw = @{
            id    = [string]$Entry.id
            state = [string]$Entry.state
        }

        if ($Entry.arguments)
        {
            $Raw.arguments = $Entry.arguments
        }

        $Reason = Resolve-WtPresetEntry -Entry $Raw
        if ($Reason)
        {
            throw $Reason
        }

        $Normalised.Add($Raw)
    }

    if (-not $Name)
    {
        $Name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    }

    $Document = [ordered]@{
        preset      = $Script:WtPresetFormatVersion
        name        = $Name
        description = $Description
        generator   = 'WindowsTweaker'
        createdUtc  = (Get-Date).ToUniversalTime().ToString('o')
        tweaks      = $Normalised.ToArray()
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'write the preset'))
    {
        return $Path
    }

    if ((Test-Path -LiteralPath $Path) -and -not $Force)
    {
        throw (Get-WtString -Key 'Tui.Path.Exists' -Arguments @($Path))
    }

    $Directory = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($Directory))
    {
        New-WtDirectory -Path $Directory
    }

    Write-WtTextFile -Path $Path -Value (ConvertTo-WtJson -InputObject $Document -Depth 8)

    Write-WtLog -Message "Preset written: $Path" -Operation 'ExportPreset' -Status 'succeeded'
    return $Path
}
