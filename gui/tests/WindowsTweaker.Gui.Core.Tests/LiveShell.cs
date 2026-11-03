using WindowsTweaker.Gui.Core.ViewModels;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// Shared helpers for the live tests, so a connect failure reports what the window would
/// have shown instead of only the returned sentence.
/// </summary>
internal static class LiveShell
{
    /// <summary>
    /// Connects the shell and asserts it succeeded. On failure the assertion carries the
    /// shell's own diagnostics (which stage failed and why), because "the interface text did
    /// not load" is a symptom and the diagnostic tail is the cause.
    /// </summary>
    public static async Task ConnectAsync(ShellViewModel shell)
    {
        var failure = await shell.ConnectAsync();
        if (failure is not null)
        {
            var diagnostics = string.Join(" | ", shell.Diagnostics.Diagnostics);
            Assert.Fail($"connect failed: {failure}{Environment.NewLine}diagnostics: {diagnostics}");
        }
    }
}
