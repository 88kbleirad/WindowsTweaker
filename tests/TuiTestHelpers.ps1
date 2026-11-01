# WindowsTweaker - helpers for the terminal interface tests.
#
# This file is dot-sourced into the *module* session state by tests/Tui.Tests.ps1 (see the
# BeforeAll block), because the interface internals are private on purpose. It is not a
# test file (its name does not end in .Tests.ps1), so Pester never discovers it on its own.
#
# The helpers only build state and inject keys: they never touch the system, and the key
# source they install replaces the real keyboard so the interface can be driven head-lessly.

<#
.SYNOPSIS
    Builds a ConsoleKeyInfo for one named key or one character.
#>
function script:New-WtTestKey
{
    param
    (
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)][string]$Character = ''
    )

    switch ($Name)
    {
        'Up' { return [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::UpArrow, $false, $false, $false) }
        'Down' { return [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::DownArrow, $false, $false, $false) }
        'Left' { return [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::LeftArrow, $false, $false, $false) }
        'Right' { return [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::RightArrow, $false, $false, $false) }
        'Enter' { return [System.ConsoleKeyInfo]::new([char]13, [System.ConsoleKey]::Enter, $false, $false, $false) }
        'Escape' { return [System.ConsoleKeyInfo]::new([char]27, [System.ConsoleKey]::Escape, $false, $false, $false) }
        'Tab' { return [System.ConsoleKeyInfo]::new([char]9, [System.ConsoleKey]::Tab, $false, $false, $false) }
        'BackTab' { return [System.ConsoleKeyInfo]::new([char]9, [System.ConsoleKey]::Tab, $true, $false, $false) }
        'Backspace' { return [System.ConsoleKeyInfo]::new([char]8, [System.ConsoleKey]::Backspace, $false, $false, $false) }
        'Delete' { return [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::Delete, $false, $false, $false) }
        'Home' { return [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::Home, $false, $false, $false) }
        'End' { return [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::End, $false, $false, $false) }
        'PageUp' { return [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::PageUp, $false, $false, $false) }
        'PageDown' { return [System.ConsoleKeyInfo]::new([char]0, [System.ConsoleKey]::PageDown, $false, $false, $false) }
        'Space' { return [System.ConsoleKeyInfo]::new([char]32, [System.ConsoleKey]::Spacebar, $false, $false, $false) }
        default
        {
            $Value = if ($Character) { [char]$Character[0] } else { [char]0 }
            return [System.ConsoleKeyInfo]::new($Value, [System.ConsoleKey]::NoName, $false, $false, $false)
        }
    }
}

<#
.SYNOPSIS
    Builds interface state whose keys and terminal size come from the test.
.DESCRIPTION
    -Keys is a queue of ConsoleKeyInfo values the interface will read instead of the
    keyboard; -Width/-Height can be changed later through $State.Sizes to simulate a resize.
#>
function script:New-WtTestState
{
    param
    (
        [Parameter(Mandatory = $false)][int]$Width = 100,
        [Parameter(Mandatory = $false)][int]$Height = 30,
        [Parameter(Mandatory = $false)][object[]]$Keys = @(),
        [Parameter(Mandatory = $false)][switch]$DryRun,
        [Parameter(Mandatory = $false)][string]$Colour = 'TrueColor',
        [Parameter(Mandatory = $false)][string]$Icons = 'Auto',
        [Parameter(Mandatory = $false)][switch]$Ascii
    )

    $Queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($Key in $Keys)
    {
        $Queue.Enqueue($Key)
    }

    $Sizes = @{ Width = $Width; Height = $Height }

    # GetNewClosure() is required: a plain scriptblock created in the module scope would
    # not see this function's local variables when the interface invokes it later.
    $KeySource = { if ($Queue.Count -eq 0) { return $null }; return $Queue.Dequeue() }.GetNewClosure()
    $SizeSource = { return @{ Width = $Sizes.Width; Height = $Sizes.Height } }.GetNewClosure()

    $State = New-WtTuiState -Language 'en' -Colour $Colour -DryRun:$DryRun -Icons $Icons -Ascii:$Ascii `
        -KeySource $KeySource -SizeSource $SizeSource -Silent

    $State.KeyQueue = $Queue
    $State.Sizes = $Sizes

    return $State
}

<#
.SYNOPSIS
    Sends one key through the normal key pipeline.
#>
function script:Send-WtTestKey
{
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Key
    )

    return (Invoke-WtTuiKey -State $State -Key (ConvertTo-WtKey -Key $Key))
}

<#
.SYNOPSIS
    Sends a whole string as individual character keys.
#>
function script:Send-WtTestText
{
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Text
    )

    foreach ($Character in $Text.ToCharArray())
    {
        Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character ([string]$Character)) | Out-Null
    }
}

<#
.SYNOPSIS
    Makes every tweak look runnable on this host.
.DESCRIPTION
    The interface refuses to queue a tweak the platform reports as unsupported, which is
    every machine-scoped tweak outside Windows. The prerequisite check is therefore doubled
    so selection, dialogs and targeting can be tested without a Windows session; the real
    detection code still runs.
#>
function script:Enable-WtTestSupport
{
    Mock Test-WtPrerequisite {
        param ($Tweak)

        [pscustomobject]@{
            PSTypeName   = 'WindowsTweaker.PrerequisiteResult'
            TweakId      = $Tweak.Id
            Supported    = $true
            Reason       = ''
            Missing      = @()
            Requirements = @()
        }
    }
}

<#
.SYNOPSIS
    Returns a pending entry with the shape Add-WtTuiPending produces.
#>
function script:New-WtTestPending
{
    param
    (
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $false)][string]$Target = 'Enabled',
        [Parameter(Mandatory = $false)][object]$Arguments = $null
    )

    return @{
        Id                = $Entry.Id
        Revision          = [guid]::NewGuid().ToString('n')
        Target            = $Target
        From              = $Entry.State
        Name              = $Entry.Name
        Arguments         = $Arguments
        Risk              = $Entry.Risk
        Restart           = $Entry.Restart
        Rollback          = $Entry.Rollback
        Irreversible      = $Entry.Irreversible
        ReducesProtection = $Entry.ReducesProtection
        Fingerprint       = $null
    }
}
<#
.SYNOPSIS
    Reports which confirmation button is painted as selected in the last frame.
.DESCRIPTION
    The highlight is a style, not a glyph, so it cannot be read from the plain text. This
    reads the style id of every cell and returns 'Yes' or 'No' for the button that carries
    the DialogSelected style - the same information the user sees.
#>
function script:Get-WtTestConfirmSelection
{
    param ([Parameter(Mandatory = $true)][object]$State)

    for ($Row = 0; $Row -lt $State.Screen.Height; $Row++)
    {
        $Line = $State.Screen.Rows[$Row]
        $Selected = [System.Text.StringBuilder]::new()

        for ($Column = 0; $Column -lt $State.Screen.Width; $Column++)
        {
            $Style = $State.Screen.Theme.StyleList[$Line.Styles[$Column]].Name
            if ($Style -eq 'DialogSelected')
            {
                [void]$Selected.Append($Line.Cells[$Column])
            }
        }

        $Text = $Selected.ToString()
        if ($Text -match 'Yes|No')
        {
            if ($Text -match 'Yes') { return 'Yes' }
            if ($Text -match 'No') { return 'No' }
        }
    }

    return ''
}

<#
.SYNOPSIS
    Returns the number of records in the structured log written so far.
#>
function script:Get-WtTestLogCount
{
    $Path = Get-WtLogPath
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-Content -LiteralPath $Path -ErrorAction Ignore).Count
}

<#
.SYNOPSIS
    Returns the log records written after a recorded count.
#>
function script:Get-WtTestLogSince
{
    param ([Parameter(Mandatory = $true)][int]$Count)

    $Path = Get-WtLogPath
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path -ErrorAction Ignore | Select-Object -Skip $Count)
}
