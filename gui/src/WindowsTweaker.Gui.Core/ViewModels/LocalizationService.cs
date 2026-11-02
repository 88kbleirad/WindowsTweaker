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
/// </remarks>
public sealed class LocalizationService : ObservableObject
{
    private readonly Dictionary<string, Dictionary<string, string>> _tables = new(StringComparer.OrdinalIgnoreCase);
    private List<string> _languages = new();
    private string _active = "en";

    /// <summary>The languages the engine ships.</summary>
    public IReadOnlyList<string> Languages => _languages;

    /// <summary>The active language code.</summary>
    public string Active
    {
        get => _active;
        private set
        {
            if (Set(ref _active, value))
            {
                Raise("Item");
                LanguageChanged?.Invoke(this, value);
            }
        }
    }

    /// <summary>Raised when the active language changes, so views can re-read their text.</summary>
    public event EventHandler<string>? LanguageChanged;

    /// <summary>True once real tables have been loaded.</summary>
    public bool IsLoaded => _tables.Count > 0;

    /// <summary>Installs the tables served by the engine.</summary>
    public void Load(IReadOnlyList<string> languages, string active, IReadOnlyDictionary<string, IReadOnlyDictionary<string, string>> tables)
    {
        _tables.Clear();
        foreach (var pair in tables)
        {
            _tables[pair.Key] = new Dictionary<string, string>(pair.Value, StringComparer.Ordinal);
        }

        _languages = languages.ToList();
        if (_languages.Count == 0)
        {
            _languages.AddRange(_tables.Keys);
        }

        if (!_tables.ContainsKey(active))
        {
            active = _tables.ContainsKey("en") ? "en" : _tables.Keys.FirstOrDefault() ?? "en";
        }

        Active = active;
        Raise("Item");
        LanguageChanged?.Invoke(this, active);
    }

    /// <summary>Switches the rendered language (the engine switches its own separately).</summary>
    public void SetActive(string language)
    {
        if (_tables.ContainsKey(language))
        {
            Active = language;
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
            return string.Format(System.Globalization.CultureInfo.InvariantCulture, text, arguments);
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
}
