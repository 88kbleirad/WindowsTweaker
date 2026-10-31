# WindowsTweaker - TUI keyboard input.
#
# All key handling goes through this file so the main loop, the dialogs and the tests
# agree on one vocabulary. A key press is normalised to a name plus its character:
#
#   @{ Name = 'Up'|'Down'|'Left'|'Right'|'Enter'|'Escape'|'Tab'|'BackTab'|'Backspace'|
#              'Delete'|'Home'|'End'|'PageUp'|'PageDown'|'Space'|'Control'|'Char';
#      Char = 'a'; Control = $false }
#
# The reader polls instead of blocking so the main loop can notice a window resize and
# a worker that finished while it was waiting for a key.
#
# Two pieces of state live here because they are properties of the input path:
#   WtConsoleInputLost - the console stopped delivering input (closed pty, detached
#                        window). The loop must end instead of polling a dead terminal.
#   WtTuiInputTrace    - opt-in diagnostic: one structured log line per key press with the
#                        normalised key and the target it was dispatched to. Ordinary text
#                        is masked, so a search term or a path never reaches the log.

$Script:WtConsoleInputLost = $false
$Script:WtTuiInputTrace = $false

<#
.SYNOPSIS
    Reads one key press if one is available.
.DESCRIPTION
    Returns $null when no key is pending (after sleeping up to -TimeoutMs) and also when
    the console disappeared, which the caller treats as a reason to shut down cleanly.
#>
function Read-WtConsoleKey
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][int]$TimeoutMs = 40)

    $Deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)

    while ($true)
    {
        try
        {
            if ([Console]::KeyAvailable)
            {
                return [Console]::ReadKey($true)
            }
        }
        catch
        {
            if (-not $Script:WtConsoleInputLost)
            {
                Write-WtLog -Level Warning -Message "Console input is no longer available; the interface will stop instead of polling a dead terminal: $($_.Exception.Message)" -NoConsole
            }

            $Script:WtConsoleInputLost = $true
            return $null
        }

        if ([datetime]::UtcNow -ge $Deadline)
        {
            return $null
        }

        Start-Sleep -Milliseconds 15
    }
}

<#
.SYNOPSIS
    Enables or disables the input diagnostic trace for this process.
.DESCRIPTION
    The trace writes structured log records only; it never paints anything into the
    interface, so enabling it cannot change what the screen looks like.
#>
function Set-WtInputTrace
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][bool]$Enabled)

    $Script:WtTuiInputTrace = $Enabled
}

<#
.SYNOPSIS
    Records one normalised key press and the target it was dispatched to.
.DESCRIPTION
    Named keys (arrows, Enter, Tab, Escape) are always recorded. A character is recorded
    only when the character *is* the command - a global shortcut such as q/l/i, or the y/n
    of a confirmation. Text typed into a search box, a path field or a DNS field is masked,
    so the trace can never leak what the user wrote. Nothing is written unless
    -InputDiagnostics (or WT_TUI_INPUT_TRACE) enabled the trace, and records go to the
    structured log file only - never to the console or the frame.
.PARAMETER Scope
    Who consumed the key: the main loop or a modal dialog.
.PARAMETER Target
    The dispatch target, e.g. 'list', 'search', 'global:q', 'dialog:confirm'.
.PARAMETER Key
    The normalised key object.
.PARAMETER Secret
    Set for keys that belong to a text field: only the fact that a key was consumed is
    recorded, never the character.
#>
function Write-WtInputTrace
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$Scope = 'main',
        [Parameter(Mandatory = $false)][string]$Target = 'ignored',
        [Parameter(Mandatory = $false)][object]$Key,
        [Parameter(Mandatory = $false)][switch]$Secret
    )

    if (-not $Script:WtTuiInputTrace)
    {
        return
    }

    $Name = if ($Key) { [string]$Key.Name } else { 'None' }
    $Character = ''
    if ($Key -and -not $Secret -and $Name -in 'Char', 'Control')
    {
        # A shortcut letter or a confirmation answer is itself the command (and is already
        # visible in the target); everything else stays masked.
        if ($Target -like 'global:*' -or $Target -like 'confirm:*')
        {
            $Character = [string]$Key.Char
        }
    }

    # Level Information so the trace reaches the log file with the default log level; the
    # console mirror stays off, so the interface's rendering is untouched.
    Write-WtLog -Level Information -NoConsole -Message ("input scope={0} key={1} char={2} target={3}" -f
        $Scope, $Name, $(if ($Character) { $Character } else { '-' }), $Target)
}

<#
.SYNOPSIS
    Normalises a ConsoleKeyInfo into the TUI's key vocabulary.
#>
function ConvertTo-WtKey
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][System.ConsoleKeyInfo]$Key)

    $Name = switch ($Key.Key)
    {
        ([System.ConsoleKey]::UpArrow) { 'Up' }
        ([System.ConsoleKey]::DownArrow) { 'Down' }
        ([System.ConsoleKey]::LeftArrow) { 'Left' }
        ([System.ConsoleKey]::RightArrow) { 'Right' }
        ([System.ConsoleKey]::Enter) { 'Enter' }
        ([System.ConsoleKey]::Escape) { 'Escape' }
        ([System.ConsoleKey]::Tab) { if ($Key.Modifiers -band [System.ConsoleModifiers]::Shift) { 'BackTab' } else { 'Tab' } }
        ([System.ConsoleKey]::Backspace) { 'Backspace' }
        ([System.ConsoleKey]::Delete) { 'Delete' }
        ([System.ConsoleKey]::Home) { 'Home' }
        ([System.ConsoleKey]::End) { 'End' }
        ([System.ConsoleKey]::PageUp) { 'PageUp' }
        ([System.ConsoleKey]::PageDown) { 'PageDown' }
        ([System.ConsoleKey]::Spacebar) { 'Space' }
        default { 'Char' }
    }

    $Character = $Key.KeyChar
    if ($Name -eq 'Char')
    {
        if ([char]::IsControl($Character))
        {
            # Ctrl+<letter> arrives as a control character; keep the letter so the main
            # loop can tell Ctrl+C/Ctrl+L apart from text entry.
            $Name = 'Control'
            if ($Character -ge [char]1 -and $Character -le [char]26)
            {
                $Character = [char]([int][char]$Character + 96)
            }
        }
        elseif ($Key.Modifiers -band [System.ConsoleModifiers]::Alt)
        {
            # Alt+<key> is not a shortcut in this interface, so it is dropped rather
            # than treated as text.
            $Name = 'Control'
        }
    }

    return [pscustomobject]@{
        Name    = $Name
        Char    = $Character
        Control = [bool]($Key.Modifiers -band [System.ConsoleModifiers]::Control)
    }
}

<#
.SYNOPSIS
    Creates the editable state of a single-line text field.
#>
function New-WtInputState
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Text = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Label = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Placeholder = ''
    )

    $Initial = ConvertTo-WtDisplayText -Text $Text

    return @{
        Text        = $Initial
        Cursor      = $Initial.Length
        Label       = $Label
        Placeholder = $Placeholder
        Error       = ''
    }
}

<#
.SYNOPSIS
    Applies one key press to a text field.
.DESCRIPTION
    Ordinary letters insert text here and never reach the global shortcuts: the caller
    routes every key to the field while it has focus, which is what keeps "/" usable
    inside a search or a path.
#>
function Update-WtInputState
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Field,
        [Parameter(Mandatory = $true)][object]$Key
    )

    $Text = [string]$Field.Text
    $Cursor = [int]$Field.Cursor
    if ($Cursor -gt $Text.Length) { $Cursor = $Text.Length }
    if ($Cursor -lt 0) { $Cursor = 0 }

    switch ($Key.Name)
    {
        'Backspace'
        {
            if ($Cursor -gt 0)
            {
                $Text = $Text.Remove($Cursor - 1, 1)
                $Cursor--
            }
        }
        'Delete'
        {
            if ($Cursor -lt $Text.Length)
            {
                $Text = $Text.Remove($Cursor, 1)
            }
        }
        'Left'
        {
            if ($Cursor -gt 0) { $Cursor-- }
        }
        'Right'
        {
            if ($Cursor -lt $Text.Length) { $Cursor++ }
        }
        'Home' { $Cursor = 0 }
        'End' { $Cursor = $Text.Length }
        'Space'
        {
            $Text = $Text.Insert($Cursor, ' ')
            $Cursor++
        }
        'Char'
        {
            $Character = [string]$Key.Char
            if ($Character.Length -gt 0)
            {
                $Text = $Text.Insert($Cursor, $Character)
                $Cursor += $Character.Length
            }
        }
        default
        {
            # Navigation keys that do not edit text are ignored here.
        }
    }

    $Field.Text = $Text
    $Field.Cursor = $Cursor
    $Field.Error = ''

    return $Field
}

<#
.SYNOPSIS
    Reports the cell width of one character.
#>
function Get-WtCharWidth
{
    [CmdletBinding()]
    [OutputType([int])]
    param ([Parameter(Mandatory = $true)][char]$Character)

    $Code = [int]$Character

    if ($Code -lt 32)
    {
        return 0
    }

    if (($Code -ge 0x0300 -and $Code -le 0x036F) -or ($Code -ge 0x200B -and $Code -le 0x200F))
    {
        return 0
    }

    if (Test-WtWideCodePoint -CodePoint $Code)
    {
        return 2
    }

    return 1
}

<#
.SYNOPSIS
    Produces the visible part of a text field of a given width.
.DESCRIPTION
    Long paths and search terms scroll instead of being clipped at the start: the text
    before the caret is trimmed from the left, which is what makes editing a long value
    possible at all.
#>
function Get-WtInputView
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Field,
        [Parameter(Mandatory = $true)][int]$Width
    )

    $Text = [string]$Field.Text
    $Cursor = [int]$Field.Cursor

    if ($Cursor -gt $Text.Length) { $Cursor = $Text.Length }
    if ($Cursor -lt 0) { $Cursor = 0 }
    if ($Width -lt 2) { $Width = 2 }

    # Walk left from the caret until the budget for the caret column is used up.
    $Start = $Cursor
    $Used = 0
    while ($Start -gt 0)
    {
        $CharacterWidth = Get-WtCharWidth -Character $Text[$Start - 1]
        if (($Used + $CharacterWidth) -gt ($Width - 1)) { break }
        $Used += $CharacterWidth
        $Start--
    }

    $Before = $Text.Substring($Start, $Cursor - $Start)
    $ScrollMark = ''
    if ($Start -gt 0)
    {
        $ScrollMark = '<'
        $Before = $Before.Substring(1)
    }

    $Under = if ($Cursor -lt $Text.Length) { [string]$Text[$Cursor] } else { ' ' }
    $After = if ($Cursor -lt $Text.Length) { $Text.Substring($Cursor + 1) } else { '' }

    $Remaining = $Width - (Get-WtTextWidth -Text $Before) - 1
    if ($Remaining -lt 0) { $Remaining = 0 }
    $After = Format-WtText -Text $After -Width $Remaining -Ellipsis ''

    return @{ Scroll = $ScrollMark; Before = $Before; Cursor = $Under; After = $After }
}
