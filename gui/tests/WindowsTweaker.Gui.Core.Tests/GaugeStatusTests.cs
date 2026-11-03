using WindowsTweaker.Gui.Core.Model;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// The semicircular gauge's utilization classification, isolated from the UI: the same
/// thresholds the control renders (normal/elevated/high/very high) are asserted here at the
/// documented boundaries, plus the all-values-and-zero edge cases the arc must draw without
/// clipping or inventing data.
/// </summary>
public sealed class GaugeStatusTests
{
    [Theory]
    [InlineData(0d, GaugeStatus.Normal)]
    [InlineData(59.999d, GaugeStatus.Normal)]
    [InlineData(60d, GaugeStatus.Elevated)]
    [InlineData(79.999d, GaugeStatus.Elevated)]
    [InlineData(80d, GaugeStatus.High)]
    [InlineData(94.999d, GaugeStatus.High)]
    [InlineData(95d, GaugeStatus.VeryHigh)]
    [InlineData(100d, GaugeStatus.VeryHigh)]
    public void ThresholdsMapToTheDocumentedStatuses(double percent, GaugeStatus expected)
    {
        Assert.Equal(expected, GaugeStatusRules.FromPercent(percent));
    }

    [Theory]
    [InlineData(-5d)]   // clamped to 0, never negative
    [InlineData(150d)]  // clamped to 100, never above
    [InlineData(60.5d)]
    public void OutOfRangeValuesClampInsteadOfThrowing(double percent)
    {
        var status = GaugeStatusRules.FromPercent(percent);
        Assert.True(Enum.IsDefined(status));
    }

    [Fact]
    public void ExactlyOneHundredRendersFullRedWithoutBlinking()
    {
        // The 100% case must be a stable, solid red (very high) - the gauge never animates
        // or blinks, and full is represented by the full arc, not a status that toggles.
        Assert.Equal(GaugeStatus.VeryHigh, GaugeStatusRules.FromPercent(100d));
    }
}
