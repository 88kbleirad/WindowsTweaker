# Migration notes - Personalization batch G9

Legacy modules converted into `src/WindowsTweaker/Tweaks/Personalization/Personalization.G9.ps1`
(category `Personalization`, nine tweaks). The legacy files under `modules/` are
read-only reference material during the migration and are deleted at the end of it;
`reference/` was used only to confirm the meaning of values, nothing was executed and
no code was copied verbatim.

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| WindowsColorMode.ps1 | migrated | `Personalization.WindowsColorMode` | `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\SystemUsesLightTheme` DWord: `0` = `Dark`, `1` = `Light`, states declared in the legacy parameter-set order. The legacy file is the only module in `modules/` that opens its parameter block with `{` instead of `(`; `tools/Parse-All.ps1` therefore reports `UnexpectedAttribute` for it (line 5) and the function could never have run. The two branches that are readable in the file are reproduced exactly. The third option of the Windows 11 Settings drop-down ("Custom") is **not** a state of this value: it only reveals the two per-scope drop-downs, which are `SystemUsesLightTheme` (this tweak) and `AppsUseLightTheme` (`AppColorMode`), so no `Custom` state exists that could be applied honestly. |
| AppColorMode.ps1 | migrated | `Personalization.AppColorMode` | `AppsUseLightTheme` DWord: `0` = `Dark`, `1` = `Light`, legacy order. Separate user-visible setting from the Windows (shell) mode above, so it is a separate tweak. |
| AeroShaking.ps1 | migrated, legacy bug fixed | `Personalization.AeroShaking` | See "The AeroShaking fix" below. `DisallowShaking`: `0` = `Enabled` (the shake gesture works), `1` = `Disabled` (gesture ignored). Both states also delete `NoWindowMinimizingShortcuts` from `HKCU\Software\Policies\...\Explorer` and `HKLM\SOFTWARE\Policies\...\Explorer`, exactly as the legacy function did (the LGPO `DELETE` lines), so the tweak is `UserAndMachine` / `Admin` and declares the machine value as `-ManagedPolicy`. A machine that has never had the setting touched has no `DisallowShaking` value at all (the gesture works), which the declarative detector reports as `Unknown` with the "value not present" reason rather than guessing; `Enabled` is that out-of-box behaviour. |
| StickyShift.ps1 | migrated | `Personalization.StickyKeys` | `HKCU\Control Panel\Accessibility\StickyKeys\Flags` REG_SZ: `510` = `Enabled` (Windows default, the "press Shift five times" shortcut works), `506` = `Disabled`. Kept as the legacy `String` type. The tweak id uses the real name of the feature (Sticky Keys) because that is what the setting controls. |
| InputMethod.ps1 | migrated | `Personalization.InputMethod` | The legacy `-English` branch calls `Set-WinDefaultInputMethodOverride -InputTip "0409:00000409"`, which writes `HKCU\Control Panel\International\User Profile\InputMethodOverride` (REG_SZ) - the legacy `-Default` branch removes exactly that value, which is the evidence for the mapping. Scripted tweak: `Default` means "value absent", and the declarative `-Detection` map reports an absent value as `Unknown`, never as a state. Detection reports any other override as `Unknown` with the value in the reason instead of guessing. The legacy `-Default` branch wrote `-ErrorActionIgnore` (no space) instead of `-ErrorAction Ignore`, which is not a parameter of `Remove-ItemProperty`: the call cannot bind, so the removal never ran; the port does remove the value. `-Restart SignOut`: the override is applied when the session starts. |
| FirstLogonAnimation.ps1 | migrated | `Personalization.FirstLogonAnimation` | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\EnableFirstLogonAnimation` DWord `1`/`0`. Both states delete the `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\EnableFirstLogonAnimation` value first (legacy LGPO `DELETE`), declared as `-ManagedPolicy`; `Admin` because of the HKLM writes. |
| JPEGWallpapersQuality.ps1 | migrated | `Personalization.JpegWallpapersQuality` | `HKCU\Control Panel\Desktop\JPEGImportQuality` DWord: `Max` writes `100`, `Default` removes the value (as the legacy did). Scripted tweak for the same absent-value reason as `InputMethod`; a quality other than `100` is reported as `Unknown`, not as one of the two states. |
| PrtScnSnippingTool.ps1 | migrated | `Personalization.PrtScnSnippingTool` | `HKCU\Control Panel\Keyboard\PrintScreenKeyForSnippingEnabled` DWord: `1` = the Print Screen key opens screen snipping, `0` = it copies the screen to the clipboard. The legacy module writes this one value, and its two parameter sets differ only in the value, so the whole setting is one tweak with one state each (the "values that always change together" rule). On a build where the value does not exist yet (Windows 10, or a profile that never opened this Settings page) the declarative detector reports `Unknown` with the "value not present" reason, so the caller picks the state explicitly. |
| ControlPanelView.ps1 | migrated | `Personalization.ControlPanelView` | Two values that always change together: `StartupPage` (`0` = categories, `1` = all items) and `AllItemsIconView` (`0` = large icons, `1` = small icons), both under `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel`. `Category` / `LargeIcons` / `SmallIcons` reproduce the three legacy parameter sets exactly. Scripted tweak: no single one of the two values identifies the view, so the declarative map cannot detect it. Every state also deletes `ForceClassicControlPanel` from `HKCU\...\CurrentVersion\Policies\Explorer` (legacy LGPO `DELETE`; note the legacy LGPO line misspells it `ForceClassisControlPanel`, and the `New-Item` key creation is unnecessary because the registry provider creates the key), declared as `-ManagedPolicy`. |

## The AeroShaking fix

The legacy `modules/AeroShaking.ps1` is broken: **both** of its parameter sets
(`-Enable` and `-Disable`) end with
`New-ItemProperty ... -Name DisallowShaking -PropertyType DWord -Value 0 -Force`.
The two halves of the function are identical, so calling `AeroShaking -Disable`
enabled Aero Shake instead of turning it off - the feature could never be disabled
through that module (the parameter sets differ only in the switch the caller must
pass). The mapping the port uses is the one Windows documents and the one the
upstream copy of the module carries:

| State | `DisallowShaking` | Meaning |
|---|---|---|
| `Enabled` | `0` | the shake gesture is allowed (minimising the other windows) |
| `Disabled` | `1` | the gesture is ignored |

So the fix is the value for the `Disabled` state (`1` instead of the copy/pasted
`0`); `Enabled` keeps `0`. The policy deletions the legacy function performed
unconditionally in both branches (`NoWindowMinimizingShortcuts` in the user and in
the machine policy hive) are kept in both states, because a machine policy value
would otherwise override the user value and make the change invisible in the UI.
The impact text states the mapping, so the tweak cannot be mistaken for the broken
legacy behaviour.

## Batch-wide decisions

- **Declarative vs scripted.** Six tweaks are declarative registry tweaks. Three are
  scripted (`InputMethod`, `JpegWallpapersQuality`, `ControlPanelView`) because the
  framework's declarative detector returns `Unknown` for "value not present" and
  matches a single value only, and these settings need either the absent value to be
  a state or two values to be read together. Their `-Detect` blocks are read-only
  (`Get-WtRegistryState`) and their `-Apply` blocks use only the registry providers
  (`Set-WtRegistryValue` / `Remove-WtRegistryValue`), so `-WhatIf`, state capture,
  verification, logging and rollback all behave exactly as for declarative tweaks.
- **No `PrtScnSnippingTool` twin value was invented.** The assignment mentioned that
  the tweak may write more than one value and named `UseWinPrtScrCapture` as an
  example. That value is not in the legacy module, is not documented by Microsoft
  (the documented and community-registered value for this setting is
  `PrintScreenKeyForSnippingEnabled`), and a code search for the name returns no
  hits, so it was **not** added: writing a value that does not exist on the target
  build would be a fabricated operation. Should a build store the flag in a second
  value, it belongs in the same tweak state, not in a new tweak - the states are
  already shaped as complete operation lists.
- **LGPO.** No legacy LGPO call is ported. The values LGPO would have deleted
  (`NoWindowMinimizingShortcuts`, `EnableFirstLogonAnimation`,
  `ForceClassicControlPanel`) are removed with plain `RegistryRemove` /
  `Remove-WtRegistryValue` operations and declared with `-ManagedPolicy`, so the
  catalog can tell the user when an organization policy governs the setting.
- **State names and order.** Multi-value settings use the legacy parameter-set order
  (`Dark`/`Light`, `English`/`Default`, `Max`/`Default`,
  `Category`/`LargeIcons`/`SmallIcons`); booleans use `Enabled`/`Disabled` as the
  spec requires.
- **`-DefaultState`** is the Windows out-of-box behaviour in every tweak here
  (`Light` for both colour modes, `Enabled` for Aero Shake, Sticky Keys,
  Print Screen snipping and the first sign-in animation, `Default` for the input
  method override and the wallpaper quality, `Category` for the Control Panel view),
  so applying a tweak without an explicit `-State` does not change a stock system.
  For `PrtScnSnippingTool` the out-of-box value depends on the build (Windows 11
  22H2 and later ship with `1`), which is why the state has to be passed explicitly
  there; the detection tells the caller which state the machine is in.
- **`-Restart`** is `Explorer` for the two theme tweaks and for Aero Shake (the shell
  has to be restarted before the taskbar or the gesture repaints), `SignOut` for the
  keyboard/session-scoped settings (`StickyKeys`, `InputMethod`,
  `PrtScnSnippingTool`) and `None` for `FirstLogonAnimation`,
  `JpegWallpapersQuality` and `ControlPanelView`, which are read when they are used.
- **Security review.** Nothing in this batch removes a value, file or package
  belonging to the user, downloads anything, uses `Invoke-Expression` or `Add-Type`,
  or writes to `System32`. No tweak here touches Defender, SmartScreen, UAC or
  logging, so none is `-ReducesProtection`; all nine are `Risk Low` and `Rollback
  Full` (the removed policy values and the previous registry values are captured by
  the providers before every write).
- No duplicate legacy modules were found in this batch and no tweak id here collides
  with another batch (checked with the catalog's duplicate-id rule).

## Validation

Run from the repository root, after the file above was written:

```
$ ~/opt/pwsh/pwsh -NoProfile -File tools/Parse-All.ps1
File                                Line Id                                           Detail
----                                ---- --                                           ------
modules/DiagTrackService.ps1          34 MissingEndParenthesisInFunctionParameterList Missing ')' in function parameter list.
modules/ExportAssociations.ps1        54 UnexpectedToken                              Unexpected token ':' in expression or statement.
modules/InitialActions.ps1           110 EndSquareBracketExpectedAtEndOfAttribute     Missing ] at end of attribute or type literal.
modules/Logging.ps1                    3 TerminatorExpectedAtEndOfString              The string is missing the terminator: ".
modules/NetworkAdapterSavePower.ps1   36 MissingEndParenthesisInExpression            Missing closing ')' in expression.
modules/UninstallUWPApps.ps1         326 UnexpectedToken                              Unexpected token '(' in expression or statement.
modules/WindowsColorMode.ps1           5 UnexpectedAttribute                          Unexpected attribute 'Parameter'.
modules/WindowsFeatures.ps1          113 EmptyPipeElement                             An empty pipe element is not allowed.

Files parsed : 166
Parse errors : 39

$ ~/opt/pwsh/pwsh -NoProfile -File tools/Test-Catalog.ps1
Tweaks in catalog : 99
Catalog invariants: OK

$ ~/opt/pwsh/pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests/Engine.Tests.ps1 -Output None"
Passed=18 Failed=0 Skipped=0 Total=18 Duration=00:00:04.62
```

Every parse error listed by `tools/Parse-All.ps1` is in a legacy `modules/*.ps1`
file; `Parse-All.ps1` exits non-zero because of them. None of the files added by
this batch has an error, and `Import-Module src/WindowsTweaker/WindowsTweaker.psd1`
succeeds with all nine tweaks registered (the catalog and test counts above move as
the other batches of this migration are written in parallel; the nine tweaks of this
batch are unchanged by that).

In addition, all nine tweaks were exercised against the in-memory provider doubles
used by `tests/Engine.Tests.ps1` (scratch harness, not committed): every state of
every tweak was applied, verified against the expected registry values, detected
back to the same state, rolled back to the previously captured value, and for one
scripted tweak a `-WhatIf` run was confirmed to write nothing (10/10 checks passed).
