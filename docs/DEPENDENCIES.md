# Dependency requirements

## Host requirements

| Requirement | Value | Why |
|---|---|---|
| Operating system | Windows 10 22H2 or Windows 11 | Tweaks declare `-SupportedOS`/`-MinBuild`; individual tweaks report `unsupported` on other builds instead of guessing |
| PowerShell | **Windows PowerShell 5.1** (included with Windows) and **PowerShell 7.4-7.6** (validated range; 7.6.9 executed) | The runtime differences are handled in `src/WindowsTweaker/Private/Compatibility.ps1`: BOM-less UTF-8 writes, JSON parameters that exist only on 7, platform detection, console VT, worker stdin encoding. `#Requires -Version 5.1` and the module manifest (`PowerShellVersion = '5.1'`, `CompatiblePSEditions = Desktop,Core`) enforce the floor. `tools/Test-Compatibility.ps1` checks the 5.1 API surface statically |
| PowerShell 6.0-7.3, 7.7+, 8.x, preview | **Untested** | They start and print a notice; the bootstrap never hands off to them. `-RuntimeReport` lists the capabilities of the running one. See [COMPATIBILITY.md](COMPATIBILITY.md) |
| PowerShell 3.0-5.0 | **Not supported** | `#Requires -Version 5.1` refuses at parse time |
| Elevation | Per tweak (`-Privilege Admin`), and an explicit UAC handoff for the external tool | Machine-wide tweaks report `unsupported` with the reason "Administrator privileges are required" when not elevated; user tweaks keep working. The external tool is launched through `Start-Process -Verb RunAs` when the session is not elevated, and a refused prompt cancels the launch |
| Runtime libraries | None bundled | No LGPO.exe, no WinRT DLLs, no downloaded binaries, no fonts. The only binary a release ships is the optional Go worker built from this repository's own `worker/` source; the modules linked into it are listed with their licences in `THIRD-PARTY-NOTICES.md` |
| Network access | Only for tweaks that download an official installer (outside a dry run, with a publisher signature check), and for the explicit external-tool action in `Licensing & Activation` (one pinned file over HTTPS) | Everything else works offline; the external tool is never fetched during navigation, refresh, startup or diagnostics |

## Terminal requirements (interactive interface)

The keyboard-driven interface needs nothing installed, but it does need a terminal it can
drive. Everything below is detected at startup; when a requirement is missing the interface
degrades (documented fallback) or refuses to start (with the CLI switches as the way
forward).

| Requirement | Why | When it is missing |
|---|---|---|
| An interactive terminal: stdin and stdout not redirected, window size > 0 | The interface reads raw key presses and addresses the screen | `Start-WtTui` prints the reason and the CLI alternatives and the entry point exits with code `2`; it never hangs on a pipe |
| A console that supports ANSI virtual terminal sequences (Windows Terminal, or conhost on Windows 10 1703+ / any modern terminal on Linux) | Frame addressing, colours and the alternate screen buffer | `-Colour Mono` rendering through the `[Console]` API (`SetCursorPosition` + `ConsoleColor` 16-colour pairs) instead of ANSI sequences |
| UTF-8 output encoding | Vietnamese diacritics and the Unicode box-drawing frame | The frame switches to ASCII (`+ - |`), which the interface reports in the header area; text is still written as-is |
| A colour depth the terminal reports (`COLORTERM`, `TERM`) | Catppuccin Mocha in true colour when possible | Automatic reduction to 256 colours, then 16 colours, then no colour. `-Colour TrueColor|Ansi256|Ansi16|Mono` forces a depth; `-Ascii` forces ASCII frames |
| A font with box-drawing glyphs (any default monospace font) | Panel borders | `-Ascii` uses `+ - |` instead. **No Nerd Font and no icon font is required**; every status is also written as text (`>`, `*`, `!`, `M`, `R`, `D`) |
| A font that has the glyphs of the active icon mode (optional) | Category, state and action icons | Icons are decoration and never the only signal. `Auto` resolves to `Unicode` on a UTF-8 terminal and to the readable ASCII tags otherwise; `-Icons Auto|Unicode|NerdFont|ASCII|None` selects another mode, `I` opens an in-terminal preview of every mode, and `-Ascii` forces ASCII frames *and* ASCII icons. **Nothing is installed, and no font is detected or changed**: the preview is what tells you whether this terminal font has the glyphs |
| A terminal and pane wide enough for the icon column (optional) | Icons in a pane | The icon column is dropped for that pane when the slot, the widest count and a readable label no longer fit (7 cells per ASCII tag, 2 per Unicode icon); the label and the count keep their space and no column behind the pane shifts |
| The optional background worker (only for `-WorkerBackend Go` / `Auto`) | Faster directory scans and, later, other read-only work | `Auto` falls back to the built-in PowerShell implementation and reports the reason (`Get-WtWorkerStatus`); `Go` reports the capability as unavailable instead of falling back. Nothing is installed, downloaded or looked up on `PATH` - the binary is read from `$env:WT_WORKER_PATH` or `worker/bin/<os>-<arch>/` |
| A terminal at least 40x6 | Rendering the panes | Below 58x12 the single-pane layout with a category tab strip is used; below 40x6 the interface still renders but the panes are severely clipped (no crash, no lost selection) |

No third-party library is used or required for any of this: the renderer, the cell grid, the
dialogs, the key handling and the worker runspace are part of the module.

## Windows-only modules and cmdlets, per feature area

Every dependency is declared per tweak (`-Requires @('Cmdlet:Get-NetAdapter')`,
`-Requires @('Module:DnsClient')`, `Admin`, `OS:Windows11`, `Build:22621`). Importing
the module never imports Windows-only modules; they are resolved when a tweak runs.

| Feature area | Dependency | Missing → behaviour |
|---|---|---|
| Registry tweaks (the majority) | Windows registry provider (`HKLM:`, `HKCU:`, `HKCR:`) | Tweak reports `unsupported` ("Registry provider is not available on this platform") and nothing is written |
| DiagTrack service, SysMain | `Get-Service`, `Set-Service` (Microsoft.PowerShell.Management) | Service tweaks report `unsupported` |
| Scheduled tasks | `ScheduledTasks` module (`Get-ScheduledTask`, `Enable/Disable-ScheduledTask`) | Task operations report `unsupported` |
| Firewall group changes | `NetSecurity` module (`Get-NetFirewallRule`, `Set-NetFirewallRule`) | Firewall operations report `unsupported`; the rest of the tweak still runs and the failure is visible per operation |
| DNS / DoH | `DnsClient` module (`Get-DnsClientServerAddress`, `Set-DnsClientServerAddress`), `Get-NetAdapter` | DNS tweaks report `unsupported` |
| App package removal | `Appx` module (`Get-AppxPackage`, `Remove-AppxPackage`) - available in PowerShell 7 through Windows PowerShell compatibility | Removal reports `unsupported`; nothing is removed |
| Defender preferences (Controlled Folder Access) | `Get-MpPreference` / `Set-MpPreference` (Defender module) | Tweaks report `unsupported` |
| Optional Windows features / capabilities | `DISM` module or `dism.exe` | Those specific tweaks report `unsupported` |
| System Restore points | `Checkpoint-Computer` and System Protection enabled | `New-WtRestorePoint` returns `unsupported`/`failed` with a message; it is never required for a change |

Rules that keep a missing dependency from spreading:

1. Dependencies are checked *before* anything runs; a tweak that cannot run returns
   `unsupported` with a reason and performs zero operations.
2. A missing dependency for one tweak never blocks another tweak, and never blocks
   the module import, the catalog listing or the environment report.
3. During a multi-operation tweak, an operation whose dependency is missing is
   reported as `unsupported` for that operation only; the aggregate status makes the
   partial outcome visible (`failed` if a real failure occurred).

## Environment variables (optional, mainly for testing and portable installs)

| Variable | Effect | Default |
|---|---|---|
| `WT_DATA_ROOT` | Root for the state store and logs | `%LOCALAPPDATA%\WindowsTweaker` |
| `WT_STATE_PATH` | Explicit state store file | `<data root>\state.json` |
| `WT_LOG_DIRECTORY` | Explicit log directory | `<data root>\logs` |
| `WT_LANG` | Interface language when `-Language` is not given | `en` (fallback), otherwise the UI culture if it is `en`/`vi` |
| `WT_SETTINGS_PATH` | Explicit interface preferences file (language, icon mode) | `<data root>\settings.json` |
| `WT_PACKS_PATH` | Directory of imported packs (a document plus a record carrying its SHA-256) | `<data root>\packs` |
| `WT_MIGRATIONS_PATH` | Id migration registry, for trying a rename before shipping it | `<module>\Data\Catalog\migrations.json` |

The catalog and pack layer adds no dependency of its own: it reads JSON with `System.Text.Json`,
which ships with PowerShell 7.4+, and it never downloads a schema or resolves a remote `$ref`.

Setting any of these in a shell and then running the test suite points the tests at those files
instead of their temporary directories, which is a common way to get confusing results.


## Third-party components referenced but not required

`LGPO.exe`, `WinRT.Runtime.dll` and `Microsoft.Windows.SDK.NET.dll` were expected by the
previous revision in a `Binaries` directory that never existed in this archive. They
are **not** needed and **not** shipped: policy values are written directly through the
registry provider, and the WinRT-based Appx helpers were removed. See
`THIRD-PARTY-NOTICES.md`.
