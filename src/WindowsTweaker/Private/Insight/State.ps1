# WindowsTweaker - configured state, effective state and recovery ownership.
#
# One Enabled/Disabled flag cannot say all of this at once:
#
#   configured   what is written right now  (Matches / Differs / Mixed / Absent / Unreadable / Unsupported)
#   effective    what Windows is doing with it (Active / Inactive / PendingRestart / PendingSignOut /
#                PendingReboot / Unknown / Unsupported)
#   ownership    who put it there and who can put it back (Unmanaged / Owned / Conflicting / Interrupted)
#
# A successful write and read-back proves *configuration*. It does not prove runtime behaviour,
# performance or that the change took effect: several of these settings are read once by a
# component at startup, and some are advisory. So the effective dimension is only ever reported
# from evidence, and every effective answer carries how it was obtained:
#
#   Observed   a probe actually read the live behaviour (or a Windows-validated observation is
#              recorded for this definition and this build);
#   Inferred   the configuration implies the behaviour through a documented mapping;
#   Unknown    nothing proves it either way - the honest answer, and the default.
#
# Nothing here writes. The probes read the restart markers, the last boot time, process start
# times and the interactive logon session, and none of them changes anything: a marker is
# Windows' own bookkeeping, and clearing one would suppress a restart Windows still owes the user.

$Script:WtConfiguredStates = @('Matches', 'Differs', 'Mixed', 'Absent', 'Unreadable', 'Unsupported')
$Script:WtEffectiveStates = @('Active', 'Inactive', 'PendingRestart', 'PendingSignOut', 'PendingReboot', 'Unknown', 'Unsupported')
$Script:WtOwnershipStates = @('Unmanaged', 'Owned', 'Conflicting', 'Interrupted')
$Script:WtEffectiveEvidenceKinds = @('Observed', 'Inferred', 'Unknown')

# Structured restart evidence. Each marker is read, never written and never removed: a marker is
# Windows' own bookkeeping, and clearing one would suppress a restart Windows still owes the user.
$Script:WtPendingRestartMarkers = @(
    @{
        Id      = 'Cbs.RebootPending'
        Kind    = 'Key'
        Path    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
        Name    = 'RebootPending'
        Boundary = 'Reboot'
    }
    @{
        Id      = 'Cbs.PackagesPending'
        Kind    = 'Key'
        Path    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
        Name    = 'PackagesPending'
        Boundary = 'Reboot'
    }
    @{
        Id      = 'WindowsUpdate.RebootRequired'
        Kind    = 'Key'
        Path    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'
        Name    = 'RebootRequired'
        Boundary = 'Reboot'
    }
    @{
        Id      = 'SessionManager.PendingFileRenameOperations'
        Kind    = 'Value'
        Path    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        Name    = 'PendingFileRenameOperations'
        Boundary = 'Reboot'
    }
    @{
        Id      = 'SessionManager.PendingComputerRenameOperations'
        Kind    = 'Value'
        Path    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        Name    = 'PendingComputerRenameOperations'
        Boundary = 'Reboot'
    }
)

<#
.SYNOPSIS
    Reads the pending-restart markers, keeping missing, empty, non-empty and unreadable apart.
.DESCRIPTION
    Read-only. "Not present", "present but empty" and "cannot be read" are three different facts:
    an empty value is Windows' shape for a marker that has been cleared, a missing key means the
    component has never registered one, and an unreadable key means this session cannot tell - and
    an unreadable probe is never evidence that a restart is or is not pending.
.OUTPUTS
    @{ Markers; Present; Unreadable; Boundary; BoundaryLabel }
#>
function Get-WtPendingRestartInternal
{
    [CmdletBinding()]
    param ()

    $Markers = [System.Collections.Generic.List[object]]::new()
    $Present = 0
    $Unreadable = 0
    $Boundary = 'None'

    # No registry provider means no probe at all: every marker is unreadable, and none of them is
    # reported as missing, because "cannot look" is not "not there".
    $Available = Test-WtRegistryAvailable

    foreach ($Marker in $Script:WtPendingRestartMarkers)
    {
        $State = 'Missing'
        $Detail = ''

        if (-not $Available)
        {
            $State = 'Unreadable'
            $Detail = 'the registry provider is not available on this system'
        }
        elseif ($Marker.Kind -eq 'Key')
        {
            try
            {
                $Exists = Test-WtRegistryKeyRaw -Path "$($Marker.Path)\$($Marker.Name)"
                $State = if ($Exists) { 'NonEmpty' } else { 'Missing' }
                if ($Exists) { $Detail = "$($Marker.Path)\$($Marker.Name) exists" }
            }
            catch
            {
                $State = 'Unreadable'
                $Detail = $_.Exception.Message
            }
        }
        else
        {
            $Value = $null
            try
            {
                $Value = Get-WtRegistryState -Path $Marker.Path -Name $Marker.Name
            }
            catch
            {
                $Value = $null
            }

            if (-not $Value -or -not $Value.Available)
            {
                $State = 'Unreadable'
                $Detail = 'the value could not be read'
            }
            elseif (-not $Value.ValueExists)
            {
                $State = 'Missing'
            }
            else
            {
                $Items = @($Value.Value) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                $State = if ($Items.Count -gt 0) { 'NonEmpty' } else { 'Empty' }
                $Detail = if ($Items.Count -gt 0) { "$($Items.Count) entry(ies) pending" } else { 'present but empty' }
            }
        }

        if ($State -eq 'NonEmpty')
        {
            $Present++
            if ($Boundary -eq 'None') { $Boundary = [string]$Marker.Boundary }
        }
        elseif ($State -eq 'Unreadable')
        {
            $Unreadable++
        }

        $Markers.Add([pscustomobject]@{
                PSTypeName = 'WindowsTweaker.PendingRestartMarker'
                Id         = [string]$Marker.Id
                Kind       = [string]$Marker.Kind
                Path       = [string]$Marker.Path
                Name       = [string]$Marker.Name
                Boundary   = [string]$Marker.Boundary
                Marker     = $State
                Detail     = $Detail
                ReadOnly   = $true
            })
    }

    return @{
        Markers     = @($Markers.ToArray())
        Present     = $Present
        Unreadable  = $Unreadable
        Boundary    = $Boundary
        BoundaryKey = switch ($Boundary)
        {
            'Reboot' { 'Tui.State.PendingReboot' }
            'SignOut' { 'Tui.State.PendingSignOut' }
            default { 'Tui.State.NoPendingRestart' }
        }
    }
}

<#
.SYNOPSIS
    Reads the machine side of one boundary: has the component that reads a setting started since a
    given instant?
.DESCRIPTION
    Strictly read-only, and deliberately separate from the journal: this is the part that talks to
    Windows (the restart markers, the last boot time, the File Explorer process and the interactive
    logon session), so a test can replace it without a registry, a process table or a CIM provider.

    Available is $false when the instant to compare with was not supplied or is not a timestamp,
    or when the machine side could not be read at all; Crossed is then $null, because nothing was
    established, and $null is never "not crossed".
    Two machine-side facts settle the question without any comparison:
      a restart marker is present    the restart that re-reads the setting has not happened yet,
                                     whatever the boot time says, so Crossed is $false. This is
                                     answered before the instant is even parsed, because Windows'
                                     own bookkeeping does not depend on when the change was made;
      File Explorer is not running   no process holds an older value, so Crossed is $false.
    Otherwise the component's last start is compared with the instant: a start after it means the
    component is running with the new value, so the boundary is crossed.
.PARAMETER Boundary
    The boundary whose component is looked for.
.PARAMETER AppliedUtc
    The instant the change was applied, as the journal recorded it - the only thing a start time
    can be compared with. Without it, the probe can still answer the Reboot boundary from a marker,
    and otherwise reads nothing and reports Available = $false.
.PARAMETER Pending
    An already-computed Get-WtPendingRestartInternal result, when the caller has one; the markers
    are read here otherwise. Only the Reboot boundary uses it.
.OUTPUTS
    @{ Available; Crossed; Source; Detail; StartedUtc }
#>
function Read-WtBoundaryProbeInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('Explorer', 'SignOut', 'Reboot')][string]$Boundary,
        [Parameter(Mandatory = $false)][AllowEmptyString()][string]$AppliedUtc,
        [Parameter(Mandatory = $false)][object]$Pending
    )

    $Result = @{ Available = $false; Crossed = $null; Source = ''; Detail = ''; StartedUtc = $null }

    # The restart boundary is decided before any clock is read. Windows' own bookkeeping outranks
    # the clock: a marker that is present means the restart this setting waits for has not happened,
    # even if the machine booted since - and it answers without an apply time, which is what lets a
    # caller ask about a configuration this tool never wrote.
    if ($Boundary -eq 'Reboot')
    {
        $Markers = if ($Pending) { $Pending } else { Get-WtPendingRestartInternal }
        if ([int]$Markers.Present -gt 0)
        {
            $Result.Available = $true
            $Result.Crossed = $false
            $Result.Source = 'restart marker'
            $Result.Detail = 'Windows reports a restart pending, so the restart that re-reads this setting has not happened yet.'
            return $Result
        }
    }

    $Since = [datetime]::MinValue
    $Readable = $false

    # The journal records UTC ISO instants, but one read back through the store arrives as text the
    # store rendered with the session's culture, without its UTC designator. It is therefore parsed
    # with both that culture and the invariant one, and a value that comes back with no kind is
    # taken as UTC: it was written as UTC, and treating it as local would shift every comparison by
    # the machine's UTC offset.
    foreach ($Culture in @([System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.CultureInfo]::InvariantCulture))
    {
        if ([datetime]::TryParse($AppliedUtc, $Culture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$Since))
        {
            $Readable = $true
            break
        }
    }

    if (-not $Readable)
    {
        $Result.Detail = "The recorded apply time '$AppliedUtc' could not be read as a timestamp, so this boundary was not compared."
        return $Result
    }

    $Since = if ($Since.Kind -eq [System.DateTimeKind]::Unspecified)
    {
        [datetime]::SpecifyKind($Since, [System.DateTimeKind]::Utc)
    }
    else
    {
        $Since.ToUniversalTime()
    }

    $Started = $null

    switch ($Boundary)
    {
        'Reboot'
        {
            $Result.Source = 'last boot time'
            try
            {
                $Started = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
            }
            catch
            {
                $Started = $null
                $Result.Detail = if ($IsWindows)
                {
                    "The last boot time could not be read ($($_.Exception.Message))."
                }
                else
                {
                    'The last boot time can only be read on Windows.'
                }
            }
        }
        'Explorer'
        {
            $Result.Source = 'File Explorer process'

            try
            {
                # No process at all is a result, not a failure: nothing is holding an older value,
                # and File Explorer will read the new one when it starts.
                $Processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)
                if ($Processes.Count -eq 0)
                {
                    $Result.Available = $true
                    $Result.Crossed = $false
                    $Result.Detail = 'File Explorer is not running, so it will read this value when it next starts.'
                    return $Result
                }

                $Started = ($Processes | Sort-Object -Property CreationDate -Descending | Select-Object -First 1).CreationDate
            }
            catch
            {
                $Started = $null
                $Result.Detail = if ($IsWindows)
                {
                    "The File Explorer start time could not be read ($($_.Exception.Message))."
                }
                else
                {
                    'The File Explorer process can only be read on Windows.'
                }
            }
        }
        'SignOut'
        {
            $Result.Source = 'interactive logon session'

            try
            {
                # The newest interactive logon session is the closest read-only approximation of
                # the session this process belongs to; Windows exposes no "current session start"
                # property without asking the session itself.
                $Session = @(Get-CimInstance -ClassName Win32_LogonSession -ErrorAction Stop |
                    Where-Object { [int]$_.LogonType -in 2, 10, 11 } |
                    Sort-Object -Property StartTime -Descending |
                    Select-Object -First 1)

                if ($Session.Count -gt 0) { $Started = $Session[0].StartTime }
                else { $Result.Detail = 'Windows reports no interactive logon session.' }
            }
            catch
            {
                $Started = $null
                $Result.Detail = if ($IsWindows)
                {
                    "The start of the interactive session could not be read ($($_.Exception.Message))."
                }
                else
                {
                    'The interactive logon session can only be read on Windows.'
                }
            }
        }
    }

    if ($null -eq $Started)
    {
        if (-not $Result.Detail)
        {
            $Result.Detail = 'The start that would show whether the component has re-read the setting could not be read.'
        }

        return $Result
    }

    try
    {
        $Started = ([datetime]$Started).ToUniversalTime()
    }
    catch
    {
        $Result.Detail = 'What was read for the start of the component was not a timestamp.'
        return $Result
    }

    $Result.Available = $true
    $Result.StartedUtc = $Started.ToString('o')
    $Result.Crossed = ($Started -gt $Since)
    $Result.Detail = if ($Result.Crossed)
    {
        "The change was applied at $($Since.ToString('o')) and the $Boundary boundary was reached at $($Result.StartedUtc), so the component is already running with the new value."
    }
    else
    {
        "The change was applied at $($Since.ToString('o')) and the $Boundary boundary has not been reached since (last reached $($Result.StartedUtc)), so the component is still running with the previous value."
    }

    return $Result
}

<#
.SYNOPSIS
    Derives the configured dimension from the live targets of one state.
.DESCRIPTION
    Read-only, and provider-backed: it re-reads every target the state would write and compares it
    with the intended value, so "Mixed" is a measured fact rather than a guess. A state with no
    readable target reports Unreadable, never Matches; so does a state whose preview cannot be
    built, because being unable to read a state is not being unsupported on this system.
    A target that cannot be read is neither a match nor a difference: it is counted in the detail
    and leaves the answer to the targets that were read, so "Mixed" needs at least one readable
    target holding the intended value.
.PARAMETER Tweak
    The tweak object.
.PARAMETER State
    The state to compare against (defaults to the tweak's default state).
.PARAMETER Arguments
    Tweak arguments, when the tweak needs them.
.OUTPUTS
    @{ Configured; Detail; Targets; Readable; Matching }
#>
function Get-WtConfiguredStateInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Tweak,
        [Parameter(Mandatory = $false)][string]$State,
        [Parameter(Mandatory = $false)][hashtable]$Arguments
    )

    if (-not $State) { $State = [string]$Tweak.DefaultState }

    # Unreadable until the targets say otherwise: a preview that cannot be built is a read that
    # failed, not a state this system does not support. Reporting Unsupported here would tell
    # every consumer that the platform is the obstacle, which is a claim nothing has proved.
    $Result = @{ Configured = 'Unreadable'; Detail = ''; Targets = @(); Readable = 0; Matching = 0 }

    $Preview = $null
    try
    {
        $Preview = Get-WtChangePreviewInternal -Id $Tweak.Id -State $State -Arguments $Arguments
    }
    catch
    {
        $Result.Detail = $_.Exception.Message
        return $Result
    }

    if (-not $Preview)
    {
        $Result.Detail = 'No preview is available for this state.'
        return $Result
    }

    $Targets = @($Preview.Targets)
    $Result.Targets = $Targets

    if ($Targets.Count -eq 0)
    {
        # Nothing to compare: the state performs no readable write (a scripted tweak, or a state
        # whose operations are not value writes). Configuration cannot be claimed.
        $Result.Configured = if ($Preview.DetectedState -eq 'Unsupported') { 'Unsupported' } else { 'Absent' }
        $Result.Detail = 'This state has no comparable target.'
        return $Result
    }

    foreach ($Target in $Targets)
    {
        $Current = $Target.Current
        if (-not $Current -or $Current.ValueKind -in 'Unreadable', 'Unsupported')
        {
            continue
        }

        $Result.Readable++

        $Intended = $Target.Intended
        $IsMatch = $false
        switch ([string]$Intended.Kind)
        {
            # 'Zero' and 'Empty' are values, not absences: the preview keeps them apart so that a
            # stored 0 can be told from a missing value, and a comparison that only accepted
            # 'Value' would report every zero as a mismatch.
            'Set' { $IsMatch = ($Current.ValueKind -in 'Value', 'Zero', 'Empty') -and (Test-WtValueEqual -Left $Current.Value -Right @($Intended.Value)) }
            'Remove' { $IsMatch = ($Current.ValueKind -eq 'Absent') }
            default { $IsMatch = $false }
        }

        if ($IsMatch) { $Result.Matching++ }
    }

    if ($Result.Readable -eq 0)
    {
        $Result.Configured = 'Unreadable'
        $Result.Detail = 'None of the targets could be read, so the configuration is unknown.'
        return $Result
    }

    if ($Result.Matching -eq $Result.Readable)
    {
        $Result.Configured = 'Matches'
        $Result.Detail = "All $($Result.Readable) target(s) hold the intended value."
        return $Result
    }

    # Targets that could not be read are neither matches nor differences: they are reported, and
    # they are never allowed to turn "nothing matches" into "some targets match".
    $Unreadable = $Targets.Count - $Result.Readable
    $UnreadableNote = if ($Unreadable -gt 0)
    {
        " $Unreadable of $($Targets.Count) target(s) could not be read and is not part of this answer."
    }
    else
    {
        ''
    }

    if ($Result.Matching -eq 0)
    {
        # Nothing readable holds the intended value, so the answer is Absent or Differs - never
        # Mixed, which claims that some targets do. The decision uses the detection of the
        # readable targets, exactly as it does when every target was readable.
        $Detected = [string]$Preview.DetectedState
        if ($Detected -in '', 'Unknown')
        {
            $Result.Configured = 'Absent'
            $Result.Detail = 'No target holds the intended value and the detection matches no declared state.' + $UnreadableNote
            return $Result
        }

        if ($Detected -eq $State)
        {
            # Detection reads one value while a state can write several: agreement on the detected
            # value is not agreement on every target.
            $Result.Configured = 'Differs'
            $Result.Detail = "Detection reports '$Detected', but $($Result.Readable - $Result.Matching) target(s) do not hold what '$State' would write." + $UnreadableNote
            return $Result
        }

        $Result.Configured = 'Differs'
        $Result.Detail = "The live configuration matches '$Detected', not '$State'." + $UnreadableNote
        return $Result
    }

    $Result.Configured = 'Mixed'
    $Result.Detail = "$($Result.Matching) of $($Result.Readable) readable target(s) hold the intended value." + $UnreadableNote
    return $Result
}

<#
.SYNOPSIS
    Gathers the evidence for whether one boundary has been crossed by one tweak's configuration.
.DESCRIPTION
    Read-only. "Crossed" answers one question: has the component that reads this setting had the
    chance to read the value that is configured now?
      $true   it started after the change was applied, so it is running with the new value;
      $false  it has not started since, so the change is still waiting for that boundary;
      $null   the evidence that would tell the two apart could not be read.
    $null is "no evidence", and it is never reported as "not crossed".

    The journal decides which change is being asked about: AppliedUtc is the timestamp of this
    tweak's newest recorded apply. When no apply is recorded at all, the configuration pre-dates
    this tool - nothing this tool wrote is involved, so whatever is configured is what the
    component read when it started. That is pre-existing configuration, and Crossed is $true. The
    one exception is the Reboot boundary with a restart marker present: Windows' own bookkeeping
    says the restart is still owed, so that boundary has not been reached and Crossed is $false.

    The machine side (markers, boot time, process and session start times) is read by
    Read-WtBoundaryProbeInternal, and only for the boundaries a component actually reads at.
.PARAMETER Boundary
    The boundary to gather evidence for.
.PARAMETER TweakId
    The tweak whose last recorded apply is the change in question. Without it no journal record
    can be attributed to the change, and it is treated as pre-existing configuration.
.PARAMETER Pending
    An already-computed Get-WtPendingRestartInternal result, when the caller has one, so the
    markers are not read twice. Only the Reboot boundary uses it.
.OUTPUTS
    @{ Boundary; Crossed; Source; Detail; AppliedUtc }
#>
function Get-WtBoundaryEvidenceInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('None', 'Explorer', 'SignOut', 'Reboot')][string]$Boundary,
        [Parameter(Mandatory = $false)][string]$TweakId,
        [Parameter(Mandatory = $false)][object]$Pending
    )

    $Result = @{ Boundary = $Boundary; Crossed = $null; Source = ''; Detail = ''; AppliedUtc = $null }

    if ($TweakId)
    {
        # The newest apply this tool recorded for the tweak. updatedUtc is the last stage the entry
        # was persisted at - the closest recorded instant to when the value became readable, and
        # never earlier than the writes themselves; the entry's timestamp is when the operation was
        # created, which is before any of its writes. The value is carried as the journal holds it:
        # the probe is what parses it, because the store renders a recorded UTC instant as text.
        $Entry = @(Get-WtJournalEntryInternal -TweakId $TweakId -All |
            Where-Object { -not $_.dryRun -and -not $_.rolledBack -and $_.outcome -in 'succeeded', 'partial' } |
            Select-Object -First 1)

        if ($Entry.Count -gt 0)
        {
            $Stamp = if ($Entry[0].updatedUtc) { [string]$Entry[0].updatedUtc } else { [string]$Entry[0].timestamp }
            if ($Stamp) { $Result.AppliedUtc = $Stamp }
        }
    }

    if ($Boundary -eq 'None')
    {
        # No component defers this setting: what Windows holds is what was written, so there is no
        # boundary left to cross. The journal is not consulted for the answer, only for AppliedUtc.
        $Result.Crossed = $true
        $Result.Source = 'no boundary'
        $Result.Detail = 'This change is not read at a boundary, so there is nothing to wait for.'
        return $Result
    }

    if (-not $Result.AppliedUtc)
    {
        # Pre-existing configuration: nothing this tool wrote is involved, so whatever is configured
        # is what the component read when it started, and the boundary counts as crossed.
        # A restart marker is the one machine fact that outranks that inference, because it is
        # Windows' own evidence: the restart is still owed, so the boundary the setting waits for
        # has not been reached - and the probe answers that without an apply time to compare with.
        if ($Boundary -eq 'Reboot')
        {
            $Marker = Read-WtBoundaryProbeInternal -Boundary 'Reboot' -AppliedUtc '' -Pending $Pending
            if ($Marker.Available -and $Marker.Crossed -eq $false)
            {
                $Result.Crossed = $false
                $Result.Source = [string]$Marker.Source
                $Result.Detail = [string]$Marker.Detail
                return $Result
            }
        }

        $Result.Crossed = $true
        $Result.Source = 'pre-existing configuration'
        $Result.Detail = 'No apply of this tweak is recorded, so this configuration pre-dates this tool and the component that reads it has already read it.'
        return $Result
    }

    $Probe = Read-WtBoundaryProbeInternal -Boundary $Boundary -AppliedUtc $Result.AppliedUtc -Pending $Pending

    $Result.Source = [string]$Probe.Source
    $Result.Detail = [string]$Probe.Detail

    if ($Probe.Available)
    {
        $Result.Crossed = [bool]$Probe.Crossed
    }

    return $Result
}

<#
.SYNOPSIS
    Returns the effective dimension for one tweak, with the evidence it rests on.
.DESCRIPTION
    A definition may declare, in its catalog metadata, how its configuration relates to observed
    behaviour ('effective' block: evidence, boundary and a state -> behaviour map). Without that
    declaration the answer is Unknown - configuration is not behaviour, and this engine will not
    pretend otherwise.
    The boundary is then applied, through Get-WtBoundaryEvidenceInternal:
      crossed       the component that reads this setting has had the value since it was applied,
                    so the declared mapping describes what is live;
      not crossed   it has not, so the change is reported as PendingReboot / PendingSignOut /
                    PendingRestart - the only case in which a pending state is claimed at all;
      no evidence   the boundary could not be read. The answer is then Unknown: with no evidence
                    the change is neither presented as applied (the mapping assumes the value was
                    read) nor as pending (that would claim the boundary was not crossed, which is
                    exactly what is unknown).
    A pending state is therefore only ever reported when the boundary is provably not crossed.
    That is the stricter of the two defensible rules on purpose: configuration is not behaviour,
    and "no evidence" is not "not crossed".
.PARAMETER Tweak
    The tweak object.
.PARAMETER Configured
    The configured dimension for the state in question.
.PARAMETER Pending
    Result of Get-WtPendingRestartInternal, when the caller already has one, so the restart markers
    are not read twice. It is evidence about the restart boundary only.
.OUTPUTS
    @{ Effective; Evidence; Reason; Boundary; BoundaryCrossed; BoundarySource }
    BoundaryCrossed is the verdict the boundary probe gave ($true crossed, $false not crossed,
    $null no evidence); BoundarySource names what was read for it ('restart marker', 'last boot
    time', 'File Explorer process', 'interactive logon session', 'pre-existing configuration',
    'no boundary'). Both are $null/'' when no boundary probe was consulted for this answer.
#>
function Get-WtEffectiveStateInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Tweak,
        [Parameter(Mandatory = $false)][string]$Configured = 'Unsupported',
        [Parameter(Mandatory = $false)][object]$Pending,
        [Parameter(Mandatory = $false)][string]$State
    )

    if (-not $State) { $State = [string]$Tweak.DefaultState }

    $Result = @{ Effective = 'Unknown'; Evidence = 'Unknown'; Reason = ''; Boundary = 'None'; BoundaryCrossed = $null; BoundarySource = '' }

    if ($Configured -eq 'Unsupported')
    {
        $Result.Effective = 'Unsupported'
        $Result.Reason = 'The change cannot run on this system.'
        return $Result
    }

    $Declared = $null
    if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionEffective') { $Declared = $Tweak.DefinitionEffective }
    $Source = if (@($Tweak.PSObject.Properties.Name) -contains 'DefinitionSource') { [string]$Tweak.DefinitionSource } else { 'BuiltIn' }

    $Evidence = 'Unknown'
    $Mapping = ''
    $Boundary = [string]$Tweak.Restart

    if ($Declared)
    {
        $Claimed = [string]$Declared.Evidence
        $Evidence = if ($Source -eq 'Pack' -and $Claimed -eq 'Observed') { 'Inferred' } else { $Claimed }
        if ($Evidence -notin $Script:WtEffectiveEvidenceKinds) { $Evidence = 'Unknown' }

        if ($Declared.Boundary) { $Boundary = [string]$Declared.Boundary }
        if ($Declared.Map -and $Declared.Map.Contains($State)) { $Mapping = [string]$Declared.Map[$State] }
        if ($Source -eq 'Pack') { $Evidence = if ($Evidence -eq 'Unknown') { 'Unknown' } else { 'Inferred' } }
    }

    $Result.Evidence = $Evidence
    $Result.Boundary = $Boundary

    if ($Configured -ne 'Matches')
    {
        $Result.Effective = 'Unknown'
        $Result.Reason = if ($Configured -eq 'Unreadable')
        {
            # Nothing was read, so nothing can be said about what Windows does with it. This is not
            # "the configuration is not in place": that would be a claim about the system.
            'The configuration could not be read, so no effective behaviour is claimed.'
        }
        else
        {
            'The configuration is not in place, so no effective behaviour is claimed.'
        }

        return $Result
    }

    if ($Boundary -in 'Reboot', 'SignOut', 'Explorer')
    {
        $BoundaryEvidence = Get-WtBoundaryEvidenceInternal -Boundary $Boundary -TweakId ([string]$Tweak.Id) -Pending $Pending
        $Result.BoundaryCrossed = $BoundaryEvidence.Crossed
        $Result.BoundarySource = [string]$BoundaryEvidence.Source

        if ($BoundaryEvidence.Crossed -eq $false)
        {
            # The component has not read the new value yet, so the previous behaviour - or none -
            # is what is live, and the change is waiting for that boundary.
            $Result.Effective = switch ($Boundary)
            {
                'Reboot' { 'PendingReboot' }
                'SignOut' { 'PendingSignOut' }
                default { 'PendingRestart' }
            }
            $Result.Reason = "This setting is read at the $Boundary boundary and that boundary has not been crossed. $($BoundaryEvidence.Detail)"
            return $Result
        }

        if ($null -eq $BoundaryEvidence.Crossed)
        {
            # No evidence about the boundary is not evidence that it was not crossed, and the
            # mapping is not applied either: the mapping describes what the component does once it
            # has read the value, and whether it has is exactly what could not be established.
            $Result.Effective = 'Unknown'
            $Result.Reason = "Whether the $Boundary boundary has been crossed could not be established. $($BoundaryEvidence.Detail)"
            return $Result
        }
    }

    if ($Mapping -in $Script:WtEffectiveStates)
    {
        $Result.Effective = $Mapping
        $Result.Reason = if ($Evidence -eq 'Observed')
        {
            'Reported from an observation recorded for this definition.'
        }
        else
        {
            'Inferred from the configuration through the mapping this definition documents; the runtime behaviour was not probed.'
        }

        return $Result
    }

    $Result.Effective = 'Unknown'
    $Result.Reason = 'The configuration is in place, but nothing here proves the runtime behaviour.'
    return $Result
}

<#
.SYNOPSIS
    Returns who owns the current configuration of one tweak.
.DESCRIPTION
    Read-only. Ownership is asked of the journal and of the live targets, not assumed:
      Interrupted  this tool started a change and never reported the last stage;
      Conflicting  an organization policy governs the setting, or a recorded target changed
                   outside this tool since it was applied;
      Owned        this tool applied the setting and it has not been rolled back;
      Unmanaged    none of the above - pre-existing or user/manufacturer configuration.
.OUTPUTS
    @{ Ownership; Detail; HistoryId; Drifted }
#>
function Get-WtOwnershipInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Tweak)

    $Result = @{ Ownership = 'Unmanaged'; Detail = ''; HistoryId = ''; Drifted = @() }

    $Policy = @()
    foreach ($Entry in @($Tweak.ManagedPolicy))
    {
        $PolicyState = Get-WtRegistryState -Path $Entry.Path -Name $Entry.Name
        if ($PolicyState.Available -and $PolicyState.ValueExists) { $Policy += "$($Entry.Path)\$($Entry.Name)" }
    }

    if ($Policy.Count -gt 0)
    {
        $Result.Ownership = 'Conflicting'
        $Result.Detail = "An organization policy governs this setting: $(@($Policy) -join ', ')."
        return $Result
    }

    $Interrupted = @(Get-WtInterruptedOperationInternal | Where-Object { $_.TweakId -eq $Tweak.Id })
    if ($Interrupted.Count -gt 0)
    {
        $Result.Ownership = 'Interrupted'
        $Result.HistoryId = [string]$Interrupted[0].OperationId
        $Result.Detail = "An operation was interrupted at stage '$($Interrupted[0].Stage)'; the captured state is available."
        return $Result
    }

    $Entry = @(Get-WtJournalEntryInternal -TweakId $Tweak.Id -All |
        Where-Object { -not $_.rolledBack -and -not $_.dryRun -and $_.outcome -in 'succeeded', 'partial' } |
        Select-Object -Last 1)

    if ($Entry.Count -eq 0)
    {
        return $Result
    }

    $Result.HistoryId = [string]$Entry[0].operationId
    $Drift = @()
    try
    {
        $Drift = @(Get-WtDriftInternal -TweakId $Tweak.Id -OnlyDrifted)
    }
    catch
    {
        $Drift = @()
    }

    if ($Drift.Count -gt 0)
    {
        $Result.Ownership = 'Conflicting'
        $Result.Drifted = $Drift
        $Result.Detail = 'This tool applied this setting, and at least one target has changed since.'
        return $Result
    }

    $Result.Ownership = 'Owned'
    $Result.Detail = 'Applied by this tool; the captured state is still available.'
    return $Result
}

<#
.SYNOPSIS
    Returns all three dimensions for one tweak in a single read-only pass.
.OUTPUTS
    @{ Configured; ConfiguredDetail; Effective; EffectiveEvidence; EffectiveReason; Ownership;
       OwnershipDetail; Pending; HistoryId; Drifted; Boundary; BoundaryCrossed; BoundarySource }
    BoundaryCrossed/BoundarySource come from the effective dimension: the crossing verdict and what
    was read for it, or $null/'' when no boundary probe was consulted.
#>
function Get-WtStateDimensionsInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Tweak,
        [Parameter(Mandatory = $false)][string]$State,
        [Parameter(Mandatory = $false)][hashtable]$Arguments,
        [Parameter(Mandatory = $false)][object]$Pending
    )

    if (-not $State) { $State = [string]$Tweak.DefaultState }
    if (-not $Pending) { $Pending = Get-WtPendingRestartInternal }

    $Configured = Get-WtConfiguredStateInternal -Tweak $Tweak -State $State -Arguments $Arguments
    $Effective = Get-WtEffectiveStateInternal -Tweak $Tweak -Configured $Configured.Configured -Pending $Pending -State $State
    $Ownership = Get-WtOwnershipInternal -Tweak $Tweak

    return @{
        Configured       = $Configured.Configured
        ConfiguredDetail = $Configured.Detail
        Effective        = $Effective.Effective
        EffectiveEvidence = $Effective.Evidence
        EffectiveReason  = $Effective.Reason
        Ownership        = $Ownership.Ownership
        OwnershipDetail  = $Ownership.Detail
        HistoryId        = $Ownership.HistoryId
        Drifted          = @($Ownership.Drifted)
        Pending          = $Pending
        Boundary         = $Effective.Boundary
        BoundaryCrossed  = $Effective.BoundaryCrossed
        BoundarySource   = $Effective.BoundarySource
    }
}
