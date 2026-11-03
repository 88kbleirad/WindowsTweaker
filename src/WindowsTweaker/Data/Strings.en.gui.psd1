# WindowsTweaker - English strings for the native WinUI frontend (part file).
#
# The WinUI interface never keeps its own copy of a translation: every label is looked up
# in this table (merged with the other parts and served to the client through the
# `strings.get` operation). Keys that exist only for the window chrome live here; anything
# the terminal interface already names is reused from Strings.en.psd1.
#
# Read with Import-PowerShellDataFile, so it must stay a single hashtable literal.
@{
    # Window chrome and navigation.
    'Gui.Nav.Overview'        = 'Overview'
    'Gui.Nav.Tweaks'          = 'Tweaks'
    'Gui.Nav.Review'          = 'Review'
    'Gui.Nav.History'         = 'History'
    'Gui.Nav.Diagnostics'     = 'Diagnostics'
    'Gui.Nav.Licensing'       = 'Licensing'
    'Gui.Header.Environment'  = 'Environment'
    'Gui.Header.Backend'      = 'Backend'
    'Gui.Header.Language'     = 'Language'
    'Gui.Header.ReducedMotion' = 'Reduce motion'
    'Gui.Details'             = 'Details'
    'Gui.Actions'             = 'Actions'
    'Gui.Status'              = 'Status'
    'Gui.Ready'               = 'Ready'
    'Gui.Starting'            = 'Starting backend...'
    'Gui.BackendDown'         = 'The backend is not running.'
    'Gui.BackendRestart'      = 'Restart backend'

    # Column headers.
    'Gui.Column.Tweak'        = 'Tweak'
    'Gui.Column.Category'     = 'Category'
    'Gui.Column.State'        = 'State'
    'Gui.Tweaks.OnlySupported' = 'only ones this host can run'
    'Gui.Tweaks.RowCount'     = '{0} rows'
    'Gui.Column.Target'       = 'Target'
    'Gui.Column.Risk'         = 'Risk'
    'Gui.Column.Scope'        = 'Scope'
    'Gui.Column.Result'       = 'Result'
    'Gui.Column.Outcome'      = 'Outcome'
    'Gui.Column.Time'         = 'Time'
    'Gui.Column.Message'      = 'Message'
    'Gui.Column.Value'        = 'Value'
    'Gui.Column.Operation'    = 'Operation'
    'Gui.Column.Source'       = 'Source'

    # Actions.
    'Gui.Action.Preview'      = 'Preview'
    'Gui.Action.AddPending'   = 'Add to review'
    'Gui.Action.RemovePending' = 'Remove from review'
    'Gui.Action.ClearPending' = 'Clear review'
    'Gui.Action.Apply'        = 'Apply reviewed changes'
    'Gui.Action.ApplyDryRun'  = 'Preview (dry run)'
    'Gui.Action.Restore'      = 'Restore this change'
    'Gui.Action.Export'       = 'Export'
    'Gui.Action.Copy'         = 'Copy'
    'Gui.Action.OpenLogs'     = 'Open log folder'
    'Gui.Action.Cancel'       = 'Cancel operation'
    'Gui.Action.Quit'         = 'Quit'
    'Gui.Action.Refresh'      = 'Refresh'
    'Gui.Action.Inspect'      = 'Inspect'

    # Review workflow.
    'Gui.Review.Title'        = 'Reviewed changes'
    'Gui.Review.Empty'        = 'Nothing reviewed yet. Pick a tweak and add it here.'
    'Gui.Review.Confirm'      = 'Apply {0} reviewed change(s)?'
    'Gui.Review.Dependency'   = 'Dependencies and conflicts are shown before anything runs.'
    'Gui.Review.DryRunNotice' = 'Dry run: every operation is reported and nothing is written.'
    'Gui.Review.Revalidation' = 'The reviewed state is re-checked right before the change.'

    # Operation and result views.
    'Gui.Busy.Title'          = 'Operation in progress'
    'Gui.Busy.Item'           = 'Item {0} of {1}'
    'Gui.Result.Title'        = 'Result'
    'Gui.Result.Verified'     = 'Verified by reading the value back'
    'Gui.Result.Unverified'   = 'Recorded as unverifiable (no read-back reader for this target)'
    'Gui.Result.Compensated'  = 'Partial failure: the already-changed targets were put back'
    'Gui.Result.Journal'      = 'Journal persisted: {0}'
    'Gui.Result.Unchanged'    = 'Already in the requested state'

    # Closing during an operation.
    'Gui.Close.BusyTitle'     = 'An operation is still running'
    'Gui.Close.BusyBody'      = 'A change is being applied. Leaving now would abandon it before its safe boundary.'
    'Gui.Close.Wait'          = 'Wait for it to finish'
    'Gui.Close.Cancel'        = 'Cancel the queued work and wait'
    'Gui.Close.Stay'          = 'Stay'

    # Overview.
    'Gui.Overview.Environment' = 'Environment'
    'Gui.Overview.Catalog'    = 'Catalog'
    'Gui.Overview.Tweaks'     = 'Tweaks'
    'Gui.Overview.Interrupted' = 'Interrupted operations'
    'Gui.Overview.Drift'      = 'Changed since applied'
    'Gui.Overview.Pending'    = 'Reviewed changes'
    'Gui.Overview.Packs'      = 'Packs'
    'Gui.Overview.None'       = 'none'

    # Diagnostics.
    'Gui.Diagnostics.Report'  = 'Diagnostics report'
    'Gui.Diagnostics.Scan'    = 'Directory scan'
    'Gui.Diagnostics.ScanPath' = 'Directory to scan'
    'Gui.Diagnostics.Monitor' = 'Monitoring cycle'
    'Gui.Diagnostics.MonitorRun' = 'Run one cycle (read-only)'
    'Gui.Diagnostics.LogPath' = 'Log file'
    'Gui.Diagnostics.StatePath' = 'Journal file'
    'Gui.Diagnostics.Privacy' = 'Privacy activity'
    'Gui.Diagnostics.Devices' = 'Device inventory'
    'Gui.Diagnostics.Power'   = 'Power settings'
    'Gui.Diagnostics.Quarantine' = 'Quarantine'
    'Gui.Diagnostics.SetupPlans' = 'Setup plans'
    'Gui.Diagnostics.Unavailable' = 'Not available on this host'

    # Licensing and the external tool.
    'Gui.Licensing.Status'    = 'Licensing status'
    'Gui.Licensing.Edition'   = 'Installed edition'
    'Gui.Licensing.Method'    = 'Activation method'
    'Gui.Licensing.NoMethod'  = 'Nothing selected'
    'Gui.Licensing.Tool'      = 'External tool'
    'Gui.Licensing.Activate'  = 'Activate Windows (external tool)'
    'Gui.Licensing.Download'  = 'Download and verify the tool'
    'Gui.Licensing.Remove'    = 'Remove the downloaded tool'
    'Gui.Licensing.Slmgr'     = 'Request activation with the installed licence (slmgr /ato)'
    'Gui.Licensing.Separate'  = 'This is an external tool: it writes no journal records and cannot be rolled back here.'
    'Gui.Licensing.Duration'  = 'Duration: {0}'

    # Errors and empty states.
    'Gui.Error.BackendExited' = 'The backend process ended unexpectedly (exit code {0}).'
    'Gui.Error.BackendTimeout' = 'The backend did not answer within {0} ms.'
    'Gui.Error.BackendProtocol' = 'The backend sent a frame this client cannot use: {0}'
    'Gui.Error.ProtocolMismatch' = 'The backend speaks protocol {0}; this client needs {1}.'
    'Gui.Error.RequiresElevation' = 'This action needs an elevated backend session, and the current one is not elevated.'
    'Gui.Header.Elevate'      = 'Elevate'
    'Gui.Header.ElevateHint'  = 'Relaunch this app elevated (UAC prompt) and restart the backend session'
    'Gui.Error.BusyMutating'  = 'Cannot elevate while an operation is running. Wait for it to finish first.'
    'Gui.Error.ElevationDeclined' = 'The elevation prompt was declined; nothing was started and this session is unchanged.'
    'Gui.Error.ElevationFailed' = 'The elevated copy could not be started.'
    'Gui.Footer.Hint'         = 'F5 refresh · Ctrl+F search · Esc close dialogs · Tab/arrows move'
    'Gui.Error.NoSelection'   = 'Select a row first.'
    'Gui.Error.EmptySearch'   = 'No tweak matches this search.'
    'Gui.Error.LoadFailed'    = 'The request failed: {0}'

    # Startup / load states and the overview's environment facts.
    'Gui.Action.Retry'        = 'Retry'
    'Gui.Overview.Os'         = 'OS'
    'Gui.Overview.PowerShell' = 'PowerShell'
    'Gui.Overview.Privilege'  = 'Privilege'
    'Gui.Overview.Engine'     = 'Engine'
    'Gui.Overview.Admin'      = 'elevated'
    'Gui.Overview.Standard'   = 'standard user'
    'Gui.Overview.NotLoaded'  = 'not loaded'
    'Gui.Overview.Loading'    = 'Loading...'
    'Gui.Overview.Empty'      = 'The catalog is empty.'
    'Gui.Overview.CatalogCount' = '{0} tweaks | {1} categories'
    'Gui.Tweaks.Loading'      = 'Loading tweaks...'
    'Gui.Tweaks.Empty'        = 'No tweak matches the current filter.'
    'Gui.Error.LocalizationFailed' = 'The interface text did not load; the engine payload may be incomplete.'
    'Gui.Error.BackendStopFailed' = 'The backend could not be stopped cleanly; nothing was elevated.'
    'Gui.Error.InitFailed'    = 'Startup failed'
}
