# WindowsTweaker - TUI theme, colour capability detection and text metrics.
#
# Presentation only: no function in this file reads or writes system state and no
# third-party library is involved. The palette is the Catppuccin Mocha set named by
# the specification; every style resolves to a concrete foreground/background pair so
# the renderer never has to guess, and every style has a value for each supported
# colour depth (true colour, 256 colours, 16 colours, no colour).

$Script:WtTuiCapabilityCache = $null

$Script:WtTuiPalette = [ordered]@{
    Background = '#1e1e2e'
    Surface    = '#181825'
    Panel      = '#313244'
    Text       = '#cdd6f4'
    Subtext    = '#bac2de'
    Accent     = '#89b4fa'
    Success    = '#a6e3a1'
    Warning    = '#f9e2af'
    Error      = '#f38ba8'
    Muted      = '#6c7086'
    Disabled   = '#7f849c'
    Inactive   = '#a6adc8'
    Border     = '#45475a'
}

# Palette equivalents for 16-colour terminals. Chosen by hand rather than by nearest
# distance: on a 16-colour terminal every palette colour collapses onto "silver",
# which would make the accent, the warning and the selection surface indistinguishable.
$Script:WtTuiAnsi16Palette = [ordered]@{
    Background = 'Black'
    Surface    = 'Black'
    Panel      = 'DarkGray'
    Text       = 'Gray'
    Subtext    = 'Gray'
    Accent     = 'Cyan'
    Success    = 'Green'
    Warning    = 'Yellow'
    Error      = 'Red'
    Muted      = 'DarkGray'
    Disabled   = 'DarkGray'
    Inactive   = 'DarkGray'
    Border     = 'DarkGray'
}

# Semantic styles used by the renderer. `Ansi16` overrides only the pairs whose
# 16-colour equivalent would have too little contrast.
$Script:WtTuiStyleSpecs = [ordered]@{
    Default        = @{ Foreground = 'Text'; Background = 'Background' }
    Header         = @{ Foreground = 'Text'; Background = 'Surface' }
    HeaderMeta     = @{ Foreground = 'Subtext'; Background = 'Surface' }
    Title          = @{ Foreground = 'Accent'; Background = 'Surface' }
    PanelTitle     = @{ Foreground = 'Accent'; Background = 'Background' }
    PanelTitleIdle = @{ Foreground = 'Muted'; Background = 'Background' }
    Border         = @{ Foreground = 'Border'; Background = 'Background' }
    Item           = @{ Foreground = 'Text'; Background = 'Background' }
    ItemMeta       = @{ Foreground = 'Muted'; Background = 'Background' }
    Selected       = @{ Foreground = 'Text'; Background = 'Panel'; Ansi16 = @{ Foreground = 'Black'; Background = 'Gray' } }
    Focused        = @{ Foreground = 'Accent'; Background = 'Panel'; Ansi16 = @{ Foreground = 'Black'; Background = 'Cyan' } }
    Pending        = @{ Foreground = 'Accent'; Background = 'Background' }
    Muted          = @{ Foreground = 'Muted'; Background = 'Background' }
    Disabled       = @{ Foreground = 'Disabled'; Background = 'Background' }
    Success        = @{ Foreground = 'Success'; Background = 'Background' }
    Warning        = @{ Foreground = 'Warning'; Background = 'Background' }
    Error          = @{ Foreground = 'Error'; Background = 'Background' }
    StatusBar      = @{ Foreground = 'Subtext'; Background = 'Surface' }
    StatusInfo     = @{ Foreground = 'Subtext'; Background = 'Surface' }
    StatusOk       = @{ Foreground = 'Success'; Background = 'Surface' }
    StatusWarn     = @{ Foreground = 'Warning'; Background = 'Surface' }
    StatusError    = @{ Foreground = 'Error'; Background = 'Surface' }
    Dialog         = @{ Foreground = 'Text'; Background = 'Panel' }
    DialogTitle    = @{ Foreground = 'Accent'; Background = 'Panel'; Ansi16 = @{ Foreground = 'Black'; Background = 'DarkCyan' } }
    DialogHint     = @{ Foreground = 'Subtext'; Background = 'Panel' }
    DialogItem     = @{ Foreground = 'Text'; Background = 'Panel' }
    DialogSelected = @{ Foreground = 'Accent'; Background = 'Surface'; Ansi16 = @{ Foreground = 'Black'; Background = 'Cyan' } }
    DialogChecked  = @{ Foreground = 'Success'; Background = 'Panel' }
    DialogBlocked  = @{ Foreground = 'Muted'; Background = 'Panel' }
    Input          = @{ Foreground = 'Text'; Background = 'Surface' }
    InputLabel     = @{ Foreground = 'Subtext'; Background = 'Panel' }
    InputCursor    = @{ Foreground = 'Background'; Background = 'Text' }

    # Icon styles. One per semantic colour class (see Private/Tui/Icons.ps1), plus the
    # two background contexts an icon can be drawn on: the normal row background
    # (Background) and the highlighted row background (Panel). The 16-colour overrides
    # follow the surfaces the 16-colour Selected/Focused styles use, so an icon never
    # leaves a differently coloured block inside a highlighted row.
    IconCategory       = @{ Foreground = 'Accent'; Background = 'Background' }
    IconSuccess        = @{ Foreground = 'Success'; Background = 'Background' }
    IconWarning        = @{ Foreground = 'Warning'; Background = 'Background' }
    IconError          = @{ Foreground = 'Error'; Background = 'Background' }
    IconInactive       = @{ Foreground = 'Inactive'; Background = 'Background' }
    IconCategoryPanel  = @{ Foreground = 'Accent'; Background = 'Panel'; Ansi16 = @{ Background = 'Gray' } }
    IconSuccessPanel   = @{ Foreground = 'Success'; Background = 'Panel'; Ansi16 = @{ Background = 'Gray' } }
    IconWarningPanel   = @{ Foreground = 'Warning'; Background = 'Panel'; Ansi16 = @{ Background = 'Gray' } }
    IconErrorPanel     = @{ Foreground = 'Error'; Background = 'Panel'; Ansi16 = @{ Background = 'Gray' } }
    IconInactivePanel  = @{ Foreground = 'Inactive'; Background = 'Panel'; Ansi16 = @{ Foreground = 'Black'; Background = 'Gray' } }
    IconCategoryFocus  = @{ Foreground = 'Accent'; Background = 'Panel'; Ansi16 = @{ Foreground = 'Black'; Background = 'Cyan' } }
    IconSuccessFocus   = @{ Foreground = 'Success'; Background = 'Panel'; Ansi16 = @{ Foreground = 'Black'; Background = 'Cyan' } }
    IconWarningFocus   = @{ Foreground = 'Warning'; Background = 'Panel'; Ansi16 = @{ Foreground = 'Black'; Background = 'Cyan' } }
    IconErrorFocus     = @{ Foreground = 'Error'; Background = 'Panel'; Ansi16 = @{ Foreground = 'Black'; Background = 'Cyan' } }
    IconInactiveFocus  = @{ Foreground = 'Inactive'; Background = 'Panel'; Ansi16 = @{ Foreground = 'Black'; Background = 'Cyan' } }
}

<#
.SYNOPSIS
    Returns the Catppuccin Mocha palette as '#rrggbb' strings.
#>
function Get-WtTuiPalette
{
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param ()

    return $Script:WtTuiPalette
}

<#
.SYNOPSIS
    Converts '#rrggbb' into its three channel values.
.DESCRIPTION
    Returns $null for anything that is not a 6-digit hex colour so a typo becomes an
    obvious failure instead of a silently black cell.
#>
function ConvertFrom-WtHexColour
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Hex)

    if ($Hex -notmatch '^#(?<R>[0-9A-Fa-f]{2})(?<G>[0-9A-Fa-f]{2})(?<B>[0-9A-Fa-f]{2})$')
    {
        return $null
    }

    return @{
        Red   = [Convert]::ToInt32($Matches.R, 16)
        Green = [Convert]::ToInt32($Matches.G, 16)
        Blue  = [Convert]::ToInt32($Matches.B, 16)
    }
}

<#
.SYNOPSIS
    Finds the nearest colour in the xterm 256-colour palette.
.DESCRIPTION
    Only the deterministic part of the palette is searched (the 6x6x6 cube and the
    grey ramp, indexes 16..255) so the result does not depend on the terminal theme.
#>
function ConvertTo-WtAnsi256Index
{
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory = $true)][int]$Red,
        [Parameter(Mandatory = $true)][int]$Green,
        [Parameter(Mandatory = $true)][int]$Blue
    )

    # 6x6x6 cube: index = 16 + 36r + 6g + b
    $Steps = @(0, 95, 135, 175, 215, 255)
    $CubeRed = 0
    $CubeGreen = 0
    $CubeBlue = 0
    $CubeDistance = [double]::MaxValue

    for ($R = 0; $R -lt 6; $R++)
    {
        for ($G = 0; $G -lt 6; $G++)
        {
            for ($B = 0; $B -lt 6; $B++)
            {
                $Distance = [math]::Pow($Steps[$R] - $Red, 2) + [math]::Pow($Steps[$G] - $Green, 2) + [math]::Pow($Steps[$B] - $Blue, 2)
                if ($Distance -lt $CubeDistance)
                {
                    $CubeDistance = $Distance
                    $CubeRed = $R
                    $CubeGreen = $G
                    $CubeBlue = $B
                }
            }
        }
    }

    # Grey ramp: index = 232 + n, value = 8 + 10n
    $Grey = [math]::Round(((($Red + $Green + $Blue) / 3) - 8) / 10)
    $Grey = [math]::Max(0, [math]::Min(23, $Grey))
    $GreyValue = 8 + (10 * $Grey)
    $GreyDistance = [math]::Pow($GreyValue - $Red, 2) + [math]::Pow($GreyValue - $Green, 2) + [math]::Pow($GreyValue - $Blue, 2)

    if ($GreyDistance -lt $CubeDistance)
    {
        return (232 + $Grey)
    }

    return (16 + (36 * $CubeRed) + (6 * $CubeGreen) + $CubeBlue)
}

<#
.SYNOPSIS
    Builds the ANSI escape sequence that selects a 24-bit or 256-colour pair.
.PARAMETER Mode
    TrueColor or Ansi256.
#>
function New-WtColourSequence
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Foreground,
        [Parameter(Mandatory = $true)][string]$Background,
        [Parameter(Mandatory = $true)][ValidateSet('TrueColor', 'Ansi256')][string]$Mode
    )

    $Fore = ConvertFrom-WtHexColour -Hex $Foreground
    $Back = ConvertFrom-WtHexColour -Hex $Background

    if ($Mode -eq 'Ansi256')
    {
        $ForeIndex = ConvertTo-WtAnsi256Index -Red $Fore.Red -Green $Fore.Green -Blue $Fore.Blue
        $BackIndex = ConvertTo-WtAnsi256Index -Red $Back.Red -Green $Back.Green -Blue $Back.Blue
        return ("{0}[38;5;{1}m{0}[48;5;{2}m" -f [char]27, $ForeIndex, $BackIndex)
    }

    return ("{0}[38;2;{1};{2};{3}m{0}[48;2;{4};{5};{6}m" -f [char]27, $Fore.Red, $Fore.Green, $Fore.Blue, $Back.Red, $Back.Green, $Back.Blue)
}

<#
.SYNOPSIS
    Builds the ANSI escape sequence that selects a 16-colour pair.
.DESCRIPTION
    Accepts the [System.ConsoleColor] names so the same table serves the ANSI renderer
    and the [Console] API renderer.
#>
function New-WtAnsi16Sequence
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Foreground,
        [Parameter(Mandatory = $true)][string]$Background
    )

    $Codes = @{
        Black        = 0
        DarkRed      = 1
        DarkGreen    = 2
        DarkYellow   = 3
        DarkBlue     = 4
        DarkMagenta  = 5
        DarkCyan     = 6
        Gray         = 7
        DarkGray     = 8
        Red          = 9
        Green        = 10
        Yellow       = 11
        Blue         = 12
        Magenta      = 13
        Cyan         = 14
        White        = 15
    }

    if (-not $Codes.ContainsKey($Foreground) -or -not $Codes.ContainsKey($Background))
    {
        return ''
    }

    $ForeCode = if ($Codes[$Foreground] -lt 8) { 30 + $Codes[$Foreground] } else { 82 + $Codes[$Foreground] }
    $BackCode = if ($Codes[$Background] -lt 8) { 40 + $Codes[$Background] } else { 92 + $Codes[$Background] }

    return ("{0}[{1};{2}m" -f [char]27, $ForeCode, $BackCode)
}

<#
.SYNOPSIS
    Describes what the current terminal can render: colour depth and character set.
.DESCRIPTION
    Detection is read-only. -Colour and -Ascii force a mode (used by the CLI switches
    and by the tests); otherwise the mode is derived from the host's virtual terminal
    support and the output encoding.
#>
function Get-WtTuiCapability
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][ValidateSet('Auto', 'TrueColor', 'Ansi256', 'Ansi16', 'Mono')][string]$Colour = 'Auto',
        [Parameter(Mandatory = $false)][switch]$Ascii,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    if ($Script:WtTuiCapabilityCache -and -not $Force -and $Colour -eq 'Auto' -and -not $Ascii)
    {
        return $Script:WtTuiCapabilityCache
    }

    # Windows PowerShell 5.1 never enables ENABLE_VIRTUAL_TERMINAL_PROCESSING, so the host
    # property below reports no virtual terminal even on a console that renders the
    # sequences. The compatibility layer probes the console first (and enables the mode on
    # Windows), and its answer is the initial value: the host can only confirm it.
    $VirtualTerminal = Test-WtConsoleVirtualTerminalAvailable
    if (-not $VirtualTerminal)
    {
        try
        {
            $VirtualTerminal = [bool]$Host.UI.SupportsVirtualTerminal
        }
        catch
        {
            $VirtualTerminal = $false
        }
    }

    if (-not $VirtualTerminal -and $env:TERM -and $env:TERM -ne 'dumb')
    {
        # A terminal that reports a terminfo entry supports the sequences we use.
        $VirtualTerminal = $true
    }

    $Encoding = 'ascii'
    try
    {
        if ([Console]::OutputEncoding) { $Encoding = [Console]::OutputEncoding.WebName }
    }
    catch
    {
        $Encoding = 'ascii'
    }

    $Unicode = -not $Ascii
    if ($Unicode -and $Encoding -notmatch 'utf')
    {
        # Box drawing survives a legacy code page, but the Vietnamese diacritics used by
        # the interface do not, so fall back to plain ASCII frames and let the status bar
        # report the reduced character set instead of printing mojibake.
        $Unicode = $false
    }

    $Resolved = $Colour
    if ($Resolved -eq 'Auto')
    {
        if (-not $VirtualTerminal)
        {
            $Resolved = 'Mono'
        }
        elseif ($env:COLORTERM -match 'truecolor|24bit')
        {
            $Resolved = 'TrueColor'
        }
        elseif ($env:TERM -and $env:TERM -match '256')
        {
            $Resolved = 'Ansi256'
        }
        elseif ((Get-WtRuntimeProfile).IsWindows)
        {
            # Windows Terminal and modern conhost both render 24-bit colour.
            $Resolved = 'TrueColor'
        }
        else
        {
            $Resolved = 'Ansi16'
        }
    }

    # A host without virtual terminal support gets no colour automatically, but an
    # explicitly requested depth is honoured: only 'Auto' is downgraded.
    if ($Colour -eq 'Auto' -and -not $VirtualTerminal -and $Resolved -ne 'Mono')
    {
        $Resolved = 'Mono'
    }

    $Capability = @{
        VirtualTerminal = $VirtualTerminal
        Colour          = $Resolved
        Unicode         = $Unicode
        Encoding        = $Encoding
    }

    if ($Colour -eq 'Auto' -and -not $Ascii)
    {
        $Script:WtTuiCapabilityCache = $Capability
    }

    return $Capability
}

<#
.SYNOPSIS
    Builds the style table the renderer stores in every screen cell.
.DESCRIPTION
    Returns an ordered table name -> @{ Id; Prefix; Foreground; Background;
    ConsoleForeground; ConsoleBackground }. Id 0 is always Default so a blank cell
    needs no special case.
#>
function New-WtTuiTheme
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$Colour = 'TrueColor',
        [Parameter(Mandatory = $false)][switch]$Unicode,
        [Parameter(Mandatory = $false)][string]$IconMode = 'Auto'
    )

    $Styles = [ordered]@{}
    $Id = 0

    foreach ($Name in $Script:WtTuiStyleSpecs.Keys)
    {
        $Spec = $Script:WtTuiStyleSpecs[$Name]
        $ForegroundName = [string]$Spec.Foreground
        $BackgroundName = [string]$Spec.Background

        $ConsoleForeground = $Script:WtTuiAnsi16Palette[$ForegroundName]
        $ConsoleBackground = $Script:WtTuiAnsi16Palette[$BackgroundName]

        if ($Spec.ContainsKey('Ansi16') -and $Colour -in 'Ansi16', 'Mono')
        {
            if ($Spec.Ansi16.ContainsKey('Foreground')) { $ConsoleForeground = [string]$Spec.Ansi16.Foreground }
            if ($Spec.Ansi16.ContainsKey('Background')) { $ConsoleBackground = [string]$Spec.Ansi16.Background }
        }

        $Prefix = ''
        if ($Colour -in 'TrueColor', 'Ansi256')
        {
            $Prefix = New-WtColourSequence -Foreground $Script:WtTuiPalette[$ForegroundName] -Background $Script:WtTuiPalette[$BackgroundName] -Mode $Colour
        }
        elseif ($Colour -eq 'Ansi16')
        {
            $Prefix = New-WtAnsi16Sequence -Foreground $ConsoleForeground -Background $ConsoleBackground
        }
        elseif ($Name -in 'Selected', 'Focused', 'DialogSelected', 'DialogTitle', 'InputCursor',
            'IconCategoryPanel', 'IconSuccessPanel', 'IconWarningPanel', 'IconErrorPanel', 'IconInactivePanel',
            'IconCategoryFocus', 'IconSuccessFocus', 'IconWarningFocus', 'IconErrorFocus', 'IconInactiveFocus')
        {
            # Without colour the selection still has to be visible: reverse video is the
            # one attribute every terminal understands. The icon styles are listed here
            # too, otherwise an icon cell inside a highlighted row would drop the
            # reverse video and leave a hole in the selection.
            $Prefix = "$([char]27)[7m"
        }

        $Styles[$Name] = @{
            Id                = $Id
            Name              = $Name
            Prefix            = $Prefix
            Foreground        = $ForegroundName
            Background        = $BackgroundName
            ConsoleForeground = $ConsoleForeground
            ConsoleBackground = $ConsoleBackground
        }

        $Id++
    }

    # Id-indexed views of the style table: the renderer looks up a style by the id
    # stored in every cell, so both directions must stay in sync.
    $Prefixes = [string[]]::new($Styles.Count)
    $StyleList = [object[]]::new($Styles.Count)
    foreach ($Style in $Styles.Values)
    {
        $Prefixes[[int]$Style.Id] = [string]$Style.Prefix
        $StyleList[[int]$Style.Id] = $Style
    }

    return @{
        Name      = 'Catppuccin Mocha'
        Colour    = $Colour
        Unicode   = [bool]$Unicode
        IconMode  = $IconMode
        Icons     = (New-WtIconTable -Mode $IconMode)
        Styles    = $Styles
        Prefixes  = $Prefixes
        StyleList = $StyleList
        Border    = if ($Unicode)
        {
            @{
                TopLeft     = [char]0x250C
                TopRight    = [char]0x2510
                BottomLeft  = [char]0x2514
                BottomRight = [char]0x2518
                Horizontal  = [char]0x2500
                Vertical    = [char]0x2502
                TeeLeft     = [char]0x251C
                TeeRight    = [char]0x2524
                TeeTop      = [char]0x252C
                TeeBottom   = [char]0x2534
                Cross       = [char]0x253C
            }
        }
        else
        {
            @{
                TopLeft     = '+'
                TopRight    = '+'
                BottomLeft  = '+'
                BottomRight = '+'
                Horizontal  = '-'
                Vertical    = '|'
                TeeLeft     = '+'
                TeeRight    = '+'
                TeeTop      = '+'
                TeeBottom   = '+'
                Cross       = '+'
            }
        }
    }
}

<#
.SYNOPSIS
    Resolves a style name to its numeric id (0 = Default for an unknown name).
#>
function Get-WtStyleId
{
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Theme,
        [Parameter(Mandatory = $false)][string]$Name = 'Default'
    )

    if ($Name -and $Theme.Styles.Contains($Name))
    {
        return [int]$Theme.Styles[$Name].Id
    }

    return 0
}

<#
.SYNOPSIS
    Measures how many terminal cells a string occupies.
.DESCRIPTION
    Combining marks and control characters count as zero, East Asian wide characters
    and astral-plane emoji count as two. Square box-drawing characters count as one,
    which is what keeps the panels aligned.
#>
function Get-WtTextWidth
{
    [CmdletBinding()]
    [OutputType([int])]
    param ([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text))
    {
        return 0
    }

    $Width = 0
    $Index = 0

    while ($Index -lt $Text.Length)
    {
        $Code = [int][char]$Text[$Index]

        if ($Code -ge 0xD800 -and $Code -le 0xDBFF -and ($Index + 1) -lt $Text.Length)
        {
            $Low = [int][char]$Text[$Index + 1]
            $Point = 0x10000 + (($Code - 0xD800) * 0x400) + ($Low - 0xDC00)
            if (-not (Test-WtZeroWidthCodePoint -CodePoint $Point))
            {
                $Width += $(if (Test-WtWideCodePoint -CodePoint $Point) { 2 } else { 1 })
            }
            $Index += 2
            continue
        }

        $Index++

        if ($Code -lt 32)
        {
            continue
        }

        if (Test-WtZeroWidthCodePoint -CodePoint $Code)
        {
            continue
        }

        $Width += $(if (Test-WtWideCodePoint -CodePoint $Code) { 2 } else { 1 })
    }

    return $Width
}

<#
.SYNOPSIS
    Reports whether a code point occupies two terminal cells.
#>
function Test-WtWideCodePoint
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][int]$CodePoint)

    foreach ($Range in $Script:WtWideRanges)
    {
        if ($CodePoint -ge $Range[0] -and $CodePoint -le $Range[1])
        {
            return $true
        }
    }

    return $false
}

$Script:WtWideRanges = @(
    @(0x1100, 0x115F),
    @(0x2E80, 0x303E),
    @(0x3041, 0x33FF),
    @(0x3400, 0x4DBF),
    @(0x4E00, 0x9FFF),
    @(0xA000, 0xA4CF),
    @(0xAC00, 0xD7A3),
    @(0xF900, 0xFAFF),
    @(0xFE10, 0xFE19),
    @(0xFE30, 0xFE6F),
    @(0xFF00, 0xFF60),
    @(0xFFE0, 0xFFE6),
    @(0x1F300, 0x1F64F),
    @(0x1F900, 0x1F9FF),
    @(0x20000, 0x3FFFD)
)

# Code points that occupy no cell of their own: combining marks (which attach to the base
# character that precedes them) and variation selectors (which only choose how the previous
# character is drawn). Listed by range rather than derived, because the width model, the
# painter and the truncator must agree on exactly the same set - a disagreement here is what
# shifts a column behind an icon.
$Script:WtZeroWidthRanges = @(
    @(0x0300, 0x036F),
    @(0x0483, 0x0489),
    @(0x1AB0, 0x1AFF),
    @(0x1DC0, 0x1DFF),
    @(0x200B, 0x200F),
    @(0x2060, 0x2064),
    @(0x20D0, 0x20FF),
    @(0xFE00, 0xFE0F),
    @(0xFE20, 0xFE2F),
    @(0xE0100, 0xE01EF)
)

<#
.SYNOPSIS
    Reports whether a code point occupies no cell of its own (combining mark or variation
    selector).
#>
function Test-WtZeroWidthCodePoint
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][int]$CodePoint)

    foreach ($Range in $Script:WtZeroWidthRanges)
    {
        if ($CodePoint -ge $Range[0] -and $CodePoint -le $Range[1])
        {
            return $true
        }
    }

    return $false
}

<#
.SYNOPSIS
    Normalises text for display: NFC, control characters removed, tabs expanded.
.DESCRIPTION
    Vietnamese input can arrive decomposed (base letter + combining mark), which would
    break column alignment. Normalising to NFC also makes the width calculation above
    correct for text that came from a file or a clipboard.
#>
function ConvertTo-WtDisplayText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text))
    {
        return ''
    }

    $Normalised = $Text
    try
    {
        $Normalised = $Text.Normalize([System.Text.NormalizationForm]::FormC)
    }
    catch
    {
        $Normalised = $Text
    }

    $Builder = [System.Text.StringBuilder]::new($Normalised.Length)
    foreach ($Character in $Normalised.ToCharArray())
    {
        if ($Character -eq [char]9)
        {
            [void]$Builder.Append('    ')
            continue
        }

        if ([char]::IsControl($Character))
        {
            continue
        }

        [void]$Builder.Append($Character)
    }

    return $Builder.ToString()
}
