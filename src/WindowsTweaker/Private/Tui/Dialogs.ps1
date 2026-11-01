# WindowsTweaker - TUI dialogs.
#
# Dialogs are overlays painted into the same cell grid as the main screen: the
# interface never opens a window, never clears the screen and never leaves the alternate
# screen buffer, so a confirmation looks exactly like the rest of the interface.
#
# Every dialog is driven by the same loop (paint one frame, read one key, handle it),
# which keeps "one UI owner": rendering and terminal input stay in the main runspace
# even while a worker runspace performs the actual change.

<#
.SYNOPSIS
    Builds a normalised overlay descriptor.
.DESCRIPTION
    Every optional field is filled in here so the painter and the key handler can rely
    on a fixed shape (an absent key would otherwise need a guard at each use site).
#>
function New-WtDialogOverlay
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('message', 'confirm', 'text', 'list')][string]$Kind,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Title = '',
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Body = @(),
        [Parameter(Mandatory = $false)][ValidateSet('Default', 'Warning', 'Error', 'Success')][string]$Tone = 'Default',
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Buttons = @(),
        [Parameter(Mandatory = $false)][string]$InputLabel = '',
        [Parameter(Mandatory = $false)][string]$InitialText = '',
        [Parameter(Mandatory = $false)][scriptblock]$Validate,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Items = @(),
        [Parameter(Mandatory = $false)][bool]$Multi = $false,
        [Parameter(Mandatory = $false)][bool]$Searchable = $false,
        [Parameter(Mandatory = $false)][scriptblock]$Details,
        [Parameter(Mandatory = $false)][scriptblock]$OnKey,
        [Parameter(Mandatory = $false)][string]$EmptyText = '',
        [Parameter(Mandatory = $false)][int]$DetailsHeight = 4,
        [Parameter(Mandatory = $false)][string]$Icon = '',
        [Parameter(Mandatory = $false)][scriptblock]$OnExport,
        [Parameter(Mandatory = $false)][scriptblock]$OnCopy,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 0,
        [Parameter(Mandatory = $false)][string]$TimeoutFormat = '',
        [Parameter(Mandatory = $false)][switch]$Countdown,
        [Parameter(Mandatory = $false)][switch]$QuitCancels
    )

    $List = $null
    if ($Kind -eq 'list')
    {
        $List = @{
            Items         = @(Get-WtDialogItem -Items $Items)
            Cursor        = 0
            Offset        = 0
            Multi         = $Multi
            Searchable    = $Searchable
            Search        = ''
            SearchFocus   = $false
            Visible       = @()
            Details       = $Details
            EmptyText     = $EmptyText
            DetailsHeight = $DetailsHeight
        }
    }

    $Field = $null
    if ($Kind -eq 'text')
    {
        $Field = New-WtInputState -Text $InitialText -Label $InputLabel
    }

    # A confirmation carries its choices as an ordered list of values in render order
    # (Yes, then No) and `Confirm` is the index of the highlighted one. Enter returns
    # `Choices[Confirm]`, so the button the user sees highlighted and the value the caller
    # receives cannot drift apart. The default is the last choice (No), which is what keeps
    # a stray Enter from confirming anything.
    $Choices = @()
    if ($Kind -eq 'confirm')
    {
        $Choices = @($true, $false)
    }

    return @{
        Kind      = $Kind
        Title     = $Title
        Icon      = $(if ($Icon) { $Icon } else { Get-WtToneIconKey -Tone $Tone })
        Body      = @($Body)
        Tone      = $Tone
        Buttons   = @($Buttons)
        Field     = $Field
        Validate  = $Validate
        List      = $List
        Choices   = $Choices
        Confirm   = $(if ($Choices.Count -gt 0) { $Choices.Count - 1 } else { 0 })
        Scroll    = 0
        OnKey     = $OnKey
        OnExport  = $OnExport
        OnCopy    = $OnCopy
        Note      = ''
        # Countdown contract: the dialog owns the timer (the OS is never asked to count
        # down), the note line shows the remaining seconds, and the loop ends itself when
        # the time is up. Enter/Space are deliberately inert while a countdown runs.
        TimeoutSeconds = [int]$TimeoutSeconds
        TimeoutFormat  = $TimeoutFormat
        Counting       = [bool]$Countdown
        QuitCancels    = [bool]$QuitCancels
        TimedOut  = $false
        Result    = $null
        Accepted  = $false
        Cancelled = $false
    }
}

<#
.SYNOPSIS
    Normalises list entries so the painter can rely on every field being present.
#>
function Get-WtDialogItem
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Items = @())

    $Normalised = [System.Collections.Generic.List[object]]::new()

    foreach ($Item in $Items)
    {
        if ($null -eq $Item)
        {
            continue
        }

        if ($Item -is [string])
        {
            $Normalised.Add(@{ Label = $Item; Right = ''; Checked = $false; Disabled = $false; Payload = $Item; Filter = $Item; Icon = '' })
            continue
        }

        $Properties = @{}
        if ($Item -is [System.Collections.IDictionary])
        {
            foreach ($Name in $Item.Keys)
            {
                $Properties[[string]$Name] = $Item[$Name]
            }
        }
        else
        {
            foreach ($Property in $Item.PSObject.Properties)
            {
                $Properties[$Property.Name] = $Property.Value
            }
        }

        $Normalised.Add(@{
            Label    = [string](Get-WtDictionaryValue -Dictionary $Properties -Name 'Label')
            Right    = [string](Get-WtDictionaryValue -Dictionary $Properties -Name 'Right')
            Checked  = [bool](Get-WtDictionaryValue -Dictionary $Properties -Name 'Checked')
            Disabled = [bool](Get-WtDictionaryValue -Dictionary $Properties -Name 'Disabled')
            Payload  = Get-WtDictionaryValue -Dictionary $Properties -Name 'Payload'
            Filter   = [string](Get-WtDictionaryValue -Dictionary $Properties -Name 'Filter')
            Icon     = [string](Get-WtDictionaryValue -Dictionary $Properties -Name 'Icon')
        })
    }

    return $Normalised.ToArray()
}

<#
.SYNOPSIS
    Reads one value out of a normalised property table, returning $null when absent.
#>
function Get-WtDictionaryValue
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Dictionary,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Dictionary.ContainsKey($Name))
    {
        return $Dictionary[$Name]
    }

    if ($Dictionary.ContainsKey($Name.ToLowerInvariant()))
    {
        return $Dictionary[$Name.ToLowerInvariant()]
    }

    return $null
}

<#
.SYNOPSIS
    Returns the indexes of the list entries that match the current filter.
#>
function Get-WtDialogVisibleItems
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Overlay)

    $List = $Overlay.List
    $Filter = [string]$List.Search

    if ([string]::IsNullOrWhiteSpace($Filter))
    {
        $All = [System.Collections.Generic.List[int]]::new()
        for ($Index = 0; $Index -lt $List.Items.Count; $Index++)
        {
            $All.Add($Index)
        }

        return $All.ToArray()
    }

    $Matched = [System.Collections.Generic.List[int]]::new()
    for ($Index = 0; $Index -lt $List.Items.Count; $Index++)
    {
        $Item = $List.Items[$Index]
        if ($Item.Label -like "*$Filter*" -or $Item.Filter -like "*$Filter*")
        {
            $Matched.Add($Index)
        }
    }

    return $Matched.ToArray()
}

<#
.SYNOPSIS
    Computes the geometry of the dialog box for the current terminal size.
.DESCRIPTION
    The box is centred and never larger than the screen; on a small terminal it uses the
    available area, which is what keeps the interface usable when the window is resized
    down.
#>
function Get-WtDialogLayout
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][object]$Overlay
    )

    $Width = [math]::Min(96, [math]::Max(24, $Screen.Width - 4))

    $BodyLines = 0
    foreach ($Line in $Overlay.Body)
    {
        $BodyLines += [math]::Max(1, (Format-WtWrappedText -Text $Line -Width ($Width - 4)).Count)
    }

    # rows: 2 borders + body + content + footer hint
    $Height = 3 + $BodyLines

    if ($Overlay.Kind -eq 'text')
    {
        $Height += 4
    }

    if ($Overlay.Kind -eq 'list')
    {
        $List = $Overlay.List
        $Extra = 0
        if ($List.Searchable) { $Extra++ }
        if ($List.Details) { $Extra += 1 + $List.DetailsHeight }
        $Height += 2 + $Extra + [math]::Min(12, [math]::Max(3, $List.Items.Count))
    }

    $Height = [math]::Min($Height, [math]::Max(6, $Screen.Height - 2))
    $Height = [math]::Max($Height, 5)

    $Column = [math]::Floor(($Screen.Width - $Width) / 2) + 1
    $Row = [math]::Floor(($Screen.Height - $Height) / 2) + 1

    if ($Column -lt 1) { $Column = 1 }
    if ($Row -lt 1) { $Row = 1 }

    return @{
        Row       = [int]$Row
        Column    = [int]$Column
        Width     = [int]$Width
        Height    = [int]$Height
        BodyWidth = [int]($Width - 4)
        BodyLines = [int]$BodyLines
    }
}

<#
.SYNOPSIS
    Paints a dialog over the already painted screen.
#>
function Add-WtDialogToScreen
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Screen,
        [Parameter(Mandatory = $true)][object]$Overlay
    )

    $Layout = Get-WtDialogLayout -Screen $Screen -Overlay $Overlay
    $TitleStyle = switch ($Overlay.Tone)
    {
        'Warning' { 'Warning' }
        'Error' { 'Error' }
        'Success' { 'Success' }
        default { 'DialogTitle' }
    }

    Add-WtScreenBox -Screen $Screen -Row $Layout.Row -Column $Layout.Column -Width $Layout.Width -Height $Layout.Height `
        -Title (Format-WtIconLabel -Icons $Screen.Theme.Icons -Key $Overlay.Icon -Label $Overlay.Title) `
        -BorderStyle 'Border' -TitleStyle $TitleStyle -Style 'Dialog'

    $Left = $Layout.Column + 2
    $Row = $Layout.Row + 1
    $Bottom = $Layout.Row + $Layout.Height - 1

    # ---- wrapped body, scrolled when it does not fit --------------------------
    $Body = [System.Collections.Generic.List[string]]::new()
    foreach ($Line in $Overlay.Body)
    {
        foreach ($Wrapped in (Format-WtWrappedText -Text $Line -Width $Layout.BodyWidth))
        {
            $Body.Add($Wrapped)
        }
    }

    $Reserved = switch ($Overlay.Kind)
    {
        'text' { 4 }
        'list' { 2 + $(if ($Overlay.List.Searchable) { 1 } else { 0 }) + $(if ($Overlay.List.Details) { 1 + $Overlay.List.DetailsHeight } else { 0 }) }
        default { 1 }
    }

    $Available = [math]::Max(1, $Layout.Height - 2 - $Reserved)
    $Start = [math]::Max(0, [math]::Min([int]$Overlay.Scroll, [math]::Max(0, $Body.Count - $Available)))
    $Overlay.Scroll = $Start

    for ($Index = 0; $Index -lt $Available; $Index++)
    {
        $LineIndex = $Start + $Index
        if ($LineIndex -ge $Body.Count) { break }
        Set-WtScreenText -Screen $Screen -Row $Row -Column $Left -Text $Body[$LineIndex] -Style 'Dialog' -MaxWidth $Layout.BodyWidth
        $Row++
    }

    # ---- text field ----------------------------------------------------------
    if ($Overlay.Kind -eq 'text')
    {
        $Row++
        $FieldWidth = $Layout.Width - 4
        Set-WtScreenText -Screen $Screen -Row $Row -Column $Left -Text $Overlay.Field.Label -Style 'InputLabel' -MaxWidth $FieldWidth
        $Row++

        $View = Get-WtInputView -Field $Overlay.Field -Width $FieldWidth
        Set-WtScreenRegion -Screen $Screen -Row $Row -Column $Left -Width $FieldWidth -Height 1 -Style 'Input'

        $Column = $Left
        if ($View.Scroll)
        {
            Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text $View.Scroll -Style 'Muted' -MaxWidth 1
            $Column++
        }

        Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text $View.Before -Style 'Input' -MaxWidth $FieldWidth
        $Column += (Get-WtTextWidth -Text $View.Before)
        Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text $View.Cursor -Style 'InputCursor' -MaxWidth 1
        $Column++
        Set-WtScreenText -Screen $Screen -Row $Row -Column $Column -Text $View.After -Style 'Input' -MaxWidth ([math]::Max(0, $Left + $FieldWidth - $Column))

        $Row++
        if ($Overlay.Field.Error)
        {
            Set-WtScreenText -Screen $Screen -Row $Row -Column $Left -Text $Overlay.Field.Error -Style 'Error' -MaxWidth $Layout.BodyWidth
        }
        $Row++
    }

    # ---- list ----------------------------------------------------------------
    if ($Overlay.Kind -eq 'list')
    {
        $List = $Overlay.List
        $Visible = @(Get-WtDialogVisibleItems -Overlay $Overlay)
        $List.Visible = $Visible

        $FooterRows = 2
        if ($List.Searchable) { $FooterRows++ }
        if ($List.Details) { $FooterRows += 1 + $List.DetailsHeight }
        $LastRow = $Bottom - $FooterRows

        if ($Visible.Count -eq 0)
        {
            $Message = if ($List.Search) { Get-WtString -Key 'Tui.NoMatch' } else { $List.EmptyText }
            Set-WtScreenText -Screen $Screen -Row $Row -Column $Left -Text $Message -Style 'Muted' -MaxWidth $Layout.BodyWidth
            $Row++
        }
        else
        {
            $CursorPosition = [array]::IndexOf($Visible, [int]$List.Cursor)
            if ($CursorPosition -lt 0) { $CursorPosition = 0 }

            $Window = [math]::Max(1, $LastRow - $Row + 1)
            $Offset = 0
            if ($CursorPosition -ge $Window) { $Offset = $CursorPosition - $Window + 1 }
            $List.Offset = $Offset

            for ($Index = $Offset; $Index -lt ($Offset + $Window); $Index++)
            {
                if ($Index -ge $Visible.Count) { break }

                $Item = $List.Items[$Visible[$Index]]
                $IsCursor = ($Visible[$Index] -eq [int]$List.Cursor)
                $Style = if ($IsCursor) { 'DialogSelected' } elseif ($Item.Disabled) { 'DialogBlocked' } elseif ($Item.Checked) { 'DialogChecked' } else { 'DialogItem' }

                $Prefix = if ($List.Multi)
                {
                    if ($Item.Checked) { '[x] ' } else { '[ ] ' }
                }
                elseif ($IsCursor)
                {
                    '> '
                }
                else
                {
                    '  '
                }

                $Available = $Layout.BodyWidth - 2
                $RightWidth = if ($Item.Right) { [math]::Min(26, [math]::Max(6, [int]($Available / 3))) } else { 0 }
                $IconPrefix = Format-WtIconPrefix -Icons $Screen.Theme.Icons -Key $Item.Icon
                $IconWidth = Get-WtIconPrefixWidth -Icons $Screen.Theme.Icons -Key $Item.Icon
                $LabelWidth = [math]::Max(4, $Available - $RightWidth - $IconWidth)

                Set-WtScreenRegion -Screen $Screen -Row $Row -Column $Left -Width $Layout.BodyWidth -Height 1 -Style $Style
                Set-WtScreenText -Screen $Screen -Row $Row -Column $Left -Text "$Prefix$IconPrefix$(Format-WtText -Text $Item.Label -Width $LabelWidth)" -Style $Style -MaxWidth $Available

                if ($RightWidth -gt 0)
                {
                    Set-WtScreenText -Screen $Screen -Row $Row -Column ($Left + $Available - $RightWidth) -Text (Format-WtColumn -Text $Item.Right -Width $RightWidth -Align Right) -Style $Style -MaxWidth $RightWidth
                }

                $Row++
            }

            if ($List.Details -and $Row -le $LastRow)
            {
                Add-WtScreenDivider -Screen $Screen -Row $Row -Column $Left -Width $Layout.BodyWidth -GlyphName 'Horizontal' -Style 'Border'
                $Row++
                $DetailLines = @(& $List.Details $List.Items[[int]$List.Cursor])
                $Shown = 0
                foreach ($DetailLine in $DetailLines)
                {
                    if ($Shown -ge $List.DetailsHeight -or $Row -gt $LastRow) { break }
                    Set-WtScreenText -Screen $Screen -Row $Row -Column $Left -Text $DetailLine -Style 'DialogHint' -MaxWidth $Layout.BodyWidth
                    $Row++
                    $Shown++
                }
            }

            if ($List.Searchable -and $Row -le $LastRow)
            {
                $Label = Format-WtIconLabel -Icons $Screen.Theme.Icons -Key 'Action.Search' -Label (Get-WtString -Key 'Tui.Filter')
                Set-WtScreenText -Screen $Screen -Row $Row -Column $Left -Text $Label -Style 'InputLabel' -MaxWidth (Get-WtTextWidth -Text $Label)
                $FieldLeft = $Left + (Get-WtTextWidth -Text $Label) + 1
                $FieldWidth = [math]::Max(4, $Layout.Width - ($FieldLeft - $Layout.Column) - 2)

                if ($List.SearchFocus)
                {
                    $Field = New-WtInputState -Text $List.Search
                    $View = Get-WtInputView -Field $Field -Width $FieldWidth
                    Set-WtScreenRegion -Screen $Screen -Row $Row -Column $FieldLeft -Width $FieldWidth -Height 1 -Style 'Input'
                    Set-WtScreenText -Screen $Screen -Row $Row -Column $FieldLeft -Text $View.Before -Style 'Input' -MaxWidth $FieldWidth
                    $CursorColumn = $FieldLeft + (Get-WtTextWidth -Text $View.Before)
                    Set-WtScreenText -Screen $Screen -Row $Row -Column $CursorColumn -Text $View.Cursor -Style 'InputCursor' -MaxWidth 1
                    Set-WtScreenText -Screen $Screen -Row $Row -Column ($CursorColumn + 1) -Text $View.After -Style 'Input' -MaxWidth ([math]::Max(0, $FieldLeft + $FieldWidth - $CursorColumn - 1))
                }
                else
                {
                    Set-WtScreenText -Screen $Screen -Row $Row -Column $FieldLeft -Text $List.Search -Style 'DialogHint' -MaxWidth $FieldWidth
                }
                $Row++
            }
        }
    }

    # ---- footer --------------------------------------------------------------
    # The footer sits on the last content row: the border row below it stays intact.
    $FooterRow = $Bottom - 1

    if ($Overlay.Kind -eq 'confirm')
    {
        # The choices are painted in the same order the key handler indexes them, and each
        # button spells out its own shortcut so the displayed instructions and the keys that
        # work can never disagree - in either language.
        $Labels = @(
            (Format-WtIconLabel -Icons $Screen.Theme.Icons -Key 'Action.Apply' -Label (Get-WtString -Key 'Tui.Confirm.Yes')),
            (Format-WtIconLabel -Icons $Screen.Theme.Icons -Key 'Action.Cancel' -Label (Get-WtString -Key 'Tui.Confirm.No'))
        )
        $Cursor = $Left
        $Selected = [math]::Max(0, [math]::Min([int]$Overlay.Confirm, $Overlay.Choices.Count - 1))

        for ($Index = 0; $Index -lt $Overlay.Choices.Count; $Index++)
        {
            $Label = if ($Index -lt $Labels.Count) { $Labels[$Index] } else { '' }
            $Style = if ($Index -eq $Selected) { 'DialogSelected' } else { 'DialogItem' }
            $Text = " $Label "
            Set-WtScreenText -Screen $Screen -Row $FooterRow -Column $Cursor -Text $Text -Style $Style -MaxWidth (Get-WtTextWidth -Text $Text)
            $Cursor += (Get-WtTextWidth -Text $Text) + 2
        }

        if ($Overlay.Buttons.Count -gt 0)
        {
            $Remaining = $Layout.Width - ($Cursor - $Layout.Column) - 2
            if ($Remaining -gt 8)
            {
                Set-WtScreenText -Screen $Screen -Row $FooterRow -Column $Cursor -Text (Format-WtText -Text ($Overlay.Buttons -join '   ') -Width $Remaining) -Style 'DialogHint' -MaxWidth $Remaining
            }
        }
        return
    }

    if ($Overlay.Buttons.Count -gt 0)
    {
        Set-WtScreenText -Screen $Screen -Row $FooterRow -Column $Left -Text (Format-WtText -Text ($Overlay.Buttons -join '   ') -Width $Layout.BodyWidth) -Style 'DialogHint' -MaxWidth $Layout.BodyWidth
    }

    if ($Overlay.Note)
    {
        Set-WtScreenText -Screen $Screen -Row $Bottom -Column $Left -Text (Format-WtText -Text $Overlay.Note -Width ($Layout.Width - 4)) -Style 'DialogHint' -MaxWidth ($Layout.Width - 4)
    }
}

<#
.SYNOPSIS
    Runs a dialog until it is accepted or cancelled.
.DESCRIPTION
    The returned value is the dialog's result: $true/$false for a confirmation, the text
    for an input, and a result object for a list.
#>
function Show-WtTuiDialog
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Overlay
    )

    $State.Overlay = $Overlay
    $State.Screen.Dirty = $true

    # The countdown lives here, inside the application: the remaining seconds are painted
    # into the note line (only when the displayed value changes, so differential rendering
    # repaints one row per second), and the loop ends itself when it reaches zero. Nothing
    # is scheduled with the operating system while the countdown runs.
    $Deadline = if ($Overlay.Counting) { [datetime]::UtcNow.AddSeconds([math]::Max(0, [int]$Overlay.TimeoutSeconds)) } else { $null }
    $Shown = -1

    try
    {
        while (-not ($Overlay.Accepted -or $Overlay.Cancelled))
        {
            if ($Deadline)
            {
                $Remaining = [int][math]::Ceiling(($Deadline - [datetime]::UtcNow).TotalSeconds)
                if ($Remaining -lt 0) { $Remaining = 0 }

                if ($Remaining -ne $Shown)
                {
                    $Shown = $Remaining
                    if ($Overlay.TimeoutFormat)
                    {
                        $Overlay.Note = [string]::Format($Overlay.TimeoutFormat, $Remaining)
                    }
                    $State.Screen.Dirty = $true
                }

                if ($Remaining -le 0)
                {
                    $Overlay.TimedOut = $true
                    $Overlay.Accepted = $true
                    break
                }
            }

            $Key = Invoke-WtTuiFrame -State $State
            if ($null -eq $Key)
            {
                if ($State.Exit)
                {
                    # A quit while a countdown runs cancels it: the restart must never be
                    # left behind by an interface that is going away.
                    $Overlay.Cancelled = $true
                    return $null
                }

                continue
            }

            Read-WtDialogKey -Overlay $Overlay -Key $Key -State $State

            # The dialog owns the keyboard while it is open: record the target so a trace can
            # show that a key reached the dialog (and that no global shortcut stole it).
            # Text fields are secrets by definition and never record the character.
            $Secret = $Overlay.Kind -eq 'text' -or ($Overlay.Kind -eq 'list' -and $Overlay.List.SearchFocus)
            Write-WtInputTrace -Scope 'dialog' -Key $Key -Target ("dialog:" + $Overlay.Kind) -Secret:$Secret
        }
    }
    finally
    {
        $State.Overlay = $null
        $State.Screen.Dirty = $true
    }

    return $Overlay.Result
}

<#
.SYNOPSIS
    Applies one key press to a dialog.
#>
function Read-WtDialogKey
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Overlay,
        [Parameter(Mandatory = $true)][object]$Key,
        [Parameter(Mandatory = $false)][object]$State
    )

    # Every branch below only mutates the overlay. The state is needed for one thing: a
    # dialog repaints after each key it consumes, and the frame loop only repaints when the
    # grid is marked dirty. Without this the highlight moved but the screen never showed it,
    # which is what made Left/Right look dead in a real terminal.
    switch ($Overlay.Kind)
    {
        'message'
        {
            # During a countdown the only decisions are "wait" and "cancel": Enter and
            # Space are inert so a key pressed out of habit cannot restart the machine
            # earlier than the countdown the user already agreed to.
            $Counting = [bool]$Overlay.Counting

            switch ($Key.Name)
            {
                'Up' { $Overlay.Scroll = [math]::Max(0, $Overlay.Scroll - 1) }
                'Down' { $Overlay.Scroll = $Overlay.Scroll + 1 }
                'PageUp' { $Overlay.Scroll = [math]::Max(0, $Overlay.Scroll - 8) }
                'PageDown' { $Overlay.Scroll = $Overlay.Scroll + 8 }
                'Home' { $Overlay.Scroll = 0 }
                'End' { $Overlay.Scroll = 2147483647 }
                'Enter'
                {
                    if (-not $Counting) { $Overlay.Accepted = $true; $Overlay.Result = $true }
                }
                'Space'
                {
                    if (-not $Counting) { $Overlay.Accepted = $true; $Overlay.Result = $true }
                }
                'Escape' { $Overlay.Cancelled = $true; $Overlay.Result = $null }
                'Char'
                {
                    $Character = ([string]$Key.Char).ToLowerInvariant()
                    if ($Counting -and $Character -eq 'q' -and $Overlay.QuitCancels)
                    {
                        $Overlay.Cancelled = $true
                        $Overlay.Result = 'quit'
                    }
                    elseif (-not $Counting -and $Character -eq 'e' -and $Overlay.OnExport)
                    {
                        $Overlay.Note = [string](& $Overlay.OnExport $Overlay)
                    }
                    elseif (-not $Counting -and $Character -eq 'c' -and $Overlay.OnCopy)
                    {
                        $Overlay.Note = [string](& $Overlay.OnCopy $Overlay)
                    }
                }
                default { }
            }
        }

        'confirm'
        {
            $Count = @($Overlay.Choices).Count
            if ($Count -lt 1)
            {
                # A confirmation without choices cannot be answered: cancel instead of
                # pretending an Enter did something.
                $Overlay.Cancelled = $true
                $Overlay.Result = $null
                break
            }

            $Selected = [math]::Max(0, [math]::Min([int]$Overlay.Confirm, $Count - 1))

            switch ($Key.Name)
            {
                # Left/Right and Tab/Shift+Tab all cycle the highlight, wrapping at the ends,
                # so a two-choice confirmation and a longer one behave the same way.
                'Left' { $Overlay.Confirm = ($Selected + $Count - 1) % $Count }
                'BackTab' { $Overlay.Confirm = ($Selected + $Count - 1) % $Count }
                'Right' { $Overlay.Confirm = ($Selected + 1) % $Count }
                'Tab' { $Overlay.Confirm = ($Selected + 1) % $Count }
                'Enter'
                {
                    # The value comes from the same ordered list the painter draws, so the
                    # highlighted button is always the answer.
                    $Overlay.Accepted = $true
                    $Overlay.Result = $Overlay.Choices[$Selected]
                }
                'Escape'
                {
                    $Overlay.Cancelled = $true
                    $Overlay.Result = $null
                }
                'Char'
                {
                    # Y/N are fixed across languages (the buttons say "Yes [Y]" / "No [N]");
                    # pressing one accepts immediately and also moves the highlight to the
                    # button it stands for, so the two can never disagree visually.
                    $Character = ([string]$Key.Char).ToLowerInvariant()
                    if ($Character -eq 'y' -or $Character -eq 'n')
                    {
                        $Index = 0
                        for ($Position = 0; $Position -lt $Count; $Position++)
                        {
                            if ([bool]$Overlay.Choices[$Position] -eq ($Character -eq 'y'))
                            {
                                $Index = $Position
                                break
                            }
                        }

                        $Overlay.Confirm = $Index
                        $Overlay.Accepted = $true
                        $Overlay.Result = $Overlay.Choices[$Index]
                    }
                }
                default { }
            }
        }

        'text'
        {
            switch ($Key.Name)
            {
                'Enter'
                {
                    $Problem = ''
                    if ($Overlay.Validate)
                    {
                        $Problem = [string](& $Overlay.Validate ([string]$Overlay.Field.Text))
                    }

                    if ($Problem)
                    {
                        $Overlay.Field.Error = $Problem
                    }
                    else
                    {
                        $Overlay.Accepted = $true
                        $Overlay.Result = [string]$Overlay.Field.Text
                    }
                }
                'Escape'
                {
                    $Overlay.Cancelled = $true
                    $Overlay.Result = $null
                }
                default
                {
                    Update-WtInputState -Field $Overlay.Field -Key $Key | Out-Null
                }
            }
        }

        'list'
        {
            Read-WtDialogListKey -Overlay $Overlay -Key $Key
        }

        default
        {
            $Overlay.Accepted = $true
        }
    }

    if ($State)
    {
        $State.Screen.Dirty = $true
    }
}

<#
.SYNOPSIS
    Applies one key press to a list dialog.
#>
function Read-WtDialogListKey
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Overlay,
        [Parameter(Mandatory = $true)][object]$Key
    )

    $List = $Overlay.List

    if ($List.SearchFocus)
    {
        switch ($Key.Name)
        {
            'Enter' { $List.SearchFocus = $false }
            'Escape'
            {
                $List.SearchFocus = $false
                $List.Search = ''
            }
            'Backspace'
            {
                if ($List.Search.Length -gt 0)
                {
                    $List.Search = $List.Search.Substring(0, $List.Search.Length - 1)
                }
            }
            'Space' { $List.Search = [string]$List.Search + ' ' }
            'Char' { $List.Search = [string]$List.Search + [string]$Key.Char }
            default { }
        }

        $VisibleItems = @(Get-WtDialogVisibleItems -Overlay $Overlay)
        if ($VisibleItems.Count -gt 0 -and $VisibleItems -notcontains [int]$List.Cursor)
        {
            $List.Cursor = $VisibleItems[0]
        }

        return
    }

    if ($Overlay.OnKey)
    {
        # Interface-specific shortcuts (export a report, change the objective, remove a pending
        # row) are offered only when the filter box does not have the keyboard: a letter typed
        # into a search field is text, never a shortcut. This runs before the generic navigation
        # below so the handler claims the key explicitly, and Left/Right stay available to it
        # because the list itself does not use them.
        $Handled = [bool](& $Overlay.OnKey $Overlay $Key)
        if ($Handled)
        {
            # A handler that returns something returns an action, and it is wrapped in the same
            # result shape the ordinary selection paths produce: a list dialog has exactly one
            # result contract, so a caller reads `$Result.Value` whichever way the dialog ended.
            # A handler that returns nothing (a row removed, the view finished) keeps $null, which
            # is what "accepted with nothing selected" and "cancelled" already mean elsewhere.
            if ($null -ne $Overlay.Result)
            {
                $Overlay.Result = New-WtListResult -Value $Overlay.Result -Selected @() -Multi $false
            }

            return
        }
    }

    $VisibleItems = @(Get-WtDialogVisibleItems -Overlay $Overlay)
    $Position = [array]::IndexOf($VisibleItems, [int]$List.Cursor)
    if ($Position -lt 0) { $Position = 0 }

    switch ($Key.Name)
    {
        'Up'
        {
            if ($Position -gt 0) { $List.Cursor = $VisibleItems[$Position - 1] }
        }
        'Down'
        {
            if ($Position -lt ($VisibleItems.Count - 1)) { $List.Cursor = $VisibleItems[$Position + 1] }
        }
        'PageUp'
        {
            if ($VisibleItems.Count -gt 0) { $List.Cursor = $VisibleItems[[math]::Max(0, $Position - 8)] }
        }
        'PageDown'
        {
            if ($VisibleItems.Count -gt 0) { $List.Cursor = $VisibleItems[[math]::Min($VisibleItems.Count - 1, $Position + 8)] }
        }
        'Home'
        {
            if ($VisibleItems.Count -gt 0) { $List.Cursor = $VisibleItems[0] }
        }
        'End'
        {
            if ($VisibleItems.Count -gt 0) { $List.Cursor = $VisibleItems[$VisibleItems.Count - 1] }
        }
        'Space'
        {
            if ($VisibleItems.Count -eq 0) { break }

            $Item = $List.Items[[int]$List.Cursor]
            if ($List.Multi)
            {
                if (-not $Item.Disabled)
                {
                    $Item.Checked = -not $Item.Checked
                }

                if ($Position -lt ($VisibleItems.Count - 1)) { $List.Cursor = $VisibleItems[$Position + 1] }
            }
            else
            {
                $Overlay.Accepted = $true
                $Overlay.Result = New-WtListResult -Value $Item.Payload -Selected @($Item.Payload) -Multi $false
            }
        }
        'Enter'
        {
            $Overlay.Accepted = $true

            if ($List.Multi)
            {
                $Selected = [System.Collections.Generic.List[object]]::new()
                foreach ($Item in $List.Items)
                {
                    if ($Item.Checked) { $Selected.Add($Item.Payload) }
                }
                $Overlay.Result = New-WtListResult -Value $null -Selected $Selected.ToArray() -Multi $true
            }
            elseif ($VisibleItems.Count -gt 0)
            {
                $Payload = $List.Items[[int]$List.Cursor].Payload
                $Overlay.Result = New-WtListResult -Value $Payload -Selected @($Payload) -Multi $false
            }
            else
            {
                $Overlay.Result = New-WtListResult -Value $null -Selected @() -Multi $false
            }
        }
        'Escape'
        {
            $Overlay.Cancelled = $true
            $Overlay.Result = $null
        }
        'Char'
        {
            if ($List.Searchable -and [string]$Key.Char -eq '/')
            {
                $List.SearchFocus = $true
            }
        }
        default { }
    }
}

<#
.SYNOPSIS
    Wraps a list result in one object so "accepted with nothing selected" and
    "cancelled" stay distinguishable ($null means cancelled).
#>
function New-WtListResult
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][object]$Value,
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Selected = @(),
        [Parameter(Mandatory = $false)][bool]$Multi = $false
    )

    return [pscustomobject]@{
        Value    = $Value
        Selected = @($Selected)
        Multi    = $Multi
    }
}

#region Dialog helpers

<#
.SYNOPSIS
    Shows a message panel and waits for Enter, Space or Esc.
#>
function Show-WtTuiMessage
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Title = '',
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory = $false)][ValidateSet('Default', 'Warning', 'Error', 'Success')][string]$Tone = 'Default',
        [Parameter(Mandatory = $false)][string]$Icon = '',
        [Parameter(Mandatory = $false)][scriptblock]$OnExport,
        [Parameter(Mandatory = $false)][scriptblock]$OnCopy
    )

    $Buttons = @((Get-WtString -Key 'Tui.CloseHint'))
    if ($OnExport -or $OnCopy)
    {
        $Buttons += Get-WtString -Key 'Tui.Result.Hint'
    }

    $Overlay = New-WtDialogOverlay -Kind 'message' -Title $Title -Body $Lines -Tone $Tone -Icon $Icon -Buttons $Buttons -OnExport $OnExport -OnCopy $OnCopy
    $null = Show-WtTuiDialog -State $State -Overlay $Overlay
    return
}

<#
.SYNOPSIS
    Asks a yes/no question. The default highlight is "No" so a stray Enter never
    confirms a change.
#>
function Confirm-WtTui
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Title = '',
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory = $false)][ValidateSet('Default', 'Warning', 'Error', 'Success')][string]$Tone = 'Warning',
        [Parameter(Mandatory = $false)][string]$Icon = ''
    )

    $Overlay = New-WtDialogOverlay -Kind 'confirm' -Title $Title -Body $Lines -Tone $Tone -Icon $Icon -Buttons @((Get-WtString -Key 'Tui.ConfirmHint'))
    return [bool](Show-WtTuiDialog -State $State -Overlay $Overlay)
}

<#
.SYNOPSIS
    Reads a single line of text, validating it before accepting.
.PARAMETER Validate
    Receives the entered text and returns an error message, or '' when it is acceptable.
#>
function Read-WtTuiText
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Title = '',
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory = $false)][string]$Label = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Initial = '',
        [Parameter(Mandatory = $false)][scriptblock]$Validate
    )

    $Overlay = New-WtDialogOverlay -Kind 'text' -Title $Title -Body $Lines -InputLabel $Label -InitialText $Initial -Validate $Validate -Buttons @((Get-WtString -Key 'Tui.TextHint'))
    return (Show-WtTuiDialog -State $State -Overlay $Overlay)
}

<#
.SYNOPSIS
    Shows a selectable list and returns a result object (or $null when cancelled).
.DESCRIPTION
    Single-selection lists expose the chosen payload as `Value`; multi-selection lists
    expose the ticked payloads as `Selected` (possibly empty when the user accepts
    without ticking anything).
#>
function Select-WtTuiItem
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Title = '',
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][string[]]$Lines = @(),
        [Parameter(Mandatory = $false)][AllowEmptyCollection()][object[]]$Items = @(),
        [Parameter(Mandatory = $false)][switch]$Multi,
        [Parameter(Mandatory = $false)][switch]$Searchable,
        [Parameter(Mandatory = $false)][scriptblock]$Details,
        [Parameter(Mandatory = $false)][scriptblock]$OnKey,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$EmptyText = '',
        [Parameter(Mandatory = $false)][int]$DetailsHeight = 4
    )

    if (-not $EmptyText) { $EmptyText = Get-WtString -Key 'Tui.NoItems' }

    $Overlay = New-WtDialogOverlay -Kind 'list' -Title $Title -Body $Lines -Items $Items -Multi:$Multi -Searchable:$Searchable `
        -Details $Details -OnKey $OnKey -EmptyText $EmptyText -DetailsHeight $DetailsHeight -Buttons @((Get-WtString -Key 'Tui.ListHint'))

    return (Show-WtTuiDialog -State $State -Overlay $Overlay)
}

#endregion Dialog helpers
