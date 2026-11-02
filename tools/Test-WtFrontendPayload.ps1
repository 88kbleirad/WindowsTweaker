# WindowsTweaker - WindowsTweaker.WinUI publish payload validator.
#
# "Compilation succeeded" is not proof the GUI can start: WinUI 3 self-contained apps need
# the full Windows App SDK native payload next to the executable, and the worst failures
# (0xc000027b stowed exceptions in Microsoft.UI.Xaml.dll) are runtime-only. This script is
# the build-time half of that proof - it verifies the *presence* and *shape* of every file
# the XAML runtime requires, and the architecture of the native binaries. It does not run
# the app; the runtime proof is a manual launch on the target OS (docs/VALIDATION.md).
#
# Usage:
#   pwsh -NoProfile -File tools/Test-WtFrontendPayload.ps1 -Path <publish-dir>
#   pwsh -NoProfile -File tools/Test-WtFrontendPayload.ps1 -Path <publish-dir> -ListMissing
#
# Exit code 0: all required assets present with the required shape.
# Non-zero: failure; the message names exactly what is missing/mismatched.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,

    # Print the full expected-asset list when validation fails (diagnosis aid).
    [switch]$ListMissing
)

$ErrorActionPreference = 'Stop'

$Expected = @(
    # The app itself and the managed side.
    'WindowsTweaker.WinUI.exe',
    'WindowsTweaker.WinUI.dll',
    'WindowsTweaker.WinUI.deps.json',
    'WindowsTweaker.WinUI.runtimeconfig.json',
    'WindowsTweaker.Gui.Core.dll',
    'resources.pri',

    # Engine payload (module + bridge host) - required by the packaged layout.
    'engine/WindowsTweaker.psd1',
    'engine/Bridge/wt-bridge.ps1',

    # Windows App SDK native runtime. The XAML runtime loads these from the app directory
    # (self-contained deployment); any gap here is a startup crash with a stowed exception.
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
    'DeploymentAgent.exe',
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

$MachineLabel = $MachineNames[$SeenMachine] ?? ('0x{0:X}' -f $SeenMachine)
"OK: $($Expected.Count) required assets present, architecture consistent ($MachineLabel)." | Write-Host -ForegroundColor Green
exit 0
