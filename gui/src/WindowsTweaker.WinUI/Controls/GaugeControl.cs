using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using WindowsTweaker.Gui.Core.Model;
using Windows.Foundation;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace WindowsTweaker.WinUI;

/// <summary>
/// A reusable semicircular gauge.
/// </summary>
/// <remarks>
/// <para>Geometry.</para>
/// The gauge is an arc of the ellipse inscribed in the control's box, sweeping 180 degrees
/// from left to right (the bottom half is unused, so the visual reads as a semicircle). The
/// background arc is the full 0–100% range; the foreground arc from 0 to <see cref="Value"/>.
/// A small circle marks the endpoint of the current value. The center shows the current
/// value as large text, with a secondary line below it (percent or a label).
/// The stroke thickness comes from <see cref="GaugeStrokeThickness"/> (a shared resource),
/// rounded caps are used for both arcs, and the marker sits on the arc's center line so it
/// never clips at 0% or 100% (the arc has a small end-cap allowance in its geometry).
///
/// <para>State and colour.</para>
/// <see cref="Value"/> is the 0..100 percentage; a value outside that range is clamped
/// (never throws). <see cref="Status"/> selects the colour by the documented thresholds:
/// normal → green, elevated → yellow, high → orange, very high → red. The foreground arc,
/// the marker and the percentage share that colour. The background arc stays
/// <c>#45475A</c> (surface1).
/// When <see cref="Quality"/> is not valid the gauge renders a muted arc with the localized
/// unavailable text and no percentage — it never draws 0%.
///
/// <para>Reduced motion.</para>
/// When <see cref="ReduceMotion"/> is true the arc and marker are drawn directly and no
/// transition is started.
/// </remarks>
public sealed partial class GaugeControl : Control
{
    // WinUI has no Arc shape; the arcs are Path elements whose geometry is rebuilt in
    // code on size changes. Path is fully qualified: System.IO.Path would otherwise be
    // ambiguous (ImplicitUsings brings both namespaces in).
    private Microsoft.UI.Xaml.Shapes.Path? _backgroundArc;
    private Microsoft.UI.Xaml.Shapes.Path? _foregroundArc;
    private Ellipse? _marker;
    private TextBlock? _valueText;
    private TextBlock? _secondaryText;
    private Border? _layoutRoot;
    private Grid? _arcHost;
    private double _cachedWidth = -1d;
    private double _cachedHeight = -1d;
    private double _cachedPercent = -1d;
    private double _cachedStroke = -1d;

    /// <inheritdoc />
    public GaugeControl()
    {
        DefaultStyleKey = typeof(GaugeControl);
    }

    /// <summary>The measured value in 0..100, or null when absent.</summary>
    public double? Value
    {
        get => (double?)GetValue(ValueProperty);
        set => SetValue(ValueProperty, value);
    }

    /// <summary>The gauge's quality: valid, unavailable, unsupported, stale or error.</summary>
    public GaugeQuality Quality
    {
        get => (GaugeQuality)GetValue(QualityProperty);
        set => SetValue(QualityProperty, value);
    }

    /// <summary>The utilization status that chooses the colour.</summary>
    public GaugeStatus Status
    {
        get => (GaugeStatus)GetValue(StatusProperty);
        set => SetValue(StatusProperty, value);
    }

    /// <summary>The primary number label (a percentage, or "—" when unavailable).</summary>
    public string? ValueText
    {
        get => (string?)GetValue(ValueTextProperty);
        set => SetValue(ValueTextProperty, value);
    }

    /// <summary>The secondary label under the value (units, or a note).</summary>
    public string? SecondaryText
    {
        get => (string?)GetValue(SecondaryTextProperty);
        set => SetValue(SecondaryTextProperty, value);
    }

    /// <summary>The metric's display name.</summary>
    public string? MetricName
    {
        get => (string?)GetValue(MetricNameProperty);
        set => SetValue(MetricNameProperty, value);
    }

    /// <summary>Lightweight animation only; reduced motion switches it off.</summary>
    public bool ReduceMotion
    {
        get => (bool)GetValue(ReduceMotionProperty);
        set => SetValue(ReduceMotionProperty, value);
    }

    /// <summary>Shared stroke thickness resource for the gauge arcs.</summary>
    public double StrokeThickness
    {
        get => (double)GetValue(StrokeThicknessProperty);
        set => SetValue(StrokeThicknessProperty, value);
    }

    /// <inheritdoc />
    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        _backgroundArc = GetTemplateChild("BackgroundArc") as Path;
        _foregroundArc = GetTemplateChild("ForegroundArc") as Path;
        _marker = GetTemplateChild("Marker") as Ellipse;
        _valueText = GetTemplateChild("ValueText") as TextBlock;
        _secondaryText = GetTemplateChild("SecondaryText") as TextBlock;
        _layoutRoot = GetTemplateChild("LayoutRoot") as Border;
        _arcHost = GetTemplateChild("ArcHost") as Grid;
        ApplyTemplateState();
        SizeChanged += (_, _) => ApplyTemplateState();
    }

    private void ApplyTemplateState()
    {
        if (_layoutRoot is null)
        {
            // The template is not applied yet; OnApplyTemplate calls this again.
            return;
        }

        _layoutRoot.Background = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0x18, 0x18, 0x25));

        var track = new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0x45, 0x47, 0x5A));
        var text = (Brush)Application.Current.Resources["WtText"];
        var subtext = (Brush)Application.Current.Resources["WtSubtext"];

        var raw = Value;
        var available = raw is { } value && !double.IsNaN(value) && !double.IsInfinity(value) && Quality == GaugeQuality.Valid;
        var percent = available ? Math.Clamp(raw!.Value, 0d, 100d) : 0d;

        UpdateGeometry(percent);

        if (_backgroundArc is not null)
        {
            _backgroundArc.Stroke = track;
            _backgroundArc.StrokeThickness = StrokeThickness;
            _backgroundArc.StrokeStartLineCap = PenLineCap.Round;
            _backgroundArc.StrokeEndLineCap = PenLineCap.Round;
        }

        if (_foregroundArc is not null)
        {
            _foregroundArc.StrokeThickness = StrokeThickness;
            _foregroundArc.StrokeStartLineCap = PenLineCap.Round;
            _foregroundArc.StrokeEndLineCap = PenLineCap.Round;
            _foregroundArc.Stroke = available ? StatusBrush(Status) : track;
            _foregroundArc.Opacity = available ? 1d : 0.45d;
        }

        if (_marker is not null)
        {
            _marker.Fill = available ? StatusBrush(Status) : subtext;
            _marker.Opacity = available ? 1d : 0.45d;
        }

        if (_valueText is not null)
        {
            // An empty label is treated as absent: a gauge always shows its own percentage
            // when the caller has no text for it, and "—" when nothing was measured.
            _valueText.Foreground = available ? StatusBrush(Status) : text;
            _valueText.Text = available
                ? (string.IsNullOrWhiteSpace(ValueText) ? $"{percent:0}%" : ValueText)
                : "—";
        }

        if (_secondaryText is not null)
        {
            _secondaryText.Foreground = subtext;
            _secondaryText.Text = SecondaryText ?? string.Empty;
        }
    }

    /// <summary>
    /// Draws the two arcs and the marker for the current size and value. Geometry is only
    /// rebuilt when the size, the stroke or the clamped value actually changed, so a
    /// per-second sample never allocates path geometry.
    /// </summary>
    private void UpdateGeometry(double percent)
    {
        if (_arcHost is null)
        {
            return;
        }

        var width = _arcHost.ActualWidth;
        var height = _arcHost.ActualHeight;
        if (width <= 0d || height <= 0d)
        {
            return;
        }

        var stroke = Math.Max(1d, StrokeThickness);
        var half = stroke / 2d;

        if (Math.Abs(width - _cachedWidth) < 0.5d
            && Math.Abs(height - _cachedHeight) < 0.5d
            && Math.Abs(stroke - _cachedStroke) < 0.5d
            && Math.Abs(percent - _cachedPercent) < 0.0001d)
        {
            // Same size, stroke and value: the geometry is already drawn.
            return;
        }

        // The inset keeps everything inside the control at 0% and 100%: the marker
        // (12x12, center on the arc) needs at least 6 px, and the rounded stroke caps
        // extend half the stroke past the arc's end points. Two extra pixels of
        // breathing room keep the caps from touching the edge.
        var margin = Math.Max(half, 6d) + 2d;
        var diameter = Math.Min(width - 2d * margin, height - 2d * margin);
        if (diameter <= 0d)
        {
            return;
        }

        var radius = diameter / 2d;
        var rx = width / 2d;
        var ry = height / 2d;
        var left = rx - radius;
        var right = rx + radius;
        var centerY = ry;
        var top = centerY - radius;
        var bottom = centerY + radius;

        // The end cap allowance: at 0%/100% a stroked line that terminated exactly at the
        // horizontal end would have its round cap extend past the control edge, so the
        // arcs are shortened by half the stroke on each side. The marker is inset by the
        // same margin, so it stays fully inside too.
        if (_backgroundArc is not null)
        {
            _backgroundArc.Data = BuildArc(left + half, top, right - half, bottom, 180d, false);
        }

        if (_foregroundArc is not null)
        {
            var sweep = percent * 180d / 100d;
            _foregroundArc.Data = BuildArc(left + half, top, right - half, bottom, sweep, sweep > 90d);
        }

        if (_marker is not null)
        {
            // The arcs' ellipse is inset by half the stroke, so the marker rides on that
            // same center line - never off the arc at the ends.
            var arcRadius = Math.Max(0d, radius - half);
            var angle = Math.PI - percent * Math.PI / 100d;
            _marker.Width = 12d;
            _marker.Height = 12d;
            _marker.Margin = new Thickness(
                rx + Math.Cos(angle) * arcRadius - 6d,
                centerY - Math.Sin(angle) * arcRadius - 6d,
                0d,
                0d);
            _marker.HorizontalAlignment = HorizontalAlignment.Left;
            _marker.VerticalAlignment = VerticalAlignment.Top;
        }

        _cachedWidth = width;
        _cachedHeight = height;
        _cachedStroke = stroke;
        _cachedPercent = percent;
    }

    /// <summary>
    /// Builds a <see cref="PathGeometry"/> for an arc of the ellipse that spans the given
    /// bounds. The arc is the top half (center line at the ellipse's vertical middle),
    /// sweeping from 180° (left) clockwise by <paramref name="sweepDegrees"/>.
    /// </summary>
    /// <param name="left">Left bound of the arc's ellipse.</param>
    /// <param name="top">Top bound of the arc's ellipse.</param>
    /// <param name="right">Right bound of the arc's ellipse.</param>
    /// <param name="bottom">Bottom bound of the arc's ellipse.</param>
    /// <param name="sweepDegrees">The covered fraction in degrees (0 = none, 180 = full).</param>
    /// <param name="isLarge">Whether the arc's sweep is larger than a semicircle.</param>
    private static PathGeometry BuildArc(
        double left, double top, double right, double bottom,
        double sweepDegrees, bool isLarge)
    {
        var radiusX = (right - left) / 2d;
        var radiusY = (bottom - top) / 2d;
        var centerX = left + radiusX;
        var centerY = top + radiusY;

        var endAngle = Math.PI - sweepDegrees * Math.PI / 180d;
        if (endAngle < 0d)
        {
            endAngle = 0d;
        }

        var figure = new PathFigure
        {
            IsClosed = false,
            IsFilled = false,
            StartPoint = new Point(left, centerY),
        };

        var segment = new ArcSegment
        {
            Point = new Point(centerX + Math.Cos(endAngle) * radiusX, centerY - Math.Sin(endAngle) * radiusY),
            Size = new Size(radiusX, radiusY),
            IsLargeArc = isLarge,
            SweepDirection = SweepDirection.Clockwise,
        };
        figure.Segments.Add(segment);

        var geometry = new PathGeometry();
        geometry.Figures.Add(figure);
        return geometry;
    }

    private static Brush StatusBrush(GaugeStatus status)
    {
        var key = status switch
        {
            GaugeStatus.Elevated => "WtYellow",
            GaugeStatus.High => "WtPeach",
            GaugeStatus.VeryHigh => "WtRed",
            _ => "WtGreen",
        };

        try
        {
            if (Application.Current?.Resources.TryGetValue(key, out var brush) == true)
            {
                return (Brush)brush;
            }
        }
        catch (Exception)
        {
            // Fall through to a literal Catppuccin colour.
        }

        return status switch
        {
            GaugeStatus.Elevated => new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0xF9, 0xE2, 0xAF)),
            GaugeStatus.High => new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0xFA, 0xB3, 0x87)),
            GaugeStatus.VeryHigh => new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0xF3, 0x8B, 0xA8)),
            _ => new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 0xA6, 0xE3, 0xA1)),
        };
    }

    /// <summary>Dependency property backing <see cref="Value"/>.</summary>
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double?), typeof(GaugeControl), new PropertyMetadata(null, OnStateChanged));

    /// <summary>Dependency property backing <see cref="Quality"/>.</summary>
    public static readonly DependencyProperty QualityProperty = DependencyProperty.Register(
        nameof(Quality), typeof(GaugeQuality), typeof(GaugeControl), new PropertyMetadata(GaugeQuality.Unavailable, OnStateChanged));

    /// <summary>Dependency property backing <see cref="Status"/>.</summary>
    public static readonly DependencyProperty StatusProperty = DependencyProperty.Register(
        nameof(Status), typeof(GaugeStatus), typeof(GaugeControl), new PropertyMetadata(GaugeStatus.Normal, OnStateChanged));

    /// <summary>Dependency property backing <see cref="ValueText"/>.</summary>
    public static readonly DependencyProperty ValueTextProperty = DependencyProperty.Register(
        nameof(ValueText), typeof(string), typeof(GaugeControl), new PropertyMetadata(null, OnStateChanged));

    /// <summary>Dependency property backing <see cref="SecondaryText"/>.</summary>
    public static readonly DependencyProperty SecondaryTextProperty = DependencyProperty.Register(
        nameof(SecondaryText), typeof(string), typeof(GaugeControl), new PropertyMetadata(null, OnStateChanged));

    /// <summary>Dependency property backing <see cref="MetricName"/>.</summary>
    public static readonly DependencyProperty MetricNameProperty = DependencyProperty.Register(
        nameof(MetricName), typeof(string), typeof(GaugeControl), new PropertyMetadata(null));

    /// <summary>Dependency property backing <see cref="ReduceMotion"/>.</summary>
    public static readonly DependencyProperty ReduceMotionProperty = DependencyProperty.Register(
        nameof(ReduceMotion), typeof(bool), typeof(GaugeControl), new PropertyMetadata(false, OnStateChanged));

    /// <summary>Dependency property backing <see cref="StrokeThickness"/>.</summary>
    public static readonly DependencyProperty StrokeThicknessProperty = DependencyProperty.Register(
        nameof(StrokeThickness), typeof(double), typeof(GaugeControl), new PropertyMetadata(19d, OnStateChanged));

    private static void OnStateChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is GaugeControl gauge)
        {
            gauge.ApplyTemplateState();
        }
    }
}

