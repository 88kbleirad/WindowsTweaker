using Microsoft.UI.Xaml.Data;

namespace WindowsTweaker.WinUI;

/// <summary>
/// Maps a percentage (0..100) to a pixel height, for the CPU trend drawn as a row of
/// columns.
/// </summary>
/// <remarks>
/// The trend is drawn with plain elements rather than a chart control: the value model has
/// no UI dependency, the window already animates nothing, and a converter keeps the drawing
/// decision in the view where it belongs. The maximum height comes from
/// <c>ConverterParameter</c>; a value outside 0..100 is clamped instead of throwing, and a
/// non-numeric value yields zero height (an empty column), never a fabricated bar.
/// </remarks>
public sealed partial class PercentToHeightConverter : IValueConverter
{
    /// <summary>The height used when the parameter is missing or unparsable.</summary>
    public double DefaultMaximum { get; set; } = 28d;

    /// <inheritdoc />
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var maximum = DefaultMaximum;
        if (parameter is string text
            && double.TryParse(text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var parsed)
            && parsed > 0)
        {
            maximum = parsed;
        }

        if (value is not double percent
            || double.IsNaN(percent)
            || double.IsInfinity(percent))
        {
            return 0d;
        }

        var clamped = Math.Clamp(percent, 0d, 100d);
        return Math.Round(clamped / 100d * maximum, 2);
    }

    /// <inheritdoc />
    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
