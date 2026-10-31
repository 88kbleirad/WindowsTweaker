# Batch notes: System.G5

Legacy modules converted into `src/WindowsTweaker/Tweaks/System/System.G5.ps1`.
Legacy sources are read-only reference material (partially extracted from Sophia Script for
Windows, MIT, (c) 2023 farag2) and are deleted once every module is accounted for.
`reference/text.txt` was not read, executed or ported.

## Outcome per legacy module

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| AdminApprovalMode.ps1 | migrated (reduced) | System.UacPromptBehavior | Category `System` because the batch file lives in `Tweaks/System/` and the category must match the folder; the setting itself is a machine-wide entry under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`, the same key Windows uses for every UAC setting. Only the prompt level (`ConsentPromptBehaviorAdmin`) is ported: 5 = `Prompt` (Windows default), 0 = `NeverNotify` (`-ReducesProtection -Risk High`, never the default). The other eight values the module wrote are listed under "not ported" below, and UAC is never disabled. |
| LocalSecurityAuthority.ps1 | migrated | System.LsaProtection | Ports the two values the module wrote (`Lsa\RunAsPPL` and `Lsa\RunAsPPLBoot` = 2 = "enabled without a UEFI variable") plus the removal of the `RunAsPPL` policy value that would otherwise override them. `-MinBuild 22621`: the docs state value 2 is only enforced on Windows 11 22H2 and later. The firmware-virtualization probe is dropped because value 2 needs no hypervisor for LSA to run as PPL. The module's "Disable" path (delete both values) is the `Disabled` state, which lowers protection, so the tweak is `-ReducesProtection -Risk High` with `Enabled` as the default state. No protection packages are registered and no special privilege beyond an elevated registry write is needed, so nothing had to be marked "not ported". |
| WindowsManageDefaultPrinter.ps1 | migrated | System.DefaultPrinterManagement | `LegacyDefaultPrinterMode`: 0 = `Enabled` (Windows manages the default printer, the Windows default), 1 = `Disabled`. Full detection map, `HKCU` only, no elevation. |
| BSoDStopError.ps1 | migrated | System.BSoDDisplayParameters | `CrashControl\DisplayParameters`: 1 = `Enabled` (show bug check parameters), 0 = `Disabled`. Full detection map. |
| Win32LongPathLimit.ps1 | migrated | System.LongPathsEnabled | `FileSystem\LongPathsEnabled`. The legacy parameter names were inverted (its `-Disable` wrote 1), so the states describe the setting: `Enabled` = long paths allowed (1), `Disabled` = the 260-character limit applies (0). `-MinBuild 14393` because the value was introduced with Windows 10 1607. The legacy module also mis-declared its parameter attribute (`[Parametet]`), a syntax error that made the file unparseable; the behaviour is preserved without it. |
| Hiberation.ps1 | migrated | System.Hibernation | The legacy ran `POWERCFG /HIBERNATE OFF|ON`. The change now goes through `Invoke-WtProcess` (exit code checked) and the state is read from `HKLM\SYSTEM\CurrentControlSet\Control\Power\HibernateEnabled`, the value powercfg maintains. `-Rollback Partial`: `powercfg /hibernate off` deletes `hiberfil.sys` and disables Fast Startup, and the state store captures neither. |
| PowerPlan.ps1 | migrated | System.PowerPlan | `powercfg /setactive SCHEME_BALANCED|SCHEME_MIN`, plus the `ActivePowerScheme` policy removal the legacy module performed. Detection reads `HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\ActivePowerScheme`. `-Rollback Partial`: the policy value is captured, the previously active plan is not. Only the Balanced/High performance states the legacy module offered are modelled; a Power saver plan detects as `Unknown` with an explicit reason instead of being guessed. `Powercfg /setactive` is run for the selected state only, never for a plan the caller did not ask for. |
| StorageSense.ps1 | migrated | System.StorageSense | The three `StoragePolicy` values the module wrote (01 = Storage Sense, 04 = temporary files that apps are not using, 2048 = run cadence in days, 30 = monthly) in both states, plus the `AllowStorageSenseGlobal` policy removal in both states. Detection uses value 01. Nothing outside temporary files is scheduled: the recycle bin (08/256) and Downloads (32/512) entries are left alone. `-Privilege Admin -Scope UserAndMachine` because one operation removes a machine policy value. |
| ReservedStorage.ps1 | migrated | System.ReservedStorage | The legacy called the DISM cmdlet `Set-WindowsReservedStorageState`; DISM is now invoked through `Invoke-WtProcess` (`dism /Online /Set-ReservedStorageState /State:...`) so the exit code is checked. Detection reads `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager\ShippedWithReserves`. `-MinBuild 19041` (the DISM option exists from Windows 10 2004). `-Rollback Partial` because the store does not capture the DISM state. The legacy COM-exception handling is replaced by honest failure reporting: DISM refuses the change while reserved storage is in use and that refusal is returned as a failed operation. |
| NumLock.ps1 | migrated | System.NumLock | `HKU:\.DEFAULT\Control Panel\Keyboard\InitialKeyboardIndicators` as REG_SZ, exactly the two strings the module used (2147483650 = NumLock on, 2147483648 = NumLock off). |
| CapsLock.ps1 | migrated | System.CapsLock | The machine-wide `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Scancode Map` with the 20-byte map that maps scancode 0x3A to nothing (`Disabled`) and its removal (`Enabled`). Scripted because the "Enabled" state is the value being absent, which a declarative detection map cannot express; a different Scancode Map (for example a Ctrl/Caps Lock swap) detects as `Unknown` and is never overwritten. |

## Values the legacy modules wrote that are deliberately not ported

* **AdminApprovalMode.ps1**: `ConsentPromptBehaviorUser` 3, `EnableInstallerDetection` 1,
  `ValidateAdminCodeSignatures` 0, `EnableSecureUIAPaths` 1, `EnableLUA` 1,
  `PromptOnSecureDesktop` 1, `EnableVirtualization` 1, `EnableUIADesktopToggle` 1, and the
  LGPO `DELETE` lines for those names plus `FilterAdministratorToken`. They are the Windows
  defaults (writing them is a no-op on a stock machine), they are not part of the prompt
  behaviour, and `ValidateAdminCodeSignatures 0` plus deleting `FilterAdministratorToken`
  would weaken admin code-signature validation and the protected-admin token. In particular
  `EnableLUA` is not written at all, so the tweak can never disable UAC. The LGPO `DELETE`
  lines are redundant here: `Set-Policy -Scope Computer -Path SOFTWARE\Microsoft\Windows\
  CurrentVersion\Policies\System` resolves to the same key the module writes directly, so
  there is no second policy location that could override the prompt level.
* **LocalSecurityAuthority.ps1**: the `CIM_Processor.VirtualizationFirmwareEnabled` /
  `CIM_ComputerSystem.HypervisorPresent` probe (only relevant for the UEFI-locked value 1,
  which is not ported) and the "enable with UEFI lock" variant, because a UEFI-locked setting
  can only be undone from firmware and would break the rollback guarantee.
* **CapsLock.ps1**: `Remove-ItemProperty "HKCU:\Keyboard Layout" -Name Attributes`. The
  per-user Scancode Map is ignored from Windows 7 onwards and removing `Attributes` does not
  touch the machine-wide mapping, so the operation is noise; it is dropped instead of
  deleting a value whose meaning has nothing to do with this setting.
* **WindowsManageDefaultPrinter.ps1** and **StorageSense.ps1**: the LGPO `DELETE` lines whose
  path resolves to the same key/value the module already wrote directly (no separate policy
  copy exists for `LegacyDefaultPrinterMode`); for StorageSense the `DELETE` of
  `AllowStorageSenseGlobal` is kept because that policy does override the user setting.
* **PowerPlan.ps1**: the LGPO `DELETE` line is redundant with the `Remove-ItemProperty` on the
  same path; the registry removal is kept as an explicit operation.

## Conventions applied to this batch

* `DefaultState` is the state the tweak exists to provide, or the state Windows ships with
  when the tweak has no obvious direction: `Prompt` (UAC), `Enabled` (LSA, default printer
  management, blue screen parameters, long paths, hibernation, Storage Sense, reserved
  storage, NumLock, Caps Lock), `Balanced` (power plan). No default state lowers protection.
* Rollback classification: `Full` when every operation goes through a provider that captures
  the previous state (registry), `Partial` for the three tweaks that drive `powercfg`/`DISM`
  (`System.Hibernation`, `System.PowerPlan`, `System.ReservedStorage`), whose previous tool
  state is not captured by the state store.
* `-ReducesProtection -Risk High` is set on `System.UacPromptBehavior` (the `NeverNotify`
  state removes the elevation prompt) and on `System.LsaProtection` (the `Disabled` state
  turns LSA protection off).
* No tweak in this batch uses `Invoke-Expression`, downloads anything, writes to `System32`,
  or deletes user data.
