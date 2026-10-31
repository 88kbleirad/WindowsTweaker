# Migration notes - Privacy batch G2

Legacy modules converted into `src/WindowsTweaker/Tweaks/Privacy/Privacy.G2.ps1`
(category `Privacy`). Thirteen modules are accounted for below. The legacy files are
read-only reference material (partially extracted from Sophia Script for Windows,
MIT, (c) 2023 farag2) and are deleted at the end of the migration; nothing from
`reference/text.txt` was executed or ported.

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| DismissMSAccount.ps1 | migrated | Privacy.DismissMSAccount | `HKCU\Software\Microsoft\Windows Security Health\State\AccountProtection_MicrosoftAccount_Disconnected` DWord `1` = `Dismissed`, value removed = `Shown`. Two defects corrected: the legacy wrote to the misspelled key `Window Security Health` (the Windows Security app state key is `Windows Security Health`, as used by the app's own notification records and documented in Microsoft Q&A answers on the same value family), and the legacy guard that skipped the whole function when Defender was disabled or its preference store was broken was dropped - the value only records a dismissed recommendation and does not touch Defender, so a Defender state is not a prerequisite. |
| SigninInfo.ps1 | migrated | Privacy.SigninInfo | Scripted tweak (the only one in the batch): the per-account opt-out lives under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\UserARSO\<account SID>` and a declarative operation list cannot address a key whose name is the caller's SID. `Detect` is read-only and resolves the SID with `WindowsIdentity` (guarded, reports `Unsupported` when it cannot), `Apply` uses only `Set-WtRegistryValue` / `Remove-WtRegistryValue`. `Disabled` writes `OptOut = 1` for the current account, `Enabled` removes it; both states clear the machine-wide `DisableAutomaticRestartSignOn` policy (`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`, Microsoft: `1` = ARSO off), which is what the legacy LGPO `DELETE` line did and what would otherwise override the per-account value. The legacy's `New-Item` used the misspelled path `...\Winlogin\UserARSO\$SID` (writing to `Winlogon`), and the legacy guard skipped the whole function when Defender was disabled; the correct path is used and the guard dropped. As in the legacy, the SID is the account the tool itself runs as (the elevated account), so the tweak is meant to be run by the account it configures. |
| LanguageListAccess.ps1 | migrated | Privacy.LanguageListAccess | `HKCU\Control Panel\International\User Profile\HttpAcceptLanguageOptOut` DWord `1` = `Disabled` (websites may not read the language list), absent/`0` = `Enabled`. `Enabled` removes the value because that is the Windows default, as the legacy `-Enable` branch did. |
| WindowsWelcomeExperience.ps1 | migrated | Privacy.WindowsWelcomeExperience | `ContentDeliveryManager\SubscribedContent-310093Enabled` `1` = `Enabled`, `0` = `Disabled`. The legacy touched no policy, but a machine-wide `DisableWindowsConsumerFeatures` value forces this content off for every user, so the `Enabled` state removes it and the value is declared as `-ManagedPolicy` (the tweak is therefore `UserAndMachine` / `Admin`). |
| WindowsTips.ps1 | migrated | Privacy.WindowsTips | `ContentDeliveryManager\SubscribedContent-338389Enabled` `1` = `Enabled`, `0` = `Disabled`. `DisableSoftLanding` under `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent` is the policy that turns Windows tips off device-wide ("Do not show Windows tips", CloudContent.admx); the legacy cleared it in both branches, the port clears it in the only state it contradicts (`Enabled`) and declares it as `-ManagedPolicy`, which is why the tweak is `UserAndMachine` / `Admin`. |
| SettingsSuggestedContent.ps1 | migrated | Privacy.SettingsSuggestedContent | One tweak for the three values the Settings app reads as one suggestion block: `SubscribedContent-338393Enabled`, `SubscribedContent-353694Enabled`, `SubscribedContent-353696Enabled` (`1` = `Enabled`, `0` = `Disabled`). The legacy `-Show` branch wrote `SubscribedContetn-353696Enabled` (transposed `SubscribedContetn`), so that direction silently left the third value at `0`; the correct name is used in both states. The machine-wide `DisableWindowsConsumerFeatures` policy is handled like in the welcome-experience tweak. |
| WhatsNewInWindows.ps1 | migrated | Privacy.WhatsNewInWindows | `UserProfileEngagement\ScoobeSystemSettingEnabled` `1` = `Enabled` (the "Let's finish setting up your device" screens are shown), `0` = `Disabled`. The legacy key creation is implicit in the value write. No `-ManagedPolicy`: this per-user preference has no documented machine-wide policy value, and the legacy cleared none. |
| BingSearch.ps1 | migrated | Privacy.BingSearch | `HKCU\Software\Policies\Microsoft\Windows\Explorer\DisableSearchBoxSuggestions` DWord `1` = `Disabled` (no web suggestions in the search box), `0`/absent = `Enabled`. The setting *is* a user policy value, so `Disabled` writes it and `Enabled` removes it, exactly like the legacy `-Enable` branch. `Enabled` also removes the machine-scope copy of the same policy, because a machine value would keep web results off for every account; that machine value is `-ManagedPolicy` and makes the tweak `UserAndMachine` / `Admin`. The user-scope value is deliberately not declared as `-ManagedPolicy`, otherwise the tweak would report itself as organization-managed after every apply. |
| SearchHighlights.ps1 | migrated | Privacy.SearchHighlights | `HKCU\Software\Microsoft\Windows\CurrentVersion\SearchSettings\IsDynamicSearchBoxEnabled` `1` = `Enabled`, `0` = `Disabled`. `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search\EnableDynamicContentInWSB` is a directional policy (`0` = highlights off, `1` = highlights on, as used by the "for all users" registrations of the same setting), so it is removed in both states and declared as `-ManagedPolicy` (`UserAndMachine` / `Admin`). Two legacy behaviours were **not** copied: the `Hide` branch refused to run when `HKCU\...\Search\BingSearchEnabled` was `0` or the `DisableSearchBoxSuggestions` policy was `1` (a declarative tweak cannot skip conditionally, and the value written here still describes the user's choice), and the `Show` branch removed `BingSearchEnabled` plus `DisableSearchBoxSuggestions` to make highlights actually appear - those belong to the `Privacy.BingSearch` setting, so re-enabling web results is left to that tweak instead of being an undeclared side effect here. |
| StartRecommendedSection.ps1 | migrated | Privacy.StartRecommendedSection | `HKCU\Software\Policies\Microsoft\Windows\Explorer\HideRecommendedSection` DWord `1` = `Hidden`, `0`/absent = `Shown`; Windows 11 only. Both states clear the machine-wide policy and the MDM values the legacy cleared (`PolicyManager\current\device\Education\IsEducationEnvironment`, `PolicyManager\current\device\Start\HideRecommendedSection`), and `Shown` additionally removes the machine policy value - that is why the tweak is `UserAndMachine` / `Admin` even though the value it detects is per user. Legacy defects not copied: the machine value name `HideRecommendSection` (missing `ed`) in the malformed path `...\Windows\Explorer-Name ...`, and the `-None` switch used instead of `-Name` together with a comma-joined path in the `-Show` branch. |
| StartRecommendationsTips.ps1 | migrated | Privacy.StartRecommendationsTips | `Explorer\Advanced\Start_IrisRecommendations` `0` = `Disabled`, absent/`1` = `Enabled`. `Enabled` removes the value (the legacy `-Show` behaviour and the Windows default). |
| StartAccountNotifications.ps1 | migrated | Privacy.StartAccountNotifications | `Explorer\Advanced\Start_AccountNotifications` `0` = `Disabled`, absent/`1` = `Enabled`, same shape as the recommendations tweak. |
| RecommendTroubleshooting.ps1 | migrated | Privacy.RecommendTroubleshooting | One tweak for the recommended-troubleshooting preference and the components it needs. States `Default` (`HKLM\SOFTWARE\Microsoft\WindowsMitigation\UserPreference` = `2`, "ask me before running a troubleshooter") and `Automatically` (`3`, "run automatically, then notify me"), matching the legacy parameter sets. Both states repeat the whole restoration list, because a state must be complete on its own: remove the `AllowTelemetry` policy in `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection`, remove `MaxTelemetryAllowed` under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection`, remove `HKCU\...\Diagnostics\DiagTrack\ShowedToastAtLevel`, remove `HKCU\...\Windows Error Reporting\Disabled`, enable the `QueueReporting` scheduled task and set `WerSvc` to `Manual` and start it. `-Risk Medium` with an explicit impact text, because this undoes diagnostic-data and error-reporting restrictions (e.g. `Privacy.DiagnosticDataLevel`, `Privacy.ErrorReporting`); `-Rollback Full`, since every operation goes through a provider. The legacy's own `Test-Path`/`New-Item` used the misspelled `HKLM:\SOFTWARE\Microsoft\Windows\WindowsMitigation` (missing backslash) in one branch and wrote to `...\Windows\Mitigation` in the other; the key the feature actually reads is the single key `WindowsMitigation`, which is also where the upstream Sophia Script for Windows reads and writes `UserPreference`. The legacy `Get-ScheduledTask ... | Enable-ScheduledTask` and `Get-Service ... | Set-Service` calls became `ScheduledTask` and `Service` operations so that state capture, dry run and rollback work. |

No module from this batch was dropped, and the batch contains no duplicate of a module
already converted elsewhere in the tree.

Three definitions of this batch - `Privacy.DismissMSAccount`, `Privacy.LanguageListAccess` and
`Privacy.WindowsTips` - now live in the declarative catalog (`Data/Catalog/builtin.json`) instead
of `Privacy.G2.ps1`. The document encodes the same detection maps, operation lists, managed-policy
values, scope, privilege, restart, rollback, risk and capability requirements that the PowerShell
definitions had, and it is loaded through the same `New-WtRegistryTweak` constructor, so nothing
about how the three settings are detected, previewed, applied, verified or restored changed. They
were chosen because they are simple, cover a user-scope setting with a removal state, a
user-and-machine setting with a managed policy, and a detection map with a value on each side, and
because no test refers to them by name. Every other definition of this batch stays in PowerShell,
including the scripted `Privacy.SigninInfo`, whose per-account key carries the caller's SID and
therefore cannot be expressed as a declarative operation list. `tests/Catalog.Tests.ps1` asserts
the detection map, the operations and the canonical target identities of the migrated definitions;
`docs/FEATURE-INVENTORY.md`, which is generated from the live catalog, is unchanged by the move.

## Framework notes and deviations

* **Machine-wide policy values and privilege.** Six tweaks write only the values the
  legacy wrote, but a state that asks for the content/suggestion/search behaviour
  *on* has to clear the machine-wide policy that forces it off, otherwise the change
  would silently have no effect on a managed device. Those tweaks
  (`Privacy.WindowsWelcomeExperience`, `Privacy.WindowsTips`,
  `Privacy.SettingsSuggestedContent`, `Privacy.SearchHighlights`,
  `Privacy.BingSearch`, `Privacy.StartRecommendedSection`) are declared
  `Scope UserAndMachine` / `Privilege Admin` and the machine value is declared as
  `-ManagedPolicy`, so `Get-WtTweakState` reports it as organization-managed and
  `Invoke-WtTweak` warns before changing anything. The three CloudContent/Windows
  Search policies were left in place for the "off" direction where they do not
  contradict the written value; they are removed only where they would override it.
* **Removal-based states.** Where the legacy reached a state by deleting the value
  (the Windows default for that direction), the port removes the value as well, and
  the detection map still lists the value Windows writes for that direction, so a
  value that some other tool or the Windows UI set to `0` is reported correctly.
  A value that is simply absent is reported as `Unknown` with the reason
  "Value not present: ...", never as a guess.
* **Typos corrected (all listed above).** `Window Security Health` ->
  `Windows Security Health`; `Winlogin` -> `Winlogon`; `SubscribedContetn-353696Enabled`
  -> `SubscribedContent-353696Enabled`; `Windows\Mitigation` / `WindowsMitigation`
  resolution for the mitigation key; `HideRecommendSection` -> `HideRecommendedSection`.
  Every correction is a name or path Windows actually reads; none of them changes
  which setting is being toggled.
* **Conditional guards.** The legacy functions skipped themselves in a few situations
  (Defender disabled or its preference store broken for `DismissMSAccount` and
  `SigninInfo`; a custom Start menu process for the Start tweaks; "web results already
  disabled" for `SearchHighlights`; `WerSvc` missing for `RecommendTroubleshooting`).
  A declarative tweak cannot skip conditionally, so those guards are not reproduced as
  code. The custom-Start-menu and Defender guards are not needed for the values
  written; the `SearchHighlights` guard is described in that row; a missing `WerSvc`
  makes the corresponding `Service` operation report `unsupported`, which the aggregate
  status surfaces instead of claiming success.
* **No protection-reducing tweak was created.** Nothing in this batch touches
  Defender, SmartScreen, UAC, Controlled Folder Access or security logging.
  `Privacy.RecommendTroubleshooting` increases what Windows reports (diagnostic data,
  Windows Error Reporting) and says so in its impact text, with `-Risk Medium`.
