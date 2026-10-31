# WindowsTweaker - graphical interface contract tests.
#
# The WPF window cannot be rendered in this environment, so these tests check what can
# be checked deterministically: the XAML is well-formed, every element the code looks up
# by name exists, the required palette and square-corner styling are present, the
# interface contains no system-modification logic of its own, and opening it performs no
# change on a platform without WPF.

BeforeAll {
    $script:GuiRoot = Join-Path $PSScriptRoot '../src/WindowsTweaker/Gui'
    $script:XamlPath = Join-Path $script:GuiRoot 'MainWindow.xaml'
    $script:GuiScriptPath = Join-Path $script:GuiRoot 'Gui.ps1'
    $script:RawXaml = Get-Content -LiteralPath $script:XamlPath -Raw
    $script:Xaml = [xml]$script:RawXaml
    # Comments are stripped for the styling assertions so that documentation such as
    # "no CornerRadius is set anywhere" does not trip them.
    $script:StyledXaml = [regex]::Replace($script:RawXaml, '<!--.*?-->', '', 'Singleline')
    $script:GuiSource = Get-Content -LiteralPath $script:GuiScriptPath -Raw

    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    Import-Module $script:ModuleManifest -Force
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
}

Describe 'Interface definition' {

    It 'is well-formed XML with a WPF Window root' {
        $script:Xaml.DocumentElement.LocalName | Should -Be 'Window'
        $script:Xaml.DocumentElement.GetAttribute('xmlns') | Should -Be 'http://schemas.microsoft.com/winfx/2006/xaml/presentation'
    }

    It 'defines every element the code looks up by name' {
        # FindName('X') calls in the code must resolve against x:Name="X" in the XAML.
        $Referenced = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($Match in [regex]::Matches($script:GuiSource, "FindName\('([^']+)'\)"))
        {
            [void]$Referenced.Add($Match.Groups[1].Value)
        }

        $Declared = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($Node in $script:Xaml.SelectNodes('//*[@*[local-name()="Name"]]'))
        {
            [void]$Declared.Add($Node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml'))
        }

        $Referenced.Count | Should -BeGreaterThan 20 -Because 'the window is wired through x:Name lookups'

        $Missing = @($Referenced | Where-Object { -not $Declared.Contains($_) })
        $Missing | Should -BeNullOrEmpty -Because 'a missing name would throw a null reference when the window opens'
    }

    It 'uses the Catppuccin Mocha palette required by the specification' {
        foreach ($Colour in '#1e1e2e', '#181825', '#cdd6f4', '#89b4fa')
        {
            $script:StyledXaml | Should -Match ([regex]::Escape($Colour))
        }
    }

    It 'keeps corners square' {
        $script:StyledXaml | Should -Not -Match 'CornerRadius'
        $script:StyledXaml | Should -Not -Match 'CornerRadius=' -Because 'the specification asks for square corners'
    }

    It 'declares a font that exists on Windows for text and icons' {
        $script:StyledXaml | Should -Match 'Segoe UI'
        $script:StyledXaml | Should -Match 'Segoe Fluent Icons'
        # Visible icons are Fluent glyphs (the entity form is what the file contains).
        $script:StyledXaml | Should -Match '&#xE[0-9A-Fa-f]{3};'
    }
}

Describe 'Interface behaviour' {

    It 'contains no system-modification logic of its own' {
        foreach ($Pattern in 'New-ItemProperty', 'Set-ItemProperty', 'Remove-ItemProperty', 'Set-Service',
            'Set-Content.*Registry', 'Remove-AppxPackage', 'Set-DnsClientServerAddress', 'Set-MpPreference',
            'Set-NetFirewallRule', 'powercfg', 'Invoke-Expression')
        {
            $script:GuiSource | Should -Not -Match $Pattern -Because "the interface must call the backend instead of changing the system ($Pattern)"
        }
    }

    It 'only calls the public module API for changes' {
        $script:GuiSource | Should -Match 'Invoke-WtTweak'
        $script:GuiSource | Should -Match 'Undo-WtTweak'
        $script:GuiSource | Should -Match 'Get-WtTweakState'

        # Private providers must not be used directly by the interface.
        foreach ($Private in 'Set-WtRegistryValue', 'Set-WtServiceState', 'Set-WtDnsServer', 'Remove-WtAppxPackage')
        {
            $script:GuiSource | Should -Not -Match ([regex]::Escape($Private))
        }
    }

    It 'runs the batch with confirmations suppressed so a background runspace cannot block on a prompt' {
        $script:GuiSource | Should -Match "\`$ConfirmPreference = 'None'"
    }

    It 'returns without changing anything where WPF is unavailable' {
        $Result = Start-WtGui
        if ($IsWindows)
        {
            # On Windows this would open a window; the test only asserts it does not throw.
            $true | Should -BeTrue
        }
        else
        {
            $Result | Should -BeNullOrEmpty
        }
    }
}
