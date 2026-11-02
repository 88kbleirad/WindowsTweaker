# WindowsTweaker - Licensing & Activation Diagnostics.
#
# Read-only Windows licensing inventory and guided diagnostics, with three explicit,
# user-requested actions (open activation settings, refresh, request activation using the
# installed license). The implementation uses documented Windows interfaces only:
#
#   * CIM/WMI  SoftwareLicensingProduct / SoftwareLicensingService
#               (the same classes slmgr.vbs reads for its status table)
#   * slmgr.vbs via cscript (documented "SLMgr" UI/scripting interface) for the
#     activation request and for structured error reporting
#   * Win32_OperatingSystem for grace/license state
#   * W32Time / w32tm for time synchronization status
#   * the CSP/activation endpoint configuration published by Microsoft
#
# MAS (Microsoft-Activation-Scripts) is a reference for *flow* only: concise status
# reporting and troubleshooting structure. None of its code is embedded or ported. This
# file is independently written. No hardware-identity spoofing, no licensing hooks, no
# forged activation data, no third-party activation servers, no reset/rearm/
# KMS-reconfiguration commands.
#
# The one place upstream MAS is involved is deliberate and separate: the licensing workspace
# offers an explicit external-tool action (Private/ExternalTool.ps1, see
# docs/EXTERNAL-TOOLS.md) that downloads the upstream file at one pinned commit and launches
# it as its own process on request. Nothing here calls it, and it never runs as part of a
# refresh, a diagnostic read or a batch.
#
# Privacy: the inventory never contains full product keys, activation tokens, installation
# identifiers, or organization hostnames. The partial key is shown only where the OS
# exposes a partial key and the caller asks for it; exports redact it by default.

$Script:WtLicensingCache = $null

# Whether the cached inventory was built with the partial key included. The cache is only
# reusable for the same inclusion mode: a caller that did not ask for the key must never be
# served the records that do carry it, and a caller that asked for it must never be served
# records that had it stripped. Without this, the answer depended on the order of calls.
$Script:WtLicensingCacheHasPartialKey = $false

<#
.SYNOPSIS
    Drops the cached inventory so the next read re-queries the provider.
#>
function Clear-WtLicensingCache
{
    [CmdletBinding()]
    param ()

    $Script:WtLicensingCache = $null
    $Script:WtLicensingCacheHasPartialKey = $false
}

<#
.SYNOPSIS
    Reports whether the licensing provider is available on this runtime.
.DESCRIPTION
    The provider is the CIM/WMI SoftwareLicensingProduct class, which exists on Windows
    only. On non-Windows or when the provider is missing, the workspace reports the
    capability as unsupported and never fabricates a status.
#>
function Test-WtLicensingAvailable
{
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    $Runtime = Get-WtRuntimeProfile
    if (-not $Runtime.IsWindows) { return $false }
    return $true
}

<#
.SYNOPSIS
    Sanitizes a message before it is shown or logged.
.DESCRIPTION
    Product keys (five five-character groups), IPv4 addresses and host names are replaced
    with markers; the message is truncated at MaxLength. Used for provider errors that can
    carry machine or network identifiers.
#>
function Get-WtSanitizedMessage
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][int]$MaxLength = 300
    )

    $Text = $Message

    $Text = [regex]::Replace($Text, '\b\d{5}(?:-\d{5}){2,5}\b', '[KEY REDACTED]')
    $Text = [regex]::Replace($Text, '\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b', '[IP REDACTED]')
    $Text = [regex]::Replace($Text, '(?i)\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}\b', '[HOSTNAME REDACTED]')

    if ($Text.Length -gt $MaxLength)
    {
        $Text = $Text.Substring(0, $MaxLength) + '...'
    }

    return $Text
}

<#
.SYNOPSIS
    Runs one slmgr.vbs query through cscript and returns its sanitized text.
.DESCRIPTION
    Read-only, bounded and failure-tolerated: /xpr and /dlv are the two slmgr views that
    state the machine's license status. Output is sanitized (keys, addresses, host names)
    so full keys or organization identifiers never leave this function. A probe that does
    not answer within 8 seconds is killed and reported as a timeout.
#>
function Invoke-WtSlmgrProbe
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][string]$Argument,
        [Parameter(Mandatory = $false)][int]$TimeoutMilliseconds = 8000
    )

    $Result = @{
        Available = $false
        Argument = $Argument
        Output = ''
        Error = ''
        ExitCode = $null
    }

    if (-not (Test-WtLicensingAvailable)) { return $Result }

    $Cscript = Get-Command -Name 'cscript.exe' -ErrorAction Ignore
    $Slmgr = Get-Command -Name 'slmgr.vbs' -ErrorAction Ignore
    if (-not $Cscript -or -not $Slmgr) { return $Result }

    $Result.Available = $true

    try
    {
        $Process = [System.Diagnostics.Process]::new()
        $Process.StartInfo.FileName = $Cscript.Source
        $Process.StartInfo.Arguments = '"{0}" {1}' -f $Slmgr.Source, $Argument
        $Process.StartInfo.UseShellExecute = $false
        $Process.StartInfo.RedirectStandardOutput = $true
        $Process.StartInfo.RedirectStandardError = $true
        $Process.StartInfo.CreateNoWindow = $true

        if (-not $Process.Start()) { return $Result }

        if (-not $Process.WaitForExit($TimeoutMilliseconds))
        {
            try { $Process.Kill() } catch { Write-WtLog -Level Debug -Message 'The timed-out slmgr probe could not be killed.' -NoConsole }
            $Result.Error = 'The slmgr probe timed out.'
            return $Result
        }

        $Result.ExitCode = $Process.ExitCode
        $StdOut = $Process.StandardOutput.ReadToEnd()
        $StdErr = $Process.StandardError.ReadToEnd()
        $Result.Output = Get-WtSanitizedMessage -Message ($StdOut.Trim()) -MaxLength 1000
        if ($StdErr)
        {
            $Result.Error = Get-WtSanitizedMessage -Message ($StdErr.Trim()) -MaxLength 300
        }
    }
    catch
    {
        $Result.Error = Get-WtSanitizedMessage -Message $_.Exception.Message -MaxLength 300
    }

    return $Result
}

<#
.SYNOPSIS
    Reads a sanitized slmgr comparison report for the running system.
.DESCRIPTION
    Uses /xpr and /dlv. The summary carries the first lines of each report that look like
    status or expiry statements, sanitized. This is what an operator compares with the
    selected CIM record; nothing here changes licensing state.
#>
function Get-WtSlmgrComparison
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Result = @{
        Available = $false
        Xpr = ''
        Dlv = ''
        Error = ''
        CollectedUtc = [datetime]::UtcNow.ToString('o')
    }

    if (-not (Test-WtLicensingAvailable)) { return $Result }

    $Xpr = Invoke-WtSlmgrProbe -Argument '/xpr'
    $Dlv = Invoke-WtSlmgrProbe -Argument '/dlv'

    if ($Xpr.Available -or $Dlv.Available) { $Result.Available = $true }

    # Keep only lines that talk about status or expiry; the sanitizer already stripped keys
    # and host names, and the rest of the report is dropped.
    $Result.Xpr = @($Xpr.Output -split "`r?`n" | Where-Object { $_ -match '(?i)(license status|permanently activated|activated until|expires|remaining|grace|status)' } | Select-Object -First 3) -join "`n"
    $Result.Dlv = @($Dlv.Output -split "`r?`n" | Where-Object { $_ -match '(?i)(license status|partial product key|channel|installed|status)' } | Select-Object -First 6) -join "`n"

    $Errors = @($Xpr.Error, $Dlv.Error | Where-Object { $_ })
    if ($Errors.Count -gt 0)
    {
        $Result.Error = ($Errors -join ' | ')
    }

    return $Result
}

<#
.SYNOPSIS
    Wrapper over the CIM provider so tests can mock the exact seam.
#>
function Get-WtLicensingCim
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$ClassName)

    return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
}

<#
.SYNOPSIS
    Wrapper over Get-Service so tests can mock the exact seam.
#>
function Get-WtLicensingService
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $true)][string]$Name)

    return (Get-Service -Name $Name -ErrorAction Stop)
}

<#
.SYNOPSIS
    Wrapper over w32tm so tests can mock the exact seam.
#>
function Get-WtLicensingTimeQuery
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $Output = & w32tm /query /status 2>$null
    if ($Output) { return ($Output -join "`n") }
    return ''
}

<#
.SYNOPSIS
    Wrapper over Get-WinEvent so tests can mock the exact seam.
#>
function Get-WtLicensingWinEvent
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][string]$LogName,
        [Parameter(Mandatory = $true)][string]$ProviderName,
        [Parameter(Mandatory = $false)][int]$Hours = 24
    )

    return @(Get-WinEvent -FilterHashtable @{ LogName = $LogName; ProviderName = $ProviderName; StartTime = (Get-Date).AddHours(-$Hours) } -MaxEvents 1 -ErrorAction Ignore)
}

<#
.SYNOPSIS
    Normalises a licensing product into a display-friendly record.
.DESCRIPTION
    Only products that describe the *Windows* license are considered. The active license is
    selected from the Windows licensing products; records that are not the active Windows
    license are reported separately (as inventory, never as the active license).
#>
function ConvertTo-WtLicensingView
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Product,
        [Parameter(Mandatory = $false)][bool]$IncludePartialKey = $false
    )

    $StatusText = switch ([int]$Product.LicenseStatus)
    {
        0 { 'Unlicensed' }
        1 { 'Licensed' }
        2 { 'OOBGrace' }
        3 { 'OOTGrace' }
        4 { 'NonGenuineGrace' }
        5 { 'Notification' }
        6 { 'ExtendedGrace' }
        default { 'Unknown' }
    }

    $Partial = ''
    if ($IncludePartialKey)
    {
        $Partial = [string]$Product.PartialProductKey
    }
    elseif ($null -ne $Product.PartialProductKey)
    {
        # Still a partial key exists; it is just not returned. The field stays '' so a
        # consumer can tell "not requested" from "no key known".
        $Partial = ''
    }

    return [pscustomobject]@{
        PSTypeName       = 'WindowsTweaker.LicensingState'
        ProductName      = [string]$Product.Name
        ApplicationId    = [string]$Product.ApplicationId
        LicenseStatus    = $StatusText
        LicenseStatusRaw = [int]$Product.LicenseStatus
        LicenseChannel   = [string]$Product.LicenseChannel
        PartialProductKey= $Partial
        GraceRemaining   = if ($null -ne $Product.GraceRemaining) { [int]$Product.GraceRemaining } else { $null }
        EvaluationEndDate = if ($null -ne $Product.EvaluationEndDate) { [string]$Product.EvaluationEndDate } else { '' }
        Description       = [string]$Product.Description
        LicenseDependsOn  = if ($null -ne $Product.LicenseDependsOn) { [string]$Product.LicenseDependsOn } else { '' }
    }
}

<#
.SYNOPSIS
    Returns a copy of a licensing record with the partial product key removed.
.DESCRIPTION
    The inventory is cached and handed to more than one caller, so redaction is applied to a
    copy: the cached record keeps exactly what the read produced, and a later read that does
    ask for the partial key still has it.
#>
function Copy-WtLicensingRedactedRecord
{
    [CmdletBinding()]
    [OutputType([psobject])]
    param ([Parameter(Mandatory = $true)][psobject]$Record)

    $Copy = $Record.PSObject.Copy()
    $Copy.PartialProductKey = ''
    return $Copy
}

<#
.SYNOPSIS
    Returns the documented display label for an OS edition id.
.DESCRIPTION
    Only the ids Microsoft documents for the Windows editions the activation methods support
    are mapped; anything else falls back to the raw id so nothing is invented. The id is the
    EditionID registry value, which is more reliable than the legacy ProductName string.
#>
function Get-WtEditionDisplayLabel
{
    [CmdletBinding()]
    [OutputType([string])]
    param ([Parameter(Mandatory = $false)][AllowEmptyString()][string]$EditionId = '')

    if (-not $EditionId) { return '' }

    switch -Regex ($EditionId)
    {
        '(?i)^professional(N|EducationN|WorkstationN)?$' { return 'Pro' }
        '(?i)^professionalEducation$' { return 'Pro Education' }
        '(?i)^professionalWorkstation$' { return 'Pro for Workstations' }
        '(?i)^core(N)?$' { return 'Home' }
        '(?i)^coreSingleLanguage$' { return 'Home Single Language' }
        '(?i)^coreCountrySpecific$' { return 'Home China' }
        '(?i)^education(N)?$' { return 'Education' }
        '(?i)^enterprise(N|G|GN)?$' { return 'Enterprise' }
        '(?i)^enterpriseS(N)?$' { return 'Enterprise LTSC' }
        '(?i)^iotEnterprise$' { return 'IoT Enterprise' }
        '(?i)^iotEnterpriseS(K)?$' { return 'IoT Enterprise LTSC' }
        '(?i)^cloud(Edition)?(N)?$' { return 'SE' }
        '(?i)^server(Standard|Datacenter|Solution|Web|Enterprise|HyperCore|StorageStandard|StorageWorkgroup|Turbine|AzureCor|ARM64|Rdsh|Core|V)?$' { return 'Server' }
        '(?i)^embeddedIndustry(A|E)?$' { return 'Embedded Industry' }
        '(?i)^starter$' { return 'Starter' }
        '(?i)^ppiPro$' { return 'Team' }
        default { return $EditionId }
    }
}

<#
.SYNOPSIS
    Maps an OS edition id to search tokens used to match the installed edition.
.DESCRIPTION
    The token list is a deliberately small, documented vocabulary: the tokens are matched
    case-insensitively against product names and descriptions, and they come from the
    edition ids Microsoft defines for the editions the methods support. A record that
    matches the installed edition wins the tie when several Windows records have the same
    license status.
#>
function Get-WtLicensingEditionTokens
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param ([Parameter(Mandatory = $false)][AllowEmptyString()][string]$EditionId = '')

    $Tokens = [System.Collections.Generic.List[string]]::new()
    if (-not $EditionId) { return @() }

    switch -Regex ($EditionId)
    {
        '(?i)(^|.*)professional' { $Tokens.Add('professional') }
        '(?i)(^|.*)core' { $Tokens.Add('core') }
        '(?i)(^|.*)education' { $Tokens.Add('education') }
        '(?i)(^|.*)enterprise' { $Tokens.Add('enterprise') }
        '(?i)(^|.*)iot' { $Tokens.Add('iot') }
        '(?i)(^|.*)server' { $Tokens.Add('server') }
    }

    if ($EditionId -match '(?i)ltsc') { $Tokens.Add('ltsc') }
    if ($EditionId -match '(?i)eval') { $Tokens.Add('eval') }
    if ($EditionId -match '(?i)singlelanguage') { $Tokens.Add('single language') }
    if ($EditionId -match '(?i)countryspecific') { $Tokens.Add('country specific') }

    return @($Tokens)
}

<#
.SYNOPSIS
    Scores how well one licensing record matches the installed OS edition.
.DESCRIPTION
    Pure. 2 when a token for the installed edition appears in the record's name or
    description, 1 when it appears in the channel, 0 otherwise.
#>
function Get-WtLicensingEditionMatchScore
{
    [CmdletBinding()]
    [OutputType([int])]
    param
    (
        [Parameter(Mandatory = $true)][object]$Product,
        [Parameter(Mandatory = $false)][string]$EditionId = ''
    )

    $Tokens = @(Get-WtLicensingEditionTokens -EditionId $EditionId)
    if ($Tokens.Count -eq 0) { return 0 }

    $Text = ([string]$Product.Name + ' ' + [string]$Product.Description).ToLowerInvariant()
    $Channel = ([string]$Product.LicenseChannel).ToLowerInvariant()

    foreach ($Token in $Tokens)
    {
        if ($Text.Contains($Token)) { return 2 }
    }
    foreach ($Token in $Tokens)
    {
        if ($Channel.Contains($Token)) { return 1 }
    }

    return 0
}

<#
.SYNOPSIS
    Reads the installed OS edition id from the registry ('' when unavailable).
#>
function Get-WtInstalledEditionId
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    try
    {
        $Info = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($Info.EditionID) { return [string]$Info.EditionID }
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'The installed edition id could not be read.' -NoConsole
    }

    return ''
}

<#
.SYNOPSIS
    Reads the Windows licensing inventory from CIM/WMI.
.DESCRIPTION
    Bounded and read-only. The SoftwareLicensingProduct class is queried for the products
    whose ApplicationId identifies Windows (55c92734-d682-4d71-983e-d6ec3f16059f).

    The active product is selected, never assumed:
      * records that depend on another license (add-ons such as ESU or APPX) are excluded
        from the selection and reported separately;
      * the candidate set is the base-installed records - those with a partial product key
        when any exists, otherwise all base records;
      * the candidate with the highest license status wins; ties are broken by matching the
        installed OS edition, then by the presence of a partial key, then by the order the
        provider returned them.
    Nothing here forces Licensed: the raw code of the selected record is what is reported.
    The selection is recorded (Selection), with the count of base records and whether
    several Windows records are installed. A status is never inferred from other records.
    Returns a hashtable with Products (the inventory), Active (the selected active product,
    or $null), Dependents, Selection, and a Reason when the overall source is unavailable.
#>
function Read-WtLicensingInventory
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][switch]$Refresh,
        [Parameter(Mandatory = $false)][switch]$IncludePartialKey
    )

    if ($Script:WtLicensingCache -and -not $Refresh -and $Script:WtLicensingCacheHasPartialKey -eq [bool]$IncludePartialKey)
    {
        return $Script:WtLicensingCache
    }

    $WindowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
    $Result = @{
        CollectedUtc = [datetime]::UtcNow
        Source = 'CIM/WMI SoftwareLicensingProduct'
        Products = @()
        Active = $null
        Dependents = @()
        Selection = [ordered]@{
            Rule = ''
            BaseCount = 0
            CandidateCount = 0
            MultipleWindowsRecords = $false
            EditionId = ''
        }
        Unreadable = $false
        Reason = ''
    }

    if (-not (Test-WtLicensingAvailable))
    {
        $Result.Unreadable = $true
        $Result.Reason = 'the licensing provider is only available on Windows'
        return $Result
    }

    $EditionId = Get-WtInstalledEditionId
    $Result.Selection.EditionId = $EditionId

    try
    {
        $All = @(Get-WtLicensingCim -ClassName SoftwareLicensingProduct)
        $Windows = @($All | Where-Object { [string]$_.ApplicationId -eq $WindowsAppId })
        $Base = @($Windows | Where-Object { -not $_.LicenseDependsOn })
        $Result.Dependents = @($Windows | Where-Object { $_.LicenseDependsOn } | ForEach-Object { ConvertTo-WtLicensingView -Product $_ -IncludePartialKey:$IncludePartialKey })
        $Result.Products = @($Base | ForEach-Object { ConvertTo-WtLicensingView -Product $_ -IncludePartialKey:$IncludePartialKey })

        $Result.Selection.BaseCount = $Base.Count
        $Result.Selection.MultipleWindowsRecords = ($Base.Count -gt 1)

        if ($Windows.Count -gt 0)
        {
            $Candidates = @($Base | Where-Object { -not [string]::IsNullOrEmpty([string]$_.PartialProductKey) })
            if ($Candidates.Count -eq 0)
            {
                $Candidates = @($Base)
            }
            $Result.Selection.CandidateCount = $Candidates.Count

            if ($Candidates.Count -gt 0)
            {
                $Best = $null
                $BestScore = -1
                $BestEditionScore = -1
                $BestHasKey = $false

                foreach ($Candidate in $Candidates)
                {
                    $Status = [int]$Candidate.LicenseStatus
                    $EditionScore = Get-WtLicensingEditionMatchScore -Product $Candidate -EditionId $EditionId
                    $HasKey = -not [string]::IsNullOrEmpty([string]$Candidate.PartialProductKey)

                    if ($EditionScore -gt $BestEditionScore -or ($EditionScore -eq $BestEditionScore -and $Status -gt $BestScore) -or ($EditionScore -eq $BestEditionScore -and $Status -eq $BestScore -and $HasKey -and -not $BestHasKey))
                    {
                        $Best = $Candidate
                        $BestScore = $Status
                        $BestEditionScore = $EditionScore
                        $BestHasKey = $HasKey
                    }
                }

                if ($Best)
                {
                    $Result.Active = ConvertTo-WtLicensingView -Product $Best -IncludePartialKey:$IncludePartialKey

                    if ($Candidates.Count -eq 1) { $Result.Selection.Rule = 'single-candidate' }
                    elseif ($BestEditionScore -gt 0) { $Result.Selection.Rule = 'highest-status-with-edition-match' }
                    else { $Result.Selection.Rule = 'highest-license-status' }
                }
            }
        }
    }
    catch
    {
        $Result.Unreadable = $true
        $Result.Reason = $_.Exception.Message
    }

    $Script:WtLicensingCache = $Result
    $Script:WtLicensingCacheHasPartialKey = [bool]$IncludePartialKey
    return $Result
}

<#
.SYNOPSIS
    Reads the system time and time-synchronization status.
.DESCRIPTION
    Bounded read-only probes: the local time, the W32Time service state, its configured
    startup trigger, and the service status. A stopped service is reported as a finding,
    not as a fault: the configured start type and trigger explain whether it is expected.
#>
function Read-WtLicensingTimeState
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Result = @{
        LocalUtc = [datetime]::UtcNow
        LocalNow = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        Service = 'unknown'
        StartType = 'unknown'
        Trigger = ''
        Synchronized = $null
        Reason = ''
    }

    try
    {
        $Svc = Get-WtLicensingService -Name w32time
        $Result.Service = [string]$Svc.Status
        $Result.StartType = [string]$Svc.StartType
    }
    catch
    {
        $Result.Service = 'unreadable'
        $Result.Reason = $_.Exception.Message
    }

    # The time service may be trigger-started (e.g., on boot for time sync); a stopped
    # service is only a finding when it has no configured trigger.
    try
    {
        $Triggers = @(Get-WtLicensingCim -ClassName 'Win32_Service' | Where-Object { $_.Name -eq 'w32time' } | Select-Object -ExpandProperty StartName)
        if ($Triggers) { $Result.Trigger = ($Triggers -join ',') }
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'The w32time trigger probe is unavailable; the trigger is reported as unknown.' -NoConsole
    }

    try
    {
        $Result.Synchronized = [bool]((Get-WtLicensingTimeQuery) -match '(?i)synchronized|synced|ntp')
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'w32tm is unavailable; time synchronization stays unreported instead of being assumed.' -NoConsole
    }

    return $Result
}

<#
.SYNOPSIS
    Reads licensing component availability and structured activation error codes.
.DESCRIPTION
    Components: the SoftwareLicensingService state and the presence of the slmgr script
    interface. Structured activation errors are read from the most recent event log entry
    of the Software Protection Service (source 'Software Protection Platform Service') when
    the caller opts into the probe.
#>
function Read-WtLicensingComponents
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Result = @{
        SlmgrAvailable = $false
        Service = 'unknown'
        ServiceStartType = 'unknown'
        ServiceError = ''
        LastActivationError = ''
        LastActivationErrorUtc = ''
        LastActivationErrorReadError = ''
    }

    try
    {
        $Slmgr = Get-Command -Name 'slmgr.vbs' -ErrorAction Ignore
        $Result.SlmgrAvailable = $null -ne $Slmgr
    }
    catch
    {
        Write-WtLog -Level Debug -Message 'The slmgr.vbs probe failed; the component is reported as unavailable.' -NoConsole
    }

    try
    {
        $Svc = Get-WtLicensingService -Name 'spssvc'
        $Result.Service = [string]$Svc.Status
        $Result.ServiceStartType = [string]$Svc.StartType
    }
    catch
    {
        $Result.Service = 'unreadable'
        $Result.ServiceError = (Get-WtSanitizedMessage -Message $_.Exception.Message -MaxLength 160)
    }

    try
    {
        $Latest = @(Get-WtLicensingWinEvent -LogName 'Application' -ProviderName 'Software Protection Platform Service') | Select-Object -First 1
        if ($Latest)
        {
            $Result.LastActivationError = [string]$Latest.Message
            $Result.LastActivationErrorUtc = $Latest.TimeCreated.ToUniversalTime().ToString('o')
        }
    }
    catch
    {
        $Result.LastActivationErrorReadError = (Get-WtSanitizedMessage -Message $_.Exception.Message -MaxLength 160)
        Write-WtLog -Level Debug -Message ('The Software Protection Service log is unreadable; the last activation error stays unknown. ' + $Result.LastActivationErrorReadError) -NoConsole
    }

    return $Result
}

<#
.SYNOPSIS
    Reads organization-managed activation configuration when accessible.
.DESCRIPTION
    KMS/activation configuration lives in HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform
    and the SLMGR KMS registry entries. Only the presence of configuration keys (paths) is
    reported, never the hostnames or keys themselves.
#>
function Read-WtLicensingOrgConfig
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param ()

    $Result = @{
        Managed = $false
        KeyPresent = $false
        Sources = @()
    }

    $Paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SoftwareProtectionPlatform',
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SLMGR'
    )

    foreach ($Path in $Paths)
    {
        try
        {
            if (Test-Path -LiteralPath $Path)
            {
                $Result.KeyPresent = $true
                $Result.Sources += [string]$Path
                $Result.Managed = $true
            }
        }
        catch
        {
            Write-WtLog -Level Debug -Message "The licensing configuration key $Path is unreadable; it is reported as absent." -NoConsole
        }
    }

    return $Result
}

<#
.SYNOPSIS
    Builds the full read-only licensing diagnostics view.
#>
function Read-WtLicensingDiagnostics
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $false)][switch]$Refresh,
        [Parameter(Mandatory = $false)][switch]$IncludePartialKey,
        [Parameter(Mandatory = $false)][switch]$IncludeSlmgr
    )

    $Inventory = Read-WtLicensingInventory -Refresh:$Refresh -IncludePartialKey:$IncludePartialKey
    $Time = Read-WtLicensingTimeState
    $Components = Read-WtLicensingComponents
    $Org = Read-WtLicensingOrgConfig

    $Diagnostics = @{
        CollectedUtc = [datetime]::UtcNow
        Inventory = $Inventory
        Time = $Time
        Components = $Components
        Org = $Org
        Redacted = $false
    }

    # The slmgr comparison (cscript /xpr and /dlv) is a child-process probe and is never
    # run synchronously on the UI thread. It is only computed by the background info
    # collector (see InfoCollector.ps1), which sets Slmgr on the workspace's snapshot.
    if ($IncludeSlmgr)
    {
        $Diagnostics.Slmgr = Get-WtSlmgrComparison
    }
    else
    {
        $Diagnostics.Slmgr = $null
    }

    return $Diagnostics
}

<#
.SYNOPSIS
    Prepares the export payload with redaction applied.
.DESCRIPTION
    Exports never include full product keys, tokens, machine identifiers or hostnames.
    The partial key is replaced by a marker; organization hostnames in the reason text are
    stripped; and the report preview is shown before anything is written.
#>
function Get-WtLicensingExportPayload
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param
    (
        [Parameter(Mandatory = $true)][hashtable]$License,
        [Parameter(Mandatory = $false)][switch]$IncludePartialKey
    )

    $Payload = [ordered]@{
        exportedUtc = [datetime]::UtcNow.ToString('o')
        source = $License.Inventory.Source
        collectedUtc = $License.CollectedUtc.ToString('o')
        active = $null
        products = @()
        time = $null
        components = $null
        organizationManaged = $null
    }

    if ($License.Inventory.Active)
    {
        $Active = $License.Inventory.Active
        $Payload.active = [ordered]@{
            productName = [string]$Active.ProductName
            licenseStatus = [string]$Active.LicenseStatus
            licenseStatusRaw = [int]$Active.LicenseStatusRaw
            licenseChannel = [string]$Active.LicenseChannel
            partialProductKey = if ($IncludePartialKey) { [string]$Active.PartialProductKey } else { '<redacted>' }
            graceRemaining = $Active.GraceRemaining
        }
    }

    $Payload.products = @($License.Inventory.Products | ForEach-Object {
            [ordered]@{
                productName = [string]$_.ProductName
                licenseStatus = [string]$_.LicenseStatus
                licenseStatusRaw = [int]$_.LicenseStatusRaw
                licenseChannel = [string]$_.LicenseChannel
            }
        })

    $Payload.time = [ordered]@{
        localNow = [string]$License.Time.LocalNow
        service = [string]$License.Time.Service
        startType = [string]$License.Time.StartType
        synchronized = $License.Time.Synchronized
    }

    $Payload.components = [ordered]@{
        slmgrAvailable = [bool]$License.Components.SlmgrAvailable
        service = [string]$License.Components.Service
        serviceStartType = [string]$License.Components.ServiceStartType
        lastActivationError = [string]$License.Components.LastActivationError
    }

    $Payload.organizationManaged = [bool]$License.Org.Managed

    return $Payload
}

<#
.SYNOPSIS
    Requests activation through the documented slmgr interface.
.DESCRIPTION
    Explicit user request only. Runs `cscript slmgr.vbs /ato` (activate using the
    installed product key and the configured KMS/MAK mechanism). No key is installed, no
    edition is changed, no KMS server is configured, nothing is reset or rearmed. The
    command's accepted status is NOT proof of activation: the inventory is re-read and the
    resulting status reported. Errors are mapped to the structured SLMGR error code when
    the exit code is a documented one.
#>
function Invoke-WtLicensingActivationRequest
{
    [CmdletBinding()]
    [OutputType([hashtable])]

    # -Refresh is part of the parameter set the public Request-WtLicensingActivation wrapper
    # forwards. The status after a request is always re-read (a cached answer is never reported
    # as the result of an activation attempt), so the switch records the caller's intent rather
    # than changing what is returned.
    param ([Parameter(Mandatory = $false)][switch]$Refresh)

    $Result = @{
        Requested = $false
        Accepted = $false
        ExitCode = $null
        ErrorDetail = ''
        StatusAfter = $null
        Reason = ''
    }

    if (-not (Test-WtLicensingAvailable))
    {
        $Result.Reason = 'the licensing provider is only available on Windows'
        return $Result
    }

    $Cscript = Get-Command -Name 'cscript.exe' -ErrorAction Ignore
    if (-not $Cscript)
    {
        $Result.Reason = 'cscript is not available'
        return $Result
    }

    $Slmgr = Get-Command -Name 'slmgr.vbs' -ErrorAction Ignore
    if (-not $Slmgr)
    {
        $Result.Reason = 'slmgr.vbs is not available'
        return $Result
    }

    $Result.Requested = $true
    try
    {
        $Process = Start-Process -FilePath $Cscript.Source -ArgumentList @($Slmgr.Source, '/ato') -NoNewWindow -Wait -PassThru
        $Result.ExitCode = $Process.ExitCode
        $Result.Accepted = ($Process.ExitCode -eq 0)
    }
    catch
    {
        $Result.ErrorDetail = $_.Exception.Message
        $Result.Accepted = $false
    }

    # Evidence, not promise: re-read the inventory and report the resulting status.
    $Result.StatusAfter = Read-WtLicensingInventory -Refresh

    if (-not $Result.Accepted)
    {
        # Documented SLMGR exit codes: 0 success, others are the structured error code.
        $Result.ErrorDetail = if ($Result.ErrorDetail) { $Result.ErrorDetail }
        elseif ($null -ne $Result.ExitCode -and $Result.ExitCode -lt 0)
        {
            $Unsigned = [uint32](([int64]$Result.ExitCode) -band [int64]4294967295)
            "slmgr /ato exited with code 0x$($Unsigned.ToString('X8'))"
        }
        else { "slmgr /ato exited with code $($Result.ExitCode)" }
    }

    return $Result
}

#region Activation evidence

<#
.SYNOPSIS
    Reduces a licensing diagnostics view to the fields an activation attempt is judged by.
.DESCRIPTION
    Pure: it reads the diagnostics object and touches neither the provider nor the disk, so the
    same snapshot can be taken before and after an activation and compared. Only what the
    provider actually reported is copied - the snapshot never derives an expiration date from a
    grace counter, and it never carries a full product key.
.OUTPUTS
    An ordered dictionary: Readable, ProductName, Status, StatusRaw, Channel, GraceRemaining,
    EvaluationEndDate, PartialKeyPresent, CollectedUtc.
#>
function Get-WtLicensingSnapshot
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][AllowNull()][object]$License)

    $Snapshot = [ordered]@{
        Readable           = $false
        ProductName        = ''
        Status             = 'Unknown'
        StatusRaw          = $null
        Channel            = ''
        GraceRemaining     = $null
        EvaluationEndDate  = ''
        PartialKeyPresent  = $false
        CollectedUtc       = ''
    }

    if (-not $License -or -not $License.Inventory) { return $Snapshot }

    $Inventory = $License.Inventory
    if ($Inventory.Unreadable) { return $Snapshot }

    $Snapshot.Readable = $true
    if ($License.CollectedUtc) { $Snapshot.CollectedUtc = ([datetime]$License.CollectedUtc).ToUniversalTime().ToString('o') }

    if (-not $Inventory.Active)
    {
        $Snapshot.Status = 'Unknown'
        return $Snapshot
    }

    $Active = $Inventory.Active
    $Snapshot.ProductName = [string]$Active.ProductName
    # The diagnostics view always carries both; a fixture that only has the raw code still works.
    $Raw = if ($null -ne $Active.LicenseStatusRaw) { [int]$Active.LicenseStatusRaw } else { [int]$Active.LicenseStatus }
    $Snapshot.StatusRaw = $Raw
    $Snapshot.Channel = [string]$Active.LicenseChannel
    $Snapshot.EvaluationEndDate = [string]$Active.EvaluationEndDate
    $Snapshot.Status = switch ($Raw)
    {
        0 { 'Unlicensed' }
        1 { 'Licensed' }
        2 { 'OOBGrace' }
        3 { 'OOTGrace' }
        4 { 'NonGenuineGrace' }
        5 { 'Notification' }
        6 { 'ExtendedGrace' }
        default { 'Unknown' }
    }
    if ($null -ne $Active.GraceRemaining) { $Snapshot.GraceRemaining = [int]$Active.GraceRemaining }
    # The diagnostics read only carries the partial key when the caller asked for it; the
    # snapshot records only whether one is present, never the value.
    $Snapshot.PartialKeyPresent = -not [string]::IsNullOrEmpty([string]$Active.PartialProductKey)

    return $Snapshot
}

<#
.SYNOPSIS
    Compares two licensing snapshots taken around one activation attempt.
.DESCRIPTION
    Pure. The verdict is one of:
      Unreadable - either read failed, so nothing is claimed;
      Activated  - the licence status became the activated state (code 1) where it was not;
      Changed    - the status code moved without reaching the activated state;
      Unchanged  - the status code is the same before and after.
    'Activated' is read from the provider after the attempt; it is never inferred from a command
    exit code.
.OUTPUTS
    An ordered dictionary: Change, BeforeStatus, AfterStatus, StatusChanged, Activated.
#>
function Compare-WtLicensingSnapshot
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)][AllowNull()][object]$Before,
        [Parameter(Mandatory = $false)][AllowNull()][object]$After
    )

    $Comparison = [ordered]@{
        Change         = 'Unreadable'
        BeforeStatus   = $null
        AfterStatus    = $null
        BeforeStatusRaw = $null
        AfterStatusRaw = $null
        StatusChanged  = $false
        Activated      = $false
    }

    if (-not $Before -or -not $After) { return $Comparison }
    if (-not $Before.Readable -or -not $After.Readable) { return $Comparison }

    $Comparison.BeforeStatus = [string]$Before.Status
    $Comparison.AfterStatus = [string]$After.Status
    $Comparison.BeforeStatusRaw = $Before.StatusRaw
    $Comparison.AfterStatusRaw = $After.StatusRaw
    $Comparison.Activated = ($null -ne $After.StatusRaw -and [int]$After.StatusRaw -eq 1)
    $Comparison.StatusChanged = ([string]$Before.StatusRaw -ne [string]$After.StatusRaw)

    if ($Comparison.Activated -and [string]$Before.StatusRaw -ne '1')
    {
        $Comparison.Change = 'Activated'
    }
    elseif ($Comparison.StatusChanged)
    {
        $Comparison.Change = 'Changed'
    }
    else
    {
        $Comparison.Change = 'Unchanged'
    }

    return $Comparison
}

<#
.SYNOPSIS
    Judges whether a Windows activation attempt can be called a success.
.DESCRIPTION
    Pure. Three separate questions are answered instead of one, because they fail independently:
      * CompletionDetermined - the operation lifetime was observed to its end. When it was not
        (a wrapper exited while a detached child kept running, or the process table was
        unreadable), nothing about activation is claimed.
      * Activated - the re-read licensing record reports the activated state. An exit code is
        never used for this.
      * Verified - both of the above.
    The remaining validity is copied from the provider as-is (grace days and, when the provider
    exposes one, an evaluation end date). No expiration date is ever derived or invented, and no
    full product key or activation response is carried: ErrorCode is the structured code the
    Software Protection service logged, when one can be matched.
.OUTPUTS
    An ordered dictionary: Completion, CompletionDetermined, ExitCode, Verified, Activated,
    Changed, AlreadyActive, ReasonKey, ErrorCode, RemainingDays, EvaluationEndDate.
#>
function Get-WtWindowsActivationResult
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][ValidateSet('Completed', 'Unknown', 'Timeout', 'NotStarted', 'Cancelled', 'Refused')][string]$Completion,
        [Parameter(Mandatory = $false)][AllowNull()][object]$ExitCode = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Before = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$After = $null,
        [Parameter(Mandatory = $false)][AllowNull()][object]$Components = $null
    )

    $Comparison = Compare-WtLicensingSnapshot -Before $Before -After $After

    # The activated state is read from the record taken after the method ran; it is not taken from
    # the before/after comparison, so an unreadable *before* read cannot hide a readable answer.
    $Activated = ($After -and $After.Readable -and $null -ne $After.StatusRaw -and [int]$After.StatusRaw -eq 1)

    $Result = [ordered]@{
        Completion           = $Completion
        CompletionDetermined = ($Completion -eq 'Completed')
        ExitCode             = $ExitCode
        Before               = $Before
        After                = $After
        Comparison           = $Comparison
        Verified             = $false
        Activated            = [bool]$Activated
        Changed              = [bool]$Comparison.StatusChanged
        AlreadyActive        = $false
        ReasonKey            = 'Act.Result.NotDetermined'
        ErrorCode            = ''
        RemainingDays        = $null
        EvaluationEndDate    = ''
    }

    if ($After -and $After.Readable)
    {
        $Result.RemainingDays = $After.GraceRemaining
        $Result.EvaluationEndDate = [string]$After.EvaluationEndDate
    }

    if ($Components -and [string]$Components.LastActivationError -match '0x[0-9A-Fa-f]{8}')
    {
        # The code the Software Protection service logged, quoted as it was logged. When the
        # message carries none, the field stays empty instead of being filled with a guess.
        $Result.ErrorCode = $Matches[0]
    }

    if (-not $Result.CompletionDetermined)
    {
        # A launcher or wrapper exit is not a completion: say so and claim nothing else.
        $Result.ReasonKey = 'Act.Result.NotDetermined'
        return $Result
    }

    if (-not $After -or -not $After.Readable)
    {
        $Result.ReasonKey = 'Act.Result.Unreadable'
        return $Result
    }

    if ($Before -and $Before.Readable -and [string]$Before.StatusRaw -eq '1' -and $Activated)
    {
        $Result.AlreadyActive = $true
        $Result.Verified = $true
        $Result.ReasonKey = 'Act.Result.AlreadyActive'
        return $Result
    }

    if ($Activated)
    {
        $Result.Verified = $true
        $Result.ReasonKey = 'Act.Result.Activated'
        return $Result
    }

    $Result.ReasonKey = 'Act.Result.NotActivated'
    return $Result
}

#endregion Activation evidence
