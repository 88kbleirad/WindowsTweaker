# WindowsTweaker - declarative catalog, packs, planning and migration tests.
#
# Everything here runs on any platform: the documents are files in a temporary directory, the
# registry is an in-memory double, and the only Windows-facing claim any of these tests makes is
# that the *engine* behaves - not that a setting behaves. Behaviour on a real Windows build is
# recorded in each definition's evidence block and is deliberately not asserted here.

BeforeAll {
    $ModuleManifest = Join-Path $PSScriptRoot '../src/WindowsTweaker/WindowsTweaker.psd1'
    $script:TestDataRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-catalog-{0}" -f ([guid]::NewGuid().ToString('n')))

    $env:WT_DATA_ROOT = $script:TestDataRoot
    $env:WT_STATE_PATH = Join-Path $script:TestDataRoot 'state.json'
    $env:WT_LOG_DIRECTORY = Join-Path $script:TestDataRoot 'logs'
    $env:WT_PACKS_PATH = Join-Path $script:TestDataRoot 'packs'
    $env:WT_MIGRATIONS_PATH = Join-Path $script:TestDataRoot 'migrations.json'
    $env:WT_LANG = 'en'

    New-Item -ItemType Directory -Path $script:TestDataRoot -Force | Out-Null

    $ConfirmPreference = 'None'
    Import-Module $ModuleManifest -Force

    $script:InitializePlatform = {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $Script:WtTestRegistry = @{}
            $Script:WtTestWrites = 0
            $Script:WtTestRemoves = 0

            Mock Get-WtEnvironmentInternal {
                @{
                    PSTypeName       = 'WindowsTweaker.Environment'
                    PowerShell       = $PSVersionTable.PSVersion
                    RequiredPS       = [version]'7.4'
                    MeetsPowerShell  = $true
                    IsWindows        = $true
                    IsAdmin          = $true
                    OSName           = 'Windows 11 Pro'
                    OSBuild          = 26100
                    OSUBR            = 1
                    OSDisplayVersion = '24H2'
                    OSVersionKey     = 'Windows11'
                    Architecture     = 'X64'
                    IsVirtualMachine = $false
                    LanguageMode     = 'FullLanguage'
                    PendingReboot    = $false
                    Culture          = 'en-US'
                }
            }

            Mock Test-WtCapability { param ($Name, $Environment) @{ Name = $Name; Available = $true; Reason = ''; Kind = 'Mocked' } }
            Mock Test-WtRegistryAvailable { $true }
            Mock Test-WtRegistryKeyRaw { param ($Path) $true }
            Mock Get-WtRegistryValueStateRaw {
                param ($Path, $Name)

                $Key = "$Path|$Name"
                if ($Script:WtTestRegistry.ContainsKey($Key))
                {
                    return @{
                        KeyExists    = $true
                        ValueExists  = $true
                        Kind         = $Script:WtTestRegistry[$Key].Kind
                        KindInferred = $false
                        Value        = $Script:WtTestRegistry[$Key].Value
                    }
                }

                return @{ KeyExists = $false; ValueExists = $false; Kind = $null; KindInferred = $false; Value = $null }
            }
            Mock Set-WtRegistryValueRaw {
                param ($Path, $Name, $Value, $Kind)

                $Script:WtTestWrites++
                $Script:WtTestRegistry["$Path|$Name"] = @{ Kind = $Kind; Value = $Value }
            }
            Mock Remove-WtRegistryPropertyRaw {
                param ($Path, $Name)

                $Script:WtTestRemoves++
                $Script:WtTestRegistry.Remove("$Path|$Name")
            }
            Mock New-WtRegistryKeyRaw { param ($Path) }
            Mock Get-WtRegistryKeyContentRaw { param ($Path) @{ Exists = $false; Values = 0; SubKeys = 0; Inspected = $true } }

            Initialize-WtLogging -Console $false -Force | Out-Null
        }
    }

    $script:ResetStore = {
        Remove-Item -LiteralPath $env:WT_STATE_PATH -Force -ErrorAction Ignore
        Remove-Item -LiteralPath "$($env:WT_STATE_PATH).lock" -Force -ErrorAction Ignore
    }

    # Writes a document to the temporary directory and returns its path. Defined in the test
    # script's scope (so an It body can call it) and handed to InModuleScope as a parameter.
    $script:NewDoc = {
        param ([string]$Name, [string]$Content)

        $Path = Join-Path $script:TestDataRoot $Name
        Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
        return $Path
    }

    # Minimal valid pack body, with overridable pieces.
    $script:PackBody = {
        param (
            [string]$Id = 'WtTest.Pack',
            [string]$TweakId = 'WtTest.Pack.Item',
            [string]$Extra = '',
            [string]$StateBody = '',
            [string]$Kind = 'Pack'
        )

        $States = if ($StateBody) { $StateBody } else {
            '{"Enabled": [{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Pack", "name": "Item", "type": "DWord", "value": 1}], "Disabled": [{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Pack", "name": "Item", "type": "DWord", "value": 0}]}'
        }

        return @"
{
  "schemaVersion": 1,
  "kind": "$Kind",
  "id": "$Id",
  "version": "1.0.0",
  "minEngineVersion": "1.0.0",
  "author": "tests",
  "description": "Test pack",
  "tweaks": [
    {
      "id": "$TweakId",
      "revision": 1,
      "category": "System",
      "tags": ["test"],
      "names": { "en": "Test item", "vi": "Muc thu" },
      "descriptions": { "en": "Test description", "vi": "Mo ta thu" },
      "impacts": { "en": "Test impact", "vi": "Anh huong thu" },
      "sideEffects": { "en": "Test side effect", "vi": "Tac dung phu thu" },
      "scope": "User",
      "lifecycle": "Available",
      "risk": "Low",
      "restart": "None",
      "rollback": "Full",
      "irreversible": false,
      "dataDeletion": false,
      "reducesProtection": false,
      "requiresCapabilities": ["Cmdlet:Get-ItemProperty"],
      "detection": {
        "hive": "HKCU",
        "key": "Software\\WtTest\\Pack",
        "name": "Item",
        "map": { "Enabled": [1], "Disabled": [0] }
      },
      "states": $States,
      "defaultState": "Enabled",
      "evidence": { "source": "Pack", "structural": "Structural" }$Extra
    }
  ]
}
"@
    }

    # Handed to every InModuleScope block: the helper scriptblocks above. The module scope
    # cannot see the test script's own scope, so they are passed in rather than published.
    $script:WtTestParameters = @{ NewDoc = $script:NewDoc; PackBody = $script:PackBody }
}

AfterAll {
    Remove-Item -LiteralPath $script:TestDataRoot -Recurse -Force -ErrorAction Ignore
    Remove-Item Env:\WT_DATA_ROOT, Env:\WT_STATE_PATH, Env:\WT_LOG_DIRECTORY, Env:\WT_PACKS_PATH, Env:\WT_MIGRATIONS_PATH, Env:\WT_LANG -ErrorAction Ignore
}

Describe 'Catalog document validation' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'loads the built-in catalog through the existing constructor' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            foreach ($Id in 'Privacy.DismissMSAccount', 'Privacy.LanguageListAccess', 'Privacy.WindowsTips')
            {
                $Tweak = Get-WtTweakInternal -Id $Id
                $Tweak | Should -Not -BeNullOrEmpty
                $Tweak.DefinitionSource | Should -Be 'BuiltIn'
                $Tweak.DefinitionDocument | Should -Not -BeNullOrEmpty
                $Tweak.DefinitionValidation.Structural | Should -Be 'Validated'
            }
        }
    }

    It 'keeps the documented detection map and operation list of every migrated definition' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $Dismiss = Get-WtTweakInternal -Id 'Privacy.DismissMSAccount'
            $Dismiss.Detection.Path | Should -Be 'HKCU:\Software\Microsoft\Windows Security Health\State'
            $Dismiss.Detection.Name | Should -Be 'AccountProtection_MicrosoftAccount_Disconnected'
            @($Dismiss.Detection.Map['Dismissed']) | Should -Be @(1)
            @($Dismiss.Detection.Map['Shown']) | Should -Be @(0)
            @($Dismiss.States['Dismissed']).Count | Should -Be 1
            $Dismiss.States['Dismissed'][0].Kind | Should -Be 'RegistrySet'
            $Dismiss.States['Dismissed'][0].Value | Should -Be 1
            $Dismiss.States['Shown'][0].Kind | Should -Be 'RegistryRemove'
            $Dismiss.Scope | Should -Be 'User'
            $Dismiss.Privilege | Should -Be 'None'
            $Dismiss.DefaultState | Should -Be 'Dismissed'

            $Language = Get-WtTweakInternal -Id 'Privacy.LanguageListAccess'
            $Language.States['Enabled'][0].Kind | Should -Be 'RegistryRemove'
            $Language.States['Disabled'][0].Kind | Should -Be 'RegistrySet'
            $Language.States['Disabled'][0].Value | Should -Be 1
            $Language.DefaultState | Should -Be 'Disabled'

            $Tips = Get-WtTweakInternal -Id 'Privacy.WindowsTips'
            $Tips.Scope | Should -Be 'UserAndMachine'
            $Tips.Privilege | Should -Be 'Admin'
            @($Tips.States['Enabled']).Count | Should -Be 2
            $Tips.States['Enabled'][0].Kind | Should -Be 'RegistryRemove'
            $Tips.States['Enabled'][0].Path | Should -Be 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
            $Tips.States['Enabled'][0].Name | Should -Be 'DisableSoftLanding'
            $Tips.States['Enabled'][1].Value | Should -Be 1
            @($Tips.ManagedPolicy).Count | Should -Be 1
            @($Tips.ManagedPolicy)[0].Name | Should -Be 'DisableSoftLanding'
            @($Tips.Requires) | Should -Be @('Cmdlet:Get-ItemProperty')
        }
    }

    It 'produces the same canonical target identities as the equivalent PowerShell definition' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $FromCatalog = Get-WtTweakInternal -Id 'Privacy.WindowsTips'

            New-WtRegistryTweak -Id 'Test.CatalogEquivalent' -Category 'System' `
                -Name @{ en = 'Equivalent'; vi = 'Tuong duong' } `
                -Description @{ en = 'Equivalent'; vi = 'Tuong duong' } `
                -Impact @{ en = 'Equivalent'; vi = 'Tuong duong' } `
                -Scope 'UserAndMachine' -Privilege 'Admin' `
                -StateNames @('Enabled', 'Disabled') -DefaultState 'Disabled' `
                -Detection @{
                    Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                    Name = 'SubscribedContent-338389Enabled'
                    Map  = [ordered]@{ Enabled = @(1); Disabled = @(0) }
                } `
                -States @{
                    Enabled  = @(
                        @{ Kind = 'RegistryRemove'; Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name = 'DisableSoftLanding' }
                        @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Type = 'DWord'; Value = 1 }
                    )
                    Disabled = @(
                        @{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Type = 'DWord'; Value = 0 }
                    )
                }

            $FromPowerShell = Get-WtTweakInternal -Id 'Test.CatalogEquivalent'

            foreach ($State in 'Enabled', 'Disabled')
            {
                $CatalogIdentities = @($FromCatalog.States[$State] | ForEach-Object { Get-WtOperationIdentity -Operation $_ })
                $PowerShellIdentities = @($FromPowerShell.States[$State] | ForEach-Object { Get-WtOperationIdentity -Operation $_ })
                $CatalogIdentities | Should -Be $PowerShellIdentities
            }

            (Get-WtOperationIdentity -Operation $FromCatalog.States['Enabled'][0]) | Should -Be 'reg:HKLM:\SOFTWARE\POLICIES\MICROSOFT\WINDOWS\CLOUDCONTENT\DISABLESOFTLANDING'
        }
    }

    It 'refuses an unsupported schema version' {
        $Path = & $NewDoc -Name 'version.json' -Content '{"schemaVersion": 2, "kind": "Catalog", "id": "x", "tweaks": []}'
        $Result = Test-WtCatalogFile -Path $Path
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'schemaVersion'
    }

    It 'refuses an unknown property instead of ignoring it' {
        $Path = & $NewDoc -Name 'unknown.json' -Content '{"schemaVersion": 1, "kind": "Catalog", "id": "x", "tweaks": [], "runThis": "who knows"}'
        $Result = Test-WtCatalogFile -Path $Path
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'runThis'
    }

    It 'refuses a document with a duplicated JSON property' {
        $Path = & $NewDoc -Name 'dup-prop.json' -Content '{"schemaVersion": 1, "kind": "Catalog", "id": "x", "id": "y", "tweaks": []}'
        $Result = Test-WtCatalogFile -Path $Path
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'duplicate property'
    }

    It 'refuses an unsupported operation kind and an unsupported registry type' {
        $Body = & $PackBody -StateBody '{"Enabled": [{"kind": "RunScript", "hive": "HKCU", "key": "Software\\X", "name": "Y", "type": "DWord", "value": 1}]}'
        $Path = & $NewDoc -Name 'kind.json' -Content $Body
        $Result = Test-WtCatalogFile -Path $Path -AsPack
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'RunScript'

        $Body = & $PackBody -StateBody '{"Enabled": [{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\X", "name": "Y", "type": "RegSz", "value": "1"}]}'
        $Path = & $NewDoc -Name 'type.json' -Content $Body
        $Result = Test-WtCatalogFile -Path $Path -AsPack
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'RegSz'
    }

    It 'refuses a registry path that carries its own hive prefix' {
        $Body = & $PackBody -StateBody '{"Enabled": [{"kind": "RegistrySet", "hive": "HKCU", "key": "HKCU:\\Software\\X", "name": "Y", "type": "DWord", "value": 1}]}'
        $Path = & $NewDoc -Name 'hive.json' -Content $Body
        $Result = Test-WtCatalogFile -Path $Path -AsPack
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'hive prefix'
    }

    It 'refuses a document that overstates its own privilege or understates its risk' {
        $Body = (& $PackBody).Replace('"scope": "User"', '"scope": "Machine"')
        $Path = & $NewDoc -Name 'privilege.json' -Content $Body
        $Result = Test-WtCatalogFile -Path $Path -AsPack
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'requires .Admin.'

        $Body = (& $PackBody).Replace('"reducesProtection": false', '"reducesProtection": true')
        $Path = & $NewDoc -Name 'risk.json' -Content $Body
        $Result = Test-WtCatalogFile -Path $Path -AsPack
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'at least .High.'
    }

    It 'refuses two operations writing the same target in one state' {
        $Body = & $PackBody -StateBody '{"Enabled": [{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\X", "name": "Y", "type": "DWord", "value": 1}, {"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\X", "name": "Y", "type": "DWord", "value": 0}]}'
        $Path = & $NewDoc -Name 'collision.json' -Content $Body
        $Result = Test-WtCatalogFile -Path $Path -AsPack
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'written twice'
    }

    It 'refuses a detection map that names a state the definition does not declare' {
        $Body = & $PackBody -Extra ''
        $Body = $Body.Replace('"map": { "Enabled": [1], "Disabled": [0] }', '"map": { "Enabled": [1], "Sometimes": [7] }')
        $Path = & $NewDoc -Name 'mapstate.json' -Content $Body
        $Result = Test-WtCatalogFile -Path $Path -AsPack
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'does not declare'
    }

    It 'refuses a pack id namespace violation and a reserved built-in prefix' {
        $Body = & $PackBody -Id 'WtTest.Pack' -TweakId 'Privacy.DismissMSAccount'
        $Path = & $NewDoc -Name 'namespace.json' -Content $Body
        $Result = Test-WtCatalogFile -Path $Path -AsPack
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'pack namespace'
    }

    It 'refuses a document larger than the documented limit' {
        $Filler = 'x' * 300000
        $Path = & $NewDoc -Name 'huge.json' -Content ("{""schemaVersion"": 1, ""kind"": ""Catalog"", ""id"": ""x"", ""description"": ""$Filler"", ""tweaks"": []}")
        $Result = Test-WtCatalogFile -Path $Path
        $Result.Valid | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'byte limit'
    }

    It 'refuses to register anything, and writes nothing, while validating' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $Before = $Script:WtCatalog.Count
            $Body = & $PackBody -Id 'WtTest.Validate' -TweakId 'WtTest.Validate.Item'
            $Path = & $NewDoc -Name 'validate.json' -Content $Body

            $Result = Test-WtCatalogFile -Path $Path -AsPack
            $Result.Valid | Should -BeTrue

            $Script:WtCatalog.Count | Should -Be $Before
            $Script:WtTestWrites | Should -Be 0
            $Script:WtTestRemoves | Should -Be 0
        }
    }

    It 'registers a validated document through the existing constructor and refuses a duplicate id' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $Body = & $PackBody -Id 'WtTest.Register' -TweakId 'WtTest.Register.Item'
            $Path = & $NewDoc -Name 'register.json' -Content $Body
            $Read = Read-WtCatalogJson -Path $Path
            $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()

            $Import = Import-WtCatalogDocument -Document $Document -Source 'Pack' -PackId 'WtTest.Register'
            @($Import.Errors).Count | Should -Be 0
            @($Import.Registered) | Should -Be @('WtTest.Register.Item')

            $Tweak = Get-WtTweakInternal -Id 'WtTest.Register.Item'
            $Tweak.DefinitionSource | Should -Be 'Pack'
            $Tweak.DefinitionPackId | Should -Be 'WtTest.Register'
            $Tweak.DefinitionEvidence.AuthorClaimed | Should -BeTrue

            $Again = Import-WtCatalogDocument -Document $Document -Source 'Pack' -PackId 'WtTest.Register'
            ($Again.Errors -join ' ') | Should -Match 'already registered'
        }
    }

    It 'never lets an imported definition declare a built-in id' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $Body = & $PackBody -Id 'WtTest.Shadow' -TweakId 'WtTest.Shadow.Privacy.DismissMSAccount'
            $Path = & $NewDoc -Name 'shadow.json' -Content $Body
            $Read = Read-WtCatalogJson -Path $Path
            $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()

            $Import = Import-WtCatalogDocument -Document $Document -Source 'Pack' -PackId 'WtTest.Shadow'
            @($Import.Errors).Count | Should -Be 0

            # The id is inside the pack namespace, so it cannot collide with a built-in one.
            (Get-WtTweakInternal -Id 'Privacy.DismissMSAccount').DefinitionSource | Should -Be 'BuiltIn'
            (Get-WtTweakInternal -Id 'WtTest.Shadow.Privacy.DismissMSAccount').DefinitionSource | Should -Be 'Pack'
            @(Get-WtTweakInternal -Id 'Privacy.DismissMSAccount').DefinitionPackId | Should -Be ''
        }
    }
}

Describe 'Catalog schema and constants' {

    It 'declares exactly the enums, key lists and limits the loader enforces' {
        $Schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../src/WindowsTweaker/Data/Catalog/catalog.schema.json') -Raw | ConvertFrom-Json -AsHashtable

        InModuleScope WindowsTweaker -Parameters @{ Schema = $Schema; NewDoc = $script:NewDoc; PackBody = $script:PackBody } {
            param ($Schema, $NewDoc, $PackBody)

            $Defs = $Schema['$defs']

            $Defs.registryOperation.oneOf[0].properties.kind.const | Should -Be 'RegistrySet'
            $Defs.registryOperation.oneOf[1].properties.kind.const | Should -Be 'RegistryRemove'
            @($Script:WtCatalogOperationKinds) | Should -Be @('RegistrySet', 'RegistryRemove')
            @($Defs.registryOperation.oneOf[0].properties.hive.enum) | Should -Be $Script:WtCatalogRegistryHives
            @($Defs.registryOperation.oneOf[0].properties.type.enum) | Should -Be @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord')
            @($Defs.registryOperation.oneOf[0].properties.view.enum) | Should -Be $Script:WtCatalogRegistryViews
            @($Defs.tweak.properties.scope.enum) | Should -Be $Script:WtCatalogScopes
            @($Defs.tweak.properties.privilege.enum) | Should -Be $Script:WtCatalogPrivileges
            @($Defs.tweak.properties.lifecycle.enum) | Should -Be $Script:WtCatalogLifecycle
            @($Defs.tweak.properties.restart.enum) | Should -Be $Script:WtCatalogRestart
            @($Defs.tweak.properties.rollback.enum) | Should -Be $Script:WtCatalogRollback
            @($Defs.tweak.properties.risk.enum) | Should -Be $Script:WtCatalogRisk
            @($Defs.tweak.properties.architecture.enum) | Should -Be $Script:WtCatalogArchitectures
            @($Defs.tweak.properties.category.enum) | Should -Be $Script:WtKnownCategories
            @($Defs.reference.properties.status.enum) | Should -Be $Script:WtCatalogEvidenceStatus
            @($Defs.migrationDocument.properties.migrations.items.properties.kind.enum) | Should -Be $Script:WtMigrationKinds

            # Recommendation eligibility, effective-state mapping and exclusive groups are part of
            # the document format, so the normative schema must describe them too. Before this
            # check the schema simply lacked them while the loader accepted them - a document
            # written against the schema was the narrower one.
            @($Defs.recommendation.properties.kind.enum) | Should -Be $Script:WtRecommendationKinds
            @($Defs.recommendation.properties.policy.enum) | Should -Be $Script:WtRecommendationPolicies
            @($Defs.recommendation.properties.objectives.items.enum) | Should -Be $Script:WtRecommendationObjectives
            @($Defs.recommendation.properties.Keys | Sort-Object) | Should -Be (@($Script:WtCatalogRecommendationKeys) | Sort-Object)
            @($Defs.recommendation.required) | Should -Be @('kind', 'policy')

            @($Defs.effective.properties.evidence.enum) | Should -Be $Script:WtEffectiveEvidenceKinds
            @($Defs.effective.properties.boundary.enum) | Should -Be $Script:WtEffectiveBoundaries
            @($Defs.effective.properties.map.additionalProperties.enum) | Should -Be $Script:WtEffectiveStates
            @($Defs.effective.properties.Keys | Sort-Object) | Should -Be (@($Script:WtCatalogEffectiveKeys) | Sort-Object)
            @($Defs.effective.required) | Should -Be @('evidence')

            @($Defs.groupOption.properties.intent.enum) | Should -Be $Script:WtGroupOptionIntents
            @($Defs.groupOption.properties.Keys | Sort-Object) | Should -Be (@($Script:WtCatalogGroupOptionKeys) | Sort-Object)
            @($Defs.group.properties.Keys | Sort-Object) | Should -Be (@($Script:WtCatalogGroupKeys) | Sort-Object)
            @($Defs.group.properties.options.items.'$ref') | Should -Be '#/$defs/groupOption'
            @($Defs.tweak.properties.group.'$ref') | Should -Be '#/$defs/group'
            @($Defs.tweak.properties.recommendation.'$ref') | Should -Be '#/$defs/recommendation'
            @($Defs.tweak.properties.effective.'$ref') | Should -Be '#/$defs/effective'

            # Capability-loss disclosures are part of the document format, so the normative schema
            # must describe them too: same enum, same keys, same bounds as the loader.
            @($Defs.capabilityImpact.properties.kind.enum) | Should -Be $Script:WtCatalogCapabilityKinds
            @($Defs.capabilityImpact.properties.Keys | Sort-Object) | Should -Be (@($Script:WtCatalogCapabilityKeys) | Sort-Object)
            @($Defs.capabilityImpact.required) | Should -Be @('capability', 'kind', 'names')
            @($Defs.capabilityCondition.properties.Keys | Sort-Object) | Should -Be (@($Script:WtCatalogCapabilityConditionKeys) | Sort-Object)
            $Defs.tweak.properties.capabilityLoss.maxItems | Should -Be $Script:WtCatalogMaxCapabilityImpacts
            @($Defs.tweak.properties.capabilityLoss.items.'$ref') | Should -Be '#/$defs/capabilityImpact'

            # The tweak key list must agree with the loader's in both directions: a key the loader
            # accepts and the schema omits makes the schema stricter than the engine, and a key the
            # schema invents makes it promise something the loader refuses.
            foreach ($Key in $Script:WtCatalogTweakKeys) { @($Defs.tweak.properties.Keys) | Should -Contain $Key }
            foreach ($Key in @($Defs.tweak.properties.Keys)) { $Script:WtCatalogTweakKeys | Should -Contain $Key }

            # Key lists must match the loader's, or an author following the schema would be rejected.
            @($Defs.tweak.additionalProperties) | Should -BeFalse
            @($Defs.tweak.required) | Should -Be @(
                'id', 'category', 'names', 'descriptions', 'impacts', 'sideEffects',
                'scope', 'lifecycle', 'risk', 'restart', 'rollback',
                'irreversible', 'dataDeletion', 'reducesProtection',
                'detection', 'states', 'defaultState')

            # Bounds.
            $Defs.catalogDocument.properties.tweaks.maxItems | Should -Be $Script:WtCatalogLimits.MaxTweaks
            $Defs.tweak.properties.states.maxProperties | Should -Be $Script:WtCatalogLimits.MaxStatesPerTweak
            # A group's states are exactly its options, so the option count cannot exceed the states
            # a definition may declare.
            $Defs.group.properties.options.maxItems | Should -Be $Script:WtCatalogLimits.MaxStatesPerTweak
            $Defs.group.properties.options.minItems | Should -Be 2
            $Script:WtCatalogLimits.MaxOperations | Should -Be 16
            $Script:WtCatalogLimits.MaxDocumentBytes | Should -Be 262144
            $Script:WtCatalogSchemaVersion | Should -Be 1
        }
    }
}

Describe 'Exclusive group validation' {

    BeforeAll {
        # A group document with everything overridable, so each loader rule can be broken on its
        # own. It is a pack document: a pack id namespaces its tweaks, which is exactly what the
        # duplicate-group-id case needs.
        $script:GroupBody = {
            param (
                [switch]$NoRevision,
                [switch]$SecondTweak,
                [switch]$OneOption,
                [switch]$Undetectable,
                [switch]$ExtraTarget,
                [switch]$ExtraState,
                [switch]$BadDefault,
                [switch]$Irreversible
            )

            $Revision = if ($NoRevision) { '' } else { '"revision": 2,' }
            $Detection = if ($Undetectable) { '{ "First": [1], "Third": [3] }' } else { '{ "First": [1], "Second": [2] }' }
            $Options = if ($OneOption)
            {
                '{ "id": "First", "intent": "Configured", "labels": { "en": "First", "vi": "Mot" } }'
            }
            else
            {
                @('{ "id": "First", "intent": "Configured", "labels": { "en": "First", "vi": "Mot" } }',
                    '{ "id": "Second", "intent": "WindowsDefault", "labels": { "en": "Second", "vi": "Hai" } }') -join ','
            }

            $States = [ordered]@{
                First  = @(
                    '{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Place", "type": "DWord", "value": 1}',
                    '{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Marker", "type": "DWord", "value": 1}'
                )
                Second = @(
                    '{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Place", "type": "DWord", "value": 2}',
                    '{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Marker", "type": "DWord", "value": 2}'
                )
            }

            if ($ExtraTarget)
            {
                $States['Second'] += '{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "OnlySecond", "type": "DWord", "value": 2}'
            }

            if ($ExtraState)
            {
                $States['Third'] = @('{"kind": "RegistrySet", "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Place", "type": "DWord", "value": 3}')
            }

            $Default = if ($BadDefault) { 'Third' } else { 'First' }
            $IrreversibleFlag = if ($Irreversible) { 'true' } else { 'false' }

            $Tweak = @"
    {
      "id": "WtTest.Group.Item",
      "revision": 1,
      "category": "Explorer",
      "names": { "en": "Test place", "vi": "Noi thu" },
      "descriptions": { "en": "Two targets per alternative", "vi": "Hai dich moi lua chon" },
      "impacts": { "en": "None", "vi": "Khong" },
      "sideEffects": { "en": "None", "vi": "Khong" },
      "scope": "User",
      "lifecycle": "Available",
      "risk": "Low",
      "restart": "Explorer",
      "rollback": "Full",
      "irreversible": $IrreversibleFlag,
      "dataDeletion": false,
      "reducesProtection": false,
      "detection": { "hive": "HKCU", "key": "Software\\WtTest\\Group", "name": "Place", "map": $Detection },
      "states": {
        "First": [$(($States['First']) -join ',')],
        "Second": [$(($States['Second']) -join ',')]$(if ($ExtraState) { ',"Third": [' + (($States['Third']) -join ',') + ']' })
      },
      "defaultState": "$Default",
      "group": {
        "id": "WtTest.Group.Place",
        $Revision
        "labels": { "en": "Test place", "vi": "Noi thu" },
        "options": [$Options]
      },
      "evidence": { "source": "Pack", "structural": "Structural" }
    }
"@

            $Second = if ($SecondTweak)
            {
                # Same group id, different tweak: two settings would report themselves as one group.
                ($Tweak -replace '"id": "WtTest.Group.Item"', '"id": "WtTest.Group.Other"')
            }
            else
            {
                ''
            }

            $Tweaks = @($Tweak, $Second) | Where-Object { $_ }
            return @"
{
  "schemaVersion": 1,
  "kind": "Pack",
  "id": "WtTest.Group",
  "version": "1.0.0",
  "minEngineVersion": "1.0.0",
  "author": "tests",
  "description": "Group test pack",
  "tweaks": [$(($Tweaks) -join ',')]
}
"@
        }

        $script:GroupParameters = @{ NewDoc = $script:NewDoc; GroupBody = $script:GroupBody }
    }

    It 'accepts a group whose options are its states, detect the same value and write the same targets' {
        InModuleScope WindowsTweaker -Parameters $script:GroupParameters {
            param ($NewDoc, $GroupBody)
            $Path = & $NewDoc -Name 'group-ok.json' -Content (& $GroupBody)
            $Result = Test-WtCatalogFile -Path $Path -AsPack
            @($Result.Errors).Count | Should -Be 0 -Because (@($Result.Errors) -join '; ')
            $Result.Valid | Should -BeTrue
        }
    }

    It 'refuses a group without a revision, a duplicate group id and a single option' {
        InModuleScope WindowsTweaker -Parameters $script:GroupParameters {
            param ($NewDoc, $GroupBody)

            $Path = & $NewDoc -Name 'group-norev.json' -Content (& $GroupBody -NoRevision)
            $Result = Test-WtCatalogFile -Path $Path -AsPack
            $Result.Valid | Should -BeFalse
            ($Result.Errors -join ' ') | Should -Match 'group\.revision'

            $Path = & $NewDoc -Name 'group-dup.json' -Content (& $GroupBody -SecondTweak)
            $Result = Test-WtCatalogFile -Path $Path -AsPack
            $Result.Valid | Should -BeFalse
            ($Result.Errors -join ' ') | Should -Match 'declared twice'

            $Path = & $NewDoc -Name 'group-one.json' -Content (& $GroupBody -OneOption)
            $Result = Test-WtCatalogFile -Path $Path -AsPack
            $Result.Valid | Should -BeFalse
            ($Result.Errors -join ' ') | Should -Match 'at least two alternatives'
        }
    }

    It 'refuses an alternative that cannot be detected or that writes its own targets' {
        InModuleScope WindowsTweaker -Parameters $script:GroupParameters {
            param ($NewDoc, $GroupBody)

            # An option that is not in the detection map can never be reported as the live one.
            $Path = & $NewDoc -Name 'group-undetectable.json' -Content (& $GroupBody -Undetectable)
            $Result = Test-WtCatalogFile -Path $Path -AsPack
            $Result.Valid | Should -BeFalse
            ($Result.Errors -join ' ') | Should -Match 'detection\.map'

            # An option that writes an extra target would leave it behind when the user switches.
            $Path = & $NewDoc -Name 'group-targets.json' -Content (& $GroupBody -ExtraTarget)
            $Result = Test-WtCatalogFile -Path $Path -AsPack
            $Result.Valid | Should -BeFalse
            ($Result.Errors -join ' ') | Should -Match 'must write the same targets'
        }
    }

    It 'refuses a group whose extra state, default state or irreversibility breaks the exclusivity' {
        InModuleScope WindowsTweaker -Parameters $script:GroupParameters {
            param ($NewDoc, $GroupBody)

            $Path = & $NewDoc -Name 'group-extra-state.json' -Content (& $GroupBody -ExtraState)
            $Result = Test-WtCatalogFile -Path $Path -AsPack
            $Result.Valid | Should -BeFalse
            ($Result.Errors -join ' ') | Should -Match 'states must be its options'

            $Path = & $NewDoc -Name 'group-default.json' -Content (& $GroupBody -BadDefault)
            $Result = Test-WtCatalogFile -Path $Path -AsPack
            $Result.Valid | Should -BeFalse
            ($Result.Errors -join ' ') | Should -Match 'defaultState'

            $Path = & $NewDoc -Name 'group-irreversible.json' -Content (& $GroupBody -Irreversible)
            $Result = Test-WtCatalogFile -Path $Path -AsPack
            $Result.Valid | Should -BeFalse
            ($Result.Errors -join ' ') | Should -Match 'irreversible'
        }
    }
}

Describe 'Definition view and filters' {

    It 'reports the declarative status of every tweak and filters on it' {
        $Definitions = @(Get-WtTweakDefinitionView -Filter definitions)
        @($Definitions).Count | Should -BeGreaterThan 0
        foreach ($Row in $Definitions) { $Row.Backed | Should -BeTrue }
        (@($Definitions | ForEach-Object { $_.Id }) -contains 'Privacy.DismissMSAccount') | Should -BeTrue

        # A pack definition registered earlier in this run is reported as a pack source, and
        # filtering by an installed pack id that does not exist must select nothing.
        $Packs = @(Get-WtTweakDefinitionView -Filter 'pack:No.Such.Pack')
        @($Packs).Count | Should -Be 0
        @(Get-WtTweakDefinitionView -Filter definitions).Count | Should -BeGreaterOrEqual @($Definitions).Count
    }

    It 'reports an unrecognised filter instead of silently showing everything' {
        { Get-WtTweakDefinitionView -Filter 'nonsense:1' -ErrorAction Stop } | Should -Throw -ExpectedMessage '*nonsense:1*'
    }

    It 'separates the support status of a pack from a built-in definition' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $BuiltIn = Get-WtTweakInternal -Id 'Privacy.WindowsTips'
            Get-WtSupportStatusInternal -Tweak $BuiltIn | Should -Be 'Structural'

            $Body = (& $PackBody -Id 'WtTest.Support' -TweakId 'WtTest.Support.Item').Replace('"structural": "Structural"', '"structural": "Structural", "providerTests": "WindowsValidated", "windowsIntegration": { "result": "WindowsValidated", "build": "26100" }')
            $Path = & $NewDoc -Name 'support.json' -Content $Body
            $Read = Read-WtCatalogJson -Path $Path
            $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()
            [void](Import-WtCatalogDocument -Document $Document -Source 'Pack' -PackId 'WtTest.Support')

            # The pack claims Windows validation; the engine records the claim and refuses to
            # present it as its own support status.
            $Imported = Get-WtTweakInternal -Id 'WtTest.Support.Item'
            $Imported.DefinitionEvidence.AuthorClaimed | Should -BeTrue
            $Imported.DefinitionEvidence.WindowsIntegration.AuthorClaimed | Should -BeTrue
            Get-WtSupportStatusInternal -Tweak $Imported | Should -Be 'AuthorClaimed'

            # A pack that claims nothing beyond structure stays unverified.
            $Plain = & $PackBody -Id 'WtTest.Plain' -TweakId 'WtTest.Plain.Item'
            $PlainPath = & $NewDoc -Name 'plain.json' -Content $Plain
            $PlainRead = Read-WtCatalogJson -Path $PlainPath
            $PlainDocument = ConvertFrom-WtCatalogElement -Element $PlainRead.Document.RootElement
            $PlainRead.Document.Dispose()
            [void](Import-WtCatalogDocument -Document $PlainDocument -Source 'Pack' -PackId 'WtTest.Plain')
            Get-WtSupportStatusInternal -Tweak (Get-WtTweakInternal -Id 'WtTest.Plain.Item') | Should -Be 'Unverified'
        }
    }
}

Describe 'Dependency planner' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    BeforeAll {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            if (-not $Script:WtCatalog.Contains('Test.PlanBase'))
            {
                New-WtRegistryTweak -Id 'Test.PlanBase' -Category 'System' `
                    -Name @{ en = 'Plan base'; vi = 'Nen ke hoach' } `
                    -Description @{ en = 'Base'; vi = 'Nen' } -Impact @{ en = 'Base'; vi = 'Nen' } `
                    -Scope 'User' -Privilege 'None' -StateNames @('Enabled', 'Disabled') -DefaultState 'Enabled' `
                    -Detection @{ Path = 'HKCU:\Software\WtPlan'; Name = 'Base'; Map = [ordered]@{ Enabled = @(1); Disabled = @(0) } } `
                    -States @{
                        Enabled  = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\WtPlan'; Name = 'Base'; Type = 'DWord'; Value = 1 })
                        Disabled = @(@{ Kind = 'RegistrySet'; Path = 'HKCU:\Software\WtPlan'; Name = 'Base'; Type = 'DWord'; Value = 0 })
                    }
            }
        }
    }

    It 'orders a prerequisite before the tweak that requires it' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $Body = & $PackBody -Id 'WtTest.Plan' -TweakId 'WtTest.Plan.Dependent' -Extra ', "requires": ["Test.PlanBase"]'
            $Path = & $NewDoc -Name 'plan.json' -Content $Body
            $Read = Read-WtCatalogJson -Path $Path
            $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()
            [void](Import-WtCatalogDocument -Document $Document -Source 'Pack' -PackId 'WtTest.Plan')

            $Plan = Get-WtDependencyPlanInternal -Ids @('WtTest.Plan.Dependent')
            $Plan.Errors | Should -BeNullOrEmpty
            $Plan.Order | Should -Be @('Test.PlanBase', 'WtTest.Plan.Dependent')
            @($Plan.Items | Where-Object { $_.Source -eq 'Prerequisite' }).Count | Should -Be 1
        }
    }

    It 'leaves a satisfied prerequisite out of the apply set and never rewrites it' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            Mock Get-WtTweakState { param ($Tweak, $Id, $Category, $Search, $Arguments) @{ State = 'Enabled'; Supported = $true } }

            $Body = & $PackBody -Id 'WtTest.Plan2' -TweakId 'WtTest.Plan2.Dependent' -Extra ', "requires": ["Test.PlanBase"]'
            $Path = & $NewDoc -Name 'plan2.json' -Content $Body
            $Read = Read-WtCatalogJson -Path $Path
            $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()
            [void](Import-WtCatalogDocument -Document $Document -Source 'Pack' -PackId 'WtTest.Plan2')

            $Plan = Get-WtDependencyPlanInternal -Ids @('WtTest.Plan2.Dependent')
            $Satisfied = @($Plan.Items | Where-Object { $_.Action -eq 'Skip-Satisfied' })
            $Satisfied.Count | Should -Be 1
            $Satisfied[0].Id | Should -Be 'Test.PlanBase'
            @($Plan.Items | Where-Object { $_.Action -eq 'Apply' }).Count | Should -Be 1
        }
    }

    It 'keeps an unreadable prerequisite in the plan and says so' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            Mock Get-WtTweakState { param ($Tweak, $Id, $Category, $Search, $Arguments) @{ State = 'Unsupported'; Supported = $false; Reason = 'no registry' } }

            $Body = & $PackBody -Id 'WtTest.Plan3' -TweakId 'WtTest.Plan3.Dependent' -Extra ', "requires": ["Test.PlanBase"]'
            $Path = & $NewDoc -Name 'plan3.json' -Content $Body
            $Read = Read-WtCatalogJson -Path $Path
            $Document = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()
            [void](Import-WtCatalogDocument -Document $Document -Source 'Pack' -PackId 'WtTest.Plan3')

            $Plan = Get-WtDependencyPlanInternal -Ids @('WtTest.Plan3.Dependent')
            @($Plan.Items | Where-Object { $_.Id -eq 'Test.PlanBase' })[0].Action | Should -Be 'Apply'
            @($Plan.Warnings).Count | Should -BeGreaterThan 0
        }
    }

    It 'reports an unknown id, a cycle and a conflict instead of resolving them by guessing' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $Plan = Get-WtDependencyPlanInternal -Ids @('No.Such.Tweak')
            ($Plan.Errors -join ' ') | Should -Match 'No.Such.Tweak'

            $Body = & $PackBody -Id 'WtTest.Plan4' -TweakId 'WtTest.Plan4.A' -Extra ', "requires": ["WtTest.Plan4.B"], "conflictsWith": ["Test.PlanBase"]'
            $Path = & $NewDoc -Name 'plan4a.json' -Content $Body
            $Read = Read-WtCatalogJson -Path $Path
            $DocumentA = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()
            [void](Import-WtCatalogDocument -Document $DocumentA -Source 'Pack' -PackId 'WtTest.Plan4')

            $Body = & $PackBody -Id 'WtTest.Plan4' -TweakId 'WtTest.Plan4.B' -Extra ', "requires": ["WtTest.Plan4.A"]'
            $Path = & $NewDoc -Name 'plan4b.json' -Content $Body
            $Read = Read-WtCatalogJson -Path $Path
            $DocumentB = ConvertFrom-WtCatalogElement -Element $Read.Document.RootElement
            $Read.Document.Dispose()
            [void](Import-WtCatalogDocument -Document $DocumentB -Source 'Pack' -PackId 'WtTest.Plan4' -AllowExisting)

            $Plan = Get-WtDependencyPlanInternal -Ids @('WtTest.Plan4.A')
            ($Plan.Errors -join ' ') | Should -Match 'cycle'

            $Plan = Get-WtDependencyPlanInternal -Ids @('WtTest.Plan4.A', 'Test.PlanBase')
            ($Plan.Errors -join ' ') | Should -Match 'conflict'
            @($Plan.Conflicts).Count | Should -Be 1
        }
    }
}

Describe 'Migration registry' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
        Remove-Item -LiteralPath $env:WT_MIGRATIONS_PATH -Force -ErrorAction Ignore
        InModuleScope WindowsTweaker { $Script:WtMigrations = @() }
    }

    It 'resolves a renamed id, keeps the old one working and refuses a broken registry' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            # A rename is only useful if the old id still resolves, so the test renames an
            # existing built-in id in the registry and asks for the old one.
            $Before = $Script:WtCatalog.Contains('Privacy.WindowsTips')
            $Before | Should -BeTrue

            $Path = & $NewDoc -Name 'migrations.json' -Content (@'
{
  "schemaVersion": 1,
  "kind": "Migrations",
  "id": "builtin",
  "migrations": [
    { "from": "Privacy.NoSuchOldId", "to": "Privacy.WindowsTips", "kind": "rename", "since": "1.0.0", "reason": "test rename" }
  ]
}
'@)

            $Load = Import-WtMigrationRegistry -Path $Path
            @($Load.Errors).Count | Should -Be 0

            $Resolved = Resolve-WtTweakIdInternal -Id 'Privacy.NoSuchOldId'
            $Resolved.Migrated | Should -BeTrue
            $Resolved.Id | Should -Be 'Privacy.WindowsTips'
            $Resolved.Tweak | Should -Not -BeNullOrEmpty

            (Get-WtTweakInternal -Id 'Privacy.NoSuchOldId').Id | Should -Be 'Privacy.WindowsTips'
            @(Get-WtTweakHistoryIdsInternal -Id 'Privacy.WindowsTips') | Should -Contain 'Privacy.NoSuchOldId'

            $Broken = & $NewDoc -Name 'migrations-broken.json' -Content (@'
{
  "schemaVersion": 1,
  "kind": "Migrations",
  "migrations": [
    { "from": "A.B", "to": "C.D", "kind": "rename" },
    { "from": "C.D", "to": "A.B", "kind": "rename" }
  ]
}
'@)
            $Load = Import-WtMigrationRegistry -Path $Broken
            @($Load.Errors).Count | Should -BeGreaterThan 0
            ($Load.Errors -join ' ') | Should -Match 'does not exist|cycle'
            @($Script:WtMigrations).Count | Should -Be 0
        }
    }

    It 'reports a retired id as retired and reports preset entries that no longer resolve' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $Path = & $NewDoc -Name 'migrations-retire.json' -Content (@'
{
  "schemaVersion": 1,
  "kind": "Migrations",
  "migrations": [
    { "from": "Privacy.Retired.Thing", "kind": "deprecate", "reason": "merged into another setting" }
  ]
}
'@)
            $Load = Import-WtMigrationRegistry -Path $Path
            @($Load.Errors).Count | Should -Be 0

            $Resolved = Resolve-WtTweakIdInternal -Id 'Privacy.Retired.Thing'
            $Resolved.Retired | Should -BeTrue
            $Resolved.Tweak | Should -BeNullOrEmpty
            $Resolved.Reason | Should -Match 'retired'
        }

        $Findings = @(Get-WtTweakMigration -Problems)
        foreach ($Finding in $Findings) { $Finding.Id | Should -Not -BeNullOrEmpty }
    }

    It 'keeps journal provenance while finding a pre-rename entry' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $Rename = & $NewDoc -Name 'migrations-provenance.json' -Content (@'
{
  "schemaVersion": 1,
  "kind": "Migrations",
  "migrations": [
    { "from": "Privacy.NoSuchOldId", "to": "Privacy.WindowsTips", "kind": "rename", "reason": "test rename" }
  ]
}
'@)
            $Load = Import-WtMigrationRegistry -Path $Rename
            @($Load.Errors).Count | Should -Be 0

            $Entry = [pscustomobject]@{
                historyId = 'h1'
                tweakId   = 'Privacy.NoSuchOldId'
                rolledBack = $false
                outcome   = 'succeeded'
                records   = @([pscustomobject]@{ resource = 'Registry'; path = 'HKCU:\Software\X'; name = 'Y' })
            }

            Mock Get-WtHistoryEntry { param ($TweakId, $Limit) if (-not $TweakId -or $TweakId -eq 'Privacy.NoSuchOldId') { return @($Entry) } return @() }

            $Candidate = Get-WtRollbackCandidate -TweakId 'Privacy.WindowsTips'
            $Candidate | Should -Not -BeNullOrEmpty
            $Candidate[0].tweakId | Should -Be 'Privacy.NoSuchOldId'
        }
    }
}

Describe 'Tweak packs' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
        Remove-Item -LiteralPath $env:WT_PACKS_PATH -Recurse -Force -ErrorAction Ignore
    }

    It 'validates a pack file without storing or registering it' {
        $Path = & $NewDoc -Name 'pack-validate.json' -Content (& $PackBody -Id 'WtTest.Lifecycle' -TweakId 'WtTest.Lifecycle.Item')
        $Result = Test-WtCatalogFile -Path $Path -AsPack
        $Result.Valid | Should -BeTrue
        $Result.TweakCount | Should -Be 1
        $Result.Sha256 | Should -Match '^[0-9a-f]{64}$'
        Test-Path -LiteralPath (Join-Path $env:WT_PACKS_PATH 'WtTest.Lifecycle.json') | Should -BeFalse
    }

    It 'stores the document byte for byte with its hash, and refuses a second import without -Force' {
        $Path = & $NewDoc -Name 'pack-import.json' -Content (& $PackBody -Id 'WtTest.Import' -TweakId 'WtTest.Import.Item')

        $Import = Import-WtTweakPack -Path $Path -Enable -Confirm:$false
        $Import.Imported | Should -BeTrue
        $Import.Enabled | Should -BeTrue
        $Import.TweakIds | Should -Be @('WtTest.Import.Item')

        $Stored = Join-Path $env:WT_PACKS_PATH 'WtTest.Import.json'
        (Get-FileHash -LiteralPath $Stored -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $Import.Sha256
        (Get-Content -LiteralPath $Stored -Raw) | Should -Be (Get-Content -LiteralPath $Path -Raw)

        $Again = Import-WtTweakPack -Path $Path -Confirm:$false
        $Again.Imported | Should -BeFalse
        ($Again.Errors -join ' ') | Should -Match 'already installed'

        $Packs = @(Get-WtTweakPack)
        $Packs.Count | Should -Be 1
        $Packs[0].Enabled | Should -BeTrue
        (Get-WtTweakDefinition -Id 'WtTest.Import.Item').Source | Should -Be 'Pack'
    }

    It 'does not store anything with -WhatIf' {
        $Path = & $NewDoc -Name 'pack-whatif.json' -Content (& $PackBody -Id 'WtTest.WhatIf' -TweakId 'WtTest.WhatIf.Item')
        $Result = Import-WtTweakPack -Path $Path -WhatIf -Confirm:$false
        $Result.Imported | Should -BeFalse
        @(Get-WtTweakPack).Count | Should -Be 0
        Test-Path -LiteralPath $env:WT_PACKS_PATH | Should -BeFalse
    }

    It 'refuses a pack that tries to leave its namespace, and one that is too large' {
        $Path = & $NewDoc -Name 'pack-hostile.json' -Content (& $PackBody -Id 'WtTest.Hostile' -TweakId 'Privacy.DismissMSAccount')
        $Result = Import-WtTweakPack -Path $Path -Confirm:$false
        $Result.Imported | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'pack namespace'
        @(Get-WtTweakPack).Count | Should -Be 0

        $Filler = 'x' * 300000
        $Path = & $NewDoc -Name 'pack-huge.json' -Content (& $PackBody -Id 'WtTest.Huge' -TweakId 'WtTest.Huge.Item' -Extra (', "notes": "' + $Filler + '"'))
        $Result = Import-WtTweakPack -Path $Path -Confirm:$false
        $Result.Imported | Should -BeFalse
        ($Result.Errors -join ' ') | Should -Match 'byte limit'
    }

    It 'refuses to enable a stored document that was edited after import' {
        $Path = & $NewDoc -Name 'pack-tamper.json' -Content (& $PackBody -Id 'WtTest.Tamper' -TweakId 'WtTest.Tamper.Item')
        $Import = Import-WtTweakPack -Path $Path -Enable -Confirm:$false
        $Import.Imported | Should -BeTrue

        $Stored = Join-Path $env:WT_PACKS_PATH 'WtTest.Tamper.json'
        (Get-Content -LiteralPath $Stored -Raw).Replace('"value": 1', '"value": 7') | Set-Content -LiteralPath $Stored -Encoding utf8

        $Disable = Disable-WtTweakPack -Id 'WtTest.Tamper' -Confirm:$false
        $Disable.Enabled | Should -BeFalse

        $Enable = Enable-WtTweakPack -Id 'WtTest.Tamper' -Confirm:$false
        $Enable.Enabled | Should -BeFalse
        ($Enable.Errors -join ' ') | Should -Match 'hash'
    }

    It 'unregisters the definitions when disabled and keeps the stored pack' {
        $Path = & $NewDoc -Name 'pack-state.json' -Content (& $PackBody -Id 'WtTest.State' -TweakId 'WtTest.State.Item')
        [void](Import-WtTweakPack -Path $Path -Enable -Confirm:$false)
        (Get-WtTweak -Id 'WtTest.State.Item') | Should -Not -BeNullOrEmpty

        $Disable = Disable-WtTweakPack -Id 'WtTest.State' -Confirm:$false
        $Disable.Enabled | Should -BeFalse
        (Get-WtTweak -Id 'WtTest.State.Item') | Should -BeNullOrEmpty
        @(Get-WtTweakPack).Count | Should -Be 1

        $Enable = Enable-WtTweakPack -Id 'WtTest.State' -Confirm:$false
        $Enable.Enabled | Should -BeTrue
        (Get-WtTweak -Id 'WtTest.State.Item') | Should -Not -BeNullOrEmpty
    }

    It 'restores a change created by a pack after the pack was removed' {
        $Path = & $NewDoc -Name 'pack-recover.json' -Content (& $PackBody -Id 'WtTest.Recover' -TweakId 'WtTest.Recover.Item')
        [void](Import-WtTweakPack -Path $Path -Enable -Confirm:$false)

        $Applied = Invoke-WtTweak -Id 'WtTest.Recover.Item' -State Enabled -Confirm:$false
        $Applied.Status | Should -Be 'succeeded'
        InModuleScope WindowsTweaker { $Script:WtTestRegistry['HKCU:\Software\WtTest\Pack|Item'].Value | Should -Be 1 }

        $Removed = Remove-WtTweakPack -Id 'WtTest.Recover' -Force -Confirm:$false
        $Removed.Removed | Should -BeTrue
        (Get-WtTweak -Id 'WtTest.Recover.Item') | Should -BeNullOrEmpty

        # The definition is gone; the captured state is not, so the change is still reversible.
        $Restored = Undo-WtTweak -Id 'WtTest.Recover.Item' -Confirm:$false
        $Restored.Status | Should -Be 'succeeded'
        InModuleScope WindowsTweaker { $Script:WtTestRegistry.ContainsKey('HKCU:\Software\WtTest\Pack|Item') | Should -BeFalse }
    }

    It 'refuses to remove a pack while a change it created has not been rolled back' {
        $Path = & $NewDoc -Name 'pack-pending.json' -Content (& $PackBody -Id 'WtTest.Pending' -TweakId 'WtTest.Pending.Item')
        [void](Import-WtTweakPack -Path $Path -Enable -Confirm:$false)
        [void](Invoke-WtTweak -Id 'WtTest.Pending.Item' -State Enabled -Confirm:$false)

        $Removed = Remove-WtTweakPack -Id 'WtTest.Pending' -Confirm:$false
        $Removed.Removed | Should -BeFalse
        @($Removed.Pending).Count | Should -Be 1
        ($Removed.Errors -join ' ') | Should -Match 'not been rolled back'
        @(Get-WtTweakPack).Count | Should -Be 1

        $Removed = Remove-WtTweakPack -Id 'WtTest.Pending' -Force -Confirm:$false
        $Removed.Removed | Should -BeTrue

        $Rollback = Undo-WtTweak -Id 'WtTest.Pending.Item' -Force -Confirm:$false
        $Rollback.Status | Should -Be 'succeeded'
    }

    It 'ships a sample pack that validates and only writes inert values' {
        $Sample = Join-Path $PSScriptRoot '../samples/example-pack.json'
        Test-Path -LiteralPath $Sample | Should -BeTrue

        $Result = Test-WtCatalogFile -Path $Sample -AsPack
        $Result.Valid | Should -BeTrue -Because ($Result.Errors -join '; ')
        $Result.TweakCount | Should -BeGreaterThan 0

        # The sample exists to be imported on a real machine, so it must not touch anything
        # Windows reads: every operation stays inside its own HKCU subtree.
        $Document = Get-Content -LiteralPath $Sample -Raw | ConvertFrom-Json -AsHashtable
        foreach ($Tweak in @($Document.tweaks))
        {
            foreach ($State in $Tweak.states.Keys)
            {
                foreach ($Operation in @($Tweak.states[$State]))
                {
                    $Operation.hive | Should -Be 'HKCU'
                    $Operation.key | Should -BeLike 'Software\WindowsTweaker\*'
                }
            }
        }
    }

    It 'ships a migration registry that validates, even when it records nothing' {
        InModuleScope WindowsTweaker {
            # The shipped registry, not the temporary one this file points the loader at.
            $Shipped = Join-Path $Script:WtDataDirectory 'Catalog/migrations.json'
            Test-Path -LiteralPath $Shipped | Should -BeTrue

            $Load = Import-WtMigrationRegistry -Path $Shipped
            @($Load.Errors).Count | Should -Be 0
            $Load.Present | Should -BeTrue
            # Nothing has been renamed yet; the registry must still be a valid document.
            @($Load.Records).Count | Should -Be 0
            @(Get-WtTweakMigration).Count | Should -Be 0

            # Leave the loader pointing at the temporary registry the rest of the file uses.
            [void](Import-WtMigrationRegistry -Path $env:WT_MIGRATIONS_PATH)
        }
    }

    It 'reports a missing pack instead of failing' {
        @(Get-WtTweakPack -Id 'No.Such.Pack').Count | Should -Be 0
        (Remove-WtTweakPack -Id 'No.Such.Pack' -Confirm:$false).Removed | Should -BeFalse
        (Enable-WtTweakPack -Id 'No.Such.Pack' -Confirm:$false).Enabled | Should -BeFalse
        (Disable-WtTweakPack -Id 'No.Such.Pack' -Confirm:$false).Enabled | Should -BeFalse
    }
}

Describe 'Catalog surfaces in the terminal interface' {

    BeforeEach {
        & $script:ResetStore
        & $script:InitializePlatform
    }

    It 'filters the list with a definition filter typed into the search box' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $State = New-WtTuiState -Language 'en' -Colour 'TrueColor' -Silent `
                -KeySource { return $null } -SizeSource { return @{ Width = 120; Height = 40 } }

            # The interface refuses to list a tweak the platform reports as unsupported; the
            # prerequisite check is doubled here so the catalog is visible outside Windows.
            Mock Test-WtPrerequisite {
                param ($Tweak)
                [pscustomobject]@{ PSTypeName = 'WindowsTweaker.PrerequisiteResult'; TweakId = $Tweak.Id; Supported = $true; Reason = ''; Missing = @(); Requirements = @() }
            }

            $State.Search = '@risk:High'
            Sync-WtTuiCatalog -State $State

            $State.Items.Count | Should -BeGreaterThan 0
            foreach ($Item in $State.Items)
            {
                (Get-WtTweakInternal -Id $Item.State.Id).Risk | Should -Be 'High'
            }

            $State.Search = '@definitions,scope:User'
            Sync-WtTuiCatalog -State $State
            foreach ($Item in $State.Items)
            {
                $Tweak = Get-WtTweakInternal -Id $Item.State.Id
                $Tweak.Scope | Should -Be 'User'
                @($Tweak.PSObject.Properties.Name) | Should -Contain 'DefinitionDocument'
            }
        }
    }

    It 'reports an unknown filter in the status line instead of showing everything' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $State = New-WtTuiState -Language 'en' -Colour 'TrueColor' -Silent `
                -KeySource { return $null } -SizeSource { return @{ Width = 120; Height = 40 } }

            $State.Search = '@nonsense:1'
            Update-WtTuiItems -State $State

            $State.Items.Count | Should -Be 0
            $State.Status.Text | Should -Match 'nonsense:1'
        }
    }

    It 'shows the definition, its support and its evidence in the details pane' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            $State = New-WtTuiState -Language 'en' -Colour 'TrueColor' -Silent `
                -KeySource { return $null } -SizeSource { return @{ Width = 140; Height = 45 } }

            Mock Test-WtPrerequisite {
                param ($Tweak)
                [pscustomobject]@{ PSTypeName = 'WindowsTweaker.PrerequisiteResult'; TweakId = $Tweak.Id; Supported = $true; Reason = ''; Missing = @(); Requirements = @() }
            }

            $State.Search = 'Privacy.WindowsTips'
            Sync-WtTuiCatalog -State $State
            $State.ItemIndex = 0
            $State.Items[0].Kind | Should -Be 'Tweak'

            Add-WtTuiDetails -State $State -Layout @{ Top = 1; Bottom = 45 } -Column 1 -Width 120
            $Text = (ConvertTo-WtScreenPlainText -Screen $State.Screen) -join "`n"

            $Text | Should -Match 'BuiltIn \(rev 1\)'
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Cat.Tui.Support')))
            $Text | Should -Match 'Validated'
            $Text | Should -Match ([regex]::Escape((Get-WtString -Key 'Cat.Tui.DefinitionTitle')))
        }
    }

    It 'lists installed packs in the overview and marks author claims as claims' {
        InModuleScope WindowsTweaker -Parameters $script:WtTestParameters {
            param ($NewDoc, $PackBody)
            # No pack installed: the section explains how to install one.
            Get-WtTuiPackLines | Should -Contain ('  ' + (Get-WtString -Key 'Cat.PackListEmpty'))

            $Body = & $PackBody -Id 'WtTest.Tui' -TweakId 'WtTest.Tui.Item'
            $Path = & $NewDoc -Name 'tui-pack.json' -Content $Body
            $Import = Import-WtTweakPack -Path $Path -Enable -Confirm:$false
            $Import.Imported | Should -BeTrue

            $Lines = (Get-WtTuiPackLines) -join "`n"
            $Lines | Should -Match 'WtTest\.Tui 1\.0\.0'
            $Lines | Should -Match ([regex]::Escape((Get-WtString -Key 'Cat.Tui.PackEnabled')))

            (Get-WtSupportStatusInternal -Tweak (Get-WtTweakInternal -Id 'WtTest.Tui.Item')) | Should -Be 'Unverified'
        }
    }
}
