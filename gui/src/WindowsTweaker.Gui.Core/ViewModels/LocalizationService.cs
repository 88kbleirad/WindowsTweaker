using System.Collections.ObjectModel;
using System.Globalization;

namespace WindowsTweaker.Gui.Core.ViewModels;

/// <summary>
/// The interface's text, served by the engine.
/// </summary>
/// <remarks>
/// The frontend keeps no translation of its own. The engine's merged string tables are
/// fetched once per session (<c>strings.get</c>) and looked up here, so the terminal
/// interface and the window render the same words from the same source - the requirement
/// that there be no divergent translation source is structural rather than a convention.
///
/// The lookup order matches the engine's own: requested language, then English, then the
/// key in brackets (visible rather than silent, so a missing key is reported by the
/// interface that needs it instead of rendering an empty label).
///
/// <para><b>Notification contract.</b> Bindings such as
/// <c>{Binding Strings[Gui.Nav.Overview]}</c> are indexer bindings: they re-evaluate only
/// when the source raises a change for the indexer (<c>Item[]</c>) or for all properties.
/// <see cref="Load"/>, <see cref="LoadFailed"/> and a language switch therefore raise the
/// indexer notification, and <see cref="Languages"/> is an observable collection mutated
/// in place so a selector bound to it never keeps a stale, empty instance.</para>
/// </remarks>
public sealed class LocalizationService : ObservableObject
{
    private readonly Dictionary<string, Dictionary<string, string>> _tables = new(StringComparer.OrdinalIgnoreCase);
    private string _active = "en";
    private string _loadError = string.Empty;
    private bool _isLoaded;

    /// <summary>The languages the engine ships (observable; mutated in place by <see cref="Load"/>).</summary>
    public ObservableCollection<string> Languages { get; } = new();

    /// <summary>The active language code.</summary>
    public string Active
    {
        get => _active;
        private set
        {
            if (Set(ref _active, value))
            {
                RaiseIndexer();
            }
        }
    }

    /// <summary>Raised when the active language changes (on load or on an explicit switch).</summary>
    public event EventHandler<string>? LanguageChanged;

    /// <summary>True once real tables have been loaded.</summary>
    public bool IsLoaded => _isLoaded;

    /// <summary>The reason the last load failed, or empty.</summary>
    public string LoadError => _loadError;

    /// <summary>True when the tables could not be loaded.</summary>
    public bool HasError => !string.IsNullOrEmpty(_loadError);

    /// <summary>Installs the tables served by the engine.</summary>
    public void Load(
        IReadOnlyList<string> languages,
        string active,
        IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> tables)
    {
        _tables.Clear();
        foreach (var pair in tables)
        {
            _tables[pair.Key] = new Dictionary<string, string>(pair.Value, StringComparer.Ordinal);
        }

        // The language list is mutated in place: a selector bound to this instance must
        // never keep the (empty) list that existed before the load.
        Languages.Clear();
        foreach (var language in languages)
        {
            if (!string.IsNullOrWhiteSpace(language))
            {
                Languages.Add(language);
            }
        }

        if (Languages.Count == 0)
        {
            foreach (var language in _tables.Keys)
            {
                Languages.Add(language);
            }
        }

        if (!_tables.ContainsKey(active))
        {
            active = _tables.ContainsKey("en") ? "en" : _tables.Keys.FirstOrDefault() ?? "en";
        }

        _loadError = string.Empty;
        _isLoaded = _tables.Count > 0;
        Active = active;
        Raise(nameof(IsLoaded));
        Raise(nameof(HasError));
        Raise(nameof(LoadError));
        RaiseIndexer();
        LanguageChanged?.Invoke(this, active);
    }

    /// <summary>Records that the tables could not be loaded (without inventing text).</summary>
    public void LoadFailed(string message)
    {
        _loadError = message;
        _isLoaded = false;
        Raise(nameof(HasError));
        Raise(nameof(LoadError));
        RaiseIndexer();
    }

    /// <summary>Switches the rendered language (the engine switches its own separately).</summary>
    public void SetActive(string language)
    {
        if (_tables.ContainsKey(language))
        {
            Active = language;

            // A switch is a language change like any other: the event the window listens
            // to must fire here too, not only when the tables are first loaded.
            LanguageChanged?.Invoke(this, language);
        }
    }

    /// <summary>Returns a string with no placeholders.</summary>
    public string this[string key] => Get(key);

    /// <summary>
    /// Returns a string, substituting <c>{0}</c>-style placeholders. Formatting failures
    /// fall back to the raw text: a bad placeholder must not take a view down.
    /// </summary>
    public string Get(string key, params object?[] arguments)
    {
        var text = Lookup(key);
        if (arguments.Length == 0)
        {
            return text;
        }

        try
        {
            return string.Format(CultureInfo.InvariantCulture, text, arguments);
        }
        catch (FormatException)
        {
            return text;
        }
    }

    private string Lookup(string key)
    {
        if (_tables.Count == 0)
        {
            // Before the tables arrive, show the key: an empty label would hide the fact
            // that text is still loading.
            return $"[{key}]";
        }

        if (_tables.TryGetValue(Active, out var active) && active.TryGetValue(key, out var text))
        {
            return text;
        }

        if (_tables.TryGetValue("en", out var english) && english.TryGetValue(key, out var fallback))
        {
            return fallback;
        }

        return $"[{key}]";
    }

    /// <summary>
    /// Raises every notification an indexer/text binding can depend on. WinUI indexer
    /// bindings (<c>Strings[Key]</c>) listen for the indexer name; raising an empty name
    /// means "every property changed", which also refreshes any other bound member.
    /// </summary>
    private void RaiseIndexer()
    {
        Raise("Item");
        Raise("Item[]");
        Raise(string.Empty);
    }
}
