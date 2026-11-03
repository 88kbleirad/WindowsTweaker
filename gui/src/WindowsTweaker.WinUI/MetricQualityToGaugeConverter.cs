using Microsoft.UI.Xaml.Data;
using WindowsTweaker.Gui.Core.Model;

namespace WindowsTweaker.WinUI;

/// <summary>
/// Maps the engine's <see cref="MetricQuality"/> to the gauge's
/// <see cref="GaugeQuality"/>, so a card that could not be measured renders as muted
/// instead of claiming a live number.
/// </summary>
public sealed class MetricQualityToGaugeConverter : IValueConverter
{
    /// <inheritdoc />
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        if (value is MetricQuality quality)
        {
            return quality switch
            {
                MetricQuality.Valid => GaugeQuality.Valid,
                MetricQuality.Unsupported => GaugeQuality.Unsupported,
                MetricQuality.Stale => GaugeQuality.Stale,
                MetricQuality.Error => GaugeQuality.Error,
                _ => GaugeQuality.Unavailable,
            };
        }

        return GaugeQuality.Unavailable;
    }

    /// <inheritdoc />
    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
