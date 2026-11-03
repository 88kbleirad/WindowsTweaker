using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace WindowsTweaker.WinUI;

/// <summary>
/// A boolean to <see cref="Visibility"/> converter, so the XAML can show one element per
/// state (loading / empty / failed / ready) without any code behind deciding it.
/// </summary>
/// <remarks>
/// WinUI ships no such converter and the XAML <c>x:Bind</c> function form would force every
/// bound element into compiled bindings; this keeps the window on classic bindings, which
/// is what the rest of the file uses consistently.
/// </remarks>
public sealed partial class BoolToVisibilityConverter : IValueConverter
{
    /// <summary>When true, <c>true</c> yields <see cref="Visibility.Collapsed"/>.</summary>
    public bool Invert { get; set; }

    /// <inheritdoc />
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var flag = value is bool boolean && boolean;
        if (Invert)
        {
            flag = !flag;
        }

        return flag ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <inheritdoc />
    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
