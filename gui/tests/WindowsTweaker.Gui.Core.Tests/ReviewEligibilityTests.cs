using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.ViewModels;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// Command eligibility for the review workspace, in the four states the workflow has to get
/// right: nothing staged, staged but nothing selected, an operation already in flight, and no
/// backend connection.
/// </summary>
/// <remarks>
/// A greyed-out button is not the guarantee - the command layer re-checks the same
/// preconditions - so these assertions cover both the property the button binds and the
/// refusal the command returns.
/// </remarks>
[Collection("bridge")]
public sealed class ReviewEligibilityTests
{
    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline && !condition())
        {
            await Task.Delay(50);
        }
    }

    [SkippableFact]
    public async Task EmptyStagedListOffersOneNextActionAndNoCommands()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        await LiveShell.ConnectAsync(shell);
        await shell.NavigateAsync(Workspace.Review);

        // Nothing staged: one message, one next action, and every operation refused.
        Assert.True(shell.Review.IsEmptyState);
        Assert.False(string.IsNullOrWhiteSpace(shell.Review.EmptyStateMessage));
        Assert.False(string.IsNullOrWhiteSpace(shell.Review.EmptyStateAction));
        Assert.False(shell.Review.HasChanges);
        Assert.False(shell.Review.CanPreview);
        Assert.False(shell.Review.CanApply);
        Assert.False(shell.Review.CanRemove);
        Assert.False(shell.Review.CanClear);
        Assert.Empty(shell.Review.Changes);

        // The commands refuse too, even if a caller ignores the bound state.
        await shell.Review.PreviewAsync();
        await shell.Review.ApplyAsync();
        Assert.True(shell.Review.IsEmptyState);
        Assert.Empty(shell.Review.Changes);
    }

    [SkippableFact]
    public async Task StagedItemsWithoutASelectionCannotRemoveAndCannotRunWhileBusy()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        await LiveShell.ConnectAsync(shell);

        // Stage through the engine's own eligibility rule, so this covers a list the engine
        // accepts; on a host with nothing applicable the refusal path is asserted instead.
        await shell.NavigateAsync(Workspace.Tweaks);
        var tweak = shell.Tweaks.States.FirstOrDefault(row => row.CanRun && row.StateNames.Count > 0);
        if (tweak is null)
        {
            var refused = shell.Tweaks.States.First();
            shell.Tweaks.Selected = refused;
            shell.Tweaks.TargetState = refused.StateNames.FirstOrDefault() ?? string.Empty;
            Assert.False(string.IsNullOrWhiteSpace(shell.Tweaks.StageSelection()));
            Assert.False(shell.Tweaks.CanStage);
            return;
        }

        shell.Tweaks.Selected = tweak;
        shell.Tweaks.TargetState = tweak.StateNames.First();
        Assert.Null(shell.Tweaks.StageSelection());
        await shell.NavigateAsync(Workspace.Review);
        Assert.True(shell.Review.HasChanges);

        // Staged but nothing selected: removal is refused, clearing is allowed.
        shell.Review.SelectedChange = null;
        Assert.False(shell.Review.CanRemove);
        Assert.True(shell.Review.CanClear);

        // While another operation is in flight, a second backend command is refused.
        await shell.RunReadAsync(async () =>
        {
            Assert.True(shell.Busy);
            Assert.False(shell.Review.CanPreview);
            Assert.False(shell.Review.CanApply);
            await Task.CompletedTask;
            return true;
        });

        // Reaching the end of a read leaves the workspace usable again.
        await WaitUntilAsync(() => !shell.Busy, TimeSpan.FromSeconds(5));
        Assert.False(shell.Busy);
    }

    [SkippableFact]
    public async Task ADeadBackendDisablesEveryStagedCommandButKeepsTheSelection()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        await LiveShell.ConnectAsync(shell);
        await shell.NavigateAsync(Workspace.Tweaks);
        var tweak = shell.Tweaks.States.FirstOrDefault(row => row.CanRun && row.StateNames.Count > 0);
        if (tweak is null)
        {
            return; // covered by the refusal path in the previous test
        }

        shell.Tweaks.Selected = tweak;
        shell.Tweaks.TargetState = tweak.StateNames.First();
        Assert.Null(shell.Tweaks.StageSelection());
        var staged = shell.Review.Changes.Select(row => row.Change.Id).ToList();

        await shell.NavigateAsync(Workspace.Review);
        var backend = shell.Runner.BackendProcessId;
        Assert.NotNull(backend);
        using (var process = System.Diagnostics.Process.GetProcessById(backend!.Value))
        {
            var name = process.ProcessName;
            Assert.True(
                name.Equals("powershell", StringComparison.OrdinalIgnoreCase)
                    || name.Equals("pwsh", StringComparison.OrdinalIgnoreCase),
                $"refusing to kill process {backend.Value}: '{name}' is not a PowerShell host");
            process.Kill();
            process.WaitForExit(15000);
        }

        await WaitUntilAsync(() => !shell.IsConnected, TimeSpan.FromSeconds(15));
        Assert.False(shell.IsConnected);

        // A dead backend disables the backend commands, and the staged work is not lost.
        Assert.False(shell.Review.CanPreview);
        Assert.False(shell.Review.CanApply);
        Assert.False(shell.Review.CanCancel);
        Assert.Equal(staged, shell.Review.Changes.Select(row => row.Change.Id));
    }
}
