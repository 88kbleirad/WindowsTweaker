# Migration notes - batch `Privacy.G3` / `Updates.G3`

Legacy modules converted: the `Privacy` batch file
`src/WindowsTweaker/Tweaks/Privacy/Privacy.G3.ps1` and the `Updates` batch file
`src/WindowsTweaker/Tweaks/Updates/Updates.G3.ps1` (the `Updates` category had no
tweaks before this batch).

Reference material: `modules/*.ps1` (read-only during the migration, partially
extracted from Sophia Script for Windows, MIT, (c) 2023 farag2).
`reference/*.txt` was not executed and nothing was ported from it.

## Modules

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| AppsLanguageSwitch.ps1 | not ported | - | The only effect is the Windows-only `Set-WinLanguageBarOption [-UseLegacySwitchMode]` cmdlet from the `International` module. It has no documented, revertible registry representation and no provider wraps it, so porting it would bypass state capture, verification and `-WhatIf` (spec rule 5). |
| AppsSilentInstalling.ps1 | migrated | `Privacy.SilentInstalledApps` | `HKCU:\...\ContentDeliveryManager\SilentInstalledAppsEnabled` DWord 1/0. The legacy code removed the machine policy value `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent\DisableWindowsConsumerFeatures` (LGPO `DELETE`) before both branches, so both states list that removal first and the tweak is declared `UserAndMachine` / `Admin`; the policy value is also declared as `-ManagedPolicy`. Detected value `1` = `Enabled`, `0` = `Disabled`; default state `Disabled`. |
| PUAppsDetection.ps1 | migrated | `Privacy.PuaProtection` | Ported through the Defender provider (`Get-WtMpPreferenceState` / `Set-WtMpPreferenceState -Name 'PUAProtection'`) - `Set-MpPreference -PUAProtection 1/0`, never called directly by the tweak. `1` = `Enabled`, `2` = `Enabled` (audit-only, reason recorded), `0` = `Disabled`. The legacy `$Script:DefenderEnabled` / `DefenderMpPreferenceBroken` guard became the provider's availability check (`Unsupported` when Defender preferences cannot be read). Because the tweak can also turn PUA protection off it is flagged `-ReducesProtection`, `-Risk High`, with the reduction spelled out in the impact text (default state is `Enabled`). Provider change: `Set-WtMpPreferenceRaw` / `Set-WtMpPreferenceState` in `src/WindowsTweaker/Private/Providers/Defender.ps1` had their `ValidateSet` widened to `'EnableControlledFolderAccess', 'PUAProtection', 'EnableNetworkProtection'` (additive only, done in agreement with the owner of the `Security` batch who needed `EnableNetworkProtection`). |
| UpdateMicrosoftProducts.ps1 | migrated | `Updates.MicrosoftProductUpdates` | `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings\AllowMUUpdateService` DWord `1` = `Enabled`; the legacy `Disable` branch *removed* the value (not `0`), which is faithfully kept as `RegistryRemove`. Because a removal-based state cannot be expressed by the declarative detector (an absent value is reported as `Unknown` there), this tweak is a scripted tweak whose read-only `Detect` uses `Get-WtRegistryState` and reports `Disabled` for "value absent" (with the Windows-default reason) and for any value other than `1`. Both states delete the machine policy value `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\AllowMUUpdateService`, declared as `-ManagedPolicy`. No "disable Windows Update" behaviour was invented. |
| WindowsLatestUpdate.ps1 | migrated | `Updates.LatestUpdatesAsSoonAsAvailable` | Opt-in for new non-security updates. Two defects in the legacy module were not copied: the `Disable` branch wrote to the misspelled key `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UXS\Settings` (should be `...\UX\Settings`), and the value name was misspelled `IsContinousInnovationOptedIn`. Both states now write the real value `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings\IsContinuousInnovationOptedIn` DWord 1/0 (name confirmed against the documented "Get the latest updates as soon as they're available" tweak), and both still delete the policy values `AllowOptionalContent` and `SetAllowOptionalContent` (legacy LGPO `DELETE`), declared as `-ManagedPolicy`. Default state `Disabled` (stay on the normal rollout). Nothing here disables Windows Update. |
| RestartDeviceAfterUpdate.ps1 | migrated | `Updates.ExpeditedRestart` | `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings\IsExpedited` DWord 1/0 - restart as soon as possible when an update needs a restart. Both states delete the organization active-hours policy values `SetActiveHours`, `ActiveHoursStart`, `ActiveHoursEnd` (legacy LGPO `DELETE`), declared as `-ManagedPolicy`. Default state `Disabled` (no surprise restarts). |
| RestartNotification.ps1 | migrated | `Updates.RestartNotifications` | `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings\RestartNotificationsAllowed2` DWord 1/0 (`Enabled` = the restart notification is shown). Both states delete the policy value `SetAutoRestartNotificationDisable` (legacy LGPO `DELETE`), declared as `-ManagedPolicy`. Default state `Enabled`. |
| DeliveryOptimization.ps1 | migrated | `Updates.DeliveryOptimization` | Kept as the single tweak for the duplicated pair. `HKU\S-1-5-20\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Settings\DownloadMode` DWord `0` = `Disabled` (HTTP only), `1` = `Enabled` (LAN peering); both states delete the policy value `DODownloadMode` (legacy LGPO `DELETE`), declared as `-ManagedPolicy`. Partially ported by design: the legacy `Disable` branch also ran `Delete-DeliveryOptimizationCache -Force`, which is *not* ported - there is no provider for that cmdlet and it deletes cached update payloads, so exposing it would need its own irreversible/data-deletion tweak (`-DataDeletion -Irreversible`) instead of hiding it inside a download-mode toggle. Reverting the download mode therefore does not restore deleted cache contents. |
| DelieryOptimization.ps1 | dropped | `Updates.DeliveryOptimization` | Byte-identical duplicate of `DeliveryOptimization.ps1` (verified with `diff`): both define `function DeliveryOptimization` with the same body. Collapsed into the one tweak above; keeping both would have produced a duplicate tweak id. |

## Security review of the ported behaviour

* No download-and-execute path exists in any of these nine modules, and none was
  added: no installer is fetched from the internet, no file is written to
  `System32`, and there is no `Invoke-Expression` / `Add-Type` of inline code.
* Nothing disables Defender, SmartScreen, UAC, CFA or security logging. The only
  protection-related tweak is `Privacy.PuaProtection`, which is flagged
  `-ReducesProtection` / `-Risk High` and is never applied automatically.
* Every state deletes the `HKLM\SOFTWARE\Policies\...` values that would otherwise
  override the preference, which is what the legacy LGPO `DELETE` lines did (LGPO is
  not bundled and must not be downloaded).
* All changes are made through the registry/Defender providers, so `-WhatIf` is
  honoured, the previous state is captured before every write and rollback restores
  the exact prior state (untouched values stay absent).
