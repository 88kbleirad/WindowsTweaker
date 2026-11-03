using System.Reflection;
using System.Text.RegularExpressions;
using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.ViewModels;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// Static wiring checks for the window definition.
/// </summary>
/// <remarks>
/// The XAML markup compiler runs only on Windows and a <c>{Binding}</c> whose path does not
/// exist on the DataContext does not fail the build - the target silently keeps its default
/// value. That is how "the stale note was visible even when nothing was stale" reached a
/// running window: the note bound <c>IsStale</c>, which lives on a workspace view model,
/// while the window's DataContext is the shell. These checks resolve every binding and every
/// event handler against the types the window actually binds to, so the same class of
/// defect fails here instead of only on a Windows screen.
/// </remarks>
public sealed class WinUiXamlWiringTests
{
    private const string XamlRelativePath = "gui/src/WindowsTweaker.WinUI/MainWindow.xaml";
    private const string CodeBehindRelativePath = "gui/src/WindowsTweaker.WinUI/MainWindow.xaml.cs";

    /// <summary>
    /// The types a DataTemplate inside the window binds to. Outside a template every binding
    /// resolves against <see cref="ShellViewModel"/> (the window's DataContext), so this list
    /// is deliberately narrow: adding a type here is a statement that the window renders it.
    /// </summary>
    private static readonly Type[] TemplateItemTypes =
    {
        typeof(LanguageOption),
        typeof(HistoryDisplayRow),
        typeof(OperationDisplayRow),
        typeof(InterruptedDisplayRow),
        typeof(ApplyResult),
        typeof(ReviewedChange),
        typeof(TweakRow),
        typeof(ReviewChangeRow),
        typeof(DataPoint),
    };

    [Fact]
    public void EveryBindingInTheWindowResolvesOnItsDataContext()
    {
        var xaml = ReadRepositoryFile(XamlRelativePath);
        var shell = PublicInstanceMembers(typeof(ShellViewModel));
        var template = TemplateItemTypes.SelectMany(PublicInstanceMembers).ToHashSet(StringComparer.Ordinal);
        var unresolved = new List<string>();

        foreach (Match match in Regex.Matches(xaml, @"\{Binding\s+([^},]*)"))
        {
            var path = match.Groups[1].Value.Trim();
            if (path.Length == 0 || path.StartsWith("Converter=", StringComparison.Ordinal))
            {
                // {Binding Converter=...} binds the item itself; there is no path to resolve.
                continue;
            }

            // {Binding Strings[Some.Key]} - the indexer is the contract; the key itself is
            // checked against the merged language tables by the engine's Pester suite.
            if (path.StartsWith("Strings[", StringComparison.Ordinal))
            {
                continue;
            }

            var root = Regex.Split(path, @"[.\[]")[0];
            if (!shell.Contains(root) && !template.Contains(root))
            {
                unresolved.Add($"{path} (root '{root}')");
            }
        }

        Assert.True(
            unresolved.Count == 0,
            "these bindings do not resolve on the shell view model or on a template item type: "
                + string.Join(", ", unresolved));
    }

    [Fact]
    public void EveryEventAttributeNamesAHandlerThatExists()
    {
        var xaml = ReadRepositoryFile(XamlRelativePath);
        var code = ReadRepositoryFile(CodeBehindRelativePath);
        var missing = new List<string>();

        foreach (Match match in Regex.Matches(
                     xaml,
                     @"(?:Click|SelectionChanged|Checked|Unchecked|Toggled|TextChanged|ValueChanged)=""([A-Za-z_][A-Za-z0-9_]*)"""))
        {
            var handler = match.Groups[1].Value;
            if (handler is "True" or "False" or "None" or "All")
            {
                continue;
            }

            if (!Regex.IsMatch(code, @"void\s+" + Regex.Escape(handler) + @"\s*[<(]"))
            {
                missing.Add(handler);
            }
        }

        Assert.True(missing.Count == 0, "no code-behind method for: " + string.Join(", ", missing));
    }

    private static string ReadRepositoryFile(string relativePath)
    {
        var fullPath = Path.Combine(TestPaths.RepositoryRoot, relativePath.Replace('/', Path.DirectorySeparatorChar));
        Assert.True(File.Exists(fullPath), $"expected the window definition at {fullPath}");
        return File.ReadAllText(fullPath);
    }

    private static HashSet<string> PublicInstanceMembers(Type type)
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in type.GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            names.Add(property.Name);
        }

        return names;
    }
}
