# WindowsTweaker - terminal interface icon registry.
#
# One file owns every glyph the interface can draw. Rendering code never contains a
# literal symbol: it asks for a semantic key ("Category.Network", "Status.Warning") and
# this registry answers with the glyph of the active icon set. That keeps the four
# display modes consistent, makes the vocabulary testable, and means a symbol is never
# scattered across the painter.
#
# Design rules this file encodes:
#   * Monochrome only. No colour emoji and no variation selectors, so a glyph can never
#     be promoted to a double-width emoji presentation by the terminal.
#   * Unicode stays away from East Asian Wide/Fullwidth characters; the exceptions are
#     the geometric shapes marked below, which the width model in Theme.ps1 (and every
#     monospace font's ambiguous-width default) already counts as one cell, exactly like
#     the box-drawing frame this interface already draws.
#   * NerdFont uses only the private-use area of the Basic Multilingual Plane
#     (U+E000..U+F8FF), in practice the Font Awesome block U+F000..U+F2FF, which is one
#     cell wide in the Nerd Font patched fonts. No astral-plane code points, so the width
#     model never has to guess about a surrogate pair.
#   * ASCII is a readable bracket tag, not a symbol, so the mode stays usable on a
#     legacy code page without pretending to detect what the font can draw.
#   * "None" answers an empty string for every key: the label alone is the interface.
#
# The three symbol sets are full vocabularies: every key exists in every set, so a mode
# switch can never leave a surface without an icon or a label.
#
# Surfaces that draw an icon today: the category pane and the compact tab strip; every
# tweak row (the icon of that tweak's own catalog category); the history rows (the
# outcome, or the rollback); the details pane (the category title, the current state, the
# administrator requirement, the restart requirement, the rollback fidelity and the
# warning/error sections); the header (brand and the capability notice); the status line;
# the dialog titles, the dialog list entries and the Yes/No buttons; the operation
# panel (title, running item and the progress bar); and the overview workspace rows
# (monitoring, disk usage, quarantine and licensing - see $Script:WtActionIconKeys).
#
# Category.Repairs, Category.Drivers, Category.Printers, Action.Refresh and Action.Select
# are part of the vocabulary the specification asks for but no surface of this interface
# draws yet; they are listed here so a surface that needs them does not invent a glyph.

$Script:WtIconModeNames = @('Auto', 'Unicode', 'NerdFont', 'ASCII', 'None')

# Display mode -> glyph set. Auto never resolves to NerdFont: font detection is not
# implemented, so a private-use glyph is only ever drawn when the user asked for it.
$Script:WtIconModeSets = [ordered]@{
    Auto     = 'Unicode'
    Unicode  = 'Unicode'
    NerdFont = 'NerdFont'
    ASCII    = 'ASCII'
    None     = 'None'
}

<#
.SYNOPSIS
    The semantic icon vocabulary: key -> glyph per icon set.
.DESCRIPTION
    Every entry also carries the style class its glyph is painted with, so the colour of
    an icon (blue for categories and actions, green for success, amber for warning and
    pending, red for failure, grey for inactive) is a property of the key, not of the
    call site.
#>
$Script:WtIconRegistry = [ordered]@{

    # --- categories ---------------------------------------------------------------
    'Category.Dashboard'      = @{ Style = 'IconCategory'; Unicode = '⌂'; NerdFont = [char]0xF015; ASCII = '[HOME]' }
    'Category.Hardware'       = @{ Style = 'IconCategory'; Unicode = '▣'; NerdFont = [char]0xF2DB; ASCII = '[HW]' }
    'Category.Privacy'        = @{ Style = 'IconCategory'; Unicode = '▪'; NerdFont = [char]0xF023; ASCII = '[PRIV]' }
    'Category.Desktop'        = @{ Style = 'IconCategory'; Unicode = '▭'; NerdFont = [char]0xF108; ASCII = '[DSK]' }
    'Category.FileExplorer'   = @{ Style = 'IconCategory'; Unicode = '▤'; NerdFont = [char]0xF07B; ASCII = '[FILE]' }
    'Category.Applications'   = @{ Style = 'IconCategory'; Unicode = '▦'; NerdFont = [char]0xF009; ASCII = '[APP]' }
    'Category.Startup'        = @{ Style = 'IconCategory'; Unicode = '▲'; NerdFont = [char]0xF135; ASCII = '[BOOT]' }
    'Category.Cleaning'       = @{ Style = 'IconCategory'; Unicode = '▫'; NerdFont = [char]0xF1F8; ASCII = '[CLN]' }
    'Category.Network'        = @{ Style = 'IconCategory'; Unicode = '○'; NerdFont = [char]0xF0AC; ASCII = '[NET]' }
    'Category.Security'       = @{ Style = 'IconCategory'; Unicode = '◆'; NerdFont = [char]0xF132; ASCII = '[SEC]' }
    'Category.WindowsUpdate'  = @{ Style = 'IconCategory'; Unicode = '⇩'; NerdFont = [char]0xF0ED; ASCII = '[UPD]' }
    'Category.Repairs'        = @{ Style = 'IconCategory'; Unicode = '▨'; NerdFont = [char]0xF0AD; ASCII = '[FIX]' }
    'Category.Drivers'        = @{ Style = 'IconCategory'; Unicode = '▧'; NerdFont = [char]0xF085; ASCII = '[DRV]' }
    'Category.Printers'       = @{ Style = 'IconCategory'; Unicode = '▥'; NerdFont = [char]0xF02F; ASCII = '[PRN]' }
    'Category.History'        = @{ Style = 'IconCategory'; Unicode = '↺'; NerdFont = [char]0xF1DA; ASCII = '[HIST]' }
    'Category.Settings'       = @{ Style = 'IconCategory'; Unicode = '⊞'; NerdFont = [char]0xF013; ASCII = '[SET]' }
    'Category.Help'           = @{ Style = 'IconCategory'; Unicode = 'ⓘ'; NerdFont = [char]0xF059; ASCII = '[HELP]' }

    # --- states -------------------------------------------------------------------
    'Status.Enabled'          = @{ Style = 'IconSuccess'; Unicode = '■'; NerdFont = [char]0xF00C; ASCII = '[ON]' }
    'Status.Disabled'         = @{ Style = 'IconInactive'; Unicode = '□'; NerdFont = [char]0xF068; ASCII = '[OFF]' }
    'Status.Pending'          = @{ Style = 'IconWarning'; Unicode = '∙'; NerdFont = [char]0xF017; ASCII = '[WAIT]' }
    'Status.Running'          = @{ Style = 'IconCategory'; Unicode = '▸'; NerdFont = [char]0xF04B; ASCII = '[RUN]' }
    'Status.Succeeded'        = @{ Style = 'IconSuccess'; Unicode = '✓'; NerdFont = [char]0xF058; ASCII = '[OK]' }
    'Status.Failed'           = @{ Style = 'IconError'; Unicode = '✗'; NerdFont = [char]0xF057; ASCII = '[ERR]' }
    'Status.Warning'          = @{ Style = 'IconWarning'; Unicode = '△'; NerdFont = [char]0xF071; ASCII = '[WARN]' }
    'Status.Unsupported'      = @{ Style = 'IconInactive'; Unicode = '∅'; NerdFont = [char]0xF05E; ASCII = '[N/A]' }
    'Status.Unknown'          = @{ Style = 'IconInactive'; Unicode = '?'; NerdFont = [char]0xF128; ASCII = '[??]' }
    'Status.AdminRequired'    = @{ Style = 'IconWarning'; Unicode = '#'; NerdFont = [char]0xF084; ASCII = '[ADMIN]' }
    'Status.RestartRequired'  = @{ Style = 'IconWarning'; Unicode = '↻'; NerdFont = [char]0xF01E; ASCII = '[RSTRT]' }
    'Status.Reversible'       = @{ Style = 'IconSuccess'; Unicode = '⇄'; NerdFont = [char]0xF0E2; ASCII = '[UNDO]' }

    # --- actions ------------------------------------------------------------------
    'Action.Search'           = @{ Style = 'IconCategory'; Unicode = '/'; NerdFont = [char]0xF002; ASCII = '[FIND]' }
    'Action.Refresh'          = @{ Style = 'IconCategory'; Unicode = '⟳'; NerdFont = [char]0xF021; ASCII = '[SYNC]' }
    'Action.Select'           = @{ Style = 'IconCategory'; Unicode = '+'; NerdFont = [char]0xF067; ASCII = '[SEL]' }
    'Action.Preview'          = @{ Style = 'IconCategory'; Unicode = '◎'; NerdFont = [char]0xF06E; ASCII = '[VIEW]' }
    'Action.Apply'            = @{ Style = 'IconCategory'; Unicode = '»'; NerdFont = [char]0xF14A; ASCII = '[GO]' }
    'Action.Restore'          = @{ Style = 'IconCategory'; Unicode = '↩'; NerdFont = [char]0xF112; ASCII = '[BACK]' }
    'Action.Import'           = @{ Style = 'IconCategory'; Unicode = '↓'; NerdFont = [char]0xF019; ASCII = '[IN]' }
    'Action.Export'           = @{ Style = 'IconCategory'; Unicode = '↑'; NerdFont = [char]0xF093; ASCII = '[OUT]' }
    'Action.Key'              = @{ Style = 'IconCategory'; Unicode = '⚿'; NerdFont = [char]0xF084; ASCII = '[KEY]' }
    'Action.Cancel'           = @{ Style = 'IconCategory'; Unicode = '⊘'; NerdFont = [char]0xF00D; ASCII = '[STOP]' }
    'Action.Quit'             = @{ Style = 'IconCategory'; Unicode = '×'; NerdFont = [char]0xF011; ASCII = '[EXIT]' }
}

# Every glyph of a set is padded to this many cells, so a column of icons never shifts
# the labels behind it. It is the measured width of the widest glyph in the set and is
# asserted by tests/Tui.Tests.ps1.
$Script:WtIconSlotWidths = [ordered]@{
    Unicode  = 1
    NerdFont = 1
    ASCII    = 7
    None     = 0
}

# Restrained progress bar: one fill and one empty glyph per set, one cell each. "None"
# carries no bar at all - the item counts stay as text.
$Script:WtIconBarGlyphs = @{
    Unicode  = @{ Fill = [char]0x2588; Empty = [char]0x2591 }
    NerdFont = @{ Fill = [char]0x2588; Empty = [char]0x2591 }
    ASCII    = @{ Fill = '#'; Empty = '-' }
    None     = $null
}

# Interface category (or catalog category) -> semantic icon key. Catalog names are the
# ones the tweak definitions use; interface names are the ten panes. A name that is not
# listed renders without an icon instead of guessing.
$Script:WtCategoryIconKeys = @{
    # interface categories
    'Overview'        = 'Category.Dashboard'
    'Privacy'         = 'Category.Privacy'
    'DesktopTaskbar'  = 'Category.Desktop'
    'FileExplorer'    = 'Category.FileExplorer'
    'Applications'    = 'Category.Applications'
    'System'          = 'Category.Settings'
    'Network'         = 'Category.Network'
    'Security'        = 'Category.Security'
    'WindowsUpdate'   = 'Category.WindowsUpdate'
    'History'         = 'Category.History'

    # catalog categories (-Category in the tweak definitions)
    'Taskbar'         = 'Category.Desktop'
    'Personalization' = 'Category.Desktop'
    'Explorer'        = 'Category.FileExplorer'
    'Apps'            = 'Category.Applications'
    'Updates'         = 'Category.WindowsUpdate'
    'Maintenance'     = 'Category.Cleaning'
    'StartMenu'       = 'Category.Startup'
}

# Detection state -> icon key. Unknown names resolve to Status.Unknown rather than
# silently disappearing.
$Script:WtStateIconKeys = @{
    'Enabled'      = 'Status.Enabled'
    'Disabled'     = 'Status.Disabled'
    'Pending'      = 'Status.Pending'
    'Running'      = 'Status.Running'
    'Succeeded'    = 'Status.Succeeded'
    'Failed'       = 'Status.Failed'
    'Warning'      = 'Status.Warning'
    'Unsupported'  = 'Status.Unsupported'
    'Unknown'      = 'Status.Unknown'
    'Installed'    = 'Status.Enabled'
    'NotPresent'   = 'Status.Disabled'
    'Mixed'        = 'Status.Warning'
    'Default'      = 'Status.Unknown'
    'None'         = 'Status.Unknown'
    'unchanged'    = 'Status.Succeeded'
    'skipped'      = 'Status.Pending'
    'dryrun'       = 'Action.Preview'
}

# Overview rows carry no tweak, so their icon comes from what the row is about.
$Script:WtActionIconKeys = @{
    'Environment' = 'Category.Hardware'
    'Presets'     = 'Action.Import'
    'DryRun'      = 'Action.Preview'
    'Icons'       = 'Category.Settings'
    'Language'    = 'Action.Select'
    'Verify'      = 'Action.Refresh'
    'DiskUsage'   = 'Category.Dashboard'
    'Quarantine'  = 'Action.Restore'
    'Monitor'      = 'Category.Dashboard'
    'Licensing'    = 'Action.Key'
}

<#
.SYNOPSIS
    Returns the semantic icon registry (key -> glyphs and style class).
#>
function Get-WtIconRegistry
{
    [CmdletBinding()]
    param ()

    return $Script:WtIconRegistry
}

<#
.SYNOPSIS
    Returns the supported -Icons values.
#>
function Get-WtIconMode
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return $Script:WtIconModeNames
}

<#
.SYNOPSIS
    Returns the icon set a display mode resolves to before terminal capabilities are
    taken into account.
#>
function Get-WtIconSetName
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][string]$Mode = 'Auto')

    if ($Script:WtIconModeSets.Contains($Mode))
    {
        return [string]$Script:WtIconModeSets[$Mode]
    }

    return 'None'
}

<#
.SYNOPSIS
    Picks the icon mode actually used, honouring the terminal and the user.
.DESCRIPTION
    Precedence: the -Ascii switch, then an explicit request, then the saved preference,
    then the conservative default. "Auto" is Unicode only when the output encoding is
    UTF-8; otherwise the readable ASCII tags are used, exactly as the frame falls back to
    ASCII box characters. NerdFont is never chosen automatically: no font detection is
    implemented, so a private-use glyph is only drawn when it was asked for. "None"
    always wins because it cannot break a layout at all.
.PARAMETER Requested
    Mode from the command line (Auto by default).
.PARAMETER Capability
    Result of Get-WtTuiCapability.
.PARAMETER Preference
    Mode saved by the user (Auto by default).
.PARAMETER Ascii
    The -Ascii switch: forces ASCII icons (and the ASCII frame, which the capability
    already reports).
#>
function Resolve-WtIconMode
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][string]$Requested = 'Auto',
        [Parameter(Mandatory = $false)][object]$Capability,
        [Parameter(Mandatory = $false)][string]$Preference = 'Auto',
        [Parameter(Mandatory = $false)][switch]$Ascii
    )

    $Mode = if ($Script:WtIconModeNames -contains $Requested) { $Requested } else { 'Auto' }

    if ($Mode -eq 'Auto')
    {
        $Mode = if ($Script:WtIconModeNames -contains $Preference -and $Preference -ne 'Auto') { $Preference } else { 'Unicode' }
    }

    if ($Mode -eq 'None')
    {
        return 'None'
    }

    $Unicode = $true
    if ($Capability -and $Capability.ContainsKey('Unicode'))
    {
        $Unicode = [bool]$Capability.Unicode
    }

    if ($Ascii -or -not $Unicode)
    {
        return 'ASCII'
    }

    return $Mode
}

<#
.SYNOPSIS
    Returns the saved TUI performance profile ('' when nothing valid is saved).
.DESCRIPTION
    The profile is a presentation preference, stored in the settings file like the icon
    mode; it is never a safety or recovery knob.
#>
function Get-WtTuiProfilePreference
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $SavedProfile = [string](Read-WtSettings).Profile
    foreach ($Name in Get-WtTuiProfiles)
    {
        if ([string]::Equals($Name, $SavedProfile, [System.StringComparison]::OrdinalIgnoreCase))
        {
            return $Name
        }
    }
    return ''
}

<#
.SYNOPSIS
    Persists the TUI performance profile preference.
#>
function Set-WtTuiProfilePreference
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Profile
    )

    $RequestedProfile = Resolve-WtTuiProfile -Requested $Profile
    $Settings = Read-WtSettings
    $Settings.Profile = $RequestedProfile

    if ($PSCmdlet.ShouldProcess($RequestedProfile, 'save the TUI performance profile'))
    {
        Write-WtSettings -Settings $Settings
    }

    return $RequestedProfile
}

<#
.SYNOPSIS
    Builds the resolved icon table the renderer carries in the theme.
.DESCRIPTION
    Returns Mode, Set, Slot (the measured icon column width) and Glyphs (semantic key ->
    the glyph of the active set; an unlisted key stays empty).
#>
function New-WtIconTable
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Mode = 'Auto')

    $Set = Get-WtIconSetName -Mode $Mode
    $Slot = if ($Script:WtIconSlotWidths.Contains($Set)) { [int]$Script:WtIconSlotWidths[$Set] } else { 0 }

    $Glyphs = @{}
    if ($Slot -gt 0)
    {
        foreach ($Entry in $Script:WtIconRegistry.GetEnumerator())
        {
            $Glyphs[$Entry.Key] = [string]$Entry.Value[$Set]
        }
    }

    return @{
        Mode   = $Mode
        Set    = $Set
        Slot   = $Slot
        Glyphs = $Glyphs
        Bar    = $(if ($Script:WtIconBarGlyphs.ContainsKey($Set)) { $Script:WtIconBarGlyphs[$Set] } else { $null })
    }
}

<#
.SYNOPSIS
    Returns the glyph for one semantic key ('' when the set has no icons or the key is
    unknown).
#>
function Get-WtIconGlyph
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Icons,
        [Parameter(Mandatory = $false)][string]$Key
    )

    if (-not $Icons -or [string]::IsNullOrEmpty($Key))
    {
        return ''
    }

    if ($Icons.Glyphs.ContainsKey($Key))
    {
        return [string]$Icons.Glyphs[$Key]
    }

    return ''
}

<#
.SYNOPSIS
    Returns the style an icon is painted with, for the surface it is painted on.
.DESCRIPTION
    A highlighted row paints its background with the Panel colour, so its icons need the
    Panel (or Focus) variant of the same semantic colour: otherwise the icon cell would
    punch a hole in the selection. The variant is picked from the row's own style name by
    Get-WtIconSurface, so a call site never has to know which styles are highlighted.
#>
function Get-WtIconStyleName
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Icons,
        [Parameter(Mandatory = $false)][string]$Key,
        [Parameter(Mandatory = $false)][ValidateSet('Row', 'Selected', 'Focused')][string]$Surface = 'Row'
    )

    $Base = 'IconCategory'
    if ($Key -and $Script:WtIconRegistry.Contains($Key))
    {
        $Base = [string]$Script:WtIconRegistry[$Key].Style
    }

    switch ($Surface)
    {
        'Selected' { return "${Base}Panel" }
        'Focused' { return "${Base}Focus" }
        default { return $Base }
    }
}

<#
.SYNOPSIS
    Maps the style of the row an icon sits in to the icon surface it must be painted
    with.
#>
function Get-WtIconSurface
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][string]$RowStyle = 'Item')

    switch ($RowStyle)
    {
        'Selected' { 'Selected' }
        'DialogSelected' { 'Selected' }
        'Focused' { 'Focused' }
        default { 'Row' }
    }
}

<#
.SYNOPSIS
    Returns the icon column width: the padded slot plus one separator cell, or zero when
    the set has no icons or the key has no glyph.
#>
function Get-WtIconPrefixWidth
{
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Icons,
        [Parameter(Mandatory = $false)][string]$Key
    )

    if (-not (Get-WtIconGlyph -Icons $Icons -Key $Key))
    {
        return 0
    }

    return ([int]$Icons.Slot + 1)
}

<#
.SYNOPSIS
    Returns the icon column width to use in a pane of the given width.
.DESCRIPTION
    One rule for every list row: the icon is only drawn when the pane keeps at least
    MinimumLabel cells for the rest of the row. A pane that cannot afford it draws none,
    so the icon never squeezes the label or the columns behind it; zero means "no icon
    column".
#>
function Get-WtIconColumnWidth
{
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Icons,
        [Parameter(Mandatory = $false)][string]$Key,
        [Parameter(Mandatory = $false)][int]$Width = 0,
        [Parameter(Mandatory = $false)][int]$MinimumLabel = 20
    )

    $IconWidth = Get-WtIconPrefixWidth -Icons $Icons -Key $Key
    if ($IconWidth -le 0 -or ($Width - $IconWidth) -lt $MinimumLabel)
    {
        return 0
    }

    return $IconWidth
}

<#
.SYNOPSIS
    Renders the icon column of a row: the glyph padded to the set's slot, then one
    separating cell. Returns '' when the key has no glyph in the active set.
.DESCRIPTION
    The padding is measured in terminal cells, never in characters, so a wide or
    combining glyph in a future set cannot shift the label behind it.
#>
function Format-WtIconPrefix
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Icons,
        [Parameter(Mandatory = $false)][string]$Key
    )

    $Glyph = Get-WtIconGlyph -Icons $Icons -Key $Key
    if (-not $Glyph)
    {
        return ''
    }

    $Pad = [int]$Icons.Slot - (Get-WtTextWidth -Text $Glyph)
    if ($Pad -lt 0) { $Pad = 0 }

    return ($Glyph + (' ' * ($Pad + 1)))
}

<#
.SYNOPSIS
    Renders an icon and its label as one string (used where a single style is painted,
    such as a panel title or a dialog list row).
#>
function Format-WtIconLabel
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Icons,
        [Parameter(Mandatory = $false)][string]$Key,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Label = ''
    )

    return ((Format-WtIconPrefix -Icons $Icons -Key $Key) + $Label)
}

<#
.SYNOPSIS
    Maps an interface or catalog category to its semantic icon key, or '' when the name
    is not part of the vocabulary.
#>
function Get-WtCategoryIconKey
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][string]$Category)

    if ($Category -and $Script:WtCategoryIconKeys.ContainsKey($Category))
    {
        return [string]$Script:WtCategoryIconKeys[$Category]
    }

    return ''
}

<#
.SYNOPSIS
    Maps a detection state, operation outcome or detail status to its semantic icon key.
#>
function Get-WtStateIconKey
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][string]$State)

    if ($State -and $Script:WtStateIconKeys.ContainsKey($State))
    {
        return [string]$Script:WtStateIconKeys[$State]
    }

    return 'Status.Unknown'
}

<#
.SYNOPSIS
    Maps an overview row action to its semantic icon key ('' when it has none).
#>
function Get-WtActionIconKey
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][string]$Action)

    if ($Action -and $Script:WtActionIconKeys.ContainsKey($Action))
    {
        return [string]$Script:WtActionIconKeys[$Action]
    }

    return ''
}

<#
.SYNOPSIS
    Maps a message tone (the style names the footer, dialogs and result panels already
    use) to a status icon key.
#>
function Get-WtToneIconKey
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][string]$Tone)

    switch ($Tone)
    {
        'StatusOk' { 'Status.Succeeded' }
        'Success' { 'Status.Succeeded' }
        'StatusWarn' { 'Status.Warning' }
        'Warning' { 'Status.Warning' }
        'Pending' { 'Status.Pending' }
        'StatusError' { 'Status.Failed' }
        'Error' { 'Status.Failed' }
        default { '' }
    }
}

<#
.SYNOPSIS
    Renders the restrained progress bar of the operation panel.
.DESCRIPTION
    The bar is derived from the completed *item counts* the worker reported - never from
    elapsed time - and is capped to a fixed number of cells, so it cannot imply a
    duration or a rate that is not known. An empty string means "this set has no bar"
    (the "None" mode) or "there is nothing to count".
#>
function Format-WtIconProgressBar
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Icons,
        [Parameter(Mandatory = $false)][int]$Done = 0,
        [Parameter(Mandatory = $false)][int]$Total = 0,
        [Parameter(Mandatory = $false)][int]$MaxCells = 20
    )

    $Bar = $null
    if ($Icons) { $Bar = $Icons.Bar }
    if (-not $Bar -or $Total -le 1 -or $MaxCells -lt 2)
    {
        return ''
    }

    $Cells = [math]::Min($MaxCells, $Total)
    if ($Done -lt 0) { $Done = 0 }
    if ($Done -gt $Total) { $Done = $Total }

    $Filled = [int][math]::Floor(($Done * $Cells) / $Total)
    $Fill = [string]$Bar.Fill
    $Empty = [string]$Bar.Empty

    return (($Fill * $Filled) + ($Empty * ($Cells - $Filled)))
}

<#
.SYNOPSIS
    Renders the icon preview used by the mode picker: the sample keys of one set, in
    order, as the interface would draw them.
.PARAMETER Keys
    Semantic keys to sample (categories, then states, then actions by default).
#>
function Format-WtIconSample
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $false)][object]$Icons,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Keys = @('Category.Network', 'Status.Warning')
    )

    $Parts = [System.Collections.Generic.List[string]]::new()
    foreach ($Key in $Keys)
    {
        $Glyph = Get-WtIconGlyph -Icons $Icons -Key $Key
        if ($Glyph) { $Parts.Add($Glyph) }
    }

    return ($Parts -join ' ')
}

# The keys the preview shows for every mode, in the order the vocabulary defines them.
$Script:WtIconPreviewKeys = @(
    'Category.Dashboard', 'Category.Network', 'Category.Security', 'Category.History',
    'Status.Enabled', 'Status.Disabled', 'Status.Pending', 'Status.Running', 'Status.Succeeded',
    'Status.Failed', 'Status.Warning', 'Status.Unsupported', 'Status.AdminRequired', 'Status.RestartRequired',
    'Action.Search', 'Action.Refresh', 'Action.Preview', 'Action.Apply', 'Action.Restore', 'Action.Cancel'
)

<#
.SYNOPSIS
    Returns the keys the icon preview shows.
#>
function Get-WtIconPreviewKey
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ()

    return $Script:WtIconPreviewKeys
}

<#
.SYNOPSIS
    Reads the saved icon preference from the settings store, validated against the
    supported modes. An unreadable or unknown value resolves to Auto.
#>
function Get-WtIconPreference
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $Mode = [string](Read-WtSettings).Icons
    if ($Mode -and $Script:WtIconModeNames -contains $Mode)
    {
        return $Mode
    }

    return 'Auto'
}

<#
.SYNOPSIS
    Persists the icon preference (the same store the interface reads at startup).
#>
function Set-WtIconPreference
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Auto', 'Unicode', 'NerdFont', 'ASCII', 'None')]
        [string]$Mode
    )

    $Settings = Read-WtSettings
    $Settings.Icons = $Mode

    if ($PSCmdlet.ShouldProcess($Mode, 'save the icon display mode'))
    {
        Write-WtSettings -Settings $Settings
    }

    return $Mode
}
