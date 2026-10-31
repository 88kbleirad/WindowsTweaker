# WindowsTweaker - in-terminal disk usage explorer.
#
# Read-only directory browsing built on the worker's scan.children capability (with the
# PowerShell implementation as the fallback). One level at a time: a directory listing with
# per-subdirectory subtree aggregates is fetched on demand and cached, so no heavy recursive
# walk runs on every redraw. Nothing is deleted, moved, hydrated or permission-modified.
#
# Honesty rules this surface:
#   * sizes are logical bytes unless the backend reports allocated size, and the result
#     states which one it is;
#   * a directory that could not be fully read is reported as partial with its structured
#     errors; a scan that was cancelled keeps the partial results gathered so far;
#   * the report never claims that scanned bytes are reclaimable;
#   * symlinks and reparse points are listed but never followed.

<#
.SYNOPSIS
    Formats a byte count for display (1024-based units).
#>
function Format-WtDiskBytes
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][long]$Bytes)

    if ($Bytes -lt 1024) { return "$Bytes B" }

    $Units = 'KB', 'MB', 'GB', 'TB', 'PB'
    $Value = [double]$Bytes
    $Index = -1
    do
    {
        $Value = $Value / 1024
        $Index++
    }
    while ($Value -ge 1024 -and $Index -lt $Units.Count - 1)

    return ('{0:N1} {1}' -f $Value, $Units[$Index])
}

<#
.SYNOPSIS
    Returns the display text for one child entry.
#>
function Format-WtDiskEntry
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $false)][string]$Mode = 'size'
    )

    switch ([string]$Entry.kind)
    {
        'dir'
        {
            $Size = Format-WtDiskBytes -Bytes ([long]$Entry.bytes)
            $Count = if ($Entry.directories -gt 0) { "$($Entry.files) files / $($Entry.directories) dirs" } else { "$($Entry.files) files" }
            if ($Mode -eq 'files') { return "$Size | $Count" }
            return "$Size ($Count)"
        }
        'link' { return (Get-WtString -Key 'Disk.Link') }
        'file' { return (Format-WtDiskBytes -Bytes ([long]$Entry.bytes)) }
        default { return (Get-WtString -Key 'Disk.Error' -Arguments @($Entry.error)) }
    }
}

<#
.SYNOPSIS
    Builds the sorted child items for the current directory.
#>
function Get-WtDiskExplorerItems
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Cache
    )

    $Items = [System.Collections.Generic.List[object]]::new()
    $Path = [string]$Cache.Path

    # Up level: only when the current directory is not the root of the browse.
    if ($Cache.Root -and $Path -ne $Cache.Root)
    {
        $Parent = [System.IO.Path]::GetDirectoryName($Path)
        if ($Parent)
        {
            $Items.Add(@{
                Label    = '..'
                Right    = ''
                Payload  = @{ Action = 'Up'; Path = $Parent }
                Filter   = '.. up parent'
                Disabled = $false
                Checked  = $false
                Icon     = 'Action.Restore'
            })
        }
    }

    $Entries = @($Cache.Listing.Entries)
    $Mode = [string]$Cache.Sort

    $Sorted = switch ($Mode)
    {
        'files' { @($Entries | Sort-Object -Property @{ Expression = { [long]$_.files }; Descending = $true }, @{ Expression = { [string]$_.name } }) }
        'name'  { @($Entries | Sort-Object -Property @{ Expression = { [string]$_.name } }) }
        default { @($Entries | Sort-Object -Property @{ Expression = { [long]$_.bytes }; Descending = $true }, @{ Expression = { [string]$_.name } }) }
    }

    foreach ($Entry in $Sorted)
    {
        $Kind = [string]$Entry.kind
        $Icon = switch ($Kind) { 'dir' { 'Category.Dashboard' } 'file' { 'Action.Search' } 'link' { 'Action.Restore' } default { 'Action.Refresh' } }

        $Items.Add(@{
            Label    = [string]$Entry.name
            Right    = Format-WtDiskEntry -Entry $Entry -Mode $Mode
            Payload  = @{ Action = 'Open'; Path = [string]$Entry.path; Entry = $Entry }
            Filter   = "$($Entry.name) $Kind"
            Disabled = $false
            Checked  = $false
            Icon     = $Icon
        })
    }

    return $Items.ToArray()
}

<#
.SYNOPSIS
    Lists one directory through the selected backend, with a bounded cancel check.
#>
function Get-WtDiskExplorerListing
{
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $WorkerPath = $State.WorkerBackend
    $Result = Invoke-WtDirectoryChildren -Root $Path -Backend $WorkerPath

    if (-not $Result.Ok)
    {
        return @{
            Ok = $false
            Message = [string]$Result.Message
        }
    }

    # The backend returns the listing flat; a double wrap would hide its Entries.
    $Listing = if ($Result.Listing) { $Result.Listing } else { $Result }

    return @{
        Ok = $true
        Listing = $Listing
    }
}

<#
.SYNOPSIS
    Exports the current directory report as TXT or JSON.
.DESCRIPTION
    Writes only after an explicit path confirmation. TXT is a readable listing with the
    size kind, coverage and errors named; JSON is the structured result as returned by the
    backend. Neither implies the bytes are reclaimable.
#>
function Export-WtDiskExplorerReport
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Cache
    )

    $Format = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Disk.ExportTitle') -Lines @(
            (Get-WtString -Key 'Disk.ExportHint')) -Items @(
            @{ Label = 'TXT'; Payload = 'txt'; Filter = 'text txt'; Disabled = $false; Checked = $false }
            @{ Label = 'JSON'; Payload = 'json'; Filter = 'json'; Disabled = $false; Checked = $false }
        ) -EmptyText (Get-WtString -Key 'Tui.NoItems')

    if ($null -eq $Format -or $null -eq $Format.Value)
    {
        return
    }

    $Extension = [string]$Format.Value
    $Initial = Join-Path ([System.IO.Path]::GetTempPath()) ("disk-report-{0}.$Extension" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))

    $Path = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Disk.ExportTitle') `
        -Label (Get-WtString -Key 'Disk.ExportPathLabel') -Initial $Initial `
        -Lines @((Get-WtString -Key 'Disk.ExportHint')) -Validate {
            param ($Text)

            if ([string]::IsNullOrWhiteSpace($Text)) { return (Get-WtString -Key 'Tui.Path.Required') }

            $Trimmed = $Text.Trim()
            if (-not [System.IO.Path]::IsPathRooted($Trimmed))
            {
                return (Get-WtString -Key 'Tui.Path.NotAbsolute')
            }

            if ([System.IO.Path]::GetExtension($Trimmed) -ne ".$Extension")
            {
                return (Get-WtString -Key 'Tui.Path.NeedsJson')
            }

            if (Test-Path -LiteralPath $Trimmed)
            {
                return (Get-WtString -Key 'Tui.Path.Exists' -Arguments @($Trimmed))
            }

            $Parent = [System.IO.Path]::GetDirectoryName($Trimmed)
            if (-not (Test-Path -LiteralPath $Parent))
            {
                return (Get-WtString -Key 'Tui.Path.NoDirectory' -Arguments @($Parent))
            }

            return ''
        }

    if (-not $Path)
    {
        return
    }

    $Listing = $Cache.Listing
    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add("WindowsTweaker disk report")
    $Lines.Add("Directory: $($Listing.Root)")
    $Lines.Add("Backend: $($Listing.Backend)")
    $Lines.Add("Elapsed (ms): $($Listing.ElapsedMS)")
    $Lines.Add("Cancelled: $($Listing.Cancelled)")
    $Lines.Add("Size kind: $(if ($Listing.Entries[0] -and $Listing.Entries[0].allocatedKnown) { 'logical+allocated' } else { 'logical' })")
    $Lines.Add("Note: sizes are report measurements, not reclaimable space.")
    $Lines.Add('')
    $Lines.Add("Name`tKind`tLogicalBytes`tAllocatedBytes`tFiles`tDirectories`tPartial`tErrors")

    foreach ($Entry in @($Listing.Entries))
    {
        $Err = if ($Entry.error) { $Entry.error } elseif (@($Entry.errors).Count -gt 0) { (@($Entry.errors) | ForEach-Object { "$($_.code): $($_.path)" }) -join '; ' } else { '' }
        $Lines.Add(("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}" -f `
                $Entry.name, $Entry.kind, $Entry.bytes, $Entry.allocatedBytes, $Entry.files, $Entry.directories, $Entry.partial, $Err))
    }

    if ($Extension -eq 'json')
    {
        $Payload = [ordered]@{
            root      = $Listing.Root
            backend   = $Listing.Backend
            elapsedMs = $Listing.ElapsedMS
            cancelled = $Listing.Cancelled
            entries   = @($Listing.Entries)
        }
        $Lines = @(ConvertTo-WtJson -InputObject $Payload -Depth 8)
    }

    try
    {
        Write-WtTextFile -Path $Path -Value ($Lines -join "`n")
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Disk.ExportTitle') -Lines @((Get-WtString -Key 'Disk.ExportDone' -Arguments @($Path))) -Tone 'Success'
    }
    catch
    {
        Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Disk.ExportTitle') -Lines @($_.Exception.Message) -Tone 'Error'
    }
}

<#
.SYNOPSIS
    Opens the disk usage explorer.
.DESCRIPTION
    Root selection happens once; afterwards the list browses one level at a time. The
    listing of a visited directory is cached (bounded), so moving up and down does not
    rescan what was already scanned.
#>
function Show-WtTuiDiskExplorer
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$State)

    if (-not $State.Explorer)
    {
        $Default = $HOME
        $Root = Read-WtTuiText -State $State -Title (Get-WtString -Key 'Disk.Title') `
            -Label (Get-WtString -Key 'Disk.RootPrompt') -Initial $Default `
            -Lines @((Get-WtString -Key 'Disk.RootHint')) -Validate {
                param ($Text)

                if ([string]::IsNullOrWhiteSpace($Text)) { return (Get-WtString -Key 'Tui.Path.Required') }

                $Trimmed = $Text.Trim()
                if (-not [System.IO.Path]::IsPathRooted($Trimmed))
                {
                    return (Get-WtString -Key 'Tui.Path.NotAbsolute')
                }

                if (-not (Test-Path -LiteralPath $Trimmed -PathType Container))
                {
                    return (Get-WtString -Key 'Worker.Reason.RootMissing' -Arguments @($Trimmed))
                }

                return ''
            }

        if (-not $Root)
        {
            return
        }

        $State.Explorer = @{
            Path  = $Root
            Root  = $Root
            Sort  = 'size'
            Cache = @{}
        }
    }

    while ($true)
    {
        $Explorer = $State.Explorer
        $Path = [string]$Explorer.Path

        if (-not $Explorer.Cache.ContainsKey($Path))
        {
            Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Disk.Scanning' -Arguments @($Path))
            $Result = Get-WtDiskExplorerListing -State $State -Path $Path

            if (-not $Result.Ok)
            {
                Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Disk.Title') -Lines @($Result.Message) -Tone 'Error'
                if ($Path -eq $Explorer.Root)
                {
                    return
                }
                $Explorer.Path = [System.IO.Path]::GetDirectoryName($Path)
                continue
            }

            $Explorer.Cache[$Path] = @{
                Path    = $Path
                Root    = $Explorer.Root
                Sort    = $Explorer.Sort
                Listing = $Result.Listing
            }

            if ($Explorer.Cache.Count -gt 64)
            {
                # Bounded cache: drop the oldest visited directory.
                $FirstKey = @($Explorer.Cache.Keys)[0]
                $Explorer.Cache.Remove($FirstKey)
            }
        }

        $Cache = $Explorer.Cache[$Path]
        $Listing = $Cache.Listing
        $BackendLabel = Get-WtString -Key 'Disk.Backend' -Arguments @($Listing.Backend, ($Listing.ElapsedMS))

        $KindText = if ($Cache.Sort -eq 'files') { (Get-WtString -Key 'Disk.Sort.Files') }
        elseif ($Cache.Sort -eq 'name') { (Get-WtString -Key 'Disk.Sort.Name') }
        else { (Get-WtString -Key 'Disk.Sort.Size') }

        $Notes = [System.Collections.Generic.List[string]]::new()
        $Notes.Add((Get-WtString -Key 'Disk.SelectedDir' -Arguments @($Path)))
        $Notes.Add($BackendLabel)
        $Notes.Add((Get-WtString -Key 'Disk.Total' -Arguments @($Listing.Entries.Count, (($Listing.Entries | Measure-Object -Property files -Sum).Sum), (($Listing.Entries | Measure-Object -Property bytes -Sum).Sum), $KindText)))

        $Partial = @($Listing.Entries | Where-Object { $_.partial })
        if ($Partial.Count -gt 0)
        {
            $Notes.Add((Get-WtString -Key 'Disk.Partial') + ": $($Partial.Count) subdirector(s) could not be read completely.")
        }
        if ($Listing.Cancelled)
        {
            $Notes.Add((Get-WtString -Key 'Disk.Cancelled'))
        }

        $Empty = if (@($Listing.Entries).Count -eq 0) { Get-WtString -Key 'Disk.ScanEmpty' } else { '' }

        $OnKey = {
            param ($Overlay, $Key)

            if ($Key.Name -ne 'Char') { return $false }

            $Character = ([string]$Key.Char).ToLowerInvariant()
            if ($Character -eq 's')
            {
                $State.Explorer.Sort = switch ([string]$State.Explorer.Sort)
                {
                    'size' { 'files' }
                    'files' { 'name' }
                    default { 'size' }
                }
                # The cache entries carry their own sort at listing time; clear them so the
                # next frame re-sorts from the same data.
                foreach ($CacheKey in @($State.Explorer.Cache.Keys))
                {
                    $State.Explorer.Cache[$CacheKey].Sort = $State.Explorer.Sort
                }
                $Overlay.Screen.Dirty = $true
                return $true
            }

            if ($Character -eq 'e')
            {
                Export-WtDiskExplorerReport -State $State -Cache $State.Explorer.Cache[$State.Explorer.Path]
                return $true
            }

            return $false
        }

        $Items = Get-WtDiskExplorerItems -State $State -Cache $Cache

        $Details = {
            param ($Item)

            $Payload = $Item.Payload
            if (-not $Payload -or $Payload.Action -ne 'Open') { return @() }

            $Entry = $Payload.Entry
            $Lines = @()
            $Lines += (Get-WtString -Key 'Disk.SelectedDir' -Arguments @($Entry.path))
            if ($Entry.kind -eq 'dir')
            {
                $Lines += (Format-WtDiskEntry -Entry $Entry)
                if ($Entry.partial)
                {
                    $Lines += (Get-WtString -Key 'Disk.Partial') + ": " + (($Entry.errors | ForEach-Object { "$($_.code): $($_.path)" }) -join '; ')
                }
            }
            else
            {
                $Lines += (Format-WtDiskEntry -Entry $Entry)
            }
            if ($Entry.error) { $Lines += (Get-WtString -Key 'Disk.Error' -Arguments @($Entry.error)) }
            return $Lines
        }

        $Result = Select-WtTuiItem -State $State -Title (Get-WtString -Key 'Disk.Title') -Lines $Notes.ToArray() `
            -Items $Items -Searchable -Details $Details -OnKey $OnKey -EmptyText $Empty -DetailsHeight 4

        if ($null -eq $Result -or $null -eq $Result.Value)
        {
            Set-WtTuiStatus -State $State -Text (Get-WtString -Key 'Tui.Status.Ready')
            return
        }

        $Action = $Result.Value.Action
        if ($Action -eq 'Up')
        {
            $Parent = [string]$Result.Value.Path
            if (Test-Path -LiteralPath $Parent -PathType Container)
            {
                $Explorer.Path = $Parent
            }
            continue
        }

        if ($Action -eq 'Open')
        {
            $Target = [string]$Result.Value.Path
            $Entry = $Result.Value.Entry
            if ($Entry.kind -eq 'dir')
            {
                $Explorer.Path = $Target
                continue
            }

            # A file: show its detail; nothing is opened outside the terminal.
            Show-WtTuiMessage -State $State -Title (Get-WtString -Key 'Disk.Title') -Lines @($Target, (Format-WtDiskEntry -Entry $Entry))
        }
    }
}
