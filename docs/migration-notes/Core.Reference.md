# Migration notes - framework reference batch (Core.Reference)

Modules of the legacy tree that were converted directly while building the framework,
plus the legacy entry point. These are the files whose defects were reported in the
audit; the fixes are noted per row.

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| `AdvertisingID.ps1` | migrated | `Privacy.AdvertisingId` | Policy value written directly (`HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo\DisabledByGroupPolicy` removed instead of an LGPO `DELETE` transcript); HKCU `Enabled` 1/0 kept. `-ManagedPolicy` declared. |
| `TailoredExperiences.ps1` | migrated | `Privacy.TailoredExperiences` | Same translation: policy value removed, user value written, `-ManagedPolicy` declared. |
| `FeedbackFrequency.ps1` | migrated | `Privacy.FeedbackFrequency` | `NumberOfSIUFInPeriod`; the legacy `Enabled` state removed the value, which the declarative detector cannot express, so `Enabled` removes it and detection maps absent to `Disabled` is avoided by documenting `Disabled` = 0 explicitly. |
| `ErrorReporting.ps1` | migrated | `Privacy.ErrorReporting` | `Windows Error Reporting\Disabled` plus removal of the machine policy that overrides it. |
| `DiagnosticDataLevel.ps1` | migrated | `Privacy.DiagnosticDataLevel` | `AllowTelemetry`; the legacy "DISABLE" LGPO line was meaningless (it deleted the policy the module itself set), so both states write their real value and the policy value is declared as managed. States are `Disabled` (1, required-only) and `Enabled` (3, full) - never "telemetry off", which Windows does not offer. |
| `DiagTrackService.ps1` | migrated | `System.DiagTrackService` | Legacy defects fixed: missing `)` in the parameter list (the file did not parse), `Stop-Service -StartupType Disabled` (invalid - `-StartupType` belongs to `Set-Service`), the `Start-Sevice` typo, and the local `Set-Policy`/LGPO transcript helper. Now a scripted tweak that disables/stops the service and blocks its firewall group, with both service configuration and firewall state captured for rollback. |
| `TaskbarWidgets.ps1` | migrated | `Taskbar.Widgets` | The `powershell.exe` -> `powershell_temp.exe` copy into `System32` (and its deletion) is removed: the registry values are written directly. Policy values that suppress the Widgets feed are removed in both states and declared as managed. The legacy module also required the Web Experience package; requirement documented in the impact text instead of aborting silently. |
| `DNSoverHTTPS.ps1` | migrated | `Network.DnsOverHttps` | Legacy defects fixed: `-SeverAddress` typo (`Set-DnsClientServerAddress -ServerAddress`), `Resolve-DnsName -HoHostsFile`, a duplicated `DohFlags` write, and an `if`/`New-Item` mismatch that created the *secondary* address subkey while configuring the primary one. Rewritten as a scripted tweak that only touches adapters passed in `-Arguments.InterfaceIndex`, refuses VPN/virtual adapters unless asked, captures the exact per-adapter server list (including "obtain automatically") and writes DoH values through the registry provider. |
| `UninstallUWPApp.ps1` | migrated | `Apps.UninstallUwpPackage` | Defined the same `UninstallUWPApps` function as the sibling file (duplicate definition). Both collapse into one tweak: nothing selected by default, protected packages refused, `-AllUsers` scope shown, and the unnamed-value/WinRT helper code dropped. |
| `UninstallUWPApps.ps1` | migrated | `Apps.UninstallUwpPackage` | The WPF picker and `Get-AppxBundle` (needs bundled `WinRT.Runtime.dll`/`Microsoft.Windows.SDK.NET.dll`, which are not shipped) are not ported; selection is explicit through `-Arguments.PackageFullName`. The hard-coded package allow/deny lists are replaced by `Get-WtProtectedPackage`. |
| `tweakWindow.ps1` (entry point) | replaced | - | Called `Disable-Telemetry`, `Disable-WindowsUpdate`, `Disable-Cortana` and `Remove-Bloatware`, none of which exist anywhere in the archive, loaded no modules and never initialised localization. Replaced by `WindowsTweaker.ps1`, which loads the module and exposes a catalog-driven CLI. There is deliberately no "disable Windows Update permanently" feature: the menu entry is gone instead of being faked. |

## Framework-level notes

* `Set-Policy` (defined only inside `DiagTrackService.ps1`) was the LGPO transcript
  helper that 40 legacy modules called. `LGPO.exe` is not bundled, so those calls did
  nothing. Every such call is replaced by an explicit `RegistryRemove`/`RegistrySet`
  operation on the real registry path, which the state store can capture and restore.
* `$Localization.*` (used by 30 modules) came from a localization file that is not in
  the archive. It is replaced by `src/WindowsTweaker/Data/Strings.en.psd1` /
  `Strings.vi.psd1` with an explicit fallback chain, plus per-tweak localized metadata.
* The `Binaries` directory the legacy `InitialActions.ps1` required
  (`LGPO.exe`, `WinRT.Runtime.dll`, `Microsoft.Windows.SDK.NET.dll`) never existed here.
  None of them is needed now; nothing is downloaded to replace them.
