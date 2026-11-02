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

    /// <summary>
    /// Registers crash handlers before any instance code runs, so an exception in the App
    /// constructor still reaches the startup log.
    /// </summary>
    static App()
    {
        StartupDiagnostics.RegisterExceptionHandlers();
    }

    public App()
    {
        StartupDiagnostics.RegisterXamlExceptionHandler(this);
        StartupDiagnostics.LogEnvironment();
        StartupDiagnostics.Stage("App.ctor begin");
        ParseArguments(Environment.GetCommandLineArgs());
        StartupDiagnostics.Stage("App.arguments parsed");
        try
        {
            InitializeComponent();
        }
        catch (Exception exception)
        {
            // Record the full chain before it becomes a stowed exception at the process
            // boundary (0xc000027b) — this is the earliest place the real failure is
            // visible as a managed exception. The exception is rethrown: nothing fatal is
            // swallowed here, and we want the initial window to fail loudly.
            StartupDiagnostics.Error("App.InitializeComponent failed", exception);
            throw;
        }
        StartupDiagnostics.Stage("App.InitializeComponent done");
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
        StartupDiagnostics.Stage("App.OnLaunched begin");
        _window = new MainWindow();
        StartupDiagnostics.Stage("MainWindow constructed");
        _window.Activate();
        StartupDiagnostics.Stage("MainWindow activated");
    }
}
