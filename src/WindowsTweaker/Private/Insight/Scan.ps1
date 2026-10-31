# WindowsTweaker - the read-only sanity scan.
#
# The scan answers one question: which configurations on this machine are worth a human look.
# It never answers "is this machine bad", never scores anything, and never repairs.
#
# Hard rules, enforced here rather than documented and hoped for:
#   * every probe is read-only; the only process this file can start is `bcdedit /enum {current}`
#     with no arguments after it, and only when the rule asks for a boot-entry probe;
#   * an unreadable required probe makes the rule - and the scan - Incomplete. Clean is only
#     reported when every required probe of every applicable rule answered;
#   * a non-default value is reported with what the documentation says about it, not as a fault;
#   * an absent value is reported as absent, never as proof of the default behaviour;
#   * nothing is exported unless the caller asks for a path.
#
# Outcomes per rule: Clean, Findings, Incomplete, Unsupported. The scan aggregates them in that
# order of precedence: Unsupported (nothing applicable) < Incomplete < Findings < Clean, where the
# aggregate takes the *most cautious* answer, never the friendliest one.

<#
.SYNOPSIS
    Reads the current boot entry once per scan (read-only).
.DESCRIPTION
    `bcdedit /enum {current}` is the documented way to read the boot-entry elements; it needs an
    elevated session, and when it cannot run the result says so. The command is fixed here: a rule
    can name settings to look for, never a command to run. The executable is resolved from
    %SystemRoot%\System32 rather than from PATH, so a shadowing directory cannot redirect it; the
    PATH lookup is only used when that file does not exist.
.OUTPUTS
    @{ Available; Settings; Error }
#>
function Read-WtBcdEntryInternal
{
    [CmdletBinding()]
    param ()

    $Result = @{ Available = $false; Settings = @{}; Error = '' }

    # Resolve the documented file first. A bare 'bcdedit' lookup walks PATH and PATH entries are
    # shadowable, so that lookup is only ever the fallback for a System32 without bcdedit.
    $SystemRoot = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($SystemRoot)) { $SystemRoot = [System.Environment]::GetFolderPath('Windows') }

    $Command = ''
    if (-not [string]::IsNullOrWhiteSpace($SystemRoot))
    {
        $Candidate = Join-Path (Join-Path $SystemRoot 'System32') 'bcdedit.exe'
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) { $Command = $Candidate }
    }

    if (-not $Command)
    {
        $Found = Get-Command -Name 'bcdedit' -ErrorAction Ignore
        if ($Found) { $Command = [string]$Found.Source }
    }

    if (-not $Command)
    {
        $Result.Error = 'bcdedit is not available on this system.'
        return $Result
    }

    try
    {
        $Output = & $Command '/enum' '{current}' 2>&1
        $ExitCode = $LASTEXITCODE
    }
    catch
    {
        $Result.Error = $_.Exception.Message
        return $Result
    }

    if ($ExitCode -ne 0)
    {
        $Result.Error = (@($Output) | ForEach-Object { [string]$_ } | Where-Object { $_ }) -join ' '
        if (-not $Result.Error) { $Result.Error = "bcdedit exited with code $ExitCode." }
        return $Result
    }

    # Lines look like '<setting> <value>' with an identifier line in braces. Only the elements of
    # the entry are kept; nothing is interpreted beyond the two columns.
    $Settings = @{}
    foreach ($Line in @($Output))
    {
        $Text = [string]$Line
        if ($Text -notmatch '^\s*([a-z][a-z0-9]*)\s+(\S.*?)\s*$') { continue }

        $Name = $Matches[1]
        $Value = $Matches[2]
        if ($Name -in 'identifier', 'device', 'path', 'description', 'locale', 'inherit', 'isolatedcontext') { continue }
        $Settings[$Name] = $Value
    }

    $Result.Available = $true
    $Result.Settings = $Settings
    return $Result
}

<#
.SYNOPSIS
    Runs one probe and reports what it saw.
.OUTPUTS
    Object with ProbeId, Kind, Required, Target, Marker (Value/Absent/Empty/Missing/NonEmpty/
    Unreadable/Unsupported), Value, Type (the registry value type name when a value was read, ''
    otherwise), Display, Fired, Compare, Detail, Source.
#>
function Invoke-WtSanityProbeInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Probe,
        [Parameter(Mandatory = $false)][object]$Pending,
        [Parameter(Mandatory = $false)][hashtable]$Bcd
    )

    $Result = [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.SanityProbeResult'
        ProbeId    = [string]$Probe['id']
        Kind       = [string]$Probe['kind']
        Required   = [bool]$Probe['required']
        Target     = ''
        Marker     = 'Unsupported'
        Value      = $null
        Type       = ''
        Display    = ''
        Fired      = $false
        Compare    = [string]$Probe['reviewWhen']
        Detail     = ''
        Expect     = if ($Probe.Contains('expect')) { $Probe['expect'] } else { $null }
        Source     = if ($Probe.Contains('source')) { $Probe['source'] } else { $null }
    }

    $ReviewWhen = [string]$Probe['reviewWhen']

    switch ([string]$Probe['kind'])
    {
        'PendingRestart'
        {
            if (-not $Pending) { $Pending = Get-WtPendingRestartInternal }

            $Result.Target = 'pending restart markers'
            if ($Pending.Unreadable -gt 0 -and $Pending.Present -eq 0)
            {
                $Result.Marker = 'Unreadable'
                $Result.Detail = "None of the $($Pending.Unreadable) restart markers could be read."
                break
            }

            $Present = @($Pending.Markers | Where-Object { $_.Marker -eq 'NonEmpty' })
            $Unreadable = @($Pending.Markers | Where-Object { $_.Marker -eq 'Unreadable' })

            if ($Present.Count -gt 0)
            {
                $Result.Marker = 'NonEmpty'
                $Result.Display = (@($Present | ForEach-Object { $_.Id }) -join ', ')
                $Result.Fired = ($ReviewWhen -eq 'NonEmpty')
                $Result.Detail = "$($Present.Count) marker(s) hold entries."
                break
            }

            if ($Unreadable.Count -gt 0)
            {
                $Result.Marker = 'Unreadable'
                $Result.Detail = "$($Unreadable.Count) marker(s) could not be read: $(@($Unreadable | ForEach-Object { $_.Id }) -join ', ')."
                break
            }

            $Result.Marker = 'Missing'
            $Result.Detail = 'No restart marker holds entries.'
        }
        'BcdEntry'
        {
            if (-not $Bcd) { $Bcd = Read-WtBcdEntryInternal }
            $Result.Target = 'bcdedit {current}'

            if (-not $Bcd.Available)
            {
                $Result.Marker = 'Unreadable'
                $Result.Detail = "The boot entry could not be read: $($Bcd.Error)"
                break
            }

            $Found = @()
            foreach ($Setting in @($Probe['settings']))
            {
                if (-not $Bcd.Settings.ContainsKey($Setting)) { continue }

                $Value = [string]$Bcd.Settings[$Setting]
                if ($Value -in 'No', 'Default', 'Off') { continue }
                $Found += "$Setting=$Value"
            }

            if ($Found.Count -gt 0)
            {
                $Result.Marker = 'Value'
                $Result.Display = $Found -join ', '
                $Result.Fired = $true
                $Result.Detail = "$($Found.Count) debugging-only boot option(s) are set."
                break
            }

            $Result.Marker = 'Absent'
            $Result.Display = 'not configured'
            $Result.Detail = 'Neither option is configured on the current boot entry.'
        }
        default
        {
            # Registry-based probes share everything up to the comparison.
            $Path = "$($Probe['hive']):\$($Probe['key'])"
            $Name = [string]$Probe['name']
            $Result.Target = "$Path\$Name"

            if (-not (Test-WtRegistryAvailable))
            {
                $Result.Marker = 'Unreadable'
                $Result.Detail = 'The registry provider is not available on this system.'
                break
            }

            $Keys = @()
            if ([string]$Probe['kind'] -eq 'RegistryValuesUnderKey')
            {
                $Keys = @(Get-WtRegistrySubKeyNamesRaw -Path $Path)
                if ($Keys.Count -eq 0)
                {
                    $Result.Marker = if (Test-WtRegistryKeyRaw -Path $Path) { 'Absent' } else { 'Unreadable' }
                    $Result.Detail = if ($Result.Marker -eq 'Absent') { 'The key has no subkeys.' } else { 'The key could not be read.' }
                    break
                }
            }
            else
            {
                $Keys = @('')
            }

            $Hits = @()
            $Missing = 0
            $Unreadable = 0

            foreach ($SubKey in $Keys)
            {
                $SubPath = if ($SubKey) { "$Path\$SubKey" } else { $Path }

                if ([string]$Probe['kind'] -eq 'RegistryPair')
                {
                    $Matched = $true
                    foreach ($Condition in @($Probe['conditions']))
                    {
                        $ConditionState = Get-WtRegistryState -Path $SubPath -Name ([string]$Condition['name'])
                        if (-not $ConditionState.Available)
                        {
                            $Unreadable++
                            $Matched = $false
                            break
                        }

                        $ConditionValue = if ($ConditionState.ValueExists) { [string]$ConditionState.Value } else { '' }
                        if ($ConditionValue -ne [string]$Condition['equals']) { $Matched = $false }
                    }

                    if (-not $Matched) { continue }
                }

                $State = Get-WtRegistryState -Path $SubPath -Name $Name
                if (-not $State.Available)
                {
                    $Unreadable++
                    continue
                }

                if (-not $State.ValueExists)
                {
                    $Missing++
                    continue
                }

                $Hits += [pscustomobject]@{ Path = $SubPath; Value = $State.Value; Kind = [string]$State.Kind }
            }

            if ($Hits.Count -eq 0)
            {
                if ($Unreadable -gt 0)
                {
                    $Result.Marker = 'Unreadable'
                    $Result.Detail = "$Unreadable location(s) could not be read."
                    break
                }

                $Result.Marker = 'Absent'
                $Result.Detail = if ($Keys.Count -gt 1) { 'The value is not present under any subkey.' } else { 'The value is not present.' }
                break
            }

            $Result.Marker = 'Value'
            $Result.Display = (@($Hits | ForEach-Object {
                        if ($Keys.Count -gt 1) { "$(Split-Path -Leaf $_.Path)=$($_.Value)" } else { [string]$_.Value }
                    }) -join ', ')
            $Result.Value = if ($Hits.Count -eq 1) { $Hits[0].Value } else { @($Hits | ForEach-Object { $_.Value }) }

            # What was actually read, so a finding can state the registry type instead of implying
            # one. Several locations may disagree; every distinct type is listed.
            $Result.Type = (@($Hits | ForEach-Object { [string]$_.Kind } | Where-Object { $_ } | Select-Object -Unique) -join ', ')

            # Comparison against the documented shape.
            switch ($ReviewWhen)
            {
                'Present' { $Result.Fired = $true }
                'Absent' { $Result.Fired = $true }
                'NonEmpty' { $Result.Fired = $true }
                'NotIn'
                {
                    foreach ($Hit in $Hits)
                    {
                        $Text = [string]$Hit.Value
                        $Allowed = @(@($Probe['values']) | ForEach-Object { [string]$_ })
                        if ($Allowed -notcontains $Text) { $Result.Fired = $true }
                    }
                }
                'GreaterThan'
                {
                    $Threshold = [double]$Probe['value']
                    foreach ($Hit in $Hits)
                    {
                        $Number = 0.0
                        if ([double]::TryParse([string]$Hit.Value, [ref]$Number) -and $Number -gt $Threshold) { $Result.Fired = $true }
                    }
                }
            }

            if ($Missing -gt 0 -and $Hits.Count -gt 0)
            {
                $Result.Detail = "$($Hits.Count) location(s) carry the value, $Missing do not."
            }
            elseif ($Result.Detail -eq '')
            {
                $Result.Detail = if ($Result.Fired) { 'The value is present and differs from the documented shape.' } else { 'The value is present and matches the documented shape.' }
            }
        }
    }

    return $Result
}

<#
.SYNOPSIS
    Runs one rule: supported-OS check, probes, outcome and findings.
.OUTPUTS
    @{ Rule; Outcome; Probes; Findings; Reason; Supported }
#>
function Invoke-WtSanityRuleInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Rule,
        [Parameter(Mandatory = $false)][object]$Pending,
        [Parameter(Mandatory = $false)][hashtable]$Bcd,
        [Parameter(Mandatory = $false)][object]$Environment
    )

    $Result = @{ Rule = $Rule; Outcome = 'Unsupported'; Probes = @(); Findings = @(); Reason = ''; Supported = $false }

    if (-not $Environment) { $Environment = Get-WtEnvironmentInternal }

    if (@($Rule.SupportedOS).Count -gt 0 -and @($Rule.SupportedOS) -notcontains [string]$Environment.OSVersionKey)
    {
        $Result.Reason = "This rule applies to $(@($Rule.SupportedOS) -join ', '); this system reports '$($Environment.OSVersionKey)'."
        return $Result
    }

    if ([int]$Rule.MinBuild -gt 0 -and [int]$Environment.OSBuild -gt 0 -and [int]$Environment.OSBuild -lt [int]$Rule.MinBuild)
    {
        $Result.Reason = "This rule needs build $($Rule.MinBuild) or later; this system reports $($Environment.OSBuild)."
        return $Result
    }

    if (-not $Pending) { $Pending = Get-WtPendingRestartInternal }

    $Probes = @()
    foreach ($Probe in @($Rule.Probes))
    {
        $Probes += Invoke-WtSanityProbeInternal -Probe $Probe -Pending $Pending -Bcd $Bcd
    }

    $Result.Probes = $Probes
    $Result.Supported = $true

    $Required = @($Probes | Where-Object { $_.Required })
    $Unreadable = @($Required | Where-Object { $_.Marker -in 'Unreadable', 'Unsupported' })
    $Fired = @($Probes | Where-Object { $_.Fired })

    if ($Fired.Count -gt 0)
    {
        $Result.Outcome = 'Findings'
        $Findings = @()
        foreach ($Probe in $Fired)
        {
            $Expected = if ($Probe.Expect) { $Probe.Expect } else { $Rule.Expected }
            $Findings += [pscustomobject]@{
                PSTypeName = 'WindowsTweaker.SanityFinding'
                RuleId     = [string]$Rule.Id
                Revision   = [int]$Rule.Revision
                Area       = [string]$Rule.Area
                Severity   = [string]$Rule.Severity
                Title      = $Rule.Title
                Rationale  = $Rule.Rationale
                ProbeId    = $Probe.ProbeId
                Target     = $Probe.Target
                Observed   = $Probe.Display
                ObservedMarker = $Probe.Marker
                ObservedType = [string]$Probe.Type
                Expected   = $Expected
                Effective  = [string]$Rule.Effective
                Claim      = if ($Probe.Source -and $Probe.Source['claim']) { [string]$Probe.Source['claim'] } else { [string]$Rule.Source.Claim }
                Source     = if ($Probe.Source -and $Probe.Source['url']) { $Probe.Source } else { $Rule.Source }
                Limitations = $Rule.Limitations
                NextStep   = $Rule.NextStep
                Remediation = $Rule.Remediation
                ProbeDetail = $Probe.Detail
                # The rule's own scope, carried on the finding so a consumer never has to re-read
                # the rule document to know where the claim applies.
                Conditions = @{
                    SupportedOS = @($Rule.SupportedOS)
                    MinBuild    = [int]$Rule.MinBuild
                }
            }
        }

        $Result.Findings = $Findings
        if ($Unreadable.Count -gt 0)
        {
            # Findings are still reported, but the rule is not "complete": something it needs
            # could not be read, so the picture is partial and the aggregate must say so.
            $Result.Outcome = 'Incomplete'
            $Result.Reason = "$($Unreadable.Count) required probe(s) could not be read: $(@($Unreadable | ForEach-Object { $_.ProbeId }) -join ', ')."
        }

        return $Result
    }

    if ($Unreadable.Count -gt 0)
    {
        $Result.Outcome = 'Incomplete'
        $Result.Reason = "$($Unreadable.Count) required probe(s) could not be read: $(@($Unreadable | ForEach-Object { $_.ProbeId }) -join ', ')."
        return $Result
    }

    $Result.Outcome = 'Clean'
    return $Result
}

<#
.SYNOPSIS
    Runs the sanity scan over the loaded rules.
.PARAMETER Rule
    Rule ids to run; empty runs every loaded rule.
.OUTPUTS
    Scan object: Outcome, Rules, Findings, Pending, Gaps, Exported, Errors.
#>
function Invoke-WtSanityScanInternal
{
    [CmdletBinding()]
    param ([Parameter(Mandatory = $false)][string[]]$Rule = @())

    $Rules = if (@($Rule).Count -gt 0)
    {
        @($Rule | ForEach-Object { Get-WtSanityRuleInternal -Id $_ } | Where-Object { $_ })
    }
    else
    {
        @(Get-WtSanityRuleInternal)
    }

    $UnknownRules = @()
    if (@($Rule).Count -gt 0)
    {
        foreach ($Wanted in @($Rule))
        {
            if (@($Rules | Where-Object { $_.Id -eq $Wanted }).Count -eq 0) { $UnknownRules += $Wanted }
        }
    }

    $Pending = Get-WtPendingRestartInternal
    $Environment = Get-WtEnvironmentInternal
    $Bcd = $null

    $Results = @()
    foreach ($RuleItem in $Rules)
    {
        if (-not $Bcd -and @($RuleItem.Probes | Where-Object { [string]$_['kind'] -eq 'BcdEntry' }).Count -gt 0)
        {
            $Bcd = Read-WtBcdEntryInternal
        }

        $Results += Invoke-WtSanityRuleInternal -Rule $RuleItem -Pending $Pending -Bcd $Bcd -Environment $Environment
    }

    $Findings = @($Results | ForEach-Object { $_.Findings } | Where-Object { $_ })

    $Outcomes = @($Results | ForEach-Object { $_.Outcome })
    $Outcome = if ($Results.Count -eq 0) { 'Unsupported' }
    elseif (@($Outcomes | Where-Object { $_ -ne 'Unsupported' }).Count -eq 0) { 'Unsupported' }
    elseif ($Outcomes -contains 'Incomplete') { 'Incomplete' }
    elseif ($Outcomes -contains 'Findings') { 'Findings' }
    else { 'Clean' }

    $Gaps = @($Results | Where-Object { $_.Outcome -in 'Incomplete', 'Unsupported' } | ForEach-Object {
            [pscustomobject]@{
                PSTypeName = 'WindowsTweaker.SanityGap'
                RuleId     = [string]$_.Rule.Id
                Outcome    = [string]$_.Outcome
                Reason     = [string]$_.Reason
            }
        })

    return [pscustomobject]@{
        PSTypeName     = 'WindowsTweaker.SanityScan'
        Outcome        = $Outcome
        ScannedUtc     = [DateTime]::UtcNow.ToString('o')
        Rules          = @($Results)
        RuleCount      = $Results.Count
        Findings       = @($Findings)
        FindingCount   = @($Findings).Count
        Gaps           = @($Gaps)
        UnknownRules   = @($UnknownRules)
        PendingRestart = $Pending
        # The scan itself writes nothing. Export-WtSanityReportInternal flips both of these on this
        # same object when it lands a report on disk, so the object carries the truth either way.
        WroteAnything  = $false
        ExportedTo     = ''
    }
}

<#
.SYNOPSIS
    Writes a scan report to an explicit path (never to a default location).
.DESCRIPTION
    Only the user's explicit request reaches this function. The report contains the findings, the
    gaps and the source citations; it contains no machine identifiers and no environment dump.
    An existing file is never replaced unless -Force is given: the refusal writes nothing and is
    reported in the result. A missing parent directory is created.
.PARAMETER Force
    Replace an existing report file.
.OUTPUTS
    @{ Ok; Path; Refused; Message } - Ok is $true only when a report was written. Path is the full
    path in both cases. Message explains a refusal and is empty on success.
#>
function Export-WtSanityReportInternal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)][object]$Scan,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][ValidateSet('Json', 'Markdown')][string]$Format = 'Markdown',
        [Parameter(Mandatory = $false)][switch]$Force
    )

    $Full = [System.IO.Path]::GetFullPath($Path)

    # Refuse before touching the disk: an existing report belongs to whoever wrote it, and the scan
    # never overwrites without being told to explicitly.
    if (-not $Force -and (Test-Path -LiteralPath $Full -PathType Leaf))
    {
        return [pscustomobject]@{
            PSTypeName = 'WindowsTweaker.SanityExportResult'
            Ok         = $false
            Path       = $Full
            Refused    = $true
            Message    = "A file already exists at $Full; nothing was written. Pass -Force to overwrite it."
        }
    }

    $Directory = Split-Path -Parent $Full
    if ($Directory -and -not (Test-Path -LiteralPath $Directory))
    {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    if ($Format -eq 'Json')
    {
        $Payload = [ordered]@{
            scan       = 'WindowsTweaker sanity scan'
            outcome    = $Scan.Outcome
            scannedUtc = $Scan.ScannedUtc
            findings   = @($Scan.Findings | ForEach-Object {
                    [ordered]@{
                        rule       = $_.RuleId
                        revision   = $_.Revision
                        area       = $_.Area
                        severity   = $_.Severity
                        probe      = $_.ProbeId
                        target     = $_.Target
                        observed   = $_.Observed
                        observedType = $_.ObservedType
                        expected   = $_.Expected
                        effective  = $_.Effective
                        claim      = $_.Claim
                        source     = $_.Source.Url
                        limitations = $_.Limitations
                        nextStep   = $_.NextStep
                        conditions = [ordered]@{
                            supportedOS = @($_.Conditions.SupportedOS)
                            minBuild    = [int]$_.Conditions.MinBuild
                        }
                        remediation = if ($_.Remediation)
                        {
                            [ordered]@{
                                kind  = [string]$_.Remediation.Kind
                                tweak = [string]$_.Remediation.Tweak
                                notes = $_.Remediation.Notes
                            }
                        }
                        else { $null }
                    }
                })
            gaps       = @($Scan.Gaps | ForEach-Object { [ordered]@{ rule = $_.RuleId; outcome = $_.Outcome; reason = $_.Reason } })
        }

        ($Payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Full -Encoding utf8
    }
    else
    {
        $Lines = @(
            '# WindowsTweaker sanity scan'
            ''
            ('Outcome: **{0}**  ' -f $Scan.Outcome)
            ('Scanned: {0}  ' -f $Scan.ScannedUtc)
            ('Rules run: {0}  ' -f $Scan.RuleCount)
            ('Findings: {0}' -f $Scan.FindingCount)
            ''
            'A finding means a configuration is worth reviewing, not that it is wrong. Every finding'
            'carries the documented claim it rests on and what that claim does not cover.'
            ''
        )

        foreach ($Finding in @($Scan.Findings))
        {
            $Scope = if (@($Finding.Conditions.SupportedOS).Count -gt 0) { @($Finding.Conditions.SupportedOS) -join ', ' } else { 'any Windows' }
            $Build = if ([int]$Finding.Conditions.MinBuild -gt 0) { "build $($Finding.Conditions.MinBuild) or later" } else { 'no minimum build' }

            $Lines += ('## {0} ({1}, severity {2})' -f (Get-WtText -Value $Finding.Title), $Finding.RuleId, $Finding.Severity)
            $Lines += ''
            $Lines += ('- Target: `{0}`' -f $Finding.Target)
            $Lines += ('- Observed: {0}' -f $Finding.Observed)
            $Lines += ('- Observed type: {0}' -f $(if ($Finding.ObservedType) { [string]$Finding.ObservedType } else { 'no registry value was read' }))
            $Lines += ('- Applies to: {0}, {1}' -f $Scope, $Build)
            $Lines += ('- Documented expectation: {0}' -f (Get-WtText -Value $Finding.Expected))
            $Lines += ('- Why it matters: {0}' -f (Get-WtText -Value $Finding.Rationale))
            $Lines += ('- Effective behaviour: {0} (this rule does not measure it)' -f $Finding.Effective)
            $Lines += ('- Claim: {0}' -f $Finding.Claim)
            $Lines += ('- Source: {0}' -f $Finding.Source.Url)
            $Lines += ('- Limitations: {0}' -f (Get-WtText -Value $Finding.Limitations))
            $Lines += ('- Next step: {0}' -f (Get-WtText -Value $Finding.NextStep))

            if ($Finding.Remediation)
            {
                $Remediation = if ([string]$Finding.Remediation.Kind -eq 'Tweak') { "tweak '$($Finding.Remediation.Tweak)'" } else { [string]$Finding.Remediation.Kind }
                $Lines += ('- Remediation: {0}' -f $Remediation)
                if ($Finding.Remediation.Notes)
                {
                    $Lines += ('- Remediation note: {0}' -f (Get-WtText -Value $Finding.Remediation.Notes))
                }
            }

            $Lines += ''
        }

        if (@($Scan.Gaps).Count -gt 0)
        {
            $Lines += '## Not fully checked'
            $Lines += ''
            foreach ($Gap in @($Scan.Gaps))
            {
                $Lines += ('- {0}: {1} - {2}' -f $Gap.RuleId, $Gap.Outcome, $Gap.Reason)
            }
            $Lines += ''
        }

        ($Lines -join "`n") | Set-Content -LiteralPath $Full -Encoding utf8
    }

    # The scan object is the record of this run: once the report is on disk, that record says so.
    $Scan.WroteAnything = $true
    $Scan.ExportedTo = $Full

    return [pscustomobject]@{
        PSTypeName = 'WindowsTweaker.SanityExportResult'
        Ok         = $true
        Path       = $Full
        Refused    = $false
        Message    = ''
    }
}