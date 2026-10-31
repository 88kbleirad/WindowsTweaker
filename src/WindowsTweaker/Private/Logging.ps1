# WindowsTweaker - structured logging.
#
# Every mutation and detection reports a per-operation status through Write-WtLog:
#   succeeded | failed | skipped | unsupported | unchanged | dryrun
# Log records are appended as JSON lines and mirrored to the console.
#
# Nothing in this file touches the file system until the first record is written.

$Script:WtLogState = @{
    Initialized  = $false
    Path         = $null
    MinimumLevel = 'Information'
    ToConsole    = $true
    MissingLevel = $false
}

$Script:WtLogLevelRank = @{
    Debug       = 10
    Information = 20
    Warning     = 30
    Error       = 40
}

function Get-WtLogLevelRank
{
    [CmdletBinding()]
    [OutputType([int])]
    param ([Parameter(Mandatory = $true)][string]$Level)

    if ($Script:WtLogLevelRank.ContainsKey($Level))
    {
        return $Script:WtLogLevelRank[$Level]
    }

    return 20
}

<#
.SYNOPSIS
    Returns the current log file path, initialising logging if required.
#>
function Get-WtLogPath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if (-not $Script:WtLogState.Initialized)
    {
        Initialize-WtLogging
    }

    return $Script:WtLogState.Path
}

<#
.SYNOPSIS
    Initialises structured logging (idempotent).
.PARAMETER Path
    Explicit log file. Defaults to <data root>\logs\wt-<yyyyMMdd>.jsonl
.PARAMETER  MinimumLevel
    Debug, Information, Warning or Error. Defaults to Information.
.PARAMETER Console
    Mirror records to the console.
#>
function Initialize-WtLogging
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]$MinimumLevel = 'Information',

        [Parameter(Mandatory = $false)]
        [bool]$Console = $true,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    if ($Script:WtLogState.Initialized -and -not $Force)
    {
        return $Script:WtLogState.Path
    }

    if (-not $Path)
    {
        $Path = Join-Path (Get-WtLogDirectory) ('wt-{0}.jsonl' -f (Get-Date).ToString('yyyyMMdd'))
    }

    $Script:WtLogState.Path = $Path
    $Script:WtLogState.MinimumLevel = $MinimumLevel
    $Script:WtLogState.ToConsole = $Console
    $Script:WtLogState.Initialized = $true

    return $Path
}

<#
.SYNOPSIS
    Writes one structured log record. Never throws.
.DESCRIPTION
    -Status is the operation outcome and is part of the machine-readable record:
    succeeded, failed, skipped, unsupported, unchanged or dryrun.
#>
function Write-WtLog
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)]
        [ValidateSet('Debug', 'Information', 'Warning', 'Error')]
        [string]$Level = 'Information',

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$TweakId,

        [Parameter(Mandatory = $false)]
        [string]$Operation,

        [Parameter(Mandatory = $false)]
        [ValidateSet('succeeded', 'failed', 'skipped', 'unsupported', 'unchanged', 'dryrun', 'pending', 'review-required', '')]
        [string]$Status = '',

        [Parameter(Mandatory = $false)]
        [hashtable]$Data,

        [Parameter(Mandatory = $false)]
        [System.Exception]$Exception,

        [Parameter(Mandatory = $false)]
        [switch]$NoConsole
    )

    if (-not $Script:WtLogState.Initialized)
    {
        # Suppress the returned path: logging must never inject output into the
        # caller's pipeline.
        Initialize-WtLogging | Out-Null
    }

    if ((Get-WtLogLevelRank -Level $Level) -lt (Get-WtLogLevelRank -Level $Script:WtLogState.MinimumLevel))
    {
        return
    }

    $Record = [ordered]@{
        ts        = (Get-Date).ToUniversalTime().ToString('o')
        level     = $Level
        message   = $Message
        tweakId   = $TweakId
        operation = $Operation
        status    = $Status
        data      = $Data
        error     = if ($Exception) { ($Exception | Out-String).Trim() } else { $null }
    }

    try
    {
        $Directory = Split-Path -Path $Script:WtLogState.Path -Parent
        if ($Directory -and -not (Test-Path -LiteralPath $Directory))
        {
            New-WtDirectory -Path $Directory
        }

        $Json = ConvertTo-WtJson -InputObject $Record -Depth 8 -Compress
        # Logging is never suppressed by -WhatIf (Write-WtTextFile implements no
        # ShouldProcess): the log lives in our own data directory and is the record of what
        # a dry run *would* have done.
        Write-WtTextFile -Path $Script:WtLogState.Path -Value $Json -Append -ErrorAction Stop
    }
    catch
    {
        # Logging must never break an operation; fall back to the console only.
        $Script:WtLogState.ToConsole = $true
    }

    if ($Script:WtLogState.ToConsole -and -not $NoConsole)
    {
        $Prefix = switch ($Status)
        {
            'succeeded' { '[ ok ]' }
            'unchanged' { '[ -- ]' }
            'skipped' { '[skip]' }
            'dryrun' { '[what]' }
            'unsupported' { '[n/a ]' }
            'failed' { '[FAIL]' }
            default { '      ' }
        }

        $Colour = switch ($Level)
        {
            'Warning' { 'Yellow' }
            'Error' { 'Red' }
            default { 'Gray' }
        }
        if ($Status -eq 'succeeded' -and $Level -eq 'Information') { $Colour = 'Gray' }

        $Scope = if ($TweakId) { "$TweakId " } else { '' }
        Write-Host -Object "$Prefix $Scope$Message" -ForegroundColor $Colour
    }
}
