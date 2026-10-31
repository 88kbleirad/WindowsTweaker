# WindowsTweaker - PowerShell implementation of the directory scan capability.
#
# This is the fallback (and the comparison baseline) for the optional Go worker: it produces
# the same result shape, so the interface, the tests and the benchmark can treat both
# backends identically and a regression is visible instead of hidden.
#
# Documented differences from the Go worker, both reported in the result itself:
#   * allocation size: no managed API exposes the on-disk allocation, so AllocatedKnown is
#     false and AllocatedNote says so (the Go worker reports it on Unix);
#   * hard links: identifying them needs the file index, which .NET does not expose portably,
#     so HardLinksDeduped stays 0 and HardLinkNote says so.

$Script:WtScanMaxErrors = 200
$Script:WtScanMaxDepth = 128
$Script:WtScanMaxLargest = 20
$Script:WtScanProgressEveryMs = 250

<#
.SYNOPSIS
    Aggregates the size of a directory tree, read-only.
.DESCRIPTION
    Iterative (no recursion, so a deep tree cannot exhaust the stack), bounded (depth cap,
    bounded error list and largest-files list), and cancellable: -CancelCheck is called
    between directories and may ask the caller to stop. A tree that cannot be read completely
    returns Partial = $true with the structured errors, never a false success.
.PARAMETER Path
    Absolute directory to aggregate. Symbolic links and reparse points are never followed.
.PARAMETER MaxDepth
    Depth cap; clamped to the documented maximum.
.PARAMETER Progress
    Called at most every 250 ms with @{ Files; Directories; Bytes; AllocatedBytes; Errors; ElapsedMs }.
.PARAMETER CancelCheck
    Called between directories; returning $true stops the walk and reports Cancelled = $true.
.OUTPUTS
    The same shape as the worker's scan.directory result, plus Backend = 'PowerShell'.
#>
function Get-WtDirectorySize
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][int]$MaxDepth = 0,
        [Parameter(Mandatory = $false)][switch]$SkipLinks,
        [Parameter(Mandatory = $false)][scriptblock]$Progress,
        [Parameter(Mandatory = $false)][scriptblock]$CancelCheck
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path))
    {
        throw (Get-WtString -Key 'Worker.Reason.RootInvalid')
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container))
    {
        throw (Get-WtString -Key 'Worker.Reason.RootMissing' -Arguments @($Path))
    }

    if ($MaxDepth -le 0 -or $MaxDepth -gt $Script:WtScanMaxDepth)
    {
        $MaxDepth = $Script:WtScanMaxDepth
    }

    $Started = [datetime]::UtcNow
    $LastProgress = $Started
    $Stack = [System.Collections.Generic.Stack[object]]::new()
    $Stack.Push(@{ Path = $Path; Depth = 0 })

    $Files = [long]0
    $Directories = [long]0
    $Bytes = [long]0
    $SkippedLinks = [long]0
    $SkippedOther = [long]0
    $Errors = [System.Collections.Generic.List[object]]::new()
    $Largest = [System.Collections.Generic.List[object]]::new()
    $Cancelled = $false

    # A hashtable, not two scalars: the capture blocks below run in their own scope, so
    # assigning to a local scalar there would be lost and truncation would never be reported.
    $Flags = @{ ErrorsTruncated = $false; LargestTruncated = $false }

    $Record = {
        param ([string]$Code, [string]$Target, [string]$Detail)

        if ($Errors.Count -ge $Script:WtScanMaxErrors)
        {
            $Flags.ErrorsTruncated = $true
            return
        }

        $Errors.Add([pscustomobject]@{ code = $Code; path = $Target; error = $Detail })
    }

    $Remember = {
        param ([string]$File, [long]$Size)

        if ($Largest.Count -eq $Script:WtScanMaxLargest -and $Size -le [long]$Largest[$Largest.Count - 1].bytes)
        {
            $Flags.LargestTruncated = $true
            return
        }

        $Largest.Add([pscustomobject]@{ path = $File; bytes = $Size })
        $Sorted = @($Largest | Sort-Object -Property bytes -Descending | Select-Object -First $Script:WtScanMaxLargest)
        $Largest.Clear()
        foreach ($Entry in $Sorted) { $Largest.Add($Entry) }
        if ($Sorted.Count -eq $Script:WtScanMaxLargest) { $Flags.LargestTruncated = $true }
    }

    while ($Stack.Count -gt 0)
    {
        if ($CancelCheck -and (& $CancelCheck))
        {
            $Cancelled = $true
            break
        }

        $Current = $Stack.Pop()
        $Directories++

        try
        {
            $Entries = [System.IO.Directory]::EnumerateFileSystemEntries($Current.Path)
        }
        catch
        {
            & $Record 'E_ACCESS_DENIED' $Current.Path $_.Exception.Message
            continue
        }

        # EnumerateFileSystemEntries is lazy: the catch above only covers opening the
        # directory, so the loop below has its own guard for an entry that disappears.
        $Enumerator = $Entries.GetEnumerator()
        while ($true)
        {
            $EntryPath = $null
            try
            {
                if (-not $Enumerator.MoveNext())
                {
                    break
                }

                $EntryPath = $Enumerator.Current
            }
            catch
            {
                & $Record 'E_IO' $Current.Path $_.Exception.Message
                break
            }

            try
            {
                $Attributes = [System.IO.File]::GetAttributes($EntryPath)

                if (($Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
                {
                    $SkippedLinks++
                    continue
                }

                if (($Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
                {
                    if ($Current.Depth + 1 -le $MaxDepth)
                    {
                        $Stack.Push(@{ Path = $EntryPath; Depth = $Current.Depth + 1 })
                    }
                    else
                    {
                        $SkippedOther++
                    }

                    continue
                }

                $Info = [System.IO.FileInfo]::new($EntryPath)
                $Size = [long]$Info.Length
                $Files++
                $Bytes += $Size
                & $Remember $EntryPath $Size
            }
            catch
            {
                if ($EntryPath)
                {
                    & $Record 'E_IO' $EntryPath $_.Exception.Message
                }
            }
        }

        if ($Progress)
        {
            $Now = [datetime]::UtcNow
            if (($Now - $LastProgress).TotalMilliseconds -ge $Script:WtScanProgressEveryMs)
            {
                $LastProgress = $Now
                & $Progress @{
                    Files          = $Files
                    Directories    = $Directories
                    Bytes          = $Bytes
                    AllocatedBytes = $Bytes
                    SkippedLinks   = $SkippedLinks
                    SkippedOther   = $SkippedOther
                    Errors         = $Errors.Count
                    ElapsedMs      = [int]($Now - $Started).TotalMilliseconds
                }
            }
        }
    }

    $Elapsed = [int]([datetime]::UtcNow - $Started).TotalMilliseconds

    return [pscustomobject]@{
        PSTypeName       = 'WindowsTweaker.DirectoryScan'
        Backend          = 'PowerShell'
        Root             = $Path
        Files            = $Files
        Directories      = $Directories
        Bytes            = $Bytes
        AllocatedBytes   = $Bytes
        AllocatedKnown   = $false
        AllocatedNote    = Get-WtString -Key 'Worker.Note.AllocatedUnknown'
        SizeKind         = 'logical'
        SkippedLinks     = $SkippedLinks
        SkippedOther     = $SkippedOther
        HardLinksDeduped = 0
        HardLinkNote     = Get-WtString -Key 'Worker.Note.HardLinksUnknown'
        Errors           = @($Errors.ToArray())
        ErrorsTruncated  = [bool]$Flags.ErrorsTruncated
        Partial          = [bool]($Errors.Count -gt 0 -or $Flags.ErrorsTruncated)
        Cancelled        = [bool]$Cancelled
        ElapsedMS        = $Elapsed
        Workers          = 1
        Largest          = @($Largest.ToArray())
        LargestTruncated = [bool]$Flags.LargestTruncated
    }
}

<#
.SYNOPSIS
    Lists the direct children of a directory with per-subdirectory subtree aggregates
    (PowerShell implementation, the fallback for the worker's scan.children capability).
.DESCRIPTION
    Read-only and cancellable: -CancelCheck is called between children and may stop the
    listing. Each subdirectory is aggregated with the same Get-WtDirectorySize walk; a
    child that cannot be read is listed with its error instead of aborting the listing.
    The shape is the same as the worker's scan.children result, so the caller cannot tell
    the backends apart except through the Backend field.
.OUTPUTS
    Object with Root, Entries, ErrorsTruncated, Cancelled, ElapsedMS and Backend.
#>
function Get-WtDirectoryChildrenFallback
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][scriptblock]$CancelCheck
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path))
    {
        throw (Get-WtString -Key 'Worker.Reason.RootInvalid')
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container))
    {
        throw (Get-WtString -Key 'Worker.Reason.RootMissing' -Arguments @($Path))
    }

    $Started = [datetime]::UtcNow
    $Cancelled = $false
    $Entries = [System.Collections.Generic.List[object]]::new()

    try
    {
        $Children = [System.IO.Directory]::EnumerateFileSystemEntries($Path)
    }
    catch
    {
        throw (Get-WtString -Key 'Worker.Reason.AccessDenied' -Arguments @($Path))
    }

    foreach ($Child in @($Children))
    {
        if ($CancelCheck -and (& $CancelCheck))
        {
            $Cancelled = $true
            break
        }

        $Name = [System.IO.Path]::GetFileName($Child)
        $Entry = [pscustomobject]@{
            name            = $Name
            path            = $Child
            kind            = 'other'
            bytes           = [long]0
            allocatedBytes  = [long]0
            allocatedKnown  = $false
            files           = [long]0
            directories     = [long]0
            skippedLinks    = [long]0
            partial         = $false
            errors          = @()
            error           = ''
        }

        try
        {
            $Attributes = [System.IO.File]::GetAttributes($Child)
        }
        catch
        {
            $Entry.error = "E_IO: $($_.Exception.Message)"
            $Entries.Add($Entry)
            continue
        }

        if (($Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        {
            $Entry.kind = 'link'
            $Entries.Add($Entry)
            continue
        }

        if (($Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
        {
            $Entry.kind = 'dir'
            try
            {
                $Sub = Get-WtDirectorySize -Path $Child
                $Entry.bytes = $Sub.Bytes
                $Entry.allocatedBytes = $Sub.AllocatedBytes
                $Entry.allocatedKnown = [bool]$Sub.AllocatedKnown
                $Entry.files = $Sub.Files
                $Entry.directories = $Sub.Directories
                $Entry.skippedLinks = $Sub.SkippedLinks
                $Entry.partial = [bool]$Sub.Partial
                $Entry.errors = @($Sub.Errors)
            }
            catch
            {
                $Entry.error = $_.Exception.Message
                $Entry.partial = $true
            }
            $Entries.Add($Entry)
            continue
        }

        try
        {
            $Info = [System.IO.FileInfo]::new($Child)
            $Entry.kind = 'file'
            $Entry.bytes = [long]$Info.Length
            $Entry.files = 1
        }
        catch
        {
            $Entry.error = "E_IO: $($_.Exception.Message)"
        }
        $Entries.Add($Entry)
    }

    return [pscustomobject]@{
        PSTypeName      = 'WindowsTweaker.DirectoryChildren'
        Backend         = 'PowerShell'
        Root            = $Path
        Entries         = @($Entries.ToArray())
        ErrorsTruncated = $false
        Cancelled       = [bool]$Cancelled
        ElapsedMS       = [int]([datetime]::UtcNow - $Started).TotalMilliseconds
    }
}
