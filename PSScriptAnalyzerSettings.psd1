@{
    # PSScriptAnalyzer settings.
    #
    # Every excluded rule below is a deliberate, documented design decision, not a
    # silenced defect. Anything that indicated a real problem (unused variables,
    # assignments to automatic variables, empty catch blocks, mandatory parameters
    # with default values, ShouldProcess advertised but not used, delegation wrappers)
    # was FIXED in the code instead of being excluded.
    Severity    = @('Error', 'Warning')

    ExcludeRules = @(
        # The console/GUI interfaces and the log mirror write to the host on purpose.
        # Machine-readable status never goes through Write-Host: every operation emits
        # a structured record via Write-WtLog (JSONL) as well.
        'PSAvoidUsingWriteHost'

        # The *-Raw provider functions are the single, deliberately narrow place that
        # mutates the system. They intentionally do not implement SupportsShouldProcess:
        # the layer above them (Set-WtRegistryValue, Set-WtServiceState, ...) performs
        # the dry-run check, state capture, verification and logging, and the public
        # Invoke-WtTweak/Undo-WtTweak confirm once per tweak.
        'PSUseShouldProcessForStateChangingFunctions'

        # Private helpers return hashtables/ordered dictionaries/arrays for internal
        # consumption; declaring [OutputType] on them adds noise without value. The
        # exported commands do declare their output types.
        'PSUseOutputTypeCorrectly'

        # Private helper naming (Get-WtSupportedLanguages, Get-WtTuiOverviewItems,
        # Assert-WtScriptParses). Exported command names are singular.
        'PSUseSingularNouns'

        # The rule is not a preference here, it is the opposite of what the project needs:
        # Windows PowerShell 5.1 is a supported runtime (the manifest declares
        # PowerShellVersion = 5.1), and it decodes a BOM-less file with the ANSI code page,
        # which mangles every Vietnamese string table and every Vietnamese literal in the
        # interface. Files that contain non-ASCII therefore carry a UTF-8 BOM, and
        # tools/Test-Compatibility.ps1 (phase 7 of the validation suite) fails the build if
        # one of them does not. Runtime data files are still written BOM-less through
        # Write-WtTextFile, because PowerShell 7 would otherwise read a BOM back into the
        # first journal/log line.
        'PSUseBOMForUnicodeEncodedFile'

        # Tweak detectors/appliers share one fixed invocation signature
        # `param($Tweak, $Arguments)`; a detector that needs neither still declares both
        # so the framework can call every tweak identically.
        'PSReviewUnusedParameter'
    )
}
