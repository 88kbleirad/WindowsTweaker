# WindowsTweaker - strict JSON reader.
#
# The catalog refuses a malformed or hostile document loudly and cheaply, before anything is
# registered, and that strictness has to be identical on both supported runtimes. A plain
# ConvertFrom-Json would silently keep the last of two properties with the same name - which is
# exactly how a definition can be smuggled past a reviewer - while the .NET JSON reader that
# would report it is part of PowerShell 7 / .NET and is absent from Windows PowerShell 5.1
# (.NET Framework), which this module also runs on.
#
# So the strictness lives here: one small recursive-descent parser for RFC 8259 JSON (no
# comments, no trailing commas, no NaN/Infinity, no duplicate property names) that produces the
# same node tree on both runtimes. It never evaluates anything: it produces strings, numbers,
# booleans, arrays and ordered hashtables, and every problem it finds is reported with its
# document path.

<#
.SYNOPSIS
    Parses one JSON document strictly, returning a positioned node tree.
.DESCRIPTION
    RFC 8259 is enforced, not interpreted: comments, trailing commas, hex literals, NaN,
    Infinity, single quotes and unescaped control characters are all syntax errors, and a
    property name that appears twice in the same object is reported as an error rather than
    silently overwriting the first one.

    Every problem carries the document path of the value it belongs to (for example
    $.tweaks[0].id) and, for syntax errors, the line it was found on. The error list is bounded
    by MaxErrors; the byte size of the document is bounded by the caller (Read-WtCatalogJson).

    The returned node tree is:
      [pscustomobject]@{ Kind; Value; Line }              - String, Number, Boolean, Null
      [pscustomobject]@{ Kind; Value; Raw; Line }         - Number also carries its raw text
      [pscustomobject]@{ Kind; Value; Properties; Line }  - Object
      [pscustomobject]@{ Kind; Value; Items; Line }       - Array
    Properties is an ordered dictionary keyed by property name with ordinal (case-sensitive)
    comparison, so 'Id' and 'id' stay distinct, and Items is an array of child nodes. A Number
    keeps a [double] in Value when its text is representable as one and $null when it is not,
    with the raw text always available in Raw.
.PARAMETER Text
    The JSON document. A leading byte-order mark is tolerated; whitespace-only text is a
    syntax error.
.PARAMETER MaxDepth
    Nesting bound. The root is at depth 1; a value deeper than this is reported and parsing
    stops there, so a hostile document cannot exhaust the stack.
.PARAMETER MaxStringLength
    Longest string accepted, counted after unescaping. Zero or less disables the check.
.PARAMETER MaxErrors
    Upper bound on the reported errors.
.OUTPUTS
    @{ Ok; Errors; Depth; Root } - Ok is $true only when the document parsed with no error at
    all, Depth is the deepest nesting observed, and Root is the root node ($null when the
    document could not be parsed).
#>
function Read-WtStrictJsonNode
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $false)][int]$MaxDepth = 64,
        [Parameter(Mandatory = $false)][int]$MaxStringLength = 65536,
        [Parameter(Mandatory = $false)][int]$MaxErrors = 100
    )

    $Result = @{ Ok = $false; Errors = @(); Depth = 0; Root = $null }

    # A byte-order mark is not part of the document; every JSON reader tolerates it in front.
    if ($Text.Length -gt 0 -and [int]$Text[0] -eq 65279)
    {
        $Text = $Text.Substring(1)
    }

    $Errors = [System.Collections.Generic.List[string]]::new()
    $State = @{
        Text   = $Text
        Length = $Text.Length
        Index  = 0
        Line   = 1
        Fatal  = $false
    }

    # Records one syntax error with the path and line it belongs to, and stops the parse: a
    # document that does not parse must not be converted into a partial tree.
    $Fail = {
        param([string]$Path, [string]$Message)

        if ($Errors.Count -lt $MaxErrors)
        {
            $Errors.Add("${Path} : line $($State.Line): $Message")
        }
        $State.Fatal = $true
    }

    # Consumes the character at the cursor and keeps the line counter truthful.
    $Advance = {
        $Char = $State.Text[$State.Index]
        $State.Index++
        if ($Char -eq "`n")
        {
            $State.Line++
        }
        return $Char
    }

    # RFC 8259 whitespace: space, tab, line feed, carriage return - and nothing else.
    $SkipWhitespace = {
        while ($State.Index -lt $State.Length)
        {
            $Char = $State.Text[$State.Index]
            if ($Char -eq ' ' -or $Char -eq "`t" -or $Char -eq "`n" -or $Char -eq "`r")
            {
                [void](& $Advance)
                continue
            }
            break
        }
    }

    # Consumes one of the three literal words, without consuming anything when it is not there.
    $ConsumeLiteral = {
        param([string]$Word)

        $Length = $Word.Length
        if ($State.Index + $Length -gt $State.Length)
        {
            return $false
        }
        if ($State.Text.Substring($State.Index, $Length) -cne $Word)
        {
            return $false
        }
        for ($Position = 0; $Position -lt $Length; $Position++)
        {
            [void](& $Advance)
        }
        return $true
    }

    # Assumes the cursor is on the opening quote. Returns a String node, or $null after a
    # syntax error.
    $ParseString = {
        param([string]$Path)

        $StartLine = $State.Line
        [void](& $Advance) # opening quote

        $Builder = [System.Text.StringBuilder]::new()
        while ($true)
        {
            if ($State.Index -ge $State.Length)
            {
                & $Fail $Path 'the string is not terminated.'
                return $null
            }

            $Char = $State.Text[$State.Index]
            if ($Char -eq '"')
            {
                [void](& $Advance)
                $Value = $Builder.ToString()
                if ($MaxStringLength -gt 0 -and $Value.Length -gt $MaxStringLength -and $Errors.Count -lt $MaxErrors)
                {
                    $Errors.Add("${Path} : string of $($Value.Length) characters exceeds the $MaxStringLength character limit.")
                }
                return [pscustomobject]@{ Kind = 'String'; Value = $Value; Line = $StartLine }
            }

            if ($Char -eq '\')
            {
                [void](& $Advance)
                if ($State.Index -ge $State.Length)
                {
                    & $Fail $Path 'the escape sequence is not terminated.'
                    return $null
                }

                $Escape = & $Advance
                switch -CaseSensitive ([string]$Escape)
                {
                    '"' { [void]$Builder.Append('"') }
                    '\' { [void]$Builder.Append('\') }
                    '/' { [void]$Builder.Append('/') }
                    'b' { [void]$Builder.Append([char]8) }
                    'f' { [void]$Builder.Append([char]12) }
                    'n' { [void]$Builder.Append("`n") }
                    'r' { [void]$Builder.Append("`r") }
                    't' { [void]$Builder.Append("`t") }
                    'u'
                    {
                        if ($State.Index + 4 -gt $State.Length -or
                            -not [System.Uri]::IsHexDigit($State.Text[$State.Index]) -or
                            -not [System.Uri]::IsHexDigit($State.Text[$State.Index + 1]) -or
                            -not [System.Uri]::IsHexDigit($State.Text[$State.Index + 2]) -or
                            -not [System.Uri]::IsHexDigit($State.Text[$State.Index + 3]))
                        {
                            & $Fail $Path 'a \u escape needs four hexadecimal digits.'
                            return $null
                        }
                        $Hex = $State.Text.Substring($State.Index, 4)
                        for ($Position = 0; $Position -lt 4; $Position++)
                        {
                            [void](& $Advance)
                        }
                        [void]$Builder.Append([char][System.Convert]::ToInt32($Hex, 16))
                    }
                    default
                    {
                        & $Fail $Path "the escape sequence '\$Escape' is not valid."
                        return $null
                    }
                }
                continue
            }

            if ([int]$Char -lt 32)
            {
                & $Fail $Path 'a control character must be escaped.'
                return $null
            }

            [void]$Builder.Append([char]([int](& $Advance)))
        }
    }

    # Assumes the cursor is on '-' or a digit. Returns a Number node, or $null after a syntax
    # error. The raw text is always kept; the [double] only when the text fits one.
    $ParseNumber = {
        param([string]$Path)

        $StartLine = $State.Line
        $Start = $State.Index

        if ($State.Text[$State.Index] -eq '-')
        {
            [void](& $Advance)
            if ($State.Index -ge $State.Length)
            {
                & $Fail $Path 'the number is not terminated.'
                return $null
            }
        }

        $Code = [int]$State.Text[$State.Index]
        if ($Code -eq 48)
        {
            # A leading zero may not be followed by another digit: 01 is not a JSON number.
            [void](& $Advance)
        }
        elseif ($Code -ge 49 -and $Code -le 57)
        {
            while ($State.Index -lt $State.Length)
            {
                $Code = [int]$State.Text[$State.Index]
                if ($Code -lt 48 -or $Code -gt 57) { break }
                [void](& $Advance)
            }
        }
        else
        {
            & $Fail $Path 'the number needs at least one digit.'
            return $null
        }

        if ($State.Index -lt $State.Length -and $State.Text[$State.Index] -eq '.')
        {
            [void](& $Advance)
            if ($State.Index -ge $State.Length)
            {
                & $Fail $Path 'the fraction needs at least one digit.'
                return $null
            }
            $Code = [int]$State.Text[$State.Index]
            if ($Code -lt 48 -or $Code -gt 57)
            {
                & $Fail $Path 'the fraction needs at least one digit.'
                return $null
            }
            while ($State.Index -lt $State.Length)
            {
                $Code = [int]$State.Text[$State.Index]
                if ($Code -lt 48 -or $Code -gt 57) { break }
                [void](& $Advance)
            }
        }

        if ($State.Index -lt $State.Length -and ($State.Text[$State.Index] -eq 'e' -or $State.Text[$State.Index] -eq 'E'))
        {
            [void](& $Advance)
            if ($State.Index -lt $State.Length -and ($State.Text[$State.Index] -eq '+' -or $State.Text[$State.Index] -eq '-'))
            {
                [void](& $Advance)
            }
            if ($State.Index -ge $State.Length)
            {
                & $Fail $Path 'the exponent needs at least one digit.'
                return $null
            }
            $Code = [int]$State.Text[$State.Index]
            if ($Code -lt 48 -or $Code -gt 57)
            {
                & $Fail $Path 'the exponent needs at least one digit.'
                return $null
            }
            while ($State.Index -lt $State.Length)
            {
                $Code = [int]$State.Text[$State.Index]
                if ($Code -lt 48 -or $Code -gt 57) { break }
                [void](& $Advance)
            }
        }

        $Raw = $State.Text.Substring($Start, $State.Index - $Start)

        # JSON has no NaN and no Infinity, so a value that does not fit a [double] (1e999, for
        # example) keeps its raw text instead of becoming an infinity - and does so on both
        # runtimes, which do not agree on how such a conversion fails.
        $Value = $null
        $Parsed = 0.0
        if ([double]::TryParse($Raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed))
        {
            if (-not [double]::IsInfinity($Parsed) -and -not [double]::IsNaN($Parsed))
            {
                $Value = $Parsed
            }
        }

        return [pscustomobject]@{ Kind = 'Number'; Value = $Value; Raw = $Raw; Line = $StartLine }
    }

    # Assumes the cursor is on '['. Returns an Array node, or $null after a syntax error.
    $ParseArray = {
        param([string]$Path, [int]$Depth)

        $StartLine = $State.Line
        [void](& $Advance) # '['

        $Items = [System.Collections.Generic.List[object]]::new()
        $Index = 0

        & $SkipWhitespace
        if ($State.Index -lt $State.Length -and $State.Text[$State.Index] -eq ']')
        {
            [void](& $Advance)
            return [pscustomobject]@{ Kind = 'Array'; Value = $null; Items = $Items.ToArray(); Line = $StartLine }
        }

        while ($true)
        {
            $Item = & $ParseValue "${Path}[$Index]" ($Depth + 1)
            if ($State.Fatal) { return $null }
            $Items.Add($Item)
            $Index++

            & $SkipWhitespace
            if ($State.Index -ge $State.Length)
            {
                & $Fail $Path 'the array is not terminated.'
                return $null
            }

            $Char = $State.Text[$State.Index]
            if ($Char -eq ',')
            {
                [void](& $Advance)
                & $SkipWhitespace
                if ($State.Index -lt $State.Length -and $State.Text[$State.Index] -eq ']')
                {
                    & $Fail $Path 'a trailing comma is not allowed.'
                    return $null
                }
                continue
            }

            if ($Char -eq ']')
            {
                [void](& $Advance)
                return [pscustomobject]@{ Kind = 'Array'; Value = $null; Items = $Items.ToArray(); Line = $StartLine }
            }

            & $Fail $Path "',' or ']' was expected."
            return $null
        }
    }

    # Assumes the cursor is on '{'. Returns an Object node, or $null after a syntax error.
    $ParseObject = {
        param([string]$Path, [int]$Depth)

        $StartLine = $State.Line
        [void](& $Advance) # '{'

        $Properties = New-WtOrderedDictionary
        $Seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

        & $SkipWhitespace
        if ($State.Index -lt $State.Length -and $State.Text[$State.Index] -eq '}')
        {
            [void](& $Advance)
            return [pscustomobject]@{ Kind = 'Object'; Value = $null; Properties = $Properties; Line = $StartLine }
        }

        while ($true)
        {
            & $SkipWhitespace
            if ($State.Index -ge $State.Length -or $State.Text[$State.Index] -ne '"')
            {
                if (-not $State.Fatal)
                {
                    & $Fail $Path 'a property name is required.'
                }
                return $null
            }

            $Name = & $ParseString $Path
            if ($State.Fatal -or $null -eq $Name)
            {
                return $null
            }

            $PropertyName = [string]$Name.Value
            $PropertyPath = "${Path}.${PropertyName}"

            # A duplicate name is an error, not a round of last-one-wins: that is how a
            # definition is smuggled past a reviewer.
            if (-not $Seen.Add($PropertyName) -and $Errors.Count -lt $MaxErrors)
            {
                $Errors.Add("${PropertyPath} : duplicate property name.")
            }

            & $SkipWhitespace
            if ($State.Index -ge $State.Length -or $State.Text[$State.Index] -ne ':')
            {
                & $Fail $Path "':' was expected after the property name '${PropertyName}'."
                return $null
            }
            [void](& $Advance)

            $Value = & $ParseValue $PropertyPath ($Depth + 1)
            if ($State.Fatal) { return $null }

            $Properties[$PropertyName] = $Value

            & $SkipWhitespace
            if ($State.Index -ge $State.Length)
            {
                & $Fail $Path 'the object is not terminated.'
                return $null
            }

            $Char = $State.Text[$State.Index]
            if ($Char -eq ',')
            {
                [void](& $Advance)
                & $SkipWhitespace
                if ($State.Index -lt $State.Length -and $State.Text[$State.Index] -eq '}')
                {
                    & $Fail $Path 'a trailing comma is not allowed.'
                    return $null
                }
                continue
            }

            if ($Char -eq '}')
            {
                [void](& $Advance)
                return [pscustomobject]@{ Kind = 'Object'; Value = $null; Properties = $Properties; Line = $StartLine }
            }

            & $Fail $Path "',' or '}' was expected."
            return $null
        }
    }

    # Returns the node for the next value, or $null after a syntax error or a depth overflow.
    $ParseValue = {
        param([string]$Path, [int]$Depth)

        if ($State.Fatal) { return $null }

        if ($Depth -gt $MaxDepth)
        {
            if ($Errors.Count -lt $MaxErrors)
            {
                $Errors.Add("${Path} : line $($State.Line): nesting depth $Depth exceeds the $MaxDepth level limit.")
            }
            $State.Fatal = $true
            return $null
        }

        if ($Depth -gt $Result.Depth) { $Result.Depth = $Depth }

        & $SkipWhitespace
        if ($State.Fatal) { return $null }

        if ($State.Index -ge $State.Length)
        {
            & $Fail $Path 'a value is required.'
            return $null
        }

        $Char = $State.Text[$State.Index]
        if ($Char -eq '{') { return (& $ParseObject $Path $Depth) }
        if ($Char -eq '[') { return (& $ParseArray $Path $Depth) }
        if ($Char -eq '"') { return (& $ParseString $Path) }

        $StartLine = $State.Line
        if ($Char -eq 't')
        {
            if (& $ConsumeLiteral 'true')
            {
                return [pscustomobject]@{ Kind = 'Boolean'; Value = $true; Line = $StartLine }
            }
            & $Fail $Path "the literal 'true' was expected."
            return $null
        }
        if ($Char -eq 'f')
        {
            if (& $ConsumeLiteral 'false')
            {
                return [pscustomobject]@{ Kind = 'Boolean'; Value = $false; Line = $StartLine }
            }
            & $Fail $Path "the literal 'false' was expected."
            return $null
        }
        if ($Char -eq 'n')
        {
            if (& $ConsumeLiteral 'null')
            {
                return [pscustomobject]@{ Kind = 'Null'; Value = $null; Line = $StartLine }
            }
            & $Fail $Path "the literal 'null' was expected."
            return $null
        }
        if ($Char -eq '-')
        {
            return (& $ParseNumber $Path)
        }
        $Code = [int]$Char
        if ($Code -ge 48 -and $Code -le 57)
        {
            return (& $ParseNumber $Path)
        }

        & $Fail $Path 'a value was expected.'
        return $null
    }

    $Root = & $ParseValue '$' 1
    if ($State.Fatal)
    {
        $Root = $null
    }

    if ($null -ne $Root)
    {
        # Two documents in one file would otherwise be read as one, with everything after the
        # first silently ignored.
        & $SkipWhitespace
        if (-not $State.Fatal -and $State.Index -lt $State.Length)
        {
            & $Fail '$' 'the document root is followed by more content.'
            $Root = $null
        }
    }

    $Result.Root = $Root
    $Result.Errors = @($Errors.ToArray())
    $Result.Ok = ($Errors.Count -eq 0 -and $null -ne $Root)
    return $Result
}
