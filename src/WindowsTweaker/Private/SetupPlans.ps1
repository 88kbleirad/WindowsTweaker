# WindowsTweaker - checkpointed setup workflows.
#
# A setup plan is a versioned, reviewed list of steps, where every step is a catalog tweak
# id plus a state (and optional arguments) - never a command string, a script path or an
# arbitrary action. Importing a plan applies nothing; applying one goes through the exact
# same reviewed path as any selection (preview, capability-loss summary, journal,
# verification). Checkpoints are persisted *before* a reboot, and a resume registration is
# a separate, explicit opt-in that is bound to the plan identity, the plan hash, the app
# version, the user identity and the trusted execution path.
#
# Rules implemented here:
#   * no step is applied on import; import only validates and stores;
#   * steps that depend on a failed prerequisite are never executed;
#   * a step whose previous result is uncertain is never retried automatically;
#   * resume runs only when the registration's plan hash, user, app version and execution
#     path still match (tampering is refused, and the plan is not silently re-created);
#   * reboot/retry counts are bounded; exceeding the bound removes the registration and
#     reports the state, it never loops;
#   * cancellation and removal of the resume registration are first-class operations.

$Script:WtSetupPlanSchemaVersion = 1
$Script:WtSetupMaxReboots = 3
$Script:WtSetupMaxSteps = 200

<#
.SYNOPSIS
    Returns the setup plans directory.
#>
function Get-WtSetupPlanDirectory
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $StatePath = Get-WtStatePath
    $StateDir = Split-Path -Path $StatePath -Parent
    $Dir = Join-Path $StateDir 'plans'
    if ($env:WT_SETUP_PLANS_DIR)
    {
        $Dir = [System.IO.Path]::GetFullPath($env:WT_SETUP_PLANS_DIR)
    }
    return $Dir
}

<#
.SYNOPSIS
    Returns the resume registration path.
#>
function Get-WtSetupResumePath
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $StatePath = Get-WtStatePath
    $StateDir = Split-Path -Path $StatePath -Parent
    return (Join-Path $StateDir 'resume.json')
}

<#
.SYNOPSIS
    Produces a stable hash of the plan content (excluding mutable bookkeeping).
#>
function Get-WtSetupPlanHash
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $true)][object]$Plan)

    $Payload = [ordered]@{
        planId = [string]$Plan.planId
        appVersion = [string]$Plan.appVersion
        steps = @($Plan.steps)
    }

    $Json = ConvertTo-WtJson -InputObject $Payload -Depth 16
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try
    {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        return ([System.BitConverter]::ToString($Sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally
    {
        $Sha.Dispose()
    }
}

<#
.SYNOPSIS
    Validates a plan document (steps are tweak ids/states only).
#>
function Test-WtSetupPlanDocument
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([Parameter(Mandatory = $true)][object]$Document)

    $Errors = [System.Collections.Generic.List[string]]::new()

    $Get = {
        param ([string]$Name)

        if ($Document -is [System.Collections.IDictionary])
        {
            if ($Document.Contains($Name)) { return $Document[$Name] }
            return $null
        }
        if (@($Document.PSObject.Properties.Name) -contains $Name) { return $Document.$Name }
        return $null
    }

    $SchemaVersion = [int]$(& $Get 'schemaVersion')
    if ($SchemaVersion -ne $Script:WtSetupPlanSchemaVersion)
    {
        $Errors.Add("Unsupported plan schema version: $SchemaVersion.")
    }

    if ([string]::IsNullOrWhiteSpace([string]$(& $Get 'planId')))
    {
        $Errors.Add('planId is required.')
    }

    $Steps = @($(& $Get 'steps'))
    if ($Steps.Count -eq 0)
    {
        $Errors.Add('A plan needs at least one step.')
    }
    if ($Steps.Count -gt $Script:WtSetupMaxSteps)
    {
        $Errors.Add("A plan may have at most $($Script:WtSetupMaxSteps) steps.")
    }

    $Seen = @{}
    $Index = 0
    foreach ($Step in $Steps)
    {
        $Index++
        if ($Step -isnot [System.Collections.IDictionary] -and $Step -isnot [System.Management.Automation.PSCustomObject])
        {
            $Errors.Add("step $Index must be an object.")
            continue
        }
        $StepId = [string](Get-WtPlanStepField -Step $Step -Name 'stepId')
        if ($Seen.ContainsKey($StepId))
        {
            $Errors.Add("step $Index repeats stepId '$StepId'.")
        }
        $Seen[$StepId] = $true

        $TweakId = [string](Get-WtPlanStepField -Step $Step -Name 'tweakId')
        if ($TweakId -notmatch $Script:WtTweakIdPattern)
        {
            $Errors.Add("step $Index has an invalid tweakId '$TweakId'.")
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-WtPlanStepField -Step $Step -Name 'state')))
        {
            $Errors.Add("step $Index is missing a state.")
        }
        $Arguments = Get-WtPlanStepField -Step $Step -Name 'arguments'
        if ($null -ne $Arguments -and $Arguments -isnot [System.Collections.IDictionary])
        {
            $Errors.Add("step $Index arguments must be an object.")
        }
    }

    return @{
        Valid = ($Errors.Count -eq 0)
        Errors = @($Errors.ToArray())
    }
}

<#
.SYNOPSIS
    Writes a plan document to the plans directory.
#>
function Write-WtSetupPlan
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Plan)

    $Dir = Get-WtSetupPlanDirectory
    New-WtDirectory -Path $Dir

    $Name = [string]$Plan.planId -replace '[^A-Za-z0-9_-]', '_'
    $Path = Join-Path $Dir "$Name.json"
    $Json = ConvertTo-WtJson -InputObject $Plan -Depth 16
    Write-WtTextFile -Path $Path -Value $Json
    return $Path
}

<#
.SYNOPSIS
    Reads a plan document by id.
#>
function Read-WtSetupPlan
{
    [CmdletBinding()]
    [OutputType([object])]
    param ([Parameter(Mandatory = $true)][string]$Id)

    $Name = $Id -replace '[^A-Za-z0-9_-]', '_'
    $Path = Join-Path (Get-WtSetupPlanDirectory) "$Name.json"
    if (-not (Test-Path -LiteralPath $Path))
    {
        return $null
    }

    try
    {
        $Plan = ConvertFrom-WtJson -Text (Read-WtTextFile -Path $Path) -Depth 16
        $Plan | Add-Member -NotePropertyName Path -NotePropertyValue $Path -Force
        return $Plan
    }
    catch
    {
        throw "The setup plan could not be read: $Path ($($_.Exception.Message))"
    }
}

<#
.SYNOPSIS
    Creates a setup plan from selected steps (no step is applied).
#>
function New-WtSetupPlanInternal
{
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Steps,
        [Parameter(Mandatory = $false)][string]$PlanId = ''
    )

    if (-not $PlanId) { $PlanId = [guid]::NewGuid().ToString('n') }

    $Normalised = @()
    foreach ($Step in $Steps)
    {
        $Table = @{
            stepId = [string]$Step.stepId
            tweakId = [string]$Step.tweakId
            state = [string]$Step.state
        }
        if ($Step.arguments) { $Table.arguments = $Step.arguments }
        $Normalised += $Table
    }

    $Plan = [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.SetupPlan'
        schemaVersion = $Script:WtSetupPlanSchemaVersion
        planId = $PlanId
        appVersion = [string](Get-WtJournalContext).appVersion
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        steps = $Normalised
    }

    $Validation = Test-WtSetupPlanDocument -Document $Plan
    if (-not $Validation.Valid)
    {
        throw "The plan is invalid: $($Validation.Errors -join '; ')"
    }

    $Plan | Add-Member -NotePropertyName planHash -NotePropertyValue (Get-WtSetupPlanHash -Plan $Plan) -Force
    $Path = Write-WtSetupPlan -Plan $Plan
    $Plan | Add-Member -NotePropertyName Path -NotePropertyValue $Path -Force
    return $Plan
}

<#
.SYNOPSIS
    Reads one field from a step (hashtable or object).
#>
function Get-WtPlanStepField
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Step,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Step -is [System.Collections.IDictionary])
    {
        if ($Step.Contains($Name)) { return $Step[$Name] }
        return $null
    }

    if (@($Step.PSObject.Properties.Name) -contains $Name)
    {
        return $Step.$Name
    }
    return $null
}

<#
.SYNOPSIS
    Resolves a plan step to its tweak and validates state/arguments.
.DESCRIPTION
    Steps only reference catalog ids; the engine resolves them, so a plan can never smuggle
    in a command or a script path.
#>
function Resolve-WtSetupPlanStep
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Step,
        [Parameter(Mandatory = $false)][hashtable]$ExistingStates
    )

    $TweakId = [string](Get-WtPlanStepField -Step $Step -Name 'tweakId')
    $State = [string](Get-WtPlanStepField -Step $Step -Name 'state')
    $Tweak = Get-WtTweakInternal -Id $TweakId

    if (-not $Tweak)
    {
        return @{ Ok = $false; Reason = "Unknown tweak: $TweakId" }
    }

    if (@($Tweak.StateNames) -notcontains $State)
    {
        return @{ Ok = $false; Reason = "State '$State' is not valid for $TweakId (supported: $(@($Tweak.StateNames) -join ', '))" }
    }

    return @{
        Ok = $true
        Reason = ''
        Tweak = $Tweak
        State = $State
        Arguments = (Get-WtPlanStepField -Step $Step -Name 'arguments')
    }
}

<#
.SYNOPSIS
    Computes the plan preview: step statuses plus the aggregated capability-loss summary.
#>
function Get-WtSetupPlanPreviewInternal
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ([Parameter(Mandatory = $true)][object]$Plan)

    $Rows = [System.Collections.Generic.List[object]]::new()
    $Selection = [System.Collections.Generic.List[object]]::new()

    foreach ($Step in @($Plan.steps))
    {
        $Resolved = Resolve-WtSetupPlanStep -Step $Step
        if (-not $Resolved.Ok)
        {
            $Rows.Add([pscustomobject]@{
                StepId = [string]$Step.stepId
                TweakId = [string]$Step.tweakId
                State = [string]$Step.state
                Status = 'Unresolved'
                Reason = $Resolved.Reason
            })
            continue
        }

        $Selection.Add(@{ Tweak = $Resolved.Tweak; State = $Resolved.State })

        $Detected = Get-WtTweakState -Id $Resolved.Tweak.Id
        $Rows.Add([pscustomobject]@{
            StepId = [string]$Step.stepId
            TweakId = $Resolved.Tweak.Id
            State = $Resolved.State
            Status = if ($Detected.Supported) { 'Ready' } else { 'Unsupported' }
            Reason = if ($Detected.Supported) { '' } else { [string]$Detected.UnsupportedReason }
            Restart = [string]$Resolved.Tweak.Restart
            Risk = [string]$Resolved.Tweak.Risk
        })
    }

    $CapabilityLoss = Get-WtCapabilityLossInternal -Selection @($Selection.ToArray())

    return @{
        Plan = $Plan
        Rows = @($Rows.ToArray())
        CapabilityLoss = $CapabilityLoss
    }
}

<#
.SYNOPSIS
    Reads the resume registration (null when none exists).
#>
function Read-WtSetupResume
{
    [CmdletBinding()]
    [OutputType([object])]
    param ()

    $Path = Get-WtSetupResumePath
    if (-not (Test-Path -LiteralPath $Path))
    {
        return $null
    }

    try
    {
        $Resume = ConvertFrom-WtJson -Text (Read-WtTextFile -Path $Path) -Depth 8
        $Resume | Add-Member -NotePropertyName Path -NotePropertyValue $Path -Force
        return $Resume
    }
    catch
    {
        throw "The resume registration could not be read: $Path ($($_.Exception.Message))"
    }
}

<#
.SYNOPSIS
    Persists a resume registration (explicit opt-in only).
#>
function Write-WtSetupResume
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][object]$Resume)

    $Path = Get-WtSetupResumePath
    $Json = ConvertTo-WtJson -InputObject $Resume -Depth 8
    Write-WtTextFile -Path $Path -Value $Json
}

<#
.SYNOPSIS
    Removes the resume registration.
#>
function Remove-WtSetupResume
{
    [CmdletBinding()]
    param ()

    $Path = Get-WtSetupResumePath
    if (Test-Path -LiteralPath $Path)
    {
        Remove-Item -LiteralPath $Path -Force
    }
}

<#
.SYNOPSIS
    Validates a resume registration against the current machine and plan.
.DESCRIPTION
    Refuses to resume when any bound identity mismatches: plan hash, user identity, app
    version, the trusted execution path and the plan's existence. A tampered registration
    is reported, never repaired silently.
#>
function Test-WtSetupResumeBinding
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Resume,
        [Parameter(Mandatory = $false)][string]$ExecutablePath = ''
    )

    $Plan = Read-WtSetupPlan -Id ([string]$Resume.planId)
    if (-not $Plan)
    {
        return @{ Ok = $false; Reason = 'The referenced plan no longer exists.' }
    }

    if ((Get-WtSetupPlanHash -Plan $Plan) -ne [string]$Resume.planHash)
    {
        return @{ Ok = $false; Reason = 'The plan changed since the checkpoint was written; review it and create a new checkpoint.' }
    }

    if ([string]$Resume.appVersion -ne [string](Get-WtJournalContext).appVersion)
    {
        return @{ Ok = $false; Reason = 'The application version changed since the checkpoint; resume is refused.' }
    }

    if ([string]$Resume.userId -ne (Get-WtSetupUserId))
    {
        return @{ Ok = $false; Reason = 'The registration belongs to a different user on this machine.' }
    }

    if ($ExecutablePath)
    {
        $Expected = [System.IO.Path]::GetFullPath($ExecutablePath)
        $Registered = [System.IO.Path]::GetFullPath([string]$Resume.executablePath)
        if ($Registered -ne $Expected)
        {
            return @{ Ok = $false; Reason = 'The registration is bound to a different execution path.' }
        }
    }

    return @{ Ok = $true; Reason = ''; Plan = $Plan }
}

<#
.SYNOPSIS
    Returns the machine user identity used to bind resume registrations.
#>
function Get-WtSetupUserId
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    if ($env:WT_SETUP_USER_ID)
    {
        return [string]$env:WT_SETUP_USER_ID
    }

    $UserId = ''
    try
    {
        $UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch
    {
        $UserId = ''
    }

    if (-not $UserId)
    {
        $UserId = [string](Get-WtEnvironment).OSName
        if (-not $UserId) { $UserId = [string]$env:USERNAME }
    }
    return $UserId
}

<#
.SYNOPSIS
    Executes the remaining steps of a validated plan.
.DESCRIPTION
    Runs inside the existing reviewed engine (Invoke-WtTweak). A failed step stops the
    plan: dependent steps are not executed. A step whose previous outcome is uncertain is
    never retried automatically. Rebooting steps advance the checkpoint and rely on the
    bounded resume registration.
#>
function Invoke-WtSetupPlanInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $false)][int]$FromIndex = 0,
        [Parameter(Mandatory = $false)][int]$MaxReboots = 0
    )

    if ($MaxReboots -le 0) { $MaxReboots = $Script:WtSetupMaxReboots }

    $Results = [System.Collections.Generic.List[object]]::new()
    $StopReason = ''
    $StepIndex = $FromIndex

    while ($StepIndex -lt @($Plan.steps).Count)
    {
        $Step = @($Plan.steps)[$StepIndex]
        $Resolved = Resolve-WtSetupPlanStep -Step $Step
        if (-not $Resolved.Ok)
        {
            $StopReason = $Resolved.Reason
            break
        }

        try
        {
            $Apply = Invoke-WtTweak -Id $Resolved.Tweak.Id -State $Resolved.State -Arguments $Resolved.Arguments -Confirm:$false
        }
        catch
        {
            $Results.Add([pscustomobject]@{
                StepId = [string]$Step.stepId
                TweakId = $Resolved.Tweak.Id
                State = $Resolved.State
                Status = 'failed'
                Reason = $_.Exception.Message
            })
            $StopReason = "Step $($StepIndex + 1) failed: $($_.Exception.Message)"
            break
        }

        $Status = [string]$Apply.Status

        # Uncertain outcomes (verification failed, external change) are never retried.
        if ($Status -in 'failed', 'review-required')
        {
            $Results.Add([pscustomobject]@{
                StepId = [string]$Step.stepId
                TweakId = $Resolved.Tweak.Id
                State = $Resolved.State
                Status = $Status
                Reason = [string]$Apply.Message
            })
            $StopReason = "Step $($StepIndex + 1) did not verify; it will not be retried automatically."
            break
        }

        $Results.Add([pscustomobject]@{
            StepId = [string]$Step.stepId
            TweakId = $Resolved.Tweak.Id
            State = $Resolved.State
            Status = $Status
            Reason = ''
        })

        $StepIndex++

        # A reboot-bound step advances the checkpoint and stops here; the resume
        # registration carries the next index.
        if ($Resolved.Tweak.Restart -eq 'Reboot' -and $Status -ne 'unchanged')
        {
            $RebootCount = [int]$Plan.reboots
            $RebootCount++
            if ($RebootCount -gt $MaxReboots)
            {
                $StopReason = "The plan exceeded its reboot bound ($MaxReboots); remove the registration and continue manually."
                break
            }
            return @{
                Completed = $false
                Results = @($Results.ToArray())
                NextIndex = $StepIndex
                NeedsReboot = $true
                RebootCount = $RebootCount
                StopReason = $StopReason
            }
        }
    }

    return @{
        Completed = ($StepIndex -ge @($Plan.steps).Count -and -not $StopReason)
        Results = @($Results.ToArray())
        NextIndex = $StepIndex
        NeedsReboot = $false
        RebootCount = [int]$Plan.reboots
        StopReason = $StopReason
    }
}

<#
.SYNOPSIS
    Starts a plan with an explicit resume opt-in: writes the checkpoint and the bounded
    registration, then executes.
#>
function Start-WtSetupPlanInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $false)][switch]$ResumeAfterReboot,
        [Parameter(Mandatory = $false)][string]$ExecutablePath = ''
    )

    $Plan | Add-Member -NotePropertyName reboots -NotePropertyValue 0 -Force -ErrorAction Ignore
    $Plan | Add-Member -NotePropertyName stepIndex -NotePropertyValue 0 -Force -ErrorAction Ignore

    $Resume = $null
    if ($ResumeAfterReboot)
    {
        $Resume = [pscustomobject]@{
            schemaVersion = $Script:WtSetupPlanSchemaVersion
            planId = [string]$Plan.planId
            planHash = (Get-WtSetupPlanHash -Plan $Plan)
            userId = (Get-WtSetupUserId)
            appVersion = [string]$Plan.appVersion
            executablePath = $ExecutablePath
            stepIndex = 0
            reboots = 0
            createdUtc = (Get-Date).ToUniversalTime().ToString('o')
            updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        Write-WtSetupResume -Resume $Resume
    }

    $Run = Invoke-WtSetupPlanInternal -Plan $Plan -FromIndex 0

    if ($Resume)
    {
        $Resume.stepIndex = $Run.NextIndex
        $Resume.reboots = $Run.RebootCount
        $Resume.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-WtSetupResume -Resume $Resume
        if ($Run.Completed)
        {
            Remove-WtSetupResume
        }
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.SetupPlanRun'
        PlanId = [string]$Plan.planId
        Completed = [bool]$Run.Completed
        Steps = @($Run.Results)
        NextIndex = $Run.NextIndex
        NeedsReboot = [bool]$Run.NeedsReboot
        RebootCount = $Run.RebootCount
        StopReason = [string]$Run.StopReason
        ResumeRegistered = ($null -ne $Resume -and -not $Run.Completed)
    }
}

<#
.SYNOPSIS
    Resumes a registered plan after revalidation.
#>
function Resume-WtSetupPlanInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][string]$ExecutablePath = ''
    )

    $Resume = Read-WtSetupResume
    if (-not $Resume)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.SetupPlanRun'
            PlanId = ''
            Completed = $false
            Steps = @()
            NextIndex = 0
            NeedsReboot = $false
            RebootCount = 0
            StopReason = 'No resume registration exists.'
            ResumeRegistered = $false
        }
    }

    $Binding = Test-WtSetupResumeBinding -Resume $Resume -ExecutablePath $ExecutablePath
    if (-not $Binding.Ok)
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.SetupPlanRun'
            PlanId = [string]$Resume.planId
            Completed = $false
            Steps = @()
            NextIndex = [int]$Resume.stepIndex
            NeedsReboot = $false
            RebootCount = [int]$Resume.reboots
            StopReason = $Binding.Reason
            ResumeRegistered = $false
        }
    }

    $Plan = $Binding.Plan
    $Plan | Add-Member -NotePropertyName reboots -NotePropertyValue ([int]$Resume.reboots) -Force -ErrorAction Ignore
    $Plan | Add-Member -NotePropertyName stepIndex -NotePropertyValue ([int]$Resume.stepIndex) -Force -ErrorAction Ignore

    $Run = Invoke-WtSetupPlanInternal -Plan $Plan -FromIndex ([int]$Resume.stepIndex) -MaxReboots $Script:WtSetupMaxReboots

    if ($Run.Completed)
    {
        Remove-WtSetupResume
        $Registered = $false
    }
    else
    {
        $Resume.stepIndex = $Run.NextIndex
        $Resume.reboots = $Run.RebootCount
        $Resume.updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-WtSetupResume -Resume $Resume
        $Registered = $true
    }

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.SetupPlanRun'
        PlanId = [string]$Plan.planId
        Completed = [bool]$Run.Completed
        Steps = @($Run.Results)
        NextIndex = $Run.NextIndex
        NeedsReboot = [bool]$Run.NeedsReboot
        RebootCount = $Run.RebootCount
        StopReason = [string]$Run.StopReason
        ResumeRegistered = $Registered
    }
}
