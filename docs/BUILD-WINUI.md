# Building and packaging the WinUI 3 frontend

The WinUI project is Windows-only: the XAML markup compiler ships as a Windows process and
cannot run on Linux. This document separates **source preparation** (done anywhere, and
validated in this repository on Linux) from **building and running on Windows** (requires
a Windows machine).

## Prerequisites (Windows build machine)

- Windows 10/11 (Windows 11 IoT Enterprise LTSC 2024 is fine; see below).
- Visual Studio 2022 (17.10+) with workloads:
  - **Windows application development** (WinUI / Windows App SDK tooling),
  - **.NET desktop development**.
- .NET SDK 10.0.x (the solution targets `net10.0` / `net10.0-windows10.0.19041.0`).
- PowerShell 7.4–7.6 (or Windows PowerShell 5.1) for the engine and the test suite.
- For MSIX packaging in Release: a code-signing certificate, or `AppxPackageSigningEnabled=false`
  with sideloading/developer mode for local installs.

### Target OS floor

The Windows App SDK 1.8 line supports Windows 10 1809+ through Windows 11 26H2, including
Windows 11 IoT Enterprise LTSC 2024 (build 26100; supported through 2029-10-09 per the SDK
support table). The project targets `10.0.19041.0` and sets
`TargetPlatformMinVersion=10.0.17763.0`, so the floor is Windows 10 1809.

## Building

```powershell
# Core library (builds anywhere, including Linux):
dotnet build gui/src/WindowsTweaker.Gui.Core

# Tests (run anywhere; require pwsh on PATH for live backend tests):
dotnet test gui/tests/WindowsTweaker.Gui.Core.Tests

# WinUI app — Debug (unpackaged, fast iteration; needs a locally installed
# Windows App SDK runtime):
dotnet build gui/src/WindowsTweaker.WinUI -c Debug -p:EnableWindowsTargeting=true

# WinUI app — Release (single-project MSIX package; produces the .msix/.msixbundle):
dotnet publish gui/src/WindowsTweaker.WinUI -c Release -p:EnableWindowsTargeting=true

# WinUI app — Release, unpackaged, self-contained, as the release pipeline builds it
# (this exact layout becomes the `frontend/` payload of the Windows release archive):
dotnet publish gui/src/WindowsTweaker.WinUI/WindowsTweaker.WinUI.csproj `
  -c Release -r win-x64 --self-contained true `
  -p:AppxPackage=false -p:EnableMsixTooling=false -p:WindowsPackageType=None `
  -p:WindowsAppSDKSelfContained=true `
  -o frontend-build/win-x64
```

`EnableWindowsTargeting=true` is only needed when building from Linux/WSL; on a Windows
machine it is harmless but unnecessary.

The WinUI project ships the engine inside the package (`engine/` folder: module + bridge
host), discovered by `EngineLocator` at startup. Debug builds prefer the repository source
tree so a modified bridge is exercised without re-publishing.

### The release-pipeline build (Windows GitHub Actions runner)

`.github/workflows/release.yml` runs a `frontend-windows` job on `windows-latest` that
executes the exact `dotnet publish` command above for `win-x64`, runs
`tools/Test-WtFrontendPayload.ps1` against the publish output (the full required-asset
contract: exe, deps/runtimeconfig, the Windows App SDK native payload, `resources.pri`,
engine module + bridge host, and architecture consistency), runs the live-backend bridge
test suite on Windows, and uploads the folder as an artifact. The separate `release` job
downloads that artifact, stages it as `frontend/win-x64/`, re-validates the staged payload
(the exact bytes that enter the archive), then runs `tools/New-ReleasePackage.ps1` for all
four platforms, so the Windows archive contains the real compiled frontend while the Linux
archives carry none. This is the only place the XAML markup compiler (a Windows-only
process) runs; nothing here is synthetic. ARM64 frontend builds are not produced until they
can be validated the same way; the ARM64 archive ships without a frontend payload.
`tools/Test-WtFrontendPayload.ps1` is also execurable manually on any published folder:

```powershell
pwsh -NoProfile -File tools/Test-WtFrontendPayload.ps1 -Path frontend-build/win-x64
```

Compilation alone is never reported as proof the GUI can start: WinUI 3 self-contained apps
fail at runtime (stowed exceptions) when a required payload file is missing or the native
architectures mismatch, so the payload check is mandatory in both workflows.

## Startup diagnostics

The frontend writes a startup trace to the engine's log directory — `%LOCALAPPDATA%\WindowsTweaker\logs` on Windows
(`WT_LOG_DIRECTORY` overrides it) — as `startup-<yyyyMMdd-HHmmss>.log`. It records, with
timestamps, each startup stage (application construction, resource loading, MainWindow
`InitializeComponent`, engine resolution, window activation, backend launch, handshake)
and the full managed exception chain (type, message, HRESULT, inner exceptions, stack
traces) before a fatal error becomes the stowed exception (0xc000027b) WER reports. The
global handlers are registered first thing in the App constructor; fatal exceptions are
never marked handled. When the frontend fails before the log can be written, collect a
crash dump and inspect the stowed exception (see docs/VALIDATION.md §25).

## Package versions (verified 2026-11)

- `Microsoft.WindowsAppSDK` **1.8.260921001** (latest stable 1.8 servicing on NuGet).
- `Microsoft.Windows.SDK.BuildTools` **10.0.26100.4654** (the floor WinAppSDK demands).
- Upgrading to the Windows App SDK 2.x line (currently 2.6.4): bump the two package
  references; the same OS floor applies. Not done here because there is no Windows build
  environment in this repository to validate the major bump.

## Running

- Debug: `dotnet run --project gui/src/WindowsTweaker.WinUI` (unpackaged; needs the
  Windows App SDK runtime installed — Visual Studio installs it).
- Release: install the produced MSIX package; the Windows App SDK runtime is installed
  automatically with the package. The first launch starts the backend bridge, which needs
  the PowerShell host at the pinned path (see `PowerShellLocator`). It never requires
  elevation to open.

## Bootstrap / release notes

The PowerShell release ZIP (built by `tools/New-ReleasePackage.ps1`) is unaffected: it
keeps shipping the module, CLI and TUI. The WinUI app is a separate MSIX artifact and is
not yet included in the ZIP release pipeline. The bootstrap additionally supports an
opt-in `WT_BOOTSTRAP_FRONTEND=winui` that launches a packaged WinUI frontend
(`frontend/WindowsTweaker.WinUI.exe`) next to the staged release when present, falling back
to the console entry point otherwise.
