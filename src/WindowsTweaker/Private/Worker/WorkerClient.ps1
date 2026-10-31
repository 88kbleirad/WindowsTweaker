# WindowsTweaker - optional background worker client (process side only).
#
# This file is the PowerShell half of the worker protocol: it locates the binary, performs
# the capability handshake, sends one request at a time, drains the worker's output
# asynchronously, and shuts the process down with a bounded wait.
#
# Rules this file follows:
#   * presentation stays in PowerShell: the worker returns structured error codes and data,
#     and every user-facing string is a Get-WtString key;
#   * stdout of the worker is protocol only - it is parsed as JSON lines and never rendered;
#   * the worker is never looked up on PATH: the path is application-controlled (see
#     Get-WtWorkerBackendPath);
#   * a transport failure is reported as a failure. A completed operation is never repeated,
#     and a result is never fabricated;
#   * one writer: all requests go through Write-WtWorkerMessage, so messages cannot interleave.

$Script:WtWorkerProtocolVersion = 1
$Script:WtWorkerCapabilityNames = @('scan.directory')
$Script:WtWorkerMaxLineBytes = 1MB
$Script:WtWorkerInfoCache = $null

<#
.SYNOPSIS
    Resolves the worker binary path.
.DESCRIPTION
    The location is deliberately explicit and application-controlled, never a PATH lookup:
      1. $env:WT_WORKER_PATH                     (packaging override, used by tests)
      2. <repository>/worker/bin/<os>-<arch>/wt-worker[.exe]
    Returns '' when the file does not exist, so callers can report "not installed" instead of
    failing with a path error.
#>
function Get-WtWorkerBackendPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($env:WT_WORKER_PATH)
    {
        return $env:WT_WORKER_PATH
    }

    $Name = if ($IsWindows) { 'wt-worker.exe' } else { 'wt-worker' }
    $Platform = if ($IsWindows) { 'windows' } else { 'linux' }
    $Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)
    {
        'X64' { 'amd64' }
        'Arm64' { 'arm64' }
        default { 'amd64' }
    }

    $Candidate = Join-Path $Script:WtProjectRoot ("worker/bin/{0}-{1}/{2}" -f $Platform, $Architecture, $Name)
    if (Test-Path -LiteralPath $Candidate -PathType Leaf)
    {
        return $Candidate
    }

    # A development build next to the module is accepted as well, but never a PATH search.
    $Development = Join-Path $Script:WtProjectRoot ("worker/bin/{0}" -f $Name)
    if (Test-Path -LiteralPath $Development -PathType Leaf)
    {
        return $Development
    }

    return ''
}

<#
.SYNOPSIS
    Reports whether the worker is installed and speaks this protocol.
.DESCRIPTION
    Every failure mode is distinguished, because the interface has to explain it:
      NotInstalled - no binary at the application-controlled path
      NotExecutable - the file exists but cannot be started
      Incompatible - the handshake reported another protocol version
      MissingCapability - the worker does not implement a capability the client needs
      NoHandshake - the worker did not answer, or answered something unparsable
.OUTPUTS
    @{ Available; Path; Reason; Code; Protocol; Version; Capabilities }
#>
function Test-WtWorkerAvailable
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][switch]$Force,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 4000
    )

    $Result = @{
        Available    = $false
        Path         = ''
        Reason       = ''
        Code         = ''
        Protocol     = 0
        Version      = ''
        Capabilities = @()
    }

    $Path = Get-WtWorkerBackendPath
    $Result.Path = $Path
    if (-not $Path)
    {
        $Result.Code = 'NotInstalled'
        $Result.Reason = Get-WtString -Key 'Worker.Reason.NotInstalled'
        return $Result
    }

    if ($Script:WtWorkerInfoCache -and -not $Force)
    {
        $Cached = $Script:WtWorkerInfoCache
        return @{
            Available    = $Cached.Available
            Path         = $Path
            Reason       = $Cached.Reason
            Code         = $Cached.Code
            Protocol     = $Cached.Protocol
            Version      = $Cached.Version
            Capabilities = $Cached.Capabilities
        }
    }

    $Client = $null
    try
    {
        $Client = Start-WtWorkerClient -TimeoutMs $TimeoutMs
        $Hello = $Client.Hello
        $Result.Protocol = [int]$Hello.protocol
        $Result.Version = [string]$Hello.version
        $Result.Capabilities = @($Hello.capabilities)

        if ($Result.Protocol -ne $Script:WtWorkerProtocolVersion)
        {
            $Result.Code = 'Incompatible'
            $Result.Reason = Get-WtString -Key 'Worker.Reason.Incompatible' -Arguments @($Result.Protocol, $Script:WtWorkerProtocolVersion)
        }
        else
        {
            $Missing = @($Script:WtWorkerCapabilityNames | Where-Object { $Result.Capabilities -notcontains $_ })
            if ($Missing.Count -gt 0)
            {
                $Result.Code = 'MissingCapability'
                $Result.Reason = Get-WtString -Key 'Worker.Reason.MissingCapability' -Arguments @(($Missing -join ', '))
            }
            else
            {
                $Result.Available = $true
                $Result.Code = 'Available'
            }
        }
    }
    catch
    {
        $Result.Code = 'NoHandshake'
        $Result.Reason = Get-WtString -Key 'Worker.Reason.NoHandshake' -Arguments @($_.Exception.Message)
    }
    finally
    {
        if ($Client) { Stop-WtWorkerClient -Client $Client | Out-Null }
    }

    $Script:WtWorkerInfoCache = $Result
    return $Result
}

<#
.SYNOPSIS
    Starts the worker and completes the handshake.
.DESCRIPTION
    The process is unprivileged, has no window, gets redirected pipes and is never asked to
    read a key. Output is read asynchronously on .NET event threads into a thread-safe queue;
    the interface drains that queue, so no worker I/O ever blocks the UI owner.
.PARAMETER TimeoutMs
    How long to wait for the handshake before giving up.
#>
function Start-WtWorkerClient
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][int]$TimeoutMs = 4000)

    $Path = Get-WtWorkerBackendPath
    if (-not $Path)
    {
        throw (Get-WtString -Key 'Worker.Reason.NotInstalled')
    }

    $StartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = $Path
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardInput = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $StartInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    $Process = $null
    try
    {
        $Process = [System.Diagnostics.Process]::Start($StartInfo)
    }
    catch
    {
        throw (Get-WtString -Key 'Worker.Reason.NotExecutable' -Arguments @($Path, $_.Exception.Message))
    }

    $Client = @{
        Path        = $Path
        Process     = $Process
        Queue       = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Stderr      = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        MaxStderr   = 64
        Overflow    = $false
        Exited      = $false
        ExitCode    = $null
        Hello       = $null
        Requests    = @{}
        # Chained asynchronous reads: one pending ReadLineAsync task per stream. Event handlers
        # (Register-ObjectEvent -Action) are deliberately not used: they execute in a separate
        # runspace, where this client object does not exist, so the reader would silently do
        # nothing.
        PendingOut  = $null
        PendingErr  = $null
    }

    $Client.PendingOut = $Process.StandardOutput.ReadLineAsync()
    $Client.PendingErr = $Process.StandardError.ReadLineAsync()

    try
    {
        $Hello = Invoke-WtWorkerRoundTrip -Client $Client -Message @{ v = $Script:WtWorkerProtocolVersion; id = 'handshake'; op = 'hello' } -TimeoutMs $TimeoutMs
        if ($null -eq $Hello.Hello)
        {
            throw (Get-WtString -Key 'Worker.Reason.NoHandshake' -Arguments @('the worker did not answer the handshake'))
        }

        $Client.Hello = $Hello.Hello
    }
    catch
    {
        Stop-WtWorkerClient -Client $Client | Out-Null
        throw
    }

    return $Client
}

<#
.SYNOPSIS
    Writes one request message (the single serialised writer).
#>
function Write-WtWorkerMessage
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][hashtable]$Message
    )

    if ($Client.Process.HasExited)
    {
        throw (Get-WtString -Key 'Worker.Reason.Exited' -Arguments @($Client.Process.ExitCode))
    }

    $Payload = $Message | ConvertTo-Json -Depth 8 -Compress
    if ($Payload.Length -gt $Script:WtWorkerMaxLineBytes)
    {
        throw (Get-WtString -Key 'Worker.Reason.RequestTooLarge' -Arguments @($Payload.Length, $Script:WtWorkerMaxLineBytes))
    }

    try
    {
        $Client.Process.StandardInput.WriteLine($Payload)
        $Client.Process.StandardInput.Flush()
    }
    catch
    {
        throw (Get-WtString -Key 'Worker.Reason.BrokenPipe' -Arguments @($_.Exception.Message))
    }
}

<#
.SYNOPSIS
    Drains one queued event from the worker.
.OUTPUTS
    @{ Kind = 'Message'|'ProtocolError'|'Exited'; ... } or $null when nothing is queued.
#>
function Read-WtWorkerEvent
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Client)

    # Pull whatever the asynchronous readers have already produced. This never blocks: a task
    # that has not completed yet is simply left pending for the next call.
    while ($Client.PendingOut -and $Client.PendingOut.IsCompleted)
    {
        $Line = $null
        try
        {
            $Line = [string]$Client.PendingOut.GetAwaiter().GetResult()
        }
        catch
        {
            $Client.Queue.Enqueue(@{ Kind = 'ProtocolError'; Code = 'E_IO'; Detail = $_.Exception.Message })
        }

        $Client.PendingOut = $null
        if (-not $Client.Process.HasExited)
        {
            try { $Client.PendingOut = $Client.Process.StandardOutput.ReadLineAsync() }
            catch { $Client.PendingOut = $null }
        }

        if ($null -eq $Line) { break }

        if ($Line.Length -gt $Script:WtWorkerMaxLineBytes)
        {
            # Bigger than the documented ceiling: a protocol violation. It is reported as an
            # error event and never parsed, so a rogue worker cannot exhaust memory.
            $Client.Overflow = $true
            $Client.Queue.Enqueue(@{ Kind = 'ProtocolError'; Code = 'E_MESSAGE_TOO_LARGE'; Detail = "line of $($Line.Length) bytes" })
            continue
        }

        try
        {
            $Message = $Line | ConvertFrom-Json -Depth 16 -ErrorAction Stop
            $Client.Queue.Enqueue(@{ Kind = 'Message'; Message = $Message })
        }
        catch
        {
            $Client.Queue.Enqueue(@{ Kind = 'ProtocolError'; Code = 'E_BAD_JSON'; Detail = $_.Exception.Message })
        }
    }

    while ($Client.PendingErr -and $Client.PendingErr.IsCompleted)
    {
        $Line = $null
        try { $Line = [string]$Client.PendingErr.GetAwaiter().GetResult() } catch { $Line = $null }

        $Client.PendingErr = $null
        if (-not $Client.Process.HasExited)
        {
            try { $Client.PendingErr = $Client.Process.StandardError.ReadLineAsync() }
            catch { $Client.PendingErr = $null }
        }

        if ($null -eq $Line) { break }

        $Client.Stderr.Enqueue($Line)
        while ($Client.Stderr.Count -gt $Client.MaxStderr) { $null = $Client.Stderr.TryDequeue([ref]$null) }
    }

    $Item = $null
    if ($Client.Queue.TryDequeue([ref]$Item))
    {
        return $Item
    }

    if ($Client.Process.HasExited -and -not $Client.Exited)
    {
        $Client.Exited = $true
        $Client.ExitCode = $Client.Process.ExitCode
        $Stderr = @($Client.Stderr.ToArray())
        return @{
            Kind     = 'Exited'
            ExitCode = $Client.ExitCode
            Stderr   = $Stderr
        }
    }

    return $null
}

<#
.SYNOPSIS
    Sends one request and returns the request id.
#>
function Send-WtWorkerRequest
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $false)][hashtable]$Parameters,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 0
    )

    $RequestId = [guid]::NewGuid().ToString('n')
    $Message = @{ v = $Script:WtWorkerProtocolVersion; id = $RequestId; op = $Operation }
    if ($Parameters) { $Message.params = $Parameters }
    if ($TimeoutMs -gt 0) { $Message.timeoutMs = $TimeoutMs }

    $Client.Requests[$RequestId] = $Operation
    Write-WtWorkerMessage -Client $Client -Message $Message
    return $RequestId
}

<#
.SYNOPSIS
    Asks the worker to cancel a running request.
#>
function Send-WtWorkerCancel
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$RequestId
    )

    Write-WtWorkerMessage -Client $Client -Message @{
        v      = $Script:WtWorkerProtocolVersion
        id     = [guid]::NewGuid().ToString('n')
        op     = 'cancel'
        params = @{ target = $RequestId }
    }
}

<#
.SYNOPSIS
    Sends one request and waits for its terminal message (result, error or cancelled).
.DESCRIPTION
    Used by scripts, tests and benchmarks. The interface does not use this: it drives
    Send/Read itself so the screen stays responsive while a request runs.
.PARAMETER OnProgress
    Called for every progress message, so a caller can show progress without polling.
#>
function Invoke-WtWorkerRoundTrip
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][hashtable]$Message,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 10000,
        [Parameter(Mandatory = $false)][scriptblock]$OnProgress
    )

    Write-WtWorkerMessage -Client $Client -Message $Message

    $Id = [string]$Message.id
    $Deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs)

    while ($true)
    {
        $WorkerEvent = Read-WtWorkerEvent -Client $Client

        if ($WorkerEvent)
        {
            if ($WorkerEvent.Kind -eq 'Exited')
            {
                throw (Get-WtString -Key 'Worker.Reason.Exited' -Arguments @($WorkerEvent.ExitCode, ($WorkerEvent.Stderr -join ' | ')))
            }

            if ($WorkerEvent.Kind -eq 'ProtocolError')
            {
                throw (Get-WtString -Key 'Worker.Reason.Protocol' -Arguments @($WorkerEvent.Code, $WorkerEvent.Detail))
            }

            $Received = $WorkerEvent.Message
            if ([string]$Received.id -ne $Id)
            {
                # A message for another request (a handshake answer, a cancellation ack) is
                # not this call's business.
                continue
            }

            switch ([string]$Received.type)
            {
                'progress' { if ($OnProgress) { & $OnProgress $Received.progress } }
                'hello' { return $Received }
                'result' { return $Received }
                'error' { return $Received }
                'cancelled' { return $Received }
                default { }
            }

            continue
        }

        if ([datetime]::UtcNow -ge $Deadline)
        {
            throw (Get-WtString -Key 'Worker.Reason.Timeout' -Arguments @($TimeoutMs))
        }

        Start-Sleep -Milliseconds 10
    }
}

<#
.SYNOPSIS
    Stops the worker: asks for a cooperative shutdown, then waits, then terminates.
.DESCRIPTION
    The cooperative path is a `shutdown` request; the worker cancels its jobs and exits.
    When that does not happen inside the grace period, the process is killed: that is the
    documented final termination path for the read-only worker, and it is only reached after
    the bounded wait.
.PARAMETER GraceMs
    How long the cooperative shutdown may take.
#>
function Stop-WtWorkerClient
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $false)][int]$GraceMs = 2000
    )

    $Result = @{ Exited = $false; Killed = $false; ExitCode = $null }

    try
    {
        if (-not $Client.Process.HasExited)
        {
            Write-WtWorkerMessage -Client $Client -Message @{ v = $Script:WtWorkerProtocolVersion; id = 'shutdown'; op = 'shutdown' }
        }
    }
    catch
    {
        Write-WtLog -Level Debug -Message "The worker did not accept a shutdown request: $($_.Exception.Message)" -NoConsole
    }

    try
    {
        if (-not $Client.Process.WaitForExit($GraceMs))
        {
            $Client.Process.Kill($true)
            $Result.Killed = $true
            $Client.Process.WaitForExit(2000) | Out-Null
        }

        $Result.Exited = $Client.Process.HasExited
        if ($Client.Process.HasExited) { $Result.ExitCode = $Client.Process.ExitCode }
    }
    catch
    {
        Write-WtLog -Level Warning -Message "The worker process could not be stopped cleanly: $($_.Exception.Message)" -NoConsole
    }
    finally
    {
        try
        {
            $Client.Process.StandardInput.Close()
        }
        catch
        {
            Write-WtLog -Level Debug -Message 'The worker input pipe was already closed.' -NoConsole
        }

        $Client.Process.Dispose()
    }

    return $Result
}

<#
.SYNOPSIS
    Returns the collected stderr lines (bounded), for diagnostics.
#>
function Get-WtWorkerStderr
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $true)][object]$Client)

    return @($Client.Stderr.ToArray())
}

<#
.SYNOPSIS
    Scans a directory through the worker and returns the structured result.
.DESCRIPTION
    Convenience wrapper for scripts, tests and benchmarks: one request, no UI. The
    interface drives the same operations step by step so it can paint progress and cancel.
.PARAMETER Root
    Absolute directory to aggregate.
.OUTPUTS
    @{ Ok; Code; Result; Progress; Message; Stderr }
#>
function Invoke-WtWorkerDirectoryScan
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 120000,
        [Parameter(Mandatory = $false)][object]$Client,
        [Parameter(Mandatory = $false)][scriptblock]$OnProgress
    )

    $OwnClient = $false
    if (-not $Client)
    {
        $Client = Start-WtWorkerClient
        $OwnClient = $true
    }

    try
    {
        $Request = @{
            v         = $Script:WtWorkerProtocolVersion
            id        = [guid]::NewGuid().ToString('n')
            op        = 'scan.directory'
            params    = @{ root = $Root }
            timeoutMs = $TimeoutMs
        }

        $Reply = Invoke-WtWorkerRoundTrip -Client $Client -Message $Request -TimeoutMs ($TimeoutMs + 5000) -OnProgress $OnProgress

        switch ([string]$Reply.type)
        {
            'result'
            {
                return @{ Ok = $true; Code = ''; Result = $Reply.result; Progress = @(); Message = ''; Stderr = @(Get-WtWorkerStderr -Client $Client) }
            }
            'error'
            {
                return @{ Ok = $false; Code = [string]$Reply.error.code; Result = $null; Progress = @(); Message = [string]$Reply.error.message; Stderr = @(Get-WtWorkerStderr -Client $Client) }
            }
            'cancelled'
            {
                return @{ Ok = $false; Code = 'E_CANCELLED'; Result = $null; Progress = @(); Message = [string]$Reply.cancelled.state; Stderr = @(Get-WtWorkerStderr -Client $Client) }
            }
        }

        return @{ Ok = $false; Code = 'E_INTERNAL'; Result = $null; Progress = @(); Message = 'unexpected reply'; Stderr = @() }
    }
    catch
    {
        return @{ Ok = $false; Code = 'E_TRANSPORT'; Result = $null; Progress = @(); Message = $_.Exception.Message; Stderr = @(Get-WtWorkerStderr -Client $Client) }
    }
    finally
    {
        if ($OwnClient) { Stop-WtWorkerClient -Client $Client | Out-Null }
    }
}
