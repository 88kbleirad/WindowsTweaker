# WindowsTweaker - keyboard dispatch and rendering for the insight overlays.
#
# These tests drive the real interface: the shortcuts open the sanity scan, the
# recommendations and the choices views exactly as the main loop does (Send-WtTestKey
# goes through Invoke-WtTuiKey), and the dialog keys are queued through the state's
# injectable key source. The registry, the journal and the state file are never touched:
# the scan is read-only, the recommendation and choice views only read the catalog, and
# the export-dialog test doubles the report writer so nothing is ever written.
#
# The interface internals are private on purpose, so every body runs through
# InModuleScope; the shared helpers live in TuiTestHelpers.ps1 and are dot-sourced into
# the module scope by the BeforeAll below. Because the painting helpers are private, a
# small probe (New-WtInsightProbe) wraps the injectable key source and snapshots the
# frame the dialog just painted before the next key is read.

BeforeAll {
    $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ModuleManifest = Join-Path $script:RepositoryRoot 'src/WindowsTweaker/WindowsTweaker.psd1'

    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-insight-tui-{0}" -f ([guid]::NewGuid().ToString('n')))
    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_LANG = 'en'
    $env:WT_TEST_MODULE = $script:ModuleManifest

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null
    Import-Module $script:ModuleManifest -Force

    InModuleScope WindowsTweaker -Parameters @{ HelperPath = (Join-Path $PSScriptRoot 'TuiTestHelpers.ps1') } {
        . $HelperPath

        <#
        .SYNOPSIS
            Turns a string into the character keys a dialog would read.
        #>
        function script:New-WtInsightKeys
        {
            param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

            $Keys = [System.Collections.Generic.List[object]]::new()
            foreach ($Character in $Text.ToCharArray())
            {
                $Keys.Add((New-WtTestKey -Name 'Char' -Character ([string]$Character)))
            }

            return $Keys.ToArray()
        }

        <#
        .SYNOPSIS
            Installs a key source that snapshots each painted frame before reading a key.
        .DESCRIPTION
            The dialog loop paints a frame and then reads one key, so the state of the
            overlay *between* two keys can only be observed from inside the injected key
            source. Only property access is used here: a scriptblock created with
            GetNewClosure() cannot call the module's private functions. The captured text
            is rebuilt from the screen cells, which is what ConvertTo-WtScreenPlainText
            renders (itself used directly once a dialog has returned).
        #>
        function script:New-WtInsightProbe
        {
            param
            (
                [Parameter(Mandatory = $true)][object]$State,
                [Parameter(Mandatory = $false)][object[]]$Keys = @()
            )

            $Queue = [System.Collections.Generic.Queue[object]]::new()
            foreach ($Key in $Keys) { $Queue.Enqueue($Key) }

            $Frames = [System.Collections.Generic.List[object]]::new()
            $State.KeyQueue = $Queue
            $State.KeySource = {
                $Builder = [System.Text.StringBuilder]::new()
                for ($Row = 0; $Row -lt $State.Screen.Height; $Row++)
                {
                    foreach ($Cell in $State.Screen.Rows[$Row].Cells) { [void]$Builder.Append($Cell) }
                    [void]$Builder.Append([char]10)
                }

                $Overlay = $State.Overlay
                $Frames.Add([pscustomobject]@{
                        Kind        = $(if ($Overlay) { [string]$Overlay.Kind } else { '' })
                        Search      = $(if ($Overlay -and $Overlay.List) { [string]$Overlay.List.Search } else { '' })
                        SearchFocus = $(if ($Overlay -and $Overlay.List) { [bool]$Overlay.List.SearchFocus } else { $false })
                        FieldText   = $(if ($Overlay -and $Overlay.Field) { [string]$Overlay.Field.Text } else { '' })
                        FieldError  = $(if ($Overlay -and $Overlay.Field) { [string]$Overlay.Field.Error } else { '' })
                        ItemsRight  = $(if ($Overlay -and $Overlay.List) { @($Overlay.List.Items | ForEach-Object { [string]$_.Right }) } else { @() })
                        Objective   = [string]$State.RecommendObjective
                        Pending     = [int]$State.Pending.Count
                        Text        = $Builder.ToString()
                    })

                if ($Queue.Count -eq 0) { return $null }
                return $Queue.Dequeue()
            }.GetNewClosure()

            return ,$Frames
        }
    }
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_LANG, Env:\WT_TEST_MODULE -ErrorAction Ignore
}

Describe 'Insight overlay keyboard dispatch' {

    It 'types a filter keystroke as text instead of running the export shortcut' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 120 -Height 40
            $Entry = Get-WtTweakState -Id 'Privacy.LanguageListAccess' | Select-Object -First 1
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'Disabled'

            $Frames = New-WtInsightProbe -State $State -Keys @(
                (New-WtTestKey -Name 'Char' -Character '/'),
                (New-WtTestKey -Name 'Char' -Character 'e'),
                (New-WtTestKey -Name 'Char' -Character 'c'),
                (New-WtTestKey -Name 'Enter'),
                (New-WtTestKey -Name 'Char' -Character 'E'),
                (New-WtTestKey -Name 'Escape')
            )

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 's')

            # Typing '/' focuses the filter; 'e' and 'c' are then text in it. None of these
            # keys may open the export prompt: the list overlay stays open throughout.
            @($Frames | Where-Object { $_.Kind -eq 'text' }).Count | Should -Be 1
            foreach ($Index in 0..4)
            {
                $Frames[$Index].Kind | Should -Be 'list' -Because "'e' and 'ec' must stay in the filter"
            }

            $Frames[2].Search | Should -Be 'e'
            $Frames[3].Search | Should -Be 'ec'
            $Frames[3].SearchFocus | Should -BeTrue

            # Only after Enter left the filter and 'E' was pressed does the export dialog open.
            $Frames[4].SearchFocus | Should -BeFalse
            $Frames[5].Kind | Should -Be 'text'

            # ...and Escape closes it again without touching the pending set.
            $State.Overlay | Should -BeNullOrEmpty
            foreach ($Frame in $Frames) { $Frame.Pending | Should -Be 1 }
            $State.Pending.Count | Should -Be 1
            $State.Pending[$Entry.Id].Target | Should -Be 'Disabled'
        }
    }

    It 'refuses an export path that is an existing file or sits under a missing directory' {
        InModuleScope WindowsTweaker {
            $Existing = Join-Path $env:WT_DATA_ROOT 'existing-report.md'
            Set-Content -LiteralPath $Existing -Value 'already here'
            $MissingChild = Join-Path (Join-Path $env:WT_DATA_ROOT ('missing-' + [guid]::NewGuid().ToString('n'))) 'report.md'

            Mock Export-WtSanityReportInternal { [pscustomobject]@{ Ok = $true; Path = ''; Message = '' } }

            foreach ($Path in @($Existing, $MissingChild))
            {
                $State = New-WtTestState -Width 120 -Height 40
                $Frames = New-WtInsightProbe -State $State -Keys ((@((New-WtTestKey -Name 'Char' -Character 'E'))) +
                    (New-WtInsightKeys -Text $Path) +
                    @((New-WtTestKey -Name 'Enter'), (New-WtTestKey -Name 'Escape')))

                Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 's')

                # The frame painted right after Enter is the failed validation: the text
                # dialog is still open and carries the validator's refusal.
                $Frames[-1].Kind | Should -Be 'text' -Because "the dialog must stay open for '$Path'"
                $Frames[-1].FieldText | Should -Be $Path
                $Frames[-1].FieldError | Should -Not -BeNullOrEmpty -Because "the validator must refuse '$Path'"
                $State.Overlay | Should -BeNullOrEmpty
            }

            Should -Invoke -CommandName Export-WtSanityReportInternal -Times 0 -Exactly
        }
    }

    It 'cycles the recommendation objective with Right/Left and never touches the pending set' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 120 -Height 40
            $Objectives = @(Get-WtRecommendationObjective)
            $Objectives.Count | Should -BeGreaterThan 1
            $Original = [string]$Objectives[0].Name
            $Forward = [string]$Objectives[1].Name
            $BackOne = [string]$Objectives[$Objectives.Count - 1].Name

            $Entry = Get-WtTweakState -Id 'Privacy.LanguageListAccess' | Select-Object -First 1
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'Disabled'

            $Frames = New-WtInsightProbe -State $State -Keys @(
                (New-WtTestKey -Name 'Right'),
                (New-WtTestKey -Name 'Left'),
                (New-WtTestKey -Name 'Left'),
                (New-WtTestKey -Name 'Escape')
            )

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'm')

            $Line = { param ($Name) Get-WtString -Key 'Cat.Tui.Rec.ObjectiveLine' -Arguments @($Name) }

            $Frames[0].Objective | Should -Be $Original
            $Frames[0].Text | Should -Match ([regex]::Escape((& $Line $Original)))

            # Right advanced the objective by one, and the painted line says so.
            $Frames[1].Objective | Should -Be $Forward
            $Frames[1].Text | Should -Match ([regex]::Escape((& $Line $Forward)))

            # Two Lefts walked back one objective from the original (wrapping to the last one).
            $State.RecommendObjective | Should -Be $BackOne
            $Frames[-1].Objective | Should -Be $BackOne
            $Frames[-1].Text | Should -Match ([regex]::Escape((& $Line $BackOne)))

            # The view reports the kept count and leaves the pending set alone.
            $Frames[0].Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Cat.Tui.Rec.Kept' -Arguments @(1))))
            foreach ($Frame in $Frames) { $Frame.Pending | Should -Be 1 }
            $State.Pending[$Entry.Id].Target | Should -Be 'Disabled'
            $State.Operation | Should -BeNullOrEmpty
        }
    }

    It "walks the recommendation objective forward with 'O' and applies nothing" {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 120 -Height 40
            $Objectives = @(Get-WtRecommendationObjective)
            $Objectives.Count | Should -BeGreaterThan 1
            $Forward = [string]$Objectives[1].Name

            $Entry = Get-WtTweakState -Id 'Privacy.LanguageListAccess' | Select-Object -First 1
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'Disabled'

            $Frames = New-WtInsightProbe -State $State -Keys @(
                (New-WtTestKey -Name 'Char' -Character 'O'),
                (New-WtTestKey -Name 'Escape')
            )

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'm')

            $State.RecommendObjective | Should -Be $Forward
            $Frames[1].Objective | Should -Be $Forward
            $Frames[1].Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Cat.Tui.Rec.ObjectiveLine' -Arguments @($Forward))))

            foreach ($Frame in $Frames) { $Frame.Pending | Should -Be 1 }
            $State.Pending[$Entry.Id].Target | Should -Be 'Disabled'
            $State.Operation | Should -BeNullOrEmpty
        }
    }

    It 'keeps the live alternative visible while another one is pending in the choices view' {
        InModuleScope WindowsTweaker {
            $State = New-WtTestState -Width 120 -Height 40
            $Entry = Get-WtTweakState -Id 'Explorer.OpenFileExplorerTo' | Select-Object -First 1
            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'ThisPC'

            $Frames = New-WtInsightProbe -State $State -Keys @((New-WtTestKey -Name 'Escape'))

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'c')

            $Group = @(Get-WtChoiceGroup -Pending $State.Pending)[0]
            $Group.Id | Should -Be 'Explorer.StartupLocation'
            $Group.TweakId | Should -Be 'Explorer.OpenFileExplorerTo'

            $Current = Get-WtString -Key 'Cat.Tui.Choices.Current' -Arguments @((Get-WtGroupStateLabelInternal -Group $Group))
            $Pending = Get-WtString -Key 'Cat.Tui.Choices.Pending' -Arguments @('ThisPC')

            # The row carries both facts: what is live and what is pending, on one line.
            $Row = @($Frames[0].ItemsRight)[0]
            $Row | Should -Be ($Current + ' | ' + $Pending)
            $Frames[0].Text | Should -Match ([regex]::Escape($Current))
        }
    }

    It 'replaces the pending alternative, drops the stale fingerprint and applies nothing' {
        InModuleScope WindowsTweaker {
            Enable-WtTestSupport

            $State = New-WtTestState -Width 120 -Height 40
            $Entry = Get-WtTweakState -Id 'Explorer.OpenFileExplorerTo' | Select-Object -First 1
            $Entry.Supported | Should -BeTrue
            $Entry.ApplyAllowed | Should -BeTrue

            $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'ThisPC'
            $State.Pending[$Entry.Id]['Fingerprint'] = 'stale-review'

            New-WtInsightProbe -State $State -Keys @(
                (New-WtTestKey -Name 'Enter'),
                (New-WtTestKey -Name 'Down'),
                (New-WtTestKey -Name 'Enter')
            ) | Out-Null

            Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character 'c')

            $State.Pending.Count | Should -Be 1
            $Pending = $State.Pending[$Entry.Id]
            $Pending.Target | Should -Be 'QuickAccess'
            $Pending.ContainsKey('Fingerprint') | Should -BeFalse -Because 'the earlier review no longer counts'

            $State.Status.Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Cat.Tui.Choices.Replaced' -Arguments @($Entry.Id, 'QuickAccess'))))

            # Nothing was applied: no operation and no worker were started.
            $State.Operation | Should -BeNullOrEmpty
            $State.Worker | Should -BeNullOrEmpty
            $State.DryRun | Should -BeFalse
        }
    }

    It 'renders the sanity, recommendation and choice views in both languages without raw keys' {
        InModuleScope WindowsTweaker {
            $Entry = Get-WtTweakState -Id 'Explorer.OpenFileExplorerTo' | Select-Object -First 1
            $Pending = New-WtTestPending -Entry $Entry -Target 'ThisPC'
            $RawKey = '\b(Cat|Rec|Tui)\.[A-Za-z]'

            foreach ($Language in 'en', 'vi')
            {
                foreach ($Trigger in 's', 'm', 'c')
                {
                    $State = New-WtTestState -Width 120 -Height 40
                    $State.Pending[$Entry.Id] = $Pending
                    Set-WtLanguage -Language $Language | Out-Null

                    $Frames = New-WtInsightProbe -State $State -Keys @((New-WtTestKey -Name 'Escape'))
                    Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character $Trigger)

                    $Text = ($Frames | ForEach-Object { $_.Text }) -join "`n"
                    $Text.Length | Should -BeGreaterThan 0
                    $Text | Should -Not -Match $RawKey -Because "the '$Trigger' overlay must be localised in $Language"
                }
            }

            Set-WtLanguage -Language 'en' | Out-Null
        }
    }

    It 'paints the sanity and choice views inside a narrow terminal without throwing' {
        InModuleScope WindowsTweaker {
            $Entry = Get-WtTweakState -Id 'Explorer.OpenFileExplorerTo' | Select-Object -First 1

            foreach ($Trigger in 's', 'c')
            {
                $State = New-WtTestState -Width 40 -Height 12
                $State.Pending[$Entry.Id] = New-WtTestPending -Entry $Entry -Target 'ThisPC'
                New-WtInsightProbe -State $State -Keys @((New-WtTestKey -Name 'Escape')) | Out-Null

                { Send-WtTestKey -State $State -Key (New-WtTestKey -Name 'Char' -Character $Trigger) } | Should -Not -Throw

                $Lines = ConvertTo-WtScreenPlainText -Screen $State.Screen
                $Lines.Count | Should -BeLessOrEqual 12 -Because "the '$Trigger' view must stay inside the screen"
                $State.Overlay | Should -BeNullOrEmpty
            }
        }
    }
}
