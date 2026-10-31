# Security batch G4 - migration notes

Tweaks: `src/WindowsTweaker/Tweaks/Security/Security.G4.ps1`
Legacy modules: `modules/<Name>.ps1` (read-only reference; not modified).
Contract: `docs/MIGRATION-SPEC.md`.

## Outcome per legacy module

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| AppsSmartScreen.ps1 | migrated | Security.SmartScreenApplicationsMachine | Legacy wrote the machine-wide value `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SmartScreenEnabled` = `Off`/`Warn`; both states ported, `Off` is `-Risk High` + `-ReducesProtection`. |
| DismissSmartScreenFilter.ps1 | migrated | Security.DismissSmartScreenFilter | The legacy one-way write of `AppAndBrowser_EdgeSmartScreenOff = 0` is the `Disabled` state; the new `Enabled` state removes the record again so the change is reversible. |
| DefenderSandbox.ps1 | migrated | Security.DefenderSandbox | `setx.exe /M MP_FORCE_USE_SANDBOX` replaced by the registry value setx itself persists (`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`), so state capture, verification and rollback work. Defender is never disabled. |
| NetworkProtection.ps1 | migrated | Security.NetworkProtection | `Set-MpPreference -EnableNetworkProtection` goes through the Defender provider; the ADMX policy value is declared with `-ManagedPolicy`. Defender is never disabled. |
| SaveZoneInformation.ps1 | migrated | Security.SaveZoneInformation | `Set-Policy`/LGPO `DELETE` lines became the equivalent `RegistryRemove` of the machine policy value; the per-user value is `1` when zone information is dropped and `0` when it is preserved. |
| PowerShellModulesLogging.ps1 | migrated | Security.PowerShellModuleLogging | `EnableModuleLogging` + the `ModuleNames\* = *` rule; logging is only ever enabled by this tool. |
| PowerShellScriptsLogging.ps1 | already covered | Security.PowerShellScriptBlockLogging (in `Tweaks/Security/Security.ps1`) | The setting is the same policy value (`HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging\EnableScriptBlockLogging`), already in the catalog with both states and `-Risk Low`. Redefining it here would create a second tweak for one user-visible setting, so this batch does not duplicate it. |
| EventViewerCustomView.ps1 | migrated (partial) | Security.ProcessCreationCommandLine | Only the registry value is ported; the auditpol step and the Event Viewer XML view are not (reasons below). No scheduled task is created by this module. |
| WindowsScriptHost.ps1 | migrated | Security.WindowsScriptHost | `HKCU\Software\Microsoft\Windows Script Host\Settings\Enabled` = `0` blocks WSH for the current user, `1` allows it. The legacy scheduled-task pre-check is inert and was not reproduced. |
| Logging.ps1 | dropped | - | Broken duplicate of the framework logging; see below. |

Not a single module in this batch disables Microsoft Defender itself, and none of the
tweaks is applied at startup or by a preset.

## Details and decisions

### AppsSmartScreen.ps1
Legacy `-Disable` wrote `Off`, `-Enable` wrote `Warn`, both to the **machine** hive.
Ported as a declarative tweak with the same two states (plus `Block` accepted by
detection because Explorer treats it as "on"). The per-user value of the same setting
is a separate Net property of Explorer and is already covered by
`Security.SmartScreenApplications` in `Security.ps1`; that entry writes
`HKCU\...\Explorer\SmartScreenEnabled`, this one writes the machine value the legacy
module actually changed, so the two ids are not duplicates of each other.
`EnableSmartScreen` under `HKLM\SOFTWARE\Policies\Microsoft\Windows\System` is declared
with `-ManagedPolicy` and deliberately **not** deleted: an organization policy can
request `Block`, which is stronger than the `Warn` this tweak writes, so removing the
policy would be able to reduce protection.

### DismissSmartScreenFilter.ps1
Legacy only had one direction: write `0` into
`HKCU\Software\Microsoft\Windows Security Health\State\AppAndBrowser_EdgeSmartScreenOff`,
which makes Windows Security report SmartScreen as on and therefore suppresses the
"SmartScreen is turned off" warning, without touching SmartScreen itself. That is a
protection-reducing action (a really disabled filter stops being reported), so the
tweak carries `-ReducesProtection` and `-Risk High`, and its `Disabled` state is that
write. Because the protective state has no value to detect (absent = not suppressed),
the tweak is scripted: `-Detect` uses `Get-WtRegistryState` and returns `Enabled` for an
absent or non-zero record, `Disabled` for `0`; `-Apply` uses `Set-WtRegistryValue` /
`Remove-WtRegistryValue`. `DefaultState` is the protective `Enabled`.
The legacy `if Defender broken / disabled then skip` guard is not ported: it silently
skipped the whole module, which is exactly the honesty problem the spec forbids.

### DefenderSandbox.ps1
The legacy module ran `setx.exe /M MP_FORCE_USE_SANDBOX <0|1>`. Running an external
binary would give no state capture and no rollback, so the tweak writes the value setx
persists (REG_SZ in `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`)
through the registry provider instead. Values and meaning follow Microsoft's
"Run Microsoft Defender Antivirus in a sandbox environment": `1` = content scanning in
the low-privilege `MsMpEngCP.exe` sandbox, `0` = in-process fallback inside the
privileged `MsMpEng.exe`. Only a restart makes Defender read the variable, hence
`-Restart Reboot`. Turning the sandbox off lowers Defender's isolation, so the tweak is
`-ReducesProtection` + `-Risk High`; Defender itself, its real-time protection and its
other settings are untouched, and no `Set-MpPreference`/policy write happens here.
No `-ManagedPolicy` entry is declared because no documented ADMX or CSP policy governs
`MP_FORCE_USE_SANDBOX` - it is only a machine environment variable.

### NetworkProtection.ps1
Ported through the Defender provider (`Get-WtMpPreferenceState` /
`Set-WtMpPreferenceState -Name EnableNetworkProtection`), which is the documented
equivalent of the legacy `Set-MpPreference -EnableNetworkProtection Enabled|Disabled`;
the previous preference value is captured before the write, so rollback restores it
exactly. `Set-WtMpPreferenceState` originally accepted only `EnableControlledFolderAccess`;
agent `MigratePrivacyApps` extended the `ValidateSet` additively to
`'EnableControlledFolderAccess', 'PUAProtection', 'EnableNetworkProtection'`
(`src/WindowsTweaker/Private/Providers/Defender.ps1`, lines 41 and 99) - no other change
was made to that shared file, and nothing in this batch calls `Set-MpPreference`
directly.
Detection maps `0` -> `Disabled`, `1` -> `Enabled` (block) and `2` -> `Enabled` (audit
mode, traffic is still inspected, reason reported). Only the two modes the legacy module
exposed are written. Network protection off is protection-reducing, so the tweak is
`-ReducesProtection` + `-Risk High`, and the ADMX value
`HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\Network Protection\EnableNetworkProtection`
is declared with `-ManagedPolicy` (it is a policy an organization can push, and the tool
reports it instead of overwriting it).

### SaveZoneInformation.ps1
The legacy module removed the machine policy value, ran `Set-Policy ... DELETE` for it,
and then wrote/removed the per-user value. The LGPO calls are replaced by the equivalent
registry operations, which is what the spec requires because LGPO is not bundled.
* `Enabled` (preserve the zone identifier - the protective, default state):
  `RegistryRemove` of `HKLM\...\Policies\Attachments\SaveZoneInformation` (it would
  otherwise override the user value) plus `RegistrySet` of
  `HKCU\...\Policies\Attachments\SaveZoneInformation = 0`.
  The legacy `Enable` branch deleted the per-user value instead; `0` means "policy not
  enforced", the same outcome, and it keeps detection deterministic.
* `Disabled`: the same `RegistryRemove` plus `RegistrySet` = `1`.
Dropping the zone identifier removes the Mark-of-the-Web that SmartScreen, Protected
View and Office macro warnings rely on, so the tweak is `-ReducesProtection` +
`-Risk High`. Both states remove the machine policy value, so the machine value is
declared with `-ManagedPolicy`. The legacy `New-Item -Path ...\CurrnetVersion\...` typo
only ever ran when the key was missing; the port creates the per-user key through
`Set-WtRegistryValue` and never writes the misspelled path.

### PowerShellModulesLogging.ps1
Ported declaratively. `Enabled` writes `EnableModuleLogging = 1` and the catch-all rule
`ModuleNames\* = *`; `Disabled` writes `EnableModuleLogging = 0` and removes the rule.
Detection uses `EnableModuleLogging` (`1`/`0`), so `Disabled` is written as `0` instead
of deleted the way the legacy module did it. The legacy guard tested
`...\ModuleLogging\ModuleName` while creating `...\ModuleLogging\ModuleNames`, so it
never had any effect; the ported version verifies both values through the provider and
reports failures instead of silently skipping. Logging is only ever enabled by this
tweak (`-Risk Low`).

### PowerShellScriptsLogging.ps1 - already covered, no new tweak on purpose
The module sets exactly `HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging\EnableScriptBlockLogging`,
which `Security.PowerShellScriptBlockLogging` in `Tweaks/Security/Security.ps1` already
defines with both states (`1`/`0`) and `-Risk Low`. One user-visible setting must not
have two ids, so this batch adds nothing for it. The legacy `Disable` branch deleted the
value while the existing catalog entry writes `0`; the observable result (script block
logging off) is the same.

### EventViewerCustomView.ps1 - registry part only
The module did three things:
1. `auditpol /set /subcategory:"{0CCE922B-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable`
   -> **not ported.** `auditpol.exe` is an external binary and audit policy is not
   registered with any provider, so the previous audit configuration could not be
   captured and rollback could not restore it (the tweak would have to claim
   `Partial`/`None` rollback and would guess the old state). Rule 5 of the spec: record
   it instead of porting it half-honestly.
2. `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit\ProcessCreationIncludeCmdLine_Enabled = 1`
   -> **ported** as `Security.ProcessCreationCommandLine` (`1`/`0`, `-Risk Low`).
3. Writing `%ProgramData%\Microsoft\Event Viewer\Views\ProcessCreation.xml`
   -> **not ported.** No provider can create an arbitrary file, and a dry run must not
   write one; inventing a file-write path would bypass state capture and rollback.
   Consequence: the custom Event Viewer view is not created and the XML written by the
   legacy script (if any) is left untouched.
No scheduled task is involved in this module, so no `ScheduledTask` operation was needed.
The impact text of the ported tweak states that Windows only records event 4688 at all
when process creation auditing (auditpol) is enabled, which this tool does not change.

### WindowsScriptHost.ps1
`Disabled` writes `HKCU\Software\Microsoft\Windows Script Host\Settings\Enabled = 0`
(WSH blocked for the current user, which removes a classic malware execution path),
`Enabled` writes `1` instead of deleting the value as the legacy `Enable` branch did, so
detection is deterministic. `DefaultState` is `Disabled`, the hardening direction the
module exists for, and `-Risk Medium` because scripts that legitimately use
`.vbs`/`.js` stop working. The machine-wide value
(`HKLM\SOFTWARE\Microsoft\Windows Script Host\Settings\Enabled`) is declared with
`-ManagedPolicy`; only the per-user value is written.
The legacy scheduled-task pre-check (`SoftwareDistribution`, `Temp`, `Window Cleanup`,
`Window Cleanup Notification`) was dead code: the `break` only left `ForEach-Object` and
execution continued into the registry write, so no scheduled task was ever disabled and
none is touched here.

### Logging.ps1 - dropped
The module is a duplicate of the framework's own logging and is itself broken:

```powershell
$TranscriptFilename = "Log-$((Get-Date).ToString("dd.MM.yyyy-HH-MM))"
Start-Transcript -Path $PSScriptRoot\..\$TranscriptFilename.txt -Force
```

The string on line 3 is unterminated (`tools/Parse-All.ps1` reports
`MissingEndOfString` for it, one of the 39 legacy parse errors), the format string is
malformed, and the transcript would be written next to the legacy module tree instead of
into the tool's log location. The framework already owns logging: `Initialize-WtLogging`
/ `Write-WtLog` / `Get-WtLogPath` in `src/WindowsTweaker/Private/Logging.ps1` write
structured records to `<data root>\logs\wt-<yyyyMMdd>.jsonl` and are used by every
provider. Nothing was ported, and `Start-Transcript` is not used anywhere in this tool.

## Validation (run from the repository root)

```
~/opt/pwsh/pwsh -NoProfile -File tools/Parse-All.ps1
~/opt/pwsh/pwsh -NoProfile -File tools/Test-Catalog.ps1
~/opt/pwsh/pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests/Engine.Tests.ps1 -Output None"
```

Results (observed at the time of writing; the catalog keeps growing as other batches land):

* `Parse-All.ps1` -> `Files parsed : 166`, `Parse errors : 39`. Every one of them is
  inside the unparseable legacy `modules/*.ps1` tree that is deleted at the end of the
  migration - checked file by file: 0 parse errors outside `modules/` (so `src/`,
  `tools/` and `tests/` are clean, and `Security.G4.ps1` in particular parses with 0
  errors). A parse error anywhere outside `modules/` would also stop the module from
  importing, so this is the check that matters.
* `Test-Catalog.ps1` -> `Tweaks in catalog : 99`, `Catalog invariants: OK` (the
  protection-reducing check passes: every `-ReducesProtection` tweak in this batch is
  `-Risk High`).
* `Invoke-Pester -Path tests/Engine.Tests.ps1` -> `Tests Passed: 18, Failed: 0,
  Skipped: 0, Result: Passed`.

Import is clean as well: `Import-Module src/WindowsTweaker/WindowsTweaker.psd1` succeeds
and `Get-WtTweak -Category Security` lists all 11 Security tweaks (3 from
`Security.ps1`, 8 from this batch). Detection on Linux reports `Unsupported` with the
reason (`Unsupported operating system for this tweak: ...`, `Required cmdlet not found:
Get-MpPreference`, ...) as expected for Windows-only providers.

Apply/detect/rollback of all 8 tweaks was additionally exercised in a throwaway Pester
harness that reuses the same in-memory provider doubles as `tests/Engine.Tests.ps1`
(mock `Get-WtEnvironmentInternal` for Windows 11 + admin, mock registry read/write and
the two Defender preference seams). Every tweak applied, was detected back as its new
state, rolled back to the captured previous state, reported `Unknown`/`Enabled`
according to the ported detector, and wrote nothing at all in `-WhatIf`. The harness was
not committed, because `tests/` belongs to the engine batch, and nothing was added to
`tests/Engine.Tests.ps1`.
