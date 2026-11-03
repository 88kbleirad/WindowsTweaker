namespace WindowsTweaker.Gui.Core.Model;

/// <summary>The data quality a gauge renders.</summary>
public enum GaugeQuality
{
    /// <summary>A current, usable measurement.</summary>
    Valid,

    /// <summary>No measurement is available.</summary>
    Unavailable,

    /// <summary>The source cannot provide this kind of measurement.</summary>
    Unsupported,

    /// <summary>The measurement is older than the sample window.</summary>
    Stale,

    /// <summary>The reading failed; the note carries the reason.</summary>
    Error,
}

/// <summary>Utilization thresholds drive the Catppuccin status colour.</summary>
public enum GaugeStatus
{
    /// <summary>0% ≤ value &lt; 60% — green.</summary>
    Normal,

    /// <summary>60% ≤ value &lt; 80% — yellow.</summary>
    Elevated,

    /// <summary>80% ≤ value &lt; 95% — orange.</summary>
    High,

    /// <summary>95% ≤ value ≤ 100% — red (a full arc, never blinking).</summary>
    VeryHigh,
}

/// <summary>
/// The utilization thresholds, in one place so the control, the converters and the tests all
/// agree. An enum cannot carry a method, hence this companion type.
/// </summary>
public static class GaugeStatusRules
{
    /// <summary>Derives the status from a 0..100 utilization percentage.</summary>
    /// <remarks>
    /// Values outside the range are clamped rather than rejected: a counter that briefly
    /// reports 100.4% is still "very high", never an exception. The tier is a presentation
    /// fact only — a high reading is not by itself a fault.
    /// </remarks>
    public static GaugeStatus FromPercent(double percent)
    {
        var clamped = Math.Clamp(percent, 0d, 100d);
        return clamped switch
        {
            >= 95d => GaugeStatus.VeryHigh,
            >= 80d => GaugeStatus.High,
            >= 60d => GaugeStatus.Elevated,
            _ => GaugeStatus.Normal,
        };
    }

    /// <summary>The localized status label for a tier (colour is never the only signal).</summary>
    public static string LabelKey(GaugeStatus status) => status switch
    {
        GaugeStatus.Elevated => "Gui.Metrics.StatusElevated",
        GaugeStatus.High => "Gui.Metrics.StatusHigh",
        GaugeStatus.VeryHigh => "Gui.Metrics.StatusVeryHigh",
        _ => "Gui.Metrics.StatusNormal",
    };
}
