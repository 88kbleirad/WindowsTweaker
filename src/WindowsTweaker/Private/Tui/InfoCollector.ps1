# WindowsTweaker - background collector for slow read-only TUI data.
#
# Several screen values are read-only but expensive to compute on the UI thread:
#   * tweak state dimensions (configured/effective/ownership) - live provider reads;
#   * Overview drift and interrupted-operation counts - state store plus live targets;
#   * the slmgr /xpr and /dlv comparison - two cscript spawns.
# Computing them inline makes a key press block for seconds on a slow VM. This module
# moves that work to one reusable background runspace (the same & $Module { } pattern the
# external-tool task uses), keeps input ownership on the UI thread, and applies results
# with a generation guard so an older response never overwrites a newer refresh.
#
# Contract:
#   * bounded: one worker, a bounded request queue (oldest dropped when full), bounded
#     response queue, and every request carries a maximum execution time;
#   * private: no typed text, keys, paths or values are logged or queued - only a small
#     vocabulary of job kinds and tweak ids;
#   * stale-proof: each batch of requests carries the current generation; responses whose
#     generation is older than the current one are discarded by the drain.

$Script:WtInfoCollectorMaxQueue = 64
$Script:WtInfoCollectorMaxWorkSeconds = 30

<#
.SYNOPSIS
    Returns the path of the module to import inside the collector runspace.
#>
function Get-WtInfoCollectorModulePath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $Module = Get-Module -Name WindowsTweaker
    if ($Module -and $Module.Path)
    {
        return $Module.Path
    }
    return (Join-Path $Script:WtModuleRoot 'WindowsTweaker.psd1')
}

<#
.SYNOPSIS
    Creates the background collector runspace.
.DESCRIPTION
    The runspace owns one long-running pipeline that waits for requests, executes them
    inside the module scope, and enqueues responses. It is created lazily and reused for
    the whole session; Close-WtInfoCollector disposes it.
#>
function New-WtInfoCollector
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string]$ModulePath)

    if (-not $ModulePath) { $ModulePath = Get-WtInfoCollectorModulePath }
    $Runspace = [runspacefactory]::CreateRunspace()
    $Runspace.ApartmentState = 'MTA'
    $Runspace.ThreadOptions = 'ReuseThread'
    $Runspace.Open()

    return @{
        ModulePath = $ModulePath
        Runspace   = $Runspace
        PowerShell = $null
        Requests   = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Responses  = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Stop       = [hashtable]::Synchronized(@{ Requested = $false })
        Handle     = $null
        Closed     = $false
    }
}

<#
.SYNOPSIS
    Starts the collector pipeline (idempotent).
.DESCRIPTION
    The pipeline runs until Stop.Requested is set. Every request is executed by invoking
    a scriptblock inside the module scope, so private functions are reachable without
    widening the public API. A request that throws is answered with an error response.
#>
function Start-WtInfoCollector
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Collector)

    if ($Collector.Handle) { return }

    $PowerShell = [powershell]::Create()
    $PowerShell.Runspace = $Collector.Runspace
    $Collector.PowerShell = $PowerShell

    [void]$PowerShell.AddScript({
        param ($ModulePath, $Requests, $Responses, $Stop)

        $Module = Import-Module -Name $ModulePath -Force -PassThru
        $ConfirmPreference = 'None'
        $ProgressPreference = 'SilentlyContinue'
        Initialize-WtLogging -Console $false | Out-Null

        while (-not $Stop.Requested)
        {
            $Request = $null
            if ($Requests.TryDequeue([ref]$Request))
            {
                if ($Request)
                {
                    $Response = [ordered]@{
                        Generation = $Request.Generation
                        Kind       = $Request.Kind
                        Key        = $Request.Key
                        Ok         = $false
                        Value      = $null
                        Error      = ''
                    }

                    try
                    {
                        $Value = & $Module {
                            param ($Job)
                            try
                            {
                                switch ($Job.Kind)
                                {
                                    'dimensions'
                                    {
                                        $Tweak = Get-WtTweakInternal -Id $Job.Key
                                        if (-not $Tweak)
                                        {
                                            throw "Unknown tweak: $($Job.Key)"
                                        }
                                        Get-WtStateDimensionsInternal -Tweak $Tweak -State $Job.State
                                    }
                                    'drift'
                                    {
                                        @{
                                            Drifted    = @(Get-WtDriftInternal -OnlyDrifted).Count
                                            Interrupted = @(Get-WtInterruptedOperationInternal).Count
                                        }
                                    }
                                    'slmgr'
                                    {
                                        Get-WtSlmgrComparison
                                    }
                                    default { throw "Unknown job kind: $($Job.Kind)" }
                                }
                            }
                            catch
                            {
                                throw
                            }
                        } $Request

                        $Response.Ok = $true
                        $Response.Value = $Value
                    }
                    catch
                    {
                        $Response.Error = [string]$_.Exception.Message
                    }

                    $Responses.Enqueue($Response)
                }
            }
            else
            {
                Start-Sleep -Milliseconds 50
            }
        }
    })

    [void]$PowerShell.AddParameter('ModulePath', $Collector.ModulePath)
    [void]$PowerShell.AddParameter('Requests', $Collector.Requests)
    [void]$PowerShell.AddParameter('Responses', $Collector.Responses)
    [void]$PowerShell.AddParameter('Stop', $Collector.Stop)

    $Collector.Handle = $PowerShell.BeginInvoke()
}

<#
.SYNOPSIS
    Enqueues one collection request, dropping the oldest when the queue is full.
#>
function Send-WtInfoCollectorRequest
{
    [CmdletBinding()]
    [OutputType([bool])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Collector,
        [Parameter(Mandatory = $true)][ValidateSet('dimensions', 'drift', 'slmgr')][string]$Kind,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Key = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$State = '',
        [Parameter(Mandatory = $false)][int]$Generation = 0
    )

    if (-not $Collector) { return $false }
    Start-WtInfoCollector -Collector $Collector

    # Bounded queue: never grow past the cap; drop the oldest request.
    if ($Collector.Requests.Count -ge $Script:WtInfoCollectorMaxQueue)
    {
        $Dropped = $null
        [void]$Collector.Requests.TryDequeue([ref]$Dropped)
    }

    $Collector.Requests.Enqueue(@{
            Generation = $Generation
            Kind       = $Kind
            Key        = $Key
            State      = $State
            EnqueuedUtc = [datetime]::UtcNow
        })
    return $true
}

<#
.SYNOPSIS
    Drains the collector response queue.
.OUTPUTS
    An array of response dictionaries.
#>
function Receive-WtInfoCollectorResponses
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ([Parameter(Mandatory = $true)][object]$Collector)

    $Responses = [System.Collections.Generic.List[object]]::new()
    if (-not $Collector) { return $Responses.ToArray() }

    $Item = $null
    while ($Collector.Responses.TryDequeue([ref]$Item))
    {
        if ($null -ne $Item) { $Responses.Add($Item) }
    }

    # Keep the result an array even for a single response: the caller must not have to
    # distinguish a one-element list from a dictionary.
    return ,$Responses.ToArray()
}

<#
.SYNOPSIS
    Drains the background collector and applies completed responses.
.DESCRIPTION
    Called once per frame. Responses whose generation is older than the current one are
    discarded (a slow job can never overwrite a newer refresh). Results are written back
    into the shared state:
      * 'drift' updates $State.OverviewVerify (the Overview pane's verification row);
      * 'slmgr' updates $State.Licensing.Slmgr when the workspace still holds the
        generation that requested it;
      * 'dimensions' fills $State.DimensionCache per tweak id.
#>
function Update-WtInfoCollector
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.InfoCollector) { return }

    foreach ($Response in @(Receive-WtInfoCollectorResponses -Collector $State.InfoCollector))
    {
        $Generation = [int]$Response.Generation
        switch ([string]$Response.Kind)
        {
            'drift'
            {
                if ($Generation -ne $State.DriftGeneration) { continue }
                if (-not $Response.Ok) { continue }
                $State.OverviewVerify = @{
                    Utc = [datetime]::UtcNow
                    Drifted = [int]$Response.Value.Drifted
                    Interrupted = [int]$Response.Value.Interrupted
                }
                $State.Screen.Dirty = $true
            }
            'slmgr'
            {
                if ($Generation -ne $State.SlmgrGeneration) { continue }
                if (-not $Response.Ok) { continue }
                if ($State.Licensing)
                {
                    $State.Licensing.Slmgr = $Response.Value
                    $State.Screen.Dirty = $true
                }
            }
            'dimensions'
            {
                # Dimensions are invalidated per catalog refresh; refuse a response that
                # predates the current generation (an older job for the same id).
                if ($Generation -lt $State.DimensionsGeneration) { continue }
                if (-not $Response.Ok) { continue }
                if (-not $State.DimensionCache) { $State.DimensionCache = @{} }
                $State.DimensionCache[[string]$Response.Key] = $Response.Value
                if ($State.DimensionPending -and $State.DimensionPending.ContainsKey([string]$Response.Key))
                {
                    $State.DimensionPending.Remove([string]$Response.Key)
                }
                $State.Screen.Dirty = $true
            }
        }
    }
}

<#
.SYNOPSIS
    Stops the collector pipeline and disposes its runspace (safe to call twice).
#>
function Close-WtInfoCollector
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Collector)

    if ($Collector.Closed) { return }
    $Collector.Stop.Requested = $true

    if ($Collector.PowerShell)
    {
        try { $Collector.PowerShell.Stop() } catch { Write-WtLog -Level Debug -Message 'The info collector could not be stopped.' -NoConsole }
        try { $Collector.PowerShell.Dispose() } catch { Write-WtLog -Level Debug -Message 'The info collector pipeline could not be disposed.' -NoConsole }
        $Collector.PowerShell = $null
    }

    try { $Collector.Runspace.Dispose() } catch { Write-WtLog -Level Debug -Message 'The info collector runspace could not be disposed.' -NoConsole }
    $Collector.Handle = $null
    $Collector.Closed = $true
}
