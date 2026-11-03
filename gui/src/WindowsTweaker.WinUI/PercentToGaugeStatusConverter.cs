using Microsoft.UI.Xaml.Data;
using WindowsTweaker.Gui.Core.Model;

namespace WindowsTweaker.WinUI;

/// <summary>
/// Maps a percentage (0..100) to a <see cref="GaugeStatus"/> using the documented
/// thresholds: normal → green, 60+ → yellow, 80+ → orange, 95+ → red. A missing value
/// maps to normal; the gauge's own quality already decides whether the status brush is
/// shown at all.
/// </summary>
public sealed class PercentToGaugeStatusConverter : IValueConverter
{
    /// <inheritdoc />
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        if (value is double percent && !double.IsNaN(percent) && !double.IsInfinity(percent))
        {
            return GaugeStatusRules.FromPercent(percent);
        }

        return GaugeStatus.Normal;
    }

    /// <inheritdoc />
    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
