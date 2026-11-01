# WindowsTweaker - runtime compatibility layer.
#
# One implementation, two runtimes. Every difference between Windows PowerShell 5.1
# (.NET Framework) and PowerShell 7+ (.NET) that the application actually depends on is
# expressed here, so the rest of the module calls one helper instead of branching on
# $IsWindows, -Encoding utf8NoBOM or ConvertFrom-Json -Depth at the call site.
#
# Hard rule: this file must parse and run on Windows PowerShell 5.1. It therefore uses no
# 7-only syntax (no ternary, no null-coalescing, no pipeline chain operators), no 7-only
# cmdlet parameters and no .NET members that do not exist on .NET Framework. The
# repository's validation suite enforces that with PSScriptAnalyzer's compatibility rules
# against the Windows PowerShell 5.1 profile (tools/Invoke-Validation.ps1, phase 7).
#
# Nothing here changes system state: it reads the runtime, writes text files with an
# explicit encoding, and (on Windows only) enables virtual-terminal processing for the
# current console, which the terminal interface restores on exit.

$Script:WtRuntimeProfileCache = $null

<#
.SYNOPSIS
    True on a Windows host, on every supported runtime.
.DESCRIPTION
    $IsWindows does not exist in Windows PowerShell 5.1; the profile answers the same
    question from .NET Framework. Call sites use this instead of the automatic variable.
#>
function Test-WtIsWindows
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool](Get-WtRuntimeProfile).IsWindows
}

<#
.SYNOPSIS
    True on a Linux host, on every supported runtime.
#>
function Test-WtIsLinux
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool](Get-WtRuntimeProfile).IsLinux
}

<#
.SYNOPSIS
    True on a macOS host, on every supported runtime.
#>
function Test-WtIsMacOS
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    return [bool](Get-WtRuntimeProfile).IsMacOS
}

<#
.SYNOPSIS
    Minimum PowerShell version the application starts on.
.DESCRIPTION
    Windows PowerShell 5.1 ships with Windows 10 22H2 and Windows 11, so it is the floor:
    the bootstrap and the application have to start there. Older hosts (4.0, 3.0) are not
    supported and are refused before anything runs.
#>
function Get-WtMinimumPowerShellVersion
{
    [CmdletBinding()]
    [OutputType([version])]
    param ()

    return [version]'5.1'
}

<#
.SYNOPSIS
    PowerShell version the application is designed and validated for.
.DESCRIPTION
    Not a gate for starting: it is the version the interactive interface and every
    capability-gated feature prefer, the version the bootstrap hands off to, and the
    version the packaging tests run on.
#>
function Get-WtSupportedPowerShellVersion
{
    [CmdletBinding()]
    [OutputType([version])]
    param ()

    return [version]'7.4'
}

<#
.SYNOPSIS
    PowerShell 7 releases that have been exercised for this project.
.DESCRIPTION
    Only a range that was actually run is advertised. 7.6.9 is the runtime the test suite
    and the packaging validation ran on; 7.4 and 7.5 are supported stable releases of the
    same major line. Anything outside this range (7.0-7.3, 7.7-preview, 8.x) is reported as
    untested rather than claimed.
#>
function Get-WtTestedPowerShellRange
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    return [pscustomobject]@{
        PSTypeName       = 'WindowsTweaker.TestedRuntimeRange'
        Minimum          = [version]'7.4'
        # Exclusive upper bound: [version]'7.6' compares as 7.6.-1, so a patch release such as
        # 7.6.9 would look newer than the bound and be reported as untested.
        MaximumExclusive = [version]'7.7'
        Maximum          = [version]'7.6'
        Tested           = [version]'7.6.9'
    }
}

<#
.SYNOPSIS
    Returns the platform family, without relying on $IsWindows.
.DESCRIPTION
    $IsWindows/$IsLinux/$IsMacOS exist only in PowerShell 6+. Reading them through
    Get-Variable keeps this file valid on 5.1 (where they are absent) without a
    ParseError or a strict-mode failure, and the .NET Framework check is the fallback.
#>
function Get-WtPlatformKind
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $IsWindowsVariable = Get-Variable -Name 'IsWindows' -ValueOnly -ErrorAction Ignore
    if ($null -ne $IsWindowsVariable)
    {
        if ($IsWindowsVariable) { return 'Windows' }
        $IsLinuxVariable = Get-Variable -Name 'IsLinux' -ValueOnly -ErrorAction Ignore
        if ($IsLinuxVariable) { return 'Linux' }
        return 'MacOS'
    }

    # Windows PowerShell 5.1: .NET Framework reports the platform directly.
    try
    {
        $Platform = [System.Environment]::OSVersion.Platform
        if ($Platform -eq [System.PlatformID]::Win32NT) { return 'Windows' }
        if ($Platform -eq [System.PlatformID]::Unix) { return 'Unix' }
    }
    catch
    {
        $null = $_
    }
    return 'Unknown'
}

<#
.SYNOPSIS
    Reports the OS architecture the current process sees.
.DESCRIPTION
    System.Runtime.InteropServices.RuntimeInformation.OSArchitecture does not exist on
    .NET Framework, so it is read through reflection: on 5.1 the member is absent and the
    documented environment variables answer; on 7 the member is used.
#>
function Get-WtPlatformArchitecture
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    try
    {
        $Type = [type]::GetType('System.Runtime.InteropServices.RuntimeInformation, System.Runtime.InteropServices.RuntimeInformation')
        if ($Type)
        {
            $Property = $Type.GetProperty('OSArchitecture')
            if ($Property)
            {
                return [string]$Property.GetValue($null)
            }
        }
    }
    catch
    {
        $null = $_
    }

    # Windows PowerShell 5.1 / Windows: the environment states the process architecture,
    # and the W6432 variable states the OS architecture of a 32-bit process on 64-bit Windows.
    $Value = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch ($Value)
    {
        'AMD64' { return 'X64' }
        'ARM64' { return 'Arm64' }
        'x86' { return 'X86' }
        default { return 'Unknown' }
    }
}

<#
.SYNOPSIS
    A human-readable OS description that works on .NET Framework and .NET.
.DESCRIPTION
    RuntimeInformation.OSDescription was added in .NET Core 2.0; on 5.1 the read goes
    through reflection so this file stays compatible with the 5.1 type profile. An empty
    result is possible and the caller falls back to the platform name.
#>
function Get-WtOsDescription
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    try
    {
        $Type = [type]::GetType('System.Runtime.InteropServices.RuntimeInformation, System.Runtime.InteropServices.RuntimeInformation')
        if ($Type)
        {
            $Property = $Type.GetProperty('OSDescription')
            if ($Property)
            {
                return [string]$Property.GetValue($null)
            }
        }
    }
    catch
    {
        $null = $_
    }

    return ''
}

<#
.SYNOPSIS
    Returns a cached snapshot of the runtime the module is running on.
.PARAMETER Refresh
    Discard the cached profile and probe again.
#>
function Get-WtRuntimeProfile
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory = $false)][switch]$Refresh)

    if ($Script:WtRuntimeProfileCache -and -not $Refresh)
    {
        return $Script:WtRuntimeProfileCache
    }

    $Version = $PSVersionTable.PSVersion
    $Edition = if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
    $IsCore = ($Edition -eq 'Core')
    $Platform = Get-WtPlatformKind
    $PreRelease = ''
    try
    {
        $PreRelease = [string]$Version.PreReleaseLabel
    }
    catch
    {
        $PreRelease = ''
    }

    $Minimum = Get-WtMinimumPowerShellVersion
    $Supported = Get-WtSupportedPowerShellVersion
    $Range = Get-WtTestedPowerShellRange

    $Tier = if ($Version -lt $Minimum)
    {
        'Unsupported'
    }
    elseif (-not $IsCore)
    {
        'WindowsPowerShell'
    }
    elseif ($PreRelease)
    {
        'Preview'
    }
    elseif ($Version -ge $Range.Minimum -and $Version -lt $Range.MaximumExclusive)
    {
        'Supported'
    }
    else
    {
        'Untested'
    }

    $RuntimeProfile = [pscustomobject]@{
        PSTypeName        = 'WindowsTweaker.RuntimeProfile'
        PSEdition         = $Edition
        Version           = $Version
        Major             = $Version.Major
        Minor             = $Version.Minor
        PreRelease        = $PreRelease
        IsCore            = $IsCore
        IsWindowsPowerShell = (-not $IsCore)
        Platform          = $Platform
        IsWindows         = ($Platform -eq 'Windows')
        IsLinux           = ($Platform -eq 'Linux')
        IsMacOS           = ($Platform -eq 'MacOS')
        Architecture      = Get-WtPlatformArchitecture
        Process64Bit      = [System.Environment]::Is64BitProcess
        OS64Bit           = [System.Environment]::Is64BitOperatingSystem
        Tier              = $Tier
        MinimumVersion    = $Minimum
        SupportedVersion  = $Supported
        TestedRange       = $Range
    }

    $Script:WtRuntimeProfileCache = $RuntimeProfile
    return $RuntimeProfile
}

<#
.SYNOPSIS
    Reports whether the runtime supports one named capability.
#>
function Test-WtRuntimeCapability
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ([Parameter(Mandatory = $true)][string]$Name)

    $Detail = Get-WtRuntimeCapabilityDetail -Name $Name
    return [bool]$Detail.Supported
}

<#
.SYNOPSIS
    Explains one capability: whether it is available, on which runtime, and why not.
.DESCRIPTION
    The capability table is the single place that answers "can this runtime do X". The
    terminal interface, the CLI and the diagnostics report read it instead of testing
    $PSVersionTable themselves, so a reduced runtime is explained once, consistently and
    in the same words.
#>
function Get-WtRuntimeCapabilityDetail
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory = $true)][string]$Name)

    $RuntimeProfile = Get-WtRuntimeProfile
    $IsCore = [bool]$RuntimeProfile.IsCore

    $Supported = $false
    $Reason = ''
    $Requires = ''

    switch ($Name)
    {
        # Writing BOM-less UTF-8 is done through .NET on both runtimes, so it is never a
        # capability difference: the helper makes it true everywhere.
        'Utf8NoBomFile'
        {
            $Supported = $true
            $Reason = 'Written through System.IO with an explicit UTF8Encoding(false).'
        }

        # ConvertFrom-Json -Depth was added in PowerShell 7.0. On 5.1 the parameter is
        # omitted and the parser's own nesting bounds apply.
        'JsonDepth'
        {
            $Supported = $IsCore
            $Reason = if ($IsCore) { 'ConvertFrom-Json -Depth is available.' } else { 'Windows PowerShell 5.1 has no ConvertFrom-Json -Depth; the helper omits it.' }
            $Requires = 'PowerShell 7.0'
        }

        # ConvertFrom-Json -AsHashtable was added in PowerShell 6.0; the helper reproduces
        # the shape with an ordered-hashtable conversion on 5.1.
        'JsonAsHashtable'
        {
            $Supported = $true
            $Reason = if ($IsCore) { 'Native -AsHashtable.' } else { 'Emulated with an ordered-hashtable conversion (same keys, same values).' }
        }

        # A strict JSON document (duplicate property names, exact value kinds) is read by
        # the portable parser, so both runtimes report the same errors.
        'StrictJsonDocument'
        {
            $Supported = $true
            $Reason = 'Read by the portable strict parser (Private/Catalog/Json.ps1), identical on both runtimes.'
        }

        # Virtual-terminal colour. On Windows it has to be enabled for the console handle
        # first; Windows PowerShell 5.1 does not do that by itself.
        'VirtualTerminal'
        {
            $Supported = if ($RuntimeProfile.IsWindows) { Test-WtConsoleVirtualTerminalAvailable } elseif ($RuntimeProfile.IsLinux -or $RuntimeProfile.IsMacOS) { $true } else { $false }
            $Reason = if ($Supported) { 'The console accepts VT sequences.' } else { 'The console does not accept VT sequences; the interface falls back to its Mono palette.' }
            $Requires = if ($RuntimeProfile.IsWindows) { 'A console that supports ENABLE_VIRTUAL_TERMINAL_PROCESSING' } else { '' }
        }

        # Redirecting a child process's standard input encoding is a .NET Core property
        # (ProcessStartInfo.StandardInputEncoding). The worker client writes UTF-8 itself
        # on 5.1, so the protocol bytes are identical.
        'StandardInputEncoding'
        {
            $Supported = $true
            $Reason = 'The worker client writes UTF-8 through its own StreamWriter on every runtime.'
        }

        # SetUnixFileMode is .NET 7+. It only matters when extracting a release on Linux.
        'SetUnixFileMode'
        {
            $HasModeApi = @([System.IO.File].GetMethods() | Where-Object { $_.Name -eq 'SetUnixFileMode' }).Count -gt 0
            $Supported = if ($RuntimeProfile.IsWindows) { $false } else { $HasModeApi }
            $Reason = if ($RuntimeProfile.IsWindows) { 'Not applicable on Windows.' } else { 'Used to keep a staged worker executable.' }
            $Requires = 'PowerShell 7.3+ on Linux/macOS'
        }

        # 7.3 changed native argument passing; the application quotes its own arguments.
        'NativeArgumentPassing'
        {
            $Supported = $IsCore
            $Reason = if ($IsCore) { 'NativeArgumentPassing is available.' } else { 'Windows PowerShell passes arguments as a single string; the code quotes explicitly.' }
            $Requires = 'PowerShell 7.3'
        }

        # The optional Go worker is a native binary that speaks JSON Lines on stdin/stdout;
        # both runtimes can host it.
        'GoWorker'
        {
            $Supported = $true
            $Reason = 'JSON Lines over the child process standard streams; encodings are set explicitly.'
        }

        # The WPF interface needs .NET Framework/Windows, not PowerShell 7.
        'WpfGui'
        {
            $Supported = ($RuntimeProfile.IsWindows -and [bool](Get-Command Add-Type -ErrorAction Ignore))
            $Reason = if ($Supported) { 'PresentationFramework is available on Windows.' } else { 'Not a Windows host.' }
        }

        default
        {
            throw "Unknown runtime capability '$Name'."
        }
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.RuntimeCapability'
        Name       = $Name
        Supported  = $Supported
        Reason     = $Reason
        Requires   = $Requires
        Runtime    = [string]$RuntimeProfile.Version
    }
}

<#
.SYNOPSIS
    Lists every capability and whether this runtime has it.
#>
function Get-WtRuntimeCapabilityList
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ()

    foreach ($Name in @(
            'Utf8NoBomFile', 'JsonDepth', 'JsonAsHashtable', 'StrictJsonDocument',
            'VirtualTerminal', 'StandardInputEncoding', 'SetUnixFileMode',
            'NativeArgumentPassing', 'GoWorker', 'WpfGui'))
    {
        Get-WtRuntimeCapabilityDetail -Name $Name
    }
}

<#
.SYNOPSIS
    Reports whether a PowerShell version satisfies a minimum, without failing on strings.
#>
function Test-WtPowerShellVersion
{
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $false)][version]$Version = $PSVersionTable.PSVersion,
        [Parameter(Mandatory = $true)][version]$Minimum
    )

    return ($Version -ge $Minimum)
}

<#
.SYNOPSIS
    Reads a text file as UTF-8 on every runtime, with or without a byte-order mark.
#>
function Read-WtTextFile
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][string]$Path)

    # Get-Content -Raw -Encoding utf8 decodes UTF-8 with or without a BOM on both runtimes
    # and does not add a BOM to the string; the explicit encoding keeps 5.1 from guessing.
    return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 -ErrorAction Stop)
}

<#
.SYNOPSIS
    Writes a text file as BOM-less UTF-8 on every runtime.
.DESCRIPTION
    -Encoding utf8NoBOM does not exist in Windows PowerShell 5.1, and its -Encoding utf8
    writes a BOM. Both would corrupt files this project hashes (packs, state, journal
    exports) and the first JSONL log line, so every write goes through here instead.
.PARAMETER Append
    Append to the file instead of replacing it. A file that already carries a BOM keeps it.
.PARAMETER NoNewline
    Do not add a trailing newline (Set-Content -NoNewline).
#>
function Write-WtTextFile
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowNull()][AllowEmptyString()][string]$Value = '',
        [Parameter(Mandatory = $false)][switch]$Append,
        [Parameter(Mandatory = $false)][switch]$NoNewline
    )

    $Full = [System.IO.Path]::GetFullPath($Path)
    $Directory = Split-Path -Parent $Full
    if ($Directory -and -not (Test-Path -LiteralPath $Directory -PathType Container))
    {
        [void][System.IO.Directory]::CreateDirectory($Directory)
    }

    $Text = [string]$Value
    if (-not $NoNewline)
    {
        $Text += [System.Environment]::NewLine
    }

    $Encoding = [System.Text.UTF8Encoding]::new($false)
    if ($Append)
    {
        [System.IO.File]::AppendAllText($Full, $Text, $Encoding)
    }
    else
    {
        [System.IO.File]::WriteAllText($Full, $Text, $Encoding)
    }
}

$Script:WtAtomicReplaceSupport = $null

<#
.SYNOPSIS
    Reports whether this runtime can replace a file atomically.
.DESCRIPTION
    The state store is persisted by writing a sibling temporary file, flushing it to the
    device and then swapping it in with System.IO.File.Replace. That is the only API that
    keeps the previous contents in place until the swap has happened, so a failure can never
    leave a half-written store behind. .NET Framework (Windows PowerShell 5.1), .NET
    (PowerShell 7) and Mono provide it; a runtime without it cannot keep the durability the
    journal promises, and the write path refuses the write instead of falling back to a
    delete-then-move, which has a window where neither file is complete.
#>
function Test-WtAtomicReplaceSupported
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if ($null -ne $Script:WtAtomicReplaceSupport)
    {
        return [bool]$Script:WtAtomicReplaceSupport
    }

    # The exact overload the store uses: Replace(string, string, string, bool). Asking for the
    # method rather than trying a call keeps the probe free of side effects.
    $Signature = [type[]]@([string], [string], [string], [bool])
    $Script:WtAtomicReplaceSupport = $null -ne [System.IO.File].GetMethod('Replace', $Signature)

    return [bool]$Script:WtAtomicReplaceSupport
}

<#
.SYNOPSIS
    Writes a file so that either the complete new content or the previous content is there.
.DESCRIPTION
    The content is written to a temporary file in the destination's own directory (the only
    place guaranteed to be on the same filesystem, where a rename is a replacement rather than
    a copy), flushed to the device, and then published with one call:

      * destination missing - File.Move publishes the new file (this is the first write);
      * destination present - File.Replace swaps it and keeps the previous content available
        to the runtime for the duration of the call.

    On any failure the destination is left exactly as it was and only the temporary file is
    removed, so a failed write can never destroy the file it was replacing. The caller gets an
    error naming the destination and the reason; nothing here silently degrades to a plain
    overwrite.
.PARAMETER Path
    Destination file. The path is used as a filesystem path (`System.IO.Path.GetFullPath`),
    which is what every caller passes. A PowerShell provider path such as `HKLM:\...` is not
    a filesystem path: the runtime either rejects it (.NET Framework) or takes it as a literal
    relative name (.NET on POSIX), so nothing here accepts one deliberately. The destination's
    directory is created when it does not exist.
.PARAMETER Value
    Exact content to write (BOM-less UTF-8). No newline is added.
.OUTPUTS
    [string] the absolute path that was written.
#>
function Write-WtAtomicFile
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$Value = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path))
    {
        throw 'An atomic write needs a destination path; the path was empty.'
    }

    $Full = [System.IO.Path]::GetFullPath($Path)
    $Directory = [System.IO.Path]::GetDirectoryName($Full)
    if ($Directory) { New-WtDirectory -Path $Directory }

    if (-not (Test-WtAtomicReplaceSupported))
    {
        throw "This PowerShell runtime cannot replace a file atomically (System.IO.File.Replace is unavailable), so '$Full' was not written. WindowsTweaker needs it to keep the state store and its recovery records intact; use Windows PowerShell 5.1 or PowerShell 7."
    }

    $Temp = [System.IO.Path]::Combine($Directory, ".$([System.IO.Path]::GetFileName($Full)).$PID.$([guid]::NewGuid().ToString('n').Substring(0, 8)).tmp")

    try
    {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $Stream = [System.IO.File]::Open($Temp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try
        {
            $Stream.Write($Bytes, 0, $Bytes.Length)
            # Flush($true) flushes to the device: without it a crash can leave a directory entry
            # pointing at content that never reached the disk.
            $Stream.Flush($true)
        }
        finally
        {
            $Stream.Dispose()
        }

        if ([System.IO.File]::Exists($Full))
        {
            # The backup argument is a TYPED null. A plain $null literal bound to a [string]
            # parameter is converted to the empty string by PowerShell, and .NET then rejects
            # the empty path ("The path is not of a legal form." on .NET Framework, "The value
            # cannot be an empty string." on .NET), which made every write that replaced an
            # existing store fail.
            [System.IO.File]::Replace($Temp, $Full, [System.Management.Automation.Language.NullString]::Value, $true)
        }
        else
        {
            [System.IO.File]::Move($Temp, $Full)
        }

        return $Full
    }
    catch
    {
        throw "The file could not be written atomically: $Full. $($_.Exception.Message) (The previous file, if any, is untouched; no recovery data was replaced.)"
    }
    finally
    {
        # Only the temporary file this call created is removed, and only when the swap did not
        # publish it. The destination is never deleted here.
        if ([System.IO.File]::Exists($Temp))
        {
            Remove-Item -LiteralPath $Temp -Force -ErrorAction Ignore
        }
    }
}

<#
.SYNOPSIS
    Converts a JSON document to PowerShell objects on any runtime.
.DESCRIPTION
    Windows PowerShell 5.1 has neither ConvertFrom-Json -Depth nor -AsHashtable. The
    wrapper omits the parameter that does not exist and reproduces the hashtable shape
    when it is asked for, so callers do not branch.
.PARAMETER Depth
    Nesting bound on PowerShell 7; ignored on 5.1, where the parameter is unavailable.
.PARAMETER AsHashtable
    Return hashtables instead of PSCustomObjects.
#>
function ConvertFrom-WtJson
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $false)][int]$Depth = 32,
        [Parameter(Mandatory = $false)][switch]$AsHashtable
    )

    if ([string]::IsNullOrWhiteSpace($Text))
    {
        return $null
    }

    $RuntimeProfile = Get-WtRuntimeProfile

    # The parameters are added to the call only when this runtime has them: -Depth and
    # -AsHashtable do not exist on Windows PowerShell 5.1, and referencing them statically
    # would also make this compatibility shim itself fail the 5.1 compatibility gate.
    $Parameters = @{ InputObject = $Text; ErrorAction = 'Stop' }
    if ($RuntimeProfile.IsCore)
    {
        $Parameters['Depth'] = $Depth
        if ($AsHashtable) { $Parameters['AsHashtable'] = $true }
    }

    $Value = ConvertFrom-Json @Parameters
    if ($AsHashtable -and -not $RuntimeProfile.IsCore)
    {
        # Windows PowerShell 5.1 has no -AsHashtable: the same shape is produced by converting
        # the parsed object tree into ordered hashtables, which is what the callers index into.
        return (ConvertTo-WtHashtable -InputObject $Value)
    }

    return $Value
}

<#
.SYNOPSIS
    Converts a PSCustomObject tree into ordered hashtables, recursively.
#>
function ConvertTo-WtHashtable
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][AllowNull()]$InputObject)

    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject.GetType().IsPrimitive -or $InputObject -is [datetime])
    {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary])
    {
        $Table = New-WtOrderedDictionary
        foreach ($Key in $InputObject.Keys)
        {
            $Table[[string]$Key] = ConvertTo-WtHashtable -InputObject $InputObject[$Key]
        }
        return $Table
    }

    if ($InputObject -is [System.Collections.IEnumerable])
    {
        $Items = @()
        foreach ($Item in $InputObject)
        {
            $Items += , (ConvertTo-WtHashtable -InputObject $Item)
        }
        # The comma: a one-element array returned from a function would otherwise be unrolled
        # into the element itself, and a list of one object would stop being a list.
        return , $Items
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject])
    {
        $Table = New-WtOrderedDictionary
        foreach ($Property in $InputObject.PSObject.Properties)
        {
            $Table[$Property.Name] = ConvertTo-WtHashtable -InputObject $Property.Value
        }
        return $Table
    }

    return $InputObject
}

<#
.SYNOPSIS
    Creates an ordered dictionary with ordinal (case-sensitive) key comparison.
.DESCRIPTION
    ConvertFrom-Json -AsHashtable returns OrderedHashtable on PowerShell 7.3+, whose keys
    are case-sensitive. The 5.1 emulation has to return the same shape, or a document with
    'Id' and 'id' would behave differently on the two runtimes.
#>
function New-WtOrderedDictionary
{
    [CmdletBinding()]
    param ()

    return [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
}

<#
.SYNOPSIS
    Serializes an object to JSON text that is byte-identical on every runtime.
.DESCRIPTION
    Windows PowerShell 5.1's ConvertTo-Json escapes non-ASCII characters as \uXXXX; 7.x
    writes them as UTF-8. Both documents are valid and parse to the same values, but this
    project hashes JSON text (packs, state, journal exports) and compares stored
    revisions, so the escaping has to be one shape. The \uXXXX escapes are decoded back to
    the characters they represent, which is exactly what 7.x emits.
.PARAMETER Compress
    One line, no insignificant whitespace.
.PARAMETER Depth
    Nesting bound passed to ConvertTo-Json (present on both runtimes).
#>
function ConvertTo-WtJson
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false)][AllowNull()]$InputObject,
        [Parameter(Mandatory = $false)][int]$Depth = 8,
        [Parameter(Mandatory = $false)][switch]$Compress
    )

    if ($Compress)
    {
        $Text = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress
    }
    else
    {
        $Text = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    }

    return (ConvertFrom-WtJsonEscape -Text ([string]$Text))
}

<#
.SYNOPSIS
    Decodes JSON \uXXXX escapes so two runtimes produce the same text for the same values.
.DESCRIPTION
    Only escapes that a JSON writer introduces are decoded: a backslash that is itself
    escaped (\\, \", \n, \t, \/ ...) is left untouched, and surrogate pairs are combined.
#>
function ConvertFrom-WtJsonEscape
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    if ($Text.IndexOf('\u') -lt 0)
    {
        return $Text
    }

    $Builder = [System.Text.StringBuilder]::new($Text.Length)
    $Index = 0
    while ($Index -lt $Text.Length)
    {
        $Character = $Text[$Index]
        if ($Character -ne [char]'\' -or ($Index + 1) -ge $Text.Length)
        {
            [void]$Builder.Append($Character)
            $Index++
            continue
        }

        $Next = $Text[$Index + 1]
        if ($Next -ne 'u' -or ($Index + 5) -ge ($Text.Length + 1))
        {
            # An ordinary escape sequence: keep both characters verbatim.
            [void]$Builder.Append($Character)
            [void]$Builder.Append($Next)
            $Index += 2
            continue
        }

        $Hex = $Text.Substring($Index + 2, 4)
        $CodePoint = 0
        if ([int]::TryParse($Hex, [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$CodePoint))
        {
            $Index += 6
            if ($CodePoint -ge 0xD800 -and $CodePoint -le 0xDBFF -and ($Index + 5) -lt $Text.Length -and $Text[$Index] -eq [char]'\' -and $Text[$Index + 1] -eq [char]'u')
            {
                $Low = 0
                if ([int]::TryParse($Text.Substring($Index + 2, 4), [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Low) -and $Low -ge 0xDC00 -and $Low -le 0xDFFF)
                {
                    $CodePoint = 0x10000 + (($CodePoint - 0xD800) -shl 10) + ($Low - 0xDC00)
                    $Index += 6
                }
            }
            [void]$Builder.Append([char]::ConvertFromUtf32($CodePoint))
            continue
        }

        # Not a valid escape: keep the text as written.
        [void]$Builder.Append($Character)
        $Index++
    }

    return $Builder.ToString()
}

<#
.SYNOPSIS
    Reports whether this console accepts VT sequences, enabling them on Windows if needed.
#>
function Test-WtConsoleVirtualTerminalAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    $RuntimeProfile = Get-WtRuntimeProfile
    if (-not $RuntimeProfile.IsWindows)
    {
        return ($RuntimeProfile.IsLinux -or $RuntimeProfile.IsMacOS)
    }

    # PowerShell 7 enables VT for its own console; ask the host first.
    try
    {
        if ($Host.UI.SupportsVirtualTerminal)
        {
            return $true
        }
    }
    catch
    {
        $null = $_
    }

    return (Enable-WtConsoleVirtualTerminal)
}

<#
.SYNOPSIS
    Enables ENABLE_VIRTUAL_TERMINAL_PROCESSING for the current console, if possible.
.DESCRIPTION
    Windows PowerShell 5.1 does not enable it, so a colour terminal interface would fall
    back to no colour on a console that can actually render it. This only changes the
    current process's console mode, never the system; the terminal interface restores the
    previous mode when it exits.
#>
function Enable-WtConsoleVirtualTerminal
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    if (-not (Get-WtRuntimeProfile).IsWindows)
    {
        return $false
    }

    if (-not ('WindowsTweaker.ConsoleMode' -as [type]))
    {
        $Source = @'
using System;
using System.Runtime.InteropServices;

namespace WindowsTweaker
{
    public static class ConsoleMode
    {
        private const int StdOutputHandle = -11;
        private const uint EnableVirtualTerminalProcessing = 0x0004;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        public static bool EnableVirtualTerminal(out uint previousMode)
        {
            previousMode = 0;
            IntPtr handle = GetStdHandle(StdOutputHandle);
            uint mode;
            if (!GetConsoleMode(handle, out mode))
            {
                return false;
            }
            previousMode = mode;
            if ((mode & EnableVirtualTerminalProcessing) == EnableVirtualTerminalProcessing)
            {
                return true;
            }
            return SetConsoleMode(handle, mode | EnableVirtualTerminalProcessing);
        }

        public static bool Restore(uint mode)
        {
            if (mode == 0)
            {
                return false;
            }
            return SetConsoleMode(GetStdHandle(StdOutputHandle), mode);
        }
    }
}
'@
        try
        {
            Add-Type -TypeDefinition $Source -ErrorAction Stop
        }
        catch
        {
            # A host that cannot compile the helper simply gets no colour.
            return $false
        }
    }

    try
    {
        $Previous = [uint32]0
        $Enabled = [bool][WindowsTweaker.ConsoleMode]::EnableVirtualTerminal([ref]$Previous)
        if ($Enabled -and $Previous -ne 0 -and $null -eq $Script:WtConsoleModePrevious)
        {
            # Remembered so Restore-WtConsoleVirtualTerminal can put the console back.
            $Script:WtConsoleModePrevious = $Previous
        }
        return $Enabled
    }
    catch
    {
        return $false
    }
}

<#
.SYNOPSIS
    Restores the console mode that existed before VT processing was enabled.
.DESCRIPTION
    Safe to call when nothing was changed, and safe on a runtime without the API. The
    terminal interface calls it from its finally block, so a normal exit, Ctrl+C and a
    crash all leave the console as it was found.
#>
function Restore-WtConsoleVirtualTerminal
{
    [CmdletBinding()]
    param ()

    if ($null -eq $Script:WtConsoleModePrevious)
    {
        return $false
    }
    if ('WindowsTweaker.ConsoleMode' -as [type])
    {
        try
        {
            [void][WindowsTweaker.ConsoleMode]::Restore([uint32]$Script:WtConsoleModePrevious)
        }
        catch
        {
            $null = $_
        }
    }
    $Script:WtConsoleModePrevious = $null
    return $true
}

<#
.SYNOPSIS
    Builds the exact command line that runs this project on a compatible pwsh.
.DESCRIPTION
    Used by the module when a capability needs a newer runtime, and by the diagnostics
    report. The bootstrap builds the same command for its relaunch; tests assert that both
    produce the same string for the same inputs.
#>
function Get-WtRuntimeHandoffCommand
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)][string]$EntryPoint,
        [Parameter(Mandatory = $false)][string]$PwshPath = 'pwsh',
        [Parameter(Mandatory = $false)][string[]]$Arguments = @()
    )

    $QuotedEntry = "'" + ($EntryPoint -replace "'", "''") + "'"
    $Parts = @($PwshPath, '-NoProfile', '-File', $QuotedEntry)
    foreach ($Argument in @($Arguments))
    {
        if ($null -eq $Argument -or $Argument -eq '') { continue }
        $Parts += ("'" + ([string]$Argument -replace "'", "''") + "'")
    }
    return ($Parts -join ' ')
}

<#
.SYNOPSIS
    Finds installed PowerShell 7 executables and reports which ones are usable.
.DESCRIPTION
    PATH and the documented installation locations are searched; every candidate is probed
    by running it, never by trusting its file name, and preview builds are reported but
    never selected. The bootstrap carries the same discovery (it has to run before
    anything is downloaded) and tests/Bootstrap.Tests.ps1 asserts both return the same
    decision for the same fakes.
.PARAMETER Path
    Additional explicit candidates, probed like the discovered ones.
#>
function Get-WtCompatiblePwshCandidate
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param ([Parameter(Mandatory = $false)][string[]]$Path = @())

    $RuntimeProfile = Get-WtRuntimeProfile
    $Minimum = Get-WtSupportedPowerShellVersion
    $Range = Get-WtTestedPowerShellRange

    $Candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($Explicit in @($Path))
    {
        if ($Explicit) { $Candidates.Add($Explicit) }
    }

    $OnPath = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction Ignore
    foreach ($Command in @($OnPath))
    {
        if ($Command -and $Command.Source) { $Candidates.Add($Command.Source) }
    }

    if ($RuntimeProfile.IsWindows)
    {
        foreach ($Root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA))
        {
            if (-not $Root) { continue }
            $Candidates.Add((Join-Path $Root 'PowerShell/7/pwsh.exe'))
            $Candidates.Add((Join-Path $Root 'Microsoft/WindowsApps/pwsh.exe'))
        }
    }
    else
    {
        foreach ($Location in @(
                '/usr/bin/pwsh', '/usr/local/bin/pwsh', '/opt/microsoft/powershell/7/pwsh',
                '/snap/bin/pwsh', '/opt/homebrew/bin/pwsh', '/usr/local/microsoft/powershell/7/pwsh'))
        {
            $Candidates.Add($Location)
        }
    }

    $Seen = @{}
    $Results = @()
    foreach ($Candidate in $Candidates)
    {
        $Full = [string]$Candidate
        if (-not $Full) { continue }
        try { $Full = [System.IO.Path]::GetFullPath($Full) } catch { continue }
        if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { continue }

        # A store alias or a /usr/bin -> /opt symlink is the same installation; probing it
        # twice would only produce two rows for one runtime.
        $Identity = $Full
        try
        {
            $Item = Get-Item -LiteralPath $Full -ErrorAction Ignore
            if ($Item -and $Item.PSObject.Properties['Target'] -and $Item.Target)
            {
                $Identity = [System.IO.Path]::GetFullPath([string]$Item.Target)
            }
        }
        catch
        {
            $null = $_
        }
        if ($Seen.ContainsKey($Identity)) { continue }
        $Seen[$Identity] = $true

        $Results += (Read-WtPwshCandidate -Path $Full -Minimum $Minimum -Range $Range)
    }

    # The highest compatible version wins; among equals the first one found (PATH before the
    # installation directories) wins, so the runtime the user gets from `pwsh` is the one used.
    $Best = $null
    foreach ($Result in $Results)
    {
        if (-not $Result.Compatible) { continue }
        if ($null -eq $Best -or $Result.Version -gt $Best.Version)
        {
            $Best = $Result
        }
    }
    foreach ($Result in $Results)
    {
        if ($Result.Selected -and $Best -and $Result.Path -ne $Best.Path)
        {
            $Result.Selected = $false
            $Result.Reason = "PowerShell $($Best.Version) was selected."
        }
    }

    return @($Results)
}

<#
.SYNOPSIS
    Probes one candidate executable and classifies it.
#>
function Read-WtPwshCandidate
{
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][version]$Minimum,
        [Parameter(Mandatory = $true)][pscustomobject]$Range
    )

    $Result = [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.PwshCandidate'
        Path       = $Path
        Version    = $null
        Edition    = ''
        Architecture = ''
        Preview    = $false
        Compatible = $false
        Selected   = $false
        Reason     = ''
    }

    # Probing runs the candidate with a fixed, non-interactive command that prints the
    # runtime facts; a file name is never trusted.
    $Probe = '"[{0}]|{1}|{2}" -f $PSVersionTable.PSVersion.ToString(), $PSVersionTable.PSEdition, $env:PROCESSOR_ARCHITECTURE'
    $Output = @()
    try
    {
        $Output = @(& $Path -NoProfile -NonInteractive -Command $Probe 2>$null)
    }
    catch
    {
        $Result.Reason = "Could not be started: $($_.Exception.Message)"
        return $Result
    }

    $Line = [string](@($Output | Where-Object { $_ -and ([string]$_).Trim() -ne '' }) | Select-Object -First 1)
    if (-not $Line) { $Line = [string]($Output | Select-Object -First 1) }
    if ($Line -notmatch '^\[(?<v>[^\]]+)\]\|(?<e>[^|]*)\|(?<a>.*)$')
    {
        $Result.Reason = 'Did not report a version.'
        return $Result
    }

    # A preview build reports a semantic version such as '7.7.0-preview.3', which
    # [version]::TryParse rejects; the numeric part is parsed and the suffix is what marks
    # the build as a preview.
    $RawVersion = $Matches['v']
    $IsPreview = ($RawVersion -match '-') -or ($Path -match '(?i)preview')
    $NumericVersion = ($RawVersion -split '-')[0]
    $Version = $null
    if (-not [version]::TryParse($NumericVersion, [ref]$Version))
    {
        $Result.Reason = "Reported an unparsable version '$RawVersion'."
        return $Result
    }

    $Result.Version = $Version
    $Result.Edition = $Matches['e']
    $Result.Architecture = $Matches['a']
    $Result.Preview = [bool]$IsPreview

    if ($Result.Preview)
    {
        $Result.Reason = 'Preview build: never selected automatically.'
        return $Result
    }
    if ($Version -lt $Minimum)
    {
        $Result.Reason = "PowerShell $Version is older than $Minimum."
        return $Result
    }
    if ($Version -ge $Range.MaximumExclusive -or $Version.Major -gt 7)
    {
        $Result.Reason = "PowerShell $Version is outside the tested range ($($Range.Minimum)-$($Range.Maximum))."
        return $Result
    }
    if ($Version -lt $Range.Minimum)
    {
        $Result.Reason = "PowerShell $Version is older than the supported stable line $($Range.Minimum)."
        return $Result
    }

    $Result.Compatible = $true
    $Result.Selected = $true
    $Result.Reason = 'Stable, compatible build.'
    return $Result
}

<#
.SYNOPSIS
    Builds the bilingual start-up notice for a runtime outside the validated range.
.DESCRIPTION
    A reduced or untested runtime is never a silent downgrade: the notice names the current
    version, the validated range, and the exact command that runs the same entry point on a
    validated runtime. It returns '' for a validated runtime, so the caller can print it
    unconditionally. Vietnamese first, then English.
#>
function Get-WtRuntimeStartupNotice
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false)][object]$RuntimeProfile,
        [Parameter(Mandatory = $false)][string]$EntryPoint
    )

    if (-not $RuntimeProfile)
    {
        $RuntimeProfile = Get-WtRuntimeProfile
    }
    if ($RuntimeProfile.Tier -eq 'Supported')
    {
        return ''
    }

    $Handoff = Get-WtRuntimeHandoffCommand -EntryPoint $EntryPoint -PwshPath 'pwsh'
    $Range = $RuntimeProfile.TestedRange

    switch ($RuntimeProfile.Tier)
    {
        'WindowsPowerShell'
        {
            return (Get-WtRuntimeMessage -Key 'Runtime.Notice.WindowsPowerShell' -Arguments @($RuntimeProfile.Version, $RuntimeProfile.SupportedVersion, $Handoff))
        }
        'Preview'
        {
            return (Get-WtRuntimeMessage -Key 'Runtime.Notice.Preview' -Arguments @($RuntimeProfile.Version, $Range.Minimum, $Range.Maximum))
        }
        'Untested'
        {
            return (Get-WtRuntimeMessage -Key 'Runtime.Notice.Untested' -Arguments @($RuntimeProfile.Version, $Range.Minimum, $Range.Maximum))
        }
    }

    return ''
}

<#
.SYNOPSIS
    Renders the runtime report: profile, capabilities and the validated range.
.DESCRIPTION
    Read-only, and the same text on every runtime, so a user on Windows PowerShell 5.1 can
    paste it into a report. `WindowsTweaker.ps1 -RuntimeReport` prints exactly this.
#>
function Get-WtRuntimeReportText
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][string]$EntryPoint)

    $RuntimeProfile = Get-WtRuntimeProfile
    $Range = $RuntimeProfile.TestedRange
    $Lines = [System.Collections.Generic.List[string]]::new()

    $Lines.Add((Get-WtRuntimeMessage -Key 'Runtime.Report.Title'))
    $Lines.Add('')
    $Lines.Add(("PowerShell          : {0} ({1})" -f $RuntimeProfile.Version, $RuntimeProfile.PSEdition))
    $Lines.Add(("Platform            : {0} {1}" -f $RuntimeProfile.Platform, $RuntimeProfile.Architecture))
    $Lines.Add(("Process / OS 64-bit : {0} / {1}" -f $RuntimeProfile.Process64Bit, $RuntimeProfile.OS64Bit))
    $Lines.Add(("Tier                : {0}" -f $RuntimeProfile.Tier))
    $Lines.Add(("Validated range     : {0}-{1} (tested on {2})" -f $Range.Minimum, $Range.Maximum, $Range.Tested))
    $Lines.Add(("Minimum to start    : {0}" -f $RuntimeProfile.MinimumVersion))
    $Lines.Add('')
    foreach ($Capability in @(Get-WtRuntimeCapabilityList))
    {
        $State = if ($Capability.Supported) { 'yes' } else { 'no' }
        # One line per capability in the session's language: the bilingual wrapper is for
        # messages that must be readable before localization is loaded, not for a table.
        $Lines.Add((Get-WtString -Key 'Runtime.Report.Capability' -Arguments @($Capability.Name, $State, $Capability.Reason)))
    }

    if ($RuntimeProfile.Tier -ne 'Supported' -and $EntryPoint)
    {
        $Lines.Add('')
        $Lines.Add((Get-WtRuntimeHandoffCommand -EntryPoint $EntryPoint -PwshPath 'pwsh'))
    }

    return ($Lines -join [System.Environment]::NewLine)
}

<#
.SYNOPSIS
    Composes the bilingual message shown when a newer runtime is required.
.DESCRIPTION
    Vietnamese first (the project's default interface language), then English, in one
    block: the same text goes to the Windows PowerShell 5.1 console, whose code page may
    not render diacritics, so the ASCII English half is the fallback the user can read.
#>
function Get-WtRuntimeMessage
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)][object[]]$Arguments = @()
    )

    # Get-WtString returns '[Key]' for a key the table does not carry; that sentinel must not
    # be printed as if it were text.
    $Vietnamese = [string](Get-WtString -Key $Key -Language 'vi' -Arguments $Arguments)
    $English = [string](Get-WtString -Key $Key -Language 'en' -Arguments $Arguments)
    $Vietnamese = if ($Vietnamese -match '^\[[^\]]+\]$') { '' } else { $Vietnamese }
    $English = if ($English -match '^\[[^\]]+\]$') { '' } else { $English }

    if (-not $Vietnamese -and -not $English) { return '' }
    if (-not $Vietnamese) { return $English }
    if (-not $English) { return $Vietnamese }
    return ($Vietnamese + [System.Environment]::NewLine + $English)
}