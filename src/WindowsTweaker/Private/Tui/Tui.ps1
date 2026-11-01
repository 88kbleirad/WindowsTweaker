# WindowsTweaker - terminal user interface.
#
# Design contract:
#   * Presentation only. The interface never writes to the registry, a service, a task,
#     DNS, a package or an installer; it calls the same public backend the CLI uses
#     (Get-WtTweakState, Invoke-WtTweak, Undo-WtTweak, Get-WtHistory, preset helpers).
#   * Selecting an item never changes the system. A change enters the pending set and is
#     only applied after the pending set has been reviewed and confirmed.
#   * One UI owner: rendering and terminal input stay in this runspace. Long operations
#     run in the worker runspace (Private/Tui/Worker.ps1) and report structured events.
#   * The terminal is always restored: alternate screen, cursor visibility, colour and
#     input state, on normal exit, on Ctrl+C and on an unexpected exception.

$Script:WtTuiCategoryDefinitions = @(
    @{ Key = 'Overview'; LabelKey = 'Cat.Overview'; Catalog = @(); Special = 'Overview' }
    @{ Key = 'Privacy'; LabelKey = 'Cat.Privacy'; Catalog = @('Privacy'); Special = $null }
    @{ Key = 'DesktopTaskbar'; LabelKey = 'Cat.DesktopTaskbar'; Catalog = @('Taskbar', 'Personalization'); Special = $null }
    @{ Key = 'FileExplorer'; LabelKey = 'Cat.FileExplorer'; Catalog = @('Explorer'); Special = $null }
    @{ Key = 'Applications'; LabelKey = 'Cat.Applications'; Catalog = @('Apps'); Special = $null }
    @{ Key = 'System'; LabelKey = 'Cat.System'; Catalog = @('System', 'Maintenance'); Special = $null }
    @{ Key = 'Network'; LabelKey = 'Cat.Network'; Catalog = @('Network'); Special = $null }
    @{ Key = 'Security'; LabelKey = 'Cat.Security'; Catalog = @('Security'); Special = $null }
    @{ Key = 'WindowsUpdate'; LabelKey = 'Cat.WindowsUpdate'; Catalog = @('Updates'); Special = $null }
    @{ Key = 'History'; LabelKey = 'Cat.History'; Catalog = @(); Special = 'History' }
)

<#
.SYNOPSIS
    Creates the interface state.
.DESCRIPTION
    Everything the renderer and the key handler need lives in this one hashtable, which
    keeps the frame a pure function of the state (and therefore testable).
#>
function New-WtTuiState
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][object]$Language,
        [Parameter(Mandatory = $false)][switch]$DryRun,
        [Parameter(Mandatory = $false)][ValidateSet('Auto', 'TrueColor', 'Ansi256', 'Ansi16', 'Mono')][string]$Colour = 'Auto',
        [Parameter(Mandatory = $false)][switch]$Ascii,
        [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Unicode', 'NerdFont', 'ASCII', 'None')][string]$Icons = 'Auto',
        [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Go', 'PowerShell')][string]$WorkerBackend = 'Auto',
        [Parameter(Mandatory = $false)][string]$Profile = '',
        [Parameter(Mandatory = $false)][scriptblock]$KeySource,
        [Parameter(Mandatory = $false)][scriptblock]$SizeSource,
        [Parameter(Mandatory = $false)][switch]$Silent
    )

    $Capability = Get-WtTuiCapability -Colour $Colour -Ascii:$Ascii

    # The icon mode is resolved once, from the terminal capability, the command line and
    # the saved preference; the theme carries the resulting glyph table so the painter
    # never has to work out which set is active.
    $IconMode = Resolve-WtIconMode -Requested $Icons -Capability $Capability -Preference (Get-WtIconPreference) -Ascii:$Ascii
    $Theme = New-WtTuiTheme -Colour $Capability.Colour -Unicode:$Capability.Unicode -IconMode $IconMode

    $Size = if ($SizeSource) { & $SizeSource } else { Get-WtConsoleSize }
    $Screen = New-WtScreen -Width $Size.Width -Height $Size.Height -Theme $Theme

    if ($Language)
    {
        Set-WtLanguage -Language $Language | Out-Null
    }

    # The performance profile is resolved once and read-only: it tunes presentation knobs
    # only. Auto picks Low-resource for a console without virtual terminal processing (the
    # classic Windows console path, which is measurably more expensive per frame).
    $EffectiveProfile = Get-WtTuiProfileEffective -Requested $Profile -Preference (Get-WtTuiProfilePreference) -UseVt ([bool]$Capability.VirtualTerminal)
    $ProfileKnobs = Get-WtTuiProfileKnobs -Profile $EffectiveProfile

    return @{
        Theme        = $Theme
        Capability   = $Capability
        Icons        = $Theme.Icons
        IconMode     = $IconMode
        IconRequested = $Icons
        WorkerBackend = $WorkerBackend
        Screen       = $Screen
        Size         = $Size
        UseVt        = [bool]$Capability.VirtualTerminal
        KeySource    = $KeySource
        SizeSource   = $SizeSource
        Silent       = [bool]$Silent
        Language     = Get-WtLanguage
        PerformanceProfile = $EffectiveProfile
        ProfileKnobs = $ProfileKnobs
        # The idle frame timeout honours the profile: a slow console gets fewer redraws
        # without delaying key feedback (the input poll stays independent).
        FrameTimeoutMs = [int]$ProfileKnobs.FrameTimeoutMs
        Environment  = $null
        Categories   = @()
        CategoryIndex = 0
        Focus        = 'List'
        States       = @()
        Items        = @()
        ItemIndex    = 0
        SelectedId   = $null
        Search       = ''
        SearchMode   = $false
        RecommendObjective = ''
        Pending      = [ordered]@{}
        DryRun       = [bool]$DryRun
        PresetName   = ''
        Status       = @{ Text = ''; Tone = 'StatusInfo' }
        Notice       = ''
        Overlay      = $null
        Worker       = $null
        Operation    = $null
        History      = @()
        Exit         = $false
        ExitPending  = $false
        EmptyFrames  = 0
        ForceRepaint = $true
        # Automatic restart for the current batch only: off at startup, spent by the batch
        # that used it, never written to the settings file.
        RestartRequested = $false
        # Drift/interrupted counts for the Overview pane are expensive (they read the
        # store), so they are cached and refreshed on a bounded cadence instead of being
        # recomputed on every key press while that pane is open.
        OverviewVerify = $null
    }
}

<#
.SYNOPSIS
    Sets the footer status line.
#>
function Set-WtTuiStatus
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory = $false)][string]$Tone = 'StatusInfo'
    )

    if ($State.Status.Text -eq $Text -and $State.Status.Tone -eq $Tone)
    {
        return
    }

    $State.Status = @{ Text = $Text; Tone = $Tone }
    $State.Screen.Dirty = $true
}

<#
.SYNOPSIS
    Recomputes the category list (labels and per-category item counts).
#>
function Update-WtTuiCategories
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Categories = [System.Collections.Generic.List[object]]::new()

    foreach ($Definition in $Script:WtTuiCategoryDefinitions)
    {
        $Count = 0
        if ($Definition.Special -eq 'Overview')
        {
            $Count = $State.States.Count
        }
        elseif ($Definition.Special -eq 'History')
        {
            $Count = $State.History.Count
        }
        else
        {
            $Count = @($State.States | Where-Object { $Definition.Catalog -contains $_.Category }).Count
        }

        $Categories.Add(@{
            Key      = $Definition.Key
            Label    = Get-WtString -Key $Definition.LabelKey
            Count    = $Count
            Special  = $Definition.Special
            Catalog  = $Definition.Catalog
        })
    }

    $State.Categories = $Categories.ToArray()
}

<#
.SYNOPSIS
    Reloads the tweak states and the history, keeping the selected row.
.DESCRIPTION
    Read-only: detection is the same call the CLI uses. The selection is restored by
    tweak id, so a refresh (or a resize, which repaints the same item list) never loses
    the user's place.
#>
function Sync-WtTuiCatalog
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][switch]$IncludeHistory
    )

    $State.States = @(Get-WtTweakState)
    $State.History = @(Get-WtHistory -Limit 100)
    $State.DimensionCache = @{}
    $State.OverviewVerify = $null
    Update-WtTuiCategories -State $State
    Update-WtTuiItems -State $State
    $State.Screen.Dirty = $true
}

<#
.SYNOPSIS
    Rebuilds the rows of the list pane for the active category and filter.
#>
function Update-WtTuiItems
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Category = $State.Categories[$State.CategoryIndex]
    $Items = [System.Collections.Generic.List[object]]::new()

    if (-not [string]::IsNullOrWhiteSpace($State.Search))
    {
        # A query that starts with '@' is a definition filter rather than a text search:
        # '@risk:High', '@lifecycle:Experimental', '@pack:', '@scope:Machine',
        # '@support:Unverified', '@evidence:ProviderTested' - comma separated for more than one.
        # It reuses the same filter vocabulary as the command line, so a filter means exactly
        # the same thing in both places.
        if ($State.Search.StartsWith('@'))
        {
            $Expressions = @($State.Search.Substring(1).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $States = @($State.States)
            $Rows = @($Script:WtCatalog.Values | ForEach-Object { Get-WtDefinitionRowInternal -Tweak $_ })
            $Selected = Select-WtDefinitionRowInternal -Rows $Rows -Filter $Expressions

            if (@($Selected.Unknown).Count -gt 0)
            {
                # The list keeps its empty state; the status line explains why it is empty, so a
                # typo in a filter is visible instead of looking like "no matches".
                Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Cat.FilterUnknown' -Arguments @(($Selected.Unknown -join ', ')))
            }
            else
            {
                $Ids = @($Selected.Rows | ForEach-Object { $_.Id })
                foreach ($Entry in @($States | Where-Object { $Ids -contains $_.Id }))
                {
                    $Items.Add(@{ Kind = 'Tweak'; State = $Entry })
                }
            }
        }
        else
        {
            # A text filter always searches the whole catalog, whichever category is selected,
            # so the interface never looks like the filter was ignored (the overview and the
            # history panes do not contain tweaks).
            $States = @($State.States | Where-Object {
                $_.Id -like "*$($State.Search)*" -or
                $_.Name -like "*$($State.Search)*" -or
                $_.Description -like "*$($State.Search)*"
            })

            foreach ($Entry in $States)
            {
                $Items.Add(@{ Kind = 'Tweak'; State = $Entry })
            }
        }
    }
    elseif ($Category.Special -eq 'Overview')
    {
        $Items.AddRange(@(Get-WtTuiOverviewItems -State $State))
    }
    elseif ($Category.Special -eq 'History')
    {
        foreach ($Entry in $State.History)
        {
            $Items.Add(@{ Kind = 'History'; Entry = $Entry })
        }
    }
    else
    {
        foreach ($Entry in @($State.States | Where-Object { $Category.Catalog -contains $_.Category }))
        {
            $Items.Add(@{ Kind = 'Tweak'; State = $Entry })
        }
    }

    $State.Items = $Items.ToArray()

    # Restore the cursor: by id when a tweak was selected, otherwise clamp the index.
    $Index = -1
    if ($State.SelectedId)
    {
        for ($Position = 0; $Position -lt $State.Items.Count; $Position++)
        {
            $Item = $State.Items[$Position]
            if ($Item.Kind -eq 'Tweak' -and $Item.State.Id -eq $State.SelectedId)
            {
                $Index = $Position
                break
            }
        }
    }

    if ($Index -lt 0)
    {
        $Index = [math]::Min($State.ItemIndex, [math]::Max(0, $State.Items.Count - 1))
    }

    Set-WtTuiItemIndex -State $State -Index $Index
}

<#
.SYNOPSIS
    Sets the cursor position, keeping the selected tweak id in sync and the cursor inside
    the list.
#>
function Set-WtTuiItemIndex
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $Count = $State.Items.Count
    if ($Count -eq 0)
    {
        $State.ItemIndex = 0
        $State.SelectedId = $null
        $State.Screen.Dirty = $true
        return
    }

    if ($Index -lt 0) { $Index = 0 }
    if ($Index -ge $Count) { $Index = $Count - 1 }

    if ($Index -eq $State.ItemIndex)
    {
        # The visible row did not change (for example an arrow press at the edge of the
        # list): nothing has to be repainted, and the keyboard must not feel delayed by a
        # redundant frame.
        return
    }

    $State.ItemIndex = $Index

    $Item = $State.Items[$Index]
    if ($Item.Kind -eq 'Tweak')
    {
        $State.SelectedId = $Item.State.Id
    }

    $State.Screen.Dirty = $true
}

<#
.SYNOPSIS
    Returns the rows of the Overview category.
.DESCRIPTION
    The overview is a read-only summary of the environment, the catalog and the session;
    nothing here changes state.
#>
function Get-WtTuiOverviewItems
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Environment = $State.Environment
    $Supported = @($State.States | Where-Object { $_.Supported }).Count
    $Managed = @($State.States | Where-Object { $_.Managed }).Count
    $Irreversible = @($State.States | Where-Object { $_.Irreversible }).Count
    $Protection = @($State.States | Where-Object { $_.ReducesProtection }).Count
    $Pending = $State.Pending.Count

    $Items = [System.Collections.Generic.List[object]]::new()

    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Windows'); Value = "$($Environment.OSName) ($($Environment.OSVersionKey) build $($Environment.OSBuild).$($Environment.OSUBR))"; Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.PowerShell'); Value = "$($Environment.PowerShell) / required $($Environment.RequiredPowerShell)"; Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Privilege'); Value = $(if ($Environment.IsAdmin) { Get-WtString -Key 'Tui.Header.Admin' } else { Get-WtString -Key 'Tui.Header.Standard' }); Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.LanguageMode'); Value = [string]$Environment.LanguageMode; Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Reboot'); Value = (Get-WtPendingRestartValueLabelInternal -Pending (Get-WtEnvironmentPendingRestartInternal -Environment $Environment)); Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Catalog'); Value = (Get-WtString -Key 'Tui.Overview.Supported' -Arguments @($Supported, $State.States.Count)); Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Managed'); Value = [string]$Managed; Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Irreversible'); Value = [string]$Irreversible; Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Protection'); Value = [string]$Protection; Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Pending'); Value = [string]$Pending; Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Preset'); Value = $(if ($State.PresetName) { $State.PresetName } else { Get-WtString -Key 'Tui.Header.NoPreset' }); Action = 'Presets' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.DryRun'); Value = $(if ($State.DryRun) { Get-WtString -Key 'Tui.Header.DryRun' } else { Get-WtString -Key 'Tui.Header.Live' }); Action = 'DryRun' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.Icons'); Value = $State.IconMode; Action = 'Icons' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Cli.Language'); Value = (Get-WtString -Key "Tui.Language.$($State.Language)"); Action = 'Language' })
    $Drifted = 0
    $Interrupted = 0
    if (-not $State.OverviewVerify -or (([datetime]::UtcNow - $State.OverviewVerify.Utc).TotalSeconds -ge 5))
    {
        try { $Drifted = @(Get-WtDriftInternal -OnlyDrifted).Count } catch { $Drifted = 0 }
        try { $Interrupted = @(Get-WtInterruptedOperationInternal).Count } catch { $Interrupted = 0 }
        $State.OverviewVerify = @{ Utc = [datetime]::UtcNow; Drifted = $Drifted; Interrupted = $Interrupted }
    }
    else
    {
        # The figures from the last refresh are shown as they were measured: the cache is
        # invalidated by every catalog refresh, so it cannot outlive a re-scan.
        $Drifted = [int]$State.OverviewVerify.Drifted
        $Interrupted = [int]$State.OverviewVerify.Interrupted
    }

    $Items.Add(@{
            Kind   = 'Info'
            Label  = (Get-WtString -Key 'Tui.Overview.Verify')
            Value  = (Get-WtString -Key 'Tui.Overview.VerifyValue' -Arguments @($Drifted, $Interrupted))
            Action = 'Verify'
        })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.StatePath'); Value = $Environment.StatePath; Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Tui.Overview.LogPath'); Value = $Environment.LogPath; Action = 'Environment' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Disk.Title'); Value = ''; Action = 'DiskUsage' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Quar.Title'); Value = ''; Action = 'Quarantine' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Mon.Title'); Value = ''; Action = 'Monitor' })
    $Items.Add(@{ Kind = 'Info'; Label = (Get-WtString -Key 'Lic.Title'); Value = ''; Action = 'Licensing' })

    return $Items.ToArray()
}

<#
.SYNOPSIS
    Computes the pane geometry for the current terminal size.
.DESCRIPTION
    Three layouts exist so the interface stays usable at every size:
      Wide    - categories, list and details side by side
      Medium  - categories and list; details are shown on demand
      Compact - one pane at a time with a category tab strip
#>
function Get-WtTuiLayout
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Width = $State.Screen.Width
    $Height = $State.Screen.Height

    $Mode = if ($Width -ge 92 -and $Height -ge 18)
    {
        'Wide'
    }
    elseif ($Width -ge 58 -and $Height -ge 12)
    {
        'Medium'
    }
    else
    {
        'Compact'
    }

    $HeaderRows = if ($Height -ge 18) { 2 } else { 1 }
    $FooterRows = if ($Height -ge 12) { 2 } else { 1 }

    $Top = $HeaderRows + 2
    $Bottom = [math]::Max($Top + 2, $Height - $FooterRows - 1)

    $Layout = @{
        Mode       = $Mode
        HeaderRows = $HeaderRows
        FooterRows = $FooterRows
        Top        = [int]$Top
        Bottom     = [int]$Bottom
        Height     = [int]($Bottom - $Top + 1)
        Divider1   = 0
        Divider2   = 0
        PaneWidth  = @{ Categories = 0; List = 0; Details = 0 }
    }

    switch ($Mode)
    {
        'Wide'
        {
            # Columns: border | categories | divider | list | divider | details | border
            $Categories = [math]::Max(16, [math]::Min(24, [int]($Width / 5)))
            $Details = [math]::Max(30, [math]::Min(46, $Width - 60))
            $List = $Width - 4 - $Categories - $Details

            $Layout.Divider1 = $Categories + 2
            $Layout.Divider2 = $Layout.Divider1 + $List + 1
            $Layout.PaneWidth.Categories = $Categories
            $Layout.PaneWidth.List = $List
            $Layout.PaneWidth.Details = [int]($Width - $Layout.Divider2 - 1)
        }
        'Medium'
        {
            $Categories = [math]::Max(14, [math]::Min(20, [int]($Width / 4)))
            $List = $Width - $Categories - 3

            $Layout.Divider1 = $Categories + 2
            $Layout.Divider2 = 0
            $Layout.PaneWidth.Categories = $Categories
            $Layout.PaneWidth.List = $List
        }
        default
        {
            $Layout.PaneWidth.List = $Width - 2
        }
    }

    return $Layout
}

#region Painting

<#
.SYNOPSIS
    Draws the panel frame (outer border, internal dividers and pane titles).
#>
function Add-WtTuiFrame
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Layout
    )

    $Screen = $State.Screen
    $Glyph = $State.Theme.Border
    $Top = $Layout.Top
    $Bottom = $Layout.Bottom
    $Width = $Screen.Width

    $Titles = @{
        Categories = Get-WtString -Key 'Tui.Pane.Categories'
        List       = Get-WtString -Key 'Tui.Pane.Tweaks'
        Details    = Get-WtString -Key 'Tui.Pane.Details'
    }

    if ($Layout.Mode -eq 'Compact')
    {
        $Titles.List = $State.Categories[$State.CategoryIndex].Label
    }

    # Horizontal rules above and below the panes, with junctions at the dividers.
    foreach ($Edge in @(@{ Row = $Top - 1 }, @{ Row = $Bottom + 1 }))
    {
        Add-WtScreenDivider -Screen $Screen -Row $Edge.Row -Column 2 -Width ($Width - 2) -GlyphName 'Horizontal' -Style 'Border'
        Set-WtScreenText -Screen $Screen -Row $Edge.Row -Column 1 -Text ([string]$Glyph.TeeLeft) -Style 'Border'
        Set-WtScreenText -Screen $Screen -Row $Edge.Row -Column $Width -Text ([string]$Glyph.TeeRight) -Style 'Border'
    }

    Add-WtScreenDivider -Screen $Screen -Row $Top -Column 2 -Width ($Width - 2) -GlyphName 'Horizontal' -Style 'Border'
    Add-WtScreenDivider -Screen $Screen -Row $Bottom -Column 2 -Width ($Width - 2) -GlyphName 'Horizontal' -Style 'Border'
    Set-WtScreenText -Screen $Screen -Row $Top -Column 1 -Text ([string]$Glyph.TopLeft) -Style 'Border'
    Set-WtScreenText -Screen $Screen -Row $Top -Column $Width -Text ([string]$Glyph.TopRight) -Style 'Border'
    Set-WtScreenText -Screen $Screen -Row $Bottom -Column 1 -Text ([string]$Glyph.BottomLeft) -Style 'Border'
    Set-WtScreenText -Screen $Screen -Row $Bottom -Column $Width -Text ([string]$Glyph.BottomRight) -Style 'Border'

    if ($Layout.Mode -eq 'Compact')
    {
        # Only the interior rows carry side borders: the top and bottom rows are the
        # frame's own horizontal borders and must keep their corner glyphs.
        for ($Row = ($Top + 1); $Row -lt $Bottom; $Row++)
        {
            Set-WtScreenText -Screen $Screen -Row $Row -Column 1 -Text ([string]$Glyph.Vertical) -Style 'Border'
            Set-WtScreenText -Screen $Screen -Row $Row -Column $Width -Text ([string]$Glyph.Vertical) -Style 'Border'
        }

        $Label = " $($Titles.List) "
        Set-WtScreenText -Screen $Screen -Row $Top -Column 2 -Text $Label -Style 'PanelTitle'
        return
    }

    $Dividers = @($Layout.Divider1)
    if ($Layout.Divider2 -gt 0)
    {
        $Dividers += $Layout.Divider2
    }

    foreach ($Column in $Dividers)
    {
        Set-WtScreenText -Screen $Screen -Row ($Top - 1) -Column $Column -Text ([string]$Glyph.TeeTop) -Style 'Border'
        Set-WtScreenText -Screen $Screen -Row $Top -Column $Column -Text ([string]$Glyph.TeeTop) -Style 'Border'
        Set-WtScreenText -Screen $Screen -Row $Bottom -Column $Column -Text ([string]$Glyph.TeeBottom) -Style 'Border'
        Set-WtScreenText -Screen $Screen -Row ($Bottom + 1) -Column $Column -Text ([string]$Glyph.TeeBottom) -Style 'Border'

        for ($Row = ($Top + 1); $Row -lt $Bottom; $Row++)
        {
            Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text ([string]$Glyph.Vertical) -Style 'Border'
        }
    }

    Set-WtScreenText -Screen $Screen -Row $Top -Column 2 -Text " $($Titles.Categories) " -Style $(if ($State.Focus -eq 'Categories') { 'PanelTitle' } else { 'PanelTitleIdle' })

    $ListColumn = $Layout.Divider1 + 1
    Set-WtScreenText -Screen $Screen -Row $Top -Column $ListColumn -Text " $($Titles.List) " -Style $(if ($State.Focus -eq 'List') { 'PanelTitle' } else { 'PanelTitleIdle' })

    if ($Layout.Divider2 -gt 0)
    {
        Set-WtScreenText -Screen $Screen -Row $Top -Column ($Layout.Divider2 + 1) -Text " $($Titles.Details) " -Style $(if ($State.Focus -eq 'Details') { 'PanelTitle' } else { 'PanelTitleIdle' })
    }
}

<#
.SYNOPSIS
    Paints the header: application name, Windows version, PowerShell version, privilege
    level and the active preset.
#>
function Add-WtTuiHeader
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Layout
    )

    $Screen = $State.Screen
    $Environment = $State.Environment
    $Width = $Screen.Width

    Set-WtScreenRegion -Screen $Screen -Row 1 -Column 1 -Width $Width -Height $Layout.HeaderRows -Style 'Header'

    $Brand = Get-WtString -Key 'Tui.Brand'
    Set-WtScreenIconText -Screen $Screen -Row 1 -Column 2 -IconKey 'Category.Settings' -Text $Brand -Style 'Title'
    $BrandWidth = (Get-WtIconPrefixWidth -Icons $State.Icons -Key 'Category.Settings') + (Get-WtTextWidth -Text $Brand)

    $Preset = if ($State.PresetName) { $State.PresetName } else { Get-WtString -Key 'Tui.Header.NoPreset' }
    $PresetText = Get-WtString -Key 'Tui.Header.Preset' -Arguments @($Preset)
    $PresetColumn = [math]::Max(($BrandWidth + 4), $Width - (Get-WtTextWidth -Text $PresetText) - 3)
    Set-WtScreenText -Screen $Screen -Row 1 -Column $PresetColumn -Text $PresetText -Style 'HeaderMeta' -MaxWidth ([math]::Max(0, $Width - $PresetColumn - 1))

    $Privilege = if ($Environment.IsAdmin) { Get-WtString -Key 'Tui.Header.Admin' } else { Get-WtString -Key 'Tui.Header.Standard' }
    $Mode = if ($State.DryRun) { Get-WtString -Key 'Tui.Header.DryRun' } else { Get-WtString -Key 'Tui.Header.Live' }

    if ($Layout.HeaderRows -ge 2)
    {
        $Meta = Get-WtString -Key 'Tui.Header.Meta' -Arguments @(
            $Environment.OSVersionKey,
            $Environment.OSBuild,
            $Environment.PowerShell,
            $Privilege,
            $Mode,
            $State.Language.ToUpperInvariant())
        Set-WtScreenText -Screen $Screen -Row 2 -Column 2 -Text $Meta -Style 'HeaderMeta' -MaxWidth ($Width - 3)

        if ($State.Notice)
        {
            # The header paints the Surface background, so the notice icon is composed
            # into the string and takes the notice's own colour instead of an icon style.
            $NoticeText = Format-WtIconLabel -Icons $State.Icons -Key 'Status.Warning' -Label $State.Notice
            $NoticeWidth = (Get-WtIconPrefixWidth -Icons $State.Icons -Key 'Status.Warning') + (Get-WtTextWidth -Text $State.Notice)
            $NoticeColumn = [math]::Max(2, $Width - $NoticeWidth - 3)
            if ($NoticeColumn -gt (Get-WtTextWidth -Text $Meta) + 4)
            {
                Set-WtScreenText -Screen $Screen -Row 2 -Column $NoticeColumn -Text $NoticeText -Style 'StatusWarn' -MaxWidth ([math]::Max(0, $Width - $NoticeColumn - 1))
            }
        }
        return
    }

    $Compact = Get-WtString -Key 'Tui.Header.Compact' -Arguments @($Environment.OSVersionKey, $Privilege, $Mode)
    $Column = 3 + $BrandWidth
    Set-WtScreenText -Screen $Screen -Row 1 -Column $Column -Text $Compact -Style 'HeaderMeta' -MaxWidth ([math]::Max(0, $Width - $Column - 1))
}

<#
.SYNOPSIS
    Paints the category pane (or the tab strip in compact mode).
#>
function Add-WtTuiCategories
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Layout
    )

    $Screen = $State.Screen

    if ($Layout.Mode -eq 'Compact')
    {
        # A tab strip: the active category stays visible, the rest is truncated. Icons
        # are part of the tab, so the strip is composed from measured parts and the
        # scroll offset is computed from the same cell widths.
        $Parts = [System.Collections.Generic.List[object]]::new()
        $Active = 0
        $Widths = [System.Collections.Generic.List[int]]::new()

        foreach ($Category in $State.Categories)
        {
            $IsActive = ($Category.Key -eq $State.Categories[$State.CategoryIndex].Key)
            $Label = if ($IsActive) { "[$($Category.Label)]" } else { $Category.Label }
            $Part = Format-WtIconLabel -Icons $State.Icons -Key (Get-WtCategoryIconKey -Category $Category.Key) -Label $Label

            if ($IsActive -and $State.Focus -eq 'Categories')
            {
                $Active = ($Widths | Measure-Object -Sum).Sum
            }

            $Parts.Add($Part)
            $Widths.Add((Get-WtTextWidth -Text $Part) + 3)
        }

        $Text = ' ' + ($Parts -join ' | ')
        $Start = 0
        if ($State.Focus -eq 'Categories' -and $Active -gt ($Screen.Width - 12))
        {
            $Start = $Active - [math]::Floor(($Screen.Width - 12) / 2)
        }

        $Visible = if ($Start -gt 0) { $Text.Substring([math]::Min($Start, $Text.Length)) } else { $Text }
        Set-WtScreenText -Screen $Screen -Row ($Layout.Top + 1) -Column 2 -Text (Format-WtText -Text $Visible -Width ($Screen.Width - 3)) `
            -Style $(if ($State.Focus -eq 'Categories') { 'Focused' } else { 'ItemMeta' }) -MaxWidth ($Screen.Width - 3)
        return
    }

    $Column = 2
    $Width = $Layout.PaneWidth.Categories
    $Row = $Layout.Top + 1
    $Bottom = $Layout.Bottom

    # The icon column and the count column are decided once for the whole pane, so the
    # rows of a category list never look ragged (the widest count is the one worth
    # reserving: [113] is wider than [9]).
    $CountWidth = 0
    foreach ($Category in $State.Categories)
    {
        $CountWidth = [math]::Max($CountWidth, (Get-WtTextWidth -Text "[$($Category.Count)]"))
    }

    $IconWidth = Get-WtIconPrefixWidth -Icons $State.Icons -Key 'Category.Dashboard'
    if (($Width - $IconWidth - $CountWidth - 2) -lt 6)
    {
        # Icons are dropped before the label is squeezed: the count and a readable label
        # matter more than the icon on a narrow pane.
        $IconWidth = 0
    }

    for ($Index = 0; $Index -lt $State.Categories.Count; $Index++)
    {
        if ($Row -gt $Bottom) { break }

        $Category = $State.Categories[$Index]
        $IsCursor = ($Index -eq $State.CategoryIndex)
        $Style = if ($IsCursor -and $State.Focus -eq 'Categories') { 'Focused' } elseif ($IsCursor) { 'Selected' } else { 'Item' }

        $Count = "[$($Category.Count)]"
        $RowCountWidth = (Get-WtTextWidth -Text $Count)
        $IconKey = if ($IconWidth -gt 0) { Get-WtCategoryIconKey -Category $Category.Key } else { '' }

        $LabelWidth = [math]::Max(4, $Width - $IconWidth - $CountWidth - 2)
        $Label = Format-WtText -Text $Category.Label -Width $LabelWidth
        Set-WtScreenRegion -Screen $Screen -Row $Row -Column $Column -Width $Width -Height 1 -Style $Style
        Set-WtScreenIconText -Screen $Screen -Row $Row -Column $Column -Width ($IconWidth + $LabelWidth) -IconKey $IconKey -Text $Label `
            -Style $Style -Surface (Get-WtIconSurface -RowStyle $Style)
        Set-WtScreenText -Screen $Screen -Row $Row -Column ($Column + $Width - $RowCountWidth) -Text $Count -Style $Style -MaxWidth $RowCountWidth

        $Row++
    }
}

<#
.SYNOPSIS
    Composes the fixed columns of a tweak row for the available width.
.DESCRIPTION
    Columns are dropped from the least important side when the pane is narrow, so a
    narrow terminal shows fewer fields instead of a broken layout.
#>
function Format-WtTweakRow
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $false)][bool]$IsCursor = $false,
        [Parameter(Mandatory = $false)][int]$IconWidth = 0
    )

    $Pending = $State.Pending.Contains($Entry.Id)
    $Target = if ($Pending) { [string]($State.Pending[$Entry.Id]).Target } else { '' }

    # Three marker columns so the state of a row is readable without colour or icons:
    #   > cursor   * pending change   ! unsupported   M managed by policy
    #   R irreversible   D deletes user data
    $CursorMark = if ($IsCursor) { '>' } else { ' ' }
    $PendingMark = if ($Pending) { '*' } else { ' ' }
    $FlagMark = if (-not $Entry.Supported) { '!' }
    elseif ($Entry.Managed) { 'M' }
    elseif ($Entry.Irreversible) { 'R' }
    elseif ($Entry.DataDeletion) { 'D' }
    else { ' ' }
    $Markers = "$CursorMark$PendingMark$FlagMark"

    $Impact = switch ($Entry.Risk)
    {
        'High' { Get-WtString -Key 'Tui.Impact.High' }
        'Medium' { Get-WtString -Key 'Tui.Impact.Medium' }
        default { Get-WtString -Key 'Tui.Impact.Low' }
    }

    $ShowState = $Width -ge 30
    $ShowTarget = $Width -ge 40
    $ShowImpact = $Width -ge 50

    # The icon cells are reserved inside the row (and painted over by the caller), so the
    # row keeps its exact width and the state/target/impact columns never move.
    $Used = 4 + $IconWidth
    $StateWidth = 0
    $TargetWidth = 0
    $ImpactWidth = 0

    if ($ShowState) { $StateWidth = 10; $Used += $StateWidth + 1 }
    if ($ShowTarget) { $TargetWidth = 14; $Used += $TargetWidth + 1 }
    if ($ShowImpact) { $ImpactWidth = 6; $Used += $ImpactWidth + 1 }

    # The name must never be squeezed below 8 cells; if the fixed columns do not fit,
    # drop them in the order that hurts least (impact, then target, then state).
    while (($Width - $Used) -lt 8 -and ($ShowState -or $ShowTarget -or $ShowImpact))
    {
        if ($ShowImpact) { $ShowImpact = $false; $Used -= $ImpactWidth + 1; $ImpactWidth = 0 }
        elseif ($ShowTarget) { $ShowTarget = $false; $Used -= $TargetWidth + 1; $TargetWidth = 0 }
        elseif ($ShowState) { $ShowState = $false; $Used -= $StateWidth + 1; $StateWidth = 0 }
    }

    $NameWidth = [math]::Max(6, $Width - $Used)

    $Line = "$Markers " + (' ' * $IconWidth) + (Format-WtColumn -Text $Entry.Name -Width $NameWidth)

    if ($ShowState)
    {
        $StateLabel = if ($Entry.Supported) { Get-WtTuiStateLabel -Name $Entry.State } else { Get-WtString -Key 'Status.Unsupported' }
        $Line += ' ' + (Format-WtColumn -Text $StateLabel -Width $StateWidth -Align Right)
    }

    if ($ShowTarget)
    {
        $Line += ' ' + (Format-WtColumn -Text $Target -Width $TargetWidth -Align Right)
    }

    if ($ShowImpact)
    {
        $Line += ' ' + (Format-WtColumn -Text $Impact -Width $ImpactWidth -Align Right)
    }

    return $Line
}

<#
.SYNOPSIS
    Paints the main list pane.
#>
function Add-WtTuiList
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Layout
    )

    $Screen = $State.Screen
    $Column = if ($Layout.Mode -eq 'Compact') { 2 } else { $Layout.Divider1 + 1 }
    $Width = if ($Layout.Mode -eq 'Compact') { $Screen.Width - 3 } else { $Layout.PaneWidth.List }
    $Top = if ($Layout.Mode -eq 'Compact') { $Layout.Top + 2 } else { $Layout.Top + 1 }
    # The pane's own border row is the last usable row of the pane, and the frame's
    # bottom border sits below it, so content stops one row earlier.
    $Bottom = $Layout.Bottom - 1

    $Rows = $Bottom - $Top + 1
    if ($Rows -le 0)
    {
        return
    }

    if ($State.Items.Count -eq 0)
    {
        $Message = if ($State.Search) { Get-WtString -Key 'Tui.NoMatch' } else { Get-WtString -Key 'Tui.NoItems' }
        Set-WtScreenText -Screen $Screen -Row $Top -Column $Column -Text $Message -Style 'Muted' -MaxWidth $Width
        return
    }

    # Scroll so the cursor is always visible; the offset is recomputed from the cursor
    # on every frame, so a resize cannot leave the list scrolled past its own end.
    $Offset = 0
    if ($State.ItemIndex -ge $Rows)
    {
        $Offset = $State.ItemIndex - $Rows + 1
    }
    $Offset = [math]::Max(0, [math]::Min($Offset, [math]::Max(0, $State.Items.Count - $Rows)))

    $Filters = @($State.Pending.Keys)
    $Row = $Top

    for ($Index = $Offset; $Index -lt $State.Items.Count; $Index++)
    {
        if ($Row -gt $Bottom) { break }

        $Item = $State.Items[$Index]
        $IsCursor = ($Index -eq $State.ItemIndex)
        $Style = if ($IsCursor) { if ($State.Focus -eq 'List') { 'Focused' } else { 'Selected' } } else { 'Item' }

        if ($Item.Kind -eq 'Tweak')
        {
            $Pending = $State.Pending.Contains($Item.State.Id)
            if ($Pending -and -not $IsCursor -and $State.Focus -eq 'List')
            {
                $Style = 'Pending'
            }

            # Row icons are a detail-density knob: Low-resource drops them (the markers and
            # text columns stay, so a row never becomes unreadable).
            $IconKey = if ($State.ProfileKnobs.ShowRowIcons) { Get-WtCategoryIconKey -Category $Item.State.Category } else { '' }
            $IconWidth = if ($IconKey) { Get-WtIconColumnWidth -Icons $State.Icons -Key $IconKey -Width $Width } else { 0 }
            if ($IconWidth -le 0) { $IconKey = '' }

            Set-WtScreenRegion -Screen $Screen -Row $Row -Column $Column -Width $Width -Height 1 -Style $Style
            $Line = Format-WtTweakRow -State $State -Entry $Item.State -Width $Width -IsCursor $IsCursor -IconWidth $IconWidth
            Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text $Line -Style $Style -MaxWidth $Width

            if ($IconWidth -gt 0)
            {
                Set-WtScreenText -Screen $Screen -Row $Row -Column ($Column + 4) -Text (Format-WtIconPrefix -Icons $State.Icons -Key $IconKey) `
                    -Style (Get-WtIconStyleName -Icons $State.Icons -Key $IconKey -Surface (Get-WtIconSurface -RowStyle $Style)) -MaxWidth $IconWidth
            }
        }
        elseif ($Item.Kind -eq 'History')
        {
            $Entry = $Item.Entry
            Set-WtScreenRegion -Screen $Screen -Row $Row -Column $Column -Width $Width -Height 1 -Style $Style
            $Marker = $Entry.TweakId
            $Outcome = Get-WtString -Key "Op.$($Entry.Outcome)"
            $Right = if ($Entry.RolledBack) { Get-WtString -Key 'Tui.History.RolledBack' } else { $Outcome }
            $IconKey = Get-WtStateIconKey -State $(if ($Entry.RolledBack) { 'Reversible' } else { $Entry.Outcome })
            $IconWidth = Get-WtIconColumnWidth -Icons $State.Icons -Key $IconKey -Width $Width
            if ($IconWidth -le 0) { $IconKey = '' }

            $Text = Format-WtColumn -Text $Marker -Width ([math]::Max(8, $Width - 14 - $IconWidth))
            $Text += ' ' + (Format-WtColumn -Text $Right -Width 12 -Align Right)
            Set-WtScreenIconText -Screen $Screen -Row $Row -Column $Column -Width $Width -IconKey $IconKey -Text $Text `
                -Style $Style -Surface (Get-WtIconSurface -RowStyle $Style)
        }
        else
        {
            Set-WtScreenRegion -Screen $Screen -Row $Row -Column $Column -Width $Width -Height 1 -Style $Style
            $IconKey = Get-WtActionIconKey -Action $Item.Action
            $IconWidth = Get-WtIconColumnWidth -Icons $State.Icons -Key $IconKey -Width $Width
            if ($IconWidth -le 0) { $IconKey = '' }

            $LabelWidth = [math]::Max(8, [int](($Width - $IconWidth) / 2))
            $Label = Format-WtColumn -Text $Item.Label -Width $LabelWidth
            $Value = Format-WtText -Text ([string]$Item.Value) -Width ([math]::Max(6, $Width - $IconWidth - $LabelWidth - 1))
            Set-WtScreenIconText -Screen $Screen -Row $Row -Column $Column -Width $Width -IconKey $IconKey -Text "$Label $Value" `
                -Style $Style -Surface (Get-WtIconSurface -RowStyle $Style)
        }

        $Row++
    }

    if ($Filters.Count -gt 0 -and $Layout.Mode -ne 'Compact' -and ($Bottom - $Row) -ge 1)
    {
        Set-WtScreenText -Screen $Screen -Row $Bottom -Column $Column -Text (Format-WtText -Text (Get-WtString -Key 'Tui.Status.Pending' -Arguments @($Filters.Count)) -Width $Width) -Style 'Pending' -MaxWidth $Width
    }
}

<#
.SYNOPSIS
    Paints the details pane for the selected row.
#>
function Add-WtTuiDetails
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Layout,
        [Parameter(Mandatory = $true)][int]$Column,
        [Parameter(Mandatory = $true)][int]$Width
    )

    $Screen = $State.Screen
    $Row = $Layout.Top + 1
    $Bottom = $Layout.Bottom - 1

    if ($State.Items.Count -eq 0)
    {
        Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text (Get-WtString -Key 'Tui.Details.None') -Style 'Muted' -MaxWidth $Width
        return
    }

    $Item = $State.Items[$State.ItemIndex]

    if ($Item.Kind -ne 'Tweak')
    {
        $Lines = @()
        if ($Item.Kind -eq 'History')
        {
            $Entry = $Item.Entry
            $Lines += (Get-WtString -Key 'Tui.Details.Tweak') + ": $($Entry.TweakId)"
            $Lines += (Get-WtString -Key 'Tui.Col.State') + ": $($Entry.State)"
            $Lines += (Get-WtString -Key 'Tui.Col.Outcome') + ": $(Get-WtString -Key "Op.$($Entry.Outcome)")"
            $Lines += (Get-WtString -Key 'Tui.Col.Time') + ": $($Entry.Timestamp)"
            $Lines += (Get-WtString -Key 'Tui.Details.Records') + ": $($Entry.RecordCount)"
            $Lines += (Get-WtString -Key 'Tui.History.RolledBack') + ": $(if ($Entry.RolledBack) { Get-WtString -Key 'Common.Yes' } else { Get-WtString -Key 'Common.No' })"
            $Lines += (Get-WtString -Key 'Tui.Pending.Restart') + ": $(Get-WtString -Key "Restart.$($State.States | Where-Object { $_.Id -eq $Entry.TweakId } | Select-Object -ExpandProperty Restart -First 1)")"
        }
        else
        {
            $Lines += (Get-WtString -Key 'Tui.Overview.Label') + ": $($Item.Label)"
            $Lines += (Get-WtString -Key 'Tui.Overview.Value') + ": $($Item.Value)"
        }

        $Lines += (Get-WtString -Key 'Tui.Details.Hint')
        foreach ($Line in $Lines)
        {
            foreach ($Wrapped in (Format-WtWrappedText -Text $Line -Width $Width))
            {
                if ($Row -gt $Bottom) { return }
                Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text $Wrapped -Style 'ItemMeta' -MaxWidth $Width
                $Row++
            }
        }
        return
    }

    $Entry = $Item.State
    $Pending = $State.Pending.Contains($Entry.Id)
    $Target = if ($Pending) { [string](($State.Pending[$Entry.Id]).Target) } else { '' }

    # The strings are composed in variables first: a binary `+` inside a hashtable
    # literal value is parsed as a statement, which makes that position ambiguous.
    $ScopeLabel = Get-WtString -Key "Tui.Scope.$($Entry.Scope)"
    if ($ScopeLabel -eq "[Tui.Scope.$($Entry.Scope)]")
    {
        $ScopeLabel = $Entry.Scope
    }

    $PrivilegeLabel = Get-WtString -Key "Tui.Privilege.$($Entry.Privilege)"
    $RiskLabel = Get-WtString -Key "Tui.Impact.$($Entry.Risk)"
    $RestartLabel = Get-WtString -Key "Restart.$($Entry.Restart)"
    $RollbackLabel = Get-WtString -Key "Rollback.$($Entry.Rollback)"

    $Sections = [System.Collections.Generic.List[object]]::new()
    $Sections.Add(@{ Text = $Entry.Name; Style = 'PanelTitle'; Icon = (Get-WtCategoryIconKey -Category $Entry.Category) })
    $Sections.Add(@{ Text = $Entry.Id; Style = 'ItemMeta' })
    $Sections.Add(@{ Text = $Entry.Description; Style = 'Item' })
    $Sections.Add(@{ Text = "$(Get-WtString -Key 'Tui.Details.Effect'): $($Entry.Impact)"; Style = 'Item' })

    # Capability-loss disclosures: what may stop working after this action, next to the
    # effect that causes it.
    $TweakForLoss = Get-WtTweakInternal -Id $Entry.Id
    $LossDeclarations = $null
    if ($TweakForLoss)
    {
        if (@($TweakForLoss.PSObject.Properties.Name) -contains 'DefinitionCapabilityLoss')
        {
            $LossDeclarations = @($TweakForLoss.DefinitionCapabilityLoss)
        }
        elseif (@($TweakForLoss.PSObject.Properties.Name) -contains 'CapabilityLoss')
        {
            $LossDeclarations = @($TweakForLoss.CapabilityLoss)
        }
    }
    if ($LossDeclarations -and $LossDeclarations.Count -gt 0)
    {
        $LossResult = Get-WtTweakCapabilityLossInternal -Tweak $TweakForLoss -State ([string]$Entry.State)
        $LossLines = @($LossResult | Where-Object { $_.Applies -or $null -eq $_.Applies } | ForEach-Object {
                $KindText = Get-WtString -Key "Cap.Loss.Kind.$($_.Kind)"
                $TemporaryText = if ($_.Temporary) { Get-WtString -Key 'Cap.Loss.Temporary' } else { Get-WtString -Key 'Cap.Loss.Persistent' }
                $Line = "{0} [{1} | {2}]" -f (Get-WtText -Value $_.Names), $KindText, $TemporaryText
                if ($_.Condition -and $_.Condition.Explanation) { $Line += " — " + (Get-WtText -Value $_.Condition.Explanation) }
                if ($_.RestoredBy) { $Line += " — " + (Get-WtString -Key 'Cap.Loss.Restore' -Arguments @((Get-WtText -Value $_.RestoredBy))) }
                $Line
            })

        if ($LossLines.Count -gt 0)
        {
            $Sections.Add(@{ Text = (Get-WtString -Key 'Tui.Details.CapabilityLoss') + ':'; Style = 'PanelTitle' })
            foreach ($Line in $LossLines)
            {
                $Sections.Add(@{ Text = "  $Line"; Style = 'ItemMeta' })
            }
        }
    }

    $Sections.Add(@{ Text = "$(Get-WtString -Key 'Tui.Details.Scope'): $ScopeLabel"; Style = 'ItemMeta' })
    $Sections.Add(@{
        Text  = "$(Get-WtString -Key 'Tui.Details.Privilege'): $PrivilegeLabel"
        Style = 'ItemMeta'
        Icon  = $(if ($Entry.Privilege -eq 'Admin') { 'Status.AdminRequired' } else { '' })
    })
    $Sections.Add(@{ Text = "$(Get-WtString -Key 'Tui.Details.State'): $(Get-WtTuiStateLabel -Name $Entry.State)"; Style = 'ItemMeta'; Icon = (Get-WtStateIconKey -State $Entry.State) })
    $Sections.Add(@{ Text = "$(Get-WtString -Key 'Tui.Details.Risk'): $RiskLabel"; Style = 'ItemMeta' })
    $Sections.Add(@{
        Text  = "$(Get-WtString -Key 'Tui.Details.Restart'): $RestartLabel"
        Style = 'ItemMeta'
        Icon  = $(if ($Entry.Restart -and $Entry.Restart -ne 'None') { 'Status.RestartRequired' } else { '' })
    })
    $Sections.Add(@{
        Text  = "$(Get-WtString -Key 'Tui.Details.Rollback'): $RollbackLabel"
        Style = 'ItemMeta'
        Icon  = $(if ($Entry.Rollback -and $Entry.Rollback -ne 'None') { 'Status.Reversible' } else { '' })
    })

    # A declarative definition is described as one: where it comes from, what it declares about
    # itself, and what that claim actually amounts to on this machine. A pack is shown as a pack,
    # with its author claims marked as claims.
    $Tweak = Get-WtTweakInternal -Id $Entry.Id
    if ($Tweak -and @($Tweak.PSObject.Properties.Name) -contains 'DefinitionDocument')
    {
        # Not $Row: that name is the render cursor of this function, and overwriting it would
        # move every following section to the wrong place.
        $DefinitionRow = Get-WtDefinitionRowInternal -Tweak $Tweak
        $Origin = if ($DefinitionRow.Source -eq 'Pack') { Get-WtString -Key 'Cat.Tui.CatalogBacked' -Arguments @($DefinitionRow.PackId) } else { $DefinitionRow.Source }
        $Sections.Add(@{ Text = "$(Get-WtString -Key 'Cat.Tui.DefinitionTitle'): $Origin (rev $($DefinitionRow.Revision))"; Style = 'ItemMeta' })

        if ($DefinitionRow.Lifecycle -ne 'Available')
        {
            $Sections.Add(@{ Text = "$(Get-WtString -Key 'Cat.Tui.Lifecycle'): $(Get-WtString -Key "Tweak.Lifecycle.$($DefinitionRow.Lifecycle)")"; Style = 'ItemMeta' })
        }

        $Evidence = Get-WtString -Key 'Cat.Tui.DefinitionEvidence' -Arguments @($DefinitionRow.Evidence.Structural, $DefinitionRow.Evidence.ProviderTests, $DefinitionRow.Evidence.Windows)
        $Sections.Add(@{ Text = "$(Get-WtString -Key 'Cat.Tui.Support'): $($DefinitionRow.Support) | $Evidence"; Style = 'ItemMeta' })

        $Unenforced = @('maxBuild', 'editions', 'architecture', 'hardware') | Where-Object {
            $Value = $Tweak.DefinitionConditions[$_]
            ($Value -is [array] -and $Value.Count -gt 0) -or ($Value -isnot [array] -and $Value -and $Value -ne 'Any' -and $Value -ne 0)
        }
        if (@($Unenforced).Count -gt 0)
        {
            $Sections.Add(@{ Text = "$(Get-WtString -Key 'Cat.Tui.Conditions'): $(@($Unenforced) -join ', ')"; Style = 'ItemMeta' })
        }

        if (@($DefinitionRow.Requires).Count -gt 0) { $Sections.Add(@{ Text = "$(Get-WtString -Key 'Cat.Tui.Requires'): $(@($DefinitionRow.Requires) -join ', ')"; Style = 'ItemMeta' }) }
        if (@($DefinitionRow.ConflictsWith).Count -gt 0) { $Sections.Add(@{ Text = "$(Get-WtString -Key 'Cat.Tui.Conflicts'): $(@($DefinitionRow.ConflictsWith) -join ', ')"; Style = 'ItemMeta' }) }
    }

    # Configured, effective and ownership are three different answers, and they are cached per
    # row: each costs live reads and the pane repaints on every key press. The cache is cleared
    # whenever the catalog is refreshed, so it cannot outlive the state it describes.
    if (-not $State.DimensionCache) { $State.DimensionCache = @{} }
    if (-not $State.DimensionCache.ContainsKey($Entry.Id))
    {
        $State.DimensionCache[$Entry.Id] = Get-WtStateDimensionsInternal -Tweak (Get-WtTweakInternal -Id $Entry.Id) -State ([string]$Entry.State)
    }

    $Dimensions = $State.DimensionCache[$Entry.Id]
    if ($Dimensions)
    {
        $Sections.Add(@{ Text = (Get-WtString -Key 'Cat.Tui.Configured') + ": " + (Get-WtDimensionLabelInternal -Dimension 'Configured' -Value $Dimensions.Configured); Style = 'ItemMeta' })
        $Sections.Add(@{ Text = (Get-WtString -Key 'Cat.Tui.Effective') + ": " + (Get-WtDimensionLabelInternal -Dimension 'Effective' -Value $Dimensions.Effective) + " (" + (Get-WtDimensionLabelInternal -Dimension 'Evidence' -Value $Dimensions.EffectiveEvidence) + ")"; Style = 'ItemMeta' })
        $Sections.Add(@{ Text = (Get-WtString -Key 'Cat.Tui.Ownership') + ": " + (Get-WtDimensionLabelInternal -Dimension 'Ownership' -Value $Dimensions.Ownership); Style = 'ItemMeta' })
        if ($Dimensions.EffectiveReason) { $Sections.Add(@{ Text = $Dimensions.EffectiveReason; Style = 'ItemMeta' }) }
    }

    $GroupForEntry = if ($Tweak -and @($Tweak.PSObject.Properties.Name) -contains 'DefinitionGroup') { $Tweak.DefinitionGroup } else { $null }
    if ($GroupForEntry)
    {
        $Sections.Add(@{ Text = (Get-WtString -Key 'Cat.Tui.Group') + ": " + (Get-WtText -Value $GroupForEntry.Labels) + " [" + $GroupForEntry.Id + "]"; Style = 'ItemMeta' })
        foreach ($OptionId in @($GroupForEntry.OptionIds))
        {
            $Option = $GroupForEntry.Options[$OptionId]
            $Sections.Add(@{ Text = "  " + (Get-WtText -Value $Option.Labels) + " - " + (Get-WtIntentLabelInternal -Intent $Option.Intent); Style = 'ItemMeta' })
        }
    }

    $Requires = @($Entry.Requires)
    if ($Requires.Count -gt 0)
    {
        $DependencyText = "$(Get-WtString -Key 'Tui.Details.Dependencies'): " + ($Requires -join ', ')
        $Sections.Add(@{ Text = $DependencyText; Style = 'ItemMeta' })
    }

    if ($Pending)
    {
        $ChangeText = "$(Get-WtString -Key 'Tui.Details.Pending'): " + (Get-WtString -Key 'Tui.Pending.Change' -Arguments @($Entry.State, $Target))
        $Sections.Add(@{ Text = $ChangeText; Style = 'Pending'; Icon = 'Status.Pending' })
    }

    if ($Entry.Managed)
    {
        $Sections.Add(@{ Text = Get-WtString -Key 'Error.ManagedByPolicy' -Arguments @(($Entry.ManagedBy) -join ', '); Style = 'Warning'; Icon = 'Status.Warning' })
    }

    if (-not $Entry.Supported)
    {
        $Sections.Add(@{ Text = $Entry.UnsupportedReason; Style = 'Warning'; Icon = 'Status.Unsupported' })
    }

    if ($Entry.Irreversible)
    {
        $Sections.Add(@{ Text = Get-WtString -Key 'Error.Irreversible' -Arguments @($Entry.Name); Style = 'Error'; Icon = 'Status.Failed' })
    }

    if ($Entry.ReducesProtection)
    {
        $Sections.Add(@{ Text = Get-WtString -Key 'Tui.Details.Protection'; Style = 'Error'; Icon = 'Status.Failed' })
    }

    if ($Entry.Note)
    {
        $Sections.Add(@{ Text = $Entry.Note; Style = 'Muted' })
    }

    if (@($Entry.Tweak.Parameters).Count -gt 0)
    {
        $ParameterText = "$(Get-WtString -Key 'Tui.Details.Parameters'): " + (@($Entry.Tweak.Parameters) -join ', ')
        $Sections.Add(@{ Text = $ParameterText; Style = 'ItemMeta' })
    }

    $Sections.Add(@{ Text = "$(Get-WtString -Key 'Tui.Details.Instances'): $(@($Entry.Instances).Count)"; Style = 'ItemMeta' })

    foreach ($Section in $Sections)
    {
        $IconKey = ''
        if ($Section.ContainsKey('Icon')) { $IconKey = [string]$Section.Icon }

        # An icon column needs room for the icon and a readable label; the label wins.
        $IconWidth = Get-WtIconColumnWidth -Icons $State.Icons -Key $IconKey -Width $Width -MinimumLabel 12
        if ($IconWidth -le 0) { $IconKey = '' }

        $First = $true
        foreach ($Wrapped in (Format-WtWrappedText -Text $Section.Text -Width ($Width - $IconWidth)))
        {
            if ($Row -gt $Bottom) { return }

            # Each painted line owns its row: clear the whole row area first so a shorter
            # line can never leave stale text from the previous selection behind.
            Set-WtScreenRegion -Screen $Screen -Row $Row -Column $Column -Width $Width -Height 1 -Style $Section.Style

            if ($IconWidth -le 0)
            {
                Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text $Wrapped -Style $Section.Style -MaxWidth $Width
            }
            elseif ($First)
            {
                # Only the first line carries the icon; the wrapped continuation lines are
                # indented by the same slot so the section stays visually one block.
                Set-WtScreenIconText -Screen $Screen -Row $Row -Column $Column -Width $Width -IconKey $IconKey -Text $Wrapped -Style $Section.Style
            }
            else
            {
                Set-WtScreenText -Screen $Screen -Row $Row -Column ($Column + $IconWidth) -Text $Wrapped -Style $Section.Style -MaxWidth ($Width - $IconWidth)
            }

            $First = $false
            $Row++
        }

        $Row++
    }
}

<#
.SYNOPSIS
    Paints the live operation panel (active item, real item counts, per-item results).
.DESCRIPTION
    Progress is reported as "item N of M" because that is the only number the worker can
    prove. No percentage is invented: the icon bar under that line is drawn from the same
    completed-item count, never from elapsed time, so it stands still while one native
    call is in flight instead of pretending to advance.
#>
function Add-WtTuiOperation
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.Operation)
    {
        return
    }

    $Operation = $State.Operation
    $Screen = $State.Screen
    $Width = [math]::Min(84, [math]::Max(30, $Screen.Width - 8))
    $Column = [math]::Floor(($Screen.Width - $Width) / 2) + 1

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Progress = $Operation.Progress
    $Completed = if ($Progress) { [int]$Progress.Completed } else { [int]$Operation.Finished }
    $Total = [math]::Max([int]$Operation.Total, $Completed)
    $Lines.Add((Get-WtString -Key 'Tui.Busy.Item' -Arguments @($Completed, $Total)))

    # The bar visualises the same completed-item counts as the line above; it is not a
    # time estimate, and it deliberately cannot move while one native call is running.
    $Bar = Format-WtIconProgressBar -Icons $State.Icons -Done $Completed -Total $Total
    if ($Bar) { $Lines.Add($Bar) }

    if ($Operation.Active) { $Lines.Add((Get-WtString -Key 'Tui.Busy.Active' -Arguments @($Operation.Active))) }
    if ($Operation.Cancelling) { $Lines.Add((Get-WtString -Key 'Tui.Busy.Cancelling')) }

    foreach ($Result in @($Operation.Events | Select-Object -Last 4))
    {
        $Lines.Add($Result)
    }

    $Height = [math]::Min($Screen.Height - 2, 4 + $Lines.Count)
    $Top = [math]::Max(2, $Screen.Height - 2 - $Height)

    $TitleIcon = if ($Operation.Cancelling) { 'Action.Cancel' }
    elseif ($Operation.Kind -eq 'rollback') { 'Action.Restore' }
    elseif ($Operation.Preview) { 'Action.Preview' }
    else { 'Action.Apply' }

    Add-WtScreenBox -Screen $Screen -Row $Top -Column $Column -Width $Width -Height $Height `
        -Title (Format-WtIconLabel -Icons $State.Icons -Key $TitleIcon -Label (Get-WtString -Key 'Tui.Busy.Title')) `
        -BorderStyle 'Border' -TitleStyle $(if ($Operation.Cancelling) { 'Warning' } else { 'DialogTitle' }) -Style 'Dialog'

    $Row = $Top + 1
    $First = $true
    foreach ($Line in $Lines)
    {
        if ($Row -ge ($Top + $Height - 1)) { break }

        if ($First)
        {
            # The active-item line carries the running icon; the remaining lines stay
            # plain text so the per-item results are easy to scan.
            Set-WtScreenIconText -Screen $Screen -Row $Row -Column ($Column + 2) -Width ($Width - 4) -IconKey 'Status.Running' `
                -Text (Format-WtText -Text $Line -Width ($Width - 4)) -Style 'Dialog'
            $First = $false
        }
        else
        {
            Set-WtScreenText -Screen $Screen -Row $Row -Column ($Column + 2) -Text (Format-WtText -Text $Line -Width ($Width - 4)) -Style 'Dialog' -MaxWidth ($Width - 4)
        }

        $Row++
    }

    $Hint = if ($Operation.Cancelling) { Get-WtString -Key 'Tui.Busy.CancelHint' } else { Get-WtString -Key 'Tui.Busy.Hint' }
    Set-WtScreenText -Screen $Screen -Row ($Top + $Height - 2) -Column ($Column + 2) -Text (Format-WtText -Text $Hint -Width ($Width - 4)) -Style 'DialogHint' -MaxWidth ($Width - 4)
}

<#
.SYNOPSIS
    Paints the context-sensitive shortcut line and the status line.
#>
function Add-WtTuiFooter
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Layout
    )

    $Screen = $State.Screen
    $Width = $Screen.Width

    $FirstRow = $Screen.Height - $Layout.FooterRows + 1
    Set-WtScreenRegion -Screen $Screen -Row $FirstRow -Column 1 -Width $Width -Height $Layout.FooterRows -Style 'StatusBar'

    $Hint = ''
    if ($State.Operation)
    {
        $Hint = Get-WtString -Key 'Tui.Keys.Busy'
    }
    elseif ($State.ExternalTool)
    {
        # A workspace owns the keyboard while it is open, so its own key map replaces the
        # main-screen hints instead of being read next to them. While a background transfer
        # runs, the hint names the one key that is meaningful then.
        $Hint = $(if ($State.ExternalToolTask -and (Test-WtExternalToolTaskBusy -Task $State.ExternalToolTask))
            {
                Get-WtString -Key 'Mas.Hint.Busy'
            }
            else
            {
                Get-WtString -Key 'Mas.Hint'
            })
    }
    elseif ($State.Licensing)
    {
        $Hint = Get-WtString -Key 'Lic.Hint'
    }
    elseif ($State.SearchMode)
    {
        $Hint = Get-WtString -Key 'Tui.Keys.Search'
    }
    elseif ($Layout.Mode -eq 'Compact')
    {
        $Hint = Get-WtString -Key 'Tui.Keys.Compact'
    }
    else
    {
        $Hint = Get-WtString -Key 'Tui.Keys.Main'
    }

    Set-WtScreenText -Screen $Screen -Row $FirstRow -Column 2 -Text (Format-WtText -Text $Hint -Width ($Width - 3)) -Style 'StatusInfo' -MaxWidth ($Width - 3)

    if ($Layout.FooterRows -ge 2)
    {
        $StatusText = [string]$State.Status.Text
        if (-not $StatusText)
        {
            $Pending = Get-WtString -Key 'Tui.Status.Pending' -Arguments @($State.Pending.Count)
            $StatusText = Get-WtString -Key 'Tui.Status.Ready' -Arguments @($Pending)
        }

        # The footer paints the Surface background, so the status icon is composed into
        # the string and takes the tone's own colour (green/amber/red) instead of an icon
        # style with a different background.
        $StatusText = Format-WtIconLabel -Icons $State.Icons -Key (Get-WtToneIconKey -Tone $State.Status.Tone) -Label $StatusText

        Set-WtScreenText -Screen $Screen -Row ($FirstRow + 1) -Column 2 -Text (Format-WtText -Text $StatusText -Width ($Width - 3)) -Style $State.Status.Tone -MaxWidth ($Width - 3)
    }
}

<#
.SYNOPSIS
    Paints the complete frame into the cell grid (main screen plus any overlay).
#>
function Update-WtTuiView
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Screen = $State.Screen
    $Layout = Get-WtTuiLayout -State $State

    Clear-WtScreen -Screen $Screen

    # Monitoring mode: the workspace canvas replaces the main panes. Dialog overlays and
    # the footer still paint on top of it, so the inspector/alerts/editor/comparison
    # flows and the keyboard conventions keep working unchanged.
    if ($State.Monitor)
    {
        Add-WtMonitorView -State $State -Monitor $State.Monitor
        Add-WtTuiFooter -State $State -Layout $Layout

        if ($State.Overlay)
        {
            Add-WtDialogToScreen -Screen $Screen -Overlay $State.Overlay
        }

        Add-WtTuiOperation -State $State

        $State.ForceRepaint = $false
        return
    }

    # Licensing workspace: same contract, a different canvas.
    if ($State.Licensing)
    {
        if ($State.ExternalTool)
        {
            # The external tool is a view of the licensing workspace, not a second workspace:
            # the diagnostics stay loaded underneath, which is what lets the status be re-read
            # the moment the launched tool returns.
            Add-WtExternalToolView -State $State -Tool $State.ExternalTool
        }
        else
        {
            Add-WtLicensingView -State $State -License $State.Licensing
        }
        Add-WtTuiFooter -State $State -Layout $Layout

        if ($State.Overlay)
        {
            Add-WtDialogToScreen -Screen $Screen -Overlay $State.Overlay
        }

        Add-WtTuiOperation -State $State

        $State.ForceRepaint = $false
        return
    }

    Add-WtTuiHeader -State $State -Layout $Layout
    Add-WtTuiFrame -State $State -Layout $Layout
    Add-WtTuiCategories -State $State -Layout $Layout
    Add-WtTuiList -State $State -Layout $Layout

    if ($Layout.Mode -eq 'Wide')
    {
        Add-WtTuiDetails -State $State -Layout $Layout -Column ($Layout.Divider2 + 1) -Width ($Layout.PaneWidth.Details)
    }
    elseif ($State.Focus -eq 'Details')
    {
        # Medium layout: the details pane replaces the list while it has focus.
        Set-WtScreenRegion -Screen $Screen -Row ($Layout.Top + 1) -Column ($Layout.Divider1 + 1) -Width $Layout.PaneWidth.List -Height ([math]::Max(1, $Layout.Bottom - $Layout.Top - 1)) -Style 'Default'
        Add-WtTuiDetails -State $State -Layout $Layout -Column ($Layout.Divider1 + 1) -Width $Layout.PaneWidth.List
    }

    Add-WtTuiFooter -State $State -Layout $Layout

    if ($State.Overlay)
    {
        Add-WtDialogToScreen -Screen $Screen -Overlay $State.Overlay
    }

    Add-WtTuiOperation -State $State

    $State.ForceRepaint = $false
}

#endregion Painting

<#
.SYNOPSIS
    Paints (when needed) and writes one frame, then returns the next key press.
.DESCRIPTION
    This is the single place the interface touches the terminal, so both the main loop
    and the dialogs stay in step: one owner for rendering and input, worker events are
    drained between frames, and a resize is picked up before anything is painted into a
    stale grid.
#>
function Invoke-WtTuiFrame
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 40
    )

    Update-WtTuiOperation -State $State

    # Performance diagnostics (opt-in): a sample is opened for this frame, populated with
    # the dispatch/construct/output durations, and completed by the caller (the main loop
    # adds the handler duration; an idle frame is completed here).
    $Perf = Test-WtTuiPerf
    if ($Perf)
    {
        if ($Script:WtTuiPerfContext)
        {
            # A previous frame left a sample without a handler (a dialog consumed the key):
            # record it as it is instead of losing it.
            Add-WtTuiPerfSample -Sample $Script:WtTuiPerfContext
        }
        $Script:WtTuiPerfContext = New-WtTuiPerfSample
        $Dispatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $Size = if ($State.SizeSource) { & $State.SizeSource } else { Get-WtConsoleSize }
    if ($Size.Width -ne $State.Screen.Width -or $Size.Height -ne $State.Screen.Height)
    {
        # A resize replaces the grid but keeps every piece of state: cursor, selection,
        # pending changes, search and the open overlay all survive it.
        $State.Size = $Size
        $State.Screen = New-WtScreen -Width $Size.Width -Height $Size.Height -Theme $State.Theme
        $State.ForceRepaint = $true
    }

    if ($State.Screen.Dirty -or $State.ForceRepaint)
    {
        $Perf = Test-WtTuiPerf
        $Construct = if ($Perf) { [System.Diagnostics.Stopwatch]::StartNew() } else { $null }
        $RowsWritten = 0

        if ($State.ForceRepaint)
        {
            # Ctrl+L and structural changes repaint from scratch; otherwise only rows that
            # actually differ from the last written frame are emitted.
            Reset-WtScreenDiff -Screen $State.Screen
        }

        Update-WtTuiView -State $State

        if ($Perf) { $Construct.Stop() }

        if (-not $State.Silent)
        {
            $Output = if ($Perf) { [System.Diagnostics.Stopwatch]::StartNew() } else { $null }

            if ($State.UseVt)
            {
                Write-WtScreen -Screen $State.Screen
            }
            else
            {
                Write-WtScreenPlain -Screen $State.Screen
            }

            if ($Perf)
            {
                $Output.Stop()
                $RowsWritten = 0
                for ($Row = 0; $Row -lt $State.Screen.Height; $Row++)
                {
                    if ($null -ne $State.Screen.PreviousCells[$Row]) { $RowsWritten++ }
                }
            }
        }
        else
        {
            $State.Screen.Dirty = $false
            $State.ForceRepaint = $false
        }

        if ($Perf -and $Script:WtTuiPerfContext)
        {
            $Script:WtTuiPerfContext.ConstructMs = $Construct.Elapsed.TotalMilliseconds
            $Script:WtTuiPerfContext.OutputMs = $(if ($Output) { $Output.Elapsed.TotalMilliseconds } else { 0 })
            $Script:WtTuiPerfContext.RowsWritten = $RowsWritten
            $Script:WtTuiPerfContext.Painted = $true
        }
    }

    if ($State.KeySource)
    {
        $Raw = & $State.KeySource
        if ($Perf) { $Dispatch.Stop() }
        if ($null -eq $Raw)
        {
            # An injected key source that never produces a key would otherwise make a
            # dialog loop forever (which is exactly what a hang looks like in a test run).
            $State.EmptyFrames = [int]$State.EmptyFrames + 1
            if ($State.EmptyFrames -gt 50)
            {
                throw 'The injected key source ran out of keys while a dialog was open.'
            }

            if ($Perf)
            {
                $Script:WtTuiPerfContext.DispatchMs = $Dispatch.Elapsed.TotalMilliseconds
                Add-WtTuiPerfSample -Sample $Script:WtTuiPerfContext
                $Script:WtTuiPerfContext = $null
            }

            return $null
        }

        $State.EmptyFrames = 0

        if ($Perf)
        {
            $Script:WtTuiPerfContext.DispatchMs = $Dispatch.Elapsed.TotalMilliseconds
        }

        return (ConvertTo-WtKey -Key $Raw)
    }

    $Raw = Read-WtConsoleKey -TimeoutMs $TimeoutMs
    if ($Perf) { $Dispatch.Stop() }

    if ($Script:WtConsoleInputLost)
    {
        # The console stopped delivering input (closed pty, detached window). Returning null
        # forever would look exactly like a frozen dialog, so the loop is told to stop and
        # the caller restores the terminal in its finally block.
        $State.Exit = $true

        if ($Perf)
        {
            $Script:WtTuiPerfContext.DispatchMs = $Dispatch.Elapsed.TotalMilliseconds
            Add-WtTuiPerfSample -Sample $Script:WtTuiPerfContext
            $Script:WtTuiPerfContext = $null
        }

        return $null
    }

    if ($null -eq $Raw)
    {
        if ($Perf)
        {
            $Script:WtTuiPerfContext.DispatchMs = $Dispatch.Elapsed.TotalMilliseconds
            Add-WtTuiPerfSample -Sample $Script:WtTuiPerfContext
            $Script:WtTuiPerfContext = $null
        }

        return $null
    }

    if ($Perf)
    {
        $Script:WtTuiPerfContext.DispatchMs = $Dispatch.Elapsed.TotalMilliseconds
    }

    return (ConvertTo-WtKey -Key $Raw)
}

<#
.SYNOPSIS
    Advances the interface by one render and one batch of keys.
.DESCRIPTION
    The render happens at most once per step; after the first key is handled, further keys
    that are already waiting are handled without another render in between, and the
    accumulated work is painted once the queue is empty. Held-arrow navigation therefore
    coalesces hundreds of autorepeat presses into a few frames instead of painting per
    key. The batch is bounded, and a modal overlay or a started operation stops it so the
    screen reflects the new mode before the next key is consumed. No key is ever dropped.
#>
function Invoke-WtTuiLoopStep
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][int]$MaxBatch = 32
    )

    $DefaultTimeout = if (@($State.Keys) -contains 'FrameTimeoutMs') { [int]$State.FrameTimeoutMs } else { 40 }
    $Key = Invoke-WtTuiFrame -State $State -TimeoutMs $DefaultTimeout
    if ($null -eq $Key)
    {
        return
    }

    $Batch = 0
    $TotalHandlerMs = [double]0
    $MaxBatch = if (@($State.Keys) -contains 'ProfileKnobs') { [int]$State.ProfileKnobs.MaxKeyBatch } else { $MaxBatch }
    $BatchBudgetMs = if (@($State.Keys) -contains 'ProfileKnobs') { [int]$State.ProfileKnobs.MaxBatchElapsedMs } else { 200 }
    $BatchWatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Key -and $Batch -lt $MaxBatch -and $BatchWatch.ElapsedMilliseconds -lt $BatchBudgetMs -and -not $State.Exit)
    {
        $Handler = if (Test-WtTuiPerf) { [System.Diagnostics.Stopwatch]::StartNew() } else { $null }
        $null = Invoke-WtTuiKey -State $State -Key $Key
        if ($Handler)
        {
            $Handler.Stop()
            $TotalHandlerMs += $Handler.Elapsed.TotalMilliseconds
        }

        $Batch++

        # A modal overlay or a started operation changes what must be on screen right now:
        # stop batching so the frame renders before the next key is consumed.
        if ($State.Overlay -or $State.Operation)
        {
            break
        }

        $Raw = if ($State.KeySource) { & $State.KeySource } else { Read-WtConsoleKey -TimeoutMs 0 }
        $Key = if ($null -eq $Raw) { $null } else { ConvertTo-WtKey -Key $Raw }
    }

    if ((Test-WtTuiPerf) -and $Script:WtTuiPerfContext)
    {
        $Script:WtTuiPerfContext.HandlerMs = $TotalHandlerMs
        Add-WtTuiPerfSample -Sample $Script:WtTuiPerfContext
        $Script:WtTuiPerfContext = $null
    }
}

<#
.SYNOPSIS
    Applies one key press to the interface.
.DESCRIPTION
    The order of the guards is the contract: a running operation first, then a modal
    overlay (dialogs own the keyboard), then the search field (ordinary letters must enter
    text there), and only then the global shortcuts.
#>
function Invoke-WtTuiKey
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Key
    )

    # The diagnostic trace records one line per key with the place it was dispatched to.
    # It is off by default and writes to the structured log only, never to the screen.
    $Target = 'ignored'
    $Secret = $false

    if ($State.Operation)
    {
        $Target = 'operation'
        $null = Read-WtTuiOperationKey -State $State -Key $Key
        Write-WtInputTrace -Scope 'main' -Key $Key -Target $Target
        return
    }

    if ($State.SearchMode)
    {
        # Letters here are the filter text, not commands: they are never recorded.
        $Target = 'search'
        $Secret = $true
        Read-WtTuiSearchKey -State $State -Key $Key
        Write-WtInputTrace -Scope 'main' -Key $Key -Target $Target -Secret:$Secret
        return
    }

    switch ($Key.Name)
    {
        'Up' { $Target = 'list'; Move-WtTuiSelection -State $State -Delta -1 }
        'Down' { $Target = 'list'; Move-WtTuiSelection -State $State -Delta 1 }
        'PageUp' { $Target = 'list'; Move-WtTuiSelection -State $State -Delta -8 }
        'PageDown' { $Target = 'list'; Move-WtTuiSelection -State $State -Delta 8 }
        'Home' { $Target = 'list'; Set-WtTuiItemIndex -State $State -Index 0 }
        'End' { $Target = 'list'; Set-WtTuiItemIndex -State $State -Index ($State.Items.Count - 1) }
        'Left' { $Target = 'panes'; Move-WtTuiFocus -State $State -Delta -1 }
        'Right' { $Target = 'panes'; Move-WtTuiFocus -State $State -Delta 1 }
        'Tab' { $Target = 'panes'; Move-WtTuiFocus -State $State -Delta 1 }
        'BackTab' { $Target = 'panes'; Move-WtTuiFocus -State $State -Delta -1 }
        'Space' { $Target = 'pending'; Switch-WtTuiPending -State $State }
        'Enter'
        {
            $Target = 'action'
            if ($State.Focus -eq 'Categories')
            {
                Move-WtTuiFocus -State $State -Delta 1
            }
            else
            {
                Invoke-WtTuiAction -State $State
            }
        }
        'Escape'
        {
            $Target = 'escape'
            if ($State.Search)
            {
                $State.Search = ''
                Update-WtTuiItems -State $State
                Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.FilterCleared')
            }
            elseif ($State.Focus -ne 'List')
            {
                Set-WtTuiFocus -State $State -Focus 'List'
            }
        }
        'Control'
        {
            $Character = ([string]$Key.Char).ToLowerInvariant()
            $Target = "control:$Character"
            if ($Character -eq 'c') { Invoke-WtTuiQuit -State $State }
            elseif ($Character -eq 'l') { $State.ForceRepaint = $true }
            elseif ($Character -eq 'p') { Show-WtTuiProfilePicker -State $State }
        }
        'Char'
        {
            # The shortcut handler reports which command (if any) claimed the letter, so the
            # trace shows "global:l" rather than a bare character.
            $Target = Read-WtTuiGlobalChar -State $State -Key $Key
        }
        default { $Target = 'unhandled' }
    }

    Write-WtInputTrace -Scope 'main' -Key $Key -Target $Target
}

<#
.SYNOPSIS
    Handles the letter shortcuts (only reached when no text field has focus).
.OUTPUTS
    The dispatch target of the letter ('global:q', ...) or 'ignored', so the input
    diagnostic can record which shortcut claimed it without a second lookup table.
#>
function Read-WtTuiGlobalChar
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Key
    )

    $Character = ([string]$Key.Char).ToLowerInvariant()

    switch ($Character)
    {
        '/' { $State.SearchMode = $true; Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.SearchMode') }
        'a' { Show-WtTuiPendingReview -State $State }
        'w' { Start-WtTuiOperation -State $State -Preview }
        'h' { Set-WtTuiCategory -State $State -Key 'History' }
        'r' { Invoke-WtTuiRestore -State $State }
        'd' { Set-WtTuiDryRun -State $State -Enabled (-not $State.DryRun) }
        'l' { Show-WtTuiLanguagePicker -State $State }
        'i' { Show-WtTuiIconPicker -State $State }
        'p' { Show-WtTuiPresets -State $State }
        'g' { Update-WtTuiCatalog -State $State }
        'v' { Show-WtTuiVerification -State $State }
        's' { Show-WtTuiSanity -State $State }
        'm' { Show-WtTuiRecommendations -State $State }
        'c' { Show-WtTuiChoices -State $State }
        'b' { Show-WtTuiMonitor -State $State }
        'n' { Show-WtTuiLicensing -State $State }
        '?' { Show-WtTuiHelp -State $State }
        'q' { Invoke-WtTuiQuit -State $State }
        default { return 'ignored' }
    }

    return "global:$Character"
}

<#
.SYNOPSIS
    Handles keys while the search field has focus.
.DESCRIPTION
    Letters, digits and spaces are text here; only Enter, Escape and the navigation keys
    keep their global meaning. This is what stops "a" from opening the pending review
    while the user is typing a filter.
#>
function Read-WtTuiSearchKey
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Key
    )

    switch ($Key.Name)
    {
        'Enter'
        {
            $State.SearchMode = $false
            Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Filtered' -Arguments @($State.Items.Count))
        }
        'Escape'
        {
            $State.SearchMode = $false
            $State.Search = ''
            Update-WtTuiItems -State $State
            Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.FilterCleared')
        }
        'Up' { Move-WtTuiSelection -State $State -Delta -1 }
        'Down' { Move-WtTuiSelection -State $State -Delta 1 }
        'PageUp' { Move-WtTuiSelection -State $State -Delta -8 }
        'PageDown' { Move-WtTuiSelection -State $State -Delta 8 }
        'Backspace'
        {
            if ($State.Search.Length -gt 0)
            {
                $State.Search = $State.Search.Substring(0, $State.Search.Length - 1)
                Update-WtTuiItems -State $State
            }
        }
        'Space'
        {
            $State.Search += ' '
            Update-WtTuiItems -State $State
        }
        'Char'
        {
            $State.Search += [string]$Key.Char
            Update-WtTuiItems -State $State
        }
        default { }
    }
}

<#
.SYNOPSIS
    Moves the cursor inside the focused pane.
#>
function Move-WtTuiSelection
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][int]$Delta
    )

    if ($State.Focus -eq 'Categories')
    {
        $Count = $State.Categories.Count
        if ($Count -eq 0) { return }
        $Index = [math]::Max(0, [math]::Min($Count - 1, $State.CategoryIndex + [math]::Sign($Delta)))
        Set-WtTuiCategory -State $State -Index $Index
        return
    }

    Set-WtTuiItemIndex -State $State -Index ($State.ItemIndex + $Delta)
}

<#
.SYNOPSIS
    Moves the focus between the panes visible in the current layout.
#>
function Move-WtTuiFocus
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][int]$Delta
    )

    $Layout = Get-WtTuiLayout -State $State

    if ($Layout.Mode -eq 'Compact')
    {
        Set-WtTuiFocus -State $State -Focus $(if ($State.Focus -eq 'Categories') { 'List' } else { 'Categories' })
        return
    }

    $Order = if ($Layout.Mode -eq 'Wide') { @('Categories', 'List', 'Details') } else { @('Categories', 'List') }
    $Position = [array]::IndexOf($Order, $State.Focus)
    if ($Position -lt 0) { $Position = 1 }

    $Position += [math]::Sign($Delta)
    if ($Position -lt 0) { $Position = $Order.Count - 1 }
    if ($Position -ge $Order.Count) { $Position = 0 }

    Set-WtTuiFocus -State $State -Focus $Order[$Position]
}

<#
.SYNOPSIS
    Changes the focused pane.
#>
function Set-WtTuiFocus
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][ValidateSet('Categories', 'List', 'Details')][string]$Focus
    )

    if ($State.Focus -eq $Focus)
    {
        return
    }

    $State.Focus = $Focus
    $State.Screen.Dirty = $true
}

<#
.SYNOPSIS
    Selects a category by index or key and rebuilds the list.
#>
function Set-WtTuiCategory
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][int]$Index = -1,
        [Parameter(Mandatory = $false)][string]$Key
    )

    $Target = $Index
    if ($Key)
    {
        for ($Position = 0; $Position -lt $State.Categories.Count; $Position++)
        {
            if ($State.Categories[$Position].Key -eq $Key)
            {
                $Target = $Position
                break
            }
        }
    }

    if ($Target -lt 0 -or $Target -ge $State.Categories.Count)
    {
        return
    }

    # Re-entering the already-active category with no filter is a no-op: it would rebuild
    # the same list and reset the cursor for no visible change.
    if ($Target -eq $State.CategoryIndex -and -not $State.Search -and -not $State.SearchMode)
    {
        return
    }

    if ($Target -ne $State.CategoryIndex)
    {
        $State.CategoryIndex = $Target
        $State.Search = ''
        $State.SearchMode = $false
    }

    Update-WtTuiItems -State $State
    Set-WtTuiItemIndex -State $State -Index 0
    $State.Screen.Dirty = $true
}

<#
.SYNOPSIS
    Enables or disables dry-run mode for everything applied from the interface.
.DESCRIPTION
    Dry run is the interface-wide default switch: while it is on, applying a selection
    reports what would happen and writes nothing.
#>
function Set-WtTuiDryRun
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][bool]$Enabled
    )

    $State.DryRun = $Enabled
    $State.Notice = if ($Enabled) { Get-WtString -Key 'Tui.Header.DryRunNotice' } else { '' }

    $Text = if ($Enabled) { Get-WtString -Key 'Tui.Status.DryRunOn' } else { Get-WtString -Key 'Tui.Status.DryRunOff' }
    Set-WtTuiStatus -State $State -Text $Text -Tone $(if ($Enabled) { 'StatusWarn' } else { 'StatusInfo' })
}

<#
.SYNOPSIS
    Toggles the current row in the pending set.
.DESCRIPTION
    Space never changes the system: it adds the row to the pending set with the state that
    is the opposite of the detected one. Parameterized tweaks and multi-state tweaks ask
    for their exact target instead of guessing.
#>
function Switch-WtTuiPending
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if ($State.Focus -eq 'Categories' -or $State.Items.Count -eq 0)
    {
        return
    }

    $Item = $State.Items[$State.ItemIndex]
    if ($Item.Kind -ne 'Tweak')
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.NotATweak') -Tone 'StatusWarn'
        return
    }

    $Entry = $Item.State
    if ($State.Pending.Contains($Entry.Id))
    {
        $State.Pending.Remove($Entry.Id) | Out-Null
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Unselected' -Arguments @($Entry.Name))
        $State.Screen.Dirty = $true
        return
    }

    if (-not $Entry.Supported)
    {
        Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Unsupported' -Arguments @($Entry.Name)) -Tone 'StatusWarn'
        return
    }

    $States = @($Entry.StateNames)
    $Target = $null

    if ($States.Count -eq 2)
    {
        $Target = if ($Entry.State -eq $States[0]) { $States[1] } else { $States[0] }
    }

    if (-not $Target)
    {
        # More than two states, an unknown current state, or a parameterized tweak: ask
        # instead of guessing.
        $Target = Select-WtTuiTargetState -State $State -Entry $Entry
        if (-not $Target)
        {
            return
        }
    }

    $Arguments = $null
    if (@($Entry.Tweak.Parameters).Count -gt 0)
    {
        $Arguments = Read-WtTuiTweakArguments -State $State -Entry $Entry
        if ($null -eq $Arguments)
        {
            return
        }
    }

    Add-WtTuiPending -State $State -Entry $Entry -Target $Target -Arguments $Arguments
}

<#
.SYNOPSIS
    Adds (or replaces) one pending change.
#>
function Add-WtTuiPending
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $false)][object]$Arguments,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Intent = ''
    )

    $Revision = [guid]::NewGuid().ToString('n')
    $State.Pending[$Entry.Id] = @{
        Id        = $Entry.Id
        Revision  = $Revision
        Target    = $Target
        From      = $Entry.State
        Name      = $Entry.Name
        Arguments = $Arguments
        Risk      = $Entry.Risk
        Restart   = $Entry.Restart
        Rollback  = $Entry.Rollback
        Irreversible = $Entry.Irreversible
        ReducesProtection = $Entry.ReducesProtection
        # The intent of the alternative, when one was chosen: 'WindowsDefault' asks for Windows'
        # own behaviour, which the review must not present as a restoration of the captured state.
        Intent    = $Intent
        # The reviewed fingerprint the engine revalidates before anything is written. It
        # exists only after a review, so a replaced alternative never carries a stale one.
    }

    if ($State.PresetName)
    {
        $State.PresetName = ''
    }

    # The fingerprint is attached by the review; an entry created or replaced here has no
    # reviewed state and therefore no fingerprint member at all.
    $State.Pending[$Entry.Id].Remove('Fingerprint')

    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Selected' -Arguments @($Entry.Name, $Target))
    $State.Screen.Dirty = $true
}

<#
.SYNOPSIS
    Opens the action dialog for the current row (state chooser, instance list, or the
    overview action).
#>
function Invoke-WtTuiAction
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if ($State.Items.Count -eq 0)
    {
        return
    }

    $Item = $State.Items[$State.ItemIndex]

    switch ($Item.Kind)
    {
        'Tweak'
        {
            $Entry = $Item.State
            $Target = Select-WtTuiTargetState -State $State -Entry $Entry
            if (-not $Target)
            {
                return
            }

            $Arguments = $null
            if (@($Entry.Tweak.Parameters).Count -gt 0)
            {
                $Arguments = Read-WtTuiTweakArguments -State $State -Entry $Entry
                if ($null -eq $Arguments)
                {
                    return
                }
            }

            Add-WtTuiPending -State $State -Entry $Entry -Target $Target -Arguments $Arguments
        }
        'History'
        {
            $Entry = $Item.Entry
            $Lines = @(
                (Get-WtString -Key 'Tui.Details.Tweak') + ": $($Entry.TweakId)",
                (Get-WtString -Key 'Tui.Col.State') + ": $($Entry.State)",
                (Get-WtString -Key 'Tui.Col.Outcome') + ": $(Get-WtString -Key "Op.$($Entry.Outcome)")",
                (Get-WtString -Key 'Tui.Col.Time') + ": $($Entry.Timestamp)",
                (Get-WtString -Key 'Tui.Details.Records') + ": $($Entry.RecordCount)"
            )
            foreach ($Message in @($Entry.Messages))
            {
                $Lines += "  - $Message"
            }

            if (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Tui.Restore.Title') -Lines $Lines -Tone 'Warning')
            {
                Start-WtTuiOperation -State $State -RollbackItem $Entry
            }
        }
        default
        {
            switch ($Item.Action)
            {
                'Presets' { Show-WtTuiPresets -State $State }
                'DryRun' { Set-WtTuiDryRun -State $State -Enabled (-not $State.DryRun) }
                'Icons' { Show-WtTuiIconPicker -State $State }
                'Language' { Show-WtTuiLanguagePicker -State $State }
                'Verify' { Show-WtTuiVerification -State $State }
                'DiskUsage' { Show-WtTuiDiskExplorer -State $State }
                'Quarantine' { Show-WtTuiQuarantine -State $State }
                'Monitor' { Show-WtTuiMonitor -State $State }
                'Licensing' { Show-WtTuiLicensing -State $State }
                default { Show-WtTuiOverviewDetails -State $State }
            }
        }
    }
}

<#
.SYNOPSIS
    Reloads the catalog and the history from the backend (read-only).
#>
function Update-WtTuiCatalog
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Refreshing')
    $State.Environment = Get-WtEnvironment
    Sync-WtTuiCatalog -State $State
    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Refreshed' -Arguments @($State.States.Count))
}

<#
.SYNOPSIS
    Paints the static parts of the header that do not depend on the catalog, and reports
    capability notices (reduced colour, ASCII frames, Windows-only tweaks).
#>
function Initialize-WtTuiState
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $State.Environment = Get-WtEnvironment
    Update-WtTuiCatalog -State $State

    $Notices = [System.Collections.Generic.List[string]]::new()
    if (-not $State.Capability.Unicode)
    {
        $Notices.Add((Get-WtString -Key 'Tui.Notice.Ascii'))
    }
    if ($State.Capability.Colour -eq 'Mono')
    {
        $Notices.Add((Get-WtString -Key 'Tui.Notice.Mono'))
    }
    if (-not $State.Environment.IsWindows)
    {
        $Notices.Add((Get-WtString -Key 'Error.WindowsOnly' -Arguments @((Get-WtPlatformDescription))))
    }

    $State.Notice = ''
    if ($Notices.Count -gt 0)
    {
        $State.Notice = $Notices[0]
    }

    # An operation that never finished is surfaced at startup and left alone: inspecting and
    # recovering it are explicit actions (the V view).
    try
    {
        $Interrupted = @(Get-WtInterruptedOperationInternal)
    }
    catch
    {
        $Interrupted = @()
    }

    if ($Interrupted.Count -gt 0)
    {
        Set-WtTuiStatus -State $State -Tone 'StatusWarn' -Text (Get-WtString -Key 'Tui.Status.Interrupted' -Arguments @($Interrupted.Count))
        return
    }

    # Background work: a Go request that cannot be served is announced, never silently
    # downgraded. Auto stays quiet because the PowerShell implementation is a normal outcome.
    $Backend = if ($State.ContainsKey('WorkerBackend')) { [string]$State.WorkerBackend } else { 'Auto' }
    if ($Backend -eq 'Go')
    {
        $Resolution = Resolve-WtWorkerBackend -Requested 'Go'
        if (-not $Resolution.Backend)
        {
            Set-WtTuiStatus -State $State -Tone 'StatusWarn' -Text $Resolution.Reason
            return
        }
    }

    Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Refreshed' -Arguments @($State.States.Count))
}

#region Terminal lifecycle

<#
.SYNOPSIS
    Switches the terminal into the interactive screen (alternate buffer, hidden cursor,
    UTF-8 output) and remembers what has to be restored.
.DESCRIPTION
    Nothing here touches the system: these are terminal modes of the current console
    session only, and Restore-WtTuiTerminal always puts them back.
#>
function Enter-WtTuiTerminal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Restore = @{ OutputEncoding = $null; CursorVisible = $true; Entered = $false }

    try
    {
        $Restore.OutputEncoding = [Console]::OutputEncoding
        $Restore.CursorVisible = [Console]::CursorVisible
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'Console encoding/cursor state is not readable.' -NoConsole
    }

    if ([Console]::OutputEncoding -and [Console]::OutputEncoding.WebName -notmatch 'utf')
    {
        try
        {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $Restore.ChangedEncoding = $true
        }
        catch
        {
            # Keep going: the theme already fell back to ASCII frames in that case.
            Write-WtLog -Level Debug -Message 'Could not switch the console to UTF-8.' -NoConsole
        }
    }

    if ($State.UseVt)
    {
        $Escape = [char]27
        try
        {
            [Console]::Out.Write("$Escape[?1049h$Escape[?25l$Escape[2J$Escape[H")
            [Console]::Out.Flush()
            $Restore.Entered = $true
        }
        catch
        {
            Write-WtLog -Level Warning -Message "Could not enter the alternate screen: $($_.Exception.Message)" -NoConsole
        }
    }
    else
    {
        try
        {
            [Console]::Clear()
            [Console]::CursorVisible = $false
            $Restore.Entered = $true
        }
        catch
        {
            Write-WtLog -Level Warning -Message "Could not prepare the console: $($_.Exception.Message)" -NoConsole
        }
    }

    return $Restore
}

<#
.SYNOPSIS
    Restores the terminal: alternate buffer, cursor visibility, colour and encoding.
.DESCRIPTION
    Called from the finally block of Start-WtTui, so a normal exit, Ctrl+C and an
    unexpected exception all leave the user's terminal exactly as it was found.
#>
function Restore-WtTuiTerminal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][object]$Restore)

    $Escape = [char]27

    try
    {
        if ($Restore -and $Restore.Entered)
        {
            [Console]::Out.Write("$Escape[0m$Escape[?25h$Escape[?1049l")
            [Console]::Out.Flush()
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'Could not write the terminal reset sequence.' -NoConsole
    }

    try
    {
        [Console]::ResetColor()
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'Could not reset the console colours.' -NoConsole
    }

    try
    {
        [Console]::CursorVisible = if ($Restore) { [bool]$Restore.CursorVisible } else { $true }
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'Could not restore cursor visibility.' -NoConsole
    }

    if ($Restore -and $Restore.ChangedEncoding -and $Restore.OutputEncoding)
    {
        try
        {
            [Console]::OutputEncoding = $Restore.OutputEncoding
        }
        catch
        {
            Write-WtLog -Level Debug -Message 'Could not restore the console encoding.' -NoConsole
        }
    }
}

#endregion Terminal lifecycle

#region Console handoff

<#
.SYNOPSIS
    Releases the console before an interactive child process is launched.
.DESCRIPTION
    A workspace that runs an external console tool must give the terminal back first: the
    alternate screen buffer and the hidden cursor belong to this interface, and leaving them
    in place would leave the user's terminal in a state the child never restores. The
    sequence is the inverse of what Enter-WtTuiTerminal set up, so the terminal the user
    returns to is their own.

    The restore token returned by Enter-WtTuiTerminal stays valid and is still applied by
    the caller that created it (Start-WtTui): this function deliberately does not take a new
    snapshot, because the state it would capture is already "entered" and re-entering would
    restore the wrong cursor visibility at the end.
.OUTPUTS
    A hashtable with Suspended and Vt, to be passed back to Resume-WtTuiConsole.
#>
function Suspend-WtTuiConsole
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    $Result = @{ Suspended = $true; Vt = $false }
    $Escape = [char]27

    try { [Console]::ResetColor() } catch { Write-WtLog -Level Debug -Message 'Could not reset the console colours.' -NoConsole }
    try { [Console]::CursorVisible = $true } catch { Write-WtLog -Level Debug -Message 'Could not show the cursor.' -NoConsole }

    if ($State.UseVt)
    {
        try
        {
            [Console]::Out.Write("$Escape[0m$Escape[?25h$Escape[?1049l")
            [Console]::Out.Flush()
            $Result.Vt = $true
        }
        catch
        {
            Write-WtLog -Level Warning -Message "Could not leave the alternate screen: $($_.Exception.Message)" -NoConsole
        }
    }

    return $Result
}

<#
.SYNOPSIS
    Re-acquires the console after an interactive child process returns.
.DESCRIPTION
    Three things are unknown after a child console process: what the terminal now contains,
    which keys are queued in this console's input buffer, and whether the child left the
    cursor visible. All three are reset here, and the full frame is invalidated so the next
    frame repaints every row instead of a diff against stale content.

    Keys typed while the child had focus are drained with a bound: a console that reports
    keys endlessly (a broken pipe or a scripted input source) must not hang the interface.
#>
function Resume-WtTuiConsole
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][object]$Suspended
    )

    $Escape = [char]27
    $Entered = $Suspended -and $Suspended.Vt

    if ($Entered)
    {
        try
        {
            [Console]::Out.Write("$Escape[?1049h$Escape[?25l$Escape[2J$Escape[H")
            [Console]::Out.Flush()
        }
        catch
        {
            Write-WtLog -Level Warning -Message "Could not re-enter the alternate screen: $($_.Exception.Message)" -NoConsole
        }
    }
    else
    {
        try
        {
            [Console]::Clear()
            [Console]::CursorVisible = $false
        }
        catch
        {
            Write-WtLog -Level Debug -Message 'Could not clear the console after the external tool.' -NoConsole
        }
    }

    $Drained = 0
    try
    {
        while ($Drained -lt 64 -and [Console]::KeyAvailable)
        {
            $null = [Console]::ReadKey($true)
            $Drained++
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'The console input buffer could not be drained.' -NoConsole
    }

    $State.ForceRepaint = $true
    $State.Screen.Dirty = $true
}

#endregion Console handoff

<#
.SYNOPSIS
    Runs the keyboard-driven terminal interface.
.PARAMETER Language
    Initial interface language (en, vi). Switchable at runtime with "L".
.PARAMETER DryRun
    Start with dry-run enabled so nothing is written until it is turned off.
.PARAMETER Colour
    Force a colour depth (Auto, TrueColor, Ansi256, Ansi16, Mono).
.PARAMETER Ascii
    Use ASCII frame characters instead of the Unicode box-drawing set.
.PARAMETER Icons
    Icon display mode: Auto (default), Unicode, NerdFont, ASCII or None. Auto picks
    Unicode when the terminal encoding is UTF-8 and the readable ASCII tags otherwise;
    the saved preference (key I) is honoured for Auto.
.PARAMETER Preset
    Load a preset (name or file path) into the pending set at startup.
.PARAMETER WorkerBackend
    Backend for background work: Auto (default), Go or PowerShell. Only Auto needs the Go
    worker to exist; see docs/WORKER.md.
.PARAMETER InputDiagnostics
    Record every normalised key press and its dispatch target in the structured log
    (never on the screen). Characters typed into a search box, a path field or any other
    text field are masked; named keys and shortcut letters are recorded. Also enabled by
    $env:WT_TUI_INPUT_TRACE = 1.
#>
function Start-WtTui
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][object]$Language,
        [Parameter(Mandatory = $false)][switch]$DryRun,
        [Parameter(Mandatory = $false)][ValidateSet('Auto', 'TrueColor', 'Ansi256', 'Ansi16', 'Mono')][string]$Colour = 'Auto',
        [Parameter(Mandatory = $false)][switch]$Ascii,
        [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Unicode', 'NerdFont', 'ASCII', 'None')][string]$Icons = 'Auto',
        [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Go', 'PowerShell')][string]$WorkerBackend = 'Auto',
        [Parameter(Mandatory = $false)][ValidateSet('Auto', 'Balanced', 'Low-resource')][string]$Profile = 'Auto',
        [Parameter(Mandatory = $false)][string]$Preset,
        [Parameter(Mandatory = $false)][switch]$InputDiagnostics,
        [Parameter(Mandatory = $false)][switch]$PerfDiagnostics
    )

    Initialize-WtLocalization -Language $Language | Out-Null

    # One input path, one diagnostic switch. The trace is a log-only view of the keys the
    # interface receives, which is what makes "the dialog ignores Left/Right" answerable
    # without guessing.
    $Script:WtConsoleInputLost = $false
    $TraceEnabled = [bool]($InputDiagnostics -or ($env:WT_TUI_INPUT_TRACE -match '^(1|true|yes)$'))
    Set-WtInputTrace -Enabled $TraceEnabled

    # Bounded application-side performance diagnostics (steady-state timing of dispatch,
    # handlers, frame construction and frame output). On by request only; it records
    # durations and key names, never typed text.
    $PerfEnabled = [bool]($PerfDiagnostics -or ($env:WT_TUI_PERF_DIAGNOSTICS -match '^(1|true|yes)$'))
    Set-WtTuiPerf -Enabled $PerfEnabled

    if (-not (Test-WtInteractiveConsole))
    {
        Write-Warning -Message (Get-WtString -Key 'Tui.Error.NoTerminal')
        Write-Host (Get-WtString -Key 'Tui.Error.NoTerminalHint')
        return 2
    }

    $State = New-WtTuiState -Language $Language -DryRun:$DryRun -Colour $Colour -Ascii:$Ascii -Icons $Icons -WorkerBackend $WorkerBackend -Profile $Profile
    $Restore = $null

    $CancelHandler = [System.ConsoleCancelEventHandler] {
        param ($CancelSource, $CancelArguments)

        # Ctrl+C never kills the interface mid-frame: the handler asks the loop to stop
        # and the finally block restores the terminal.
        $CancelArguments.Cancel = $true
        $State.Exit = $true
    }

    try
    {
        [Console]::add_CancelKeyPress($CancelHandler)
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'Ctrl+C handling could not be installed.' -NoConsole
    }

    try
    {
        $Restore = Enter-WtTuiTerminal -State $State
        Initialize-WtTuiState -State $State | Out-Null

        if ($Preset)
        {
            Import-WtTuiPreset -State $State -Preset $Preset | Out-Null
        }

        while (-not $State.Exit)
        {
            Invoke-WtTuiLoopStep -State $State
        }
    }
    catch
    {
        Write-WtLog -Level Error -Message 'The terminal interface stopped with an unexpected error.' -Operation 'Tui' -Status 'failed' -Exception $_.Exception
        throw
    }
    finally
    {
        try
        {
            [Console]::remove_CancelKeyPress($CancelHandler)
        }
        catch
        {
            Write-WtLog -Level Debug -Message 'Ctrl+C handling could not be removed.' -NoConsole
        }

        Restore-WtTuiTerminal -Restore $Restore

        # The capability probe enabled ENABLE_VIRTUAL_TERMINAL_PROCESSING on Windows; put
        # the console mode back last, and never let it mask the rest of the cleanup. It is
        # a no-op when nothing was enabled and does not throw.
        try
        {
            [void](Restore-WtConsoleVirtualTerminal)
        }
        catch
        {
            Write-WtLog -Level Debug -Message 'Could not restore the console mode.' -NoConsole
        }

        Close-WtTuiWorker -State $State
    }

    if ($PerfEnabled)
    {
        Write-WtTuiPerfSummary
    }

    return 0
}
