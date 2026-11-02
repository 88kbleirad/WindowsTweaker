using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Windowing;
using WindowsTweaker.Gui.Core.Model;
using WindowsTweaker.Gui.Core.ViewModels;

namespace WindowsTweaker.WinUI;

/// <summary>
/// The main window. It owns the <see cref="ShellViewModel"/> and the navigation; every
/// workspace renders what the shell already computed, and nothing here talks to the
/// engine directly.
/// </summary>
/// <remarks>
/// System-owned chrome that cannot be restyled is called out honestly:
/// <list type="bullet">
/// <item>the title bar, the window frame and the default context menus belong to the OS
/// (DWM) and keep their rounded corners; the app's own panels and controls have square
/// corners by style;</item>
/// <item>WinUI dialog overlays (<see cref="ContentDialog"/>) follow the system control
/// template and are rounded; the application uses them only for the closing-choice and
/// the apply confirmation, and keeps inline panels square.</item>
/// </list>
/// </remarks>
public sealed partial class MainWindow : Window
{
    private readonly ShellViewModel _shell;
    private bool _closing;

    public MainWindow()
    {
        InitializeComponent();

        _shell = new ShellViewModel(EngineLocator.ResolveRepositoryRoot(), dispatch: action =>
        {
            if (DispatcherQueue is not null)
            {
                DispatcherQueue.TryEnqueue(() => action());
            }
            else
            {
                action();
            }
        });

        RootGrid.DataContext = _shell;

        // The environment text updates through the shell's bindings; the header badges
        // listen to the properties the shell raises.
        _shell.PropertyChanged += OnShellPropertyChanged;
        _shell.Strings.LanguageChanged += (_, _) => UpdateLanguageBinding();

        LanguageCombo.ItemsSource = _shell.Strings.Languages;
        LanguageCombo.SelectionChanged += (_, _) =>
        {
            if (LanguageCombo.SelectedItem is string language && language != _shell.Strings.Active)
            {
                _ = _shell.SetLanguageAsync(language);
            }
        };

        ReduceMotionBox.IsChecked = _shell.ReduceMotion;
        ReduceMotionBox.Click += (_, _) => _shell.ReduceMotion = ReduceMotionBox.IsChecked == true;

        // The default window is comfortably large; the floor keeps the layout readable on
        // small screens instead of letting the panels collapse into unusable slivers.
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1200, 800));
        AppWindow.SetPresenter(AppWindowPresenterKind.Default);

        RootGrid.KeyDown += RootGrid_KeyDown;
        SearchBox.KeyDown += SearchBox_KeyDown;
        _shell.Review.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ReviewViewModel.HasResults))
            {
                UpdateReviewResultsVisibility();
            }
        };

        Closed += OnClosed;
        _shell.Runner.Exited += (_, _) => _shell.Dispatch(() => UpdateBackendBadge());

        // Connect then load the overview; the banner reports whatever is wrong.
        _ = InitializeAsync();
    }

    /// <summary>
    /// Window-level keyboard support. Tab/Shift+Tab, arrows and Enter are native to the
    /// controls; this adds what the task requires and the controls do not provide.
    /// Nothing here intercepts letter keys while a field is focused - SearchBox gets its
    /// own handler for the Ctrl+Enter stage and otherwise keeps typing untouched.
    /// </summary>
    private async void RootGrid_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Escape)
        {
            // Escape closes a dialog that is open; otherwise it clears the search and
            // returns focus to the tweak list (the terminal interface's escape habit).
            if (DialogCount > 0 || _closing)
            {
                return;
            }

            if (!string.IsNullOrEmpty(_shell.Tweaks.Search))
            {
                _shell.Tweaks.Search = string.Empty;
                SearchBox.Focus(FocusState.Keyboard);
                e.Handled = true;
                return;
            }

            if (_shell.Current != Workspace.Tweaks)
            {
                NavList.SelectedIndex = (int)Workspace.Tweaks;
                e.Handled = true;
            }

            return;
        }

        if (e.Key == Windows.System.VirtualKey.F5)
        {
            // Refresh the current workspace (same action as the toolbar button).
            await RefreshAsync();
            e.Handled = true;
        }

        if (e.Key == Windows.System.VirtualKey.F && KeyboardModifiers.IsControlPressed())
        {
            // Ctrl+F focuses the search box without typing in it.
            NavList.SelectedIndex = (int)Workspace.Tweaks;
            SearchBox.Focus(FocusState.Keyboard);
            e.Handled = true;
        }
    }

    /// <summary>
    /// Ctrl+Enter in the search box stages the current selection into the review list
    /// (the mouse path's "Add to review"). Plain typing is never intercepted.
    /// </summary>
    private void SearchBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter && KeyboardModifiers.IsControlPressed())
        {
            if (_shell.Tweaks.HasSelection)
            {
                AddPending_Click(sender, new RoutedEventArgs());
            }

            e.Handled = true;
        }
    }

    private static class KeyboardModifiers
    {
        public static bool IsControlPressed() =>
            (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
                & Windows.UI.Core.CoreVirtualKeyStates.Down) == Windows.UI.Core.CoreVirtualKeyStates.Down;
    }

    private void UpdateElevateButton()
    {
        // The elevate control offers the handoff only when the backend itself is not
        // elevated (the child is already elevated, or there is nothing to hand off to).
        // On non-Windows hosts the engine reports its own capability and this stays
        // hidden.
        ElevateButton.Visibility = _shell.IsElevated || !_shell.IsProcessElevated
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void UpdateReviewResultsVisibility()
    {
        ReviewResultsPanel.Visibility = _shell.Review.HasResults
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private int _dialogCount;

    /// <summary>Tracks open dialogs so Escape does not fight one.</summary>
    private int DialogCount => _dialogCount;

    private async void Elevate_Click(object sender, RoutedEventArgs e)
    {
        var failure = await _shell.RelaunchElevatedAsync();
        if (failure is not null)
        {
            _shell.StatusText = failure;
        }
        else
        {
            // The elevated child owns the session now; this copy closes.
            _closing = true;
            Close();
        }
    }

    private async Task InitializeAsync()
    {
        var failure = await _shell.ConnectAsync();
        if (failure is null)
        {
            // The elevated relaunch carries the language across the handoff; the engine
            // answers in its own default until told otherwise.
            if (!string.IsNullOrWhiteSpace(App.ArgumentLanguage) && App.ArgumentLanguage != _shell.Strings.Active)
            {
                await _shell.SetLanguageAsync(App.ArgumentLanguage);
            }

            LanguageCombo.SelectedItem = _shell.Strings.Active;
            await _shell.NavigateAsync(Workspace.Overview);
            UpdateBackendBadge();
        }
    }

    private void OnShellPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ShellViewModel.HeaderEnvironment))
        {
            EnvironmentText.Text = _shell.HeaderEnvironment;
        }
        else if (e.PropertyName == nameof(ShellViewModel.BackendSummary))
        {
            BackendText.Text = _shell.BackendSummary;
            UpdateBackendBadge();
        }
        else if (e.PropertyName == nameof(ShellViewModel.IsElevated))
        {
            ElevationBadge.Visibility = _shell.IsElevated ? Visibility.Visible : Visibility.Collapsed;
            ElevationText.Text = _shell.IsElevated
                ? _shell.Strings["Tui.Header.Admin"]
                : _shell.Strings["Tui.Header.Standard"];

            UpdateElevateButton();
        }
        else if (e.PropertyName == nameof(ShellViewModel.IsProcessElevated))
        {
            UpdateElevateButton();
        }
        else if (e.PropertyName == nameof(ShellViewModel.CurrentTitle))
        {
            WorkspaceTitle.Text = _shell.CurrentTitle;
        }
    }

    private void UpdateLanguageBinding()
    {
        // Re-evaluate the binding source so localized labels re-render.
        RootGrid.DataContext = null;
        RootGrid.DataContext = _shell;
        WorkspaceTitle.Text = _shell.CurrentTitle;
        EnvironmentText.Text = _shell.HeaderEnvironment;
    }

    private void UpdateBackendBadge()
    {
        BackendText.Text = _shell.IsConnected ? _shell.BackendSummary : _shell.Strings["Gui.BackendDown"];
        BackendBadge.Style = _shell.IsConnected
            ? (Style)RootGrid.Resources["WtBadgeOk"]
            : (Style)RootGrid.Resources["WtBadgeError"];
    }

    private async void NavList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (NavList.SelectedIndex < 0)
        {
            return;
        }

        var workspace = (Workspace)NavList.SelectedIndex;
        await _shell.NavigateAsync(workspace);
        ShowWorkspace(workspace);
    }

    private void ShowWorkspace(Workspace workspace)
    {
        OverviewPanel.Visibility = Visibility.Collapsed;
        TweaksPanel.Visibility = Visibility.Collapsed;
        ReviewPanel.Visibility = Visibility.Collapsed;
        HistoryPanel.Visibility = Visibility.Collapsed;
        DiagnosticsPanel.Visibility = Visibility.Collapsed;
        LicensingPanel.Visibility = Visibility.Collapsed;

        switch (workspace)
        {
            case Workspace.Overview:
                OverviewPanel.Visibility = Visibility.Visible;
                break;
            case Workspace.Tweaks:
                TweaksPanel.Visibility = Visibility.Visible;
                break;
            case Workspace.Review:
                ReviewPanel.Visibility = Visibility.Visible;
                break;
            case Workspace.History:
                HistoryPanel.Visibility = Visibility.Visible;
                break;
            case Workspace.Diagnostics:
                DiagnosticsPanel.Visibility = Visibility.Visible;
                break;
            case Workspace.Licensing:
                LicensingPanel.Visibility = Visibility.Visible;
                break;
        }

        // Reduced motion: the one app-owned animation (a brief panel fade) is skipped
        // entirely. System-owned animation (dialogs, focus rings) follows the OS
        // "animation effects" setting, which this app does not override.
        if (!_shell.ReduceMotion)
        {
            AnimateWorkspaceEntrance(workspace);
        }

        // The cancel/refresh actions apply to the workspace that is visible.
        CancelButton.Visibility = _shell.Busy ? Visibility.Visible : Visibility.Collapsed;
    }

    private void AnimateWorkspaceEntrance(Workspace workspace)
    {
        // The panels are Grids except Diagnostics (a ScrollViewer), so the switch arms
        // have no single best type; the common base the animation target needs is
        // DependencyObject.
        var panel = (DependencyObject)(workspace switch
        {
            Workspace.Overview => OverviewPanel,
            Workspace.Tweaks => TweaksPanel,
            Workspace.Review => ReviewPanel,
            Workspace.History => HistoryPanel,
            Workspace.Diagnostics => DiagnosticsPanel,
            _ => LicensingPanel,
        });

        var animation = new Microsoft.UI.Xaml.Media.Animation.DoubleAnimation
        {
            From = 0,
            To = 1,
            Duration = TimeSpan.FromMilliseconds(140),
            EnableDependentAnimation = true,
        };

        var storyboard = new Microsoft.UI.Xaml.Media.Animation.Storyboard();
        storyboard.Children.Add(animation);
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTarget(animation, panel);
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(
            animation, "Opacity");
        storyboard.Begin();
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        // XAML Click handlers must be void; the awaitable work lives in RefreshAsync
        // so callers (e.g. the F5 shortcut) can await it and observe completion/errors.
        await RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        await _shell.RunReadAsync(async () =>
        {
            switch (_shell.Current)
            {
                case Workspace.Tweaks:
                    await _shell.Tweaks.RefreshAsync();
                    break;
                case Workspace.Review:
                    await _shell.Review.PreviewAsync();
                    break;
                case Workspace.History:
                    await _shell.History.ReloadAsync();
                    break;
                case Workspace.Diagnostics:
                    await _shell.Diagnostics.ReloadAsync();
                    break;
                case Workspace.Licensing:
                    await _shell.Licensing.ReloadAsync();
                    break;
            }

            return true;
        });
    }

    private async void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        if (_shell.Current == Workspace.Review)
        {
            await _shell.Review.CancelAsync();
        }
        else
        {
            await _shell.Runner.CancelActiveAsync();
        }
    }

    private async void AddPending_Click(object sender, RoutedEventArgs e)
    {
        var reason = _shell.Tweaks.StageSelection();
        if (reason is not null)
        {
            _shell.StatusText = reason;
        }
        else
        {
            NavList.SelectedIndex = (int)Workspace.Review;
        }
    }

    private async void Preview_Click(object sender, RoutedEventArgs e)
    {
        await _shell.Review.PreviewAsync();
    }

    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (_shell.Review.Changes.Count == 0)
        {
            _shell.StatusText = _shell.Strings["Gui.NothingPending"];
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = _shell.Strings.Get("Gui.Review.Confirm", _shell.Review.Changes.Count),
            Content = _shell.Strings["Gui.Review.Revalidation"],
            PrimaryButtonText = _shell.Strings["Gui.Apply"],
            CloseButtonText = _shell.Strings["Common.Cancel"],
            DefaultButton = ContentDialogButton.Primary,
        };

        _dialogCount++;
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await _shell.Review.ApplyAsync();
            }
        }
        finally
        {
            _dialogCount--;
        }
    }

    private void ClearPending_Click(object sender, RoutedEventArgs e) => _shell.Review.Clear();

    private async void RemovePending_Click(object sender, RoutedEventArgs e)
    {
        if (ReviewList.SelectedItem is ReviewedChange change)
        {
            _shell.Review.Remove(change);
        }
    }

    private void HistoryMode_Changed(object sender, RoutedEventArgs e)
    {
        HistoryList.Visibility = HistoryModeRadio.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        JournalList.Visibility = JournalModeRadio.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
        InterruptedList.Visibility = InterruptedModeRadio.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Restore_Click(object sender, RoutedEventArgs e)
    {
        await _shell.History.RestoreAsync();
    }

    private async void Scan_Click(object sender, RoutedEventArgs e) => await _shell.Diagnostics.ScanAsync();

    private async void Monitor_Click(object sender, RoutedEventArgs e) => await _shell.Diagnostics.MonitorAsync();

    private async void Devices_Click(object sender, RoutedEventArgs e) => await _shell.Diagnostics.DevicesAsync();

    private async void DownloadTool_Click(object sender, RoutedEventArgs e) => await _shell.Licensing.DownloadToolAsync();

    private async void RemoveTool_Click(object sender, RoutedEventArgs e) => await _shell.Licensing.RemoveToolAsync();

    private async void Activate_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = _shell.Strings["Gui.Licensing.Activate"],
            Content = _shell.Strings["Gui.Licensing.Separate"],
            PrimaryButtonText = _shell.Strings["Gui.Licensing.Activate"],
            CloseButtonText = _shell.Strings["Common.Cancel"],
            DefaultButton = ContentDialogButton.Close,
        };

        _dialogCount++;
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                await _shell.Licensing.ActivateAsync();
            }
        }
        finally
        {
            _dialogCount--;
        }
    }

    private async void Slmgr_Click(object sender, RoutedEventArgs e) => await _shell.Licensing.RequestSlmgrAsync();

    /// <summary>
    /// Closing during an operation offers a choice. The backend is never killed out from
    /// under a mutation: the options are to wait, or to cancel the queued work and wait
    /// for the running item to finish at its safe boundary.
    /// </summary>
    private async void OnClosed(object sender, WindowEventArgs args)
    {
        if (_closing)
        {
            return;
        }

        if (_shell.HasMutatingOperation)
        {
            args.Handled = true;

            var dialog = new ContentDialog
            {
                XamlRoot = RootGrid.XamlRoot,
                Title = _shell.Strings["Gui.Close.BusyTitle"],
                Content = _shell.Strings["Gui.Close.BusyBody"],
                PrimaryButtonText = _shell.Strings["Gui.Close.Wait"],
                SecondaryButtonText = _shell.Strings["Gui.Close.Cancel"],
                CloseButtonText = _shell.Strings["Gui.Close.Stay"],
                DefaultButton = ContentDialogButton.Close,
            };

            _dialogCount++;
            ContentDialogResult choice;
            try
            {
                choice = await dialog.ShowAsync();
            }
            finally
            {
                _dialogCount--;
            }

            switch (choice)
            {
                case ContentDialogResult.Primary:
                    _closing = true;
                    await _shell.WaitAndCloseAsync();
                    Close();
                    break;
                case ContentDialogResult.Secondary:
                    _closing = true;
                    await _shell.CancelAndCloseAsync();
                    Close();
                    break;
                default:
                    // Stay: the operation is not abandoned.
                    break;
            }

            return;
        }

        _closing = true;
        await _shell.TryCloseAsync();
    }
}
