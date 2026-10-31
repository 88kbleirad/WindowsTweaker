# WindowsTweaker - worker backend selection and the one scan entry point.
#
# Backend modes:
#   Auto        - use the Go worker when it is installed and protocol-compatible, otherwise
#                 the PowerShell implementation, and say which one was used and why
#   Go          - require the Go worker; if it is missing or incompatible the capability is
#                 reported as unavailable rather than silently served by PowerShell
#   PowerShell  - always use the PowerShell implementation (also the comparison baseline)
#
# Precedence: the -WorkerBackend parameter > the saved setting > Auto.

$Script:WtWorkerBackendNames = @('Auto', 'Go', 'PowerShell')

<#
.SYNOPSIS
    Reads the saved backend preference ('' when nothing valid is saved).
#>
function Get-WtWorkerBackendPreference
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $Value = ([string](Read-WtSettings).Backend).Trim()
    if ($Value -and $Script:WtWorkerBackendNames -contains $Value)
    {
        return $Value
    }

    return ''
}

<#
.SYNOPSIS
    Saves the backend preference.
#>
function Set-WtWorkerBackendPreference
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet('Auto', 'Go', 'PowerShell')]
        [string]$Backend
    )

    $Settings = Read-WtSettings
    $Settings.Backend = $Backend

    if ($PSCmdlet.ShouldProcess($Backend, 'save the worker backend preference'))
    {
        Write-WtSettings -Settings $Settings
    }

    return $Backend
}

<#
.SYNOPSIS
    Resolves which backend will serve a capability, and why.
.DESCRIPTION
    Nothing here installs or starts anything: the resolution is a path check plus (for Auto
    and Go) the protocol handshake. A backend that cannot serve the request is reported as
    unavailable instead of being substituted.
.OUTPUTS
    @{ Backend = 'Go'|'PowerShell'; Requested; Reason; Code; Worker = <handshake info> }
#>
function Resolve-WtWorkerBackend
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$Requested = '')

    $Mode = if ($Requested -and $Script:WtWorkerBackendNames -contains $Requested)
    {
        $Requested
    }
    elseif (Get-WtWorkerBackendPreference)
    {
        Get-WtWorkerBackendPreference
    }
    else
    {
        'Auto'
    }

    $Result = @{ Backend = 'PowerShell'; Requested = $Mode; Reason = ''; Code = ''; Worker = $null }

    $Availability = Test-WtWorkerAvailable -Force:($Mode -ne 'Auto')

    if ($Mode -eq 'PowerShell')
    {
        $Result.Reason = Get-WtString -Key 'Worker.Reason.ForcedPowerShell'
        return $Result
    }

    if ($Availability.Available)
    {
        $Result.Backend = 'Go'
        $Result.Code = 'Available'
        $Result.Worker = $Availability
        $Result.Reason = Get-WtString -Key 'Worker.Reason.UsingGo' -Arguments @($Availability.Version, $Availability.Protocol)
        return $Result
    }

    $Result.Code = $Availability.Code
    $Result.Worker = $Availability

    if ($Mode -eq 'Go')
    {
        # An explicit Go request is not silently answered by the fallback: the capability is
        # reported as unavailable, with the reason.
        $Result.Backend = ''
        $Result.Reason = Get-WtString -Key 'Worker.Reason.GoUnavailable' -Arguments @($Availability.Reason)
        return $Result
    }

    $Result.Reason = Get-WtString -Key 'Worker.Reason.FallingBack' -Arguments @($Availability.Reason)
    return $Result
}

<#
.SYNOPSIS
    Scans a directory with the selected backend and returns one result shape.
.DESCRIPTION
    The single entry point the interface, the CLI and the benchmark call. Both backends return
    the same fields (the Go worker's JSON is mapped onto them) and both accept a progress
    callback and a cancellation check, so the caller cannot tell them apart except through
    the Backend field - which is exactly what it should be able to see.
.PARAMETER Backend
    Auto (default), Go or PowerShell; empty means "use the saved preference, then Auto".
.PARAMETER OnProgress
    Called with @{ Files; Directories; Bytes; Errors; ElapsedMs; Backend } at a bounded rate.
.PARAMETER CancelCheck
    Called between directories (PowerShell backend) or polled between worker events (Go
    backend); returning $true cancels the scan and returns partial results.
#>
function Invoke-WtDirectoryScan
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][ValidateSet('', 'Auto', 'Go', 'PowerShell')][string]$Backend = '',
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 120000,
        [Parameter(Mandatory = $false)][scriptblock]$OnProgress,
        [Parameter(Mandatory = $false)][scriptblock]$CancelCheck
    )

    $Resolution = Resolve-WtWorkerBackend -Requested $Backend

    if (-not $Resolution.Backend)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.DirectoryScan'
            Backend    = ''
            Root       = $Root
            Ok         = $false
            Code       = $(if ($Resolution.Code) { $Resolution.Code } else { 'E_UNAVAILABLE' })
            Message    = $Resolution.Reason
            Reason     = $Resolution.Reason
        }
    }

    if ($Resolution.Backend -eq 'PowerShell')
    {
        $Watch = [System.Diagnostics.Stopwatch]::StartNew()
        try
        {
            $Scan = Get-WtDirectorySize -Path $Root -Progress $OnProgress -CancelCheck $CancelCheck
        }
        catch
        {
            return [pscustomobject]@{
                PSTypeName = 'WindowsTweaker.DirectoryScan'
                Backend    = 'PowerShell'
                Root       = $Root
                Ok         = $false
                Code       = 'E_SCAN'
                Message    = $_.Exception.Message
                Reason     = $Resolution.Reason
            }
        }

        return [pscustomobject]@{
            PSTypeName       = 'WindowsTweaker.DirectoryScan'
            Backend          = 'PowerShell'
            Root             = $Scan.Root
            Ok               = $true
            Code             = ''
            Message          = ''
            Reason           = $Resolution.Reason
            Files            = $Scan.Files
            Directories      = $Scan.Directories
            Bytes            = $Scan.Bytes
            AllocatedBytes   = $Scan.AllocatedBytes
            AllocatedKnown   = $Scan.AllocatedKnown
            AllocatedNote    = $Scan.AllocatedNote
            SizeKind         = $Scan.SizeKind
            SkippedLinks     = $Scan.SkippedLinks
            SkippedOther     = $Scan.SkippedOther
            HardLinksDeduped = $Scan.HardLinksDeduped
            HardLinkNote     = $Scan.HardLinkNote
            Errors           = $Scan.Errors
            ErrorsTruncated  = $Scan.ErrorsTruncated
            Partial          = $Scan.Partial
            Cancelled        = $Scan.Cancelled
            ElapsedMS        = [int]$Watch.ElapsedMilliseconds
            Workers          = $Scan.Workers
            Largest          = $Scan.Largest
            LargestTruncated = $Scan.LargestTruncated
        }
    }

    # ---- Go worker -------------------------------------------------------------------
    $Client = $null
    $Watch = [System.Diagnostics.Stopwatch]::StartNew()

    try
    {
        $Client = Start-WtWorkerClient

        $RequestId = Send-WtWorkerRequest -Client $Client -Operation 'scan.directory' -Parameters @{ root = $Root } -TimeoutMs $TimeoutMs
        $Deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs + 10000)
        $CancelSent = $false

        while ($true)
        {
            if ($CancelCheck -and -not $CancelSent -and (& $CancelCheck))
            {
                Send-WtWorkerCancel -Client $Client -RequestId $RequestId
                $CancelSent = $true
            }

            $WorkerEvent = Read-WtWorkerEvent -Client $Client

            if ($null -eq $WorkerEvent)
            {
                if ([datetime]::UtcNow -ge $Deadline)
                {
                    Send-WtWorkerCancel -Client $Client -RequestId $RequestId
                    return [pscustomobject]@{
                        PSTypeName = 'WindowsTweaker.DirectoryScan'
                        Backend    = 'Go'
                        Root       = $Root
                        Ok         = $false
                        Code       = 'E_TIMEOUT'
                        Message    = Get-WtString -Key 'Worker.Reason.Timeout' -Arguments @($TimeoutMs)
                        Reason     = $Resolution.Reason
                    }
                }

                Start-Sleep -Milliseconds 20
                continue
            }

            if ($WorkerEvent.Kind -eq 'ProtocolError')
            {
                # A transport violation is reported as such; the operation is never retried and
                # no result is fabricated.
                return [pscustomobject]@{
                    PSTypeName = 'WindowsTweaker.DirectoryScan'
                    Backend    = 'Go'
                    Root       = $Root
                    Ok         = $false
                    Code       = [string]$WorkerEvent.Code
                    Message    = Get-WtString -Key 'Worker.Reason.Protocol' -Arguments @($WorkerEvent.Code, $WorkerEvent.Detail)
                    Reason     = $Resolution.Reason
                }
            }

            if ($WorkerEvent.Kind -eq 'Exited')
            {
                return [pscustomobject]@{
                    PSTypeName = 'WindowsTweaker.DirectoryScan'
                    Backend    = 'Go'
                    Root       = $Root
                    Ok         = $false
                    Code       = 'E_WORKER_EXITED'
                    Message    = Get-WtString -Key 'Worker.Reason.Exited' -Arguments @($WorkerEvent.ExitCode, ($WorkerEvent.Stderr -join ' | '))
                    Reason     = $Resolution.Reason
                }
            }

            $Message = $WorkerEvent.Message
            if ([string]$Message.id -ne $RequestId)
            {
                continue
            }

            switch ([string]$Message.type)
            {
                'progress'
                {
                    if ($OnProgress)
                    {
                        & $OnProgress @{
                            Files          = [long]$Message.progress.files
                            Directories    = [long]$Message.progress.directories
                            Bytes          = [long]$Message.progress.bytes
                            AllocatedBytes = [long]$Message.progress.allocatedBytes
                            SkippedLinks   = [long]$Message.progress.skipped
                            Errors         = [long]$Message.progress.errors
                            ElapsedMs      = [int]$Message.progress.elapsedMs
                            Backend        = 'Go'
                        }
                    }
                }

                'cancelled'
                {
                    # "stopping" is the acknowledgement; the job's own message says "stopped".
                    if ([string]$Message.cancelled.state -eq 'stopped' -or [string]$Message.cancelled.state -eq 'completed')
                    {
                        return [pscustomobject]@{
                            PSTypeName = 'WindowsTweaker.DirectoryScan'
                            Backend    = 'Go'
                            Root       = $Root
                            Ok         = $false
                            Code       = 'E_CANCELLED'
                            Message    = [string]$Message.cancelled.state
                            Reason     = $Resolution.Reason
                            Cancelled  = $true
                            ElapsedMS  = [int]$Watch.ElapsedMilliseconds
                        }
                    }
                }

                'error'
                {
                    return [pscustomobject]@{
                        PSTypeName = 'WindowsTweaker.DirectoryScan'
                        Backend    = 'Go'
                        Root       = $Root
                        Ok         = $false
                        Code       = [string]$Message.error.code
                        Message    = [string]$Message.error.detail
                        Reason     = $Resolution.Reason
                        ElapsedMS  = [int]$Watch.ElapsedMilliseconds
                    }
                }

                'result'
                {
                    $Result = $Message.result
                    return [pscustomobject]@{
                        PSTypeName       = 'WindowsTweaker.DirectoryScan'
                        Backend          = 'Go'
                        Root             = [string]$Result.root
                        Ok               = $true
                        Code             = ''
                        Message          = ''
                        Reason           = $Resolution.Reason
                        Files            = [long]$Result.files
                        Directories      = [long]$Result.directories
                        Bytes            = [long]$Result.bytes
                        AllocatedBytes   = [long]$Result.allocatedBytes
                        AllocatedKnown   = [bool]$Result.allocatedKnown
                        AllocatedNote    = [string]$Result.allocatedNote
                        SizeKind         = [string]$Result.sizeKind
                        SkippedLinks     = [long]$Result.skippedLinks
                        SkippedOther     = [long]$Result.skippedOther
                        HardLinksDeduped = [long]$Result.hardLinksDeduped
                        HardLinkNote     = [string]$Result.hardLinkNote
                        Errors           = @($Result.errors)
                        ErrorsTruncated  = [bool]$Result.errorsTruncated
                        Partial          = [bool]$Result.partial
                        Cancelled        = [bool]$Result.cancelled
                        ElapsedMS        = [int]$Watch.ElapsedMilliseconds
                        Workers          = [int]$Result.workers
                        Largest          = @($Result.largest)
                        LargestTruncated = [bool]$Result.largestTruncated
                    }
                }
            }
        }
    }
    catch
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.DirectoryScan'
            Backend    = 'Go'
            Root       = $Root
            Ok         = $false
            Code       = 'E_TRANSPORT'
            Message    = $_.Exception.Message
            Reason     = $Resolution.Reason
        }
    }
    finally
    {
        if ($Client) { Stop-WtWorkerClient -Client $Client | Out-Null }
    }
}

<#
.SYNOPSIS
    Lists the direct children of a directory with the selected backend.
.DESCRIPTION
    The hierarchy entry point for the disk-usage explorer: one directory, one level, with
    per-subdirectory subtree aggregates. Both backends return the same fields and both are
    read-only; the Go worker is used when it advertises scan.children, otherwise the
    PowerShell implementation runs (Auto) or the capability is reported unavailable (Go).
.PARAMETER Root
    Absolute directory to list.
.PARAMETER Backend
    Auto (default), Go or PowerShell; empty means "use the saved preference, then Auto".
.PARAMETER CancelCheck
    Called between children; returning $true cancels the listing.
.OUTPUTS
    Object with Backend, Root, Entries, Cancelled, ElapsedMS, Ok, Code and Message.
#>
function Invoke-WtDirectoryChildren
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][ValidateSet('', 'Auto', 'Go', 'PowerShell')][string]$Backend = '',
        [Parameter(Mandatory = $false)][int]$TimeoutMs = 120000,
        [Parameter(Mandatory = $false)][scriptblock]$CancelCheck
    )

    $Resolution = Resolve-WtWorkerBackend -Requested $Backend

    if (-not $Resolution.Backend)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.DirectoryChildren'
            Backend    = ''
            Root       = $Root
            Ok         = $false
            Code       = $(if ($Resolution.Code) { $Resolution.Code } else { 'E_UNAVAILABLE' })
            Message    = $Resolution.Reason
            Reason     = $Resolution.Reason
        }
    }

    # The worker may predate the scan.children capability. An Auto request falls back to
    # PowerShell with the reason; an explicit Go request reports the capability unavailable.
    if ($Resolution.Backend -eq 'Go' -and @($Resolution.Worker.Capabilities) -notcontains 'scan.children')
    {
        if ($Backend -eq 'Go' -or $Resolution.Requested -eq 'Go')
        {
            return [pscustomobject]@{
                PSTypeName = 'WindowsTweaker.DirectoryChildren'
                Backend    = ''
                Root       = $Root
                Ok         = $false
                Code       = 'MissingCapability'
                Message    = Get-WtString -Key 'Worker.Reason.MissingCapability' -Arguments @('scan.children')
                Reason     = Get-WtString -Key 'Worker.Reason.MissingCapability' -Arguments @('scan.children')
            }
        }

        $Resolution = @{
            Backend = 'PowerShell'
            Requested = $Resolution.Requested
            Reason = Get-WtString -Key 'Worker.Reason.MissingCapabilityForOp' -Arguments @('scan.children')
            Code = 'MissingCapability'
            Worker = $Resolution.Worker
        }
    }

    $Watch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($Resolution.Backend -eq 'PowerShell')
    {
        try
        {
            $Children = Get-WtDirectoryChildrenFallback -Path $Root -CancelCheck $CancelCheck
        }
        catch
        {
            return [pscustomobject]@{
                PSTypeName = 'WindowsTweaker.DirectoryChildren'
                Backend    = 'PowerShell'
                Root       = $Root
                Ok         = $false
                Code       = 'E_SCAN'
                Message    = $_.Exception.Message
                Reason     = $Resolution.Reason
            }
        }

        return [pscustomobject]@{
            PSTypeName      = 'WindowsTweaker.DirectoryChildren'
            Backend         = 'PowerShell'
            Root            = $Children.Root
            Ok              = $true
            Code            = ''
            Message         = ''
            Reason          = $Resolution.Reason
            Entries         = @($Children.Entries)
            ErrorsTruncated = [bool]$Children.ErrorsTruncated
            Cancelled       = [bool]$Children.Cancelled
            ElapsedMS       = [int]$Watch.ElapsedMilliseconds
        }
    }

    # ---- Go worker -------------------------------------------------------------------
    $Client = $null
    try
    {
        $Client = Start-WtWorkerClient

        $RequestId = Send-WtWorkerRequest -Client $Client -Operation 'scan.children' -Parameters @{ root = $Root } -TimeoutMs $TimeoutMs
        $Deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMs + 10000)
        $CancelSent = $false

        while ($true)
        {
            if ($CancelCheck -and -not $CancelSent -and (& $CancelCheck))
            {
                Send-WtWorkerCancel -Client $Client -RequestId $RequestId
                $CancelSent = $true
            }

            $WorkerEvent = Read-WtWorkerEvent -Client $Client

            if ($null -eq $WorkerEvent)
            {
                if ([datetime]::UtcNow -ge $Deadline)
                {
                    Send-WtWorkerCancel -Client $Client -RequestId $RequestId
                    return [pscustomobject]@{
                        PSTypeName = 'WindowsTweaker.DirectoryChildren'
                        Backend    = 'Go'
                        Root       = $Root
                        Ok         = $false
                        Code       = 'E_TIMEOUT'
                        Message    = Get-WtString -Key 'Worker.Reason.Timeout' -Arguments @($TimeoutMs)
                        Reason     = $Resolution.Reason
                    }
                }

                Start-Sleep -Milliseconds 20
                continue
            }

            if ($WorkerEvent.Kind -eq 'ProtocolError')
            {
                return [pscustomobject]@{
                    PSTypeName = 'WindowsTweaker.DirectoryChildren'
                    Backend    = 'Go'
                    Root       = $Root
                    Ok         = $false
                    Code       = [string]$WorkerEvent.Code
                    Message    = Get-WtString -Key 'Worker.Reason.Protocol' -Arguments @($WorkerEvent.Code, $WorkerEvent.Detail)
                    Reason     = $Resolution.Reason
                }
            }

            if ($WorkerEvent.Kind -eq 'Exited')
            {
                return [pscustomobject]@{
                    PSTypeName = 'WindowsTweaker.DirectoryChildren'
                    Backend    = 'Go'
                    Root       = $Root
                    Ok         = $false
                    Code       = 'E_WORKER_EXITED'
                    Message    = Get-WtString -Key 'Worker.Reason.Exited' -Arguments @($WorkerEvent.ExitCode, ($WorkerEvent.Stderr -join ' | '))
                    Reason     = $Resolution.Reason
                }
            }

            $Message = $WorkerEvent.Message
            if ([string]$Message.id -ne $RequestId)
            {
                continue
            }

            switch ([string]$Message.type)
            {
                'cancelled'
                {
                    if ([string]$Message.cancelled.state -eq 'stopped' -or [string]$Message.cancelled.state -eq 'completed')
                    {
                        return [pscustomobject]@{
                            PSTypeName = 'WindowsTweaker.DirectoryChildren'
                            Backend    = 'Go'
                            Root       = $Root
                            Ok         = $false
                            Code       = 'E_CANCELLED'
                            Message    = [string]$Message.cancelled.state
                            Reason     = $Resolution.Reason
                            Cancelled  = $true
                            ElapsedMS  = [int]$Watch.ElapsedMilliseconds
                        }
                    }
                }

                'error'
                {
                    return [pscustomobject]@{
                        PSTypeName = 'WindowsTweaker.DirectoryChildren'
                        Backend    = 'Go'
                        Root       = $Root
                        Ok         = $false
                        Code       = [string]$Message.error.code
                        Message    = [string]$Message.error.detail
                        Reason     = $Resolution.Reason
                        ElapsedMS  = [int]$Watch.ElapsedMilliseconds
                    }
                }

                'result'
                {
                    $Result = $Message.result
                    return [pscustomobject]@{
                        PSTypeName      = 'WindowsTweaker.DirectoryChildren'
                        Backend         = 'Go'
                        Root            = [string]$Result.root
                        Ok              = $true
                        Code            = ''
                        Message         = ''
                        Reason          = $Resolution.Reason
                        Entries         = @($Result.entries)
                        ErrorsTruncated = [bool]$Result.errorsTruncated
                        Cancelled       = [bool]$Result.cancelled
                        ElapsedMS       = [int]$Watch.ElapsedMilliseconds
                    }
                }
            }
        }
    }
    catch
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.DirectoryChildren'
            Backend    = 'Go'
            Root       = $Root
            Ok         = $false
            Code       = 'E_TRANSPORT'
            Message    = $_.Exception.Message
            Reason     = $Resolution.Reason
        }
    }
    finally
    {
        if ($Client) { Stop-WtWorkerClient -Client $Client | Out-Null }
    }
}

<#
.SYNOPSIS
    Describes the current backend choice for the interface (translated for the user).
#>
function Get-WtWorkerBackendSummary
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][string]$Requested = '')

    $Resolution = Resolve-WtWorkerBackend -Requested $Requested
    if (-not $Resolution.Backend)
    {
        return $Resolution.Reason
    }

    return (Get-WtString -Key 'Worker.Status.Backend' -Arguments @($Resolution.Backend, $Resolution.Reason))
}
