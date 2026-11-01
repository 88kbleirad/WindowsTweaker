# WindowsTweaker - helpers for the external-tool tests.
#
# This file is dot-sourced into the *module* session state by tests/ExternalTool.Tests.ps1
# (see its BeforeAll block), because the helpers call the module's own private functions
# (Get-WtExternalToolRoot, Write-WtAtomicFile, ...) and because a function defined inline in
# an InModuleScope block would not survive that block.
#
# Its name does not end in .Tests.ps1, so Pester never discovers it on its own.
#
# Nothing in this file downloads, launches or elevates anything: the "installed copy" it can
# create is an inert fixture file, described by an equally inert provenance record.

<#
.SYNOPSIS
    Computes the SHA-256 and the git blob id of some bytes, independently of the module.
.DESCRIPTION
    The expectation a verification test compares against is computed here with .NET
    directly, so a mistake in the implementation's own hashing cannot make a test pass.
#>
function script:Get-WtTestDigest
{
    param ([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $Sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $Sha = $Sha256.ComputeHash($Bytes) } finally { $Sha256.Dispose() }

    $Sha1 = [System.Security.Cryptography.SHA1]::Create()
    try
    {
        # git's own object id: "blob <length>\0" followed by the content.
        $Header = [System.Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
        $null = $Sha1.TransformBlock($Header, 0, $Header.Length, $null, 0)
        $null = $Sha1.TransformFinalBlock($Bytes, 0, $Bytes.Length)
        $Blob = $Sha1.Hash
    }
    finally { $Sha1.Dispose() }

    $ToHex = { param ($Data) ($Data | ForEach-Object { $_.ToString('x2') }) -join '' }

    return @{ Sha256 = (& $ToHex $Sha); GitBlobSha1 = (& $ToHex $Blob); Bytes = $Bytes.Length }
}

<#
.SYNOPSIS
    Builds a pin for an inert fixture, with the same shape as the shipped pin.
.DESCRIPTION
    The URL is the real pinned URL, but no test that uses this spec ever fetches it: the
    transport (Save-WtExternalToolDownload) is mocked wherever the download path runs.
.PARAMETER BreakDigests
    Record digests that do not match the content, which is how the integrity refusal is
    exercised.
#>
function script:New-WtTestSpec
{
    param
    (
        [Parameter(Mandatory = $false)][string]$Content = 'inert MAS fixture payload',
        [Parameter(Mandatory = $false)][string]$FileName = 'MAS_AIO.cmd',
        [Parameter(Mandatory = $false)][int]$MaxBytes = 1048576,
        [Parameter(Mandatory = $false)][switch]$BreakDigests
    )

    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $Digest = Get-WtTestDigest -Bytes $Bytes

    $Sha256 = $Digest.Sha256
    $BlobSha1 = $Digest.GitBlobSha1
    if ($BreakDigests)
    {
        $Sha256 = ('0' * 64)
        $BlobSha1 = ('0' * 40)
    }

    return [ordered]@{
        Id               = 'microsoft-activation-scripts'
        Name             = 'Fixture tool'
        Repository       = 'massgravel/Microsoft-Activation-Scripts'
        RepositoryUrl    = 'https://github.com/massgravel/Microsoft-Activation-Scripts'
        DocumentationUrl = 'https://massgrave.dev/'
        License          = 'GPL-3.0'
        LicenseUrl       = 'https://github.com/massgravel/Microsoft-Activation-Scripts/blob/abc/LICENSE'
        Tag              = '3.12'
        Commit           = '40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f'
        RepositoryPath   = 'MAS/All-In-One-Version-KL/MAS_AIO.cmd'
        FileName         = $FileName
        Bytes            = $Digest.Bytes
        Sha256           = $Sha256
        GitBlobSha1      = $BlobSha1
        DownloadUrl      = 'https://raw.githubusercontent.com/massgravel/Microsoft-Activation-Scripts/40c74d0d7f42146b1dd1ab59b5c7e836d6a56d1f/MAS/All-In-One-Version-KL/MAS_AIO.cmd'
        MaxBytes         = $MaxBytes
        TimeoutSeconds   = 30
        MaxRedirects     = 3
        PinSource        = 'shipped'
        RequiresAdmin    = $true
        Content          = $Content
    }
}

<#
.SYNOPSIS
    Installs an inert fixture as a verified local copy.
.DESCRIPTION
    Writes the fixture file and the provenance record that pins it, which is what makes a
    local copy "ready" for the interface tests (the shipped pin describes the real upstream
    artifact, so it cannot describe a fixture). Nothing here is MAS, and nothing here can run.
#>
function script:New-WtTestInstalledCopy
{
    param ([Parameter(Mandatory = $false)][string]$Content = 'inert MAS fixture payload')

    $Spec = Get-WtExternalToolSpec
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $Digest = Get-WtTestDigest -Bytes $Bytes

    New-WtDirectory -Path (Get-WtExternalToolRoot)
    [System.IO.File]::WriteAllBytes((Get-WtExternalToolEntryPointPath -Spec $Spec), $Bytes)

    $Record = [ordered]@{
        schema        = 'windows-tweaker.external-tool/1'
        toolId        = 'microsoft-activation-scripts'
        repository    = 'https://github.com/massgravel/Microsoft-Activation-Scripts'
        tag           = 'fixture'
        commit        = ('f' * 40)
        fileName      = $Spec.FileName
        downloadUrl   = $Spec.DownloadUrl
        bytes         = $Digest.Bytes
        sha256        = $Digest.Sha256
        gitBlobSha1   = $Digest.GitBlobSha1
        pinSource     = 'user-update'
        downloadedUtc = '2026-01-01T00:00:00.0000000Z'
    }
    $null = Write-WtAtomicFile -Path (Get-WtExternalToolProvenancePath) -Value (ConvertTo-WtJson -InputObject $Record -Depth 6)
}
