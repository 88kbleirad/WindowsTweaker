# WindowsTweaker - TUI screen buffer and rendering.
#
# The interface paints into an in-memory cell grid and then writes the whole frame in
# a single console write. That keeps the screen consistent (no partially painted
# frames), makes the layout testable without a terminal, and avoids the Clear-Host
# redraw loop the specification forbids: a frame is only ever written when something
# actually changed.
#
# Two renderers exist and consume the same grid:
#   * Write-WtScreen       - ANSI cursor addressing; true colour, 256 or 16 colours
#   * Write-WtScreenPlain  - [Console] API (SetCursorPosition/ConsoleColor) for hosts
#                            without virtual terminal support

# A cell holds the string that occupies it, so a double-width glyph (or a surrogate
# pair) lives in one cell and its continuation cell stays empty. The parallel style
# array carries the numeric style id for every cell.
$Script:WtScreenContinuation = [string]::Empty

<#
.SYNOPSIS
    Reports whether a real interactive terminal is attached.
.DESCRIPTION
    A redirected stdin/stdout (a pipe, a scheduled task, an IDE output pane) cannot
    deliver key presses, so the TUI refuses to start there instead of hanging.
#>
function Test-WtInteractiveConsole
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    try
    {
        if ([Console]::IsOutputRedirected -or [Console]::IsInputRedirected)
        {
            return $false
        }
    }
    catch
    {
        return $false
    }

    $Size = Get-WtConsoleSize

    return ($Size.Width -gt 0 -and $Size.Height -gt 0)
}

<#
.SYNOPSIS
    Returns the current terminal size, falling back to the host buffer when the .NET
    console API is unavailable.
#>
function Get-WtConsoleSize
{
    [CmdletBinding()]
    param ()

    $Width = 0
    $Height = 0

    try
    {
        $Width = [Console]::WindowWidth
        $Height = [Console]::WindowHeight
    }
    catch
    {
        $Width = 0
        $Height = 0
    }

    if (($Width -le 0 -or $Height -le 0) -and $Host.UI.RawUI)
    {
        try
        {
            $Size = $Host.UI.RawUI.WindowSize
            if ($Width -le 0) { $Width = $Size.Width }
            if ($Height -le 0) { $Height = $Size.Height }
        }
        catch
        {
            Write-WtLog -Level Debug -Message 'Terminal size is unavailable from the host.' -NoConsole
        }
    }

    # Bound the buffer: a bogus size must not allocate an enormous grid.
    if ($Width -le 0) { $Width = 100 }
    if ($Height -le 0) { $Height = 24 }
    if ($Width -gt 400) { $Width = 400 }
    if ($Height -gt 200) { $Height = 200 }

    return @{ Width = [int]$Width; Height = [int]$Height }
}

<#
.SYNOPSIS
    Creates an empty cell grid.
#>
function New-WtScreen
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][object]$Theme
    )

    if ($Width -lt 1) { $Width = 1 }
    if ($Height -lt 1) { $Height = 1 }

    $Rows = [System.Collections.Generic.List[object]]::new($Height)
    for ($Row = 0; $Row -lt $Height; $Row++)
    {
        $Cells = [string[]]::new($Width)
        $Styles = [int[]]::new($Width)
        for ($Column = 0; $Column -lt $Width; $Column++)
        {
            $Cells[$Column] = ' '
        }
        $Rows.Add(@{ Cells = $Cells; Styles = $Styles })
    }

    $Screen = @{
        Width  = $Width
        Height = $Height
        Theme  = $Theme
        Rows   = $Rows
        Dirty  = $true
        # The last successfully written cell/style state, one entry per row; a null entry
        # means the row has never been written (a new screen, or after an explicit reset),
        # so the first write emits every row.
        PreviousCells = [string[][]]::new($Height)
        PreviousStyles = [int[][]]::new($Height)
        # Diagnostic counter: the number of rows the most recent write emitted.
        LastWrittenRows = 0
    }

    Clear-WtScreen -Screen $Screen
    return $Screen
}

<#
.SYNOPSIS
    Computes which rows differ from the last written frame.
.DESCRIPTION
    The cell grid is compared with the recorded previous frame, row by row. The bottom-right
    cell is excluded exactly as it is excluded when painting, so a row whose only difference
    is that never-painted corner is not rewritten. Rows that have never been written are
    reported as changed.
#>
function Get-WtScreenChangedRows
{
    [CmdletBinding()]
    [OutputType([bool[]])]
    param ([Parameter(Mandatory = $true)][object]$Screen)

    $Height = $Screen.Height
    $Width = $Screen.Width
    $LastIndex = $Height - 1
    $Changed = [bool[]]::new($Height)
    $PreviousCells = $Screen.PreviousCells
    $PreviousStyles = $Screen.PreviousStyles
    $Rows = $Screen.Rows

    for ($Index = 0; $Index -lt $Height; $Index++)
    {
        $Previous = $PreviousCells[$Index]
        if ($null -eq $Previous)
        {
            $Changed[$Index] = $true
            continue
        }

        $Limit = $Width
        if ($Index -eq $LastIndex) { $Limit = $Width - 1 }

        $Row = $Rows[$Index]
        $Cells = $Row.Cells
        $Styles = $Row.Styles
        $PreviousStyleRow = $PreviousStyles[$Index]

        $Same = $true
        for ($Column = 0; $Column -lt $Limit; $Column++)
        {
            if ($Cells[$Column] -ne $Previous[$Column] -or $Styles[$Column] -ne $PreviousStyleRow[$Column])
            {
                $Same = $false
                break
            }
        }

        $Changed[$Index] = -not $Same
    }

    return ,$Changed
}

<#
.SYNOPSIS
    Records one row as written: its current cells and styles become the previous frame.
#>
function Set-WtScreenRowWritten
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][int]$Row
    )

    $Index = $Row - 1
    $Screen.PreviousCells[$Index] = $Screen.Rows[$Index].Cells.Clone()
    $Screen.PreviousStyles[$Index] = $Screen.Rows[$Index].Styles.Clone()
}

<#
.SYNOPSIS
    Drops the recorded previous frame so the next write emits every row.
.DESCRIPTION
    Used after a resize (new grid) and by the forced-repaint path (Ctrl+L).
#>
function Reset-WtScreenDiff
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Screen)

    for ($Index = 0; $Index -lt $Screen.Height; $Index++)
    {
        $Screen.PreviousCells[$Index] = $null
        $Screen.PreviousStyles[$Index] = $null
    }
}

<#
.SYNOPSIS
    Fills the whole grid with blanks.
#>
function Clear-WtScreen
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $false)][string]$Style = 'Default'
    )

    $StyleId = Get-WtStyleId -Theme $Screen.Theme -Name $Style

    for ($Row = 0; $Row -lt $Screen.Height; $Row++)
    {
        $Line = $Screen.Rows[$Row]
        for ($Column = 0; $Column -lt $Screen.Width; $Column++)
        {
            $Line.Cells[$Column] = ' '
            $Line.Styles[$Column] = $StyleId
        }
    }

    $Screen.Dirty = $true
}

<#
.SYNOPSIS
    Returns how many columns may be painted on a row.
.DESCRIPTION
    The bottom-right cell is deliberately never written: painting it makes most
    terminal emulators scroll the whole buffer, which would shift the freshly painted
    frame up by one line.
#>
function Get-WtRowWidth
{
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][int]$Row
    )

    if ($Row -eq $Screen.Height)
    {
        return ($Screen.Width - 1)
    }

    return $Screen.Width
}

<#
.SYNOPSIS
    Paints a background style over a rectangular region.
#>
function Set-WtScreenRegion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][int]$Row,
        [Parameter(Mandatory = $true)][int]$Column,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $false)][string]$Style = 'Default'
    )

    $StyleId = Get-WtStyleId -Theme $Screen.Theme -Name $Style

    for ($Y = $Row; $Y -lt ($Row + $Height); $Y++)
    {
        if ($Y -lt 1 -or $Y -gt $Screen.Height) { continue }

        $Limit = Get-WtRowWidth -Screen $Screen -Row $Y
        for ($X = $Column; $X -lt ($Column + $Width); $X++)
        {
            if ($X -lt 1 -or $X -gt $Limit) { continue }

            $Screen.Rows[$Y - 1].Cells[$X - 1] = ' '
            $Screen.Rows[$Y - 1].Styles[$X - 1] = $StyleId
        }
    }

    $Screen.Dirty = $true
}

<#
.SYNOPSIS
    Writes text at an absolute position, clipped to the row.
.PARAMETER MaxWidth
    Maximum number of cells to paint (0 = until the row limit).
#>
function Set-WtScreenText
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][int]$Row,
        [Parameter(Mandatory = $true)][int]$Column,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $false)][string]$Style = 'Default',
        [Parameter(Mandatory = $false)][int]$MaxWidth = 0
    )

    if ($Row -lt 1 -or $Row -gt $Screen.Height)
    {
        return
    }

    $Display = ConvertTo-WtDisplayText -Text $Text
    if ([string]::IsNullOrEmpty($Display))
    {
        return
    }

    $StyleId = Get-WtStyleId -Theme $Screen.Theme -Name $Style
    $Limit = Get-WtRowWidth -Screen $Screen -Row $Row
    if ($Column -gt $Limit)
    {
        return
    }

    if ($MaxWidth -gt 0)
    {
        $Limit = [math]::Min($Limit, $Column + $MaxWidth - 1)
    }

    $Line = $Screen.Rows[$Row - 1]
    $X = $Column
    $Index = 0

    while ($Index -lt $Display.Length)
    {
        $Character = $Display[$Index]
        $Code = [int][char]$Character
        $Point = $Code
        $Glyph = [string]$Character
        $CellWidth = 1

        if ($Code -ge 0xD800 -and $Code -le 0xDBFF -and ($Index + 1) -lt $Display.Length)
        {
            $Glyph = $Display.Substring($Index, 2)
            $Low = [int][char]$Display[$Index + 1]
            $Point = 0x10000 + (($Code - 0xD800) * 0x400) + ($Low - 0xDC00)
            if (Test-WtWideCodePoint -CodePoint $Point) { $CellWidth = 2 }
            $Index += 2
        }
        else
        {
            if (Test-WtWideCodePoint -CodePoint $Code) { $CellWidth = 2 }
            $Index++
        }

        # Combining marks and variation selectors attach to the previous cell, which
        # already holds the base character; rendering them separately would break the
        # column arithmetic.
        if (Test-WtZeroWidthCodePoint -CodePoint $Point)
        {
            continue
        }

        if (($X + $CellWidth - 1) -gt $Limit)
        {
            break
        }

        $Line.Cells[$X - 1] = $Glyph
        $Line.Styles[$X - 1] = $StyleId

        if ($CellWidth -eq 2)
        {
            $Line.Cells[$X] = $Script:WtScreenContinuation
            $Line.Styles[$X] = $StyleId
        }

        $X += $CellWidth
    }

    $Screen.Dirty = $true
}

<#
.SYNOPSIS
    Writes an icon and its label at an absolute position, clipping both to the row.
.DESCRIPTION
    The single place an icon is painted. The icon keeps its own style (so its colour
    survives on a highlighted row) while the label keeps the row's style, and the label
    starts exactly one slot after the icon, measured in terminal cells. Callers pass the
    width they have; when the icon cannot fit, the label is written alone rather than
    shifting into the neighbouring pane.
.PARAMETER Width
    Cells available for the icon and the label together (0 = until the row limit).
.PARAMETER Surface
    The style of the row this text sits in (see Get-WtIconSurface), so the icon uses the
    matching background variant.
#>
function Set-WtScreenIconText
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][int]$Row,
        [Parameter(Mandatory = $true)][int]$Column,
        [Parameter(Mandatory = $false)][int]$Width = 0,
        [Parameter(Mandatory = $false)][string]$IconKey = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory = $false)][string]$Style = 'Default',
        [Parameter(Mandatory = $false)][ValidateSet('Row', 'Selected', 'Focused')][string]$Surface = 'Row'
    )

    $Icons = $Screen.Theme.Icons
    $IconWidth = Get-WtIconPrefixWidth -Icons $Icons -Key $IconKey

    if ($IconWidth -le 0)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text $Text -Style $Style -MaxWidth $Width
        return
    }

    if ($Width -gt 0)
    {
        if ($Width -le $IconWidth)
        {
            # Not enough room for an icon and a label: keep the label readable.
            Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text $Text -Style $Style -MaxWidth $Width
            return
        }

        Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text (Format-WtIconPrefix -Icons $Icons -Key $IconKey) `
            -Style (Get-WtIconStyleName -Icons $Icons -Key $IconKey -Surface $Surface) -MaxWidth $IconWidth
        Set-WtScreenText -Screen $Screen -Row $Row -Column ($Column + $IconWidth) -Text $Text -Style $Style -MaxWidth ($Width - $IconWidth)
        return
    }

    Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text (Format-WtIconPrefix -Icons $Icons -Key $IconKey) `
        -Style (Get-WtIconStyleName -Icons $Icons -Key $IconKey -Surface $Surface) -MaxWidth $IconWidth
    Set-WtScreenText -Screen $Screen -Row $Row -Column ($Column + $IconWidth) -Text $Text -Style $Style
}

<#
.SYNOPSIS
    Draws a square-cornered box with an optional title.
.DESCRIPTION
    Panels use square corners on purpose (the specification asks for them); the
    character set comes from the theme, so a terminal without Unicode gets ASCII.
#>
function Add-WtScreenBox
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][int]$Row,
        [Parameter(Mandatory = $true)][int]$Column,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Title = '',
        [Parameter(Mandatory = $false)][string]$BorderStyle = 'Border',
        [Parameter(Mandatory = $false)][string]$TitleStyle = 'PanelTitle',
        [Parameter(Mandatory = $false)][string]$Style = 'Default'
    )

    if ($Width -lt 2 -or $Height -lt 2)
    {
        return
    }

    $Glyph = $Screen.Theme.Border
    Set-WtScreenRegion -Screen $Screen -Row $Row -Column $Column -Width $Width -Height $Height -Style $Style

    $Top = $Row
    $Bottom = $Row + $Height - 1
    $Left = $Column
    $Right = $Column + $Width - 1

    Set-WtScreenText -Screen $Screen -Row $Top -Column $Left -Text ([string]$Glyph.TopLeft) -Style $BorderStyle
    Set-WtScreenText -Screen $Screen -Row $Top -Column $Right -Text ([string]$Glyph.TopRight) -Style $BorderStyle
    Set-WtScreenText -Screen $Screen -Row $Bottom -Column $Left -Text ([string]$Glyph.BottomLeft) -Style $BorderStyle
    Set-WtScreenText -Screen $Screen -Row $Bottom -Column $Right -Text ([string]$Glyph.BottomRight) -Style $BorderStyle

    $Horizontal = [string]$Glyph.Horizontal * ($Width - 2)
    Set-WtScreenText -Screen $Screen -Row $Top -Column ($Left + 1) -Text $Horizontal -Style $BorderStyle -MaxWidth ($Width - 2)
    Set-WtScreenText -Screen $Screen -Row $Bottom -Column ($Left + 1) -Text $Horizontal -Style $BorderStyle -MaxWidth ($Width - 2)

    for ($Y = ($Top + 1); $Y -lt $Bottom; $Y++)
    {
        Set-WtScreenText -Screen $Screen -Row $Y -Column $Left -Text ([string]$Glyph.Vertical) -Style $BorderStyle
        Set-WtScreenText -Screen $Screen -Row $Y -Column $Right -Text ([string]$Glyph.Vertical) -Style $BorderStyle
    }

    if ($Title -and $Width -gt 4)
    {
        $Available = $Width - 4
        $TitleText = Format-WtText -Text $Title -Width $Available
        Set-WtScreenText -Screen $Screen -Row $Top -Column ($Left + 2) -Text " $TitleText " -Style $TitleStyle -MaxWidth $Available
    }

    $Screen.Dirty = $true
}

<#
.SYNOPSIS
    Draws a horizontal divider with the requested junction glyph.
#>
function Add-WtScreenDivider
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][int]$Row,
        [Parameter(Mandatory = $true)][int]$Column,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $false)][ValidateSet('Horizontal', 'TeeLeft', 'TeeRight', 'TeeTop', 'TeeBottom', 'Cross')][string]$GlyphName = 'Horizontal',
        [Parameter(Mandatory = $false)][string]$Style = 'Border'
    )

    if ($Width -lt 1)
    {
        return
    }

    $Glyph = $Screen.Theme.Border
    Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text ([string]$Glyph[$GlyphName] * $Width) -Style $Style -MaxWidth $Width
}

<#
.SYNOPSIS
    Truncates text to a cell width, appending an ellipsis when it does not fit.
#>
function Format-WtText
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $false)][string]$Ellipsis = '…'
    )

    if ($Width -le 0)
    {
        return ''
    }

    $Display = ConvertTo-WtDisplayText -Text $Text
    if ((Get-WtTextWidth -Text $Display) -le $Width)
    {
        return $Display
    }

    $Target = $Width - (Get-WtTextWidth -Text $Ellipsis)
    if ($Target -lt 1)
    {
        $Ellipsis = ''
        $Target = $Width
    }

    $Builder = [System.Text.StringBuilder]::new()
    $Used = 0
    $Index = 0

    while ($Index -lt $Display.Length)
    {
        $Character = $Display[$Index]
        $Code = [int][char]$Character

        $CellWidth = 1
        $Point = $Code
        if ($Code -ge 0xD800 -and $Code -le 0xDBFF -and ($Index + 1) -lt $Display.Length)
        {
            [void]$Builder.Append($Display.Substring($Index, 2))
            $Low = [int][char]$Display[$Index + 1]
            $Point = 0x10000 + (($Code - 0xD800) * 0x400) + ($Low - 0xDC00)
            if (Test-WtWideCodePoint -CodePoint $Point) { $CellWidth = 2 }
            $Index += 2
        }
        else
        {
            [void]$Builder.Append($Character)
            if (Test-WtWideCodePoint -CodePoint $Code) { $CellWidth = 2 }
            $Index++
        }

        # A combining mark or variation selector belongs to the character in front of it,
        # so it is kept (never counted, never cut off by itself).
        if (Test-WtZeroWidthCodePoint -CodePoint $Point)
        {
            continue
        }

        $Used += $CellWidth
        if ($Used -ge $Target)
        {
            break
        }
    }

    return ($Builder.ToString() + $Ellipsis)
}

<#
.SYNOPSIS
    Pads text to an exact cell width (right-aligned when -Align Right).
#>
function Format-WtColumn
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $false)][ValidateSet('Left', 'Right', 'Centre')][string]$Align = 'Left'
    )

    if ($Width -le 0)
    {
        return ''
    }

    $Display = Format-WtText -Text $Text -Width $Width
    $Pad = $Width - (Get-WtTextWidth -Text $Display)
    if ($Pad -le 0)
    {
        return $Display
    }

    switch ($Align)
    {
        'Right' { return ((' ' * $Pad) + $Display) }
        'Centre'
        {
            $Left = [math]::Floor($Pad / 2)
            return ((' ' * $Left) + $Display + (' ' * ($Pad - $Left)))
        }
        default { return ($Display + (' ' * $Pad)) }
    }
}

<#
.SYNOPSIS
    Wraps text to a cell width, breaking on spaces and on hard boundaries.
.DESCRIPTION
    Used for dialog bodies and detail panes so long English or Vietnamese sentences stay
    inside their panel instead of being clipped mid-word.
#>
function Format-WtWrappedText
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][int]$Width
    )

    $Lines = [System.Collections.Generic.List[string]]::new()
    if ($Width -lt 1)
    {
        return $Lines.ToArray()
    }

    foreach ($Paragraph in (ConvertTo-WtDisplayText -Text $Text) -split "`n")
    {
        if ([string]::IsNullOrWhiteSpace($Paragraph))
        {
            $Lines.Add('')
            continue
        }

        $Current = ''
        foreach ($Word in ($Paragraph.Trim() -split '\s+'))
        {
            $Candidate = if ($Current) { "$Current $Word" } else { $Word }

            if ((Get-WtTextWidth -Text $Candidate) -le $Width)
            {
                $Current = $Candidate
                continue
            }

            if ($Current)
            {
                $Lines.Add($Current)
                $Current = ''
            }

            # A single word longer than the line is hard-split.
            $Remaining = $Word
            while ((Get-WtTextWidth -Text $Remaining) -gt $Width)
            {
                $Chunk = Format-WtText -Text $Remaining -Width $Width -Ellipsis ''
                if ([string]::IsNullOrEmpty($Chunk))
                {
                    break
                }
                $Lines.Add($Chunk)
                $Remaining = $Remaining.Substring($Chunk.Length)
            }

            $Current = $Remaining
        }

        $Lines.Add($Current)
    }

    return $Lines.ToArray()
}

<#
.SYNOPSIS
    Renders one row of the grid into a string containing ANSI sequences.
#>
function ConvertTo-WtScreenLine
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][int]$Row
    )

    $Line = $Screen.Rows[$Row - 1]
    $Limit = Get-WtRowWidth -Screen $Screen -Row $Row
    $Prefixes = $Screen.Theme.Prefixes
    $Builder = [System.Text.StringBuilder]::new($Screen.Width + 16)
    $Current = -1

    for ($Column = 0; $Column -lt $Limit; $Column++)
    {
        $StyleId = $Line.Styles[$Column]
        if ($StyleId -ne $Current)
        {
            if ($StyleId -ge 0 -and $StyleId -lt $Prefixes.Count)
            {
                [void]$Builder.Append($Prefixes[$StyleId])
            }
            $Current = $StyleId
        }

        [void]$Builder.Append($Line.Cells[$Column])
    }

    return $Builder.ToString()
}

<#
.SYNOPSIS
    Renders the whole grid into an array of strings with ANSI sequences applied.
.DESCRIPTION
    Kept separate from the console write so the exact painted frame can be asserted in
    tests without a terminal.
#>
function ConvertTo-WtScreenText
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $true)][object]$Screen)

    $Lines = [System.Collections.Generic.List[string]]::new($Screen.Height)
    for ($Row = 1; $Row -le $Screen.Height; $Row++)
    {
        $Lines.Add((ConvertTo-WtScreenLine -Screen $Screen -Row $Row))
    }

    return $Lines.ToArray()
}

<#
.SYNOPSIS
    Returns the visible text of one row, one entry per cell, with no escape sequences.
#>
function Get-WtScreenRowText
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][int]$Row
    )

    $Line = $Screen.Rows[$Row - 1]
    $Limit = Get-WtRowWidth -Screen $Screen -Row $Row
    $Cells = [string[]]::new($Limit)

    for ($Column = 0; $Column -lt $Limit; $Column++)
    {
        $Cells[$Column] = $Line.Cells[$Column]
    }

    return $Cells
}

<#
.SYNOPSIS
    Renders the whole grid into plain text lines with no escape sequences.
.DESCRIPTION
    Used by the tests and by the no-colour fallback path to inspect what the user
    would actually read.
#>
function ConvertTo-WtScreenPlainText
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $true)][object]$Screen)

    $Lines = [System.Collections.Generic.List[string]]::new($Screen.Height)
    for ($Row = 1; $Row -le $Screen.Height; $Row++)
    {
        $Builder = [System.Text.StringBuilder]::new($Screen.Width)
        foreach ($Cell in (Get-WtScreenRowText -Screen $Screen -Row $Row))
        {
            [void]$Builder.Append($Cell)
        }
        $Lines.Add($Builder.ToString())
    }

    return $Lines.ToArray()
}

<#
.SYNOPSIS
    Writes a frame using ANSI cursor addressing.
.DESCRIPTION
    One console write per frame, every changed line positioned explicitly. Rows whose
    cells and styles are identical to the last written frame are skipped, so a frame that
    only moved the cursor rewrites just the rows that actually changed. No scrolling can
    occur and no Clear-Host is needed.
#>
function Write-WtScreen
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Screen)

    $Escape = [char]27
    $Builder = [System.Text.StringBuilder]::new(($Screen.Width + 24) * $Screen.Height)
    [void]$Builder.Append("$Escape[?25l")

    $Changed = Get-WtScreenChangedRows -Screen $Screen
    $Written = 0

    for ($Row = 1; $Row -le $Screen.Height; $Row++)
    {
        if (-not $Changed[$Row - 1]) { continue }

        [void]$Builder.Append("$Escape[$($Row);1H")
        [void]$Builder.Append((ConvertTo-WtScreenLine -Screen $Screen -Row $Row))
        $Written++
    }

    [void]$Builder.Append("$Escape[0m")

    if ($Written -eq 0)
    {
        $Screen.LastWrittenRows = 0
        return
    }

    try
    {
        [Console]::Out.Write($Builder.ToString())
        [Console]::Out.Flush()

        for ($Row = 1; $Row -le $Screen.Height; $Row++)
        {
            if ($Changed[$Row - 1]) { Set-WtScreenRowWritten -Screen $Screen -Row $Row }
        }

        $Screen.LastWrittenRows = $Written
        $Screen.Dirty = $false
    }
    catch
    {
        Write-WtLog -Level Warning -Message "Could not write a TUI frame: $($_.Exception.Message)" -NoConsole
    }
}

<#
.SYNOPSIS
    Writes a frame through the [Console] API for hosts without virtual terminal support.
.DESCRIPTION
    Only rows that differ from the last written frame are touched, and each row is written
    in one buffered run per style segment instead of one call per cell. This keeps the
    classic console (Windows PowerShell 5.1 without virtual terminal processing) on the
    same changed-row contract as the ANSI renderer.
#>
function Write-WtScreenPlain
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Screen)

    $StyleList = $Screen.Theme.StyleList
    $Changed = Get-WtScreenChangedRows -Screen $Screen
    $Written = 0

    try
    {
        try { [Console]::CursorVisible = $false } catch { $null = $_ }

        for ($Row = 1; $Row -le $Screen.Height; $Row++)
        {
            if (-not $Changed[$Row - 1]) { continue }

            $Index = $Row - 1
            $Line = $Screen.Rows[$Index]
            $Limit = Get-WtRowWidth -Screen $Screen -Row $Row

            try { [Console]::SetCursorPosition(0, $Index) } catch { $null = $_ }

            $CurrentStyle = -1
            $Segment = [System.Text.StringBuilder]::new($Limit)

            for ($Column = 0; $Column -lt $Limit; $Column++)
            {
                $StyleId = $Line.Styles[$Column]
                if ($StyleId -ne $CurrentStyle)
                {
                    if ($Segment.Length -gt 0)
                    {
                        [Console]::Out.Write($Segment.ToString())
                        [void]$Segment.Clear()
                    }

                    if ($StyleId -ge 0 -and $StyleId -lt $StyleList.Count)
                    {
                        $Style = $StyleList[$StyleId]
                        try { [Console]::ForegroundColor = [System.ConsoleColor]$Style.ConsoleForeground } catch { $null = $_ }
                        try { [Console]::BackgroundColor = [System.ConsoleColor]$Style.ConsoleBackground } catch { $null = $_ }
                    }

                    $CurrentStyle = $StyleId
                }

                [void]$Segment.Append($Line.Cells[$Column])
            }

            if ($Segment.Length -gt 0)
            {
                [Console]::Out.Write($Segment.ToString())
            }

            $Written++
        }

        try { [Console]::ResetColor() } catch { $null = $_ }

        for ($Row = 1; $Row -le $Screen.Height; $Row++)
        {
            if ($Changed[$Row - 1]) { Set-WtScreenRowWritten -Screen $Screen -Row $Row }
        }

        $Screen.LastWrittenRows = $Written
        $Screen.Dirty = $false
    }
    catch
    {
        Write-WtLog -Level Warning -Message "Could not write a plain TUI frame: $($_.Exception.Message)" -NoConsole
    }
}
