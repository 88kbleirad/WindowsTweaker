using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace WindowsTweaker.WinUI;

/// <summary>
/// Maps a semantic tone name from a view model to one of the Catppuccin Mocha brushes.
/// </summary>
/// <remarks>
/// The view models decide <em>meaning</em> ("this value is fine", "this one is unknown",
/// "this operation failed") and the window decides <em>colour</em>, so a tone is a stable
/// name rather than a brush the core library would have to know about. The names come from
/// the engine's stable values, never from localized text, which is what keeps the colour
/// correct in both languages.
/// </remarks>
public sealed partial class ToneToBrushConverter : IValueConverter
{
    /// <inheritdoc />
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var tone = value as string ?? string.Empty;
        var key = tone switch
        {
            // Tweak values.
            "ok" => "WtTeal",          // Enabled
            "warn" => "WtYellow",      // Unknown
            "subtext" => "WtSubtext",  // Unsupported
            "muted" => "WtText",       // Disabled / Default / anything else neutral

            // Diagnostics section states.
            "idle" => "WtSubtext",     // not loaded / nothing requested yet
            "loading" => "WtYellow",   // a read is in flight
            "unsupported" => "WtOverlay0",

            // Operation outcomes and section success share one colour.
            "success" => "WtGreen",
            "failure" => "WtRed",
            "interrupted" => "WtYellow",

            // Licensing badge.
            "error" => "WtRed",

            _ => "WtText",
        };

        return Resolve(key) ?? Resolve("WtText") ?? Fallback;
    }

    /// <inheritdoc />
    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();

    private static Brush? Resolve(string key)
    {
        try
        {
            var resources = Application.Current?.Resources;
            if (resources is not null && resources.TryGetValue(key, out var found))
            {
                return found as Brush;
            }
        }
        catch (Exception)
        {
            // A missing resource must not take the window down; the fallback below is used.
        }

        return null;
    }

    /// <summary>
    /// The last resort only: the merged theme dictionary is loaded before any binding runs,
    /// so a lookup that fails at all means the theme failed to load.
    /// </summary>
    private static Brush Fallback { get; } = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0xcd, 0xd6, 0xf4));
}
