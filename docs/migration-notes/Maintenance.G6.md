# Maintenance batch G6 - migration notes

Batch file: `src/WindowsTweaker/Tweaks/Maintenance/Maintenance.G6.ps1`
Legacy sources: `modules/*.ps1` (read-only reference, deleted at the end of the migration;
partially extracted from Sophia Script for Windows, MIT, (c) 2023 farag2).

## Per-module outcome

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| `RegistryBackup.ps1` | migrated (declarative) | `Maintenance.RegistryBackup` | One registry value (`HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager\EnablePeriodicBackup`, lines 24 and 28). `Enabled` writes 1, `Disabled` writes 0 instead of deleting the value, so both states are detectable and restorable. |
| `CreateRestorePoint.ps1` | not ported - documented instead | - | Implicit restore-point creation plus System Protection enable/disable; the existing public `New-WtRestorePoint` covers the intent and is opt-in. See "CreateRestorePoint" below. |
| `ThumbnailCacheRemoval.ps1` | migrated (declarative) | `Maintenance.ThumbnailCacheCleanup` | Two registry values (the `Thumbnail Cache` Disk Cleanup handler's `Autorun`, 64-bit key and `WOW6432Node` key). The legacy `Disable` branch wrote a differently spelled key (`...\Explorer\VolumeCache\Thumbnail Cache`, line 26) instead of `VolumeCaches`; the batch writes the same, correct `VolumeCaches` path in both states and never touches the misspelled key. |
| `SaveRestartableApps.ps1` | migrated (declarative) | `Maintenance.RestartApps` | One registry value (`HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\RestartApps`, lines 24 and 28). |
| `NetworkAdapterSavePower.ps1` | migrated (scripted, per adapter) | `Maintenance.AdapterPowerSaving` | Required a new provider (`Private/Providers/AdapterPower.ps1`); see "NetworkAdapterSavePower" below. |
| `NetworkDiscovery.ps1` | migrated (scripted, firewall groups) | `Maintenance.NetworkDiscovery` | Firewall groups only; two parts of the legacy function are not ported (network category change, redundant single rule). See "NetworkDiscovery" below. |
| `ScheduledTasks.ps1` | not ported | - | The module is a WPF task picker with no explicit task paths. See "ScheduledTasks" below. |
| `InstallDotNetRuntimes.ps1` | migrated (scripted, download + install) | `Maintenance.InstallDotNetRuntime` | Ported through `Get-WtVerifiedDownload` + `Invoke-WtProcess`; the automatic "latest release" lookup is not ported. See "InstallDotNetRuntimes" below. |
| `LatestInstalled.NET.ps1` | migrated (declarative) | `Maintenance.OnlyUseLatestClr` | Two registry values (`HKLM:\SOFTWARE\Microsoft\.NETFramework` and `HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework`, `OnlyUseLatestCLR`, lines 24-29). `Enabled` writes 1, `Disabled` writes 0 in both keys instead of deleting them. Kept at `-Risk High`, because it redirects every .NET Framework application to the newest CLR. |
| `InitialActions.ps1` | not ported (startup logic) | - | Nine separate behaviours, each not ported for a specific reason. See "InitialActions" below. |

## Batch decisions that deviate from the batch ticket

The batch ticket listed `RegistryBackup`, `ThumbnailCacheRemoval`, `InstallDotNetRuntimes`
and `LatestInstalled.NET` together as "bulk/irreversible or download-based" and asked for
`New-WtScriptTweak -Rollback None -Risk High` with mandatory `-Arguments` for all four.
Reading the sources shows that only one of them is bulk or download-based
(`InstallDotNetRuntimes.ps1`, which downloads, installs and then deletes files), while the
other three are single, fully reversible registry values. `docs/MIGRATION-SPEC.md` is the
binding contract and requires honest metadata (one tweak per user-visible setting, `Rollback`
classified by what the provider can actually restore), so:

* `Maintenance.RegistryBackup`, `Maintenance.ThumbnailCacheCleanup` and
  `Maintenance.OnlyUseLatestClr` are declarative registry tweaks with `-Rollback Full`
  (the registry provider captures the previous values, including "the value did not exist",
  and rollback restores exactly that) and no mandatory `-Arguments` (nothing destructive
  happens and there is nothing to select).
  * `Maintenance.OnlyUseLatestClr` keeps `-Risk High`: forcing every .NET Framework
    application onto the newest CLR can break applications that were built for an older one.
  * `Maintenance.RegistryBackup` and `Maintenance.ThumbnailCacheCleanup` are `-Risk Medium`:
    they change machine-wide Windows maintenance behaviour (registry backup files, and what
    Disk Cleanup may delete) but the tweaks themselves write one registry value each and are
    fully reversible. Claiming `-Risk High` and `-Rollback None` for them would misreport
    their real consequence and their rollback fidelity.
* `Maintenance.InstallDotNetRuntime` follows the instruction: scripted tweak,
  `-Rollback None -Irreversible -Risk High`, and it refuses to do anything without an
  explicit `-Arguments.Uri`.

## Tweaks added

| Tweak id | States | Scope / privilege | Rollback | Risk |
|---|---|---|---|---|
| `Maintenance.RestartApps` | Enabled, Disabled | User / None | Full | Low |
| `Maintenance.RegistryBackup` | Enabled, Disabled | Machine / Admin | Full | Medium |
| `Maintenance.ThumbnailCacheCleanup` | Enabled, Disabled | Machine / Admin | Full | Medium |
| `Maintenance.OnlyUseLatestClr` | Enabled, Disabled | Machine / Admin | Full | High |
| `Maintenance.InstallDotNetRuntime` | None (default), Enabled | Machine / Admin | None (irreversible) | High |
| `Maintenance.NetworkDiscovery` | Enabled, Disabled (default) | Machine / Admin | Full | Medium |
| `Maintenance.AdapterPowerSaving` | Enabled (default), Disabled | PerAdapter / Admin | Full | Medium |

## CreateRestorePoint: documented, deliberately not a tweak

`modules/CreateRestorePoint.ps1` is not expressible as a tweak, and every part of it would be
wrong to run as one:

* line 14/19 sets `SystemRestorePointCreationFrequency` to 0 and back to 1440, a
  machine-wide System Restore frequency change used only to bypass the 24-hour throttle,
* lines 8-11 and 22-25 enable System Protection when it is off and then turn it off again
  (via `Enable-ComputerRestore` / `Disable-ComputerRestore`),
* line 16 calls `Checkpoint-Computer` unconditionally ("Never skip creating a restore point").

The intent already exists as a public function: `New-WtRestorePoint`
(`src/WindowsTweaker/Public/Reporting.ps1`) honours `-WhatIf`, reports `unsupported`/`failed`
honestly, and is never implicit - the caller opts in with
`Invoke-WtTweak -Id <Id> -IncludeRestorePoint`. Nothing creates a restore point as a side
effect of another tweak, and the "creation frequency 0" trick is not ported because it
changes a user-visible System Restore setting to defeat a built-in throttle.

## NetworkAdapterSavePower (migrated)

* The legacy function (lines 24-59) selected every physical adapter with a MAC address and
  status `Up`, skipped adapters reporting `Unsupported`, then assigned
  `$Adapter.AllowComputerToTurnOffDevice = "Enable"/"Disable"` and piped the instance into
  `Set-NetAdapterPowerManagement`. `Set-NetAdapterPowerManagement` has no
  `-AllowComputerToTurnOffDevice` parameter (the property lives on
  `MSFT_NetAdapterPowerManagementSettingData`), so the InputObject form is the only supported
  way; the batch keeps that technique but uses the documented property values
  `Enabled`/`Disabled` instead of the legacy's `Enable`/`Disable`.
* `Set-NetAdapterPowerManagement` restarts the selected adapter, which is why the tweak asks
  for an explicit `-Arguments.InterfaceIndex` list (the DNS tweak uses the same convention)
  and refuses to run without one; the legacy "all physical adapters" sweep is not reproduced.
* New provider `src/WindowsTweaker/Private/Providers/AdapterPower.ps1`:
  `Test-WtAdapterPowerAvailable`, `Get-WtAdapterPowerRaw`, `Set-WtAdapterPowerRaw`,
  `Get-WtAdapterPowerSnapshot`, `Set-WtAdapterPowerState` (availability check, read-only
  snapshot, `-WhatIf`, state capture, verification by re-reading the property, per-operation
  logging). `Private/Rollback.ps1` gained the matching `AdapterPower` record kind, so
  `-Rollback Full` is truthful: the captured per-adapter value is re-applied by
  `Set-WtAdapterPowerState`.
* Not ported: the trailing wait loop and the Wi-Fi reconnect (`netsh wlan connect name=$SSID`,
  lines 36-39 and 61-78), the `WinAPI.GetStrings` verbose output and the interactive
  `Write-Information` chatter. Those are console/UX side effects, not settings, and the
  reconnect would run a `netsh` command outside the providers.

## NetworkDiscovery (migrated, firewall groups only)

* Legacy lines 25-37: `Set-NetFirewallRule -Group @FirewallAPI.dll,-32752,@FirewallAPI.dll,-28502
  -Profile Private -Enable True` plus `Set-NetFirewallRule -Profile Private -Name FPS-SMB-In-TCP
  -Enable True` plus `Set-NetConnectionProfile -NetworkCategory Private` to enable, and the same
  group call with `-Enable False` to disable.
* `-Profile` of `Set-NetFirewallRule` is the profile the rules are *assigned to*, not a filter
  (`Get-NetFirewallRule` has no `-Profile` parameter at all; profile scoping is done with
  `Get-NetFirewallProfile`). `Set-WtFirewallGroupState` therefore gained an optional `-Profile`
  that is passed through to every rule of the group, exactly as the legacy call did, and
  `Get-WtFirewallGroupSnapshot` now also captures each rule's `Profile` so rollback can restore
  it (`Private/Rollback.ps1` passes `Profile` back when the record has one; older records
  without it still restore `Enabled`/`Action`). Multi-profile values are recorded as Windows
  reports them (`Domain, Private`) and are passed back with the spaces removed, which is the
  form the parameter expects.
* Ported: the enable/disable of both groups with `-Profile Private` (states `Enabled` and
  `Disabled`; default `Disabled`).
* Not ported: `Set-NetConnectionProfile -NetworkCategory Private` (no provider exists, and
  forcing the active network's category is a broader change than a firewall-rule toggle), and
  the separate `FPS-SMB-In-TCP` rule (it belongs to the `File and Printer Sharing` group
  `@FirewallAPI.dll,-28502`, which the tweak already covers).
* The `NetworkDiscovery` groups are also enabled/disabled regardless of the *current* network
  category, so a user who is on a network Windows classifies as Public gets the rules enabled
  and assigned to `Private`: discovery stays off until the network is Private, which the
  impact text states.

## ScheduledTasks (not ported)

`modules/ScheduledTasks.ps1` cannot be turned into an honest, path-explicit tweak:

* it is a WPF dialog (`System.Windows.Markup.XamlReader`, lines 39-92, 236-244) whose task set
  is the *user's* selection; the 12 names at lines 24-37 (`MareBackup`,
  `Microsoft Compatibility Appraiser`, `StartupAppTask`, `Proxy`, `Consolidator`, `UsbCeip`,
  `Microsoft-Windows-DiskDiagnosticDataCollector`, `MapsToastTask`, `MapsUpdateTask`,
  `FamilySafetyMonitor`, `FamilySafetyRefreshTask`, `XblGameSaveTask`) are only the
  pre-checked default of the picker,
* matching is by *task name* against the whole task library (`$_.TaskName -match $_` at
  line 177, and `$_.TaskName -eq $CheckBox.Parent.Children[1].Text` at line 110), so two tasks
  with the same name in different folders cannot be distinguished,
* the query uses an undefined variable: line 207 filters with `$_.TaskName -in
  $CheckScheduledTasks`, but the list is called `$CheckedScheduledTasks`, and `$CheckScheduledTasks`
  does not exist anywhere in the repository,
* the enable path calls a cmdlet that does not exist (`Enabled-ScheduledTask`, line 148;
  `Disable-ScheduledTask` at line 138 is correct).

No task *path* appears anywhere in the module, so the list cannot be established reliably
from it, and guessing paths for tasks that disable OS maintenance/telemetry would be exactly
the kind of unverified action the migration rules forbid. `Set-WtScheduledTaskState -Path -Name`
is available for a curated tweak, but such a tweak needs an explicit, verified path list that
this batch cannot derive from the legacy source. Recorded as not ported for that reason.

## InstallDotNetRuntimes (migrated, narrowed)

* Legacy behaviour: download `https://builds.dotnet.microsoft.com/dotnet/release-metadata/<8.0|9.0>/releases.json`
  (lines 26, 97) to discover the newest release, download
  `dotnet-runtime-<version>-win-x64.exe` into the user's Downloads folder (lines 56-62, 127-133),
  run it with `/install /passive /norestart` (lines 77, 148) after comparing the version found
  in the Package Cache (lines 41-51, 113-123), then delete the installer and the .NET log files
  (lines 79-83, 150-154). It also has a typo at line 116 (`$CurrnetNET9Version`).
* Ported: the install itself, through the providers. `-Arguments.Uri` must be an explicit
  https URL to the official installer, `Get-WtVerifiedDownload` refuses `http://` and refuses
  any file whose Authenticode signature is not valid *and* issued to `Microsoft Corporation`
  (the downloaded file is deleted when the signature check fails), and only then is the file
  run with `Invoke-WtProcess /install /passive /norestart`. In `-WhatIf` nothing is downloaded
  and nothing is executed.
* Not ported: the "latest release" lookup. `Detect`/`Apply` may only use provider functions,
  and no provider fetches or parses release metadata from the internet, so the release version
  must come from the caller as an exact URL. Also not ported: the post-install deletion of the
  installer and of `%TEMP%\Microsoft_.NET_Runtime*.log` (there is no file-deletion provider, and
  the migration rules require an explicit, documented deletion target); the installer is left in
  the destination path (`%TEMP%` unless `-Arguments.DestinationPath` is given) and the impact
  text says so.
* `-Rollback None -Irreversible -Risk High`, `-StateNames None,Enabled`, default `None`: nothing
  is downloaded or executed unless `-State Enabled` and `-Arguments.Uri` are both given.

## InitialActions (not ported - startup logic, nine behaviours)

The file is startup/initialisation logic for the legacy CLI, not a setting. It cannot be ported
as-is; each of its behaviours is not ported for the reason below. Line numbers refer to
`modules/InitialActions.ps1`.

| Behaviour | Reason it is not ported |
|---|---|
| `Get-ChildItem -Path $PSScriptRoot\..\ -File -Recurse -Force \| Unblock-File` (line 13) | Bulk modification of every file in the script tree (removes Zone.Identifier data) with no provider, no dry run and unrelated to any setting. |
| `[Net.ServicePointManager]::SecurityProtocol = Tls12` (line 15) | Process-wide, legacy TLS configuration; PowerShell 7 negotiates TLS 1.2+ itself, so it is dead weight. |
| `Import-Module ... -UseWindowPowerShell` (line 19) | Windows PowerShell 5.1 host switching; the module targets PowerShell 7 and must stay in-process. |
| `Add-Type` of inline C# Win32 P/Invoke helpers (lines 31-110, 663-679) | Hard rule 2 forbids inline C# (`Add-Type`); the helpers only format strings and foreground windows. |
| `Get-NetFirewallRule -DisplayName Block.MSFT*, Blocker MicrosoftTelemetry*, Blocker MicrosoftExtra*, windowsSpyBlocker* \| Remove-NetFirewallRule` (lines 288-290) | Deletes firewall rules that third-party tools created, machine-wide and inside a startup path; the provider only toggles the enabled state of a named group, and deleting rules is not a maintenance setting. |
| `hosts` file handling: warning about third-party entries (lines 297-320), download of six WindowsSpyBlocker lists over https and rewrite of `%SystemRoot%\System32\drivers\etc\hosts` (lines 331-402), then `Start-Process notepad.exe` (line 404) | Downloads data from the internet and rewrites a system file outside any provider, with no reversible state capture; the rules explicitly forbid download-and-write flows and deleting/rewriting data outside an explicit target. |
| Component/consistency gates and their exits: PowerShell-from-the-Store check (lines 415-425), Experience Pack / EventLog / Store checks (lines 424-448), Defender files, `SettingsPageVisibility` policy and Security Center queries (lines 450-560), pending-reboot check (lines 616-638), bundled-binary check for `Binaries\LGPO.exe`, `Microsoft.Windows.SDK.NET.dll`, `WinRT.Runtime.dll` (lines 641-650) | These are pre-flight guards that terminate the CLI; they change no setting, and the bundled binary requirement cannot be satisfied at all (LGPO must not be shipped or downloaded - see the spec's rule on the LGPO `DELETE` lines). |
| `Start-Service -Name SecurityHealthService` (line 516) | Starts a security service automatically during startup, outside the providers and without the user asking; not a maintenance setting. |
| `Set-MpPreference -EnableControlledFolderAccess Disabled` followed by `Start-Process windowsdefender://RansomwareProtection` (lines 601-611) | Controlled Folder Access is ransomware protection: hard rule 1 forbids disabling it during startup or as a side effect, and it could only ever be a separate `-ReducesProtection -Risk High` tweak that never applies automatically. |
| `New-ItemProperty ... AllowMUUpdateService = 1` (lines 686, 723, 747), `UsoClient.exe StartInteractiveScan` (lines 689, 729, 753), `Invoke-CimMethod UpdateScanMethod` (lines 708, 726, 750), `ms-settings:windowsupdate` (lines 732, 756), `ms-windows-store://pdp/?productid=9NODX20HK701` (line 705) | Startup-time update scanning and app-store/URL launches: writing `AllowMUUpdateService` and triggering scans/UI from startup is not a maintenance setting, and launching URLs and Store pages from a tweak is a user-visible side effect the framework does not provide. |
| SysMain re-enable plus `Start-Process https://www.outsitethebox.ms/19318` (lines 764-770) | Silently reconfigures a service and opens an external URL during startup. The service change would belong to a service tweak (`System.SysMainService` already exists in the catalog and is explicit); the URL launch is dropped entirely. |
| `Set-CimInstance` `AutomaticManagedPageFile = $true` (lines 773-776) | Changes the paging-file configuration machine-wide during startup with no provider, no state capture and no rollback. |
| `Remove-Item "$env:TEMP\LGPO.txt"`, `Remove-Item` of the paths in `$Paths` (lines 778, 83, 154) | Deletes files without an explicit, documented target and outside the providers. |
| COM enumeration of open Explorer windows (`Shell.Application.Windows()`, line 781) and the reset-preset prompt that `Invoke-Item`s a preset file (lines 790-816) | Explorer automation and an interactive "run this preset instead" flow; neither is a setting and both act outside any provider. |

### Module import and `Get-WtEnvironment` perform none of the above

Confirmed by reading the code paths that run at import time:

* `src/WindowsTweaker/WindowsTweaker.psm1` parses then dot-sources `Private\*.ps1`,
  `Private\Providers\*.ps1`, `Public\*.ps1`, `Tweaks\**\*.ps1` and `Gui\*.ps1`. Tweak files
  (including this batch) only call the constructors, so importing the module registers metadata
  and nothing else.
* `src/WindowsTweaker/Private/Environment.ps1` is read-only by construction (its header says so
  and the code matches): `[System.Security.Principal.WindowsIdentity]::GetCurrent()`,
  `Get-ItemProperty` on `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion`, `Get-CimInstance
  Win32_ComputerSystem`, `Test-Path` on the pending-reboot markers, `Get-Command`/`Get-Module`
  lookups for dependency tokens. It does not call Controlled Folder Access (no `Set-MpPreference`),
  does not touch services, the page file or the hosts file, does not download anything, does not
  open URLs, and does not `Add-Type` inline C#. `Get-WtEnvironmentInternal` is additionally cached
  and only reads.
* `tests/Loading.Tests.ps1` asserts both properties and they pass:
  "writes no state, logs or directories when the module is imported" and
  "performs no detection-time mutation for any tweak" (which runs `Get-WtTweakState` over the
  whole catalog, this batch included).

## Framework changes this batch needed

* `src/WindowsTweaker/Private/Providers/AdapterPower.ps1` (new): adapter power-management
  provider, described above.
* `src/WindowsTweaker/Private/Providers/System.ps1` (firewall section): optional `-Profile`
  pass-through on `Set-WtFirewallRuleRaw` and `Set-WtFirewallGroupState` (additive; omitted
  means the previous behaviour is byte-for-byte unchanged, so `System.DiagTrackService` and the
  declarative `FirewallGroup` operations are unaffected), and the rule snapshot now records
  `Profile`.
* `src/WindowsTweaker/Private/Rollback.ps1`: new `AdapterPower` record kind, and the
  `FirewallGroup` restore passes the captured `Profile` when the record has one (records
  written before this change still restore `Enabled`/`Action`).

## Validation

Commands run from the repository root (PowerShell 7.6.9, Pester 5.7.1). The catalog
grows as the sibling batches land, so the tweak count below is the one observed when
this batch was validated.

```
$ ~/opt/pwsh/pwsh -NoProfile -File tools/Parse-All.ps1
Files parsed : 51
Parse errors : 0

    No parse error anywhere in the tree (`grep -E "\.ps1" | grep -vc "^modules/"`
    returned 0 as well while the legacy modules/ tree still existed: the 39 parser
    errors it reported were all in the 8 unparseable legacy files, none of them in
    this batch). The legacy modules/ tree has since been deleted by the migration, so
    the line references to modules/*.ps1 above are historical.

$ ~/opt/pwsh/pwsh -NoProfile -File tools/Test-Catalog.ps1
Tweaks in catalog : 111
Catalog invariants: OK

$ ~/opt/pwsh/pwsh -NoProfile -Command "Import-Module Pester -RequiredVersion 5.7.1; Invoke-Pester -Path tests/Engine.Tests.ps1 -Output None"
    all tests pass (21 passed, 0 failed)
```

Additional runs: `tests/Loading.Tests.ps1` (14 passed, 0 failed), the whole `tests`
directory (67 passed, 0 failed), and a throwaway Pester check of this batch run from
outside the repository - detection of all seven tweaks, `-WhatIf` never downloading,
adapter-power apply + rollback, discovery apply + rollback, and the two "no explicit
selection" refusals. The throwaway file was deleted afterwards.
