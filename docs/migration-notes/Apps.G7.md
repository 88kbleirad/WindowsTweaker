# Migration notes - batch `Apps.G7`

Legacy modules converted: the batch file `src/WindowsTweaker/Tweaks/Apps/Apps.G7.ps1`
(category `Apps`). Fourteen modules are accounted for below; the context-menu entries
were filed under `Apps` because the batch file lives in the `Apps` folder and
`Test-Catalog.ps1` requires the tweak category to match the folder.

Reference material: `modules/*.ps1` (read-only during the migration, partially
extracted from Sophia Script for Windows, MIT, (c) 2023 farag2).
`reference/*.txt` was not executed and nothing was ported from it.

## Modules

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| DefaultTerminalApp.ps1 | migrated | `Apps.DefaultTerminalApp` | User preference for the console host. States `WindowsTerminal` / `ConsoleHost`, detected through `HKCU\Console\%%Startup\DelegationConsole`. The legacy discovered the Windows Terminal packaged-COM class ids at runtime by walking `HKLM\SOFTWARE\Classes\PackagedCom\Package\<FullName>\Class`; those ids are stable, so the port writes them directly (`{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}` for the console, `{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}` for the terminal), `ConsoleHost` writes `{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}` into both values exactly like the legacy branch. The legacy "Windows Terminal 1.11 or newer" guard cannot be expressed declaratively; the impact text states that the Terminal package must be installed. `Restart None` (new console windows pick the host up). |
| UseStoreOpenWith.ps1 | migrated | `Apps.UseStoreOpenWith` | `HKCU\Software\Policies\Microsoft\Windows\Explorer\NoUseStoreOpenWith`: `1` = `Disabled` (the Store link is hidden), `0` = `Enabled`. The legacy removed the HKCU value for `-Show`; the port writes `0` explicitly so that both states are detectable, and removes the machine policy value `HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer\NoUseStoreOpenWith` in both states (legacy LGPO `DELETE`), which is why the tweak is `UserAndMachine` / `Admin`. The machine value is declared as `-ManagedPolicy`. Default state `Disabled`. |
| AutoPlay.ps1 | migrated | `Apps.AutoPlay` | `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers\DisableAutoPlay` DWord `1` = `Disabled`, `0` = `Enabled`. Both states clear the legacy autorun policy `NoDriveTypeAutoRun` under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer` and `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer` (legacy LGPO `DELETE` on both scopes), which is why the tweak is `UserAndMachine` / `Admin`; the HKLM value is `-ManagedPolicy`. Default state `Disabled`. `Restart Explorer`. |
| F1HelpPage.ps1 | migrated | `Apps.F1HelpPage` | `Disabled` writes an empty unnamed value into `HKCU\Software\Classes\Typelib\{8cec5860-07a1-11d9-b15e-000d56bfe6ee}\1.0\0\{win32,win64}` (the Winhelponline type-library override that stops F1 from opening Windows Help and Support); `Enabled` deletes the whole `{8cec5860-...}` key recursively. The legacy wrote the `win64` platform only; `win32` is written as well, because the original trick registers both and a 32-bit help host would otherwise still open the page. The `HKLM:\...\Typelib` machine registration is never touched. `-Rollback Partial` because `Enabled` deletes a registry subtree. |
| PreventEdgeShortcutCreation.ps1 | migrated | `Apps.PreventEdgeShortcutCreation` | One tweak for the four Edge Update channel policies. `Disabled` sets `CreateDesktopShortcut{guid}` DWord `0` (Microsoft: `0` = the desktop shortcut is not created) for the Stable/Beta/Dev/Canary channel guids; `Enabled` removes all four, which restores Edge's default behaviour. Three defects in the legacy module were **not** copied: the Canary value name `CreateDesktopShortcut{65C35B14-6C1D-4122-AC46-7148C9D6497}` (11 characters in the last group - malformed), the outdated Stable guids `...-4CBD-...` and `...-7148CC9D6497` written by the `Set-Policy` lines with the unrelated value `3`, and the `Beta`/`Dev`/`Canary` branches that all set the Stable guid. All four value names and both values (`0`/`1`) were taken from the Microsoft Edge Update policy documentation. The legacy `Get-Package` "Edge is installed" guard is not expressible declaratively; the impact text states the policy only affects a later install or update. |
| CompressedFolderNewContext.ps1 | migrated | `Apps.CompressedFolderNewContext` | `Shown` recreates `HKCR\.zip\CompressedFolder\ShellNew` with `Data` (REG_BINARY, the 22-byte empty ZIP end-of-central-directory record) and `ItemName` (REG_EXPAND_SZ `@%SystemRoot%\System32\zipfldr.dll,-10194`); `Hidden` deletes that key. The legacy `-Show` branch created the misspelled key `HKCR\.zip\CompressFolder\ShellNew` in its `Test-Path`/`New-Item` path while writing the values into `CompressedFolder`; the port uses `CompressedFolder` everywhere, and `ItemName` uses the value Windows registers (no space after the comma, unlike the legacy string). `-Rollback Partial` (recursive key removal). |
| MSIExtractContext.ps1 | migrated | `Apps.MsiExtractContext` | `Shown` writes `HKCR\Msi.Package\shell\Extract\Command` (unnamed value = `msiexec.exe /a "%1" /qb TARGETDIR="%1 extracted"`), plus `MUIVerb` and `Icon` on the verb key; `Hidden` deletes `HKCR\Msi.Package\shell\Extract` recursively. The legacy `Icon` line was missing its dash (`-Name Icon PropertyType String`), so that value was never written and the branch raised a parameter binding error; the port writes `shell32.dll,-16817` as the legacy intended. `-Rollback Partial` (recursive key removal). |
| EditWithClipchampContext.ps1 | migrated | `Apps.EditWithClipchampContext` | `Hidden` adds the Clipchamp shell-extension CLSID to the per-user block list `HKCU\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked` and removes the machine-wide block value; `Shown` removes both. The legacy write used the mis-typed CLSID `{8AB635F8-9A67-4698-AB99-784AD929F384}` while its own machine-wide removal used `...F3B4`; `...F3B4` is the real Clipchamp shell-extension CLSID (confirmed against the gHacks removal instructions and the Microsoft/community context-menu documentation), so the port uses it in both scopes. |
| EditWithPaintContext.ps1 | migrated | `Apps.EditWithPaintContext` | Same block-list mechanism for `{2430F218-B743-4FD6-97BF-5C76541B4AE9}`. Two legacy defects were not copied: the write targeted the misspelled key `...\CurrentVersion\Shell Exceptions\Blocked` (should be `Shell Extensions\Blocked`) and used the mis-typed CLSID `...-4DF6-...`; the port uses the correct key and the CLSID confirmed in the Windows 11 "Edit with Paint" registry documentation. The legacy `Get-AppxPackage` presence guard became a statement in the impact text (the entry only exists while the app is installed). |
| EditWithPhotosContext.ps1 | migrated | `Apps.EditWithPhotosContext` | Same block-list mechanism for `{BFE0E2A4-C70C-4AD7-AC3D-10D1ECEBB5B4}`. The legacy machine-wide removal used the mis-typed `...-10D1ECEBB584`; the CLSID used in the per-user write (`...BB5B4`) is the correct one and is used in both scopes. |
| PrintCMDContext.ps1 | migrated | `Apps.PrintCommandContext` | `Hidden` writes the `ProgrammaticAccessOnly` value (REG_SZ, empty) under `HKCR\batfile\shell\print` and `HKCR\cmdfile\shell\print`; `Shown` removes both values. The legacy `-Hide` branch marked only `batfile` while its `-Show` branch cleaned `batfile` and `cmdfile`, which made the two states inconsistent; both keys are handled now. The Print verb stays registered for programmatic use. |
| MultipleInvokeContext.ps1 | migrated | `Apps.MultipleInvokeContext` | States `Raised` (`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MultipleInvokePromptMinimum` DWord `300`) and `Default` (value removed, Windows' built-in limit of 15 files). Two legacy typos were corrected to the names Microsoft documents: the key `CurrentVerison` -> `CurrentVersion`, and the value `MultipleInvokePromptMinimum` (the legacy wrote `MultipleInvokePromptMinium`). The documented default (`15`, decimal) is part of the detection map, so an explicitly configured `15` is also reported as `Default`; the change takes effect after Explorer is restarted or the user signs out (`Restart Explorer`). Default state `Default` (no change from stock). |
| CABInstallContext.ps1 | migrated | `Apps.CabInstallContext` | `Shown` writes `HKCR\CABFolder\Shell\runas` (`MUIVerb` `@shell32.dll,-10210`, `HasLUAShield` empty) and its `Command` unnamed value; `Hidden` deletes the `runas` key recursively. Two legacy defects were corrected: the DISM switch `/App-Package` is not a DISM option (the valid one for a Windows package is `/Add-Package`), and the `New-Item` call in the branch was truncated (`New-Item -Path Registry::HKEY_CLASSES_ROOT\CABFolde`) and would have errored. The legacy guard that looked up `HKCU\...\FileExts\.cab\UserChoice\ProgId = 'CABFolder'` cannot be expressed declaratively; the impact text states that the entry is only visible while the built-in `CABFolder` association owns `.cab`. `-Rollback Partial` (recursive key removal). |
| WindowsSandbox.ps1 | migrated | `Apps.WindowsSandbox` | Scripted tweak that runs the signed in-box `dism.exe` through `Invoke-WtProcess`: `/Online /Enable-Feature /FeatureName:Containers-DisposableClientVM /All /NoRestart` and `/Online /Disable-Feature /FeatureName:Containers-DisposableClientVM /NoRestart`. `-Privilege Admin`, `-Restart Reboot`, `-Rollback Partial` (an optional-feature change is not captured by the state store, so the documented way back is to apply the opposite state), impact text states that a reboot is required. The legacy module's two `Enable-WindowsOptionalFeature` call sites were broken (a missing line continuation) and one of them used the misspelled feature name `Container-DisposableClientVM`; the correct feature name `Containers-DisposableClientVM` is used. The legacy `EditionID`/`VirtualizationFirmwareEnabled` pre-checks became the impact text (Pro/Enterprise/Education and a hardware-virtualization-capable CPU) plus the feature-existence check in `Detect`. The feature state is read before DISM runs, so an already satisfied state reports `unchanged` instead of starting DISM, and `-WhatIf` never reaches DISM. |

No module from this batch was dropped, and no duplicate existed in it.

## Framework notes and deviations

* **Unnamed registry values.** `Apps.F1HelpPage`, `Apps.MsiExtractContext` and
  `Apps.CabInstallContext` write the *unnamed* value of a key (that is where the shell
  reads a verb's command line, and where the help-page override stores its empty
  string). The operations use `Name = '(default)'`, which the registry provider
  normalises to the unnamed value for reads, writes, verification, state capture and
  rollback. The write path for the unnamed value uses the .NET registry API, so it is
  Windows-only; on other platforms it fails loudly instead of reporting success. This
  is a Windows-only integration check, not something the Linux test run can execute
  (the registry provider is reported as `Unsupported` there).
* **Detection of a removed state.** The declarative detector reports `Unknown` (with a
  reason) when the tracked value or key is absent and no map entry matches. This is the
  existing catalog convention (`Privacy.FeedbackFrequency` works the same way): for
  `Apps.MultipleInvokeContext`, `Apps.F1HelpPage`, `Apps.MsiExtractContext`,
  `Apps.CabInstallContext` and the three `EditWith*` tweaks the "removed" or "absent"
  variant is reported as `Unknown` when it is not present, and the applied state is
  always captured for rollback.
* **`HKCR:` paths.** The shell-registration tweaks use `HKCR:` paths like the legacy
  modules did. On Windows those resolve through the merged class view and writing or
  deleting there needs elevation (the changes land in
  `HKLM\SOFTWARE\Classes`), which is why those tweaks declare `-Privilege Admin`
  (and `Apps.UseStoreOpenWith`, `Apps.AutoPlay` and the `EditWith*` tweaks because they
  also remove a machine-wide value).
* **Shell `Restart` metadata.** The context-menu and block-list tweaks report
  `Restart Explorer`: shell registrations are read by the running Explorer, so a
  restart of Explorer (or a sign-out) is the way to make the change visible if it is
  not immediate. No reboot is required for any of them.
* **Policy values.** Where the legacy used a policy transcript, the equivalent
  registry value is written or removed directly; nothing downloads a policy tool.
  `Apps.UseStoreOpenWith` and `Apps.AutoPlay` declare the machine-wide policy value they
  clear as `-ManagedPolicy`, and `Apps.PreventEdgeShortcutCreation` removes the Edge
  Update policy values it owns.

## Security review of the ported behaviour

* No download-and-execute path was added: the only process ever started is the in-box
  signed `dism.exe` that `Apps.WindowsSandbox` invokes through `Invoke-WtProcess`, and
  that call is skipped entirely in a dry run.
* Nothing weakens Defender, SmartScreen, UAC, Controlled Folder Access or security
  logging. No tweak removes user data and none is flagged `-Irreversible` or
  `-DataDeletion`; every state that deletes a registry key deletes exactly one known
  shell-registration key, and its subtree is captured before the deletion.
* All changes go through the registry or process providers, so `-WhatIf` is honoured,
  the previous value/kind/existence is captured before every write and rollback
  restores exactly that state (values that did not exist stay absent).

## Validation

Run from the repository root (results reported in the batch report):

```
~/opt/pwsh/pwsh -NoProfile -File tools/Parse-All.ps1
~/opt/pwsh/pwsh -NoProfile -File tools/Test-Catalog.ps1
~/opt/pwsh/pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests/Engine.Tests.ps1 -Output None"
```
