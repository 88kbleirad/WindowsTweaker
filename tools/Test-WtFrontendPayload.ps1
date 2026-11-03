# WindowsTweaker - WindowsTweaker.WinUI publish payload validator.
#
# "Compilation succeeded" is not proof the GUI can start: WinUI 3 self-contained apps need
# the full Windows App SDK native payload next to the executable, and the worst failures
# (0xc000027b stowed exceptions in Microsoft.UI.Xaml.dll) are runtime-only. This script is
# the build-time half of that proof - it verifies the *presence* and *shape* of every file
# the XAML runtime requires, and the architecture of the native binaries. It does not run
# the app; the runtime proof is a manual launch on the target OS (docs/VALIDATION.md).
#
# Evidence for the required-file rules (pinned Windows App SDK 1.8.260921001 targets):
#   * MRT Core generates the app PRI as <TargetName>.pri (NOT resources.pri, which is only
#     the MSIX name) in TargetDir during Build; the .NET publish pipeline has no item that
#     carries it, so WindowsTweaker.WinUI.csproj explicitly adds it to output/publish.
#     This validator accepts resources.pri under -ProjectPriName resources.pri for app
#     projects that deliberately rename it, but the default is the SDK's name.
#   * The app-local WinUI/WindowsAppRuntime native payload is assembled by
#     AddMicrosoftWindowsAppSDKPayloadFilesFromComponents (Microsoft.WindowsAppSDK
#     .SelfContained.targets): *.dll, workloads*.json, restartAgent.exe, map.html,
#     *.mui, *.png, *.winmd, *.xaml, *.xbf, *.pri. DeploymentAgent.exe is NOT in that
#     set (its consumer, the DeploymentManager auto-initializer, is disabled when
#     WindowsAppSDKSelfContained=true), so it is deliberately not required here.
#   * `resources.pri` is never required as a publish file in unpackaged self-contained
#     mode; the app's own PRI is the .pri file named by -ProjectPriName.
#
# Usage:
#   pwsh -NoProfile -File tools/Test-WtFrontendPayload.ps1 -Path <publish-dir>
#   pwsh -NoProfile -File tools/Test-WtFrontendPayload.ps1 -Path <publish-dir> -ListMissing
#   pwsh -NoProfile -File tools/Test-WtFrontendPayload.ps1 -Path <publish-dir> -Inventory <file>
#
# Exit code 0: all required assets present with the required shape.
# Non-zero: failure; the message names exactly what is missing/mismatched.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,

    # The generated application PRI file name (relative to the publish root). Defaults to
    # the MRT Core unpackaged name: <targetname>.pri. Pass "resources.pri" only if the
    # app is actually published with that name.
    [string]$ProjectPriName = 'WindowsTweaker.WinUI.pri',

    # Print the full expected-asset list when validation fails (diagnosis aid).
    [switch]$ListMissing,

    # Write a recursive inventory (relative path + size) of the publish directory to this
    # file. Useful for diagnosing CI failures; written even when validation fails.
    [string]$Inventory = ''
)

$ErrorActionPreference = 'Stop'

if ($Inventory) {
    try {
        $InvFull = if ([System.IO.Path]::IsPathRooted($Inventory)) {
            [System.IO.Path]::GetFullPath($Inventory)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Inventory))
        }
        $InvDir = [System.IO.Path]::GetDirectoryName($InvFull)
        if (-not [System.IO.Directory]::Exists($InvDir)) {
            [System.IO.Directory]::CreateDirectory($InvDir) | Out-Null
        }
        $Lines = [System.Collections.Generic.List[string]]::new()
        $Lines.Add('# Publish inventory (relative path <tab> size bytes)')
        foreach ($File in Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction Stop) {
            $Rel = $File.FullName.Substring((Resolve-Path -LiteralPath $Path).Path.Length + 1) -replace '\\', '/'
            $Lines.Add("$Rel`t$($File.Length)")
        }
        [System.IO.File]::WriteAllLines($InvFull, $Lines)
    }
    catch {
        Write-Warning "Could not write inventory to '$Inventory': $_"
    }
}

$Expected = @(
    # The app itself and the managed side.
    'WindowsTweaker.WinUI.exe',
    'WindowsTweaker.WinUI.dll',
    'WindowsTweaker.WinUI.deps.json',
    'WindowsTweaker.WinUI.runtimeconfig.json',
    'WindowsTweaker.Gui.Core.dll',

    # The application's generated PRI file (MRT Core unpackaged name; see header).
    $ProjectPriName,

    # Engine payload (module + bridge host) - required by the packaged layout.
    'engine/WindowsTweaker.psd1',
    'engine/Bridge/wt-bridge.ps1',

    # Localization + catalog data. The engine serves the interface text through
    # `strings.get` from Data\Strings.<lang>.psd1 plus its part files, and registers the
    # catalog from Data\Catalog. Missing these makes every label render as [Key] and the
    # catalog empty while the handshake still succeeds - a published-payload regression
    # that compilation cannot catch.
    'engine/Data/Strings.en.psd1',
    'engine/Data/Strings.vi.psd1',
    'engine/Data/Strings.en.gui.psd1',
    'engine/Data/Strings.vi.gui.psd1',
    'engine/Data/Catalog/builtin.json',

    # Windows App SDK native runtime. The XAML runtime loads these from the app directory
    # (self-contained deployment); any gap here is a startup crash with a stowed exception.
    # This exact set is what AddMicrosoftWindowsAppSDKPayloadFilesFromComponents copies
    # (dll + restartAgent.exe + mui/png/winmd/xaml/xbf/pri; DeploymentAgent.exe excluded
    # because DeploymentManager is disabled for self-contained apps).
    'Microsoft.ui.xaml.dll',                       # the faulting module in the observed Event 1000
    'Microsoft.UI.Xaml.Controls.dll',
    'Microsoft.UI.Xaml.Controls.pri',
    'Microsoft.UI.Xaml.Internal.dll',
    'Microsoft.UI.Xaml.Phone.dll',
    'Microsoft.ui.xaml.resources.19h1.dll',
    'Microsoft.ui.xaml.resources.common.dll',
    'WinUIEdit.dll',
    'Microsoft.WindowsAppRuntime.dll',
    'Microsoft.Windows.ApplicationModel.Resources.dll',
    'MRM.dll',
    'Microsoft.WindowsAppRuntime.pri',
    'DWriteCore.dll',
    'Microsoft.UI.dll',
    'Microsoft.UI.Windowing.dll',
    'Microsoft.UI.Windowing.Core.dll',
    'Microsoft.UI.Input.dll',
    'CoreMessagingXP.dll',
    'Microsoft.UI.Composition.OSSupport.dll',
    'Microsoft.Graphics.Display.dll',
    'Microsoft.InputStateManager.dll',
    'Microsoft.Internal.FrameworkUdk.dll',
    'dcompi.dll',
    'dwmcorei.dll',
    'wuceffectsi.dll',
    'marshal.dll',
    'RestartAgent.exe',
    'PushNotificationsLongRunningTask.ProxyStub.dll'
)

$Missing = @()
foreach ($Relative in $Expected) {
    $Full = Join-Path $Path $Relative
    if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) {
        $Missing += $Relative
    }
}

if ($Missing.Count -gt 0) {
    'FAIL: required publish assets are missing:' | Write-Host -ForegroundColor Red
    foreach ($Relative in $Missing) {
        "  $Relative" | Write-Host -ForegroundColor Red
    }
    if ($ListMissing) {
        ''
        'All expected assets:'
        $Expected | ForEach-Object { "  $_" }
    }
    exit 1
}

# XAML runtime assets whose absence is a runtime-only failure; warn, but a missing one is
# not fatal to the presence proof (the language dirs are generated per runtime version).
$MuiDirs = @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^[a-z]{2}(-[A-Z]{2})?$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'Microsoft.UI.Xaml.dll.mui')) })
if ($MuiDirs.Count -lt 4) {
    "WARN: only $($MuiDirs.Count) language resource dirs found (expected ~130); download missing MUI files" | Write-Host -ForegroundColor Yellow
}

# Architecture consistency: the exe and the key native DLLs must have the same machine
# type. WinUI fails at runtime (not at load) when the arch of a dependency mismatches.
function Get-PEMachine {
    param([string]$File)
    $Bytes = [System.IO.File]::ReadAllBytes($File)
    if ($Bytes.Length -lt 64) { return 'invalid' }
    if ($Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { return 'not-pe' }
    $PeOffset = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($PeOffset -lt 0 -or $PeOffset + 24 -gt $Bytes.Length) { return 'invalid' }
    if ($Bytes[$PeOffset] -ne 0x50 -or $Bytes[$PeOffset + 1] -ne 0x45) { return 'not-pe' }
    # Machine field is at PE header + 4.
    return [BitConverter]::ToUInt16($Bytes, $PeOffset + 4)
}

$MachineNames = @{ 0x8664 = 'x64'; 0x014c = 'x86'; 0xAA64 = 'arm64' }
function Get-MachineLabel {
    param([int]$Machine)
    if ($MachineNames.ContainsKey($Machine)) { return $MachineNames[$Machine] }
    return ('0x{0:X}' -f $Machine)
}
$ArchFiles = @('WindowsTweaker.WinUI.exe', 'Microsoft.ui.xaml.dll', 'Microsoft.WindowsAppRuntime.dll', 'Microsoft.UI.dll')
$ArchMismatches = @()
$SeenMachine = $null
foreach ($Relative in $ArchFiles) {
    $Machine = Get-PEMachine (Join-Path $Path $Relative)
    if ($Machine -eq 'not-pe' -or $Machine -eq 'invalid') {
        $ArchMismatches += "$Relative has no valid PE header (machine=$Machine)"
        continue
    }
    if ($null -eq $SeenMachine) { $SeenMachine = $Machine }
    elseif ($Machine -ne $SeenMachine) {
        $ArchMismatches += "$Relative is $(Get-MachineLabel $Machine), payload is $(Get-MachineLabel $SeenMachine)"
    }
}

if ($ArchMismatches.Count -gt 0) {
    'FAIL: architecture mismatch in the native payload:' | Write-Host -ForegroundColor Red
    foreach ($Message in $ArchMismatches) {
        "  $Message" | Write-Host -ForegroundColor Red
    }
    exit 1
}

$MachineLabel = Get-MachineLabel $SeenMachine
"OK: $($Expected.Count) required assets present, architecture consistent ($MachineLabel)." | Write-Host -ForegroundColor Green
exit 0
