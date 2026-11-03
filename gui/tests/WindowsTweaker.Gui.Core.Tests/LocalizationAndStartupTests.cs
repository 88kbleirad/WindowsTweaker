using System.Text.Json;
using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.ViewModels;
using Xunit;

namespace WindowsTweaker.Gui.Core.Tests;

/// <summary>
/// Tests for the initialization layer: the engine-served string tables and the window's
/// startup sequence. No backend is required; the failing-startup tests point the shell at
/// a directory that holds no engine, which is a real, reachable configuration (a broken or
/// relocated install) rather than a mock.
/// </summary>
[Collection("bridge")]
public sealed class LocalizationAndStartupTests
{
    private static IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> Tables(
        params (string Language, Dictionary<string, string> Entries)[] tables)
    {
        var result = new Dictionary<string, IReadOnlyDictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var (language, entries) in tables)
        {
            result[language] = entries;
        }

        return result;
    }

    private static Dictionary<string, string> Entries(params (string Key, string Text)[] pairs)
    {
        var entries = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, text) in pairs)
        {
            entries[key] = text;
        }

        return entries;
    }

    /// <summary>A service loaded with two languages, active <c>de</c>, and one English-only key.</summary>
    private static LocalizationService Loaded()
    {
        var service = new LocalizationService();
        service.Load(
            new[] { "en", "de" },
            "de",
            Tables(
                ("en", Entries(("Gui.Hello", "Hello"), ("Gui.OnlyEn", "English only"), ("Gui.Two", "{0} and {1}"))),
                ("de", Entries(("Gui.Hello", "Hallo")))));
        return service;
    }

    private static T WithJson<T>(string json, Func<JsonElement, T> read)
    {
        using var document = JsonDocument.Parse(json);
        return read(document.RootElement);
    }

    // ---- LocalizationService ----

    [Fact]
    public void LoadFillsTheLanguageListInPlace()
    {
        var service = new LocalizationService();

        // The instance a language selector binds to before the tables arrive.
        var languages = service.Languages;
        Assert.Empty(languages);

        service.Load(new[] { "en", "de" }, "en", Tables(("en", Entries(("Gui.Hello", "Hello")))));

        Assert.Same(languages, service.Languages);
        Assert.Equal(new[] { "en", "de" }, languages);
    }

    [Fact]
    public void LoadDerivesTheLanguageListFromTheTablesWhenNoneIsSent()
    {
        var service = new LocalizationService();
        var languages = service.Languages;

        service.Load(
            Array.Empty<string>(),
            "en",
            Tables(("en", Entries(("Gui.Hello", "Hello"))), ("de", Entries(("Gui.Hello", "Hallo")))));

        Assert.Same(languages, service.Languages);
        Assert.Equal(new[] { "en", "de" }, languages);
    }

    [Fact]
    public void LoadSetsIsLoadedAndClearsAnEarlierError()
    {
        var service = new LocalizationService();
        service.LoadFailed("backend down");
        Assert.False(service.IsLoaded);
        Assert.True(service.HasError);

        service.Load(new[] { "en" }, "en", Tables(("en", Entries(("Gui.Hello", "Hello")))));

        Assert.True(service.IsLoaded);
        Assert.False(service.HasError);
        Assert.Equal(string.Empty, service.LoadError);
        Assert.Equal("en", service.Active);
    }

    [Fact]
    public void LoadAndSetActiveRaiseTheIndexerNotification()
    {
        var service = new LocalizationService();
        var names = new List<string>();
        service.PropertyChanged += (_, e) => names.Add(e.PropertyName ?? string.Empty);

        service.Load(new[] { "en", "de" }, "en", Tables(
            ("en", Entries(("Gui.Hello", "Hello"))),
            ("de", Entries(("Gui.Hello", "Hallo")))));

        // An indexer binding re-reads only for "Item[]" (or "every property changed").
        Assert.Contains("Item", names);
        Assert.Contains(names, name => name is "Item[]" or "");

        names.Clear();
        service.SetActive("de");

        Assert.Contains("Item", names);
        Assert.Contains(names, name => name is "Item[]" or "");
    }

    [Fact]
    public void LookupFallsBackToTheKeyAndThenToEnglish()
    {
        var service = new LocalizationService();

        // Nothing loaded yet: the key is shown rather than an empty label.
        Assert.Equal("[Gui.Hello]", service["Gui.Hello"]);

        service = Loaded();

        Assert.Equal("Hallo", service["Gui.Hello"]);
        Assert.Equal("English only", service["Gui.OnlyEn"]);
        Assert.Equal("[Gui.Missing]", service["Gui.Missing"]);
    }

    [Fact]
    public void GetSubstitutesPlaceholdersAndSurvivesAMalformedOne()
    {
        var service = Loaded();

        // Active table lacks the key, so the English text is used and still formatted.
        Assert.Equal("a and 5", service.Get("Gui.Two", "a", 5));
        Assert.Equal("{0} and {1}", service["Gui.Two"]);

        // A placeholder with no matching argument must not take the view down.
        Assert.Equal("{0} and {1}", service.Get("Gui.Two", "only"));
    }

    [Fact]
    public void LoadFailedRecordsTheErrorAndLeavesIsLoadedFalse()
    {
        var service = Loaded();
        Assert.True(service.IsLoaded);

        service.LoadFailed("strings.get failed");

        Assert.True(service.HasError);
        Assert.Equal("strings.get failed", service.LoadError);
        Assert.False(service.IsLoaded);
    }

    /// <remarks>
    /// <c>LanguageChanged</c> is raised whenever the active language changes - both when the
    /// tables are installed (with the resolved code, not the requested one) and on an
    /// explicit switch, which is the contract the window's re-binding handler relies on.
    /// A language with no table is not a switch at all, so it raises nothing.
    /// </remarks>
    [Fact]
    public void LanguageChangedFiresOnLoadAndOnASwitch()
    {
        var service = new LocalizationService();
        var observed = new List<string>();
        service.LanguageChanged += (_, language) => observed.Add(language);

        // The requested language is not served, so the event carries the resolved one.
        service.Load(new[] { "en", "de" }, "fr", Tables(
            ("en", Entries(("Gui.Hello", "Hello"))),
            ("de", Entries(("Gui.Hello", "Hallo")))));

        Assert.Equal(new[] { "en" }, observed);
        Assert.Equal("en", service.Active);

        service.SetActive("de");

        Assert.Equal("de", service.Active);
        Assert.Equal(new[] { "en", "de" }, observed);

        // A language with no table is not switched to, and raises no change.
        service.SetActive("fr");
        Assert.Equal("de", service.Active);
        Assert.Equal(new[] { "en", "de" }, observed);
    }

    // ---- Projections ----

    [Fact]
    public void StringsProjectionReadsLanguagesAndNestedTables()
    {
        var (languages, active, tables) = WithJson(
            """
            {
              "languages": ["en", "de"],
              "active": "de",
              "tables": {
                "en": { "Gui.Hello": "Hello", "Gui.Bye": "Bye" },
                "de": { "Gui.Hello": "Hallo" }
              }
            }
            """,
            Projections.Strings);

        Assert.Equal(new[] { "en", "de" }, languages);
        Assert.Equal("de", active);
        Assert.Equal(2, tables.Count);
        Assert.Equal("Hallo", tables["de"]["Gui.Hello"]);
        Assert.Equal(2, tables["en"].Count);
        Assert.Equal("Bye", tables["en"]["Gui.Bye"]);
    }

    [Fact]
    public void StringsProjectionToleratesAnEmptyOrOddPayload()
    {
        var (emptyLanguages, emptyActive, emptyTables) = WithJson("{}", Projections.Strings);
        Assert.Empty(emptyLanguages);
        Assert.Equal(string.Empty, emptyActive);
        Assert.Empty(emptyTables);

        var (missingLanguages, _, missingTables) = Projections.Strings(default);
        Assert.Empty(missingLanguages);
        Assert.Empty(missingTables);

        // Wrong kinds are read defensively instead of throwing.
        var (oddLanguages, _, oddTables) = WithJson(
            """{"languages":"en","tables":{"de":{"Gui.Hello":42}}}""",
            Projections.Strings);
        Assert.Empty(oddLanguages);
        Assert.Equal("42", oddTables["de"]["Gui.Hello"]);
    }

    [Fact]
    public void CatalogProjectionReadsCategoriesAndTweaks()
    {
        var (categories, tweaks) = WithJson(
            """
            {
              "categories": ["Appearance", "Privacy", ""],
              "tweaks": [
                { "Id": "T1", "Category": "Appearance", "DisplayName": "Dark mode" },
                { "Id": "T2", "Category": "Privacy" }
              ]
            }
            """,
            Projections.Catalog);

        Assert.Equal(new[] { "Appearance", "Privacy" }, categories);
        Assert.Equal(2, tweaks.Count);
        Assert.Equal("T1", tweaks[0].Id);
        Assert.Equal("Appearance", tweaks[0].Category);
        Assert.Equal("Dark mode", tweaks[0].DisplayName);
        Assert.Equal("T2", tweaks[1].DisplayName);
    }

    // ---- ShellViewModel startup ----

    [Fact]
    public async Task ConnectAgainstAMissingEngineRootFailsWithoutThrowing()
    {
        var root = Path.Combine(Path.GetTempPath(), "wt-nobackend-" + Guid.NewGuid().ToString("n"));
        Directory.CreateDirectory(root);
        try
        {
            await using var shell = new ShellViewModel(root);

            var error = await shell.ConnectAsync();

            Assert.False(string.IsNullOrEmpty(error));
            Assert.Equal(error, shell.InitializationError);
            Assert.Equal(InitializationState.Failed, shell.Initialization);
            Assert.True(shell.InitializationFailed);
            Assert.False(shell.InitializationBusy);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task ReconnectAgainstAMissingEngineRootFailsTheSameWay()
    {
        var root = Path.Combine(Path.GetTempPath(), "wt-nobackend-" + Guid.NewGuid().ToString("n"));
        Directory.CreateDirectory(root);
        try
        {
            await using var shell = new ShellViewModel(root);
            await shell.ConnectAsync();

            var error = await shell.ReconnectAsync();

            Assert.False(string.IsNullOrEmpty(error));
            Assert.Equal(error, shell.InitializationError);
            Assert.Equal(InitializationState.Failed, shell.Initialization);
            Assert.True(shell.InitializationFailed);
            Assert.False(shell.InitializationBusy);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    // ---- live end-to-end startup against the real engine ----
    //
    // These are the regression tests for the reported failure shape: the window opened with
    // every label as its raw [Key], an empty language selector and a 0/0 catalog because the
    // startup sequence aborted after the handshake. They run the real sequence (handshake ->
    // strings.get -> env.status -> overview load) against the real bridge, so a contract
    // change on either side fails here instead of only in the GUI.

    [SkippableFact]
    public async Task StartupLoadsLocalizationAndTheCatalogFromTheRealEngine()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        var notifications = new List<string>();
        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        shell.Strings.PropertyChanged += (_, e) => notifications.Add(e.PropertyName ?? string.Empty);

        var error = await shell.ConnectAsync();

        Assert.Null(error);
        Assert.Equal(InitializationState.Ready, shell.Initialization);
        Assert.True(shell.IsConnected);
        Assert.False(shell.InitializationBusy);

        // Localization payload: the tables arrived, the language list is populated, and the
        // active language is the one the environment asked for (WT_LANG=en in the tests).
        Assert.True(shell.Strings.IsLoaded);
        Assert.False(shell.Strings.HasError);
        Assert.Equal(new[] { "en", "vi" }, shell.Strings.Languages.ToArray());
        Assert.Equal("en", shell.Strings.Active);

        // Indexer binding contract: the load must re-evaluate `Strings[Key]` bindings, and a
        // real key must resolve instead of falling back to "[Key]".
        Assert.Contains("Item[]", notifications);
        Assert.DoesNotContain("[", shell.Strings["Gui.Nav.Overview"]);
        Assert.DoesNotContain("[", shell.Strings["Gui.Footer.Hint"]);

        // The overview's catalog counts come from the backend and agree with what the engine
        // reports for the same catalog - never a default 0 from an aborted load.
        var catalog = await shell.Runner.RunAsync(
            "catalog.list",
            Projections.Catalog,
            timeout: TimeSpan.FromSeconds(60));
        Assert.True(catalog.Ok, catalog.Message);

        await shell.NavigateAsync(Workspace.Overview);
        Assert.Equal(LoadState.Ready, shell.Overview.State);
        Assert.Equal(catalog.Value.Tweaks.Count, shell.Overview.TweakCount);
        Assert.Equal(catalog.Value.Categories.Count, shell.Overview.CategoryCount);
        Assert.True(shell.Overview.TweakCount >= 100, $"Expected the whole catalog, got {shell.Overview.TweakCount}.");
        Assert.Equal(10, shell.Overview.CategoryCount);
        Assert.Contains(shell.Overview.TweakCount.ToString(), shell.Overview.CatalogSummary);
        Assert.DoesNotContain("[", shell.Overview.CatalogSummary);

        // The environment facts the overview renders are real values, not placeholders.
        Assert.NotNull(shell.Environment);
        Assert.True(shell.Overview.HasEnvironment);
        Assert.DoesNotContain("[", shell.Overview.OsText);
        Assert.DoesNotContain("[", shell.Overview.PowerShellText);
        Assert.DoesNotContain("[", shell.Overview.EngineText);
        Assert.False(string.IsNullOrEmpty(shell.Overview.OsText));
        Assert.False(string.IsNullOrEmpty(shell.Overview.PowerShellText));
        Assert.False(string.IsNullOrEmpty(shell.Overview.EngineText));
    }

    [SkippableFact]
    public async Task SwitchingLanguageReLocalizesAndNotifiesThroughTheRealEngine()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        Assert.Null(await shell.ConnectAsync());

        var englishTitle = shell.Strings["Gui.Nav.Overview"];
        var target = shell.Strings.Languages.First(language => language != shell.Strings.Active);

        var notifications = new List<string>();
        shell.Strings.PropertyChanged += (_, e) => notifications.Add(e.PropertyName ?? string.Empty);

        await shell.SetLanguageAsync(target);

        Assert.Equal(target, shell.Strings.Active);
        Assert.Contains("Item[]", notifications);
        Assert.NotEqual(englishTitle, shell.Strings["Gui.Nav.Overview"]);
        Assert.DoesNotContain("[", shell.Strings["Gui.Nav.Overview"]);

        // The switch is a real round trip: the engine agrees with the client afterwards.
        var switched = await shell.Runner.RunAsync(
            "strings.get",
            Projections.Strings,
            timeout: TimeSpan.FromSeconds(60));
        Assert.True(switched.Ok, switched.Message);
        Assert.Equal(target, switched.Value.Active);
    }

    [SkippableFact]
    public async Task HandshakeReportsTheEngineVersionNotThePowerShellVersion()
    {
        Skip.IfNot(TestPaths.CanRunLive, "No PowerShell host (or no bridge script) is available on this machine.");

        await using var shell = new ShellViewModel(TestPaths.RepositoryRoot);
        Assert.Null(await shell.ConnectAsync());

        var manifest = Path.Combine(TestPaths.RepositoryRoot, "src", "WindowsTweaker", "WindowsTweaker.psd1");
        var match = System.Text.RegularExpressions.Regex.Match(
            File.ReadAllText(manifest),
            @"ModuleVersion\s*=\s*'([^']+)'");

        Assert.True(match.Success, "The module manifest must declare ModuleVersion.");
        Assert.Equal(match.Groups[1].Value, shell.EngineVersion);

        // The runtime has its own line in the overview; reporting it as the engine version
        // printed the same number twice.
        Assert.NotNull(shell.Environment);
        Assert.NotEqual(shell.Environment!.PowerShellVersion, shell.EngineVersion);
    }
}
