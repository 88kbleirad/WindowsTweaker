using WindowsTweaker.Gui.Core.Bridge;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>Discovery tests: a candidate is believed only after it is run.</summary>
public sealed class PowerShellLocatorTests
{
    [Fact]
    public void CandidatesAreUniqueAndNeverContainEmptyPaths()
    {
        var candidates = PowerShellLocator.Candidates();

        Assert.All(candidates, candidate => Assert.False(string.IsNullOrWhiteSpace(candidate.Path)));
        Assert.Equal(candidates.Count, candidates.Select(c => c.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }

    [Fact]
    public void ProbeRejectsAMissingFileInsteadOfTrustingItsName()
    {
        var missing = Path.Combine(Path.GetTempPath(), "definitely-not-pwsh-" + Guid.NewGuid().ToString("n"));

        Assert.Null(PowerShellLocator.Probe(missing, "test"));
    }

    [Fact]
    public void DiscoverProbesEveryCandidateItReports()
    {
        var hosts = PowerShellLocator.Discover();

        foreach (var host in hosts)
        {
            Assert.True(File.Exists(host.Path), $"{host.Path} was reported as a host but does not exist.");
            Assert.NotNull(host.Version);
            Assert.Contains(host.Edition, new[] { "Core", "Desktop" });
        }
    }

    [Fact]
    public void ReportsTheProcessArchitectureAsAStableKey()
    {
        Assert.Contains(PowerShellLocator.CurrentArchitecture, new[] { "x64", "x86", "arm64" });
    }
}
