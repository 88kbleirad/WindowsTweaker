# WindowsTweaker - bounded, local diagnostics for the terminal interface.
#
# The interface must be able to answer "which key was dispatched where, and what went
# wrong" after a failure. This file holds that one facility: a bounded in-memory ring of
# normalised records, one sanitizer that runs before anything is stored, and one exporter
# that only runs when the user asks for it.
#
# Deliberate impossibilities, in the order the data flows:
#   * a typed character can never be stored - an input record keeps the key *name*
#     ('Up', 'Enter', 'Char') and never the character a text field received;
#   * a home directory, a 'C:\Users\<name>' path or a 'token=...' secret can never be
#     stored, because every string passes ConvertTo-WtSanitizedText first;
#   * an environment variable can never be recorded; the only machine facts that leave the
#     process are the fixed whitelist returned by Get-WtAppVersion;
#   * a record can never grow past 200 characters per field, the ring never holds more
#     than $Script:WtDiagnosticLimit records and one export never exceeds 256 KiB;
#   * nothing is written to disk unless Export-WtDiagnostics is called explicitly.
#
# A record is a plain ordered hashtable of strings, numbers, booleans and $null values, so
# it survives ConvertTo-Json without a conversion step and cannot smuggle an object graph
# (and with it the environment) into an export.

$Script:WtDiagnosticLimit = 200

# FIFO ring: the newest record is enqueued, the oldest is dequeued once the limit is hit.
$Script:WtDiagnosticRecords = [System.Collections.Generic.Queue[object]]::new()

# The record kinds that can be recorded, and the stable shape Get-WtDiagnosticSummary
# reports even when a kind has never occurred.
$Script:WtDiagnosticKinds = @('input', 'error', 'crash', 'lifecycle')

# One text field is capped so a single record can never dominate the export.
$Script:WtDiagnosticMaxTextLength = 200

# Hard ceiling for one export file, header line included.
$Script:WtDiagnosticMaxExportBytes = 262144

<#
.SYNOPSIS
    Removes user-identifying and secret material from a string.
.DESCRIPTION
    The single sanitizer every diagnostic string passes through, so that a record can
    never contain a path that points at a person or a secret the user pasted:

      * the user's home directory ($HOME, $env:USERPROFILE, $env:HOME) and any
        'C:\Users\<name>' form become <home>; the longest home candidate is replaced
        first so a longer path is not clipped by a shorter prefix;
      * 'password=...', 'passwd=...', 'token=...', 'secret=...' and 'apikey=...' become
        <redacted>, wherever they appear in the text;
      * control characters (newlines, tabs, escape sequences) collapse to a single space.

    Nothing else is altered: the remaining text is preserved verbatim.
.PARAMETER Text
    The text to sanitize. $null or an empty string yields an empty string.
.EXAMPLE
    ConvertTo-WtSanitizedText -Text 'C:\Users\alice\notes.txt'
    Returns '<home>\notes.txt'.
#>
function ConvertTo-WtSanitizedText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false, Position = 0)][AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text))
    {
        return ''
    }

    $Sanitized = $Text

    $Homes = @()
    foreach ($Candidate in @($env:USERPROFILE, $HOME, $env:HOME))
    {
        if ($Candidate)
        {
            $Homes += [string]$Candidate
        }
    }

    # Longest first: replacing 'C:\Users\alice' before 'C:\Users' cannot strand a suffix.
    foreach ($HomePath in @($Homes | Sort-Object -Property Length -Descending))
    {
        $Sanitized = [regex]::Replace($Sanitized, [regex]::Escape($HomePath), '<home>', 'IgnoreCase')
    }

    $Sanitized = [regex]::Replace($Sanitized, '(?i)C:[\\/]Users[\\/][^\\/\s"]+', '<home>')
    $Sanitized = [regex]::Replace($Sanitized, '(?i)(password|passwd|token|secret|apikey)\s*[=:]\s*\S+', '<redacted>')
    $Sanitized = [regex]::Replace($Sanitized, '[\x00-\x1F\x7F]+', ' ')

    return $Sanitized.Trim()
}

<#
.SYNOPSIS
    Caps one diagnostic text field at the diagnostic text limit.
.DESCRIPTION
    A record field longer than $Script:WtDiagnosticMaxTextLength characters is cut and
    marked with a trailing '...', which keeps the total export bounded no matter what a
    caller passes in. The marker is part of the stored value, so a reader can tell a
    truncated field from a short one.
.PARAMETER Text
    The text to cap. $null or an empty string yields an empty string.
#>
function ConvertTo-WtBoundedText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false, Position = 0)][AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text))
    {
        return ''
    }

    if ($Text.Length -le $Script:WtDiagnosticMaxTextLength)
    {
        return $Text
    }

    return $Text.Substring(0, $Script:WtDiagnosticMaxTextLength - 3) + '...'
}

<#
.SYNOPSIS
    Adds one record to the diagnostics ring.
.DESCRIPTION
    The record is normalised before it is stored:

      * -Key contributes its Name and Control only. The character of a key is never read,
        so a letter typed into a search box, a path field or a DNS field cannot reach the
        ring. A caller that owns a text field passes no -Key at all; when it does pass one,
        the key name is 'Char' and no character is stored either way.
      * -Target and -Message are sanitized (see ConvertTo-WtSanitizedText) and capped.
      * -Data values must be strings, numbers, booleans or dates; a date is stored in
        round-trip format. Any other value type is dropped, so an object graph (and with it
        the environment) can never be recorded. String values are sanitized and capped.
        -Data keys matching password, passwd, token, secret, apikey or credential are
        dropped entirely, key and value alike.
      * -Exception contributes its type name to the data (exceptionType) and, when
        -Message is empty, its sanitized message as the record message. Stack traces are
        deliberately not recorded: they carry machine detail that is not needed to find the
        failing dispatch.

    When the ring is full the oldest record is dropped, so the newest record always
    survives.
.PARAMETER Kind
    What the record describes: input, error, crash or lifecycle.
.PARAMETER Key
    The normalized key object produced by ConvertTo-WtKey. Only Name and Control are
    stored. Optional: a text field passes no key at all.
.PARAMETER Target
    The dispatch target the record belongs to, e.g. 'list', 'search', 'global:q'.
.PARAMETER Message
    Free text for the record. Sanitized before it is stored.
.PARAMETER Data
    Structured values for the record. Sensitive keys are dropped, string values are
    sanitized, unsupported value types are ignored.
.PARAMETER Exception
    The exception being reported. Its type name is recorded and its message is used when
    -Message is empty.
.EXAMPLE
    Add-WtDiagnosticRecord -Kind input -Key (ConvertTo-WtKey -Key $Key) -Target 'list'
#>
function Add-WtDiagnosticRecord
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('input', 'error', 'crash', 'lifecycle')][string]$Kind,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Key,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Target = '',
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Message = '',
        [Parameter(Mandatory = $false)][AllowNull()][hashtable]$Data,
        [Parameter(Mandatory = $false)][AllowNull()][System.Exception]$Exception
    )

    $KeyName = $null
    $KeyControl = $null
    if ($null -ne $Key)
    {
        # Only the name is read. $Key.Char holds the typed letter and is never touched.
        $Candidate = [string]$Key.Name
        if ($Candidate)
        {
            $KeyName = $Candidate
            $KeyControl = [bool]$Key.Control
        }
    }

    $CleanData = [ordered]@{}
    if ($Data)
    {
        foreach ($Field in $Data.Keys)
        {
            $FieldName = [string]$Field
            if ($FieldName -match '(?i)(password|passwd|token|secret|apikey|credential)')
            {
                continue
            }

            $Value = $Data[$Field]
            if ($null -eq $Value)
            {
                continue
            }

            if ($Value -is [string])
            {
                $CleanData[$FieldName] = ConvertTo-WtBoundedText -Text (ConvertTo-WtSanitizedText -Text ([string]$Value))
            }
            elseif ($Value -is [bool])
            {
                $CleanData[$FieldName] = [bool]$Value
            }
            elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])
            {
                $CleanData[$FieldName] = $Value
            }
            elseif ($Value -is [datetime])
            {
                $CleanData[$FieldName] = ([datetime]$Value).ToUniversalTime().ToString('o')
            }
        }
    }

    if ($Exception)
    {
        if (-not $CleanData.Contains('exceptionType'))
        {
            $CleanData['exceptionType'] = [string]$Exception.GetType().FullName
        }
    }

    $MessageText = [string]$Message
    if (-not $MessageText -and $Exception)
    {
        $MessageText = [string]$Exception.Message
    }

    $Record = [ordered]@{
        Kind    = $Kind
        Utc     = [datetime]::UtcNow.ToString('o')
        Key     = $KeyName
        Control = $KeyControl
        Target  = ConvertTo-WtBoundedText -Text (ConvertTo-WtSanitizedText -Text $Target)
        Message = ConvertTo-WtBoundedText -Text (ConvertTo-WtSanitizedText -Text $MessageText)
        Data    = $(
            if ($CleanData.Count -gt 0)
            {
                $CleanData
            }
            else
            {
                $null
            }
        )
    }

    if ($Script:WtDiagnosticRecords.Count -ge $Script:WtDiagnosticLimit)
    {
        [void]$Script:WtDiagnosticRecords.Dequeue()
    }

    $Script:WtDiagnosticRecords.Enqueue($Record)
}

<#
.SYNOPSIS
    Reports how many records the ring holds, per kind.
.DESCRIPTION
    Machine-readable counts only - the summary never returns record text, so it is safe to
    show next to the interface, log or assert on.
.OUTPUTS
    Hashtable with Count, Limit and ByKind. ByKind always carries every kind, zero-filled.
.EXAMPLE
    Get-WtDiagnosticSummary
    Returns @{ Count = 2; Limit = 200; ByKind = @{ input = 2; error = 0; ... } }.
#>
function Get-WtDiagnosticSummary
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $ByKind = [ordered]@{}
    foreach ($RecordKind in $Script:WtDiagnosticKinds)
    {
        $ByKind[$RecordKind] = 0
    }

    foreach ($Record in $Script:WtDiagnosticRecords)
    {
        if ($ByKind.Contains($Record.Kind))
        {
            $ByKind[$Record.Kind] = $ByKind[$Record.Kind] + 1
        }
    }

    return @{
        Count  = $Script:WtDiagnosticRecords.Count
        Limit  = $Script:WtDiagnosticLimit
        ByKind = $ByKind
    }
}

<#
.SYNOPSIS
    Empties the diagnostics ring.
.DESCRIPTION
    Used by troubleshooting and by the tests, which must not inherit records from an
    earlier scenario. Exporting is a separate, explicit action and is unaffected by this
    command.
.EXAMPLE
    Clear-WtDiagnosticRecord
#>
function Clear-WtDiagnosticRecord
{
    [CmdletBinding()]
    param ()

    $Script:WtDiagnosticRecords.Clear()
}

<#
.SYNOPSIS
    Reports the application, PowerShell, platform and OS versions of this process.
.DESCRIPTION
    The one place the diagnostics facility reads machine facts, and the whitelist is fixed:
    the module manifest's version from $Script:WtModuleRoot, the PowerShell version from
    $PSVersionTable, the platform from $IsWindows/$IsLinux/$IsMacOS, and the OS
    build/version/culture from the runtime. No environment variable is read or reported.
    Values that cannot be determined are empty strings rather than failures.
.OUTPUTS
    Hashtable with ModuleVersion, PSVersion, Platform, OSBuild, OSVersion and Culture.
.EXAMPLE
    Get-WtAppVersion
#>
function Get-WtAppVersion
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $ModuleVersion = ''
    $ManifestPath = Join-Path $Script:WtModuleRoot 'WindowsTweaker.psd1'
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf)
    {
        $Manifest = Import-PowerShellDataFile -LiteralPath $ManifestPath
        $ModuleVersion = [string]$Manifest.ModuleVersion
    }

    $OsVersion = [System.Environment]::OSVersion

    # A friendly platform name first; the raw .NET platform only as a fallback.
    $Platform = [string]$OsVersion.Platform
    if ($IsWindows)
    {
        $Platform = 'Windows'
    }
    elseif ($IsMacOS)
    {
        $Platform = 'macOS'
    }
    elseif ($IsLinux)
    {
        $Platform = 'Linux'
    }

    # On Windows the OS build is the number tweaks are keyed on; elsewhere the kernel
    # version is the equivalent machine fact.
    $OsBuild = if ($IsWindows) { [string]$OsVersion.Version.Build } else { [string]$OsVersion.Version }

    return @{
        ModuleVersion = $ModuleVersion
        PSVersion     = [string]$PSVersionTable.PSVersion
        Platform      = $Platform
        OSBuild       = $OsBuild
        OSVersion     = [string]$OsVersion.VersionString
        Culture       = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    }
}

<#
.SYNOPSIS
    Writes the diagnostics ring to a JSONL file.
.DESCRIPTION
    The only code in the module that writes a diagnostics file, and it only runs when the
    user asks for it: nothing calls this automatically.

    The file starts with one header line (type=header, appVersion, moduleVersion,
    psVersion, platform, osBuild, osVersion, culture, sessionId, exportedUtc) followed by
    one line per record with the stable shape
    type, kind, utc, key, control, target, message, data.

    The export is bounded twice: at most $Script:WtDiagnosticLimit record lines, and at
    most 256 KiB in total - once the byte budget is spent, the remaining records are left
    out rather than written partially, so the file is always complete JSONL. The target
    file is never overwritten unless -Force is given, and the parent directory is created
    when it does not exist.
.PARAMETER Path
    Where to write the export.
.PARAMETER Force
    Overwrite an existing file. Without it, an existing path is refused.
.PARAMETER SessionId
    Identifier tying the export to one interface session. A fresh identifier is generated
    when omitted.
.OUTPUTS
    The full path of the file that was written.
.EXAMPLE
    Export-WtDiagnostics -Path (Join-Path $HOME 'wt-diagnostics.jsonl')
#>
function Export-WtDiagnostics
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true, Position = 0)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Force,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$SessionId = ''
    )

    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not $Force)
    {
        $Message = "A diagnostics export already exists at '$Path'. Use -Force to overwrite it."
        $Exception = [System.IO.IOException]::new($Message)
        $ErrorRecord = [System.Management.Automation.ErrorRecord]::new(
            $Exception, 'WtDiagnosticsExportExists',
            [System.Management.Automation.ErrorCategory]::ResourceExists, $Path)
        $PSCmdlet.ThrowTerminatingError($ErrorRecord)
    }

    $FullPath = [System.IO.Path]::GetFullPath($Path)
    $Parent = Split-Path -Path $FullPath -Parent
    if ($Parent -and -not (Test-Path -LiteralPath $Parent -PathType Container))
    {
        New-WtDirectory -Path $Parent
    }

    if (-not $SessionId)
    {
        $SessionId = [guid]::NewGuid().ToString('n')
    }

    $App = Get-WtAppVersion

    # The manifest version is the application version. When the session runs a module from
    # elsewhere, the version actually in use is recorded instead, so the header always
    # describes the code that produced the records.
    $Loaded = @(Get-Module -Name 'WindowsTweaker' -ErrorAction Ignore)
    $AppVersion = [string]$App.ModuleVersion
    if ($Loaded.Count -gt 0 -and $Loaded[0].Version)
    {
        $AppVersion = [string]$Loaded[0].Version
    }

    $Header = [ordered]@{
        type          = 'header'
        appVersion    = $AppVersion
        moduleVersion = [string]$App.ModuleVersion
        psVersion     = [string]$App.PSVersion
        platform      = [string]$App.Platform
        osBuild       = [string]$App.OSBuild
        osVersion     = [string]$App.OSVersion
        culture       = [string]$App.Culture
        sessionId     = $SessionId
        exportedUtc   = [datetime]::UtcNow.ToString('o')
    }

    $Lines = [System.Collections.Generic.List[string]]::new()
    $HeaderLine = $Header | ConvertTo-Json -Compress -Depth 4
    $Lines.Add($HeaderLine)

    # Two bytes per line: the longest newline PowerShell writes (CRLF) plus a margin, so
    # the accounting is an upper bound on every platform.
    $Bytes = [System.Text.Encoding]::UTF8.GetByteCount($HeaderLine) + 2

    foreach ($Record in $Script:WtDiagnosticRecords)
    {
        $Line = ([ordered]@{
                type    = 'record'
                kind    = [string]$Record.Kind
                utc     = [string]$Record.Utc
                key     = $Record.Key
                control = $Record.Control
                target  = [string]$Record.Target
                message = [string]$Record.Message
                data    = $Record.Data
            }) | ConvertTo-Json -Compress -Depth 4

        $LineBytes = [System.Text.Encoding]::UTF8.GetByteCount($Line) + 2
        if (($Bytes + $LineBytes) -gt $Script:WtDiagnosticMaxExportBytes)
        {
            break
        }

        $Lines.Add($Line)
        $Bytes += $LineBytes
    }

    [System.IO.File]::WriteAllLines($FullPath, $Lines, [System.Text.UTF8Encoding]::new($false))

    return $FullPath
}
