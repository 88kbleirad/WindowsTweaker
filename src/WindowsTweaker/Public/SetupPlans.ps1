# WindowsTweaker - public setup plan API (checkpointed workflows).

<#
.SYNOPSIS
    Lists stored setup plans.
#>
function Get-WtSetupPlan
{
    [CmdletBinding()]
    [OutputType([object[]])]
    param ()

    $Dir = Get-WtSetupPlanDirectory
    if (-not (Test-Path -LiteralPath $Dir))
    {
        return @()
    }

    $Plans = [System.Collections.Generic.List[object]]::new()
    foreach ($File in @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File | Sort-Object -Property Name))
    {
        try
        {
            $Plan = Get-Content -LiteralPath $File.FullName -Raw | ConvertFrom-Json -Depth 16
            $Plan | Add-Member -NotePropertyName Path -NotePropertyValue $File.FullName -Force
            $Plans.Add($Plan)
        }
        catch
        {
            # A corrupt plan file is reported via the list, never silently dropped.
            $Plans.Add([pscustomobject]@{
                planId = $File.BaseName
                schemaVersion = -1
                appVersion = ''
                createdUtc = ''
                steps = @()
                Path = $File.FullName
                ReadError = $_.Exception.Message
            })
        }
    }

    return @($Plans.ToArray())
}

<#
.SYNOPSIS
    Creates a plan from tweak id/state steps (no step is applied).
.PARAMETER Steps
    Array of @{ stepId; tweakId; state; arguments? }.
#>
function New-WtSetupPlan
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][object[]]$Steps,
        [Parameter(Mandatory = $false)][string]$PlanId = ''
    )

    if ($PSCmdlet.ShouldProcess("$($Steps.Count) step(s)", 'create a setup plan'))
    {
        return (New-WtSetupPlanInternal -Steps $Steps -PlanId $PlanId)
    }
    return $null
}

<#
.SYNOPSIS
    Exports a plan document (versioned JSON).
#>
function Export-WtSetupPlan
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Plan = Read-WtSetupPlan -Id $Id
    if (-not $Plan)
    {
        throw "The setup plan '$Id' does not exist."
    }

    if (-not $Force -and (Test-Path -LiteralPath $Path))
    {
        throw "The export path already exists: $Path"
    }

    $Json = $Plan | ConvertTo-Json -Depth 16
    Set-Content -LiteralPath $Path -Value $Json -Encoding utf8NoBOM
    return $Path
}

<#
.SYNOPSIS
    Imports a plan document: validates and stores it, applies nothing.
.DESCRIPTION
    The document must be the versioned plan shape (schemaVersion, planId, appVersion,
    steps with tweakId/state only). No step is executed and no resume registration is
    created by importing.
#>
function Import-WtSetupPlan
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 16
    $Validation = Test-WtSetupPlanDocument -Document $Document
    if (-not $Validation.Valid)
    {
        throw "The plan document is invalid: $($Validation.Errors -join '; ')"
    }

    $Existing = Read-WtSetupPlan -Id ([string]$Document.planId)
    if ($Existing -and -not $Force)
    {
        throw "The plan '$( $Document.planId)' already exists; use -Force to replace it."
    }

    if ($PSCmdlet.ShouldProcess([string]$Document.planId, 'import a setup plan'))
    {
        $Plan = $Document
        $Plan | Add-Member -NotePropertyName planHash -NotePropertyValue (Get-WtSetupPlanHash -Plan $Plan) -Force
        $Stored = Write-WtSetupPlan -Plan $Plan
        return [pscustomobject]@{
            PlanId = [string]$Plan.planId
            StepCount = @($Plan.steps).Count
            Path = $Stored
            Applied = $false
        }
    }

    return [pscustomobject]@{
        PlanId = [string]$Document.planId
        StepCount = @($Document.steps).Count
        Path = ''
        Applied = $false
    }
}

<#
.SYNOPSIS
    Reviews a plan: step statuses and the aggregated capability-loss summary.
#>
function Get-WtSetupPlanPreview
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $true)][string]$Id)

    $Plan = Read-WtSetupPlan -Id $Id
    if (-not $Plan)
    {
        throw "The setup plan '$Id' does not exist."
    }

    $Preview = Get-WtSetupPlanPreviewInternal -Plan $Plan
    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.SetupPlanPreview'
        PlanId = [string]$Plan.planId
        Rows = @($Preview.Rows)
        CapabilityLoss = $Preview.CapabilityLoss
    }
}

<#
.SYNOPSIS
    Starts a plan, with an optional resume-after-reboot registration.
.DESCRIPTION
    Applying goes through the reviewed engine per step. -ResumeAfterReboot is the explicit
    opt-in: a checkpoint and a bounded, identity-bound registration are written before the
    first step; reboot-bound steps stop and rely on Resume-WtSetupPlan. No step runs before
    the reviewed confirmation.
#>
function Start-WtSetupPlan
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $false)][switch]$ResumeAfterReboot,
        [Parameter(Mandatory = $false)][string]$ExecutablePath = ''
    )

    $Plan = Read-WtSetupPlan -Id $Id
    if (-not $Plan)
    {
        throw "The setup plan '$Id' does not exist."
    }

    $Preview = Get-WtSetupPlanPreviewInternal -Plan $Plan
    $Unsupported = @($Preview.Rows | Where-Object { $_.Status -ne 'Ready' })
    if ($Unsupported.Count -gt 0)
    {
        throw "The plan contains $($Unsupported.Count) unsupported/unresolved step(s); review it before starting (preview via Get-WtSetupPlanPreview)."
    }

    if ($PSCmdlet.ShouldProcess("$Id ($(@($Plan.steps).Count) steps)", 'start a setup plan'))
    {
        return (Start-WtSetupPlanInternal -Plan $Plan -ResumeAfterReboot:$ResumeAfterReboot -ExecutablePath $ExecutablePath)
    }

    return $null
}

<#
.SYNOPSIS
    Resumes a registered plan after revalidation.
#>
function Resume-WtSetupPlan
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $false)][string]$ExecutablePath = ''
    )

    if ($PSCmdlet.ShouldProcess('the registered plan', 'resume after reboot'))
    {
        return (Resume-WtSetupPlanInternal -ExecutablePath $ExecutablePath)
    }

    return $null
}

<#
.SYNOPSIS
    Removes the resume registration without applying anything.
#>
function Remove-WtSetupPlanResume
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([bool])]
    param ()

    if ($PSCmdlet.ShouldProcess('the resume registration', 'remove'))
    {
        Remove-WtSetupResume
        return $true
    }
    return $false
}
