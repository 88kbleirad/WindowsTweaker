# WindowsTweaker - bridge protocol contract tests (engine half).
#
# The WinUI frontend's C# live tests already verify the served string tables against the
# handshake's key list over the real host. These tests check the same contract from the
# engine side, without starting a process: the key list must stay a subset of every table
# the module ships, so a table that lags behind the frontend's vocabulary fails here first.

BeforeAll {
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    Import-Module $script:ModuleManifest -Force

    # Dot-source the protocol file directly (it is module-private and carries no module
    # dependency, so it can be exercised standalone against the shipped tables).
    $script:ProtocolPath = Join-Path $PSScriptRoot '../src/WindowsTweaker/Private/Bridge/BridgeProtocol.ps1'
    . $script:ProtocolPath
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
}

Describe 'Bridge frontend string contract' {

    It 'exposes the key list through the protocol file' {
        $Keys = @(Get-WtBridgeGuiStringKeys)
        $Keys.Count | Should -BeGreaterThan 20
        $Keys | Should -Contain 'Gui.Nav.Overview'
        $Keys | Should -Contain 'Gui.Action.Apply'
        $Keys | Should -Contain 'Gui.Error.RequiresElevation'
    }

    It 'defines every frontend key in every merged language table' {
        $Keys = @(Get-WtBridgeGuiStringKeys)
        foreach ($Lang in @('en', 'vi')) {
            # The same merge the bridge serves: the language table, then the catalog and
            # insight tables, then the terminal tables (all shipped psd1 files).
            $Table = @{}
            $Shipped = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '../src/WindowsTweaker/Data') -Filter "Strings.$Lang*.psd1" -File
            foreach ($File in $Shipped) {
                $FileTable = Import-PowerShellDataFile -LiteralPath $File.FullName
                foreach ($Entry in $FileTable.GetEnumerator()) { $Table[$Entry.Key] = $Entry.Value }
            }
            foreach ($Key in $Keys) {
                $Table.ContainsKey($Key) | Should -BeTrue -Because "'$Key' must be defined in the merged $Lang tables"
            }
        }
    }

    It 'defines no gui table key that the frontend never uses' {
        $Keys = @(Get-WtBridgeGuiStringKeys)
        foreach ($Lang in @('en', 'vi')) {
            $Table = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "../src/WindowsTweaker/Data/Strings.$Lang.gui.psd1")
            foreach ($Key in @($Table.Keys)) {
                if ($Key -in $Keys) { continue }
                # Keys that only the terminal UI uses are fine; the gui table must not
                # carry them (the frontend's vocabulary is the single source of truth).
                $Key | Should -Not -Match '^Gui\.' -Because "gui table key '$Key' has no declared frontend consumer"
            }
        }
    }

    It 'declares the overview metrics snapshot as a short read-only inline operation' {
        $Ops = Get-WtBridgeOperations
        $Ops.ContainsKey('metrics.snapshot') | Should -BeTrue -Because 'the overview dashboard samples through this op'
        $Ops['metrics.snapshot'].Mutating | Should -BeFalse
        $Ops['metrics.snapshot'].Worker | Should -BeFalse -Because 'a sample must not start a worker runspace'
        $Ops['metrics.snapshot'].Privileged | Should -BeFalse
        $Ops['metrics.snapshot'].TimeoutMs | Should -BeLessOrEqual 30000
    }
}
