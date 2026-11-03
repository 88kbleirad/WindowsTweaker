# WindowsTweaker - WinUI frontend wiring contract tests.
#
# The WinUI window is not compiled by the Linux gate (the XAML markup compiler is a Windows
# process) and a bad binding or a missing localization key does not fail any build - it shows
# up on a Windows screen as a default-valued control or a raw "[Gui.Key]" label. These tests
# check the parts that can be checked without Windows:
#   * every localization key the frontend references exists in both merged language tables;
#   * every XAML dependency names a resource the theme actually defines;
#   * every navigation glyph is one the shipped icon font carries.
# The binding-path and event-handler checks live in the C# suite
# (WinUiXamlWiringTests), where the view-model assembly can be reflected.

BeforeAll {
    $script:RepoRoot = Join-Path $PSScriptRoot '..'
    $script:WinUiRoot = Join-Path $script:RepoRoot 'gui/src/WindowsTweaker.WinUI'

    # The same merge the bridge serves: the language table, then the catalog/insight tables,
    # then the terminal tables (all shipped psd1 files under Data/).
    $script:Tables = @{}
    foreach ($Lang in @('en', 'vi')) {
        $Table = @{}
        Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'src/WindowsTweaker/Data') -Filter "Strings.$Lang*.psd1" -File |
            ForEach-Object {
                $FileTable = Import-PowerShellDataFile -LiteralPath $_.FullName
                foreach ($Entry in $FileTable.GetEnumerator()) { $Table[$Entry.Key] = $Entry.Value }
            }
        $script:Tables[$Lang] = $Table
    }

    $script:FrontendFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'gui/src') -Recurse -Include '*.xaml', '*.cs' -File |
        Where-Object { $_.FullName -notmatch '[\\/]obj[\\/]|[\\/]bin[\\/]' })
}

Describe 'WinUI frontend wiring' {

    It 'references only localization keys that both shipped tables define' {
        $script:FrontendFiles.Count | Should -BeGreaterThan 0

        $Missing = New-Object System.Collections.ArrayList
        foreach ($File in $script:FrontendFiles) {
            $Text = Get-Content -Raw -LiteralPath $File.FullName
            $Keys = New-Object System.Collections.Generic.HashSet[string]
            foreach ($Pattern in @(
                    'Strings\[([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)\]',
                    'Strings(?:\.Get)?\("([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)"',
                    "Strings\.Get\('([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)'"
                )) {
                foreach ($Match in [regex]::Matches($Text, $Pattern)) {
                    $null = $Keys.Add($Match.Groups[1].Value)
                }
            }

            foreach ($Key in $Keys) {
                foreach ($Lang in @('en', 'vi')) {
                    if (-not $script:Tables[$Lang].ContainsKey($Key)) {
                        $null = $Missing.Add("$Key is used by $($File.Name) but is not in the merged $Lang tables")
                    }
                }
            }
        }

        $Missing.Count | Should -Be 0 -Because ($Missing -join '; ')
    }

    It 'resolves every theme resource the window asks for' {
        $Xaml = Get-Content -Raw -LiteralPath (Join-Path $script:WinUiRoot 'MainWindow.xaml')
        $Theme = ''
        foreach ($File in @('Themes/CatppuccinMocha.xaml', 'App.xaml')) {
            $Theme += Get-Content -Raw -LiteralPath (Join-Path $script:WinUiRoot $File)
        }

        $Missing = New-Object System.Collections.ArrayList
        foreach ($Match in [regex]::Matches($Xaml, '\{StaticResource\s+([A-Za-z][A-Za-z0-9_]*)\}')) {
            $Key = $Match.Groups[1].Value
            if ($Theme -notmatch ('x:Key="' + [regex]::Escape($Key) + '"')) {
                $null = $Missing.Add($Key)
            }
        }

        $Missing.Count | Should -Be 0 -Because ("these keys have no definition in the merged theme dictionary: " + ($Missing -join ', '))
    }

    It 'draws navigation with glyphs the shipped icon font stack carries' {
        $Xaml = Get-Content -Raw -LiteralPath (Join-Path $script:WinUiRoot 'MainWindow.xaml')
        $Glyphs = @([regex]::Matches($Xaml, 'Glyph="&#x([0-9A-Fa-f]{4});"') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() })
        $Glyphs.Count | Should -BeGreaterThan 0

        # Segoe Fluent Icons ships with Windows 11 (and with this IoT LTSC image, where
        # Segoe MDL2 Assets is NOT installed), so it must stay first in the stack; MDL2 is
        # the Windows 10 fallback. Every code point in use was verified present in
        # C:\Windows\Fonts\SegoeIcons.ttf (Segoe Fluent Icons) on the Windows 11 IoT LTSC
        # validation VM (see docs/VALIDATION.md section 28).
        $Theme = Get-Content -Raw -LiteralPath (Join-Path $script:WinUiRoot 'Themes/CatppuccinMocha.xaml')
        $Theme | Should -Match '<FontFamily x:Key="WtIconFont">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>'

        # The reviewed vocabulary. A new glyph must be added here deliberately, and checked
        # against the font, rather than rendering as a missing-glyph box on the target image.
        $Reviewed = @('E711', 'E72C', 'E80F', 'E81C', 'E8D7', 'E8FB', 'E9D9', 'E9F5')
        foreach ($Glyph in ($Glyphs | Sort-Object -Unique)) {
            $Reviewed | Should -Contain $Glyph -Because "glyph U+$Glyph is not part of the reviewed icon vocabulary"
        }

        # The vocabulary is in use, not just declared: the navigation entries carry them.
        foreach ($NavGlyph in @('E80F', 'E9F5', 'E8FB', 'E81C', 'E9D9', 'E8D7')) {
            $Glyphs | Should -Contain $NavGlyph -Because "navigation entry U+$NavGlyph must be drawn"
        }
    }
}
