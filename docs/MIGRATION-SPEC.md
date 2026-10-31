# Tweak migration specification (internal working document)

This document is the contract for converting the legacy `modules\*.ps1` functions
(partially extracted from Sophia Script for Windows, MIT, see
`THIRD-PARTY-NOTICES.md`) into catalog tweak definitions.

**Nothing from the upstream reference material (`reference/original-upstream-reference.txt`,
the file originally named `text.txt`) may be ported without review, and it must never be
executed.** `modules\*.ps1` was read-only reference material during the migration; every one
of its 117 files is now accounted for (`docs/FEATURE-INVENTORY.md`, `docs/migration-notes/`)
and the tree has been deleted. The `file:line` references to it in those notes describe the
revision it was reviewed in, which remains in the git history of the initial revision.

## Where new tweaks go

```
src/WindowsTweaker/Tweaks/<Category>/<BatchName>.ps1
```

`<Category>` is one of: `Privacy`, `Security`, `System`, `Explorer`, `Taskbar`,
`StartMenu`, `Apps`, `Network`, `Updates`, `Personalization`, `Maintenance`.

One file per batch, containing only `New-WtRegistryTweak` / `New-WtScriptTweak`
calls. Do not define helper functions in these files - use the providers.

## Metadata required for every tweak

| Parameter | Notes |
|---|---|
| `-Id` | `Category.Setting` (e.g. `Explorer.FileExtensions`), unique across the catalog, stable, never renamed silently |
| `-Category` | must match the folder |
| `-Name`, `-Description`, `-Impact` | localized hashtables `@{ en = '...'; vi = '...' }`; `-Impact` states the concrete consequence for the user |
| `-Scope` | `User`, `Machine`, `UserAndMachine`, `PerAdapter`, `PerApp` |
| `-Privilege` | `None` or `Admin` |
| `-SupportedOS` | default `@('Windows10','Windows11')`; narrow it when the setting only exists on a build |
| `-MinBuild` | when a minimum Windows build is required |
| `-Requires` | dependency tokens: `Cmdlet:<name>`, `Module:<name>`, `Admin`, `Windows`, `OS:Windows11`, `Build:22000` |
| `-Restart` | `None`, `Explorer`, `SignOut`, `Reboot` |
| `-Rollback` | `Full` (default), `Partial`, `None` |
| `-Risk` | `Low`, `Medium`, `High` |
| `-Detection` | registry detection map (declarative) or a `-Detect` script block |
| `-States` | state name -> array of operation descriptors (declarative) or `-Apply` script block |
| `-StateNames` | optional, to order states; must equal the `-States` keys |
| `-DefaultState` | the state used when the caller does not pass `-State` |
| `-ManagedPolicy` | `@{ Path; Name }` values that prove an organization policy governs the setting |
| `-ReducesProtection` | set for anything that weakens Defender/SmartScreen/UAC/logging/CFA |
| `-Irreversible`, `-DataDeletion` | set for app removal, file deletion, download-and-install |
| `-Parameters` | for tweaks that need `-Arguments` (list the expected keys) |

## State naming convention

`Enabled` / `Disabled` for booleans, meaning "the feature/behaviour is on/off".
For multi-value settings use descriptive states (`Left`, `Centre`, `Hidden`,
`IconOnly`, ...) and declare `-StateNames` explicitly.

## Operation descriptors (declarative registry tweaks)

```powershell
@{ Kind = 'RegistrySet';         Path = 'HKCU:\...'; Name = 'X'; Type = 'DWord'; Value = 1 }
@{ Kind = 'RegistryRemove';      Path = 'HKCU:\...'; Name = 'X' }
@{ Kind = 'RegistryKeyCreate';   Path = 'HKCU:\...' }
@{ Kind = 'RegistryKeyRemove';   Path = 'HKCU:\...'; Recurse = $true }
@{ Kind = 'Service';             Name = 'X'; StartupType = 'Disabled'; Status = 'Stopped' }
@{ Kind = 'ScheduledTask';       Path = '\Microsoft\X\'; Name = 'Y'; Enabled = $false }
@{ Kind = 'FirewallGroup';       Group = 'DiagTrack'; Enabled = 'True'; Action = 'Block' }
```

`Type` accepts `String`, `ExpandString`, `Binary`, `DWord`, `MultiString`, `QWord`.

Every state must list the *complete* set of operations needed to reach it, including
removing a `HKLM\SOFTWARE\Policies\...` value that would otherwise override the new
value (the legacy code expressed this as an LGPO `DELETE` line; we write the
equivalent registry operation directly because LGPO is not bundled and must not be
downloaded).

## Scripted tweaks

Use `New-WtScriptTweak` with `-Detect { param($Tweak, $Arguments) ... }` (read-only,
returns a hashtable with `State`, optional `Reason`, optional `Instances`) and
`-Apply { param($Tweak, $State, $Arguments) ... }` (returns the provider result
objects).

Inside `-Apply` and `-Detect` only provider functions may be used. Never call
`New-ItemProperty`, `Set-Service`, `Remove-AppxPackage`, ... directly: that would
bypass state capture, dry run, verification and logging.

Available providers (all private, all honour `-WhatIf`, capture state, verify and log):

* Registry: `Get-WtRegistryState`, `Set-WtRegistryValue`, `Remove-WtRegistryValue`,
  `New-WtRegistryKey`, `Remove-WtRegistryKey`
* Services: `Get-WtServiceSnapshot`, `Set-WtServiceState`
* Scheduled tasks: `Get-WtScheduledTaskSnapshot`, `Set-WtScheduledTaskState`
* Firewall groups: `Get-WtFirewallGroupSnapshot`, `Set-WtFirewallGroupState`
* DNS: `Get-WtDnsState`, `Set-WtDnsServer`, `Reset-WtDnsServer`, `Set-WtDohSetting`,
  `Get-WtNetworkAdapterInternal`
* Packages: `Get-WtAppxPackageInfo`, `Remove-WtAppxPackage`, `Get-WtProtectedPackage`
* Defender: `Get-WtMpPreferenceState`, `Set-WtMpPreferenceState`
* Processes/downloads: `Invoke-WtProcess`, `Test-WtFileSignature`, `Get-WtVerifiedDownload`
* Results: `New-WtOperationResult -Status <status> -Operation <name> -Target <t> -Message <m>`

## Hard rules (security and honesty)

1. Never disable Defender, Controlled Folder Access, SmartScreen, UAC prompts or
   security logging during startup or as a side effect of another tweak. Anything
   protection-reducing must be its own tweak with `-ReducesProtection`, `-Risk High`
   and an explicit impact text. Never apply anything automatically.
2. No `Invoke-Expression`, no download-and-execute, no `Add-Type` of inline C#,
   no copying/renaming executables into `System32`, no `-Force` recursive delete of
   user directories. Deletion of user data must be a separate, explicit,
   `-Irreversible -DataDeletion` tweak.
3. Dry run must never write, remove, download or install anything.
4. Report failures. Never report success for an operation that failed or was
   skipped, and never swallow an unexpected exception.
5. If a legacy function cannot be expressed honestly and safely (e.g. it needs
   LGPO, a bundled binary, or an undocumented trick), do not port it: record it in
   the batch notes with the reason and mark it as "not ported".
6. One tweak per user-visible setting. Do not create a tweak per registry value if
   the values always change together - group them into one tweak with one state
   each.

## Duplicates and dead code

The legacy tree contains duplicates (`DelieryOptimization.ps1` == `DeliveryOptimization.ps1`,
`UninstallUWPApp.ps1` and `UninstallUWPApps.ps1` both define `UninstallUWPApps`,
`Logging.ps1` duplicates module infrastructure). Collapse them into one tweak and
note the duplicate in the batch notes.

## Per-batch notes file

Write `docs/migration-notes/<BatchName>.md` with one line per legacy module:

```
| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| FileExtensions.ps1 | migrated | Explorer.FileExtensions | ... |
| Logging.ps1 | dropped | - | duplicate of framework logging |
```

## Validation each batch must run before reporting

From the repository root:

```bash
pwsh -NoProfile -File tools/Parse-All.ps1                            # AST parse, must be 0 errors
pwsh -NoProfile -File tools/Test-Catalog.ps1                         # catalog invariants
pwsh -NoProfile -Command "Invoke-Pester -Path tests"                  # unit and integration tests
pwsh -NoProfile -File tools/Invoke-Validation.ps1                    # all of the above + analyzer + dry-run proof
```

All of them must pass. Report the exact commands and their results.
