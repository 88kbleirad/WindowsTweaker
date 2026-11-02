using Microsoft.UI.Xaml;

namespace WindowsTweaker.WinUI;

/// <summary>The application entry point. No engine work happens here: the window owns it.</summary>
public partial class App : Application
{
    private Window? _window;

    /// <summary>Engine root passed with <c>--engine</c> (used by the elevated relaunch).</summary>
    public static string? ArgumentEngineRoot { get; private set; }

    /// <summary>Language passed with <c>--language</c> (used by the elevated relaunch).</summary>
    public static string? ArgumentLanguage { get; private set; }

    /// <summary>True when this copy was started by the elevation handoff.</summary>
    public static bool ArgumentElevated { get; private set; }

    public App()
    {
        ParseArguments(Environment.GetCommandLineArgs());
        InitializeComponent();
    }

    private static void ParseArguments(string[] args)
    {
        for (var i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--elevated":
                    ArgumentElevated = true;
                    break;
                case "--engine" when i + 1 < args.Length:
                    ArgumentEngineRoot = args[++i];
                    break;
                case "--language" when i + 1 < args.Length:
                    ArgumentLanguage = args[++i];
                    break;
            }
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
    }
}
