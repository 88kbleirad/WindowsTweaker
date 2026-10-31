# Migration notes - Explorer batch G1

Legacy modules converted into `src/WindowsTweaker/Tweaks/Explorer/Explorer.G1.ps1`
(category `Explorer`). The legacy files are read-only reference material and are
deleted at the end of the migration; nothing from `reference/text.txt` was used.

| Legacy module | Outcome | Tweak id(s) | Notes |
|---|---|---|---|
| CheckBoxes.ps1 | migrated | Explorer.CheckBoxes | Register: `Explorer\Advanced\AutoCheckSelect` (1 = check boxes shown, 0 = hidden). Windows default is 0. |
| ThisPC.ps1 | migrated | Explorer.ThisPC | `HideDesktopIcons\NewStartPanel\{20D04FE0-3AEA-1069-A2D8-08002B30309D}`. `Shown` writes 0 (the missing key is created by the value write itself); `Hidden` removes the value (legacy `-Hide`). The value `1` (explicitly hidden) is detection-equivalent to `Hidden`. |
| HiddenItems.ps1 | migrated | Explorer.HiddenItems | `Hidden` is 1 = show, 2 = do not show; there is no boolean, hence two explicit values. |
| FileExtensions.ps1 | migrated | Explorer.FileExtensions | `HideFileExt` 0 = show, 1 = hide (note the inverted sense of the value name). |
| MergeConflicts.ps1 | migrated | Explorer.MergeConflicts | The legacy `-Show` branch wrote to the misspelled key `CurrnetVersion`; the correct path `CurrentVersion` is used for both states. |
| OpenFileExplorerTo.ps1 | migrated | Explorer.OpenFileExplorerTo | Legacy defines only `LaunchTo` 1 (This PC) and 2 (Quick access). The assignment's third value was verified against public documentation: `LaunchTo` 3 = Downloads (undocumented value, not offered by the Folder Options dialog). Ids/states are descriptive: `ThisPC`, `QuickAccess`, `Downloads`. |
| FileExplorerCompactMode.ps1 | migrated | Explorer.FileExplorerCompactMode | `UseCompactMode` 1/0. |
| OneDriveFileExplorerAd.ps1 | migrated | Explorer.OneDriveFileExplorerAd | `ShowSyncProviderNotifications` 1 = banner shown (Windows default), 0 = hidden. Only the promotional banner is affected; OneDrive keeps syncing. |
| SnapAssist.ps1 | migrated | Explorer.SnapAssist | Legacy bug: both `-Enable` and `-Disable` wrote `SnapAssist = 1`. Upstream Sophia Script writes `WindowArrangementActive = 1` (String) unconditionally and `SnapAssist = 0` for Disable; that behaviour is restored. |
| FileTransferDialog.ps1 | migrated | Explorer.FileTransferDialog | `OperationStatusManager\EnthusiastMode`: `Detailed` = 1, `Compact` = 0 (Windows default). The key is created by the value write, so no separate key operation is needed. |
| RecycleBinDeleteConfirmation.ps1 | migrated | Explorer.RecycleBinDeleteConfirmation | Scripted tweak: the confirmation flag is bit `0x04` of byte 4 of the `ShellState` binary value. The legacy module hard-coded the whole byte (51/55), which resets the other folder-option bits stored in it, so the bit is now modified in place (like upstream Sophia). All four `ConfirmFileDelete` policy locations the legacy deleted through LGPO are removed in both states; needs Admin for the HKLM ones. Risk Medium: the safety prompt disappears. |
| QuickAccessRecentFiles.ps1 | migrated | Explorer.QuickAccessRecentFiles | `HKCU\...\Explorer\ShowRecent` (root key, not `Advanced`) 1 = shown, 0 = hidden. Both states remove the `NoRecentDocsHistory` policy value from the four locations the legacy module/LGPO touched. |
| QuickAccessFrequentFolders.ps1 | migrated | Explorer.QuickAccessFrequentFolders | Legacy function is misspelled `QuickAccesFrequentFolders`; `ShowFrequent` is the value. The legacy module removed no policy: `NoRecentDocsHistory` is the same policy that governs "recently used files" and would silently override `ShowFrequent`, so the same removals are applied here and declared as `-ManagedPolicy`. |
| FolderGroupBy.ps1 | not ported | - | The `-None` state deletes every per-folder view key under `HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\*\Shell\{885A186E-A440-4ADA-812B-DB871B942259}` (wildcard recursive delete of the user's saved folder views). The registry providers take literal paths and capture state per path, so this cannot be expressed or rolled back; porting only the `FolderTypes\TopViews` half would silently deliver a partial setting. |
| NavigationPaneExpand.ps1 | migrated | Explorer.NavigationPaneExpand | `NavPaneExpandToCurrentFolder` 1/0. (Legacy parameter was misspelled `$Disale`.) |
| FoldersLaunchSeparateProcess.ps1 | migrated | Explorer.FoldersLaunchSeparateProcess | Boolean: `Advanced\SeparateProcess` 1/0. (Legacy parameter attribute was misspelled `ParametetSetName`.) |
| ShortcutsSuffix.ps1 | migrated | Explorer.ShortcutsSuffix | Boolean: `NamingTemplates\ShortcutNameTemplate = "%s.lnk"` means the " - Shortcut" suffix is not used. The legacy `-Enable` branch removed the value from the misspelled key `NamingTemplate` (singular) and therefore never worked; the correct key is used. `Explorer\link` is removed in both states, as in the legacy. The `Enabled` state leaves the default (value absent), so detection reports it as `Unknown` with the reason "value not present" instead of guessing. |
| WinPrtScrFolder.ps1 | migrated | Explorer.WinPrtScrFolder | `User Shell Folders\{B7BEDE81-DF94-4682-A7D8-57A52620B86F}` (Screenshots known folder). `Desktop` writes the standard `%USERPROFILE%\Desktop` (REG_EXPAND_SZ) instead of copying the raw Desktop shell-folder value, so the state is fixed and detectable; `Default` removes it (screenshots go to `Pictures\Screenshots`). The legacy OneDrive-account guard and its preset-script/`Get-PSCallStack` introspection were dropped: they inspected the calling script rather than the setting, and package queries are not part of the provider surface. |

## Batch-wide decisions

- No duplicate legacy modules were found inside this batch, and no tweak id here
  collides with another batch.
- Every state of `Explorer.RecycleBinDeleteConfirmation`,
  `Explorer.QuickAccessRecentFiles` and `Explorer.QuickAccessFrequentFolders` lists
  the complete set of operations, including the removal of the
  `HKLM\SOFTWARE\Policies\...` / `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\...`
  values that would otherwise override the user values. Those tweaks are therefore
  `-Privilege Admin` / `-Scope UserAndMachine` and declare `-ManagedPolicy`.
- `-Restart` is `Explorer` for the folder-option toggles, `None` where the value is
  read per operation (`FileTransferDialog`, `RecycleBinDeleteConfirmation`,
  `ShortcutsSuffix`) and `SignOut` for the shell-folder redirection
  (`WinPrtScrFolder`).
- `-DefaultState` is the Windows out-of-box behaviour where it is unambiguous
  (`QuickAccess` for the Explorer launch folder, `Compact` for the transfer dialog,
  `Hidden` for the desktop This PC icon, ...), so applying a tweak without an
  explicit `-State` does not change anything on a stock system.
