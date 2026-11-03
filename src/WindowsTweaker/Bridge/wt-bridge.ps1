# WindowsTweaker - bridge host process (stdin/stdout JSON-Lines server).
#
# This is the process the WinUI 3 frontend spawns and talks to. It is a long-lived
# backend session: the module is imported once, and every request reuses that session -
# no per-click powershell.exe, no per-click module import.
#
# Protocol (v1):
#   * stdout is the protocol channel: one JSON object per line, UTF-8, LF-terminated.
#     Nothing else is ever written to stdout (logging is file-only, preferences are
#     silenced, and the only escape is the fatal error banner at the very bottom).
#   * stdin carries requests, one JSON object per line, with the same bounds.
#   * Diagnostics (host banner, fatal errors) go to stderr only.
#   * The first frame is the hello frame; the last frame is the bye frame.
#
# Requests:
#   { "id": "<client-generated>", "op": "<allowlisted op>", "args": { ... } }
#
# Results / events:
#   { "type": "result",   "id": "...", "ok": true, "data": ... }
#   { "type": "error",    "id": "...", "code": "...", "message": "..." }
#   { "type": "progress",  "id": "...", "phase": "...", ... }
#   { "type": "notice",    "kind": "...", "data": ... }
#
# The allowlist, the bounds and the frame shapes live in BridgeProtocol.ps1; the task
# runner lives in BridgeTasks.ps1. This file only owns the process loop.

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)][string]$ModuleManifest = ''
)

$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Locates the module manifest. The bridge entry point lives beside the module directory
    (src/WindowsTweaker/Bridge/wt-bridge.ps1), so the manifest is its parent's sibling.
#>
function Resolve-WtBridgeModuleManifest
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Given = '')

    if ($Given) { return [System.IO.Path]::GetFullPath($Given) }
    return (Join-Path (Split-Path $PSScriptRoot -Parent) 'WindowsTweaker.psd1')
}

$BridgeManifest = Resolve-WtBridgeModuleManifest -Given $ModuleManifest
if (-not (Test-Path -LiteralPath $BridgeManifest))
{
    [Console]::Error.WriteLine("bridge: module manifest not found: $BridgeManifest")
    exit 70
}

# The protocol, task runner and projection helpers are module-private files: the module
# loader dot-sources them, and this host dot-sources the same text so the framing
# functions exist in its own scope too (one implementation, two hosts).
$ModuleRoot = Split-Path $BridgeManifest -Parent
$BridgeProtocolPath = Join-Path $ModuleRoot 'Private/Bridge/BridgeProtocol.ps1'
$BridgeTasksPath = Join-Path $ModuleRoot 'Private/Bridge/BridgeTasks.ps1'
$BridgeDtoPath = Join-Path $ModuleRoot 'Private/Bridge/BridgeDto.ps1'
. $BridgeProtocolPath
. $BridgeTasksPath
. $BridgeDtoPath

# Unicode safety for the console streams (the protocol is UTF-8 on both sides). On
# Windows the default console code page would otherwise garble Vietnamese text.
try
{
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
}
catch { $null = $_ }

# The host never prompts. A question would block forever because stdin belongs to the
# frontend, so confirmation is the caller's job and every engine prompt is suppressed.
$ConfirmPreference = 'None'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

# Flush the banner to stderr before any protocol frame (it is diagnostics, not data).
[Console]::Error.WriteLine("bridge: starting protocol $($Script:WtBridgeProtocolVersion) for $BridgeManifest")

# Host facts, on stderr only, before the engine is imported. This is what makes a startup
# failure self-diagnosing: when the module cannot be imported, the reason is usually that
# this host cannot see its own core modules (a Windows PowerShell 5.1 process that
# inherited a PowerShell 7 PSModulePath resolves Microsoft.PowerShell.Utility from the 7.x
# copy and loses Import-PowerShellDataFile), and these lines say exactly which executable
# and which module path were in effect. stderr is diagnostics by contract; stdout carries
# protocol frames only and is never written here.
try
{
    $DiagImport = Get-Command -Name 'Import-PowerShellDataFile' -ErrorAction SilentlyContinue
    $DiagUtility = @()
    try
    {
        $DiagUtility = @(Get-Module -Name 'Microsoft.PowerShell.Utility' -ListAvailable -ErrorAction SilentlyContinue |
            ForEach-Object { "$($_.Version):$($_.Path)" })
    }
    catch { $null = $_ }

    [Console]::Error.WriteLine("bridge: host exe=$([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)")
    [Console]::Error.WriteLine("bridge: host version=$($PSVersionTable.PSVersion) edition=$($PSVersionTable.PSEdition) bitness=$([IntPtr]::Size * 8)")
    [Console]::Error.WriteLine("bridge: host pshome=$PSHOME")
    [Console]::Error.WriteLine("bridge: host psmodulepath=$env:PSModulePath")
    [Console]::Error.WriteLine("bridge: host psmoduleautoloadingpreference=$($PSModuleAutoLoadingPreference)")
    [Console]::Error.WriteLine("bridge: host import-powershelldatafile=$(if ($DiagImport) { $DiagImport.Source } else { '<not found>' })")
    [Console]::Error.WriteLine("bridge: host utility-modules=$($DiagUtility -join '; ')")
}
catch
{
    # Diagnostics must never stop the host.
    [Console]::Error.WriteLine("bridge: host diagnostics failed: $($_.Exception.Message)")
}

$Module = $null
try
{
    $Module = Import-Module -Name $BridgeManifest -Force -PassThru -ErrorAction Stop
}
catch
{
    # The full import failure, on stderr, before the process exits: the client shows the
    # stderr tail with its "exited before its handshake" report, so a startup failure names
    # the command, the file and the position instead of only reporting the exit.
    [Console]::Error.WriteLine("bridge: module import failed: $($_.Exception.ToString())")
    if ($_.ScriptStackTrace) { [Console]::Error.WriteLine("bridge: module import stack: $($_.ScriptStackTrace)") }
    [Console]::Error.WriteLine("bridge: module import command ($($_.InvocationInfo.MyCommand)): $($_.InvocationInfo.PositionMessage)")
    exit 71
}

& $Module {
    Initialize-WtLogging -Console $false | Out-Null
    Initialize-WtLocalization | Out-Null
}

$Session = New-WtBridgeSession

# Elevation is read once, through the module's exported surface (the private profile
# helper is not visible outside module scope). A privileged operation is refused here,
# before anything runs, so the boundary is enforced by the backend and not only by the UI.
$IsAdmin = [bool](Get-WtEnvironment).IsAdmin

# ---- stdin handling -----------------------------------------------------------
# `Console.In.ReadLineAsync()` is polled from the main loop instead of parking a reader
# thread in a blocking read. Two reasons, both measured here:
#   * a reader runspace whose thread sits in a blocking read keeps the process alive after
#     the loop ends (the host never exited);
#   * `PowerShell.Stop()` on that pipeline blocks until the read returns - which it does
#     not while the client still owns the pipe.
# Polling one line at a time also gives the bounded-request property for free: the pipe
# itself is the queue, and the frontend cannot make the host buffer unbounded input.

$StdinStream = [Console]::OpenStandardInput()
$StdinReader = New-Object System.IO.StreamReader($StdinStream, (New-Object System.Text.UTF8Encoding($false)))
$PendingRead = $StdinReader.ReadLineAsync()

<#
.SYNOPSIS
    Normalises a JSON value into plain hashtables / arrays (no PSCustomObject), so the
    consumers in the task runner and the inline dispatcher work on one shape.
#>
function ConvertTo-WtBridgeInputValue
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Array])
    {
        $List = [System.Collections.Generic.List[object]]::new()
        foreach ($Item in $Value) { $List.Add((ConvertTo-WtBridgeInputValue -Value $Item)) }
        return $List.ToArray()
    }
    if ($Value -is [psobject] -and $Value.psobject.Properties.Count -gt 0)
    {
        $Map = @{}
        foreach ($Property in $Value.psobject.Properties)
        {
            $Map[$Property.Name] = ConvertTo-WtBridgeInputValue -Value $Property.Value
        }
        return $Map
    }
    return $Value
}

<#
.SYNOPSIS
    Parses one request line into a normalised request map, or an error marker.
.OUTPUTS
    A hashtable: { kind = 'request'|'error'; ... }.
#>
function ConvertFrom-WtBridgeInputLine
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Line)

    if ($Line.Length -gt $Script:WtBridgeMaxLineBytes)
    {
        return @{ kind = 'error'; code = 'FrameTooLarge'; message = "A request line exceeded the $($Script:WtBridgeMaxLineBytes)-byte bound and was discarded." }
    }

    $Request = $null
    try
    {
        $Request = ConvertFrom-Json -InputObject $Line
    }
    catch
    {
        return @{ kind = 'error'; code = 'InvalidRequest'; message = "A request was not valid JSON and was discarded: $($_.Exception.Message)" }
    }

    if ($null -eq $Request -or $Request -isnot [psobject])
    {
        return @{ kind = 'error'; code = 'InvalidRequest'; message = 'A request was not a JSON object and was discarded.' }
    }

    $Map = @{}
    foreach ($Property in $Request.psobject.Properties)
    {
        $Map[$Property.Name] = ConvertTo-WtBridgeInputValue -Value $Property.Value
    }
    return @{ kind = 'request'; request = $Map }
}

# ---- helpers ------------------------------------------------------------------

function Write-WtBridgeFrames
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object[]]$Frames)

    foreach ($Frame in $Frames) { Write-WtBridgeFrame -Payload $Frame }
}

function New-WtBridgeHelloFrame
{
    [CmdletBinding()]
    param ()

    $Ops = Get-WtBridgeOperations

    # moduleVersion is the WindowsTweaker module's own version - the code the session is
    # running - not the PowerShell runtime's. The runtime has its own field (`powerShell`),
    # and reporting the runtime version as the engine version made the frontend's Overview
    # print the PowerShell version twice. The loaded module is authoritative (it is what is
    # actually loaded, even when the manifest resolved from elsewhere); the manifest is the
    # fallback when the module object is not available.
    $ModuleVersion = ''
    if ($null -ne $Module -and $Module.Version)
    {
        $ModuleVersion = [string]$Module.Version
    }
    if (-not $ModuleVersion -and (Test-Path -LiteralPath $BridgeManifest -PathType Leaf))
    {
        $ModuleVersion = [string](Import-PowerShellDataFile -LiteralPath $BridgeManifest).ModuleVersion
    }

    return [ordered]@{
        type = 'hello'
        protocol = $Script:WtBridgeProtocolVersion
        bridge = 'wt-bridge'
        engine = [ordered]@{
            moduleVersion = $ModuleVersion
            powerShell = $PSVersionTable.PSVersion.ToString()
            edition = $PSVersionTable.PSEdition
            platform = [string](Get-WtRuntimeInfo).Profile.Platform
            architecture = [string](Get-WtRuntimeInfo).Profile.Architecture
            tier = [string](Get-WtRuntimeInfo).Profile.Tier
            isWindows = [bool](Get-WtRuntimeInfo).Profile.IsWindows
            isAdmin = [bool](Get-WtEnvironment).IsAdmin
        }
        ops = @($Ops.Keys | Sort-Object)
        guiKeys = @(Get-WtBridgeGuiStringKeys)
        limits = [ordered]@{
            maxFrameBytes = $Script:WtBridgeMaxLineBytes
            maxPending = $Script:WtBridgeMaxPendingRequests
            taskEventCap = $Script:WtBridgeTaskEventCap
        }
    }
}

function Invoke-WtBridgeInline
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$Session,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$OpArgs
    )

    switch ($Name)
    {
        'handshake'
        {
            return (New-WtBridgeResultFrame -Id $Id -Data (New-WtBridgeHelloFrame))
        }
        'ping'
        {
            return (New-WtBridgeResultFrame -Id $Id -Data @{ pong = $true; utc = (Get-Date).ToUniversalTime().ToString('o') })
        }
        'strings.get'
        {
            $Strings = & $Module {
                $Langs = @(Get-WtSupportedLanguages)
                $Tables = @{}
                foreach ($Lang in $Langs) { $Tables[$Lang] = Read-WtStringTable -Code $Lang }
                [pscustomobject]@{
                    languages = $Langs
                    active = (Get-WtLanguage)
                    tables = $Tables
                }
            }
            return (New-WtBridgeResultFrame -Id $Id -Data $Strings)
        }
        'env.status'
        {
            $Env = Get-WtEnvironment
            $Runtime = Get-WtRuntimeInfo
            return (New-WtBridgeResultFrame -Id $Id -Data @{
                environment = $Env
                runtime = $Runtime
            })
        }
        'catalog.list'
        {
            $Definitions = @(Get-WtTweakDefinitionView | ForEach-Object { ConvertTo-WtBridgeCatalogRow -Row $_ })
            $Categories = @(Get-WtCategory)
            return (New-WtBridgeResultFrame -Id $Id -Data @{
                categories = $Categories
                tweaks = $Definitions
            })
        }
        'preset.export'
        {
            $Entries = @(Get-WtBridgeArrayParam -Map $OpArgs -Name 'entries')
            $Name = Get-WtBridgeStringParam -Map $OpArgs -Name 'name'
            $Path = Get-WtBridgeStringParam -Map $OpArgs -Name 'path'
            $Params = @{ Entries = $Entries; Path = $Path }
            if ($Name) { $Params['Name'] = $Name }
            $Result = Export-WtPreset @Params
            return (New-WtBridgeResultFrame -Id $Id -Data $Result)
        }
        'monitor.defaults'
        {
            return (New-WtBridgeResultFrame -Id $Id -Data (Get-WtMonitorDefaults))
        }
        'dashboard.list'
        {
            return (New-WtBridgeResultFrame -Id $Id -Data @(Get-WtDashboardList))
        }
        'dashboard.get'
        {
            $DashboardId = Get-WtBridgeStringParam -Map $OpArgs -Name 'id'
            return (New-WtBridgeResultFrame -Id $Id -Data (Get-WtDashboard -Id $DashboardId))
        }
        'restart.test'
        {
            $Requested = Get-WtBridgeBoolParam -Map $OpArgs -Name 'requested'
            $Preview = Get-WtBridgeBoolParam -Map $OpArgs -Name 'preview'
            $ReadOnly = Get-WtBridgeBoolParam -Map $OpArgs -Name 'readOnly'
            $Decision = Test-WtRestartRequest -Requested:$Requested -Preview:$Preview -ReadOnly:$ReadOnly
            return (New-WtBridgeResultFrame -Id $Id -Data $Decision)
        }
        'metrics.snapshot'
        {
            $Drive = Get-WtBridgeStringParam -Map $OpArgs -Name 'drive'
            $Snapshot = & $Module { param ($Disk) Get-WtMetricOverviewSnapshot -Drive $Disk } $Drive
            return (New-WtBridgeResultFrame -Id $Id -Data $Snapshot)
        }
        'language.set'
        {
            $Language = Get-WtBridgeStringParam -Map $OpArgs -Name 'language'
            $Params = @{ Language = $Language }
            $Result = Set-WtLanguage @Params
            return (New-WtBridgeResultFrame -Id $Id -Data $Result)
        }
        'exttool.setmethod'
        {
            $MethodId = Get-WtBridgeStringParam -Map $OpArgs -Name 'method'
            $Result = & $Module { param ($Id) Set-WtWindowsActivationMethodSetting -Id $Id } $MethodId
            return (New-WtBridgeResultFrame -Id $Id -Data $Result)
        }
        'cancel'
        {
            $Target = Get-WtBridgeStringParam -Map $OpArgs -Name 'target'
            $Stopped = Stop-WtBridgeTask -Session $Session -Id $Target
            return (New-WtBridgeResultFrame -Id $Id -Data @{ stopped = $Stopped })
        }
        'quit'
        {
            return (New-WtBridgeResultFrame -Id $Id -Data @{ bye = $true })
        }
        default
        {
            return (New-WtBridgeErrorFrame -Id $Id -Code 'UnknownOperation' -Message "Operation '$Name' is not in the allowlist.")
        }
    }
}

# ---- the main loop ------------------------------------------------------------

$Quit = $false
Write-WtBridgeFrame -Payload (New-WtBridgeHelloFrame)

while (-not $Quit)
{
    # 1. Drain finished tasks into frames.
    $Frames = Receive-WtBridgeTaskFrames -Session $Session
    if ($Frames.Count -gt 0) { Write-WtBridgeFrames -Frames $Frames }

    # 2. Poll stdin: handle exactly one line when one has arrived.
    $HaveLine = $false
    $Line = $null
    if ($null -ne $PendingRead -and $PendingRead.IsCompleted)
    {
        try { $Line = $PendingRead.Result } catch { $Line = $null }
        $PendingRead = $null
        $HaveLine = $true
    }

    if ($HaveLine)
    {
        # A null line means the client closed the pipe (EOF).
        if ($null -eq $Line)
        {
            # The frontend closed stdin: let running tasks reach a safe boundary, drain
            # their final frames, then exit.
            $ShutdownDeadline = [datetime]::UtcNow.AddSeconds(20)
            foreach ($Id in @($Session.Tasks.Keys)) { $Session.Tasks[$Id].Cancel.Requested = $true }
            while ([datetime]::UtcNow -lt $ShutdownDeadline -and $Session.Tasks.Count -gt 0)
            {
                $Frames = Receive-WtBridgeTaskFrames -Session $Session
                if ($Frames.Count -gt 0) { Write-WtBridgeFrames -Frames $Frames }
                if ($Session.Tasks.Count -gt 0) { Start-Sleep -Milliseconds 100 }
            }
            Stop-WtBridgeAllTasks -Session $Session -TimeoutMs 5000
            $Frames = Receive-WtBridgeTaskFrames -Session $Session
            if ($Frames.Count -gt 0) { Write-WtBridgeFrames -Frames $Frames }
            $Quit = $true
            continue
        }

        # Start the next read immediately (the pipe supplies the backpressure).
        $PendingRead = $StdinReader.ReadLineAsync()

        $Parsed = ConvertFrom-WtBridgeInputLine -Line $Line
        if ($Parsed.kind -eq 'error')
        {
            Write-WtBridgeFrame -Payload (New-WtBridgeErrorFrame -Id '' -Code $Parsed.code -Message $Parsed.message)
            continue
        }

        $Request = $Parsed.request
        $Id = Get-WtBridgeStringParam -Map $Request -Name 'id'
        $Name = Get-WtBridgeStringParam -Map $Request -Name 'op'
        $OpArgs = Get-WtBridgeHashtableParam -Map $Request -Name 'args'
        if (-not $OpArgs) { $OpArgs = @{} }

        if (-not $Id)
        {
            Write-WtBridgeFrame -Payload (New-WtBridgeErrorFrame -Id '' -Code 'MissingId' -Message 'Every request must carry a non-empty id.')
            continue
        }

        $Operation = Get-WtBridgeOperation -Name $Name
        if (-not $Operation)
        {
            Write-WtBridgeFrame -Payload (New-WtBridgeErrorFrame -Id $Id -Code 'UnknownOperation' -Message "Operation '$Name' is not in the allowlist.")
            continue
        }

        if ($Operation.Privileged -and -not $IsAdmin)
        {
            Write-WtBridgeFrame -Payload (New-WtBridgeErrorFrame -Id $Id -Code 'RequiresElevation' -Message 'This operation needs an elevated backend session.')
            continue
        }

        # Mutating tasks are single-flight by construction (the runner refuses a second
        # one); non-mutating tasks run concurrently but the queue stays bounded.
        if ($Operation.Worker)
        {
            $Task = Start-WtBridgeTask -Session $Session -Id $Id -Name $Name -Options $OpArgs -ModulePath $BridgeManifest
            if (-not $Task)
            {
                Write-WtBridgeFrame -Payload (New-WtBridgeErrorFrame -Id $Id -Code 'Busy' -Message 'Another mutating operation is already running in this session.')
            }
            continue
        }

        # Inline (fast) operation.
        $Frame = Invoke-WtBridgeInline -Session $Session -Id $Id -Name $Name -OpArgs $OpArgs
        Write-WtBridgeFrame -Payload $Frame
        if ($Name -eq 'quit')
        {
            $ShutdownDeadline = [datetime]::UtcNow.AddSeconds(20)
            foreach ($TaskId in @($Session.Tasks.Keys)) { $Session.Tasks[$TaskId].Cancel.Requested = $true }
            while ([datetime]::UtcNow -lt $ShutdownDeadline -and $Session.Tasks.Count -gt 0)
            {
                $Frames = Receive-WtBridgeTaskFrames -Session $Session
                if ($Frames.Count -gt 0) { Write-WtBridgeFrames -Frames $Frames }
                if ($Session.Tasks.Count -gt 0) { Start-Sleep -Milliseconds 100 }
            }
            Stop-WtBridgeAllTasks -Session $Session -TimeoutMs 5000
            $Frames = Receive-WtBridgeTaskFrames -Session $Session
            if ($Frames.Count -gt 0) { Write-WtBridgeFrames -Frames $Frames }
            $Quit = $true
        }
    }
    else
    {
        # No line yet and no task output: wait briefly, never spin hot. The pending read
        # completes on a thread-pool thread, so nothing here blocks the loop.
        Start-Sleep -Milliseconds 15
    }
}

# ---- shutdown -----------------------------------------------------------------
Write-WtBridgeFrame -Payload (New-WtBridgeNoticeFrame -Kind 'bye')

# Any read still in flight is abandoned: the process is ending, the client owns the pipe
# and nothing in this process reads it again.
try { $null = Close-WtSession } catch { $null = $_ }
[Console]::Error.WriteLine('bridge: clean shutdown')
