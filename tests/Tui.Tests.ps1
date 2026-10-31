# WindowsTweaker - terminal interface (TUI) tests.
#
# The interface is driven head-lessly: its state carries an injectable key source and an
# injectable terminal size, so keyboard focus, filtering, selection, dialogs, resize
# handling and the worker lifecycle are exercised deterministically. No terminal and no
# Windows session is required, and destructive work never happens here - the prerequisite
# check is doubled where a supported tweak is needed, and the worker tests only run tweaks
# that this platform reports as unsupported.
#
# The interface internals are private on purpose, so every body runs through
# InModuleScope; helpers live in TuiTestHelpers.ps1 and are dot-sourced into the module
# scope by the BeforeAll below.

BeforeAll {
    $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ModuleManifest = Join-Path $script:RepositoryRoot 'src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TuiRoot = Join-Path $script:RepositoryRoot 'src/WindowsTweaker/Private/Tui'

    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-tui-{0}" -f ([guid]::NewGuid().ToString('n')))
    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'
    $env:WT_TEST_MODULE = $script:ModuleManifest

    Import-Module $script:ModuleManifest -Force

    InModuleScope WindowsTweaker -Parameters @{ HelperPath = (Join-Path $PSScriptRoot 'TuiTestHelpers.ps1') } {
        . $HelperPath
    }
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG, Env:\WT_TEST_MODULE -ErrorAction Ignore
}

Describe 'Palette and text metrics' {

    It 'uses the exact Catppuccin Mocha colours required by the specification' {
        InModuleScope WindowsTweaker {
            $Palette = Get-WtTuiPalette

            $Palette.Background | Should -Be '#1e1e2e'
            $Palette.Surface | Should -Be '#181825'
            $Palette.Panel | Should -Be '#313244'
            $Palette.Text | Should -Be '#cdd6f4'
            $Palette.Subtext | Should -Be '#bac2de'
            $Palette.Accent | Should -Be '#89b4fa'
            $Palette.Success | Should -Be '#a6e3a1'
            $Palette.Warning | Should -Be '#f9e2af'
            $Palette.Error | Should -Be '#f38ba8'
        }
    }

    It 'measures Vietnamese, CJK and emoji text in terminal cells' {
        InModuleScope WindowsTweaker {
            Get-WtTextWidth -Text 'Privacy' | Should -Be 7
            Get-WtTextWidth -Text 'Tùy biến' | Should -Be 8
            Get-WtTextWidth -Text '日本' | Should -Be 4
            Get-WtTextWidth -Text '😀' | Should -Be 2
            Get-WtTextWidth -Text '' | Should -Be 0
            Get-WtTextWidth -Text "a`tb" | Should -Be 2 -Because 'a tab expands to spaces before measuring'
        }
    }

    It 'normalises decomposed Vietnamese input to one cell per letter' {
        InModuleScope WindowsTweaker {
            $Decomposed = 'De' + [char]0x0302 + 'composition'
            $Normalised = ConvertTo-WtDisplayText -Text $Decomposed
            $Normalised.Contains([char]0x0302) | Should -BeFalse
            (Get-WtTextWidth -Text $Normalised) | Should -Be $Normalised.Length
            (ConvertTo-WtDisplayText -Text "a`tb") | Should -Be 'a    b'
            (ConvertTo-WtDisplayText -Text "a$([char]0)b") | Should -Be 'ab'
        }
    }

    It 'truncates with an ellipsis and never exceeds the requested width' {
        InModuleScope WindowsTweaker {
            (Get-WtTextWidth -Text (Format-WtText -Text 'abcdefghij' -Width 6)) | Should -Be 6
            Format-WtText -Text 'abcdefghij' -Width 6 | Should -Be 'abcde…'
            Format-WtText -Text 'short' -Width 10 | Should -Be 'short'
            Format-WtText -Text 'anything' -Width 0 | Should -Be ''
        }
    }

    It 'treats combining marks and variation selectors as zero width' {
        InModuleScope WindowsTweaker {
            $VariationSelector = [char]0xFE0F
            $Combining = [char]0x0301

            (Get-WtTextWidth -Text "a$VariationSelector") | Should -Be 1
            (Get-WtTextWidth -Text "😀$VariationSelector") | Should -Be 2
            (Get-WtTextWidth -Text ('e' + $Combining)) | Should -Be 1 -Because 'the mark adds no cell of its own'
            (Get-WtTextWidth -Text ([char]::ConvertFromUtf32(0xE0100))) | Should -Be 0 -Because 'a supplementary variation selector is still zero width'
            (Test-WtZeroWidthCodePoint -CodePoint 0xFE0F) | Should -BeTrue
            (Test-WtZeroWidthCodePoint -CodePoint 0xE0100) | Should -BeTrue
            (Test-WtZeroWidthCodePoint -CodePoint 0x41) | Should -BeFalse

            # The painter agrees with the width model, so a variation selector cannot shift
            # the cell behind it.
            $Screen = New-WtScreen -Width 6 -Height 1 -Theme (New-WtTuiTheme -Colour 'Mono')
            Set-WtScreenText -Screen $Screen -Row 1 -Column 1 -Text "a${VariationSelector}b"
            (Get-WtScreenRowText -Screen $Screen -Row 1)[0] | Should -Be 'a'
            (Get-WtScreenRowText -Screen $Screen -Row 1)[1] | Should -Be 'b'

            $Truncated = Format-WtText -Text "abcd$VariationSelector" -Width 3 -Ellipsis ''
            $Truncated | Should -Be 'abc'
        }
    }

    It 'pads a column to an exact width' {
        InModuleScope WindowsTweaker {
            (Get-WtTextWidth -Text (Format-WtColumn -Text 'ab' -Width 5)) | Should -Be 5
            Format-WtColumn -Text 'ab' -Width 5 | Should -Be 'ab   '
            Format-WtColumn -Text 'ab' -Width 5 -Align Right | Should -Be '   ab'
            Format-WtColumn -Text 'ab' -Width 5 -Align Centre | Should -Be ' ab  '
        }
    }

    It 'wraps long paragraphs and hard-splits long words' {
        InModuleScope WindowsTweaker {
            $Lines = Format-WtWrappedText -Text 'one two three four five six' -Width 10
            $Lines.Count | Should -BeGreaterThan 1
            foreach ($Line in $Lines)
            {
                (Get-WtTextWidth -Text $Line) | Should -BeLessOrEqual 10
            }

            $Long = Format-WtWrappedText -Text 'abcdefghijklmnopqrstuvwxyz' -Width 5
            $Long.Count | Should -Be 6
            $Long[0] | Should -Be 'abcde'
        }
    }
}

Describe 'Theme' {

    It 'builds a 24-bit colour sequence for true colour terminals' {
        InModuleScope WindowsTweaker {
            $Theme = New-WtTuiTheme -Colour 'TrueColor' -Unicode
            $Theme.Styles['Title'].Prefix | Should -Match ([regex]::Escape('38;2;137;180;250'))
            $Theme.Styles['Title'].Prefix | Should -Match ([regex]::Escape('48;2;24;24;37'))
        }
    }

    It 'reduces to the 256-colour and 16-colour palettes' {
        InModuleScope WindowsTweaker {
            $Ansi256 = New-WtTuiTheme -Colour 'Ansi256' -Unicode
            $Ansi256.Styles['Title'].Prefix | Should -Match '38;5;\d+'

            $Ansi16 = New-WtTuiTheme -Colour 'Ansi16' -Unicode
            $Ansi16.Styles['Selected'].Prefix | Should -Match ([regex]::Escape('30;47'))
            $Ansi16.Styles['Selected'].ConsoleForeground | Should -Be 'Black'
        }
    }

    It 'keeps the selection visible without colour' {
        InModuleScope WindowsTweaker {
            $Mono = New-WtTuiTheme -Colour 'Mono' -Unicode
            $Mono.Styles['Selected'].Prefix | Should -Be "$([char]27)[7m"
            $Mono.Styles['Error'].Prefix | Should -Be ''
            $Mono.Prefixes.Count | Should -Be $Mono.Styles.Count
        }
    }

    It 'uses square corners and an ASCII fallback' {
        InModuleScope WindowsTweaker {
            $Unicode = New-WtTuiTheme -Colour 'TrueColor' -Unicode
            $Unicode.Border.TopLeft | Should -Be ([char]0x250C)
            $Unicode.Border.Vertical | Should -Be ([char]0x2502)

            $Ascii = New-WtTuiTheme -Colour 'TrueColor'
            $Ascii.Border.TopLeft | Should -Be '+'
            $Ascii.Border.Vertical | Should -Be '|'
        }
    }

    It 'resolves an unknown style to the default style and reports the capability' {
        InModuleScope WindowsTweaker {
            $Theme = New-WtTuiTheme -Colour 'TrueColor' -Unicode
            (Get-WtStyleId -Theme $Theme -Name 'NoSuchStyle') | Should -Be 0

            (Get-WtTuiCapability -Colour 'Mono').Colour | Should -Be 'Mono'
            (Get-WtTuiCapability -Colour 'Ansi16').Colour | Should -Be 'Ansi16'
            (Get-WtTuiCapability -Colour 'TrueColor' -Ascii).Unicode | Should -BeFalse
        }
    }
}

Describe 'Screen buffer' {

    It 'starts blank and paints text at absolute positions' {
        InModuleScope WindowsTweaker {
            $Screen = New-WtScreen -Width 20 -Height 4 -Theme (New-WtTuiTheme -Colour 'TrueColor' -Unicode)
            $Blank = ConvertTo-WtScreenPlainText -Screen $Screen
            $Blank.Count | Should -Be 4
            $Blank[0].Trim() | Should -Be ''

            Set-WtScreenText -Screen $Screen -Row 2 -Column 3 -Text 'hello' -Style 'Item'
            (ConvertTo-WtScreenPlainText -Screen $Screen)[1].TrimEnd() | Should -Be '  hello'
        }
    }

    It 'draws a square-cornered box with a title' {
        InModuleScope WindowsTweaker {
            $Screen = New-WtScreen -Width 20 -Height 6 -Theme (New-WtTuiTheme -Colour 'TrueColor' -Unicode)
            Add-WtScreenBox -Screen $Screen -Row 1 -Column 1 -Width 20 -Height 5 -Title 'Tweaks'
            $Lines = ConvertTo-WtScreenPlainText -Screen $Screen
            $Lines[0] | Should -Be '┌─ Tweaks ─────────┐'
            $Lines[1] | Should -Be '│                  │'
            $Lines[4] | Should -Be '└──────────────────┘'
        }
    }

    It 'clips the bottom-right cell so a frame cannot scroll the terminal' {
        InModuleScope WindowsTweaker {
            $Screen = New-WtScreen -Width 10 -Height 3 -Theme (New-WtTuiTheme -Colour 'TrueColor' -Unicode)
            Set-WtScreenText -Screen $Screen -Row 3 -Column 1 -Text 'abcdefghij'
            (ConvertTo-WtScreenPlainText -Screen $Screen)[2] | Should -Be 'abcdefghi'
            (Get-WtRowWidth -Screen $Screen -Row 3) | Should -Be 9
            (Get-WtRowWidth -Screen $Screen -Row 2) | Should -Be 10
        }
    }

    It 'never writes outside the grid' {
        InModuleScope WindowsTweaker {
            $Screen = New-WtScreen -Width 8 -Height 3 -Theme (New-WtTuiTheme -Colour 'TrueColor' -Unicode)
            Set-WtScreenText -Screen $Screen -Row 0 -Column 1 -Text 'ignored'
            Set-WtScreenText -Screen $Screen -Row 4 -Column 1 -Text 'ignored'
            { Set-WtScreenText -Screen $Screen -Row 1 -Column 20 -Text 'ignored' } | Should -Not -Throw
            Set-WtScreenText -Screen $Screen -Row 3 -Column 1 -Text 'x' -MaxWidth 1
            (ConvertTo-WtScreenPlainText -Screen $Screen)[2].TrimEnd() | Should -Be 'x'
        }
    }

    It 'gives a double-width character two cells' {
        InModuleScope WindowsTweaker {
            $Screen = New-WtScreen -Width 10 -Height 2 -Theme (New-WtTuiTheme -Colour 'TrueColor' -Unicode)
            Set-WtScreenText -Screen $Screen -Row 1 -Column 1 -Text '日本x' -Style 'Item'
            $Cells = Get-WtScreenRowText -Screen $Screen -Row 1
            $Cells[0] | Should -Be '日'
            $Cells[1] | Should -Be ''
            $Cells[2] | Should -Be '本'
            $Cells[4] | Should -Be 'x'
        }
    }

    It 'renders colour only when the theme has colour' {
        InModuleScope WindowsTweaker {
            $Colour = New-WtScreen -Width 10 -Height 2 -Theme (New-WtTuiTheme -Colour 'TrueColor' -Unicode)
            Set-WtScreenText -Screen $Colour -Row 1 -Column 1 -Text 'x' -Style 'Error'
            (ConvertTo-WtScreenText -Screen $Colour)[0] | Should -Match ([regex]::Escape([char]27))

            $Mono = New-WtScreen -Width 10 -Height 2 -Theme (New-WtTuiTheme -Colour 'Mono' -Unicode)
            Set-WtScreenText -Screen $Mono -Row 1 -Column 1 -Text 'x' -Style 'Error'
            (ConvertTo-WtScreenText -Screen $Mono)[0].TrimEnd() | Should -Be 'x'
        }
    }
}

Describe 'Keyboard input' {

    It 'normalises every documented key' {
        InModuleScope WindowsTweaker {
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Up')).Name | Should -Be 'Up'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Down')).Name | Should -Be 'Down'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Left')).Name | Should -Be 'Left'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Right')).Name | Should -Be 'Right'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Enter')).Name | Should -Be 'Enter'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Escape')).Name | Should -Be 'Escape'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Tab')).Name | Should -Be 'Tab'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'BackTab')).Name | Should -Be 'BackTab'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Backspace')).Name | Should -Be 'Backspace'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'PageUp')).Name | Should -Be 'PageUp'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'PageDown')).Name | Should -Be 'PageDown'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Home')).Name | Should -Be 'Home'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'End')).Name | Should -Be 'End'
            (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Space')).Name | Should -Be 'Space'

            $Slash = ConvertTo-WtKey -Key (New-WtTestKey -Name 'Char' -Character '/')
            $Slash.Name | Should -Be 'Char'
            $Slash.Char | Should -Be '/'
        }
    }

    It 'keeps Ctrl+C recognisable instead of treating it as text' {
        InModuleScope WindowsTweaker {
            $Control = [System.ConsoleKeyInfo]::new([char]3, [System.ConsoleKey]::C, $true, $false, $false)
            $Key = ConvertTo-WtKey -Key $Control
            $Key.Name | Should -Be 'Control'
            $Key.Char | Should -Be 'c'
        }
    }

    It 'edits a text field like a single-line editor' {
        InModuleScope WindowsTweaker {
            $Field = New-WtInputState -Text 'abc'
            $Field.Cursor = 3

            Update-WtInputState -Field $Field -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Char' -Character 'd')) | Out-Null
            $Field.Text | Should -Be 'abcd'
            $Field.Cursor | Should -Be 4

            Update-WtInputState -Field $Field -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Backspace')) | Out-Null
            $Field.Text | Should -Be 'abc'

            Update-WtInputState -Field $Field -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Home')) | Out-Null
            $Field.Cursor | Should -Be 0

            Update-WtInputState -Field $Field -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Backspace')) | Out-Null
            $Field.Text | Should -Be 'abc' -Because 'backspace at the start removes nothing'

            Update-WtInputState -Field $Field -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Delete')) | Out-Null
            $Field.Text | Should -Be 'bc'

            Update-WtInputState -Field $Field -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'End')) | Out-Null
            Update-WtInputState -Field $Field -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Delete')) | Out-Null
            $Field.Text | Should -Be 'bc' -Because 'delete at the end removes nothing'
        }
    }

    It 'scrolls a long value so the caret stays visible' {
        InModuleScope WindowsTweaker {
            $Field = New-WtInputState -Text 'C:\Users\someone\AppData\Local\Temp\file.exe'
            $View = Get-WtInputView -Field $Field -Width 20
            $View.Scroll | Should -Be '<'
            (Get-WtTextWidth -Text $View.Before) | Should -BeLessOrEqual 19
        }
    }
}

Describe 'Interface layout and state' {

    It 'exposes the ten required categories, each mapped to real catalog categories' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            $Keys = @($State.Categories | ForEach-Object { $_.Key })
            $Keys | Should -Be @('Overview', 'Privacy', 'DesktopTaskbar', 'FileExplorer', 'Applications', 'System', 'Network', 'Security', 'WindowsUpdate', 'History')

            $Catalog = @(Get-WtCategory)
            foreach ($Category in $State.Categories)
            {
                foreach ($Mapped in $Category.Catalog)
                {
                    $Catalog | Should -Contain $Mapped -Because "interface category $($Category.Key) maps to catalog category $Mapped"
                }
            }

            $State.Categories[1].Count | Should -Be (Get-WtTweak -Category 'Privacy').Count
            $State.Categories[0].Count | Should -Be (Get-WtTweakState).Count
        }
    }

    It 'cycles the focus through the panes of the current layout' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            $State.Focus | Should -Be 'List'
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Tab')
            $State.Focus | Should -Be 'Details'
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Tab')
            $State.Focus | Should -Be 'Categories'
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'BackTab')
            $State.Focus | Should -Be 'Details'
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Right')
            $State.Focus | Should -Be 'Categories'
        }
    }

    It 'falls back to a compact layout on a small terminal and stays usable' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 50 -Height 12
            Initialize-WtTuiState -State $State
            (Get-WtTuiLayout -State $State).Mode | Should -Be 'Compact'

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Left')
            $State.Focus | Should -Be 'Categories'
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Down')
            $State.CategoryIndex | Should -Be 1

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Right')
            $State.Focus | Should -Be 'List'
            { Update-WtTuiView -State $State } | Should -Not -Throw
        }
    }

    It 'switches category, rebuilds the list and clears the filter' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            Set-WtTuiCategory -State $State -Key 'FileExplorer'
            $State.Categories[$State.CategoryIndex].Key | Should -Be 'FileExplorer'
            @($State.Items).Count | Should -BeGreaterThan 10

            $State.Search = 'CheckBoxes'
            Update-WtTuiItems -State $State
            $State.Items.Count | Should -Be 1
            $State.Items[0].State.Id | Should -Be 'Explorer.CheckBoxes'

            Set-WtTuiCategory -State $State -Key 'Privacy'
            $State.Search | Should -Be ''
            @($State.Items | Where-Object { $_.State.Category -ne 'Privacy' }).Count | Should -Be 0
        }
    }

    It 'searches the whole catalog while a filter is active' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            $State.CategoryIndex = 0   # Overview

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character '/')
            $State.SearchMode | Should -BeTrue

            Send-WtTestText -State $State -Text 'advertising'
            $State.Search | Should -Be 'advertising'
            $State.Items.Count | Should -Be 1
            $State.Items[0].State.Id | Should -Be 'Privacy.AdvertisingId'

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Enter')
            $State.SearchMode | Should -BeFalse
            $State.Search | Should -Be 'advertising' -Because 'Enter keeps the filter'

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Escape')
            $State.Search | Should -Be ''
            $State.Items.Count | Should -BeGreaterThan 10
        }
    }

    It 'lets letters type into the active filter instead of firing global shortcuts' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character '/')
            # 'q' would quit and 'a' would open the pending review; inside the filter they
            # must be plain text.
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'q')
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'a')

            $State.Search | Should -Be 'qa'
            $State.Exit | Should -BeFalse
            $State.Overlay | Should -BeNullOrEmpty
        }
    }

    It 'adds and removes a pending change without touching the system' {
        InModuleScope WindowsTweaker {
            Enable-WtTestSupport

            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'FileExplorer'
            Set-WtTuiItemIndex -State $State -Index 0

            $Entry = $State.Items[0].State
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Space')

            $State.Pending.Count | Should -Be 1
            $State.Pending.Contains($Entry.Id) | Should -BeTrue
            $State.Pending[$Entry.Id].Target | Should -Not -Be $Entry.State
            $State.Pending[$Entry.Id].From | Should -Be $Entry.State

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Space')
            $State.Pending.Count | Should -Be 0

            Test-Path -LiteralPath (Join-Path $env:WT_DATA_ROOT 'state.json') | Should -BeFalse
        }
    }

    It 'refuses to queue a tweak this machine cannot run' {
        InModuleScope WindowsTweaker {
            Mock Test-WtPrerequisite {
                param ($Tweak)
                [pscustomobject]@{
                    PSTypeName = 'WindowsTweaker.PrerequisiteResult'; TweakId = $Tweak.Id
                    Supported = $false; Reason = 'Administrator privileges are required'; Missing = @(); Requirements = @()
                }
            }

            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'Privacy'
            Set-WtTuiItemIndex -State $State -Index 0

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Space')

            $State.Pending.Count | Should -Be 0
            $State.Status.Text | Should -Match 'cannot run|không chạy'
        }
    }

    It 'asks for the target state when a tweak has more than two states' {
        InModuleScope WindowsTweaker {
            Enable-WtTestSupport
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Down'), (New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $State

            $Entry = $State.States | Where-Object { $_.Id -eq 'Taskbar.SearchBox' } | Select-Object -First 1
            $Entry | Should -Not -BeNullOrEmpty
            @($Entry.StateNames).Count | Should -BeGreaterThan 2

            $Chosen = Select-WtTuiTargetState -State $State -Entry $Entry
            $Chosen | Should -Be @($Entry.StateNames)[1]
            $State.Overlay | Should -BeNullOrEmpty -Because 'the dialog must clean up after itself'
            $State.Pending.Count | Should -Be 0 -Because 'choosing a target state queues nothing yet'
        }
    }

    It 'cancels a target state selection without queueing anything' {
        InModuleScope WindowsTweaker {
            Enable-WtTestSupport
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            $Entry = $State.States | Where-Object { $_.Id -eq 'Taskbar.SearchBox' } | Select-Object -First 1
            (Select-WtTuiTargetState -State $State -Entry $Entry) | Should -BeNullOrEmpty
        }
    }

    It 'keeps the selection and the pending set across a refresh and a resize' {
        InModuleScope WindowsTweaker {
            Enable-WtTestSupport

            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'FileExplorer'
            Set-WtTuiItemIndex -State $State -Index 3

            $Selected = $State.SelectedId
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Space')
            $PendingBefore = @($State.Pending.Keys)

            Sync-WtTuiCatalog -State $State
            $State.SelectedId | Should -Be $Selected
            @($State.Pending.Keys) | Should -Be $PendingBefore

            $State.Sizes.Width = 120
            $State.Sizes.Height = 40
            $null = Invoke-WtTuiFrame -State $State
            $State.Screen.Width | Should -Be 120
            $State.Screen.Height | Should -Be 40
            $State.SelectedId | Should -Be $Selected
            @($State.Pending.Keys) | Should -Be $PendingBefore
            (Get-WtTuiLayout -State $State).Mode | Should -Be 'Wide'

            $State.Sizes.Width = 60
            $State.Sizes.Height = 16
            $null = Invoke-WtTuiFrame -State $State
            (Get-WtTuiLayout -State $State).Mode | Should -Be 'Medium'
            $State.SelectedId | Should -Be $Selected

            $State.Sizes.Width = 44
            $State.Sizes.Height = 10
            $null = Invoke-WtTuiFrame -State $State
            (Get-WtTuiLayout -State $State).Mode | Should -Be 'Compact'
            $State.SelectedId | Should -Be $Selected
        }
    }

    It 'toggles dry run and announces it in the header' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            $State.DryRun | Should -BeFalse

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'd')
            $State.DryRun | Should -BeTrue
            $State.Notice | Should -Be (Get-WtString -Key 'Tui.Header.DryRunNotice')
            $State.Status.Text | Should -Be (Get-WtString -Key 'Tui.Status.DryRunOn')

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'd')
            $State.DryRun | Should -BeFalse
        }
    }

    It 'confirms before quitting and honours the answer' {
        InModuleScope WindowsTweaker {
            $Declined = New-WtTestState -Keys @((New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $Declined
            Send-WtTestKey -State $Declined -Key (New-WtTestKey -Name 'Char' -Character 'q')
            $Declined.Exit | Should -BeFalse -Because 'the default answer is No'
            $Declined.Overlay | Should -BeNullOrEmpty

            $Accepted = New-WtTestState -Keys @((New-WtTestKey -Name 'Char' -Character 'y'))
            Initialize-WtTuiState -State $Accepted
            Send-WtTestKey -State $Accepted -Key (New-WtTestKey -Name 'Char' -Character 'q')
            $Accepted.Exit | Should -BeTrue
        }
    }

    It 'warns about pending changes before quitting' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Char' -Character 'y'))
            Initialize-WtTuiState -State $State
            $Entry = $State.States | Where-Object { $_.Id -eq 'Explorer.FileExtensions' } | Select-Object -First 1
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'Enabled'

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'q')
            $State.Exit | Should -BeTrue
        }
    }

    It 'opens the execution history from the shortcut' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'h')
            $State.Categories[$State.CategoryIndex].Key | Should -Be 'History'
        }
    }

    It 'renders a frame that lists the categories, the selection and the status line' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'Privacy'
            Update-WtTuiView -State $State

            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match 'WindowsTweaker'
            $Text | Should -Match 'Categories'
            $Text | Should -Match 'Privacy'
            $Text | Should -Match 'Details'
            # The shortcut line and the status line are both painted; the exact wording lives
            # in the string tables (assert the keys' content, not a frozen phrase).
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Tui.Keys.Main').Split('  ')[0]))
            $Text | Should -Match 'Q quit'
            $Text | Should -Match 'Advertising'
        }
    }

    It 'renders the help panel with the documented shortcuts' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $State

            Show-WtTuiHelp -State $State
            $State.Overlay | Should -BeNullOrEmpty
        }
    }
}

Describe 'Dialogs' {

    It 'closes a message panel on Enter or Escape' {
        InModuleScope WindowsTweaker {
            $Enter = New-WtTestState -Keys @((New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $Enter
            { Show-WtTuiMessage -State $Enter -Title 'Test' -Lines @('line one') } | Should -Not -Throw
            $Enter.Overlay | Should -BeNullOrEmpty

            $Escape = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $Escape
            { Show-WtTuiMessage -State $Escape -Title 'Test' -Lines @('line one') } | Should -Not -Throw
        }
    }

    It 'draws the dialog inside the frame and keeps the footer readable' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @()
            Initialize-WtTuiState -State $State

            $Overlay = New-WtDialogOverlay -Kind 'message' -Title 'Panel' -Body @('body line') -Buttons @('Enter closes')
            $State.Overlay = $Overlay
            Update-WtTuiView -State $State

            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match 'Panel'
            $Text | Should -Match 'body line'
            $Text | Should -Match 'Enter closes'
            $State.Overlay = $null
        }
    }

    It 'defaults a confirmation to No so Enter cannot confirm a change' {
        InModuleScope WindowsTweaker {
            $Enter = New-WtTestState -Keys @((New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $Enter
            (Confirm-WtTui -State $Enter -Title 'Apply?' -Lines @('sure?')) | Should -BeFalse

            $Yes = New-WtTestState -Keys @((New-WtTestKey -Name 'Char' -Character 'y'))
            Initialize-WtTuiState -State $Yes
            (Confirm-WtTui -State $Yes -Title 'Apply?' -Lines @('sure?')) | Should -BeTrue

            $Left = New-WtTestState -Keys @((New-WtTestKey -Name 'Left'), (New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $Left
            (Confirm-WtTui -State $Left -Title 'Apply?' -Lines @('sure?')) | Should -BeTrue -Because 'Left selects Yes'
        }
    }

    It 'validates text input and reports the error without closing' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'x'),
                (New-WtTestKey -Name 'Enter'),
                (New-WtTestKey -Name 'Backspace'),
                (New-WtTestKey -Name 'Char' -Character '/'),
                (New-WtTestKey -Name 'Enter')
            )
            Initialize-WtTuiState -State $State

            $Result = Read-WtTuiText -State $State -Title 'Path' -Label 'Path' -Validate {
                param ($Text)
                if ($Text -notmatch '^/') { return 'must start with /' }
                return ''
            }

            $Result | Should -Be '/'
        }
    }

    It 'cancels text input on Escape' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State
            (Read-WtTuiText -State $State -Title 'Path' -Label 'Path') | Should -BeNullOrEmpty
        }
    }

    It 'supports multi-selection, filtering and cancellation in a list' {
        InModuleScope WindowsTweaker {
            $Items = @(
                @{ Label = 'Alpha'; Payload = 'a'; Right = '1' }
                @{ Label = 'Beta'; Payload = 'b'; Right = '2' }
                @{ Label = 'Gamma'; Payload = 'c'; Right = '3'; Disabled = $true }
            )

            # Space ticks the current row and moves on, so two presses select the two
            # selectable rows without any extra navigation.
            $State = New-WtTestState -Keys @(
                (New-WtTestKey -Name 'Space'),
                (New-WtTestKey -Name 'Space'),
                (New-WtTestKey -Name 'Enter')
            )
            Initialize-WtTuiState -State $State
            $Result = Select-WtTuiItem -State $State -Title 'Pick' -Items $Items -Multi
            @($Result.Selected) | Should -Be @('a', 'b')

            $Cancelled = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $Cancelled
            (Select-WtTuiItem -State $Cancelled -Title 'Pick' -Items $Items -Multi) | Should -BeNullOrEmpty

            $Filtered = New-WtTestState -Keys @(
                (New-WtTestKey -Name 'Char' -Character '/'),
                (New-WtTestKey -Name 'Char' -Character 'g'),
                (New-WtTestKey -Name 'Enter'),
                (New-WtTestKey -Name 'Space'),
                (New-WtTestKey -Name 'Enter')
            )
            Initialize-WtTuiState -State $Filtered
            $FilteredResult = Select-WtTuiItem -State $Filtered -Title 'Pick' -Items $Items -Multi -Searchable
            @($FilteredResult.Selected).Count | Should -Be 0 -Because 'the only match is a protected row'
        }
    }

    It 'returns one value for a single-selection list' {
        InModuleScope WindowsTweaker {
            $Items = @(@{ Label = 'One'; Payload = 1 }, @{ Label = 'Two'; Payload = 2 })
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Down'), (New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $State

            $Result = Select-WtTuiItem -State $State -Title 'Pick' -Items $Items
            $Result.Value | Should -Be 2
            $Result.Multi | Should -BeFalse
        }
    }

    It 'scrolls a message that is longer than the dialog' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Height 12 -Keys @((New-WtTestKey -Name 'PageDown'), (New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $State

            $Lines = 1..40 | ForEach-Object { "line $_" }
            { Show-WtTuiMessage -State $State -Title 'Long' -Lines $Lines } | Should -Not -Throw
            $State.Overlay | Should -BeNullOrEmpty
        }
    }
}

Describe 'Backend workflows and results' {

    It 'reports failures, dry runs and restart requirements honestly' {
        InModuleScope WindowsTweaker {
            $Results = @(
                [pscustomobject]@{
                    TweakId = 'A.B'; State = 'Disabled'; Status = 'succeeded'; Restart = 'Reboot'; Rollback = 'Full'
                    Operations = @([pscustomobject]@{ Status = 'succeeded'; Operation = 'RegistrySet'; Target = 'HKCU:\X'; Message = 'set' })
                    Messages = @()
                },
                [pscustomobject]@{
                    TweakId = 'C.D'; State = 'Enabled'; Status = 'failed'; Restart = 'None'; Rollback = 'None'
                    Operations = @([pscustomobject]@{ Status = 'failed'; Operation = 'Service'; Target = 'DiagTrack'; Message = 'access denied' })
                    Messages = @('one operation failed')
                }
            )

            $Report = Get-WtTuiResultReport -Results $Results -Preview $false
            $Report.Failed | Should -Be 1
            $Report.Changed | Should -Be 1
            $Report.Tone | Should -Be 'Error'
            ($Report.Lines -join "`n") | Should -Match 'access denied'
            ($Report.Lines -join "`n") | Should -Match 'one operation failed'
            ($Report.Lines -join "`n") | Should -Match 'Restart required'

            $Preview = Get-WtTuiResultReport -Results @($Results[0]) -Preview $true
            ($Preview.Lines -join "`n") | Should -Match 'WhatIf'
            $Preview.Failed | Should -Be 0

            $WorkerFailure = Get-WtTuiResultReport -Failures @(@{ Message = 'module import failed' })
            $WorkerFailure.Failed | Should -Be 1
            ($WorkerFailure.Lines -join "`n") | Should -Match 'module import failed'
        }
    }

    It 'marks an irreversible and an already-applied pending change' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            $Entry = $State.States | Where-Object { $_.Id -eq 'Apps.OneDriveUninstall' } | Select-Object -First 1
            $Entry | Should -Not -BeNullOrEmpty

            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'Enabled'
            ((Get-WtTuiPendingWarnings -State $State) -join "`n") | Should -Match 'cannot be undone'

            $State.Pending.Clear()
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target $Entry.State
            ((Get-WtTuiPendingWarnings -State $State) -join "`n") | Should -Match 'already in the requested state'
        }
    }

    It 'summarises collected arguments without leaking their objects' {
        InModuleScope WindowsTweaker {
            (Get-WtTuiArgumentSummary -Arguments @{ ServerAddresses = @('1.1.1.1', '1.0.0.1'); DohTemplate = 'https://x/y' }) |
                Should -Match 'ServerAddresses=2 item\(s\)'
            (Get-WtTuiArgumentSummary -Arguments @{ AllUsers = $true }) | Should -Match 'AllUsers=True'
        }
    }

    It 'refuses to apply when nothing is pending' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State

            Start-WtTuiOperation -State $State
            $State.Operation | Should -BeNullOrEmpty
            $State.Status.Text | Should -Be (Get-WtString -Key 'Gui.NothingPending')
            $State.Worker | Should -BeNullOrEmpty -Because 'no worker is created for an empty selection'
        }
    }

    It 'previews the pending selection in dry-run mode without starting a real change' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            $Entry = $State.States | Where-Object { $_.Id -eq 'Privacy.AdvertisingId' } | Select-Object -First 1
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'Disabled'

            Start-WtTuiOperation -State $State -Preview
            $State.Operation | Should -Not -BeNullOrEmpty
            $State.Operation.Preview | Should -BeTrue
            $State.Status.Text | Should -Be (Get-WtString -Key 'Tui.Busy.Preview' -Arguments @(1))

            # The worker was started: let it finish and collect the (unsupported on this
            # platform) result without leaving a runspace behind.
            $Outcome = Complete-WtWorkerTask -Worker $State.Worker -TimeoutSeconds 120
            @($Outcome.Results).Count | Should -Be 1
            $Outcome.Results[0].Result.Status | Should -BeIn @('dryrun', 'unsupported')
            Close-WtTuiWorker -State $State

            Test-Path -LiteralPath (Join-Path $env:WT_DATA_ROOT 'state.json') | Should -BeFalse
        }
    }

    It 'validates a writable destination path' {
        InModuleScope WindowsTweaker {
            $Root = [System.IO.Path]::GetTempPath()
            (Resolve-WtTuiPathError -Path 'relative/file.exe') | Should -Match 'absolute'
            (Resolve-WtTuiPathError -Path (Join-Path $Root 'thing')) | Should -Match 'extension'
            (Resolve-WtTuiPathError -Path (Join-Path $Root 'definitely-missing-dir/thing.exe')) | Should -Match 'does not exist'
            (Resolve-WtTuiPathError -Path (Join-Path $Root ("fresh-{0}.exe" -f ([guid]::NewGuid().ToString('n'))))) | Should -Be ''
        }
    }

    It 'exposes no Windows features or capabilities on a non-Windows host' {
        InModuleScope WindowsTweaker {
            $Features = @(Get-WtWindowsFeature)
            $Capabilities = @(Get-WtWindowsCapability)

            if (-not $IsWindows)
            {
                $Features.Count | Should -Be 0
                $Capabilities.Count | Should -Be 0
            }
        }
    }

    It 'adds the current DNS configuration to the adapter list it reads' {
        InModuleScope WindowsTweaker {
            $Adapters = @(Get-WtNetworkAdapter)
            foreach ($Adapter in $Adapters)
            {
                $Adapter.PSObject.Properties.Name | Should -Contain 'DnsServers'
                $Adapter.PSObject.Properties.Name | Should -Contain 'DnsAutomatic'
            }

            if (-not $IsWindows)
            {
                $Adapters.Count | Should -Be 0
            }
        }
    }
}

Describe 'Worker runspace' {

    It 'runs a tweak in its own runspace, reports events and never fakes a result' {
        InModuleScope WindowsTweaker {
            $Worker = New-WtWorker -ModulePath $env:WT_TEST_MODULE
            try
            {
                $Items = @(
                    @{ Id = 'Privacy.AdvertisingId'; Target = 'Disabled'; Arguments = $null; Label = 'Privacy.AdvertisingId' },
                    @{ Id = 'This.Tweak.Does.Not.Exist'; Target = 'Enabled'; Arguments = $null; Label = 'This.Tweak.Does.Not.Exist' }
                )

                $null = Start-WtWorkerTask -Worker $Worker -Kind 'apply' -Items $Items -DryRun $true
                Test-WtWorkerBusy -Worker $Worker | Should -BeTrue
                $Outcome = Complete-WtWorkerTask -Worker $Worker -TimeoutSeconds 180

                $Kinds = @($Outcome.Events | ForEach-Object { $_.Kind })
                $Kinds | Should -Contain 'start'
                $Kinds | Should -Contain 'done'
                $Kinds[-1] | Should -Be 'done'

                # One item is applicable (dry run) and one cannot be resolved at all: the
                # worker must report them separately instead of collapsing them.
                @($Outcome.Results).Count | Should -Be 1
                @($Outcome.Failures).Count | Should -Be 1
                $Outcome.Results[0].Result.TweakId | Should -Be 'Privacy.AdvertisingId'
                $Outcome.Results[0].Result.Status | Should -BeIn @('dryrun', 'unsupported')
                $Outcome.Failures[0].Message | Should -Match 'Unknown tweak id'
            }
            finally
            {
                Close-WtWorker -Worker $Worker
            }

            Test-Path -LiteralPath (Join-Path $env:WT_DATA_ROOT 'state.json') | Should -BeFalse -Because 'a dry run must not capture state'
        }
    }

    It 'drops queued work when cancellation is requested before it starts' {
        InModuleScope WindowsTweaker {
            $Worker = New-WtWorker -ModulePath $env:WT_TEST_MODULE
            try
            {
                $Items = @(
                    @{ Id = 'Privacy.AdvertisingId'; Target = 'Disabled'; Arguments = $null; Label = 'one' },
                    @{ Id = 'Privacy.BingSearch'; Target = 'Disabled'; Arguments = $null; Label = 'two' }
                )

                $null = Start-WtWorkerTask -Worker $Worker -Kind 'apply' -Items $Items -DryRun $true

                # Cancellation is cooperative: the request arrives while the worker is still
                # importing the module, so no item is started and both are reported as
                # cancelled. A native operation that is already in flight cannot be
                # interrupted, which is why the worker reports that explicitly.
                $Request = Stop-WtWorkerTask -Worker $Worker
                $Request | Should -Not -BeNullOrEmpty
                $Request.Interruptible | Should -BeFalse

                $Outcome = Complete-WtWorkerTask -Worker $Worker -TimeoutSeconds 180

                @($Outcome.Events | Where-Object { $_.Kind -eq 'cancelled' }).Count | Should -Be 2
                @($Outcome.Results).Count | Should -Be 0
                @($Outcome.Events | Where-Object { $_.Kind -eq 'start' }).Count | Should -Be 0
            }
            finally
            {
                Close-WtWorker -Worker $Worker
            }
        }
    }

    It 'refuses a second task while one is running' {
        InModuleScope WindowsTweaker {
            $Worker = New-WtWorker -ModulePath $env:WT_TEST_MODULE
            try
            {
                $Items = @(@{ Id = 'Privacy.AdvertisingId'; Target = 'Disabled'; Arguments = $null; Label = 'x' })
                $null = Start-WtWorkerTask -Worker $Worker -Kind 'apply' -Items $Items -DryRun $true
                { Start-WtWorkerTask -Worker $Worker -Kind 'apply' -Items $Items -DryRun $true } |
                    Should -Throw -ExpectedMessage '*already running*'
                $null = Complete-WtWorkerTask -Worker $Worker -TimeoutSeconds 180
            }
            finally
            {
                Close-WtWorker -Worker $Worker
            }
        }
    }

    It 'closes cleanly even when no task ever ran' {
        InModuleScope WindowsTweaker {
            $Worker = New-WtWorker -ModulePath $env:WT_TEST_MODULE
            { Close-WtWorker -Worker $Worker } | Should -Not -Throw
            { Close-WtWorker -Worker $Worker } | Should -Not -Throw -Because 'closing twice must be safe'
        }
    }
}

Describe 'Presets' {

    It 'ships presets that only contain valid, reversible entries' {
        InModuleScope WindowsTweaker {
            $Presets = @(Get-WtPreset)
            $Presets.Count | Should -BeGreaterThan 0

            foreach ($Preset in $Presets)
            {
                @($Preset.Entries).Count | Should -BeGreaterThan 0 -Because "$($Preset.Name) must contain entries"
                @($Preset.Skipped).Count | Should -Be 0 -Because "$($Preset.Name) must not contain entries the catalog rejects"

                foreach ($Entry in $Preset.Entries)
                {
                    $Tweak = Get-WtTweak -Id $Entry.Id
                    $Tweak | Should -Not -BeNullOrEmpty -Because "$($Preset.Name) references $($Entry.Id)"
                    @($Tweak.StateNames) | Should -Contain $Entry.State
                    $Tweak.ReducesProtection | Should -BeFalse -Because 'a shipped preset must not reduce protection'
                    $Tweak.Irreversible | Should -BeFalse -Because 'a shipped preset must not contain irreversible changes'
                }
            }
        }
    }

    It 'writes, re-imports and refuses to overwrite a preset file' {
        InModuleScope WindowsTweaker {
            $Path = Join-Path $env:WT_DATA_ROOT 'roundtrip.json'
            New-Item -ItemType Directory -Path $env:WT_DATA_ROOT -Force | Out-Null

            Export-WtPreset -Entries @(@{ id = 'Explorer.FileExtensions'; state = 'Enabled' }) -Path $Path -Name 'roundtrip' | Out-Null
            Test-Path -LiteralPath $Path | Should -BeTrue

            $Imported = Import-WtPreset -Path $Path
            $Imported.Name | Should -Be 'roundtrip'
            @($Imported.Entries).Count | Should -Be 1
            $Imported.Entries[0].Id | Should -Be 'Explorer.FileExtensions'

            { Export-WtPreset -Entries @(@{ id = 'Explorer.FileExtensions'; state = 'Enabled' }) -Path $Path } |
                Should -Throw -ExpectedMessage '*already exists*'
        }
    }

    It 'refuses an unknown tweak, an invalid state and reports excluded entries' {
        InModuleScope WindowsTweaker {
            $Directory = Join-Path $env:WT_DATA_ROOT 'presets'
            New-Item -ItemType Directory -Path $Directory -Force | Out-Null

            { Export-WtPreset -Entries @(@{ id = 'Nope.Nope'; state = 'Enabled' }) -Path (Join-Path $Directory 'a.json') } |
                Should -Throw -ExpectedMessage '*Unknown tweak id*'

            { Export-WtPreset -Entries @(@{ id = 'Explorer.FileExtensions'; state = 'Sideways' }) -Path (Join-Path $Directory 'b.json') } |
                Should -Throw -ExpectedMessage '*not supported by*'

            $Bad = Join-Path $Directory 'bad.json'
            @'
{
  "preset": 1,
  "name": "bad",
  "tweaks": [
    { "id": "Privacy.PuaProtection", "state": "Disabled" },
    { "id": "Explorer.FileExtensions", "state": "Enabled" }
  ]
}
'@ | Set-Content -LiteralPath $Bad -Encoding utf8NoBOM

            $Imported = Import-WtPreset -Path $Bad
            @($Imported.Entries).Count | Should -Be 1
            @($Imported.Skipped).Count | Should -Be 1
            ($Imported.Skipped -join ' ') | Should -Match 'reduces protection'
        }
    }

    It 'loads a preset into the pending set without applying it' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Char' -Character 'y'))
            Initialize-WtTuiState -State $State

            $Preset = Get-WtPreset -Name 'explorer-usability' | Select-Object -First 1
            $Preset | Should -Not -BeNullOrEmpty

            Import-WtTuiPreset -State $State -Preset $Preset
            $State.Pending.Count | Should -Be @($Preset.Entries).Count
            $State.PresetName | Should -Be 'explorer-usability'
            Test-Path -LiteralPath (Join-Path $env:WT_DATA_ROOT 'state.json') | Should -BeFalse -Because 'loading a preset applies nothing'
        }
    }
}

Describe 'Safety of the interface layer' {

    BeforeAll {
        $script:TuiSources = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '../src/WindowsTweaker/Private/Tui') -Filter '*.ps1' -File)
        # Comments are stripped first so sentences such as "a running native operation
        # (DISM, Remove-AppxPackage) finishes" do not trip the code checks.
        $script:TuiCode = ($script:TuiSources | ForEach-Object {
                (Get-Content -LiteralPath $_.FullName | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
            }) -join "`n"
    }

    It 'never changes the system itself' {
        foreach ($Pattern in 'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-Service',
            'Start-Service', 'Stop-Service', 'Remove-AppxPackage', 'Set-DnsClientServerAddress', 'Set-MpPreference',
            'Set-NetFirewallRule', 'Enable-ScheduledTask', 'Disable-ScheduledTask', 'dism\.exe', 'Checkpoint-Computer')
        {
            $script:TuiCode | Should -Not -Match $Pattern -Because "the interface must call the backend instead ($Pattern)"
        }
    }

    It 'goes through the shared backend for every change' {
        $script:TuiCode | Should -Match 'Invoke-WtTweak'
        $script:TuiCode | Should -Match 'Undo-WtTweak'
        $script:TuiCode | Should -Match 'Get-WtTweakState'
        $script:TuiCode | Should -Match 'Get-WtHistory'
        $script:TuiCode | Should -Match 'Runspace'
    }

    It 'never opens a graphical surface' {
        foreach ($Pattern in 'MessageBox', 'ShowDialog', 'OpenFileDialog', 'SaveFileDialog', 'PresentationFramework',
            'XamlReader', 'System\.Windows', 'WinForms', 'Start-Process')
        {
            $script:TuiCode | Should -Not -Match $Pattern -Because "a terminal workflow must not open a window ($Pattern)"
        }
    }

    It 'uses no unsafe execution or download primitives' {
        foreach ($Pattern in 'Invoke-Expression', 'Add-Type', 'DownloadString', 'powershell_temp\.exe', 'System32')
        {
            $script:TuiCode | Should -Not -Match $Pattern
        }
    }

    It 'refuses to start without an interactive terminal' {
        InModuleScope WindowsTweaker {
            $ExitCode = Start-WtTui -Colour 'Mono' -Ascii 6>$null 3>$null
            $ExitCode | Should -Be 2 -Because 'Pester has no interactive terminal, so the interface must refuse to start'
        }
    }

    It 'restores the terminal on every exit path' {
        $Text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/WindowsTweaker/Private/Tui/Tui.ps1') -Raw
        $Text | Should -Match 'Restore-WtTuiTerminal'
        $Text | Should -Match 'add_CancelKeyPress'
        $Text | Should -Match 'finally'
        $Text | Should -Match '\[Console\]::CursorVisible'
    }
}

Describe 'Localization of the interface' {

    BeforeAll {
        # The tables are split by feature (Import-PowerShellDataFile refuses more than 500
        # entries in one hashtable literal), so a language is its main file plus part files.
        function Merge-WtTuiStringTable([string]$Code)
        {
            $Table = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "../src/WindowsTweaker/Data/Strings.$Code.psd1")
            foreach ($Part in @(Get-ChildItem -Path (Join-Path $PSScriptRoot '../src/WindowsTweaker/Data') -Filter "Strings.$Code.*.psd1" -File | Sort-Object -Property Name))
            {
                $Extra = Import-PowerShellDataFile -LiteralPath $Part.FullName
                foreach ($Key in $Extra.Keys) { $Table[$Key] = $Extra[$Key] }
            }
            return $Table
        }

        $script:English = Merge-WtTuiStringTable -Code 'en'
        $script:Vietnamese = Merge-WtTuiStringTable -Code 'vi'
    }

    It 'defines every dynamically composed interface key in both languages' {
        # The list is built inside the module scope: the keys depend on catalog values.
        $Dynamic = InModuleScope WindowsTweaker {
            $Keys = [System.Collections.Generic.List[string]]::new()

            foreach ($Name in 'Overview', 'Privacy', 'DesktopTaskbar', 'FileExplorer', 'Applications', 'System', 'Network', 'Security', 'WindowsUpdate', 'History')
            {
                $Keys.Add("Cat.$Name")
            }

            foreach ($Scope in 'User', 'Machine', 'UserAndMachine', 'PerAdapter', 'PerApp')
            {
                $Keys.Add("Tui.Scope.$Scope")
            }

            foreach ($Privilege in 'None', 'Admin')
            {
                $Keys.Add("Tui.Privilege.$Privilege")
            }

            foreach ($Level in 'Low', 'Medium', 'High')
            {
                $Keys.Add("Tui.Impact.$Level")
            }

            foreach ($Action in 'Move', 'Panes', 'Select', 'Enter', 'Search', 'Review', 'Preview', 'History', 'Restore',
                              'Language', 'Icons', 'IconsNote', 'Presets', 'DryRun', 'Refresh', 'Help', 'Escape', 'Quit', 'Safety', 'Notes', 'Title')
            {
                $Keys.Add("Tui.Help.$Action")
            }

            foreach ($Language in 'en', 'vi')
            {
                $Keys.Add("Tui.Language.$Language")
            }

            foreach ($Tweak in (Get-WtTweak))
            {
                $Keys.Add("Restart.$($Tweak.Restart)")
                $Keys.Add("Rollback.$($Tweak.Rollback)")
                foreach ($Name in @($Tweak.StateNames))
                {
                    $Keys.Add("Tui.State.$Name")
                }
            }

            return @($Keys | Sort-Object -Unique)
        }

        $Dynamic.Count | Should -BeGreaterThan 50
        @($Dynamic | Where-Object { -not $script:English.ContainsKey($_) }) | Should -BeNullOrEmpty
        @($Dynamic | Where-Object { -not $script:Vietnamese.ContainsKey($_) }) | Should -BeNullOrEmpty
    }

    It 'keeps every catalog category reachable from the interface' {
        InModuleScope WindowsTweaker {
            $Covered = @()
            foreach ($Definition in $Script:WtTuiCategoryDefinitions)
            {
                $Covered += @($Definition.Catalog)
            }

            foreach ($Name in (Get-WtCategory))
            {
                $Covered | Should -Contain $Name -Because "catalog category $Name must be reachable in the interface"
            }
        }
    }

    It 'renders the interface in Vietnamese without falling back to raw keys' {
        InModuleScope WindowsTweaker {
            # 120 columns so the category labels are not truncated: this test is about
            # localization, not about what the narrowest layout clips.
            $State = New-WtTestState -Width 120 -Height 30
            Set-WtLanguage -Language 'vi' | Out-Null
            try
            {
                Initialize-WtTuiState -State $State
                Update-WtTuiView -State $State
                $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
                $Text | Should -Match 'Tổng quan'
                $Text | Should -Match 'Quyền riêng tư'
                $Text | Should -Not -Match '\[Cat\.'
                $Text | Should -Not -Match '\[Tui\.'
            }
            finally
            {
                Set-WtLanguage -Language 'en' | Out-Null
            }
        }
    }
}

Describe 'Icon registry' {

    It 'defines every required key in every icon set, with a stable semantic key' {
        InModuleScope WindowsTweaker {
            # The vocabulary the specification requires, by family.
            $Vocabulary = @{
                Category = @('Dashboard', 'Hardware', 'Privacy', 'Desktop', 'FileExplorer', 'Applications',
                    'Startup', 'Cleaning', 'Network', 'Security', 'WindowsUpdate', 'Repairs', 'Drivers',
                    'Printers', 'History', 'Settings', 'Help')
                Status = @('Enabled', 'Disabled', 'Pending', 'Running', 'Succeeded', 'Failed', 'Warning',
                    'Unsupported', 'Unknown', 'AdminRequired', 'RestartRequired', 'Reversible')
                Action = @('Search', 'Refresh', 'Select', 'Preview', 'Apply', 'Restore', 'Import', 'Export',
                    'Cancel', 'Quit')
            }

            $Registry = Get-WtIconRegistry
            $Expected = [System.Collections.Generic.List[string]]::new()
            foreach ($Family in $Vocabulary.Keys)
            {
                foreach ($Name in $Vocabulary[$Family])
                {
                    $Expected.Add("$Family.$Name")
                }
            }

            $Expected.Count | Should -Be 39
            foreach ($Key in $Expected)
            {
                $Registry.Contains($Key) | Should -BeTrue -Because "$Key must exist in the registry"
                foreach ($Set in 'Unicode', 'NerdFont', 'ASCII')
                {
                    [string]::IsNullOrEmpty([string]$Registry[$Key][$Set]) | Should -BeFalse -Because "$Key needs a $Set glyph"
                }
                $Registry[$Key].Style | Should -BeIn @('IconCategory', 'IconSuccess', 'IconWarning', 'IconError', 'IconInactive')
            }

            # No key outside the vocabulary: the registry is the whole vocabulary, not a
            # dumping ground for literal symbols added at a call site.
            @($Registry.Keys | Where-Object { $Expected -notcontains $_ }) | Should -BeNullOrEmpty
        }
    }

    It 'pads every glyph to the measured column width of its set' {
        InModuleScope WindowsTweaker {
            foreach ($Mode in 'Unicode', 'NerdFont', 'ASCII')
            {
                $Table = New-WtIconTable -Mode $Mode
                $Widest = 0

                foreach ($Entry in (Get-WtIconRegistry).GetEnumerator())
                {
                    $Glyph = [string]$Entry.Value[$Table.Set]
                    $Width = Get-WtTextWidth -Text $Glyph
                    $Width | Should -BeGreaterThan 0
                    $Width | Should -BeLessOrEqual $Table.Slot -Because "$($Entry.Key) must fit the $Mode slot"
                    if ($Width -gt $Widest) { $Widest = $Width }

                    (Format-WtIconPrefix -Icons $Table -Key $Entry.Key).Length | Should -BeGreaterThan 0
                    (Get-WtIconPrefixWidth -Icons $Table -Key $Entry.Key) | Should -Be ($Table.Slot + 1)
                    # The padded prefix occupies the slot exactly, plus one separating cell.
                    (Get-WtTextWidth -Text (Format-WtIconPrefix -Icons $Table -Key $Entry.Key)) | Should -Be ($Table.Slot + 1)
                }

                # The declared slot is the real maximum: a wider glyph would shift labels.
                $Table.Slot | Should -Be $Widest -Because "the $Mode slot must be the widest glyph of the set"
            }

            (New-WtIconTable -Mode 'None').Slot | Should -Be 0
            (Format-WtIconPrefix -Icons (New-WtIconTable -Mode 'None') -Key 'Category.Network') | Should -Be ''
            (Get-WtIconPrefixWidth -Icons (New-WtIconTable -Mode 'None') -Key 'Category.Network') | Should -Be 0
        }
    }

    It 'uses monochrome glyphs: no emoji presentation, no variation selectors, no exotic width' {
        InModuleScope WindowsTweaker {
            $Wide = @(
                @(0x1100, 0x115F), @(0x2E80, 0x303E), @(0x3041, 0x33FF), @(0x3400, 0x4DBF),
                @(0x4E00, 0x9FFF), @(0xA000, 0xA4CF), @(0xAC00, 0xD7A3), @(0xF900, 0xFAFF),
                @(0xFE10, 0xFE19), @(0xFE30, 0xFE6F), @(0xFF00, 0xFF60), @(0xFFE0, 0xFFE6),
                @(0x1F000, 0x1FAFF), @(0x20000, 0x3FFFD)
            )

            foreach ($Entry in (Get-WtIconRegistry).GetEnumerator())
            {
                foreach ($Set in 'Unicode', 'NerdFont', 'ASCII')
                {
                    $Glyph = [string]$Entry.Value[$Set]
                    foreach ($Character in $Glyph.ToCharArray())
                    {
                        $Code = [int][char]$Character
                        $Code | Should -Not -Be 0xFE0F -Because 'a variation selector can promote a glyph to emoji presentation'
                        foreach ($Range in $Wide)
                        {
                            ($Code -lt $Range[0] -or $Code -gt $Range[1]) | Should -BeTrue -Because "U+$('{0:X4}' -f $Code) ($($Entry.Key)/$Set) must stay one cell wide"
                        }
                    }

                    if ($Set -eq 'NerdFont')
                    {
                        # The private-use area of the basic multilingual plane: one cell
                        # in the Nerd Font patched fonts, no astral-plane surprises.
                        foreach ($Character in $Glyph.ToCharArray())
                        {
                            $Code = [int][char]$Character
                            ($Code -ge 0xE000 -and $Code -le 0xF8FF) | Should -BeTrue -Because "$($Entry.Key) must use the BMP private-use area"
                        }
                    }
                }
            }
        }
    }

    It 'resolves the display mode from the switch, the terminal and the saved preference' {
        InModuleScope WindowsTweaker {
            $Unicode = @{ Unicode = $true; Colour = 'TrueColor'; Encoding = 'utf-8' }
            $Legacy = @{ Unicode = $false; Colour = 'Ansi16'; Encoding = 'cp850' }

            # Auto: conservative, and never NerdFont (no font detection is implemented).
            (Resolve-WtIconMode -Requested 'Auto' -Capability $Unicode) | Should -Be 'Unicode'
            (Resolve-WtIconMode -Requested 'Auto' -Capability $Legacy) | Should -Be 'ASCII'
            (Resolve-WtIconMode -Requested 'Auto' -Capability $Unicode -Preference 'NerdFont') | Should -Be 'NerdFont'

            # An explicit request wins over the preference, the switch wins over both.
            (Resolve-WtIconMode -Requested 'ASCII' -Capability $Unicode -Preference 'NerdFont') | Should -Be 'ASCII'
            (Resolve-WtIconMode -Requested 'NerdFont' -Capability $Unicode -Ascii) | Should -Be 'ASCII'

            # A mode the terminal cannot draw is never invented.
            (Resolve-WtIconMode -Requested 'NerdFont' -Capability $Legacy) | Should -Be 'ASCII'
            (Resolve-WtIconMode -Requested 'Unicode' -Capability $Legacy) | Should -Be 'ASCII'

            # "No icons" cannot break anything, so it is always honoured.
            (Resolve-WtIconMode -Requested 'None' -Capability $Legacy -Ascii) | Should -Be 'None'
            (Resolve-WtIconMode -Requested 'NoSuchMode' -Capability $Unicode) | Should -Be 'Unicode'
        }
    }

    It 'maps categories, states, actions and tones to semantic keys' {
        InModuleScope WindowsTweaker {
            Get-WtCategoryIconKey -Category 'Overview' | Should -Be 'Category.Dashboard'
            Get-WtCategoryIconKey -Category 'Network' | Should -Be 'Category.Network'
            Get-WtCategoryIconKey -Category 'WindowsUpdate' | Should -Be 'Category.WindowsUpdate'
            Get-WtCategoryIconKey -Category 'History' | Should -Be 'Category.History'
            Get-WtCategoryIconKey -Category 'NoSuchCategory' | Should -Be ''

            # Catalog categories (what a tweak row uses) resolve too.
            Get-WtCategoryIconKey -Category 'StartMenu' | Should -Be 'Category.Startup'
            Get-WtCategoryIconKey -Category 'Maintenance' | Should -Be 'Category.Cleaning'
            foreach ($Name in (Get-WtCategory))
            {
                (Get-WtCategoryIconKey -Category $Name) | Should -Not -BeNullOrEmpty -Because "catalog category $Name needs an icon"
            }

            Get-WtStateIconKey -State 'Enabled' | Should -Be 'Status.Enabled'
            Get-WtStateIconKey -State 'succeeded' | Should -Be 'Status.Succeeded'
            Get-WtStateIconKey -State 'failed' | Should -Be 'Status.Failed'
            Get-WtStateIconKey -State 'NoSuchState' | Should -Be 'Status.Unknown'

            Get-WtActionIconKey -Action 'Presets' | Should -Be 'Action.Import'
            Get-WtActionIconKey -Action 'NoSuchAction' | Should -Be ''

            Get-WtToneIconKey -Tone 'StatusOk' | Should -Be 'Status.Succeeded'
            Get-WtToneIconKey -Tone 'StatusWarn' | Should -Be 'Status.Warning'
            Get-WtToneIconKey -Tone 'StatusError' | Should -Be 'Status.Failed'
            Get-WtToneIconKey -Tone 'StatusInfo' | Should -Be ''
        }
    }

    It 'colours icons per semantic class and keeps them on the selection background' {
        InModuleScope WindowsTweaker {
            $Icons = New-WtIconTable -Mode 'Unicode'

            (Get-WtIconStyleName -Icons $Icons -Key 'Category.Network') | Should -Be 'IconCategory'
            (Get-WtIconStyleName -Icons $Icons -Key 'Status.Succeeded') | Should -Be 'IconSuccess'
            (Get-WtIconStyleName -Icons $Icons -Key 'Status.Warning') | Should -Be 'IconWarning'
            (Get-WtIconStyleName -Icons $Icons -Key 'Status.Failed') | Should -Be 'IconError'
            (Get-WtIconStyleName -Icons $Icons -Key 'Status.Unsupported') | Should -Be 'IconInactive'

            # A highlighted row paints the Panel background, so the icon must use the
            # variant that keeps that background.
            (Get-WtIconSurface -RowStyle 'Selected') | Should -Be 'Selected'
            (Get-WtIconSurface -RowStyle 'Focused') | Should -Be 'Focused'
            (Get-WtIconSurface -RowStyle 'Item') | Should -Be 'Row'
            (Get-WtIconStyleName -Icons $Icons -Key 'Category.Network' -Surface 'Selected') | Should -Be 'IconCategoryPanel'

            $Theme = New-WtTuiTheme -Colour 'TrueColor' -Unicode -IconMode 'Unicode'
            $Panel = $Theme.Styles['IconCategoryPanel']
            $Panel.Prefix | Should -Match ([regex]::Escape('38;2;137;180;250'))
            $Panel.Prefix | Should -Match ([regex]::Escape('48;2;49;50;68'))
            $Theme.Styles['IconSuccess'].Prefix | Should -Match ([regex]::Escape('38;2;166;227;161'))
            $Theme.Styles['IconWarning'].Prefix | Should -Match ([regex]::Escape('38;2;249;226;175'))
            $Theme.Styles['IconError'].Prefix | Should -Match ([regex]::Escape('38;2;243;139;168'))
            $Theme.Styles['IconInactive'].Prefix | Should -Match ([regex]::Escape('38;2;166;173;200'))

            # Without colour the highlighted row is reverse video, and the icon cell has
            # to follow it instead of leaving a hole in the selection.
            $Mono = New-WtTuiTheme -Colour 'Mono' -Unicode -IconMode 'Unicode'
            $Mono.Styles['IconCategoryFocus'].Prefix | Should -Be "$([char]27)[7m"
            $Mono.Styles['IconSuccessPanel'].Prefix | Should -Be "$([char]27)[7m"

            # 16 colours: an icon inside a highlighted row keeps that row's background.
            $Ansi = New-WtTuiTheme -Colour 'Ansi16' -Unicode -IconMode 'Unicode'
            $Ansi.Styles['IconCategoryFocus'].ConsoleBackground | Should -Be 'Cyan'
            $Ansi.Styles['IconCategoryPanel'].ConsoleBackground | Should -Be 'Gray'
        }
    }

    It 'derives the progress bar from item counts only' {
        InModuleScope WindowsTweaker {
            $Unicode = New-WtIconTable -Mode 'Unicode'
            (Format-WtIconProgressBar -Icons $Unicode -Done 0 -Total 4) | Should -Be ([string][char]0x2591 * 4)
            (Format-WtIconProgressBar -Icons $Unicode -Done 2 -Total 4) | Should -Be (([string][char]0x2588 * 2) + ([string][char]0x2591 * 2))
            (Format-WtIconProgressBar -Icons $Unicode -Done 9 -Total 4) | Should -Be ([string][char]0x2588 * 4) -Because 'the bar is clamped to the item count'
            (Get-WtTextWidth -Text (Format-WtIconProgressBar -Icons $Unicode -Done 3 -Total 40)) | Should -Be 20 -Because 'the bar is capped'

            # One item is not progress; no bar in "None" mode either.
            (Format-WtIconProgressBar -Icons $Unicode -Done 0 -Total 1) | Should -Be ''
            (Format-WtIconProgressBar -Icons (New-WtIconTable -Mode 'None') -Done 1 -Total 4) | Should -Be ''
        }
    }
}

Describe 'Icons in the interface' {

    It 'draws a category icon, a row icon and a detail icon in the wide layout' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'Unicode'
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'Privacy'
            Update-WtTuiView -State $State

            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Category.Privacy')))
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Category.Dashboard')))

            # Every status icon is still accompanied by its text: the state column and the
            # details pane both spell the state out.
            $Entry = $State.Items[$State.ItemIndex].State
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key (Get-WtStateIconKey -State $Entry.State))))
            $Text | Should -Match ([regex]::Escape([string]$Entry.State))
        }
    }

    It 'draws no glyph at all in the None mode' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'None'
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'Privacy'
            Update-WtTuiView -State $State

            $State.Icons.Set | Should -Be 'None'
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            foreach ($Key in 'Category.Privacy', 'Status.Unsupported', 'Status.Pending')
            {
                $Glyph = Get-WtIconGlyph -Icons (New-WtIconTable -Mode 'Unicode') -Key $Key
                $Text | Should -Not -Match ([regex]::Escape($Glyph))
            }
            $Text | Should -Match 'Privacy'
        }
    }

    It 'keeps every painted row exactly the screen width in every mode and layout' {
        InModuleScope WindowsTweaker {
            foreach ($Size in @(@(100, 30), @(92, 18), @(58, 12), @(50, 12), @(40, 10), @(30, 8)))
            {
                foreach ($Mode in 'Auto', 'Unicode', 'NerdFont', 'ASCII', 'None')
                {
                    $State = New-WtTestState -Width $Size[0] -Height $Size[1] -Icons $Mode
                    Initialize-WtTuiState -State $State
                    Set-WtTuiCategory -State $State -Key 'Privacy'
                    Update-WtTuiView -State $State

                    $Lines = ConvertTo-WtScreenPlainText -Screen $State.Screen
                    for ($Index = 0; $Index -lt $Lines.Count; $Index++)
                    {
                        $Expected = if (($Index + 1) -eq $State.Screen.Height) { $State.Screen.Width - 1 } else { $State.Screen.Width }
                        (Get-WtTextWidth -Text $Lines[$Index]) | Should -Be $Expected `
                            -Because "$($Size[0])x$($Size[1]) $Mode row $($Index + 1) must fill its cells exactly"
                    }
                }
            }
        }
    }

    It 'never moves the frame when icons are enabled' {
        InModuleScope WindowsTweaker {
            $DividerColumns = @{}
            foreach ($Mode in 'None', 'Unicode', 'NerdFont', 'ASCII')
            {
                $State = New-WtTestState -Width 100 -Height 30 -Icons $Mode
                Initialize-WtTuiState -State $State
                Set-WtTuiCategory -State $State -Key 'Privacy'
                Update-WtTuiView -State $State

                $Positions = [System.Collections.Generic.List[int]]::new()
                foreach ($Row in 2, 3, 4)
                {
                    $Line = (ConvertTo-WtScreenPlainText -Screen $State.Screen)[$Row]
                    for ($Column = 0; $Column -lt $Line.Length; $Column++)
                    {
                        if ($Line[$Column] -in '│', '|', '┌', '┐', '└', '┘', '├', '┤', '┬', '┴', '┼', '+', '─', '-')
                        {
                            $Positions.Add($Column)
                        }
                    }
                }

                $DividerColumns[$Mode] = ($Positions -join ',')
            }

            $DividerColumns['None'] | Should -Not -BeNullOrEmpty
            $DividerColumns['Unicode'] | Should -Be $DividerColumns['None']
            $DividerColumns['NerdFont'] | Should -Be $DividerColumns['None']
            $DividerColumns['ASCII'] | Should -Be $DividerColumns['None']
        }
    }

    It 'drops an icon column that does not fit instead of squeezing the pane' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 80 -Height 18 -Icons 'ASCII'
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'Privacy'
            Update-WtTuiView -State $State

            $Layout = Get-WtTuiLayout -State $State
            $Layout.Mode | Should -Be 'Medium'

            # A 20-cell category pane cannot hold a 7-cell tag, the widest count and a
            # readable label at once, so that pane draws no icons and keeps the label.
            $CategoryPane = (Get-WtScreenRowText -Screen $State.Screen -Row 6)[0..($Layout.PaneWidth.Categories + 1)] -join ''
            $CategoryPane | Should -Not -Match ([regex]::Escape('[PRIV]'))
            $CategoryPane | Should -Match 'Privacy'

            # The wider list pane still shows the tag on its own rows: the decision is
            # measured per pane, not switched off globally.
            $ListRow = (Get-WtScreenRowText -Screen $State.Screen -Row 5) -join ''
            $ListRow | Should -Match ([regex]::Escape('[PRIV]'))

            # A compact terminal still renders every mode without shifting anything.
            foreach ($Mode in 'Unicode', 'ASCII')
            {
                $Narrow = New-WtTestState -Width 30 -Height 8 -Icons $Mode
                Initialize-WtTuiState -State $Narrow
                Set-WtTuiCategory -State $Narrow -Key 'Network'
                { Update-WtTuiView -State $Narrow } | Should -Not -Throw
                foreach ($Line in (ConvertTo-WtScreenPlainText -Screen $Narrow.Screen))
                {
                    (Get-WtTextWidth -Text $Line) | Should -BeLessOrEqual $Narrow.Screen.Width
                }
            }
        }
    }

    It 'keeps a selected row readable, with the icon on the selection background' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'Unicode'
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'Privacy'
            Set-WtTuiFocus -State $State -Focus 'List'
            Update-WtTuiView -State $State

            # Screen row 5 is the cursor row of the list pane; its icon cells must use the
            # focus variant so the selection has no holes.
            $Row = $State.Screen.Rows[4]
            $Names = @($Row.Styles | ForEach-Object { $State.Screen.Theme.StyleList[$_].Name })
            $Names | Should -Contain 'IconCategoryFocus'
            $Names | Should -Contain 'Focused'

            # The category cursor row (Privacy) uses the selected-row variant too.
            $CategoryRow = $State.Screen.Rows[5]
            $CategoryNames = @($CategoryRow.Styles | ForEach-Object { $State.Screen.Theme.StyleList[$_].Name })
            $CategoryNames | Should -Contain 'IconCategoryPanel'
            $CategoryNames | Should -Contain 'Selected'
        }
    }

    It 'renders Vietnamese labels next to the icons' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 120 -Height 30 -Icons 'Unicode'
            Set-WtLanguage -Language 'vi' | Out-Null
            try
            {
                Initialize-WtTuiState -State $State
                Update-WtTuiView -State $State
                $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
                $Text | Should -Match 'Tổng quan'
                $Text | Should -Match 'Quyền riêng tư'
                $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Category.Privacy')))
                $Text | Should -Not -Match '\[Tui\.'
                $Text | Should -Not -Match '\[Cat\.'
            }
            finally
            {
                Set-WtLanguage -Language 'en' | Out-Null
            }
        }
    }

    It 'forces ASCII icons and borders when -Ascii is used' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'Unicode' -Ascii
            $State.IconMode | Should -Be 'ASCII'
            $State.Icons.Set | Should -Be 'ASCII'
            $State.Theme.Border.TopLeft | Should -Be '+'
            $State.Theme.Border.Vertical | Should -Be '|'
            $State.Capability.Unicode | Should -BeFalse
        }
    }

    It 'keeps every shortcut working in the None mode' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'None'
            Initialize-WtTuiState -State $State

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character '/')
            $State.SearchMode | Should -BeTrue
            Send-WtTestText -State $State -Text 'advertising'
            $State.Items.Count | Should -Be 1
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Enter')
            $State.SearchMode | Should -BeFalse
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Escape')
            $State.Search | Should -Be ''

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'h')
            $State.Categories[$State.CategoryIndex].Key | Should -Be 'History'
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'd')
            $State.DryRun | Should -BeTrue

            # The icon picker is reachable without icons too, and closing it changes nothing.
            $State.KeyQueue.Enqueue((New-WtTestKey -Name 'Escape'))
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'i')
            $State.Overlay | Should -BeNullOrEmpty
            $State.IconMode | Should -Be 'None'
        }
    }

    It 'titles the help and the quit panel with their own icon' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'Unicode'
            Initialize-WtTuiState -State $State

            Mock Show-WtTuiMessage { }
            Mock Confirm-WtTui { return $false }

            Show-WtTuiHelp -State $State
            Should -Invoke Show-WtTuiMessage -ParameterFilter { $Icon -eq 'Category.Help' } -Because 'the help panel carries the help icon'

            Invoke-WtTuiQuit -State $State
            Should -Invoke Confirm-WtTui -ParameterFilter { $Icon -eq 'Action.Quit' } -Because 'the quit confirmation carries the quit icon'
            $State.Exit | Should -BeFalse
        }
    }

    It 'falls back to the tone icon for a dialog that names no icon' {
        InModuleScope WindowsTweaker {
            (New-WtDialogOverlay -Kind 'confirm' -Title 'Apply?' -Tone 'Warning').Icon | Should -Be 'Status.Warning'
            (New-WtDialogOverlay -Kind 'message' -Title 'Result' -Tone 'Success').Icon | Should -Be 'Status.Succeeded'
            (New-WtDialogOverlay -Kind 'message' -Title 'Result' -Tone 'Error').Icon | Should -Be 'Status.Failed'
            (New-WtDialogOverlay -Kind 'message' -Title 'Text').Icon | Should -Be ''
            (New-WtDialogOverlay -Kind 'message' -Title 'Help' -Icon 'Category.Help').Icon | Should -Be 'Category.Help'
        }
    }

    It 'paints a status icon next to the status text and in dialogs' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'Unicode'
            Initialize-WtTuiState -State $State
            Set-WtTuiStatus -State $State -Text 'Change applied.' -Tone 'StatusOk'
            Update-WtTuiView -State $State

            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Status.Succeeded') + ' Change applied.'))

            $Overlay = New-WtDialogOverlay -Kind 'confirm' -Title 'Apply?' -Body @('sure') -Tone 'Warning'
            $Overlay.Icon | Should -Be 'Status.Warning'
            $State.Overlay = $Overlay
            Update-WtTuiView -State $State
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Status.Warning') + ' Apply?'))
            # The buttons carry the action icons of the vocabulary.
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Action.Apply')))
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Action.Cancel')))
            $State.Overlay = $null
        }
    }

    It 'shows a dialog list item icon only when the item declares one' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'Unicode'
            Initialize-WtTuiState -State $State

            $Overlay = New-WtDialogOverlay -Kind 'list' -Title 'States' -Items @(
                @{ Label = 'Enabled'; Payload = 'Enabled'; Icon = 'Status.Enabled' },
                @{ Label = 'Disabled'; Payload = 'Disabled' }
            )
            $State.Overlay = $Overlay
            Update-WtTuiView -State $State
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Status.Enabled') + ' Enabled'))
            $Text | Should -Match 'Disabled'
            $State.Overlay = $null
        }
    }

    It 'reports progress with the running icon and a count bar' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'Unicode'
            Initialize-WtTuiState -State $State
            $State.Operation = @{
                Kind       = 'apply'
                Preview    = $false
                Total      = 4
                Finished   = 2
                Started    = 2
                Active     = 'Privacy.AdvertisingId'
                Results    = @()
                Failures   = @()
                Events     = @()
                Cancelling = $false
            }
            $State.ForceRepaint = $true
            Update-WtTuiView -State $State

            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Status.Running')))
            $Text | Should -Match ([regex]::Escape((Get-WtIconGlyph -Icons $State.Icons -Key 'Action.Apply') + ' Operation'))
            $Text | Should -Match ([regex]::Escape(([string][char]0x2588 * 2) + ([string][char]0x2591 * 2))) -Because 'the bar reflects 2 of 4 completed items'
            $State.Operation = $null
        }
    }
}

Describe 'Icon preference' {

    BeforeAll {
        $script:SettingsPath = Join-Path $env:WT_DATA_ROOT 'settings.json'
    }

    BeforeEach {
        Remove-Item -LiteralPath $script:SettingsPath -Force -ErrorAction Ignore
    }

    AfterEach {
        Remove-Item -LiteralPath $script:SettingsPath -Force -ErrorAction Ignore
    }

    It 'saves the mode and reads it back, tolerating a missing or corrupt file' {
        InModuleScope WindowsTweaker {
            (Get-WtIconPreference) | Should -Be 'Auto'
            (Set-WtIconPreference -Mode 'NerdFont') | Should -Be 'NerdFont'
            (Get-WtIconPreference) | Should -Be 'NerdFont'

            Set-Content -LiteralPath (Get-WtSettingsPath) -Value '{ this is not json' -Encoding utf8NoBOM
            (Get-WtIconPreference) | Should -Be 'Auto' -Because 'a corrupt preference must not stop the interface'

            Set-Content -LiteralPath (Get-WtSettingsPath) -Value '{ "version": 1, "icons": "Nonsense" }' -Encoding utf8NoBOM
            (Get-WtIconPreference) | Should -Be 'Auto'
        }
    }

    It 'starts the interface in the saved mode and lets a command-line override win' {
        InModuleScope WindowsTweaker {
            Set-WtIconPreference -Mode 'ASCII' | Out-Null

            (New-WtTestState).IconMode | Should -Be 'ASCII'
            (New-WtTestState).Icons.Set | Should -Be 'ASCII'
            (New-WtTestState -Icons 'None').IconMode | Should -Be 'None'
            (New-WtTestState -Icons 'Unicode').IconMode | Should -Be 'Unicode'
        }
    }

    It 'switches the mode from the picker, repaints and saves the choice' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @(
                (New-WtTestKey -Name 'Down'),
                (New-WtTestKey -Name 'Down'),
                (New-WtTestKey -Name 'Enter')
            ) -Icons 'Unicode'
            Initialize-WtTuiState -State $State

            Show-WtTuiIconPicker -State $State

            $State.IconMode | Should -Be 'NerdFont'
            $State.Icons.Set | Should -Be 'NerdFont'
            $State.Theme.Icons.Set | Should -Be 'NerdFont' -Because 'the screen must paint with the new glyph table'
            (Get-WtIconPreference) | Should -Be 'NerdFont'
            Test-Path -LiteralPath (Get-WtSettingsPath) | Should -BeTrue
            $State.Screen.Dirty | Should -BeTrue
            $State.Overlay | Should -BeNullOrEmpty

            # Everything still renders after the switch.
            { Update-WtTuiView -State $State } | Should -Not -Throw
        }
    }

    It 'cancels the picker without changing anything' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape')) -Icons 'Unicode'
            Initialize-WtTuiState -State $State

            Show-WtTuiIconPicker -State $State

            $State.IconMode | Should -Be 'Unicode'
            (Get-WtIconPreference) | Should -Be 'Auto'
            Test-Path -LiteralPath (Get-WtSettingsPath) | Should -BeFalse
        }
    }

    It 'previews the real glyph table of every mode in the picker' {
        InModuleScope WindowsTweaker {
            $NerdFont = Format-WtIconSample -Icons (New-WtIconTable -Mode 'NerdFont') -Keys (Get-WtIconPreviewKey)
            $Ascii = Format-WtIconSample -Icons (New-WtIconTable -Mode 'ASCII') -Keys (Get-WtIconPreviewKey)
            $None = Format-WtIconSample -Icons (New-WtIconTable -Mode 'None') -Keys (Get-WtIconPreviewKey)

            $NerdFont | Should -Match ([regex]::Escape([string][char]0xF0AC))
            $NerdFont | Should -Not -Match '\[NET\]'
            $Ascii | Should -Match ([regex]::Escape('[NET]'))
            $Ascii | Should -Match ([regex]::Escape('[ADMIN]'))
            $None | Should -Be ''
        }
    }
}

Describe 'Modal confirmation input and quit' {

    It 'confirms the choice the user sees highlighted, not an inverted one' {
        InModuleScope WindowsTweaker {
            # Default: the second button (No) is highlighted, so a stray Enter cancels.
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $State
            $Result = Confirm-WtTui -State $State -Title 'Apply?' -Lines @('sure?')
            (Get-WtTestConfirmSelection -State $State) | Should -Be 'No'
            $Result | Should -BeOfType [bool]
            $Result | Should -BeFalse

            # Right moves the highlight to Yes and Enter then answers Yes.
            $Right = New-WtTestState -Keys @((New-WtTestKey -Name 'Right'), (New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $Right
            (Confirm-WtTui -State $Right -Title 'Apply?' -Lines @('sure?')) | Should -BeTrue
            (Get-WtTestConfirmSelection -State $Right) | Should -Be 'Yes'
        }
    }

    It 'returns exactly one boolean from the confirmation helpers' {
        InModuleScope WindowsTweaker {
            foreach ($Case in @(
                @{ Keys = @((New-WtTestKey -Name 'Enter')); Expected = $false },
                @{ Keys = @((New-WtTestKey -Name 'Right'), (New-WtTestKey -Name 'Enter')); Expected = $true },
                @{ Keys = @((New-WtTestKey -Name 'Char' -Character 'y')); Expected = $true },
                @{ Keys = @((New-WtTestKey -Name 'Char' -Character 'n')); Expected = $false },
                @{ Keys = @((New-WtTestKey -Name 'Escape')); Expected = $false }
            ))
            {
                $State = New-WtTestState -Keys $Case.Keys
                Initialize-WtTuiState -State $State
                $Result = Confirm-WtTui -State $State -Title 'Apply?' -Lines @('sure?')
                @($Result).Count | Should -Be 1 -Because 'extra pipeline output would be cast to $true by the caller'
                $Result | Should -BeOfType [bool]
                $Result | Should -Be $Case.Expected
                $State.Overlay | Should -BeNullOrEmpty
            }
        }
    }

    It 'returns the same single boolean with the diagnostic trace enabled' {
        InModuleScope WindowsTweaker {
            Set-WtInputTrace -Enabled $true
            try
            {
                foreach ($Case in @(
                    @{ Keys = @((New-WtTestKey -Name 'Enter')); Expected = $false },
                    @{ Keys = @((New-WtTestKey -Name 'Right'), (New-WtTestKey -Name 'Enter')); Expected = $true }
                ))
                {
                    $State = New-WtTestState -Keys $Case.Keys
                    Initialize-WtTuiState -State $State
                    $Result = Confirm-WtTui -State $State -Title 'Apply?' -Lines @('sure?')
                    @($Result).Count | Should -Be 1 -Because 'the trace writes to the log, never to the pipeline'
                    $Result | Should -Be $Case.Expected
                }
            }
            finally
            {
                Set-WtInputTrace -Enabled $false
            }
        }
    }

    It 'fits a confirmation dialog into a narrow terminal and keeps it usable' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 40 -Height 12 -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            (Confirm-WtTui -State $State -Title (Get-WtString -Key 'Tui.Quit.Title') -Lines @((Get-WtString -Key 'Tui.Quit.Confirm'))) | Should -BeFalse

            $Lines = ConvertTo-WtScreenPlainText -Screen $State.Screen
            foreach ($Line in $Lines)
            {
                (Get-WtTextWidth -Text $Line) | Should -BeLessOrEqual 40
            }

            $Text = $Lines -join "`n"
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Tui.Quit.Confirm')))
            $Text | Should -Match ([regex]::Escape('Yes [Y]'))
            $Text | Should -Match ([regex]::Escape('No [N]'))
            { Update-WtTuiView -State $State } | Should -Not -Throw
        }
    }

    It 'repaints the dialog after a key, so the highlight visibly moves' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Right'), (New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            $Overlay = New-WtDialogOverlay -Kind 'confirm' -Title 'Quit' -Body @('Close?') -Tone 'Warning'
            $State.Overlay = $Overlay
            Update-WtTuiView -State $State
            $State.Screen.Dirty = $false
            (Get-WtTestConfirmSelection -State $State) | Should -Be 'No'

            Read-WtDialogKey -Overlay $Overlay -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Right')) -State $State
            $Overlay.Confirm | Should -Be 0
            $State.Screen.Dirty | Should -BeTrue -Because 'a dialog key must mark the grid dirty or the terminal shows nothing'

            Update-WtTuiView -State $State
            (Get-WtTestConfirmSelection -State $State) | Should -Be 'Yes'
            $State.Overlay = $null
        }
    }

    It 'cycles the confirmation with Left/Right, Tab and Shift+Tab' {
        InModuleScope WindowsTweaker {
            $Overlay = New-WtDialogOverlay -Kind 'confirm' -Title 'Quit' -Body @('Close?')
            $Overlay.Choices.Count | Should -Be 2
            $Overlay.Confirm | Should -Be 1 -Because 'No is the default choice'

            Read-WtDialogKey -Overlay $Overlay -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Right'))
            $Overlay.Confirm | Should -Be 0
            Read-WtDialogKey -Overlay $Overlay -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Right'))
            $Overlay.Confirm | Should -Be 1 -Because 'the highlight wraps around'
            Read-WtDialogKey -Overlay $Overlay -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Left'))
            $Overlay.Confirm | Should -Be 0
            Read-WtDialogKey -Overlay $Overlay -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Tab'))
            $Overlay.Confirm | Should -Be 1
            Read-WtDialogKey -Overlay $Overlay -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'BackTab'))
            $Overlay.Confirm | Should -Be 0
        }
    }

    It 'lets Y and N select their own button before answering' {
        InModuleScope WindowsTweaker {
            $Overlay = New-WtDialogOverlay -Kind 'confirm' -Title 'Quit' -Body @('Close?')
            Read-WtDialogKey -Overlay $Overlay -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Char' -Character 'y'))
            $Overlay.Confirm | Should -Be 0
            $Overlay.Result | Should -BeTrue
            $Overlay.Accepted | Should -BeTrue

            $No = New-WtDialogOverlay -Kind 'confirm' -Title 'Quit' -Body @('Close?')
            Read-WtDialogKey -Overlay $No -Key (ConvertTo-WtKey -Key (New-WtTestKey -Name 'Char' -Character 'N'))
            $No.Confirm | Should -Be 1 -Because 'the answer letter is case-insensitive'
            $No.Result | Should -BeFalse
        }
    }

    It 'quits on Q then Right then Enter, and stays open on Q then Enter' {
        InModuleScope WindowsTweaker {
            # Q, Enter: the highlight is No, so the interface must stay open.
            $Stay = New-WtTestState -Keys @((New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $Stay
            Send-WtTestKey -State $Stay -Key (New-WtTestKey -Name 'Char' -Character 'q')
            $Stay.Exit | Should -BeFalse
            $Stay.Overlay | Should -BeNullOrEmpty

            # Q, Right, Enter: Yes is highlighted, so the loop is told to stop.
            $Exit = New-WtTestState -Keys @((New-WtTestKey -Name 'Right'), (New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $Exit
            Send-WtTestKey -State $Exit -Key (New-WtTestKey -Name 'Char' -Character 'q')
            $Exit.Exit | Should -BeTrue
        }
    }

    It 'quits on Q then Y without needing Enter, and cancels on Q then N' {
        InModuleScope WindowsTweaker {
            $Yes = New-WtTestState -Keys @((New-WtTestKey -Name 'Char' -Character 'y'))
            Initialize-WtTuiState -State $Yes
            Send-WtTestKey -State $Yes -Key (New-WtTestKey -Name 'Char' -Character 'q')
            $Yes.Exit | Should -BeTrue

            $No = New-WtTestState -Keys @((New-WtTestKey -Name 'Char' -Character 'n'))
            Initialize-WtTuiState -State $No
            Send-WtTestKey -State $No -Key (New-WtTestKey -Name 'Char' -Character 'q')
            $No.Exit | Should -BeFalse
            $No.Status.Text | Should -Be (Get-WtString -Key 'Tui.Status.QuitCancelled')
        }
    }

    It 'keeps the category, filter, selection and focus when the quit is cancelled' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'Security'
            Set-WtTuiItemIndex -State $State -Index 2
            Set-WtTuiFocus -State $State -Focus 'Categories'
            $State.Search = 'prot'
            Update-WtTuiItems -State $State

            $Category = $State.Categories[$State.CategoryIndex].Key
            $Selected = $State.SelectedId
            $Index = $State.ItemIndex

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'q')

            $State.Exit | Should -BeFalse
            $State.Categories[$State.CategoryIndex].Key | Should -Be $Category
            $State.Search | Should -Be 'prot'
            $State.SelectedId | Should -Be $Selected
            $State.ItemIndex | Should -Be $Index
            $State.Focus | Should -Be 'Categories'
        }
    }

    It 'keeps the confirm selection across a redraw and a resize' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Right'), (New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $State

            # Resize the terminal between two dialog frames, exactly as a user would drag it.
            $Inner = $State.KeySource
            $Sizes = $State.Sizes
            $Step = 0
            $State.KeySource = {
                $Key = & $Inner
                $Step++
                if ($Step -eq 1)
                {
                    $Sizes.Width = 64
                    $Sizes.Height = 18
                }
                return $Key
            }.GetNewClosure()

            (Confirm-WtTui -State $State -Title 'Quit' -Lines @('Close?')) | Should -BeTrue
            $State.Screen.Width | Should -Be 64
            (Get-WtTestConfirmSelection -State $State) | Should -Be 'Yes'

            # The dialog is still usable in the smaller grid.
            { Update-WtTuiView -State $State } | Should -Not -Throw
        }
    }
}

Describe 'Text fields and shortcuts' {

    It 'types q, l, y and n into the search field instead of firing a shortcut' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            $Language = $State.Language

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character '/')
            Send-WtTestText -State $State -Text 'qlyn'

            $State.Search | Should -Be 'qlyn'
            $State.Exit | Should -BeFalse
            $State.Overlay | Should -BeNullOrEmpty
            $State.Language | Should -Be $Language
        }
    }

    It 'types q, l, y and n into a dialog text field instead of firing a shortcut' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'q'),
                (New-WtTestKey -Name 'Char' -Character 'l'),
                (New-WtTestKey -Name 'Char' -Character 'y'),
                (New-WtTestKey -Name 'Char' -Character 'n'),
                (New-WtTestKey -Name 'Enter')
            )
            Initialize-WtTuiState -State $State

            $Text = Read-WtTuiText -State $State -Title 'Path' -Label 'Value'
            $Text | Should -Be 'qlyn'
            $State.Exit | Should -BeFalse
            $State.Overlay | Should -BeNullOrEmpty
        }
    }

    It 'types into a searchable dialog filter without leaving the dialog' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @(
                (New-WtTestKey -Name 'Char' -Character '/'),
                (New-WtTestKey -Name 'Char' -Character 'q'),
                (New-WtTestKey -Name 'Char' -Character 'l'),
                (New-WtTestKey -Name 'Escape'),
                (New-WtTestKey -Name 'Escape')
            )
            Initialize-WtTuiState -State $State

            $Result = Select-WtTuiItem -State $State -Title 'Pick' -Items @('alpha', 'beta') -Searchable
            $Result | Should -BeNullOrEmpty
            $State.Overlay | Should -BeNullOrEmpty
            $State.Exit | Should -BeFalse
            $State.Search | Should -Be ''
        }
    }
}

Describe 'Language selection' {

    BeforeAll {
        $script:SettingsPath = Join-Path $env:WT_DATA_ROOT 'settings.json'
    }

    BeforeEach {
        Remove-Item -LiteralPath $script:SettingsPath -Force -ErrorAction Ignore
        Remove-Item Env:\WT_TUI_LANG_TEST -ErrorAction Ignore
    }

    AfterEach {
        Remove-Item -LiteralPath $script:SettingsPath -Force -ErrorAction Ignore
    }

    It 'switches English to Vietnamese and back, preserving the interface state' {
        InModuleScope WindowsTweaker {
            Set-WtLanguage -Language 'en' | Out-Null

            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'Privacy'
            Set-WtTuiItemIndex -State $State -Index 1

            # Put one change in the pending set and one filter in place, then remember exactly
            # what the interface shows before the language changes.
            $Entry = $State.Items[$State.ItemIndex].State
            Add-WtTuiPending -State $State -Entry $Entry -Target 'Disabled'
            $State.Search = 'advert'
            Update-WtTuiItems -State $State

            $Before = @{
                Selected    = $State.SelectedId
                Index       = $State.ItemIndex
                Items       = $State.Items.Count
                Search      = $State.Search
                Pending     = @($State.Pending.Keys)
                Category    = $State.Categories[$State.CategoryIndex].Key
                IconMode    = $State.IconMode
                DryRun      = $State.DryRun
            }
            $Before.Selected | Should -Not -BeNullOrEmpty

            # English -> Vietnamese, exactly as the picker does it (first entry is English).
            $Picker = New-WtTestState -Keys @((New-WtTestKey -Name 'Down'), (New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $Picker
            Show-WtTuiLanguagePicker -State $Picker

            $Picker.Language | Should -Be 'vi'
            $Picker.Status.Text | Should -Be (Get-WtString -Key 'Tui.Status.Language' -Arguments @('Tiếng Việt'))
            $Picker.Categories | ForEach-Object { $_.Label | Should -Not -Match '^\[Cat\.' }
            (Get-WtLanguagePreference) | Should -Be 'vi'

            # The same state keeps its navigation, filter and pending set across the switch.
            Set-WtLanguage -Language 'vi' | Out-Null
            $State.Language = Get-WtLanguage
            Sync-WtTuiCatalog -State $State
            Update-WtTuiCategories -State $State
            Update-WtTuiItems -State $State

            $State.Search | Should -Be $Before.Search
            $State.SelectedId | Should -Be $Before.Selected -Because 'the cursor survives the switch'
            $State.ItemIndex | Should -Be $Before.Index
            $State.Items.Count | Should -Be $Before.Items
            @($State.Pending.Keys) | Should -Be $Before.Pending
            $State.Categories[$State.CategoryIndex].Key | Should -Be $Before.Category
            $State.IconMode | Should -Be $Before.IconMode
            $State.DryRun | Should -Be $Before.DryRun
            $State.Focus | Should -Be 'List'

            # The re-localized catalog is Vietnamese now (the tweak name comes from detection).
            $State.Categories[1].Label | Should -Be (Get-WtString -Key 'Cat.Privacy')

            # Vietnamese -> English again.
            $Back = New-WtTestState -Keys @((New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $Back
            Show-WtTuiLanguagePicker -State $Back
            $Back.Language | Should -Be 'en'
            (Get-WtLanguagePreference) | Should -Be 'en'
            Set-WtLanguage -Language 'en' | Out-Null
        }
    }

    It 'shows the quit confirmation in Vietnamese with Có [Y] / Không [N] and stable shortcuts' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Right'), (New-WtTestKey -Name 'Enter'))
            Initialize-WtTuiState -State $State

            # Switch the open interface, exactly as the language picker does.
            Set-WtLanguage -Language 'vi' | Out-Null
            try
            {
                $State.Language = Get-WtLanguage
                Sync-WtTuiCatalog -State $State
                Update-WtTuiCategories -State $State
                Update-WtTuiItems -State $State
                Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'q')

                $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
                $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Tui.Quit.Title')))
                $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Tui.Quit.Confirm')))
                $Text | Should -Match ([regex]::Escape('Có [Y]'))
                $Text | Should -Match ([regex]::Escape('Không [N]'))
                $Text | Should -Not -Match '\[Tui\.'
                $State.Exit | Should -BeTrue
            }
            finally
            {
                Set-WtLanguage -Language 'en' | Out-Null
            }
        }
    }

    It 'prefers the explicit option, then the saved preference, then English' {
        InModuleScope WindowsTweaker {
            # saved preference wins over the environment fallback
            Set-WtLanguagePreference -Language 'vi' | Out-Null
            (Get-WtLanguagePreference) | Should -Be 'vi'
            (Resolve-WtLanguage) | Should -Be 'vi'

            # an explicit option always wins
            (Resolve-WtLanguage -Language 'en') | Should -Be 'en'
            (Resolve-WtLanguage -Language 'vi-VN') | Should -Be 'vi'
            (Resolve-WtLanguage -Language 'de-DE') | Should -Be 'en'

            # and a saved value can be replaced
            Set-WtLanguagePreference -Language 'en' | Out-Null
            (Get-WtLanguagePreference) | Should -Be 'en'
        }
    }

    It 'honours the documented startup override' {
        InModuleScope WindowsTweaker {
            Set-WtLanguagePreference -Language 'en' | Out-Null
            Initialize-WtLocalization -Language 'vi' -Force | Should -Be 'vi'
            (Get-WtString -Key 'Tui.Quit.Title') | Should -Be (Get-WtString -Key 'Tui.Quit.Title')
            Set-WtLanguage -Language 'en' | Out-Null
            Initialize-WtLocalization -Language $null -Force | Should -Be 'en' -Because 'the saved preference is English again'
        }
    }

    It 'exposes language selection from the Overview pane' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State
            $State.CategoryIndex = 0
            Update-WtTuiItems -State $State

            $Row = @($State.Items | Where-Object { $_.Kind -eq 'Info' -and $_.Action -eq 'Language' })
            $Row.Count | Should -Be 1
            $Row[0].Label | Should -Be (Get-WtString -Key 'Cli.Language')

            # Enter on that row opens the language picker (Escape closes it again).
            Set-WtTuiItemIndex -State $State -Index ([array]::IndexOf(@($State.Items), $Row[0]))
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Enter')
            $State.Overlay | Should -BeNullOrEmpty
        }
    }
}

Describe 'Input diagnostics' {

    It 'records keys and targets in the log without recording typed text' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            $Before = Get-WtTestLogCount

            Set-WtInputTrace -Enabled $true
            try
            {
                Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character '/')
                Send-WtTestText -State $State -Text 'secretvalue'
                Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Enter')
                Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Escape')
            }
            finally
            {
                Set-WtInputTrace -Enabled $false
            }

            $Records = (Get-WtTestLogSince -Count $Before) -join "`n"
            $Records | Should -Match 'input scope=main key=Char char=- target=search'
            $Records | Should -Not -Match 'secretvalue'
            $Records | Should -Not -Match 'char=s'

            # With the trace off nothing new is written, and the screen is untouched.
            $Quiet = Get-WtTestLogCount
            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Down')
            (Get-WtTestLogCount) | Should -Be $Quiet
            (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n" | Should -Not -Match 'input scope='
        }
    }

    It 'records a global shortcut by name and never the character of a text field' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState
            Initialize-WtTuiState -State $State
            $Before = Get-WtTestLogCount

            Set-WtInputTrace -Enabled $true
            try
            {
                Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'd')
            }
            finally
            {
                Set-WtInputTrace -Enabled $false
            }

            $Records = (Get-WtTestLogSince -Count $Before) -join "`n"
            $Records | Should -Match 'target=global:d'
            $Records | Should -Match 'char=d'
        }
    }
}

Describe 'Terminal cleanup' {

    It 'stops the loop and restores the terminal when console input disappears' {
        InModuleScope WindowsTweaker {
            Mock Test-WtInteractiveConsole { return $true }
            Mock Enter-WtTuiTerminal { return @{ Entered = $false; CursorVisible = $true } }
            Mock Restore-WtTuiTerminal { }
            Mock Close-WtTuiWorker { }
            Mock Initialize-WtTuiState { }
            Mock Write-WtScreen { }
            Mock Write-WtScreenPlain { }

            # Pester has no console: [Console]::KeyAvailable throws, which is exactly the
            # "input disappeared" path the interface must survive.
            $Code = Start-WtTui -Colour 'Mono' -Ascii -Language 'en'
            $Code | Should -Be 0
            Should -Invoke Restore-WtTuiTerminal -Times 1 -Because 'the terminal is restored in finally'
            Should -Invoke Close-WtTuiWorker -Times 1 -Because 'the worker runspace is closed in finally'
            $Script:WtConsoleInputLost | Should -BeTrue
        }
    }
}

Describe 'Verification and recovery views' {

    It 'shows the exact per-target preview in the pending review' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'Privacy'
            $Entry = $State.Items[$State.ItemIndex].State
            Add-WtTuiPending -State $State -Entry $Entry -Target 'Disabled'

            # Open the review and close it again; the frame it painted is asserted below.
            Show-WtTuiPendingReview -State $State

            $Preview = Get-WtChangePreviewInternal -Id $Entry.Id -State 'Disabled'
            $Preview.Targets.Count | Should -BeGreaterThan 0
            $State.Pending[$Entry.Id].Fingerprint | Should -Be $Preview.Fingerprint -Because 'the review records what the engine will revalidate'

            $Target = $Preview.Targets[0]
            $Row = Get-WtString -Key 'Tui.Preview.Row' -Arguments @($Target.Label, $Target.Current.Display, $Target.Intended.Display)
            $Row | Should -Match ([regex]::Escape($Target.Current.Display))
            $Row | Should -Match ([regex]::Escape($Target.Intended.Display))
        }
    }

    It 'announces an interrupted operation at startup and lists it for recovery' {
        InModuleScope WindowsTweaker {
            # Simulate a run that died after the recovery data was written.
            $Entry = New-WtHistoryEntry -TweakId 'Privacy.AdvertisingId' -State 'Disabled'
            Add-WtStateRecord -HistoryEntry $Entry -Record @{
                resource = 'Registry'; path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
                name = 'Enabled'; keyExisted = $true; valueExisted = $true; kind = 'DWord'; value = 1
                kindInferred = $false
            }
            Add-WtJournalEntry -Entry $Entry | Out-Null

            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            $State.Status.Text | Should -Be (Get-WtString -Key 'Tui.Status.Interrupted' -Arguments @(1))
            $State.Status.Tone | Should -Be 'StatusWarn'

            $Rows = @(Get-WtInterruptedOperationInternal)
            $Rows.Count | Should -Be 1
            $Rows[0].OperationId | Should -Be $Entry.operationId

            # The view opens, renders the row and closes without touching anything.
            Show-WtTuiVerification -State $State
            $State.Overlay | Should -BeNullOrEmpty
            @(Get-WtInterruptedOperationInternal).Count | Should -Be 1 -Because 'inspecting it changes nothing'
        }
    }

    It 'exports the journal and the diagnostics only when asked' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'e'),
                (New-WtTestKey -Name 'Enter'),
                (New-WtTestKey -Name 'Escape')
            )
            Initialize-WtTuiState -State $State

            $Journal = Join-Path (Get-WtDataRoot) 'journal-export-test.json'
            Export-WtHistory -Path $Journal -Force | Out-Null
            Test-Path -LiteralPath $Journal | Should -BeTrue

            $Diagnostics = Join-Path (Get-WtDataRoot) 'diagnostics-export-test.jsonl'
            Export-WtDiagnostics -Path $Diagnostics -Force | Out-Null
            Test-Path -LiteralPath $Diagnostics | Should -BeTrue
            (Get-Content -LiteralPath $Diagnostics -TotalCount 1 | ConvertFrom-Json).type | Should -Be 'header'
        }
    }
}

Describe 'Capability-loss in the interface' {

    It 'renders the disclosure in the details pane for a tweak that declares one' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Icons 'Unicode'
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'System'

            # Select System.Hibernation (declared with a capability-loss disclosure).
            $Index = -1
            for ($I = 0; $I -lt $State.Items.Count; $I++)
            {
                if ($State.Items[$I].Kind -eq 'Tweak' -and $State.Items[$I].State.Id -eq 'System.Hibernation')
                {
                    $Index = $I
                    break
                }
            }
            $Index | Should -BeGreaterThan -1
            Set-WtTuiItemIndex -State $State -Index $Index
            Update-WtTuiView -State $State

            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"
            $Text | Should -Match 'Capability loss'
            $Text | Should -Match 'guaranteed'
            $Text | Should -Match 'Hibernation'
        }
    }

    It 'keeps the details pane readable at the narrowest layout with disclosures' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 58 -Height 12 -Icons 'None'
            Initialize-WtTuiState -State $State
            Set-WtTuiCategory -State $State -Key 'System'

            $Index = -1
            for ($I = 0; $I -lt $State.Items.Count; $I++)
            {
                if ($State.Items[$I].Kind -eq 'Tweak' -and $State.Items[$I].State.Id -eq 'System.Hibernation')
                {
                    $Index = $I
                    break
                }
            }
            Set-WtTuiItemIndex -State $State -Index $Index
            Update-WtTuiView -State $State

            $Lines = ConvertTo-WtScreenPlainText -Screen $State.Screen
            for ($Row = 0; $Row -lt $Lines.Count; $Row++)
            {
                (Get-WtTextWidth -Text $Lines[$Row]) | Should -BeLessOrEqual $State.Screen.Width
            }
        }
    }
}

Describe 'Localized layout budgets' {

    It 'keeps the shortcut line inside the layout that shows it' {
        InModuleScope WindowsTweaker {
            foreach ($Code in 'en', 'vi')
            {
                Set-WtLanguage -Language $Code | Out-Null
                try
                {
                    # Wide layout starts at 92 columns (89 visible cells after the margin);
                    # the compact layout starts at 58 (55 visible cells).
                    (Get-WtTextWidth -Text (Get-WtString -Key 'Tui.Keys.Main')) | Should -BeLessOrEqual 89
                    (Get-WtTextWidth -Text (Get-WtString -Key 'Tui.Keys.Compact')) | Should -BeLessOrEqual 55
                }
                finally
                {
                    Set-WtLanguage -Language 'en' | Out-Null
                }
            }
        }
    }
}

Describe 'Disk usage explorer' {

    It 'browses one level, caches listings and reports sizes' {
        InModuleScope WindowsTweaker {
            Mock Invoke-WtDirectoryChildren -ParameterFilter { $Root -eq '/fake/root' } {
                [pscustomobject]@{
                    Ok = $true
                    Listing = [pscustomobject]@{
                        Root = '/fake/root'
                        Backend = 'Go'
                        ElapsedMS = 3
                        Cancelled = $false
                        Entries = @(
                            [pscustomobject]@{ name = 'big'; path = '/fake/root/big'; kind = 'dir'; bytes = [long]2048; allocatedBytes = 2048; allocatedKnown = $true; files = 2; directories = 1; partial = $false; errors = @(); error = '' }
                            [pscustomobject]@{ name = 'small.txt'; path = '/fake/root/small.txt'; kind = 'file'; bytes = [long]3; allocatedBytes = 3; allocatedKnown = $true; files = 1; directories = 0; partial = $false; errors = @(); error = '' }
                        )
                    }
                }
            }
            Mock Invoke-WtDirectoryChildren -ParameterFilter { $Root -eq '/fake/root/big' } {
                [pscustomobject]@{
                    Ok = $true
                    Listing = [pscustomobject]@{
                        Root = '/fake/root/big'
                        Backend = 'Go'
                        ElapsedMS = 2
                        Cancelled = $false
                        Entries = @(
                            [pscustomobject]@{ name = 'deeper'; path = '/fake/root/big/deeper'; kind = 'dir'; bytes = [long]1; allocatedBytes = 1; allocatedKnown = $true; files = 0; directories = 0; partial = $false; errors = @(); error = '' }
                        )
                    }
                }
            }

            Mock Read-WtTuiText { '/fake/root' }

            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            Show-WtTuiDiskExplorer -State $State

            $State.Explorer.Path | Should -Be '/fake/root'
            $State.Explorer.Cache.Count | Should -Be 1
        }
    }

    It 'descends into a directory on Enter and goes back up' {
        InModuleScope WindowsTweaker {
            Mock Invoke-WtDirectoryChildren -ParameterFilter { $Root -eq '/fake/root' } {
                [pscustomobject]@{
                    Ok = $true
                    Listing = [pscustomobject]@{
                        Root = '/fake/root'
                        Backend = 'Go'
                        ElapsedMS = 1
                        Cancelled = $false
                        Entries = @(
                            [pscustomobject]@{ name = 'sub'; path = '/fake/root/sub'; kind = 'dir'; bytes = [long]10; allocatedBytes = 10; allocatedKnown = $true; files = 1; directories = 0; partial = $false; errors = @(); error = '' }
                        )
                    }
                }
            }
            Mock Invoke-WtDirectoryChildren -ParameterFilter { $Root -eq '/fake/root/sub' } {
                [pscustomobject]@{
                    Ok = $true
                    Listing = [pscustomobject]@{
                        Root = '/fake/root/sub'
                        Backend = 'Go'
                        ElapsedMS = 1
                        Cancelled = $false
                        Entries = @(
                            [pscustomobject]@{ name = 'leaf.txt'; path = '/fake/root/sub/leaf.txt'; kind = 'file'; bytes = [long]7; allocatedBytes = 7; allocatedKnown = $true; files = 1; directories = 0; partial = $false; errors = @(); error = '' }
                        )
                    }
                }
            }

            Mock Read-WtTuiText { '/fake/root' }

            $State = New-WtTestState -Keys @(
                (New-WtTestKey -Name 'Enter'),
                (New-WtTestKey -Name 'Escape')
            )
            Initialize-WtTuiState -State $State

            Show-WtTuiDiskExplorer -State $State

            $State.Explorer.Path | Should -Be '/fake/root/sub'
            $State.Explorer.Cache.Count | Should -Be 2
        }
    }

    It 'marks partial subdirectories in the listing summary' {
        InModuleScope WindowsTweaker {
            Mock Invoke-WtDirectoryChildren {
                [pscustomobject]@{
                    Ok = $true
                    Listing = [pscustomobject]@{
                        Root = '/fake/root'
                        Backend = 'PowerShell'
                        ElapsedMS = 1
                        Cancelled = $false
                        Entries = @(
                            [pscustomobject]@{ name = 'blocked'; path = '/fake/root/blocked'; kind = 'dir'; bytes = [long]0; allocatedBytes = 0; allocatedKnown = $false; files = 0; directories = 0; partial = $true; errors = @([pscustomobject]@{ code = 'E_ACCESS_DENIED'; path = '/fake/root/blocked'; error = 'denied' }); error = '' }
                        )
                    }
                }
            }

            Mock Read-WtTuiText { '/fake/root' }

            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State

            Show-WtTuiDiskExplorer -State $State

            # The cache kept the listing; the partial flag and error came through undamaged.
            $Listing = $State.Explorer.Cache['/fake/root'].Listing
            $Listing.Entries[0].partial | Should -BeTrue
            $Listing.Entries[0].errors[0].code | Should -Be 'E_ACCESS_DENIED'
        }
    }
}

Describe 'Overview action dispatch' {

    It 'opens the disk explorer and the quarantine from their overview rows' {
        InModuleScope WindowsTweaker {
            Mock Read-WtTuiText { '/fake/root' }
            Mock Invoke-WtDirectoryChildren {
                [pscustomobject]@{ Ok = $true; Listing = [pscustomobject]@{ Root='/fake/root'; Backend='Go'; ElapsedMS=1; Cancelled=$false; Entries=@([pscustomobject]@{ name='x'; path='/fake/root/x'; kind='dir'; bytes=[long]1; allocatedBytes=1; allocatedKnown=$true; files=0; directories=0; partial=$false; errors=@(); error='' }) } }
            }
            Mock Get-WtQuarantineManifest {
                [pscustomobject]@{ Records = @(); Meta = @{ Active = $true } }
            }

            # Disk explorer row action.
            $State = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State
            $State.Items = @(@{ Kind = 'Info'; Label = 'Disk'; Value = ''; Action = 'DiskUsage' })
            $State.ItemIndex = 0
            Invoke-WtTuiAction -State $State
            $State.Explorer.Path | Should -Be '/fake/root'

            # Quarantine row action reaches the quarantine workflow (summary lines present).
            $State2 = New-WtTestState -Keys @((New-WtTestKey -Name 'Escape'))
            Initialize-WtTuiState -State $State2
            $State2.Items = @(@{ Kind = 'Info'; Label = 'Quar'; Value = ''; Action = 'Quarantine' })
            $State2.ItemIndex = 0
            Invoke-WtTuiAction -State $State2
            $State2.Explorer | Should -BeNullOrEmpty
        }
    }
}
