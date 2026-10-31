# WindowsTweaker - terminal monitoring workspace.
#
# A local, keyboard-driven observability mode: dashboards, time-series charts, time-range
# and target filters, panel inspection, change annotations, and local alert evaluation.
# It reuses the existing terminal rendering, dialogs, input and worker components; it
# never mutates system state and never opens listeners.

<#
.SYNOPSIS
    Formats a byte/unit value with a short unit suffix.
#>
function Format-WtMetricValue
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][double]$Value,
        [Parameter(Mandatory = $false)][string]$Unit = ''
    )

    if ($Unit -eq 'bytes' -or $Unit -eq 'bytes/s')
    {
        $Base = if ($Unit -eq 'bytes/s') { 'B/s' } else { 'B' }
        if ([math]::Abs($Value) -ge 1TB) { return ('{0:N1} TB' -f ($Value / 1TB)) }
        if ([math]::Abs($Value) -ge 1GB) { return ('{0:N1} GB' -f ($Value / 1GB)) }
        if ([math]::Abs($Value) -ge 1MB) { return ('{0:N1} MB' -f ($Value / 1MB)) }
        if ([math]::Abs($Value) -ge 1KB) { return ('{0:N1} KB' -f ($Value / 1KB)) }
        return ('{0:N0} {1}' -f $Value, $Base)
    }

    if ($Unit -eq 'seconds' -and $Value -ge 60)
    {
        return ('{0:N0}m {1:N0}s' -f [math]::Floor($Value / 60), ($Value % 60))
    }

    return ('{0:N1} {1}' -f $Value, $Unit).Trim()
}

<#
.SYNOPSIS
    Renders a time-series chart line set.
.DESCRIPTION
    Draws one or more lines of terminal cells from a bucket array (see
    ConvertTo-WtMetricBuckets). Gaps are drawn as a gap glyph, never as zero. The
    baseline shows the min/max of the visible samples and the aggregation method. Unicode
    block glyphs are used when the terminal supports Unicode; otherwise ASCII levels are
    used. Returns an array of strings (one per row), plus label/legend data.
#>
function Format-WtMetricChart
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Buckets,
        [Parameter(Mandatory = $false)][string]$Unit = '',
        [Parameter(Mandatory = $false)][int]$Height = 4,
        [Parameter(Mandatory = $false)][int]$Width = 30,
        [Parameter(Mandatory = $false)][string]$Method = 'avg',
        [Parameter(Mandatory = $false)][bool]$Unicode = $true
    )

    if ($Height -lt 1) { $Height = 1 }
    if ($Width -lt 4) { $Width = 4 }
    if ($Buckets.Count -eq 0)
    {
        $Lines = @()
        for ($Row = 0; $Row -lt $Height; $Row++)
        {
            $Lines += ' ' * $Width
        }
        return @{ Lines = $Lines; Max = $null; Min = $null; Gaps = 0 }
    }

    # Visible value range from non-gap buckets.
    $Values = @($Buckets | Where-Object { -not $_.Gap -and $null -ne $_.Last } | ForEach-Object { [double]$_.Last })
    $Max = if ($Values.Count -gt 0) { ($Values | Measure-Object -Maximum).Maximum } else { $null }
    $Min = if ($Values.Count -gt 0) { ($Values | Measure-Object -Minimum).Minimum } else { $null }
    $Gaps = @($Buckets | Where-Object { $_.Gap }).Count

    # The chart draws one glyph per bucket; narrower charts merge buckets.
    $Step = [math]::Ceiling($Buckets.Count / $Width)
    $Cells = @()
    for ($B = 0; $B -lt $Width -and ($B * $Step) -lt $Buckets.Count; $B++)
    {
        $Start = $B * $Step
        $End = [math]::Min($Buckets.Count, $Start + $Step)
        $Slice = @($Buckets[$Start..($End - 1)])
        $AnyGap = @($Slice | Where-Object { $_.Gap }).Count -gt 0
        $SliceValues = @($Slice | Where-Object { -not $_.Gap -and $null -ne $_.Last } | ForEach-Object { [double]$_.Last })

        if ($AnyGap -and $SliceValues.Count -eq 0)
        {
            $Cells += $null
            continue
        }

        $CellValue = switch ($Method)
        {
            'min' { if ($SliceValues.Count) { ($SliceValues | Measure-Object -Minimum).Minimum } else { $null } }
            'max' { if ($SliceValues.Count) { ($SliceValues | Measure-Object -Maximum).Maximum } else { $null } }
            'sum' { if ($SliceValues.Count) { ($SliceValues | Measure-Object -Sum).Sum } else { $null } }
            'last' { if ($SliceValues.Count) { $SliceValues[$SliceValues.Count - 1] } else { $null } }
            'raw' { if ($SliceValues.Count) { $SliceValues[0] } else { $null } }
            default { if ($SliceValues.Count) { ($SliceValues | Measure-Object -Average).Average } else { $null } }
        }

        $Cells += $CellValue
    }

    $Levels = if ($Unicode) { @('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█') } else { @('_', '.', ':', '-', '+', '#', '%', '@') }
    $GapGlyph = if ($Unicode) { '·' } else { ' ' }

    $Lines = @()
    for ($Row = $Height - 1; $Row -ge 0; $Row--)
    {
        $Buffer = [System.Text.StringBuilder]::new()
        foreach ($Cell in $Cells)
        {
            if ($null -eq $Cell)
            {
                [void]$Buffer.Append($GapGlyph)
                continue
            }

            if ($null -eq $Max -or $Max -le $Min)
            {
                [void]$Buffer.Append($Levels[0])
                continue
            }

            $Fraction = 0.0
            if ($Max -gt $Min)
            {
                $Fraction = ($Cell - $Min) / ($Max - $Min)
            }
            $Position = $Row / [math]::Max(1, $Height - 1)
            $Level = [math]::Floor($Fraction * 8)
            if ($Level -lt 0) { $Level = 0 }
            if ($Level -gt 7) { $Level = 7 }

            if ($Fraction -le 0) { $Level = 0 }
            $Visible = $Fraction -ge $Position
            if ($Visible)
            {
                [void]$Buffer.Append($Levels[$Level])
            }
            else
            {
                [void]$Buffer.Append(' ')
            }
        }
        $Lines += $Buffer.ToString()
    }

    return @{
        Lines = $Lines
        Max = $Max
        Min = $Min
        Gaps = $Gaps
    }
}

<#
.SYNOPSIS
    Builds the chart line block for a metric series in history.
#>
function Get-WtMonitorChartBlock
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$History,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $false)][int]$Seconds = 300,
        [Parameter(Mandatory = $false)][string]$Unit = '',
        [Parameter(Mandatory = $false)][int]$Height = 4,
        [Parameter(Mandatory = $false)][int]$Width = 30,
        [Parameter(Mandatory = $false)][string]$Method = 'avg',
        [Parameter(Mandatory = $false)][bool]$Unicode = $true
    )

    $Range = Select-WtMetricRange -History $History -Key $Key -Seconds $Seconds
    $Buckets = @(ConvertTo-WtMetricBuckets -Range $Range -Buckets ([math]::Max(20, $Width)) -Method $Method)
    $Chart = Format-WtMetricChart -Buckets $Buckets -Unit $Unit -Height $Height -Width $Width -Method $Method -Unicode $Unicode

    $Lines = @()
    if ($Chart.Lines.Count -gt 0)
    {
        $Lines += $Chart.Lines
    }

    $Meta = ''
    if ($null -ne $Chart.Min -and $null -ne $Chart.Max)
    {
        $Meta = "min {0}  max {1}" -f (Format-WtMetricValue -Value ([double]$Chart.Min) -Unit $Unit), (Format-WtMetricValue -Value ([double]$Chart.Max) -Unit $Unit)
    }
    if ($Chart.Gaps -gt 0)
    {
        $Meta += "  [gaps: $($Chart.Gaps)]"
    }
    $Lines += $Meta
    if (-not $Range.Available)
    {
        $Lines += (Get-WtString -Key 'Mon.Range.Partial')
    }

    return $Lines
}
