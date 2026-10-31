# WindowsTweaker - provider level unit tests.
#
# Pure logic that must stay correct regardless of the host platform: operation status
# aggregation, registry value-name normalisation, value comparison and the honest
# classification of what a result means.

BeforeAll {
    $env:WT_LANG = 'en'
    $script:ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    Import-Module $script:ModuleManifest -Force
}

AfterAll {
    Remove-Module WindowsTweaker -Force -ErrorAction Ignore
    Remove-Item Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Operation status aggregation' {

    BeforeAll {
        $script:Status = {
            param ([string[]]$Statuses)

            $Results = @($Statuses | ForEach-Object {
                [pscustomobject]@{ PSTypeName = 'WindowsTweaker.OperationResult'; Status = $_; Operation = 'Test'; Target = 'x'; Message = '' }
            })

            InModuleScope WindowsTweaker -Parameters @{ R = $Results } {
                Get-WtAggregateStatus -Results $R
            }
        }
    }

    It 'reports a failure above everything else' {
        & $script:Status @('failed', 'succeeded', 'dryrun') | Should -Be 'failed'
    }

    It 'reports a real change above a dry run' {
        & $script:Status @('succeeded', 'dryrun') | Should -Be 'succeeded'
    }

    It 'reports a pending change above nothing-to-do during a dry run' {
        & $script:Status @('unchanged', 'dryrun') | Should -Be 'dryrun'
    }

    It 'reports nothing-to-do when every operation is a no-op' {
        & $script:Status @('unchanged', 'unchanged') | Should -Be 'unchanged'
    }

    It 'reports unsupported only when nothing else applied' {
        & $script:Status @('unsupported', 'unsupported') | Should -Be 'unsupported'
        & $script:Status @('unchanged', 'unsupported') | Should -Be 'unchanged'
    }
}

Describe 'Registry value name handling' {

    It 'maps the provider spelling of the unnamed value to the empty name' {
        InModuleScope WindowsTweaker {
            Resolve-WtRegistryValueName -Name '(default)' | Should -Be ''
            Resolve-WtRegistryValueName -Name '(Default)' | Should -Be ''
            Resolve-WtRegistryValueName -Name '' | Should -Be ''
            Resolve-WtRegistryValueName -Name 'Named' | Should -Be 'Named'
        }
    }

    It 'accepts the unnamed value spelling in the registry tweak model' {
        InModuleScope WindowsTweaker {
            $Tweak = New-WtRegistryTweak -Id 'Test.Unnamed' -Category 'Explorer' `
                -Name @{ en = 'Unnamed value'; vi = 'Giá trị không tên' } `
                -Description @{ en = 'd'; vi = 'd' } `
                -Impact @{ en = 'i'; vi = 'i' } `
                -States @{
                    Enabled  = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Test'; Name = '(default)'; Type = 'String'; Value = 'on' })
                    Disabled = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Test'; Name = '(default)'; Type = 'String'; Value = 'off' })
                }

            $Tweak.States['Enabled'][0].Name | Should -Be '(default)'
            $Tweak.Detection.Path | Should -Be 'HKCU:\Software\Test'
            $Tweak.Detection.Map['Enabled'] | Should -Be @('on')
        }
    }
}

Describe 'Value comparison' {

    It 'treats equal numbers of different widths as equal' {
        InModuleScope WindowsTweaker {
            (Test-WtValueEqual -Left ([uint32]1) -Right 1) | Should -BeTrue
            (Test-WtValueEqual -Left ([int64]1) -Right 1) | Should -BeTrue
            (Test-WtValueEqual -Left 1 -Right 2) | Should -BeFalse
        }
    }

    It 'compares string arrays element by element' {
        InModuleScope WindowsTweaker {
            (Test-WtValueEqual -Left @('a', 'b') -Right @('a', 'b')) | Should -BeTrue
            (Test-WtValueEqual -Left @('a', 'b') -Right @('b', 'a')) | Should -BeFalse
            (Test-WtValueEqual -Left @('a') -Right @('a', 'b')) | Should -BeFalse
        }
    }

    It 'compares binary values by content' {
        InModuleScope WindowsTweaker {
            (Test-WtValueEqual -Left ([byte[]](1, 2, 3)) -Right ([byte[]](1, 2, 3))) | Should -BeTrue
            (Test-WtValueEqual -Left ([byte[]](1, 2, 3)) -Right ([byte[]](3, 2, 1))) | Should -BeFalse
        }
    }

    It 'treats a missing value as different from an empty string' {
        InModuleScope WindowsTweaker {
            (Test-WtValueEqual -Left $null -Right '') | Should -BeFalse
            (Test-WtValueEqual -Left $null -Right $null) | Should -BeTrue
        }
    }
}

Describe 'Operation result contract' {

    It 'refuses unknown statuses' {
        InModuleScope WindowsTweaker {
            { New-WtOperationResult -Status 'probably-fine' -Operation 'Test' } | Should -Throw
        }
    }

    It 'reports an irreversible operation as non-rollbackable' {
        InModuleScope WindowsTweaker {
            (New-WtOperationResult -Status 'succeeded' -Operation 'Test' -Rollback None).Rollback | Should -Be 'None'
        }
    }

    It 'marks a truncated capture as partial rollback' {
        InModuleScope WindowsTweaker {
            (New-WtOperationResult -Status 'succeeded' -Operation 'Test' -PartialRollback).Rollback | Should -Be 'Partial'
        }
    }
}
