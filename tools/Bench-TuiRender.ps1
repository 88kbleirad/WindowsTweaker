# WindowsTweaker - TUI render benchmark (before/after).
#
# Measures the application-side cost of writing a frame on the SAME runtime/terminal
# configuration, comparing:
#   * the legacy all-rows, per-cell plain renderer and the all-rows ANSI renderer
#     (copies of the exact bodies at the start of this work), and
#   * the current Write-WtScreen / Write-WtScreenPlain (row diff + segmented plain output)
#     loaded from the module.
#
# Usage:
#   pwsh -NoProfile -File tools/Bench-TuiRender.ps1 [-Iterations 300] [-Width 120] [-Height 40]
#
# Notes:
#   * This measures application processing time, NOT physical key-to-display latency:
#     console writes go to a null writer during measurement, so the syscall side of a real
#     terminal is excluded. The deltas between the two renderers are still the point.
#   * RowsMedian/RowsP95 are the rows emitted per frame (legacy writers always emit every
#     row; the diff writers emit only rows that actually changed).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)][int]$Iterations = 300,
    [Parameter(Mandatory = $false)][int]$Width = 120,
    [Parameter(Mandatory = $false)][int]$Height = 40
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Path $PSScriptRoot -Parent
Import-Module (Join-Path $Root 'src/WindowsTweaker/WindowsTweaker.psd1') -Force
$M = Get-Module WindowsTweaker

function New-BenchScreen
{
    param ([bool]$Navigating)

    return & $M {
        param ($W, $H, $Navigate)

        $Theme = New-WtTuiTheme -Colour 'Ansi16' -Unicode:$true -IconMode 'Unicode'
        $Screen = New-WtScreen -Width $W -Height $H -Theme $Theme
        $Limit = Get-WtRowWidth -Screen $Screen -Row 1

        Set-WtScreenRegion -Screen $Screen -Row 1 -Column 1 -Width $W -Height 2 -Style 'Header'
        Set-WtScreenText -Screen $Screen -Row 1 -Column 2 -Text 'WindowsTweaker benchmark frame' -Style 'Title' -MaxWidth ($Limit - 4)
        Set-WtScreenText -Screen $Screen -Row 2 -Column 2 -Text 'row2 meta text' -Style 'HeaderMeta' -MaxWidth ($Limit - 4)

        for ($Row = 4; $Row -lt ($H - 2); $Row++)
        {
            $Style = if (($Row % 5) -eq 0) { 'Focused' } else { 'Item' }
            Set-WtScreenRegion -Screen $Screen -Row $Row -Column 1 -Width $W -Height 1 -Style $Style
            Set-WtScreenText -Screen $Screen -Row $Row -Column 2 -Text ('list row {0} with some text padded to look realistic' -f $Row) -Style $Style -MaxWidth ($Limit - 4)
        }

        Set-WtScreenRegion -Screen $Screen -Row ($H - 1) -Column 1 -Width $W -Height 1 -Style 'StatusBar'
        Set-WtScreenText -Screen $Screen -Row ($H - 1) -Column 2 -Text 'status line' -Style 'StatusInfo' -MaxWidth ($Limit - 4)

        if ($Navigate)
        {
            Set-WtScreenText -Screen $Screen -Row 8 -Column 2 -Text '> cursor row' -Style 'Focused' -MaxWidth ($Limit - 4)
        }

        return $Screen
    } $Width $Height $Navigating
}

function Measure-Writer
{
    param (
        [string]$Name,
        [scriptblock]$Body,
        [object]$Screen,
        [int]$Iterations,
        [scriptblock]$Mutate
    )

    $OldOut = [Console]::Out
    $Durations = [System.Collections.Generic.List[double]]::new($Iterations)

    # Measurements write to a null sink. [Console]::SetOut does not accept the static
    # TextWriter.Null, so a real stream to /dev/null (NUL on Windows) is used.
    $NullPath = if ($IsWindows) { 'NUL' } else { '/dev/null' }
    $NullStream = [System.IO.File]::Open($NullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $Sink = [System.IO.StreamWriter]::new($NullStream)

    try
    {
        [Console]::SetOut($Sink)
        for ($I = 0; $I -lt $Iterations; $I++)
        {
            if ($Mutate) { & $Mutate $Screen $I }
            $Watch = [System.Diagnostics.Stopwatch]::StartNew()
            & $Body $Screen
            $Watch.Stop()
            $Durations.Add($Watch.Elapsed.TotalMilliseconds)
        }
    }
    finally
    {
        [Console]::SetOut($OldOut)
        $Sink.Dispose()
        $NullStream.Dispose()
    }

    $Sorted = @($Durations | Sort-Object)
    $Count = $Sorted.Count
    $Median = $Sorted[[math]::Floor($Count / 2)]
    $P95 = $Sorted[[math]::Min($Count - 1, [int][math]::Ceiling(0.95 * $Count) - 1)]
    $Max = $Sorted[$Count - 1]

    return [pscustomobject]@{
        Writer      = $Name
        Iterations  = $Count
        MedianMs    = [math]::Round($Median, 3)
        P95Ms       = [math]::Round($P95, 3)
        MaxMs       = [math]::Round($Max, 3)
    }
}

# ---- Verbatim copies of the legacy renderers (before this work) -------------------

$LegacyAnsi = {
    param ([object]$Screen)
    & $M {
        param ($S)

        $Escape = [char]27
        $Builder = [System.Text.StringBuilder]::new(($S.Width + 24) * $S.Height)
        [void]$Builder.Append("$Escape[?25l")

        $Lines = ConvertTo-WtScreenText -Screen $S
        for ($Row = 1; $Row -le $S.Height; $Row++)
        {
            [void]$Builder.Append("$Escape[$($Row);1H")
            [void]$Builder.Append($Lines[$Row - 1])
        }

        [void]$Builder.Append("$Escape[0m")
        [Console]::Out.Write($Builder.ToString())
        [Console]::Out.Flush()
        $S.LastWrittenRows = $S.Height
    } $Screen
}

$LegacyPlain = {
    param ([object]$Screen)
    & $M {
        param ($S)

        $StyleList = $S.Theme.StyleList
        [Console]::CursorVisible = $false
        for ($Row = 1; $Row -le $S.Height; $Row++)
        {
            [Console]::SetCursorPosition(0, $Row - 1)
            $Line = $S.Rows[$Row - 1]
            $Limit = Get-WtRowWidth -Screen $S -Row $Row
            $CurrentStyle = -1

            for ($Column = 0; $Column -lt $Limit; $Column++)
            {
                $StyleId = $Line.Styles[$Column]
                if ($StyleId -ne $CurrentStyle)
                {
                    if ($StyleId -ge 0 -and $StyleId -lt $StyleList.Count)
                    {
                        $Style = $StyleList[$StyleId]
                        [Console]::ForegroundColor = [System.ConsoleColor]$Style.ConsoleForeground
                        [Console]::BackgroundColor = [System.ConsoleColor]$Style.ConsoleBackground
                    }
                    $CurrentStyle = $StyleId
                }

                [Console]::Out.Write($Line.Cells[$Column])
            }
        }

        [Console]::ResetColor()
        $S.LastWrittenRows = $S.Height
    } $Screen
}

# ---- Current renderers (module) ---------------------------------------------------

function Invoke-CurrentAnsiWriter
{
    param ([object]$Screen)
    & $M { param ($S) Write-WtScreen -Screen $S } $Screen
}

function Invoke-CurrentPlainWriter
{
    param ([object]$Screen)
    & $M { param ($S) Write-WtScreenPlain -Screen $S } $Screen
}

$CurrentAnsi = { param ([object]$Screen) Invoke-CurrentAnsiWriter -Screen $Screen }
$CurrentPlain = { param ([object]$Screen) Invoke-CurrentPlainWriter -Screen $Screen }

function Invoke-QuietWriter
{
    param ([scriptblock]$Body, [object]$Screen)

    $OldOut = [Console]::Out
    [Console]::SetOut([System.IO.TextWriter]::Null)
    try
    {
        & $Body $Screen | Out-Null
    }
    finally
    {
        [Console]::SetOut($OldOut)
    }
}

$MutateNav = {
    param ($Screen, $Iteration)
    & $M {
        param ($S, $N)
        $Row = 8 + ($N % 3)
        Set-WtScreenText -Screen $S -Row $Row -Column 2 -Text '> cursor row' -Style 'Focused' -MaxWidth ((Get-WtRowWidth -Screen $S -Row $Row) - 4)
    } $Screen $Iteration
}

try
{
    Write-Host "TUI render benchmark: $Iterations iterations, $Width x $Height grid, null console sink"
    Write-Host ''

    foreach ($Scenario in @('navigation', 'static'))
    {
        $Navigating = ($Scenario -eq 'navigation')
        $Screen = New-BenchScreen -Navigating $Navigating
        $Mutate = if ($Scenario -eq 'navigation') { $MutateNav } else { $null }

        # Heat the new renderers (their first call establishes the previous frame).
        Invoke-QuietWriter -Body $CurrentAnsi -Screen $Screen
        Invoke-QuietWriter -Body $CurrentPlain -Screen $Screen

        $Rows = [System.Collections.Generic.List[object]]::new()
        $Rows.Add((Measure-Writer -Name 'legacy ansi (all rows)' -Body $LegacyAnsi -Screen $Screen -Iterations $Iterations -Mutate $Mutate))
        $Rows.Add((Measure-Writer -Name 'current ansi (diff)' -Body $CurrentAnsi -Screen $Screen -Iterations $Iterations -Mutate $Mutate))
        $Rows.Add((Measure-Writer -Name 'legacy plain (per-cell)' -Body $LegacyPlain -Screen $Screen -Iterations $Iterations -Mutate $Mutate))
        $Rows.Add((Measure-Writer -Name 'current plain (segments+diff)' -Body $CurrentPlain -Screen $Screen -Iterations $Iterations -Mutate $Mutate))

        Write-Output "== Scenario: $Scenario =="
        $Rows.ToArray() | Format-Table -AutoSize | Out-String | Write-Output
    }
}
finally
{
}
