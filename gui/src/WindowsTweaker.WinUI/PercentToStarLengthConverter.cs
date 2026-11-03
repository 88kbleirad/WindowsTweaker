using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace WindowsTweaker.WinUI;

/// <summary>
/// Turns a percentage (0..100) into a proportional grid length, so a usage bar can be drawn
/// as two columns that split the available width.
/// </summary>
/// <remarks>
/// A bar drawn as grid columns never animates: the frame's value changes are applied as a
/// new layout, which is what the interface must do when reduced motion is on. The
/// framework's <c>ProgressBar</c> animates its fill by default, so it is deliberately not
/// used for the hardware cards. <see cref="Invert"/> produces the remainder of the split
/// (100 - value), which is how the empty part of the bar is drawn.
/// </remarks>
public sealed partial class PercentToStarLengthConverter : IValueConverter
{
    /// <summary>When true, the complement of the value is returned.</summary>
    public bool Invert { get; set; }

    /// <inheritdoc />
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        if (value is not double percent || double.IsNaN(percent) || double.IsInfinity(percent))
        {
            return new GridLength(0, GridUnitType.Star);
        }

        var clamped = Math.Clamp(percent, 0d, 100d);
        if (Invert)
        {
            clamped = 100d - clamped;
        }

        return new GridLength(clamped, GridUnitType.Star);
    }

    /// <inheritdoc />
    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
