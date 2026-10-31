# WindowsTweaker - localization with explicit fallback chain.
#
# Lookup order for Get-WtString:  requested language -> English -> "[Key]".
# A string value must not contain a typographic quotation mark (U+2018, U+2019, U+201C, U+201D):
# PowerShell accepts those as string delimiters, so the literal would end in the middle of the text
# and the whole data file would stop parsing. tests/Loading.Tests.ps1 enforces this.
#
# Strings live in Data\Strings.<lang>.psd1 and are read with
# Import-PowerShellDataFile, so a string file can never execute code.

$Script:WtLocalizationState = @{
    Language  = $null
    Strings   = @{}
    Fallback  = @{}
    Languages = @('en', 'vi')
    Missing   = @{}
}

<#
.SYNOPSIS
    Returns the language codes WindowsTweaker ships strings for.
#>
function Get-WtSupportedLanguages
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return $Script:WtLocalizationState.Languages
}

<#
<#
.SYNOPSIS
    Reads the language saved by the user (the picker writes it through the settings store).
.DESCRIPTION
    Returns '' when nothing valid is saved, so the caller can fall through to the next
    source of the precedence chain.
>

<#
.SYNOPSIS
    Reads one language table: the main file plus its part files.
.DESCRIPTION
    Import-PowerShellDataFile refuses a hashtable literal with more than 500 entries, so the
    table is split by feature: Data\Strings.<lang>.psd1 holds the shell of the interface and
    Data\Strings.<lang>.<part>.psd1 hold feature-specific keys. The parts are merged in file
    name order; a key defined twice is an error rather than a silent override, because a
    duplicate would mean two features disagree about the same text.
#>
function Read-WtStringTable
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Code)

    $Main = Join-Path $Script:WtDataDirectory ("Strings.{0}.psd1" -f $Code)
    if (-not (Test-Path -LiteralPath $Main))
    {
        return @{}
    }

    $Table = Import-PowerShellDataFile -LiteralPath $Main

    $Parts = @(Get-ChildItem -Path $Script:WtDataDirectory -Filter ("Strings.{0}.*.psd1" -f $Code) -File | Sort-Object -Property Name)
    foreach ($Part in $Parts)
    {
        $Extra = Import-PowerShellDataFile -LiteralPath $Part.FullName
        foreach ($Key in $Extra.Keys)
        {
            if ($Table.ContainsKey($Key))
            {
                throw "The string key '$Key' is defined in both Strings.$Code.psd1 and $($Part.Name)."
            }

            $Table[$Key] = $Extra[$Key]
        }
    }

    return $Table
}

<#
.SYNOPSIS
    Returns the saved interface language preference as a code, or an empty string.
#>
function Get-WtLanguagePreference
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $Code = ([string](Read-WtSettings).Language).Trim().ToLowerInvariant()
    if ($Code -and $Script:WtLocalizationState.Languages -contains $Code)
    {
        return $Code
    }

    return ''
}

<#
.SYNOPSIS
    Persists the interface language without switching this session.
#>
function Set-WtLanguagePreference
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet('en', 'vi')]
        [string]$Language
    )

    $Settings = Read-WtSettings
    $Settings.Language = $Language

    if ($PSCmdlet.ShouldProcess($Language, 'save the interface language'))
    {
        Write-WtSettings -Settings $Settings
    }

    return $Language
}

<#
.SYNOPSIS
    Normalises a language identifier into a supported two-letter code.
.DESCRIPTION
    Accepts 'vi', 'vi-VN', [CultureInfo] or $null. Precedence, highest first: the value
    passed in (the -Language option), the language saved by the user, WT_LANG, the
    supported UI culture, then English. An explicit but unsupported value resolves to
    English rather than silently picking another language, so a typo is visible.
#>
function Resolve-WtLanguage
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][object]$Language)

    $Candidates = [System.Collections.Generic.List[string]]::new()

    if ($Language)
    {
        if ($Language -is [System.Globalization.CultureInfo])
        {
            $Candidates.Add($Language.TwoLetterISOLanguageName)
        }
        else
        {
            $Text = ([string]$Language).Trim()
            if ($Text)
            {
                $Candidates.Add($Text)
                if ($Text.Length -gt 2)
                {
                    $Candidates.Add($Text.Substring(0, 2))
                }
            }
        }
    }
    else
    {
        $Saved = Get-WtLanguagePreference
        if ($Saved)
        {
            $Candidates.Add($Saved)
        }
        elseif ($env:WT_LANG)
        {
            $Candidates.Add(([string]$env:WT_LANG).Trim())
        }
        else
        {
            try
            {
                $Candidates.Add([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName)
            }
            catch
            {
                $Candidates.Add('en')
            }
        }
    }

    foreach ($Candidate in $Candidates)
    {
        $Normalised = $Candidate.ToLowerInvariant()
        if ($Script:WtLocalizationState.Languages -contains $Normalised)
        {
            return $Normalised
        }
    }

    return 'en'
}

<#
.SYNOPSIS
    Loads the string tables (idempotent).
.PARAMETER Language
    Preferred language; falls back to English and finally to the raw key.
#>
function Initialize-WtLocalization
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)]
        [object]$Language,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    $Resolved = Resolve-WtLanguage -Language $Language

    if ($Script:WtLocalizationState.Language -and -not $Force -and $Script:WtLocalizationState.Language -eq $Resolved)
    {
        return $Resolved
    }

    $Load = {
        param ([string]$Code)

        return (Read-WtStringTable -Code $Code)
    }

    $Script:WtLocalizationState.Fallback = & $Load 'en'
    $Script:WtLocalizationState.Strings = if ($Resolved -eq 'en') { $Script:WtLocalizationState.Fallback } else { & $Load $Resolved }
    $Script:WtLocalizationState.Language = $Resolved

    return $Resolved
}

<#
.SYNOPSIS
    Returns the active language code.
#>
function Get-WtLanguage
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if (-not $Script:WtLocalizationState.Language)
    {
        Initialize-WtLocalization | Out-Null
    }

    return $Script:WtLocalizationState.Language
}

<#
.SYNOPSIS
    Switches the active language for this session.
#>
function Set-WtLanguage
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true, Position = 1)][object]$Language)

    return Initialize-WtLocalization -Language $Language -Force
}

<#
.SYNOPSIS
    Returns a localized string.
.PARAMETER Key
    String key, e.g. 'Cli.Menu.Apply'.
.PARAMETER Arguments
    Values for the format placeholders ({0}, {1}, ...).
#>
function Get-WtString
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Key,

        [Parameter(Mandatory = $false, Position = 2)]
        [object[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [object]$Language
    )

    if (-not $Script:WtLocalizationState.Language)
    {
        Initialize-WtLocalization | Out-Null
    }

    $Table = $Script:WtLocalizationState.Strings
    $Fallback = $Script:WtLocalizationState.Fallback

    if ($Language)
    {
        $Code = Resolve-WtLanguage -Language $Language
        if ($Code -ne $Script:WtLocalizationState.Language)
        {
            $Table = Read-WtStringTable -Code $Code
        }
    }

    $Value = $null
    if ($Table.ContainsKey($Key))
    {
        $Value = $Table[$Key]
    }
    elseif ($Fallback.ContainsKey($Key))
    {
        $Value = $Fallback[$Key]
    }

    if ($null -eq $Value)
    {
        # Report a missing key once per session, then degrade to the key itself.
        $Signature = "$(Get-WtLanguage)|$Key"
        if (-not $Script:WtLocalizationState.Missing.ContainsKey($Signature))
        {
            $Script:WtLocalizationState.Missing[$Signature] = $true
            Write-WtLog -Level Warning -Message "Localization key missing: $Key" -NoConsole
        }
        return "[$Key]"
    }

    if ($null -ne $Arguments)
    {
        try
        {
            return ($Value -f $Arguments)
        }
        catch
        {
            # A malformed placeholder set must not hide the string itself.
            Write-WtLog -Level Warning -Message "Could not format string '$Key' with $($Arguments.Count) argument(s)." -NoConsole
            return [string]$Value
        }
    }

    return [string]$Value
}
