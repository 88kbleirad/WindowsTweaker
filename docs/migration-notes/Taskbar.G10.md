# Migration notes - Taskbar batch G10

Legacy source: `modules/*.ps1` (read-only reference material during the migration).
New definitions: `src/WindowsTweaker/Tweaks/Taskbar/Taskbar.G10.ps1`.

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| `TaskbarCombine.ps1` | migrated | `Taskbar.CombineButtons` | Legacy parameter sets `Always`/`Full`/`Never` become states `Always` (TaskbarGlomLevel 0), `WhenFull` (1) and `Never` (2). The LGPO lines `Set-Policy -Scope Computer/User -Path SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name NoTaskGrouping -Type DELETE` resolve to `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer` and `HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer`, i.e. exactly the two keys the module also cleared with `Remove-ItemProperty`; both no longer exist as LGPO, so every state now performs the two `RegistryRemove` operations plus the `RegistrySet`. Those two values are declared in `-ManagedPolicy` because either one pins the setting. Removing the machine value needs elevation, hence `-Scope UserAndMachine -Privilege Admin`. |
| `TaskbarEndTask.ps1` | migrated | `Taskbar.EndTask` | Same value (`HKCU:\...\Explorer\Advanced\TaskbarDeveloperSettings\TaskbarEndTask`), but the legacy "Disable" branch deleted the value while this definition writes `0`, the documented default, so detection is deterministic; the state store still captures and restores "value absent" exactly. The registry provider creates the `TaskbarDeveloperSettings` subkey on demand, so no separate `RegistryKeyCreate` is needed. Narrowed to `-SupportedOS Windows11 -MinBuild 22621` because the "End task" entry only exists in Windows 11 22H2+. |
| `TaskbarSearch.ps1` | already covered | `Taskbar.SearchBox` (existing) | Same setting (`SearchBoxTaskbarMode`), already defined in `Tweaks/Taskbar/Taskbar.ps1` with the four states `Hidden`/`IconOnly`/`SearchBox`/`IconAndLabel`; not duplicated. Fidelity gap in the pre-existing definition when this batch was written (reported to the catalog owner, who fixed it in `Taskbar.ps1`): the legacy module clears `DisableSearch`/`SearchOnTaskbarMode` under `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search`, which a domain policy could otherwise use to override the user value; every state of `Taskbar.SearchBox` now lists those two `RegistryRemove` operations and both values are declared in `-ManagedPolicy`. The legacy module's `New-ItemProperty ...\SOFTWARE\Microsoft\PolicyManager\default\Search\DisableSearch -Name value -Value 0` is deliberately not reproduced: that value is an MDM default the module only ever resets to `0` (it is never set to `1` by the module), not a user-visible setting. |
| `SecondsInSystemClock.ps1` | migrated | `Taskbar.SecondsInClock` | `ShowSecondsInSystemClock` DWord 1/0, identical values to the legacy `-Show`/`-Hide` branches. `-MinBuild 14393` (Windows 10 1607, when the value appeared); the impact text states that Windows 11 only honours it from 22H2 (build 22621) because there is no single minimum build covering both families. |
| `TaskViewButton.ps1` | already covered | `Taskbar.TaskViewButton` (existing) | Same setting (`ShowTaskViewButton`), already defined in `Tweaks/Taskbar/Taskbar.ps1`; not duplicated. Fidelity gap in the pre-existing definition when this batch was written (reported to the catalog owner, who fixed it in `Taskbar.ps1`): the legacy module also removes `HideTaskViewButton` from `HKCU:\Software\Policies\Microsoft\Windows\Explorer` and `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer` (its two `Set-Policy ... -Type DELETE` lines), which would otherwise pin the button's visibility; both states of `Taskbar.TaskViewButton` now list those two `RegistryRemove` operations, declared in `-ManagedPolicy`. |
| `UnpinTaskbarShortcuts.ps1` | not ported | - | See below. |
| `TaskbarAlignment.ps1` | already covered (recorded for completeness; the module is not part of this batch's conversion list) | `Taskbar.Alignment` (existing) | Same setting (`TaskbarAl` DWord 0/1), already defined in `Tweaks/Taskbar/Taskbar.ps1`; not duplicated. |

`modules/TaskbarWidgets.ps1` belongs to the same legacy area but is already handled by
the pre-existing `Taskbar.Widgets` definition (see the header comment of
`Tweaks/Taskbar/Taskbar.ps1`); it is not part of this batch.

## Why `UnpinTaskbarShortcuts.ps1` is not ported

The legacy function takes `-Shortcuts Edge,Store,Outlook` and, for each selected
shortcut, invokes the shell's localized *Unpin from taskbar* verb: the verb name comes
from an inline `[WinAPI.GetStrings]::GetString(5387)` helper (an `Add-Type` of inline
Win32 API code) and the verb is executed through `Shell.Application` COM
(`.Verb(...).DoIt()`), either on the shortcut file in
`%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\Taskbar` or on an item
of the shell namespace `shell:::{4234d49b-0245-4df3-b780-3893943456e1}` (AppsFolder).

It cannot be expressed with the providers the engine captures state and rollback
through:

1. **No provider can run a shell verb.** `Invoke-WtProcess` runs a process with
   `-File`; there is no shell-verb (`ShellExecute`) call, no COM seam, and the
   localized verb name cannot be obtained without the banned inline `Add-Type` of
   Win32 API code (rule 2).
2. **No provider deletes files.** Unpinning removes
   `...\Quick Launch\User Pinned\Taskbar\<name>.lnk` (a single file, not a recursive
   delete), and removal of user data must be its own explicit
   `-Irreversible -DataDeletion` tweak driven by a provider; no such provider exists,
   so any port would have to bypass state capture.
3. **The registry side is not a per-shortcut list.** The pinned taskbar layout lives
   in `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband` (`Favorites`,
   `FavoritesResolve`, ...) as opaque `REG_BINARY` blobs that only Explorer can
   compose. Rewriting them from outside Explorer is unsupported, and deleting them
   resets *every* pinned item — including the user's own pins — while Explorer
   rebuilds its default set, so it neither selects Edge/Store/Outlook nor reliably
   leaves Edge unpinned.

Because of (3) there is no honest registry-only substitute either, so no
`Taskbar.UnpinShortcuts`-style tweak was invented: it would be a different
user-visible setting (all pins, no selection) whose effect is user-data loss, which
rules 2 and 6 of the specification require to be a separate explicit `-DataDeletion`
tweak rather than a reuse of this module. Recorded as **not ported**.

## Validation

Run from the repository root:

```
~/opt/pwsh/pwsh -NoProfile -File tools/Parse-All.ps1
~/opt/pwsh/pwsh -NoProfile -File tools/Test-Catalog.ps1
~/opt/pwsh/pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests/Engine.Tests.ps1 -Output None"
```

* `tools/Parse-All.ps1` -> `Files parsed : 151`, `Parse errors : 39`, exit 1. All 39
  errors are in `modules/*.ps1` (the unparseable legacy modules that are deleted at the
  end of the migration); `Taskbar.G10.ps1` parses with 0 errors.
* `tools/Test-Catalog.ps1` -> `Tweaks in catalog : 19` (the count while the other
  batches were still landing; higher now), `Catalog invariants: OK`,
  exit 0. The catalog contains `Taskbar.Alignment`, `Taskbar.CombineButtons`,
  `Taskbar.EndTask`, `Taskbar.SearchBox`, `Taskbar.SecondsInClock`,
  `Taskbar.TaskViewButton`, `Taskbar.Widgets` - no duplicate ids.
* Pester `tests/Engine.Tests.ps1` -> all tests pass.

Batch-local smoke tests (temporary file, removed afterwards) exercised the three new
definitions against the in-memory registry double: dry run writes nothing
(`-WhatIf` on all three, registry untouched), `Taskbar.SecondsInClock` applies and
rolls back to the previous state, `Taskbar.CombineButtons` clears both
`NoTaskGrouping` values and sets `TaskbarGlomLevel`, detects `Always`/`WhenFull`/`Never`
from 0/1/2, and restores both policy values and the previous glom level on rollback;
`Taskbar.EndTask` applies/detects `Enabled` and `Disabled`.

## State after the batch was merged

* Re-checked on the merged tree: `tools/Parse-All.ps1` reports no parse-error row
  outside the legacy `modules/` tree (every `src/**` file, including this batch's,
  parses), `tools/Test-Catalog.ps1` reports `Catalog invariants: OK`, and the Pester
  suite is green.
* Two issues this batch reported were fixed upstream, in code owned by other batches:
  `Get-WtAggregateStatus` now ranks `dryrun` above `unchanged` (so a `-WhatIf` run of a
  multi-operation tweak no longer reports `unchanged` on a clean machine), and
  `Tweaks/Taskbar/Taskbar.ps1` now clears the `HideTaskViewButton` and
  `DisableSearch`/`SearchOnTaskbarMode` policy values as described in the table above.
  Neither change alters the definitions in this batch.
